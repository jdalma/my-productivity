import AppKit
import SwiftUI
import TowerCore

/// What a diff window shows: one workspace's changes. Workers sharing a folder share its window.
struct DiffTarget: Codable, Hashable {
    var workspace: String
}

/// A workspace's changes in a window of their own (T72): the folder tree beside the diff, the file view over it.
/// Nothing is read until the window opens; then the diff is read again on each board refresh.
struct DiffWindow: View {
    let target: DiffTarget
    let tower: Tower
    @State private var changes = ChangesState()
    @State private var clickMonitor: Any?
    @AppStorage(FontScale.storageKey) private var storedScale = FontScale.standard.value

    var body: some View {
        NavigationSplitView(columnVisibility: Binding { changes.treeVisible ? .all : .detailOnly }
                                                  set: { changes.treeVisible = $0 != .detailOnly }) {
            DiffTreeSidebar(workspace: target.workspace, state: changes)
                .navigationSplitViewColumnWidth(min: 160, ideal: 260, max: 480)
        } detail: {
            detail
        }
        .navigationTitle("변경 · " + abbreviate(target.workspace, home: homeDirectory()))
        .scaledFont(.body)
        .frame(minWidth: 560, minHeight: 360)
        .environment(changes)
        .environment(\.boardFontScale, FontScale(stored: storedScale).value)
        .background { FontScaleAlias(stored: $storedScale) }
        .background(NotRestorable())
        .background(WindowTab(kind: .diff, title: diffTabTitle(workspace: target.workspace, board: tower.board)))
        .background(TestWindowPlacement())
        .focusedSceneValue(\.windowNavigation, WindowNavigation(
            escape: ("diff로", { if changes.candidates != nil { changes.candidates = nil } else { changes.history.toDiff() } }),
            back: WindowNavigation.step(changes.history.canGoBack) { changes.history.back() },
            forward: WindowNavigation.step(changes.history.canGoForward) { changes.history.forward() }))
        .onAppear {
            clickMonitor = CommandClick.install()
            tower.windows.diffs.insert(target)
        }
        .onDisappear {
            tower.windows.diffs.remove(target)
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }
    }

    private var detail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let scope = changes.diff(for: target.workspace).map({ diffScopeLabel(scope: $0.scope, sharers: []) }),
                       !scope.isEmpty {
                        Text(scope).scaledFont(.caption1).foregroundStyle(.secondary)
                    }
                    ChangesView(workspace: target.workspace, at: tower.board?.at ?? "", state: changes)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                // GitHub's page colors: `.primary`/`.secondary` inside read as fgColor-default/-muted
                .foregroundStyle(DiffColors.text, DiffColors.mutedText)
            }
            .background(DiffColors.canvas)
            .accessibilityHidden(changes.history.current != nil)
            .overlay {
                // over the diff, which keeps its scroll position underneath
                if let location = changes.history.current, let top = changes.diff(for: target.workspace)?.toplevel {
                    FileCodeView(toplevel: top, location: location, state: changes)
                }
            }
            .overlay(alignment: .top) {
                if let notice = changes.notice {
                    Text(notice).scaledFont(.callout)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(DiffColors.header, in: .capsule)
                        .overlay(Capsule().strokeBorder(DiffColors.border))
                        .padding(.top, 48)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: changes.scrollTarget) { _, target in
                guard let target else { return }
                changes.scrollTarget = nil
                // reveal may have just inserted the header (a folded section); scroll once it is laid out
                Task { @MainActor in
                    await Task.yield()
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                }
            }
        }
    }
}

/// ⌘=, the unshifted key of the 보기 menu's ⌘+: a menu item holds one shortcut.
struct FontScaleAlias: View {
    @Binding var stored: Double

    var body: some View {
        Button("글자 크게") { stored = FontScale(stored: stored).bigger().value }
            .keyboardShortcut("=")
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

/// Keeps the diff window out of state restoration: a relaunch, a login launch above all, opens no diff window
/// by itself, so it neither shows the Dock icon nor reads git (T72 R1 S1).
struct NotRestorable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() { window?.isRestorable = false }
    }
}

/// The diff window's folder tree: the changed files of each section, or every file of the workspace.
/// Picking a changed file, by click or arrow key, shows it in the diff, an unchanged one in the file view; a double
/// click or Return shows the picked file again.
struct DiffTreeSidebar: View {
    let workspace: String
    @Bindable var state: ChangesState
    /// What a picked line does; the diff window's `state.pick` when nil.
    var pick: ((TreeLine) -> Void)?
    /// The context menu of a line, or of the list where no line is (nil); no menu when nil, as in the diff window.
    var menu: ((TreeLine?) -> AnyView)?

    private struct FullTreeKey: Equatable {
        var mode: TreeMode
        var fetched: Loaded?
    }

    var body: some View {
        FolderTreeList(tree: state.tree, pick: pick ?? state.pick, menu: menu) {
            if let diff = state.diff(for: workspace) {
                switch state.treeMode {
                case .changed:
                    if let committed = diff.committed { section("커밋됨", committed, .committed) }
                    section("미커밋", diff.uncommitted, .uncommitted)
                case .all:
                    if let full = state.fullTree {
                        ForEach(full.nodes, id: \.path) { TreeNodeRow(node: $0, part: nil, openByDefault: full.changed.contains, tree: state.tree) }
                    } else if state.fullTreeFailed {
                        Text("파일 목록을 읽지 못함").scaledFont(.caption1).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("트리", selection: $state.treeMode) {
                Text("변경된 파일").tag(TreeMode.changed)
                Text("전체 폴더").tag(TreeMode.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("변경된 파일만, 또는 워크스페이스의 모든 파일(무시된 파일 제외)")
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
        }
        .task(id: FullTreeKey(mode: state.treeMode, fetched: state.fetched)) { await state.loadFullTree() }
    }

    private func section(_ title: String, _ s: DiffSection, _ part: DiffPart) -> some View {
        Section {
            let nodes = changeTree(s)
            if nodes.isEmpty { Text("변경 없음").scaledFont(.caption1).foregroundStyle(.secondary) }
            ForEach(nodes, id: \.path) { TreeNodeRow(node: $0, part: part, openByDefault: { _ in true }, tree: state.tree) }
        } header: {
            Text(title).scaledFont(.subheadline, weight: .semibold)
        }
    }
}

/// A folder tree as a sidebar list of `TreeNodeRow`s, in sections or not. Picking a line, by click or arrow key,
/// calls `pick`; a double click or Return calls it again.
struct FolderTreeList<Rows: View>: View {
    @Bindable var tree: FolderTreeState
    let pick: (TreeLine) -> Void
    var menu: ((TreeLine?) -> AnyView)?
    @ViewBuilder let rows: Rows
    @FocusState private var focused: Bool

    var body: some View {
        List(selection: $tree.picked) { rows }
            .listStyle(.sidebar)
            // ↑↓ walk the tree as soon as it shows
            .focused($focused)
            .onAppear { focused = true }
            .onChange(of: tree.picked) { _, line in if let line { pick(line) } }
            .contextMenu(forSelectionType: TreeLine.self) { lines in menu?(lines.first) } primaryAction: { lines in lines.first.map(pick) }
    }
}

/// A tree line and, while it is an open folder, the lines under it; a closed folder builds nothing below it.
struct TreeNodeRow: View {
    let node: ChangeTreeNode
    let part: DiffPart?
    let openByDefault: (String) -> Bool
    let tree: FolderTreeState

    var body: some View {
        let line = TreeLine(node, part: part)
        if let children = node.children {
            let byDefault = openByDefault(node.path)
            let open = Binding { tree.isOpen(line, byDefault: byDefault) } set: { tree.setOpen(line, $0, byDefault: byDefault) }
            DisclosureGroup(isExpanded: open) {
                if open.wrappedValue {
                    ForEach(children, id: \.path) { TreeNodeRow(node: $0, part: part, openByDefault: openByDefault, tree: tree) }
                }
            } label: {
                Label(node.name, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                    .scaledFont(.caption1).foregroundStyle(.secondary)
                    .help(node.path)
            }
            .tag(line)
        } else if case .file(let change) = node.kind {
            HStack(spacing: 4) {
                Text(node.name).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(change == .unchanged ? .secondary : .primary)
                Spacer(minLength: 4)
                marker(change).foregroundStyle(.secondary)
            }
            .scaledFont(.caption1, design: .monospaced)
            .help(node.path)
            .tag(line)
        }
    }

    @ViewBuilder
    private func marker(_ change: FileChange) -> some View {
        switch change {
        case .lines(let added, let removed):
            ForEach(changeCounts(added: added, removed: removed), id: \.self) { Text($0).foregroundStyle(countColor($0)) }
        case .binary: Text("bin")
        case .untracked: Text("N")
        case .unchanged: EmptyView()
        }
    }
}
