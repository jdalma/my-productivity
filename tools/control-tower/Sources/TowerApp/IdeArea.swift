import AppKit
import SwiftUI
import TowerCore

// The IDE area (G4 I5, plan K4; I6, K5): the editor with the code's folder tree on its right, in the board window
// the session's terminal under both, the whole width. The editor's files are the worktree's only (D#6 a), read-only
// until unlocked (D#5 b), and each window's own (D#8 b). The task board window's are read-only, never unlocked.

/// One window's editor, its folder tree and the watch on its worktree. Kept across the detail's redraws and rows;
/// made again when another code source shows.
// ponytail: one editor per window, its buffers lost on a switch of worktree; keep one per worktree if switching back and forth costs too much
@MainActor @Observable
final class IdeState {
    /// Whether a file can be unlocked for editing: the board window's; the task board window's never (D#8 b).
    let lockable: Bool
    private(set) var source: TaskCodeSource?
    @ObservationIgnored private var started = false
    private(set) var editor: EditorController?
    @ObservationIgnored private var watch: FileWatch?
    /// The tree's diff and file list, read as the diff window reads them.
    let changes = ChangesState()
    /// The real path of the file the editor shows.
    private(set) var shown: String?
    private(set) var readOnly = true
    private(set) var dirty: Set<String> = []
    private(set) var status = ""
    /// A commit source's tree: its mode, and its lines; nil lines when git could not read them.
    var commitMode = TreeMode.changed
    private(set) var commitTree: (mode: TreeMode, nodes: [ChangeTreeNode]?)?
    /// Narrow, the code is a tab beside the detail: shown, or the detail is.
    var codeShown = false

    init(lockable: Bool = true) { self.lockable = lockable }

    /// The worktree the editor reads and may save in; nil for a commit or no source.
    var root: String? { if case .worktree(let r) = source { r } else { nil } }

    func show(root: String) { show(.worktree(root)) }

    /// Shows `source`'s files; another source drops the editor's files, its tree and its watch. With no source the
    /// editor still shows documents (`openDocument`).
    func show(_ source: TaskCodeSource?) {
        guard !started || source != self.source else { return }
        started = true
        self.source = source
        shown = nil
        readOnly = true
        dirty = []
        status = ""
        commitTree = nil
        watch = nil
        let root = root
        if let root { changes.select(workspace: root) }
        editor = editorPageFolder.map { EditorController(roots: root.map { [$0] } ?? [], page: $0) }
        guard let editor, let root else { return }
        editor.onDirty = { [weak self] path, dirty in
            if dirty { self?.dirty.insert(path) } else { self?.dirty.remove(path) }
        }
        let files = editor.files
        // a clean buffer takes what a worker wrote; a dirty one keeps the user's edit (its banner is I7's)
        watch = FileWatch(root: root) { [weak editor] batch in
            Task { @MainActor in
                for command in await files.diskChanged(batch, root: root) { await editor?.send(command) }
            }
        }
    }

    /// A tree line picked: a file opens in the editor, a folder does nothing. A commit's file is read from git.
    func pick(_ line: TreeLine) {
        guard !line.isFolder else { return }
        switch source {
        case .worktree(let root)?:
            guard let top = changes.diff(for: root)?.toplevel else { return }
            Task { await open(top + "/" + line.path) }
        case .commit(let repo, _, let commit)?:
            let path = line.path
            Task { await show(await Task.detached { commitOpen(dir: repo, rev: commit, path: path) }.value) }
        case nil: break
        }
    }

    /// A ticket or report the task board names, read-only in this editor (D#7 b); narrow, the code tab comes forward.
    func openDocument(_ path: String) {
        codeShown = true
        Task { await show(await Task.detached { readOnlyOpen(path) }.value) }
    }

    /// Shows a file Swift read itself (a commit's, a document), always read-only.
    private func show(_ command: EditorCommand?) async {
        guard let editor else { return }
        guard let command, case .openFile(let path, _, _, _, _) = command else { status = "열 수 없음"; return }
        await editor.show(command)
        shown = path
        readOnly = true
        status = ""
    }

    /// The commit source's tree in `commitMode`: every file of the commit, or those the task changed from its base.
    func loadCommitTree() async {
        guard case .commit(let repo, let base, let commit)? = source else { return }
        let mode = commitMode
        let nodes = await Task.detached { () -> [ChangeTreeNode]? in
            switch mode {
            case .all: filesAt(dir: repo, rev: commit).map { folderTree(files: $0) }
            case .changed: base.flatMap { diffFiles(dir: repo, base: $0, head: commit) }.map(changedTree)
            }
        }.value
        guard !Task.isCancelled, case .commit(repo, base, commit)? = source, mode == commitMode else { return }
        commitTree = (mode, nodes)
    }

    func open(_ path: String) async {
        guard let editor else { return }
        if let opened = await editor.open(path) {
            shown = opened.path
            readOnly = opened.readOnly
            status = ""
        } else {
            status = "열 수 없음"
        }
    }

    func toggleLock() async {
        guard lockable, let editor, let shown else { return }
        readOnly.toggle()
        await editor.setReadOnly(shown, readOnly)
    }

    func save() async {
        guard let editor else { return }
        let r = await editor.send(.save)
        status = switch r?["result"] as? String {
        case "ok": "저장함"
        case "conflict": "저장 안 함: 디스크의 파일이 바뀜"
        case "refused": "저장 안 함: \(r?["reason"] as? String ?? "")"
        case let other: "저장 실패" + (other.map { ": \($0)" } ?? "")
        }
    }
}

/// The editor over the terminal, or alone without one (the task board window); `at` is the window's refresh, which
/// reads a worktree's diff again.
struct IdeArea: View {
    let source: TaskCodeSource?
    var terminal: TmuxRef?
    let at: String
    @Bindable var state: IdeState
    @AppStorage(IdeLayout.storageKey) private var stored = ""

    var body: some View {
        let layout = IdeLayout(stored: stored)
        GeometryReader { geo in
            let key = state.root ?? ""
            let h = terminal == nil ? (editor: geo.size.height, terminal: 0) : IdeLayout.heights(total: geo.size.height, ratio: layout.ratio(for: key))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    editorColumn.frame(maxWidth: .infinity)
                    if layout.treeShown {
                        let width = IdeLayout.treeWidth(layout.treeWidth, total: geo.size.width)
                        DragLine(axis: .vertical, at: width, total: geo.size.width) { change($0) { $0.treeWidth = $1 } }
                        tree.frame(width: width)
                    }
                }
                .frame(height: h.editor)
                if let terminal {
                    DragLine(axis: .horizontal, at: h.editor, total: geo.size.height) { editor in
                        change(editor) { $0.setRatio(IdeLayout.ratio(editor: $1, total: geo.size.height), for: key) }
                    }
                    // a new terminal, and a new tmux client, for each pane
                    PaneTerminal(ref: terminal).id("\(terminal.session) \(terminal.pane)")
                        .padding(.top, 8)
                        .frame(height: h.terminal)
                }
            }
        }
        .task(id: "\(String(describing: source)) \(at) \(state.commitMode)") {
            state.show(source)
            switch source {
            case .worktree(let root)?: await state.changes.load(workspace: root)
            case .commit?: await state.loadCommitTree()
            case nil: break
            }
        }
    }

    @ViewBuilder
    private var tree: some View {
        switch source {
        case .worktree(let root)?:
            DiffTreeSidebar(workspace: root, state: state.changes, pick: state.pick)
        case .commit(_, _, let commit)?:
            CommitTreeSidebar(commit: commit, state: state)
        case nil:
            Text("이 태스크에는 읽을 코드가 없습니다: 담당 워커가 실행 중이 아니고 커밋을 낸 제출도 없습니다")
                .scaledFont(.caption1).foregroundStyle(.secondary).padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            if let editor = state.editor {
                // another source is another editor: without the identity SwiftUI keeps the first one's web view
                EditorWebView(controller: editor).id(ObjectIdentifier(editor))
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
                Text(abbreviate(shown, home: homeDirectory()) + (state.dirty.contains(shown) ? " •" : ""))
                    .scaledFont(.caption1, design: .monospaced).lineLimit(1).truncationMode(.head).help(shown)
            } else {
                Text("편집기").scaledFont(.headline, weight: .semibold)
            }
            Spacer(minLength: 8)
            Text(state.status).scaledFont(.caption1).foregroundStyle(.secondary).lineLimit(1)
            if state.lockable {
                Button(state.readOnly ? "잠금 해제" : "잠그기", systemImage: state.readOnly ? "lock" : "lock.open") {
                    Task { await state.toggleLock() }
                }
                .disabled(state.shown == nil)
                .help("작업 트리 파일은 읽기 전용으로 열립니다. 풀면 이 파일을 고쳐 저장할 수 있습니다")
                Button("저장", systemImage: "square.and.arrow.down") { Task { await state.save() } }
                    .disabled(state.shown == nil || state.readOnly)
                    .help("저장 (편집기 안에서 ⌘S)")
            } else {
                Label("읽기 전용", systemImage: "lock").help("작업판 창의 편집기는 읽기만 합니다. 고치려면 board 창에서 엽니다")
            }
            Button("트리", systemImage: "sidebar.right") { change(0) { l, _ in l.treeShown.toggle() } }
                .help("폴더 트리 보이기/숨기기")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}

/// A line between two parts of the area that a drag moves: `at` is the first part's size along `axis` when the
/// drag began, `moved` gets the size it asks for. A vertical line sizes the part right of it (the tree).
private struct DragLine: View {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    let at: Double
    let total: Double
    let moved: (Double) -> Void
    @State private var dragFrom: Double?

    var body: some View {
        let horizontal = axis == .horizontal
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: horizontal ? nil : IdeLayout.line, height: horizontal ? IdeLayout.line : nil)
            .overlay {
                Color.clear
                    .frame(width: horizontal ? nil : 7, height: horizontal ? 7 : nil)
                    .contentShape(.rect)
                    .background(horizontal ? AnyView(ResizeUpDownCursor()) : AnyView(ResizeLeftRightCursor()))
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let from = dragFrom ?? at
                                dragFrom = from
                                moved(horizontal ? from + drag.translation.height : from - drag.translation.width)
                            }
                            .onEnded { _ in dragFrom = nil }
                    )
                    .help(horizontal ? "끌어서 편집기와 터미널의 높이 조절" : "끌어서 트리 폭 조절")
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

/// A commit's tree: the files the task changed from its base, or every file of the commit.
private struct CommitTreeSidebar: View {
    let commit: String
    @Bindable var state: IdeState

    var body: some View {
        FolderTreeList(tree: state.changes.tree, pick: state.pick) {
            if let tree = state.commitTree, tree.mode == state.commitMode {
                if let nodes = tree.nodes {
                    if nodes.isEmpty { Text("파일 없음").scaledFont(.caption1).foregroundStyle(.secondary) }
                    ForEach(nodes, id: \.path) { TreeNodeRow(node: $0, part: nil, openByDefault: { _ in tree.mode == .changed }, tree: state.changes.tree) }
                } else {
                    Text("커밋의 파일을 읽지 못함").scaledFont(.caption1).foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Picker("트리", selection: $state.commitMode) {
                    Text("변경된 파일").tag(TreeMode.changed)
                    Text("전체 폴더").tag(TreeMode.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("커밋 \(commit.prefix(7))").scaledFont(.caption1, design: .monospaced).foregroundStyle(.secondary)
                    .help("끝난 태스크는 마지막 제출의 커밋으로 읽습니다: 워커의 worktree는 다음 태스크로 넘어갔을 수 있습니다")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
        }
    }
}

extension EnvironmentValues {
    /// Opens a document path the task board names in the window's read-only editor; nil where there is none.
    @Entry var openInIde: ((String) -> Void)?
}
