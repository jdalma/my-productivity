import AppKit
import SwiftUI
import TowerCore

// The board's IDE area (G4 I5, plan K4): the editor with the worktree's folder tree on its right, the session's
// terminal under both, the whole width. The editor's files are the worktree's only (D#6 a), read-only until
// unlocked (D#5 b), and the board window's own (D#8 b) while it shows them.

/// One board window's IDE area: the worktree it shows, that worktree's editor (IdeBuffers.swift) and its folder tree.
/// Kept across the detail's redraws and rows. A row of another worktree shows that worktree's editor; the one left
/// waits in `IdeParking` while it holds edits that are not saved, and is dropped otherwise.
@MainActor @Observable
final class IdeState {
    private(set) var session: IdeSession?
    /// The tree's diff and file list, read as the diff window reads them.
    let changes = ChangesState()

    var editor: EditorController? { session?.editor }
    var buffers: EditorBuffers { session?.buffers ?? EditorBuffers() }
    /// The real path of the file the editor shows.
    var shown: String? { buffers.shown }
    var readOnly: Bool { shown.flatMap { buffers.files[$0]?.readOnly } ?? true }
    var status: String { session?.status ?? "" }

    /// Shows `root`'s files: its waiting editor, edits and all, or a new one.
    func show(root: String) {
        guard root != session?.root else { return }
        if let session { _ = IdeParking.park(session) }
        changes.select(workspace: root)
        session = IdeParking.session(for: root)
    }

    /// The area left the window (a row with no terminal, the window closed): an editor with edits that are not saved
    /// waits for the next area of its worktree; one without stays here, as before.
    func areaGone() {
        if let session, IdeParking.park(session) { self.session = nil }
    }

    /// A tree line picked: a file opens in the editor, a folder does nothing.
    func pick(_ line: TreeLine) {
        guard !line.isFolder, let session, let top = changes.diff(for: session.root)?.toplevel else { return }
        Task { await session.open(top + "/" + line.path) }
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
        .onDisappear { state.areaGone() }
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
                IdeTabs(buffers: state.buffers) { path in Task { await state.session?.open(path) } }
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
                Task { await state.session?.toggleLock() }
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
