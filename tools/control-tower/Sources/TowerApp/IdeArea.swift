import AppKit
import SwiftUI
import TowerCore

// The board's IDE area (G4 I5, plan K4): the editor with the worktree's folder tree on its right, the session's
// terminal under both, the whole width. The editor's files are the worktree's only (D#6 a), read-only until
// unlocked (D#5 b), and the board window's own (D#8 b).

/// One board window's editor, its folder tree and the watch on its worktree. Kept across the detail's redraws and
/// rows; made again when a row of another worktree shows.
// ponytail: one editor per window, its buffers lost on a switch of worktree; keep one per worktree if switching back and forth costs too much
@MainActor @Observable
final class IdeState {
    private(set) var root: String?
    private(set) var editor: EditorController?
    @ObservationIgnored private var watch: FileWatch?
    /// The tree's diff and file list, read as the diff window reads them.
    let changes = ChangesState()
    /// The real path of the file the editor shows.
    private(set) var shown: String?
    private(set) var readOnly = true
    private(set) var dirty: Set<String> = []
    private(set) var status = ""

    /// Shows `root`'s files; another root drops the editor's files and watch.
    func show(root: String) {
        guard root != self.root else { return }
        self.root = root
        shown = nil
        readOnly = true
        dirty = []
        status = ""
        changes.select(workspace: root)
        watch = nil
        editor = editorPageFolder.map { EditorController(roots: [root], page: $0) }
        guard let editor else { return }
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

    /// A tree line picked: a file opens in the editor, a folder does nothing.
    func pick(_ line: TreeLine) {
        guard !line.isFolder, let root, let top = changes.diff(for: root)?.toplevel else { return }
        Task { await open(top + "/" + line.path) }
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
        guard let editor, let shown else { return }
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

/// The editor over the terminal; `at` is the board's refresh, which reads the tree's diff again.
struct IdeArea: View {
    let root: String
    let terminal: TmuxRef
    let at: String
    @Bindable var state: IdeState
    @AppStorage(IdeLayout.storageKey) private var stored = ""

    var body: some View {
        let layout = IdeLayout(stored: stored)
        GeometryReader { geo in
            let h = IdeLayout.heights(total: geo.size.height, ratio: layout.ratio(for: root))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    editorColumn.frame(maxWidth: .infinity)
                    if layout.treeShown {
                        let width = IdeLayout.treeWidth(layout.treeWidth, total: geo.size.width)
                        DragLine(axis: .vertical, at: width, total: geo.size.width) { change($0) { $0.treeWidth = $1 } }
                        DiffTreeSidebar(workspace: root, state: state.changes, pick: state.pick).frame(width: width)
                    }
                }
                .frame(height: h.editor)
                DragLine(axis: .horizontal, at: h.editor, total: geo.size.height) { editor in
                    change(editor) { $0.setRatio(IdeLayout.ratio(editor: $1, total: geo.size.height), for: root) }
                }
                // a new terminal, and a new tmux client, for each pane
                PaneTerminal(ref: terminal).id("\(terminal.session) \(terminal.pane)")
                    .padding(.top, 8)
                    .frame(height: h.terminal)
            }
        }
        .task(id: "\(root) \(at)") {
            state.show(root: root)
            await state.changes.load(workspace: root)
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
                Text(abbreviate(shown, home: homeDirectory()) + (state.dirty.contains(shown) ? " •" : ""))
                    .scaledFont(.caption1, design: .monospaced).lineLimit(1).truncationMode(.head).help(shown)
            } else {
                Text("편집기").scaledFont(.headline, weight: .semibold)
            }
            Spacer(minLength: 8)
            Text(state.status).scaledFont(.caption1).foregroundStyle(.secondary).lineLimit(1)
            Button(state.readOnly ? "잠금 해제" : "잠그기", systemImage: state.readOnly ? "lock" : "lock.open") {
                Task { await state.toggleLock() }
            }
            .disabled(state.shown == nil)
            .help("작업 트리 파일은 읽기 전용으로 열립니다. 풀면 이 파일을 고쳐 저장할 수 있습니다")
            Button("저장", systemImage: "square.and.arrow.down") { Task { await state.save() } }
                .disabled(state.shown == nil || state.readOnly)
                .help("저장 (편집기 안에서 ⌘S)")
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
