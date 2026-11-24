import AppKit
import SwiftUI
import TowerCore

// The IDE area (G4 I5, plan K4; I6, K5): the editor with the code's folder tree on its right, in the board window
// the session's terminal under both, the whole width. The editor's files are the worktree's only (D#6 a), read-only
// until unlocked (D#5 b), and each window's own (D#8 b) while it shows them. The task board window's are read-only,
// never unlocked.

/// One window's IDE area: the code it shows, that code's editor (IdeBuffers.swift) and its folder tree. Kept across
/// the detail's redraws and rows. Another source shows another editor; the board window's editor waits in
/// `IdeParking` while it holds edits that are not saved, and is dropped otherwise.
@MainActor @Observable
final class IdeState {
    /// Whether a file can be unlocked for editing: the board window's; the task board window's never (D#8 b).
    let lockable: Bool
    private(set) var source: TaskCodeSource?
    @ObservationIgnored private var started = false
    private(set) var session: IdeSession?
    /// The tree's diff and file list, read as the diff window reads them.
    let changes = ChangesState()
    /// A commit source's tree: its mode, and its lines; nil lines when git could not read them.
    var commitMode = TreeMode.changed
    private(set) var commitTree: (mode: TreeMode, nodes: [ChangeTreeNode]?)?
    /// Narrow, the code is a tab beside the detail: shown, or the detail is.
    var codeShown = false

    init(lockable: Bool = true) { self.lockable = lockable }

    var editor: EditorController? { session?.editor }
    var buffers: EditorBuffers { session?.buffers ?? EditorBuffers() }
    /// The real path of the file the editor shows: a worktree's file, or one Swift read itself (a commit's, a document).
    var shown: String? { session?.outside ?? buffers.shown }
    var readOnly: Bool { session?.outside != nil ? true : shown.flatMap { buffers.files[$0]?.readOnly } ?? true }
    var status: String { session?.status ?? "" }

    /// The worktree the editor reads and may save in; nil for a commit or no source.
    var root: String? { if case .worktree(let r) = source { r } else { nil } }

    func show(root: String) { show(.worktree(root)) }

    /// Shows `source`'s files: a worktree's waiting editor, edits and all (the board window), or a new one. With no
    /// source the editor still shows documents (`openDocument`).
    func show(_ source: TaskCodeSource?) {
        guard !started || source != self.source else { return }
        started = true
        if lockable, let session { _ = IdeParking.park(session) }
        self.source = source
        commitTree = nil
        if let root { changes.select(workspace: root) }
        // A window that never unlocks takes no waiting editor: its files may be unlocked and edited (D#8 b).
        session = if lockable, let root { IdeParking.session(for: root) } else { IdeSession(root: root) }
    }

    /// The area left the window (a row with no terminal, the window closed): an editor with edits that are not saved
    /// waits for the next area of its worktree; one without stays here, as before.
    func areaGone() {
        guard lockable, let session, IdeParking.park(session) else { return }
        self.session = nil
        started = false
    }

    /// A tree line picked: a file opens in the editor, a folder does nothing. A commit's file is read from git.
    func pick(_ line: TreeLine) {
        guard !line.isFolder, let session else { return }
        switch source {
        case .worktree(let root)?:
            guard let top = changes.diff(for: root)?.toplevel else { return }
            Task { await session.open(top + "/" + line.path) }
        case .commit(let repo, _, let commit)?:
            let path = line.path
            Task { await session.show(await Task.detached { commitOpen(dir: repo, rev: commit, path: path) }.value) }
        case nil: break
        }
    }

    /// A ticket or report the task board names, read-only in this editor (D#7 b); narrow, the code tab comes forward.
    func openDocument(_ path: String) {
        codeShown = true
        Task { await session?.show(await Task.detached { readOnlyOpen(path) }.value) }
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
        .onDisappear { state.areaGone() }
        .sheet(isPresented: Binding { state.session?.comparing != nil } set: { if !$0 { state.session?.comparing = nil } }) {
            if let file = state.session?.comparing { IdeCompare(file: file) { state.session?.comparing = nil } }
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
            // buffers (I7): the open files once there are two, and the shown file's banner
            if state.buffers.tabs.count > 1, state.session?.outside == nil {
                IdeTabs(buffers: state.buffers) { path in Task { await state.session?.open(path) } }
                Divider()
            }
            if let banner = state.buffers.banner {
                IdeBanner(banner: banner) { choice in Task { await state.session?.choose(choice) } }
                Divider()
            }
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
                Text(abbreviate(shown, home: homeDirectory()) + (state.buffers.files[shown]?.dirty == true ? " •" : ""))
                    .scaledFont(.caption1, design: .monospaced).lineLimit(1).truncationMode(.head).help(shown)
            } else {
                Text("편집기").scaledFont(.headline, weight: .semibold)
            }
            Spacer(minLength: 8)
            Text(state.status).scaledFont(.caption1).foregroundStyle(.secondary).lineLimit(1)
            if state.lockable {
                Button(state.readOnly ? "잠금 해제" : "잠그기", systemImage: state.readOnly ? "lock" : "lock.open") {
                    Task { await state.session?.toggleLock() }
                }
                .disabled(state.buffers.shown == nil || state.session?.outside != nil)
                .help("작업 트리 파일은 읽기 전용으로 열립니다. 풀면 이 파일을 고쳐 저장할 수 있습니다")
                Button("저장", systemImage: "square.and.arrow.down") { Task { await state.session?.save() } }
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
