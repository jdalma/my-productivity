import AppKit
import SwiftUI
import TowerCore

// The board's IDE area (G4 I5, plan K4): the editor with the worktree's folder tree on its right. The editor's files are the worktree's only (D#6 a), read-only until
// unlocked (D#5 b), and the board window's own (D#8 b) while it shows them.

/// One board window's IDE area: the worktree it shows, that worktree's editor (IdeBuffers.swift) and its folder tree.
/// Kept across the detail's redraws and rows. A row of another worktree shows that worktree's editor; the one left
/// waits in `IdeParking` while it holds edits that are not saved, and is dropped otherwise.
@MainActor @Observable
final class IdeState {
    private(set) var session: IdeSession?
    /// The built editor page; tests give a stand-in.
    @ObservationIgnored private let page: URL?

    init(page: URL? = editorPageFolder) { self.page = page }
    /// The tree's diff and file list, read as the diff window reads them.
    let changes = ChangesState()

    var editor: EditorController? { session?.editor }
    var buffers: EditorBuffers { session?.buffers ?? EditorBuffers() }
    /// The real path of the file the editor shows.
    var shown: String? { buffers.shown }
    var readOnly: Bool { shown.flatMap { buffers.files[$0]?.readOnly } ?? true }
    var status: String { session?.status ?? "" }

    /// The worker of the code shown, named in the warning of a file it just wrote (W3).
    var worker: String? { didSet { session?.worker = worker } }

    /// The tree's paths (from its top) of the files a worker wrote lately (W3).
    var workerWritten: Set<String> {
        guard let session, let top = changes.diff(for: session.root)?.toplevel else { return [] }
        let prefix = (realPath(top) ?? top) + "/"
        return Set(session.writes.last.keys.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil })
    }

    /// The warning before unlocking the shown file while a worker's write of it is recent (W3); nil otherwise.
    var unlockWarning: String? {
        guard readOnly, let shown else { return nil }
        return session?.writtenWarning(shown)
    }

    /// Shows `root`'s files: its waiting editor, edits and all, or a new one.
    func show(root: String) {
        guard root != session?.root else { return }
        if let session { _ = IdeParking.park(session) }
        changes.select(workspace: root)
        session = IdeParking.session(for: root, page: page)
        session?.worker = worker
    }

    /// The area left the window (a row with no tmux pane, the window closed): an editor with edits that are not saved
    /// waits for the next area of its worktree; one without stays here, as before.
    func areaGone() {
        if let session, IdeParking.park(session) { self.session = nil }
    }

    /// A tree line picked: a file opens in the editor, a folder does nothing.
    func pick(_ line: TreeLine) {
        guard !line.isFolder, let session, let top = changes.diff(for: session.root)?.toplevel else { return }
        Task { await session.open(top + "/" + line.path) }
    }

    /// A file operation from the tree's menu (I9), then the tree read again.
    func fileOp(_ op: IdeSession.FileOp) async {
        guard let session else { return }
        await session.run(op)
        await changes.load(workspace: session.root)
        await changes.loadFullTree()
    }
}

/// The editor with its folder tree; `at` is the board's refresh, which reads the tree's diff again.
struct IdeArea: View {
    let root: String
    /// The worker whose code this is, for the warning of a file it just wrote.
    var worker: String?
    let at: String
    @Bindable var state: IdeState
    /// The warning asked before unlocking a file a worker just wrote.
    @State private var unlockAsked: String?
    @AppStorage(IdeLayout.storageKey) private var stored = ""

    var body: some View {
        let layout = IdeLayout(stored: stored)
        GeometryReader { geo in
            HStack(spacing: 0) {
                editorColumn.frame(maxWidth: .infinity)
                if layout.treeShown {
                    let width = IdeLayout.treeWidth(layout.treeWidth, total: geo.size.width)
                    DragLine(at: width) { change($0) { $0.treeWidth = $1 } }
                    DiffTreeSidebar(workspace: root, state: state.changes, pick: state.pick,
                                    menu: { line in AnyView(IdeTreeMenu(line: line, state: state)) })
                        .environment(\.workerWritten, state.workerWritten)
                        .frame(width: width)
                }
            }
        }
        .task(id: "\(root) \(at)") {
            state.show(root: root)
            await state.changes.load(workspace: root)
        }
        .onDisappear { state.areaGone() }
        .onChange(of: worker, initial: true) { state.worker = $1 }
        .sheet(isPresented: Binding { state.session?.comparing != nil } set: { if !$0 { state.session?.comparing = nil } }) {
            if let file = state.session?.comparing { IdeCompare(file: file) { state.session?.comparing = nil } }
        }
    }

    private func change(_ value: Double, _ apply: (inout IdeLayout, Double) -> Void) {
        var layout = IdeLayout(stored: stored)
        apply(&layout, value)
        stored = layout.stored
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            bar.padding(.horizontal, 8).padding(.vertical, 4)
            Divider()
            // buffers (I7): the open files once there are two, and the shown file's banner
            if state.buffers.tabs.count > 1 {
                IdeTabs(buffers: state.buffers, written: state.session.map { Set($0.writes.last.keys) } ?? []) { path in Task { await state.session?.open(path) } }
                Divider()
            }
            if let banner = state.buffers.banner {
                IdeBanner(banner: banner) { choice in Task { await state.session?.choose(choice) } }
                Divider()
            }
            if let editor = state.editor {
                EditorWebView(controller: editor)
                    .overlay {
                        if state.shown == nil {
                            Text("오른쪽 트리에서 파일을 고르세요").foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.background)
                        }
                    }
            } else {
                Text("편집기 페이지가 빌드되지 않았습니다 (editor-web에서 npm run build)").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            if let shown = state.shown {
                Text(abbreviate(shown, home: homeDirectory()) + (state.buffers.files[shown]?.dirty == true ? " •" : ""))
                    .scaledFont(.caption1, design: .monospaced).lineLimit(1).truncationMode(.head).help(shown)
            } else {
                Text("편집기").scaledFont(.headline, weight: .semibold)
            }
            Spacer(minLength: 8)
            Text(state.status).scaledFont(.caption1).foregroundStyle(.secondary).lineLimit(1)
            Button(state.readOnly ? "잠금 해제" : "잠그기", systemImage: state.readOnly ? "lock" : "lock.open") {
                if let warning = state.unlockWarning { unlockAsked = warning } else { Task { await state.session?.toggleLock() } }
            }
            .confirmationDialog(unlockAsked ?? "", isPresented: Binding { unlockAsked != nil } set: { if !$0 { unlockAsked = nil } }) {
                Button("잠금 해제") { Task { await state.session?.toggleLock() } }
            } message: {
                Text("워커가 이 파일을 계속 고치는 중일 수 있습니다. 지금 고치면 워커의 다음 편집이 실패하거나 내 편집을 덮을 수 있습니다.")
            }
            .disabled(state.shown == nil)
            .help("작업 트리 파일은 읽기 전용으로 열립니다. 풀면 이 파일을 고쳐 저장할 수 있습니다")
            Button("저장", systemImage: "square.and.arrow.down") { Task { await state.session?.save() } }
                .disabled(state.shown == nil || state.readOnly)
                .help("저장 (편집기 안에서 ⌘S)")
            Button("트리", systemImage: "sidebar.right") { change(0) { l, _ in l.treeShown.toggle() } }
                .help("폴더 트리 보이기/숨기기")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}

/// The line between the editor and the tree, which a drag moves: `at` is the tree's width when the drag began,
/// `moved` gets the width it asks for.
private struct DragLine: View {
    let at: Double
    let moved: (Double) -> Void
    @State private var dragFrom: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: IdeLayout.line)
            .overlay {
                Color.clear
                    .frame(width: 7)
                    .contentShape(.rect)
                    .background(ResizeLeftRightCursor())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let from = dragFrom ?? at
                                dragFrom = from
                                moved(from - drag.translation.width)
                            }
                            .onEnded { _ in dragFrom = nil }
                    )
                    .help("끌어서 트리 폭 조절")
            }
            .zIndex(1)
    }
}

/// Shows the left-right resize cursor over its bounds and lets clicks through to the SwiftUI view above it.
private struct ResizeLeftRightCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Area() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Area: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - The tree's file menu (G4 I9)

/// The absolute path of a new file or folder `name` made from `line`'s menu: in the line's folder, beside a file's
/// line, or in `root` where no line is. `name` may hold folders (`a/b.swift`); `toplevel` is what the tree's paths are from.
func newPath(_ name: String, from line: TreeLine?, toplevel: String, root: String) -> String {
    let folder = line.map { toplevel + "/" + ($0.isFolder ? $0.path : String(splitPath($0.path).dir.dropLast())) } ?? root
    return (folder.hasSuffix("/") ? String(folder.dropLast()) : folder) + "/" + name
}

/// Asks for a name in a dialog; nil when cancelled or left empty.
@MainActor func askName(_ title: String, initial: String = "", note: String = "") -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = note
    let field = NSTextField(string: initial)
    field.frame = NSRect(x: 0, y: 0, width: 320, height: 22)
    alert.accessoryView = field
    alert.addButton(withTitle: "확인")
    alert.addButton(withTitle: "취소")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : name
}

/// The context menu of the board window's worktree tree: make, rename, trash. Everything but the lock is off until
/// the user unlocks file operations for this worktree (D#5 b).
struct IdeTreeMenu: View {
    let line: TreeLine?
    let state: IdeState

    var body: some View {
        let locked = state.session?.fileOpsLocked ?? true
        Button(locked ? "파일 작업 잠금 해제" : "파일 작업 잠그기") { Task { await state.session?.toggleFileOps() } }
        Divider()
        Group {
            Button("새 파일…") { make(folder: false) }
            Button("새 폴더…") { make(folder: true) }
            if let line {
                Button("이름 변경…") {
                    guard let path = absolute(line), let name = askName("이름 변경", initial: splitPath(line.path).name) else { return }
                    Task { await state.fileOp(.rename(path, to: name)) }
                }
                Button("휴지통으로 이동") {
                    guard let path = absolute(line) else { return }
                    Task { await state.fileOp(.trash(path)) }
                }
            }
        }
        .disabled(locked)
    }

    private var toplevel: String? { state.session.flatMap { state.changes.diff(for: $0.root)?.toplevel } }

    private func absolute(_ line: TreeLine) -> String? { toplevel.map { $0 + "/" + line.path } }

    private func make(folder: Bool) {
        guard let root = state.session?.root, let toplevel,
              let name = askName(folder ? "새 폴더" : "새 파일", note: folder ? "폴더는 파일이 생긴 뒤에 트리에 보입니다 (git이 빈 폴더를 세지 않음)" : "이름에 /를 넣으면 폴더도 만듭니다") else { return }
        let path = newPath(name, from: line, toplevel: toplevel, root: root)
        Task { await state.fileOp(folder ? .newFolder(path) : .newFile(path)) }
    }
}
