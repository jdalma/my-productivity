import AppKit
import SwiftUI
import TowerCore

// The IDE area's buffers (G4 I7): one worktree's editor with what Swift holds of its files (EditorBuffers.swift), the
// banner for a disk change under an edit, the tabs, and where an editor with edits that are not saved waits while no
// window shows it.

/// The editor of the built page for `root`; nil when editor-web was not built.
@MainActor func builtEditor(_ root: String) -> EditorController? {
    editorPageFolder.map { EditorController(roots: [root], page: $0) }
}

/// One worktree's editor: the page, its files' state and the watch on the worktree.
@MainActor @Observable
final class IdeSession {
    let root: String
    let editor: EditorController?
    @ObservationIgnored private var watch: FileWatch?
    private(set) var buffers = EditorBuffers()
    private(set) var status = ""
    /// The banner's 비교: the disk's text against the buffer's.
    var comparing: FileDiff?
    /// Making, renaming and trashing from the tree: locked until the user unlocks it for this worktree (D#5 b).
    private(set) var fileOpsLocked = true
    /// The path of a file Swift read itself and the page shows (`show`: a task board link's, D#17), in place of the
    /// shown buffer; nil when a buffer shows. Never unlocked: it is no file of the editor's.
    private(set) var outside: String?

    /// The files a worker wrote lately (W3): marked in the tree and the tabs, and warned of before an edit.
    private(set) var writes = WorkerWrites()
    /// The worker of this worktree, for the warning; nil says 워커.
    var worker: String?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    init(root: String, makeEditor: @MainActor (String) -> EditorController? = builtEditor) {
        self.root = root
        editor = makeEditor(root)
        guard let editor else { return }
        editor.onLanguageNotice = { [weak self] notice in self?.status = notice }
        editor.onDirty = { [weak self] path, dirty in
            guard let self else { return }
            let effect = buffers.setDirty(path, dirty)
            // the first edit of an unlocked file a worker just wrote: the next Edit of the worker may fail on it, or
            // undo it. Only an unlocked file: the page may report a locked one dirty for a moment as it takes the disk's text
            if dirty, buffers.files[path]?.readOnly == false, let warning = writtenWarning(path) { status = warning }
            Task { await self.run(effect) }
        }
        editor.onWrite = { [weak self] path, reply in self?.wrote(path, reply) }
        editor.onRestart = { [weak self] in self?.restarted() }
        let files = editor.files
        let base = realPath(root) ?? root
        watch = FileWatch(root: root) { [weak self] batch in
            Task { @MainActor in
                // the app's own saves and file operations are not the worker's
                let own = await files.ownWrites(batch.changed.map { base + "/" + $0 })
                self?.recordWrites(batch, root: base, own: own)
                for command in await files.diskChanged(batch, root: root) { await self?.disk(command) }
            }
        }
    }

    /// "<worker>가 N초 전에 이 파일을 썼습니다" while a worker's write of `path` is recent; nil otherwise.
    func writtenWarning(_ path: String) -> String? {
        writes.age(path, at: Date()).map { workerWriteWarning(worker: worker, age: $0) }
    }

    /// Takes in a watch batch, and drops each write as it gets old, so the marks go without another event.
    private func recordWrites(_ batch: FileWatchBatch, root: String, own: Set<String>) {
        writes.record(batch, root: root, own: own, at: Date())
        guard expiry == nil, !writes.last.isEmpty else { return }
        expiry = Task { [weak self] in
            // weak across each sleep: a session no window shows is not kept for its marks
            while let oldest = self?.writes.last.values.min() {
                try? await Task.sleep(for: .seconds(max(0.1, oldest.timeIntervalSinceNow + WorkerWrites.window)))
                self?.writes.expire(at: Date())
            }
            self?.expiry = nil
        }
    }

    func open(_ path: String, line: Int? = nil) async {
        guard let editor else { return }
        if let opened = await editor.open(path, line: line) {
            buffers.open(opened.path, hash: opened.hash, readOnly: opened.readOnly)
            outside = nil
            status = ""
        } else {
            status = "열 수 없음"
        }
    }

    /// Shows a file Swift read itself (a task board link's, D#17): read-only, no buffer of this editor's.
    func show(_ command: EditorCommand?) async {
        guard let editor else { return }
        guard let command, case .openFile(let path, _, _, _, _) = command else { return status = "열 수 없음" }
        await editor.show(command)
        outside = path
        status = ""
    }

    func toggleLock() async {
        guard let editor, outside == nil, let shown = buffers.shown, let f = buffers.files[shown] else { return }
        buffers.setReadOnly(shown, !f.readOnly)
        await editor.setReadOnly(shown, !f.readOnly)
    }

    /// The shown file's save. What came of a write is said by `wrote`; the page refuses by itself a file that is
    /// locked or not open.
    func save() async {
        guard let editor else { return }
        say(refusal: await editor.send(.save))
    }

    func toggleFileOps() async {
        fileOpsLocked.toggle()
        await editor?.files.setFileOpsLocked(fileOpsLocked)
    }

    /// The tree's menu, by absolute path; `rename` takes the new name.
    enum FileOp: Equatable {
        case newFile(String), newFolder(String), rename(String, to: String), trash(String)
    }

    /// Does `op` through the editor's files, which judge the path and the lock again, then brings the buffers along:
    /// a new file opens, a renamed file's buffer follows it, a trashed file's buffer is marked deleted.
    func run(_ op: FileOp) async {
        guard let editor else { return }
        let files = editor.files
        let result = switch op {
        case .newFile(let path): await files.createFile(path)
        case .newFolder(let path): await files.createFolder(path)
        case .rename(let path, let name): await files.rename(path, to: name)
        case .trash(let path): await files.trash(path)
        }
        switch result {
        case .refused(let why): status = "하지 않음: " + fileOpRefusalText(why)
        case .failed(let message): status = "실패: " + message
        case .done(let done):
            switch op {
            case .newFile:
                await open(done)
                status = "만듦"
            case .newFolder:
                status = "폴더를 만듦"
            case .rename(let path, _):
                let old = (done as NSString).deletingLastPathComponent + "/" + (path as NSString).lastPathComponent
                for moved in buffers.renamed(from: old, to: done) { await editor.send(.renameFile(from: moved.from, to: moved.to)) }
                status = "이름을 바꿈"
            case .trash:
                // the watch says the same 250 ms later; the buffers hear a deletion once
                for path in buffers.open(under: done) { await run(buffers.diskChanged(path, hash: nil)) }
                status = "휴지통으로 옮김"
            }
        }
    }

    func choose(_ choice: BannerChoice) async {
        guard let shown = buffers.shown else { return }
        await run(buffers.choose(choice, shown))
    }

    /// What the watch saw of an open file, as `EditorFiles.diskChanged` read it.
    private func disk(_ command: EditorCommand) async {
        switch command {
        case .fileChangedOnDisk(let path, _, let hash?): await run(buffers.diskChanged(path, hash: hash), read: command)
        case .fileDeleted(let path): await run(buffers.diskChanged(path, hash: nil))
        default: break
        }
    }

    /// `read`: the disk's text the effect came from, when the caller has it.
    private func run(_ effect: BufferEffect?, read: EditorCommand? = nil) async {
        guard let editor, let effect else { return }
        switch effect {
        case .reload(let path, force: false):
            let command = if let read { read } else { await editor.files.changed(path) }
            // gone since the effect was made: that is the news
            guard case .fileChangedOnDisk(_, _, let hash?) = command else { return await disk(command) }
            let reply = await editor.send(command)
            buffers.reloaded(path, hash: hash, applied: reply?["applied"] as? Bool ?? true)
            // the page locks a file it hears is deleted; this one is there again
            if let f = buffers.files[path] { await editor.setReadOnly(path, f.readOnly) }
        case .reload(let path, force: true):
            guard let command = await editor.files.reload(path), case .reloadFile(_, _, let hash) = command,
                  await editor.send(command) != nil else { return status = "다시 읽지 못함" }
            buffers.reloaded(path, hash: hash, applied: true)
            status = "디스크의 내용으로 바꿈 (편집기에서 ⌘Z로 되돌림)"
        case .deleted(let path):
            await editor.send(.fileDeleted(path: path))
        case .overwrite(let path, let diskHash):
            say(refusal: await editor.send(.overwrite(path: path, diskHash: diskHash)))
        case .compare(let path):
            guard let text = (await editor.send(.getText(path: path)))?["text"] as? String else { return status = "비교하지 못함" }
            comparing = await Task.detached { bufferDiff(path: path, text: text) }.value
            if comparing == nil { status = "비교하지 못함" }
        }
    }

    /// A save the page asked Swift for: its ⌘S, the 저장 button, the banner's 덮어쓰기.
    private func wrote(_ path: String, _ reply: EditorReply) {
        switch reply {
        case .written(let hash):
            buffers.saved(path, hash: hash)
            status = "저장함"
        case .conflict(let diskHash):
            buffers.conflict(path, diskHash: diskHash)
            status = "저장 안 함: 디스크의 파일이 바뀜"
        case .refused(let why): status = "저장 안 함: " + saveRefusalText(why.rawValue)
        case .failed(let message): status = "저장 실패: \(message)"
        case .file, .ok, .lspStarted: break
        }
    }

    /// A save the page refused before asking Swift. It locks a file it heard is deleted: that is the reason then.
    private func say(refusal reply: [String: Any]?) {
        guard reply?["result"] as? String == "refused" else { return }
        let gone = buffers.shown.flatMap { buffers.files[$0]?.disk } == .deleted
        status = "저장 안 함: " + saveRefusalText(gone ? "missing" : reply?["reason"] as? String ?? "")
    }

    /// The page's process ended: its buffers are gone, the edits in them too. The shown file opens again from disk.
    private func restarted() {
        let lost = buffers.unsaved.count
        // a file Swift read itself is shown again by the controller
        let was = outside == nil ? buffers.shown : nil
        buffers = EditorBuffers()
        Task {
            if let was { await open(was) }
            status = lost > 0 ? "편집기가 다시 시작됨: 저장하지 않은 편집 \(lost)개가 사라짐" : "편집기가 다시 시작됨"
        }
    }
}

/// Why a save did not happen, from the reason the page or Swift gave (`EditorRefusal`).
func saveRefusalText(_ reason: String) -> String {
    switch reason {
    case "readOnly": "잠겨 있음 (잠금 해제 뒤 저장)"
    case "missing", "notRegularFile": "디스크에 파일이 없음"
    case "notOpen": "열린 파일이 아님"
    case "outside": "이 작업 트리 밖의 파일"
    default: reason
    }
}

/// Why a file operation from the tree did not happen.
func fileOpRefusalText(_ why: FileOpRefusal) -> String {
    switch why {
    case .locked: "파일 작업이 잠겨 있음"
    case .missing: "그 자리에 없음"
    case .outside: "이 작업 트리 밖"
    case .exists: "같은 이름이 이미 있음"
    case .badName: "쓸 수 없는 이름"
    case .notAbsolute: "경로가 올바르지 않음"
    }
}

/// Every worktree's editor in the app, and the ones that wait: an editor with edits that are not saved is kept
/// when its area stops showing it (another worktree's row, the window closed), and shown again with the next area
/// for that worktree (R24 S1). One without such edits is dropped as before.
@MainActor enum IdeParking {
    private static var parked: [String: IdeSession] = [:]
    private static let all = NSHashTable<IdeSession>.weakObjects()

    /// The waiting editor of `root`, or a new one.
    static func session(for root: String, makeEditor: @MainActor (String) -> EditorController? = builtEditor) -> IdeSession {
        if let waiting = parked.removeValue(forKey: root) { return waiting }
        let session = IdeSession(root: root, makeEditor: makeEditor)
        all.add(session)
        return session
    }

    /// The area stopped showing `session`: true when it waits here, and the area must let go of it.
    static func park(_ session: IdeSession) -> Bool {
        guard !session.buffers.unsaved.isEmpty else { return false }
        parked[session.root] = session
        return true
    }

    /// The files with edits that are not saved, in every editor shown or waiting.
    static var unsaved: [String] { all.allObjects.flatMap(\.buffers.unsaved).sorted() }
}

/// What quitting asks first; nil with nothing to lose.
func unsavedQuitMessage(_ paths: [String], home: String) -> String? {
    guard !paths.isEmpty else { return nil }
    let shown = paths.prefix(8).map { abbreviate($0, home: home) }
    let more = paths.count > shown.count ? ["외 \(paths.count - shown.count)개"] : []
    return "종료하면 이 편집이 사라집니다.\n\n" + (shown + more).joined(separator: "\n")
}

/// Asks before a quit that would lose edits; true: quit.
@MainActor func confirmQuitWithUnsavedEdits() -> Bool {
    let unsaved = IdeParking.unsaved
    guard let message = unsavedQuitMessage(unsaved, home: homeDirectory()) else { return true }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "저장하지 않은 편집 \(unsaved.count)개"
    alert.informativeText = message
    alert.addButton(withTitle: "취소")
    alert.addButton(withTitle: "버리고 종료")
    return alert.runModal() == .alertSecondButtonReturn
}

// MARK: - Views

/// The open files, in the order they were opened: a click shows one. `•` an edit not saved, `!` the disk changed
/// under it or the file is gone.
struct IdeTabs: View {
    let buffers: EditorBuffers
    /// The files a worker wrote lately (W3), marked with ✎.
    var written: Set<String> = []
    let show: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(buffers.tabs, id: \.self) { path in
                    Button { show(path) } label: {
                        Text(Self.label(path, buffers.files[path]) + (written.contains(path) ? " ✎" : ""))
                            .scaledFont(.caption1, design: .monospaced).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(path == buffers.shown ? Color.accentColor.opacity(0.2) : .clear, in: .rect(cornerRadius: 4))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(path)
                    .accessibilityAddTraits(path == buffers.shown ? .isSelected : [])
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
        }
    }

    static func label(_ path: String, _ f: EditorBuffer?) -> String {
        splitPath(path).name + (f?.dirty == true ? " •" : "") + (f.map { $0.disk != .same } == true ? " !" : "")
    }
}

/// The shown file's banner: the disk changed under an edit (four choices, nothing merges by itself), or the file is gone.
struct IdeBanner: View {
    let banner: EditorBanner
    let choose: (BannerChoice) -> Void

    static func title(_ choice: BannerChoice) -> String {
        switch choice {
        case .compare: "비교"
        case .reload: "디스크로 다시 읽기"
        case .overwrite: "덮어쓰기"
        case .keep: "내 편집 유지"
        }
    }

    static func help(_ choice: BannerChoice) -> String {
        switch choice {
        case .compare: "디스크의 내용과 내 편집의 차이를 봅니다. 아무것도 바꾸지 않습니다"
        case .reload: "내 편집을 버리고 디스크의 내용을 읽습니다 (편집기에서 ⌘Z로 되돌릴 수 있음)"
        case .overwrite: "내 편집을 디스크에 씁니다. 디스크의 바뀐 내용은 사라집니다"
        case .keep: "지금은 아무것도 하지 않습니다. 저장할 때 다시 묻습니다"
        }
    }

    static func text(_ banner: EditorBanner) -> String {
        switch banner {
        case .changed: "디스크의 파일이 바뀌었습니다. 저장하지 않은 편집이 있습니다."
        case .deleted(_, let dirty):
            "디스크에서 이 파일이 삭제됐습니다. 내용은 여기 남아 있고 저장할 수 없습니다." + (dirty ? " 저장하지 않은 편집이 있습니다." : "")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(Self.text(banner)).scaledFont(.callout).lineLimit(2)
            Spacer(minLength: 8)
            if case .changed = banner {
                ForEach(BannerChoice.allCases, id: \.self) { choice in
                    Button(Self.title(choice)) { choose(choice) }.help(Self.help(choice))
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("파일 변경 알림")
    }
}

/// The banner's 비교: the disk's text (removed lines) against the buffer's (added lines).
struct IdeCompare: View {
    let file: FileDiff
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("디스크 → 내 편집 · " + file.path).scaledFont(.headline, weight: .semibold)
                Text(changeCounts(added: file.added, removed: file.removed).joined(separator: " ")).foregroundStyle(.secondary)
                Spacer()
                Button("닫기", action: close).keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            ScrollView {
                if file.lines.isEmpty {
                    Text("차이 없음").foregroundStyle(DiffColors.mutedText).padding(12)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
                            LineView(line: line).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DiffColors.canvas)
            .foregroundStyle(DiffColors.text, DiffColors.mutedText)
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
