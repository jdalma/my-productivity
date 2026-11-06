import os
import SwiftUI
import TowerCore

/// Sidebar of running sessions (teams, then Claude Code and Codex sessions) and history; detail of the selected row.
/// Grouping, wording and search live in Sidebar.swift.
struct BoardView: View {
    let tower: Tower
    @State private var query = ""
    @State private var filter = AgentFilter.all
    @State private var historyLimit = historyPageSize
    @State private var selection: RowID?
    /// The detail's diff state; here so Esc and ⌘[ ⌘] reach the file view.
    @State private var changes = ChangesState()
    @State private var clickMonitor: Any?
    @FocusState private var searchFocused: Bool
    @AppStorage(FontScale.storageKey) private var storedScale = FontScale.standard.value
    @AppStorage(AppearanceChoice.storageKey) private var storedAppearance = AppearanceChoice.system.rawValue
    @AppStorage(DiffLayout.storageKey) private var diffLayout = DiffLayout.unified.rawValue
    @AppStorage(CollapsedTeams.storageKey) private var storedCollapsed = ""
    @AppStorage(SidebarSplit.storageKey) private var splitRatio = SidebarSplit.standard

    private let home = NSHomeDirectory()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = tower.myTeamError {
                MyTeamErrorLine(error: error).scaledFont(.callout).padding([.horizontal, .top])
            }
            if let board = tower.board {
                content(board, sidebarModel(board: board, history: tower.history, query: query, filter: filter,
                                             historyLimit: historyLimit, home: home))
            } else {
                ProgressView("수집 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .scaledFont(.body)
        .frame(minWidth: 760, minHeight: 440)
        .onChange(of: tower.boardSelectRequest, initial: true) { _, request in
            guard let request else { return }
            query = ""  // a search could hide the requested row
            reveal(request)
            selection = request
            tower.boardSelectRequest = nil
        }
        .onChange(of: query) { historyLimit = historyPageSize }
        .onChange(of: filter) { historyLimit = historyPageSize }
        .toolbar {
            ToolbarItem {
                TextField("검색", text: $query, prompt: Text("세션, 팀, 워크스페이스, 제목 (⌘K)"))
                    .textFieldStyle(.roundedBorder)
                    .scaledFont(.body)
                    .frame(width: 280 * scale.value)
                    .focused($searchFocused)
            }
            ToolbarItem {
                Menu("보기") {
                    Button("글자 크게") { storedScale = scale.bigger().value }.keyboardShortcut("+")
                    Button("글자 작게") { storedScale = scale.smaller().value }.keyboardShortcut("-")
                    Button("기본 크기") { storedScale = FontScale.standard.value }.keyboardShortcut("0")
                    Divider()
                    Picker("화면", selection: $storedAppearance) {
                        ForEach(AppearanceChoice.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Picker("diff", selection: $diffLayout) {
                        ForEach(DiffLayout.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("전체 화면") { FullScreenCapable.toggle() }.keyboardShortcut("f", modifiers: [.control, .command])
                }
            }
        }
        .background {
            Group {
                Button("검색") { searchFocused = true }.keyboardShortcut("k")
                Button("내 차례 목록") {
                    // an open candidate list first, then the file view: Esc returns to the diff
                    if changes.candidates != nil { changes.candidates = nil }
                    else if selection != nil, changes.history.current != nil { changes.history.toDiff() } else { selection = nil }
                }
                .keyboardShortcut(.escape, modifiers: [])
                Button("뒤로") { if selection != nil { changes.history.back() } }.keyboardShortcut("[")
                Button("앞으로") { if selection != nil { changes.history.forward() } }.keyboardShortcut("]")
                Button("글자 크게") { storedScale = scale.bigger().value }.keyboardShortcut("+")
                Button("글자 크게") { storedScale = scale.bigger().value }.keyboardShortcut("=")
                Button("글자 작게") { storedScale = scale.smaller().value }.keyboardShortcut("-")
                Button("기본 크기") { storedScale = FontScale.standard.value }.keyboardShortcut("0")
                // no menu bar in a menu bar app, so the main menu's ⌃⌘F is out of reach
                Button("전체 화면") { FullScreenCapable.toggle() }.keyboardShortcut("f", modifiers: [.control, .command])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .environment(\.boardFontScale, scale.value)
        .background(FullScreenCapable())
        .onAppear { clickMonitor = CommandClick.install() }
        .onDisappear {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }
    }

    private var scale: FontScale { FontScale(stored: storedScale) }

    private func content(_ board: Board, _ model: SidebarModel) -> some View {
        NavigationSplitView {
            GeometryReader { geo in
                let h = SidebarSplit.heights(total: geo.size.height, ratio: splitRatio)
                VStack(spacing: 0) {
                    liveList(model)
                        .safeAreaInset(edge: .top, spacing: 0) { sidebarHeader(model) }
                        .frame(height: h.top)
                    SidebarDivider(top: h.top, total: geo.size.height, ratio: $splitRatio)
                    historyList(model).frame(height: h.bottom)
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 520)
        } detail: {
            DetailView(board: board, model: model, history: tower.history, selection: selection, home: home, changes: changes,
                       select: { id in
                           query = ""  // a search could hide the row
                           reveal(id)
                           selection = id
                       },
                       deselect: { selection = nil },
                       focus: { tower.focus($0.session.handle) })
        }
    }

    private func paneSelection(_ pane: SidebarPane) -> Binding<RowID?> {
        Binding { pane.shown(selection) } set: { selection = pane.select($0, current: selection) }
    }

    private func liveList(_ model: SidebarModel) -> some View {
        List(selection: paneSelection(.live)) {
            if model.teams.isEmpty && model.agents.isEmpty {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "실행 중인 세션 없음" : "검색과 맞는 실행 중 세션 없음").foregroundStyle(.secondary)
            }
            if model.liveAreas.contains(.team) {
                // the area's head only: no rows, so nothing in it can be selected or double-clicked
                Section {} header: {
                    GroupHeader(tag: .team, count: nil, tooltip: "my-team 팀 \(model.teams.count)개")
                }
                ForEach(model.teams, id: \.name) { team in
                    Section(isExpanded: teamExpanded(team.name)) {
                        ForEach(team.rows, id: \.id) { LiveRowView(row: $0).tag($0.id) }
                    } header: {
                        TeamHeader(team: team)
                            .contentShape(.rect)
                            .onTapGesture { toggleTeam(team.name) }
                    }
                }
            }
            ForEach(model.agents, id: \.agent) { g in
                Section {
                    ForEach(g.rows, id: \.id) { LiveRowView(row: $0).tag($0.id) }
                } header: {
                    GroupHeader(tag: .agent(g.agent), count: waitingText(g.waiting), tooltip: g.summary)
                }
            }
        }
        .contextMenu(forSelectionType: RowID.self) { rowMenu($0, model) } primaryAction: { rowAction($0, model) }
    }

    private func historyList(_ model: SidebarModel) -> some View {
        List(selection: paneSelection(.history)) {
            Section {
                ForEach(model.history, id: \.transcriptPath) { h in
                    HistoryRowView(h: h, now: Date(), home: home).tag(RowID.history(h.transcriptPath))
                }
                if model.historyRemaining > 0 {
                    Button("더 보기 (남은 \(model.historyRemaining)개)") { historyLimit += historyPageSize }
                        .buttonStyle(.link)
                }
            } header: {
                HStack {
                    Text("기록 · 최근순")
                    Spacer()
                    Picker("에이전트", selection: $filter) {
                        Text("전체").tag(AgentFilter.all)
                        Text("Claude").tag(AgentFilter.claude)
                        Text("Codex").tag(AgentFilter.codex)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }
            }
        }
        .contextMenu(forSelectionType: RowID.self) { rowMenu($0, model) } primaryAction: { rowAction($0, model) }
    }

    @ViewBuilder
    private func rowMenu(_ ids: Set<RowID>, _ model: SidebarModel) -> some View {
        let h = ids.first.flatMap { historyEntry($0, model) }
        Button("resume 명령 복사") {
            if let h {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(resumeCopyText(h), forType: .string)
            }
        }
        .disabled(h == nil)
    }

    private func rowAction(_ ids: Set<RowID>, _ model: SidebarModel) {
        guard let id = ids.first else { return }
        switch id {
        case .live:
            if let row = model.liveRows.first(where: { $0.id == id }) { tower.focus(row.session.handle) }
        case .history:
            if let h = historyEntry(id, model) { tower.open(h) }
        }
    }

    private var collapsed: CollapsedTeams { CollapsedTeams(stored: storedCollapsed) }

    private func teamExpanded(_ team: String) -> Binding<Bool> {
        Binding {
            collapsed.isExpanded(team, query: query)
        } set: { open in
            var c = collapsed
            c.set(team, expanded: open, query: query)
            storedCollapsed = c.stored
        }
    }

    private func toggleTeam(_ team: String) {
        var c = collapsed
        c.toggle(team, query: query)
        storedCollapsed = c.stored
    }

    /// A row picked outside the sidebar opens its folded team, so the selection shows.
    private func reveal(_ id: RowID) {
        guard let board = tower.board else { return }
        var c = collapsed
        c.reveal(id, in: board)
        if c != collapsed { storedCollapsed = c.stored }
    }

    private func sidebarHeader(_ model: SidebarModel) -> some View {
        HStack {
            Text("실행 중").scaledFont(.headline, weight: .semibold)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    /// The history entry a row stands for: itself, or the entry reading a live session's transcript.
    private func historyEntry(_ id: RowID, _ model: SidebarModel) -> HistorySession? {
        switch id {
        case .history(let path): model.history.first { $0.transcriptPath == path } ?? tower.history.first { $0.transcriptPath == path }
        case .live: model.liveRows.first { $0.id == id }?.matched
        }
    }
}

/// The line between the sidebar's two lists. A drag moves it from where it was when the drag began, so the
/// first move does not jump; the resize cursor is an AppKit cursor rect, which AppKit sets and clears itself.
private struct SidebarDivider: View {
    let top: CGFloat
    let total: CGFloat
    @Binding var ratio: Double
    @State private var dragFrom: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: SidebarSplit.line)
            .overlay {
                Color.clear
                    .frame(height: 7)
                    .contentShape(.rect)
                    .background(ResizeUpDownCursor())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let from = dragFrom ?? top
                                dragFrom = from
                                ratio = SidebarSplit.ratio(top: from + drag.translation.height, total: total)
                            }
                            .onEnded { _ in dragFrom = nil }
                    )
                    .help("끌어서 실행 중과 기록의 높이 조절")
            }
            .zIndex(1)  // the grab strip reaches 3 points into each list
    }
}

/// Shows the up-down resize cursor over its bounds and lets clicks through to the SwiftUI view above it.
struct ResizeUpDownCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Area() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Area: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeUpDown) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// An area's head, the sidebar's largest text: its label `.headline`, waiting count `.callout`.
/// Sizes, largest first: group header > live row title (`.body`) > history title, folder (`.callout`) > secondary lines
/// (`.caption1`); paths are tooltips. The group summary is the tooltip.
private struct GroupHeader: View {
    /// The area's label: my-team, claude or codex.
    let tag: LineKind
    let count: String?
    let tooltip: String

    var body: some View {
        HStack(spacing: 6) {
            KindTag(kind: tag, style: .headline)
            Spacer(minLength: 8)
            if let count { Text(count).scaledFont(.callout).foregroundStyle(.secondary) }
        }
        .textCase(nil)
        .help(tooltip)
    }
}

/// A team under the my-team head, drawn as a folder line rather than a worker: a group icon, the name, its counts,
/// on a band of GitHub's header color, where the text and muted colors read 4.5:1 or more (DiffContrastTests).
private struct TeamHeader: View {
    let team: TeamGroup

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.3").scaledFont(.callout).foregroundStyle(DiffColors.mutedText)
            Text(team.name).scaledFont(.headline, weight: .semibold).foregroundStyle(DiffColors.text).lineLimit(1)
            Spacer(minLength: 8)
            Text(teamHeaderDetail(team)).scaledFont(.callout).foregroundStyle(DiffColors.mutedText).lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(DiffColors.header, in: .rect(cornerRadius: 5))
        // the band alone is close to the sidebar (R45); the outline makes the folder line show
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DiffColors.border, lineWidth: 1))
        .padding(.leading, 6)
        .textCase(nil)
        .help(team.summary)
    }
}

private struct LiveRowView: View {
    let row: LiveRow

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            StatusIconView(badge: row.badge, style: .body)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).scaledFont(.body).foregroundStyle(.primary).lineLimit(1).layoutPriority(1)
                    if let folder = row.shownFolder {
                        Text(folder).scaledFont(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(row.badge.elapsed).scaledFont(.caption1).foregroundStyle(.secondary).fixedSize()
                }
                if !row.line.isEmpty {
                    Text(row.line).scaledFont(.caption1).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .help(badgeLabel(row.badge) + "\n" + row.path)
    }
}

private struct HistoryRowView: View {
    let h: HistorySession
    let now: Date
    let home: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(historyTitle(h)).scaledFont(.callout).foregroundStyle(.primary).lineLimit(1)
                Text(historySubtitle(h)).scaledFont(.caption1).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(relativeTime(h.updatedAt, now: now)).scaledFont(.caption1).foregroundStyle(.secondary)
        }
        .help(historyTooltip(h, home: home))
    }
}

private struct DetailView: View {
    let board: Board
    let model: SidebarModel
    /// Every history entry: a selected row paged out of `model.history` keeps its detail.
    let history: [HistorySession]
    let selection: RowID?
    let home: String
    let changes: ChangesState
    let select: (RowID) -> Void
    let deselect: () -> Void
    /// The sidebar's double click on a live row: `Tower.focus`.
    let focus: (LiveRow) -> Void
    @AppStorage(diffTreeVisibleKey) private var treeVisible = true
    @AppStorage(diffTreeWidthKey) private var treeWidth = 240.0
    /// The width while the divider is dragged; stored once the drag ends.
    @State private var draggedWidth: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if selection != nil {
                Button("← 내 차례 목록 (Esc)", action: deselect)
                    .buttonStyle(.link)
                    .scaledFont(.caption1)
                    .padding([.horizontal, .top], 10)
            }
            Group {
                switch selection {
                case .live:
                    if let row = model.liveRows.first(where: { $0.id == selection }) { live(row) } else { empty }
                case .history(let path):
                    if let h = (model.history + history).first(where: { $0.transcriptPath == path }) { past(h) } else { empty }
                case nil:
                    QueueView(model: model, select: select, focus: focus)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            Text("더블 클릭: 실행 중이면 pane으로 이동 · 종료된 세션이면 Ghostty에서 resume · 우클릭: resume 명령 복사")
                .scaledFont(.caption1).foregroundStyle(.secondary)
                .padding(10)
        }
    }

    private var empty: some View {
        Text("세션을 선택하세요").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func live(_ row: LiveRow) -> some View {
        let s = row.session
        let team = row.teamName.flatMap { n in board.teams.first { $0.name == n } }
        return detailBody(
            title: row.title,
            badges: {
                if let team, let role = row.worker?.role { Pill(text: "\(team.name) · \(role)") }
                else if let team { Pill(text: team.name) }
                HStack(spacing: 4) {
                    StatusIconView(badge: row.badge, style: .callout)
                    Text(badgeLabel(row.badge)).scaledFont(.caption1).foregroundStyle(.secondary)
                }
            },
            facts: [
                ("에이전트", agentName(s.agent)),
                ("워크스페이스", abbreviate(s.cwd, home: home)),
                ("branch", row.matched?.branch ?? ""),
                ("tmux", s.tmux.map { t in
                    "\(t.session) · pane \(t.pane)" + (team.map { $0.attached ? " · attached" : " · detached" } ?? "")
                } ?? ""),
                ("메일", row.worker.map { mailSummary([$0], at: board.at) } ?? ""),
            ],
            workspace: s.cwd,
            conversation: [("나", s.lastUser), ("에이전트", s.lastAssistant)])
    }

    private func past(_ h: HistorySession) -> some View {
        detailBody(
            title: historyTitle(h),
            badges: { Text(h.live ? "실행 중" : "종료됨").scaledFont(.caption1).foregroundStyle(.secondary) },
            facts: [
                ("에이전트", agentName(h.agent)),
                ("워크스페이스", abbreviate(h.workspace, home: home)),
                ("branch", h.branch ?? ""),
                ("최근 활동", fullTime(h.updatedAt)),
            ],
            workspace: h.workspace,
            conversation: [("최근 프롬프트", h.lastPrompt ?? "")])
    }

    private func detailBody(title: String, @ViewBuilder badges: () -> some View,
                            facts: [(String, String)], workspace: String, conversation: [(String, String)]) -> some View {
        let badges = badges()
        return HStack(spacing: 0) {
            ScrollViewReader { proxy in
                scrollingBody(title: title, badges: badges, facts: facts, workspace: workspace, conversation: conversation)
                    .accessibilityHidden(changes.history.current != nil)
                    .overlay {
                        // over the diff, which keeps its scroll position underneath
                        if let location = changes.history.current, let top = changes.diff(for: workspace)?.toplevel {
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
                    .environment(changes)
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
            if treeVisible, let diff = changes.diff(for: workspace) {
                treeDivider
                ChangeTreeColumn(diff: diff, state: changes).frame(width: draggedWidth ?? clampTreeWidth(treeWidth))
            }
        }
    }

    /// The line left of the tree; dragging it resizes the tree within `treeWidthBounds`.
    private var treeDivider: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in draggedWidth = clampTreeWidth(clampTreeWidth(treeWidth) - v.translation.width) }
                            .onEnded { _ in
                                if let draggedWidth { treeWidth = draggedWidth }
                                draggedWidth = nil
                            }
                    )
            }
    }

    private func scrollingBody(title: String, badges: some View,
                               facts: [(String, String)], workspace: String, conversation: [(String, String)]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(title).scaledFont(.title2, weight: .bold).lineLimit(2)
                    badges
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(facts.filter { !$0.1.isEmpty }, id: \.0) { k, v in
                        GridRow {
                            Text(k).foregroundStyle(.secondary)
                            Text(v).textSelection(.enabled)
                                .scaledFont(.body, design: monoFacts.contains(k) ? .monospaced : .default)
                        }
                    }
                }
                ChangesView(workspace: workspace, at: board.at, state: changes)
                let talk = conversation.filter { !$0.1.isEmpty }
                if !talk.isEmpty {
                    Divider()
                    Text("최근 대화").scaledFont(.headline, weight: .semibold)
                    ForEach(talk, id: \.0) { who, text in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(who).scaledFont(.caption1).foregroundStyle(.secondary)
                            Text(text).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            // GitHub's page colors: `.primary`/`.secondary` inside read as fgColor-default/-muted
            .foregroundStyle(DiffColors.text, DiffColors.mutedText)
        }
        .background(DiffColors.canvas)
    }
}

private struct Pill: View {
    let text: String

    var body: some View {
        Text(text).scaledFont(.caption1)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(DiffColors.header, in: .capsule)
            .overlay(Capsule().strokeBorder(DiffColors.border))
    }
}

/// The main area with nothing selected: who is waiting on me, longest first.
private struct QueueView: View {
    let model: SidebarModel
    let select: (RowID) -> Void
    let focus: (LiveRow) -> Void

    var body: some View {
        if model.queue.isEmpty {
            VStack(spacing: 4) {
                Text("내 차례인 세션이 없습니다").foregroundStyle(.secondary)
                if model.working > 0 {
                    Text("작업 중 \(model.working)개").scaledFont(.caption1).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("내 차례 · \(model.queue.count)").scaledFont(.headline, weight: .semibold)
                    ForEach(model.queue, id: \.id) { row in
                        QueueCard(row: row, focus: { focus(row) }).onTapGesture { select(row.id) }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct QueueCard: View {
    let row: LiveRow
    let focus: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusIconView(badge: row.badge, style: .body)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(row.title).scaledFont(.body, weight: .semibold).lineLimit(1)
                    KindTag(kind: row.group.kind, style: .caption2)
                    if let name = row.group.name { Text(name).scaledFont(.caption1).lineLimit(1) }
                    if let folder = row.shownFolder {
                        Text(folder).scaledFont(.caption1).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(row.badge.elapsed).scaledFont(.caption1).foregroundStyle(.secondary).help(badgeLabel(row.badge))
                }
                if !row.message.isEmpty {
                    Text(row.message).scaledFont(.callout).foregroundStyle(.secondary).lineLimit(3).truncationMode(.tail)
                }
                Button("pane으로 이동", action: focus).scaledFont(.caption1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .help(badgeLabel(row.badge) + "\n" + row.path)
    }
}

/// Detail facts that are paths or identifiers.
private let monoFacts: Set = ["워크스페이스", "branch", "tmux"]

/// Lets the board window take its own Space in full screen (green button, ⌃⌘F). Left to AppKit's own
/// choice, the board window of this menu bar app (LSUIElement) did not go full screen.
struct FullScreenCapable: NSViewRepresentable {
    /// The board window, for ⌃⌘F: the key window may be a candidate list's popover.
    static weak var board: NSWindow?

    func makeNSView(context: Context) -> NSView { makeProbe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeProbe() -> NSView { Probe() }

    static func toggle() { board?.toggleFullScreen(nil) }

    private static func allow(_ window: NSWindow?) {
        guard let window else { return }
        board = window
        // at most one of each group may be set; SwiftUI marks the accessory app's board .auxiliary
        var behavior = window.collectionBehavior
        behavior.subtract([.fullScreenNone, .fullScreenAuxiliary, .auxiliary, .canJoinAllApplications])
        behavior.insert([.fullScreenPrimary, .primary])
        if behavior != window.collectionBehavior { window.collectionBehavior = behavior }
    }

    /// Each write the probe sees, at debug level: kept off the disk unless `log stream --level debug` asks for it.
    private static let log = Logger(subsystem: "local.control-tower", category: "fullscreen")

    private final class Probe: NSView {
        /// SwiftUI writes its own behavior back after the board mounts (T38b log), so each write is undone.
        private var rewrite: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            FullScreenCapable.allow(window)
            rewrite = window?.observe(\.collectionBehavior) { [weak window] _, _ in
                MainActor.assumeIsolated {
                    FullScreenCapable.log.debug("behavior written: \(window?.collectionBehavior.rawValue ?? 0, privacy: .public)")
                    FullScreenCapable.allow(window)
                }
            }
        }
    }
}
