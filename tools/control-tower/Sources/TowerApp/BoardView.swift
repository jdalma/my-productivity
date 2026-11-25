import os
import SwiftUI
import TowerCore

/// Sidebar of running sessions (teams, then Claude Code and Codex sessions) and history; detail of the selected row.
/// Grouping, wording and search live in Sidebar.swift.
struct BoardView: View {
    let tower: Tower
    @State private var query = ""
    @State private var filter = HistoryFilter.claude
    @State private var historyLimit = historyPageSize
    /// Where the board is and has been: the sidebar's selection and the picked task are its current screen.
    @State private var nav = ScreenHistory()
    /// Bumped to put the keyboard in the search field.
    @State private var searchFocus = 0
    /// The window's editor and folder tree, under a live session's terminal (D#8 b: this window's own).
    @State private var ide = IdeState()
    @Environment(\.openWindow) private var openWindow
    @AppStorage(FontScale.storageKey) private var storedScale = FontScale.standard.value
    @AppStorage(OpenedTeams.storageKey) private var storedOpened = ""
    @AppStorage(SidebarSplit.storageKey) private var splitRatio = SidebarSplit.standard
    @Environment(\.controlActiveState) private var activeState

    private let home = homeDirectory()

    var body: some View {
        let model = tower.board.map {
            sidebarModel(board: $0, history: tower.history, query: query, filter: filter, historyLimit: historyLimit, home: home,
                         taskBoards: tower.taskBoards.compactMapValues(\.status))
        }
        let title = model.map { screenTitle(nav.current, model: $0, history: tower.history, usage: tower.usage.report) }
        VStack(alignment: .leading, spacing: 0) {
            if let error = tower.myTeamError {
                MyTeamErrorLine(error: error).scaledFont(.callout).padding([.horizontal, .top])
            }
            if let board = tower.board, let model {
                content(board, model)
            } else {
                ProgressView("수집 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .scaledFont(.body)
        .frame(minWidth: 760, minHeight: 440)
        .navigationTitle(title?.title ?? "Control Tower")
        .navigationSubtitle(title?.subtitle ?? "")
        .onChange(of: tower.boardSelectRequest, initial: true) { _, request in
            guard let request else { return }
            go(Screen(request))
            tower.boardSelectRequest = nil
        }
        .onChange(of: tower.ideOpenRequest, initial: true) { _, request in
            guard let request else { return }
            tower.ideOpenRequest = nil
            Task { await ide.take(request) }
        }
        .onChange(of: query) { historyLimit = historyPageSize }
        .onChange(of: filter) { historyLimit = historyPageSize }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("뒤로", systemImage: "chevron.backward") { nav.back() }
                    .disabled(!nav.canGoBack).help("뒤로 (⌘[)")
                Button("앞으로", systemImage: "chevron.forward") { nav.forward() }
                    .disabled(!nav.canGoForward).help("앞으로 (⌘])")
            }
            ToolbarItem {
                SearchField(text: $query, prompt: "검색", focusRequest: searchFocus)
                    .frame(width: 240)
                    .help("세션, 팀, 워크스페이스, 제목 (⌘F, ⌘K)")
            }
        }
        .background {
            FontScaleAlias(stored: $storedScale)
            // ⌘K, the menu's ⌘F under another key
            // not while the editor has the keyboard: ⌘K starts its chords (⌘K ⌘C), and a disabled button lets it pass
            Button("검색") { searchFocus += 1 }
                .keyboardShortcut("k")
                .disabled(EditorKeyFocus.shared.inKeyWindow)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .focusedSceneValue(\.windowNavigation, WindowNavigation(
            // nil where there is nowhere to go, so the menu items are off as the toolbar's are (R3 L1)
            back: WindowNavigation.step(nav.canGoBack) { nav.back() },
            forward: WindowNavigation.step(nav.canGoForward) { nav.forward() },
            search: { searchFocus += 1 },
            quickOpen: ide.canSearch ? { ide.search(.files) } : nil,
            findInFiles: ide.canSearch ? { ide.search(.text) } : nil,
            reload: {
                tower.reloadTaskBoards()
                if nav.current.row == .dashboard { Task { await tower.usage.refresh() } }
            },
            openDiff: model.flatMap { workspace(of: nav.current.row, $0) }.map { w in
                { openWindow(id: "diff", value: DiffTarget(workspace: w)) }
            },
            openTaskBoard: model.flatMap { taskBoardTeam(of: nav.current.row, $0) }.map { team in { openTaskBoard(team) } }))
        .environment(\.boardFontScale, scale.value)
        .background(BoardWindowBehavior())
        .alert(tower.failure?.title ?? "", isPresented: Binding { tower.failure != nil } set: { if !$0 { tower.failure = nil } },
               presenting: tower.failure) { _ in
            Button("확인") {}
        } message: { Text($0.reason) }
        .modifier(ShutdownConfirmation(tower: tower))
        .onChange(of: activeState, initial: true) { tower.windows.boardKey = activeState == .key }
        .onAppear { tower.windows.board = true }
        .onChange(of: model.map { diffTotalFolders($0.teams) { opened.isExpanded($0, query: query) } } ?? [], initial: true) {
            tower.diffTotals.folders = $1
        }
        .onDisappear {
            tower.windows.board = false
            tower.diffTotals.folders = []
            // the window's editor goes, and its language servers with it (K12)
            ide.close()
        }
    }

    private var scale: FontScale { FontScale(stored: storedScale) }

    private var selection: RowID { nav.current.row }

    /// Goes to `screen` from outside the sidebar: a search could hide its row, a folded team hide it.
    private func go(_ screen: Screen) {
        query = ""
        reveal(screen.row)
        nav.go(screen)
    }

    /// The folder a session row's diff is of; nil for the dashboard and task boards.
    private func workspace(of id: RowID, _ model: SidebarModel) -> String? {
        switch id {
        case .live: model.liveRows.first { $0.id == id }?.session.cwd
        case .history(let path): (model.history + tower.history).first { $0.transcriptPath == path }?.workspace
        case .dashboard: nil
        }
    }

    /// The team whose task board the selected worker's is; nil off a team worker or without a board.
    private func taskBoardTeam(of id: RowID, _ model: SidebarModel) -> String? {
        guard let name = model.liveRows.first(where: { $0.id == id })?.teamName,
              model.teams.contains(where: { $0.name == name && $0.hasTaskBoard }) else { return nil }
        return name
    }

    /// Brings the team's task board window forward, opening it on `task` when one is given (T86).
    private func openTaskBoard(_ team: String, task: String? = nil) {
        openWindow(id: "taskBoard", value: tower.taskPicks.open(team, task: task))
    }

    private func content(_ board: Board, _ model: SidebarModel) -> some View {
        NavigationSplitView {
            GeometryReader { geo in
                let h = SidebarSplit.heights(total: geo.size.height, ratio: splitRatio)
                // each list's head sits above it on the sidebar's own material, not as a bar over its rows (T124, MU13 c);
                // the end of each list keeps a margin so its last row does not stop against the line (D11)
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        sidebarHeader(model)
                        liveList(board, model).contentMargins(.bottom, SidebarSplit.endMargin, for: .scrollContent)
                    }
                    .frame(height: h.top)
                    SidebarDivider(top: h.top, total: geo.size.height, ratio: $splitRatio)
                    VStack(spacing: 0) {
                        historyHeader
                        historyList(model).contentMargins(.bottom, SidebarSplit.endMargin, for: .scrollContent)
                    }
                    .frame(height: h.bottom)
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 520)
        } detail: {
            DetailView(board: board, model: model, history: tower.history, selection: selection, home: home,
                       taskBoards: tower.taskBoards, ide: ide, openTask: { openTaskBoard($0.team, task: $0.task) },
                       dashboard: DashboardView(
                           usage: tower.usage,
                           advisor: tower.advisor,
                           teams: board.teams,
                           openProject: { query = $0 },
                           openSession: { path in
                               usageSessionTarget(path, model: model, history: tower.history).map { id in { go(Screen(id)) } }
                           },
                           sessionTitle: { path in tower.history.first { $0.transcriptPath == path }.map(historyTitle) }))
        }
    }

    private func paneSelection(_ pane: SidebarPane) -> Binding<RowID?> {
        // a list letting go of its row (a click on blank space) keeps the screen: the board always shows one
        Binding { pane.shown(selection) } set: { if let id = $0 { nav.go(Screen(id)) } }
    }

    private func liveList(_ board: Board, _ model: SidebarModel) -> some View {
        List(selection: paneSelection(.live)) {
            DashboardRow().tag(RowID.dashboard)
            if model.teams.isEmpty && model.agents.isEmpty {
                Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "실행 중인 세션 없음" : "검색과 맞는 실행 중 세션 없음").foregroundStyle(.secondary)
            }
            if model.liveAreas.contains(.team) || !tower.launches.teams.isEmpty {
                // the area's head only: no rows, so nothing in it can be selected or double-clicked
                Section {} header: {
                    GroupHeader(tag: .team, count: nil, tooltip: "my-team 팀 \(model.teams.count)개")
                }
                // a team asked to start and not running yet holds a line at the top until the board sees it (T206 §2)
                ForEach(tower.launches.teams, id: \.self) { name in
                    Section {} header: { LaunchingTeamLine(team: name) }
                }
                ForEach(model.teams, id: \.name) { team in
                    Section(isExpanded: teamExpanded(team.name)) {
                        ForEach(team.rows, id: \.id) {
                            LiveRowView(row: $0, change: rowChange($0, totals: tower.diffTotals.byFolder, board: board))
                                .padding(.leading, TeamHeader.workerInset(scale.value)).tag($0.id)
                        }
                    } header: {
                        TeamHeader(team: team, expanded: opened.isExpanded(team.name, query: query),
                                   board: TaskBoardButtonState(counts: team.taskCounts, problem: tower.taskBoards[team.name]?.shownFailure.map {
                                       let p = taskBoardProblem($0, bin: myTeamBin); return "\(p.title)\n\(p.detail)" }),
                                   openBoard: { openTaskBoard(team.name) }, toggle: { toggleTeam(team.name) },
                                   shuttingDown: tower.shutdowns.running.contains(team.name),
                                   shutdown: { tower.askShutdown(team.name) })
                        .contextMenu {
                            if team.hasTaskBoard {
                                Button("작업판 열기") { openTaskBoard(team.name) }
                                Divider()
                            }
                            Button("팀 종료…", role: .destructive) { tower.askShutdown(team.name) }
                                .disabled(tower.shutdowns.running.contains(team.name))
                        }
                    }
                }
            }
            ForEach(model.agents, id: \.agent) { g in
                Section {
                    ForEach(g.rows, id: \.id) { LiveRowView(row: $0).tag($0.id) }
                } header: {
                    GroupHeader(tag: .agent(g.agent), count: myTurnText(g.myTurn), tooltip: g.summary)
                }
            }
        }
        .contextMenu(forSelectionType: RowID.self) { rowMenu($0, model) } primaryAction: { rowAction($0, model) }
        .onKeyPress(.rightArrow) { arrow(unfold: true, model) }
        .onKeyPress(.leftArrow) { arrow(unfold: false, model) }
    }

    private func arrow(unfold: Bool, _ model: SidebarModel) -> KeyPress.Result {
        guard let team = teamForArrow(unfold: unfold, selection: selection, teams: model.teams,
                                      expanded: { opened.isExpanded($0, query: query) }) else { return .ignored }
        var o = opened
        o.set(team, expanded: unfold, query: query)
        guard o != opened else { return .ignored }
        storedOpened = o.stored
        return .handled
    }

    private func historyList(_ model: SidebarModel) -> some View {
        List(selection: paneSelection(.history)) {
            ForEach(model.history, id: \.transcriptPath) { h in
                HistoryRowView(h: h, now: Date(), home: home) { tower.open(h) }.tag(RowID.history(h.transcriptPath))
            }
            if model.historyRemaining > 0 {
                Button("더 보기 (남은 \(model.historyRemaining)개)") { historyLimit += historyPageSize }
                    .buttonStyle(.link)
            }
        }
        .contextMenu(forSelectionType: RowID.self) { rowMenu($0, model) } primaryAction: { rowAction($0, model) }
    }

    @ViewBuilder
    private func rowMenu(_ ids: Set<RowID>, _ model: SidebarModel) -> some View {
        if let id = ids.first {
            ForEach(rowMenuItems(id, in: model), id: \.self) { item in
                Button(item.title) { perform(item, on: id, model) }
            }
        }
    }

    /// A double click or Return: the menu's first item.
    private func rowAction(_ ids: Set<RowID>, _ model: SidebarModel) {
        guard let id = ids.first, let first = rowMenuItems(id, in: model).first else { return }
        perform(first, on: id, model)
    }

    private func perform(_ item: RowMenuItem, on id: RowID, _ model: SidebarModel) {
        let row = model.liveRows.first { $0.id == id }
        switch item {
        case .focus: if let row { tower.focus(row.session.handle) }
        case .diff: if let row { openWindow(id: "diff", value: DiffTarget(workspace: row.session.cwd)) }
        case .copyPath: if let row { copy(row.session.cwd) }
        case .copyResume: if let h = historyEntry(id, model) { copy(resumeCopyText(h)) }
        case .resume: if let h = historyEntry(id, model) { tower.open(h) }
        }
    }

    private var opened: OpenedTeams { OpenedTeams(stored: storedOpened) }

    private func teamExpanded(_ team: String) -> Binding<Bool> {
        Binding {
            opened.isExpanded(team, query: query)
        } set: { open in
            var o = opened
            o.set(team, expanded: open, query: query)
            storedOpened = o.stored
        }
    }

    private func toggleTeam(_ team: String) {
        var o = opened
        o.toggle(team, query: query)
        storedOpened = o.stored
    }

    /// A row picked outside the sidebar opens its folded team, so the selection shows.
    private func reveal(_ id: RowID) {
        guard let board = tower.board else { return }
        var o = opened
        o.reveal(id, in: board)
        if o != opened { storedOpened = o.stored }
    }

    /// The history list's bar, built like the running list's so both line up with the sidebar's edges: a section
    /// header sits on the list's own insets, which put a fixed-width picker right of the rows below it.
    private var historyHeader: some View {
        HStack {
            Text("기록 · 최근순").scaledFont(.headline, weight: .semibold)
            Spacer()
            Picker("기록 종류", selection: $filter) {
                Text("Claude").tag(HistoryFilter.claude)
                Text("Codex").tag(HistoryFilter.codex)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func sidebarHeader(_ model: SidebarModel) -> some View {
        HStack {
            Text("실행 중").scaledFont(.headline, weight: .semibold)
            Spacer()
            launchMenu(running: tower.board.map(runningTeams) ?? [])
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// 팀 실행 (T206 §2, T208): the team configs in ~/teams, the team run last first, each with when it last ran; then
    /// the files that are not one, then 새 팀 만들기… and the folder. A team that runs or is being started is dimmed.
    private func launchMenu(running: Set<String>) -> some View {
        let list = tower.teamConfigList
        let last = lastRuns(tower.history)
        let now = Date()
        return Menu {
            if list.configs.isEmpty { Text("~/teams 에 팀 config가 없습니다") }
            ForEach(launchOrder(list.configs, last: last), id: \.path) { c in
                let launching = tower.launches.pending(c.team)
                Button { tower.launchTeam(c) } label: {
                    Text(c.team)
                    Text(tower.historyRead ? launchItemSubtitle(workers: tower.launchWorkers[c.team] ?? c.workers, last: last[c.team], running: running.contains(c.team),
                                                                launching: launching, now: now, group: c.group)
                                           : "기록 읽는 중 · 워커 \(c.workers)")
                }
                // before the first history read every team would look never run, and start without its conversations
                .disabled(running.contains(c.team) || launching || !tower.historyRead)
                .help(launchItemTooltip(c, last: last[c.team], running: running.contains(c.team), home: home, now: now))
            }
            if !list.unreadable.isEmpty {
                Divider()
                Section("읽지 못한 파일") {
                    ForEach(list.unreadable, id: \.file) { u in Text("\(u.file) — \(u.reason.rawValue)") }
                }
            }
            Divider()
            Button("새 팀 만들기…") { tower.newTeam() }
            Button("~/teams 폴더 열기") { tower.openTeamsFolder() }
        } label: {
            Label("팀 실행", systemImage: "play")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .scaledFont(.callout)
        .help("~/teams 의 config로 팀을 새 터미널에서 실행하거나, Claude와 새 팀 config를 만듭니다")
    }

    /// The history entry a row stands for: itself, or the entry reading a live session's transcript.
    private func historyEntry(_ id: RowID, _ model: SidebarModel) -> HistorySession? {
        switch id {
        case .history(let path): model.history.first { $0.transcriptPath == path } ?? tower.history.first { $0.transcriptPath == path }
        case .live: model.liveRows.first { $0.id == id }?.matched
        case .dashboard: nil
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

/// An area's head, the sidebar's largest text: its label `.headline`, 내 차례 count `.callout`.
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

/// A team under the my-team head, drawn as one folder line rather than a worker, without a band or an outline
/// (T124, MU10, MU13, T184): the fold chevron, the name, the task board button, the worker count, the decisions
/// waiting, then each state's icon and number. When the name whole does not fit, the line gives way through the
/// densities (`TeamLineDensity`): words become icons, then the worker count goes, then the working count. What is
/// my turn goes last (T189): the name is cut to its first four characters (`nameShortWidth`) before the my-turn
/// counts are added into one, and cut further before any count is. It never wraps. The name is `.primary`; the gray marks are
/// `TaskColor.sidebarGray`, which reads 4.5:1 where `.secondary` does not in light (T132, DiffContrastTests). The insets stay as the band had them.
struct TeamHeader: View {
    let team: TeamGroup
    /// Whether the team's workers are listed under the line.
    let expanded: Bool
    let board: TaskBoardButtonState
    let openBoard: () -> Void
    /// A click on the line, or VoiceOver's action.
    let toggle: () -> Void
    /// 팀 종료 has been confirmed and the team still runs: its counts give way to a spinner (T206 §1).
    var shuttingDown = false
    /// VoiceOver's 팀 종료 action, as the line's context menu has it.
    var shutdown: (() -> Void)?
    @Environment(\.boardFontScale) private var scale
    /// Wide enough for the chevron at `.callout` up to the largest font scale (R47).
    private static let iconWidth: CGFloat = 26

    /// Where the team's name starts past the header cell's leading edge: outer inset 6, band inset 6, icon, spacing 6.
    static func nameInset(_ scale: CGFloat) -> CGFloat { 6 + 6 + iconWidth * scale + 6 }
    /// A worker row's inset, so its name starts half a step (8) past the team's name: a row cell sits 2 points right
    /// of a header cell in the sidebar style (R47), and the row's status icon and 6 points come before its name.
    static func workerInset(_ scale: CGFloat) -> CGFloat {
        nameInset(scale) + 8 - 2 - StatusIconView.size(.body, scale: scale) - 6
    }

    /// The name's width at the board's font scale.
    static func nameWidth(_ name: String, scale: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .headline).pointSize * scale, weight: .semibold)
        return (name as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    /// The width of a name cut short: its first four characters and an ellipsis, or the name whole when it is
    /// shorter than that.
    static func nameShortWidth(_ name: String, scale: CGFloat) -> CGFloat {
        min(nameWidth(name, scale: scale), nameWidth(String(name.prefix(4)) + "…", scale: scale))
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(.full)
            line(.icons)
            line(.compact)
            line(.noWorkers)
            line(.myTurn)
            line(.myTurn, shortName: true)
            line(.myTurnTotal, shortName: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .padding(.leading, 6)
        .textCase(nil)
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
        .help(shuttingDown ? "팀을 종료하는 중" : teamLineTooltip(team))
        // a section header is one accessibility element: the name carries the line's whole label, the task board's
        // counts or failure in it, and the button reaches VoiceOver as an action of that element
        .accessibilityElement(children: .contain)
    }

    /// `shortName`: the line counts as fitting with the name cut to `nameShortWidth`, and shows as much of the name
    /// as there is room for.
    private func line(_ density: TeamLineDensity, shortName: Bool = false) -> some View {
        let parts = teamLine(team, density)
        let whole = Self.nameWidth(team.name, scale: scale)
        return HStack(spacing: 6) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right").scaledFont(.callout, weight: .semibold)
                .foregroundStyle(TaskColor.sidebarGray)
                .frame(width: Self.iconWidth * scale, alignment: .leading)
                .accessibilityHidden(true)
            Text(team.name).scaledFont(.headline, weight: .semibold).foregroundStyle(shuttingDown ? .secondary : .primary).lineLimit(1)
                .frame(idealWidth: shortName ? Self.nameShortWidth(team.name, scale: scale) : whole, maxWidth: whole, alignment: .leading)
                .accessibilityLabel(shuttingDown ? "\(team.name), 팀을 종료하는 중"
                                                 : teamLineLabel(team) + (team.hasTaskBoard ? ", " + board.spoken : ""))
                .accessibilityValue(expanded ? "펼침" : "접힘")
                .accessibilityAction(named: expanded ? "접기" : "펴기", toggle)
                .accessibilityActions {
                    if parts.board != nil { Button(board.label, action: openBoard) }
                    if let shutdown, !shuttingDown { Button("팀 종료", action: shutdown) }
                }
            // hidden from accessibility: left in, the header's one element presses it along with the fold
            if let form = parts.board {
                TaskBoardButton(state: board, showsWord: form == .words, open: openBoard).accessibilityHidden(true)
            }
            Group {
                switch parts.workersForm {
                case .words: Text("워커 \(parts.workers)").monospacedDigit()
                case .icon: count("person.2", parts.workers).help("워커 \(parts.workers)")
                case nil: EmptyView()
                }
                if parts.decisions > 0 && !shuttingDown { decisions(parts) }
            }
            .scaledFont(.callout).foregroundStyle(TaskColor.sidebarGray).fixedSize().accessibilityHidden(true)
            Spacer(minLength: 8)
            if shuttingDown {
                ProgressView().controlSize(.mini).accessibilityHidden(true)
            } else {
            HStack(spacing: 8) {
                ForEach(parts.statuses, id: \.badge.icon) { s in
                    HStack(spacing: 2) {
                        StatusIconView(badge: s.badge, style: .callout)
                        Text("\(s.count)").monospacedDigit()
                    }
                    .help("\(badgeLabel(s.badge)) \(s.count)")
                }
                if let n = parts.myTurnTotal, n > 0 {
                    count("tray.full.fill", n).foregroundStyle(.orange).help("내 차례 \(n)")
                }
            }
            .scaledFont(.callout).foregroundStyle(TaskColor.sidebarGray).fixedSize().accessibilityHidden(true)
            }
        }
    }

    private func count(_ symbol: String, _ n: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
            Text("\(n)").monospacedDigit()
        }
    }

    /// A filled shape and a number, with words when there is room, not color alone (T116).
    @ViewBuilder
    private func decisions(_ parts: TeamLineParts) -> some View {
        switch parts.decisionsForm {
        case .words:
            Label("결정 대기 \(parts.decisions)", systemImage: "person.fill.questionmark")
                .scaledFont(.caption1, weight: .bold).monospacedDigit()
                .foregroundStyle(TaskColor.onRed)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(TaskColor.pink, in: .capsule)
        case .icon:
            count("person.fill.questionmark", parts.decisions).foregroundStyle(TaskColor.pink)
                .help("결정 대기 \(parts.decisions)")
        }
    }
}

/// The sidebar's first line: the usage dashboard.
private struct DashboardRow: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.3.group").scaledFont(.body)
            Text("대시보드").scaledFont(.body, weight: .semibold)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("대시보드")
    }
}

struct LiveRowView: View {
    let row: LiveRow
    var change: RowChange?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if let change { line(change) }
            line(nil)
        }
        .help(([badgeLabel(row.badge), row.path] + (change.map { [$0.words] } ?? [])).joined(separator: "\n"))
        .overlay { if let change { spokenWhetherDrawnOrNot(change) } }
    }

    private func spokenWhetherDrawnOrNot(_ change: RowChange) -> some View {
        Color.clear.accessibilityElement().accessibilityLabel(change.words).allowsHitTesting(false)
    }

    private func line(_ change: RowChange?) -> some View {
        HStack(spacing: 6) {
            StatusIconView(badge: row.badge, style: .body)
            Text(row.title).scaledFont(.body).foregroundStyle(.primary).lineLimit(1).layoutPriority(1)
            if let folder = row.shownFolder {
                Text(folder).scaledFont(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let change {
                HStack(spacing: 4) {
                    if !change.sharers.isEmpty { Image(systemName: "folder") }
                    Text(change.added).foregroundStyle(.green)
                    Text(change.removed).foregroundStyle(.red)
                }
                .scaledFont(.caption1).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                .accessibilityHidden(true)
            }
            Text(row.badge.elapsed).scaledFont(.caption1).foregroundStyle(.secondary).fixedSize()
        }
    }
}

private struct HistoryRowView: View {
    let h: HistorySession
    let now: Date
    let home: String
    /// The row's run button, the same as a double click on it; nil leaves it out.
    var run: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(historyTitle(h)).scaledFont(.callout).foregroundStyle(.primary).lineLimit(1)
                Text(historySubtitle(h)).scaledFont(.caption1).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Text(relativeTime(h.updatedAt, now: now)).scaledFont(.caption1).foregroundStyle(.secondary).fixedSize()
            if let run {
                RunButton(label: "세션 실행", action: run)
                    .help("실행: 새 Ghostty 창에서 이 세션을 resume합니다(더블 클릭과 같음)")
            }
        }
        .help(historyTooltip(h, home: home))
    }
}

/// ▶: starts what a history line stands for, a team run or a session. The words are its tooltip and label.
private struct RunButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill").scaledFont(.caption1)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}

private struct DetailView: View {
    let board: Board
    let model: SidebarModel
    /// Every history entry: a selected row paged out of `model.history` keeps its detail.
    let history: [HistorySession]
    let selection: RowID
    let home: String
    let taskBoards: [String: TaskBoardState]
    let ide: IdeState
    /// Opens the task's team's task board window on it.
    let openTask: (TaskRef) -> Void
    let dashboard: DashboardView
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch selection {
                case .live:
                    if let row = model.liveRows.first(where: { $0.id == selection }) { live(row) } else { empty }
                case .history(let path):
                    if let h = (model.history + history).first(where: { $0.transcriptPath == path }) { past(h) } else { empty }
                case .dashboard:
                    dashboard
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var empty: some View {
        Text("세션을 선택하세요").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func live(_ row: LiveRow) -> some View {
        let s = row.session
        let team = row.teamName.flatMap { n in board.teams.first { $0.name == n } }
        let sharers = workspaceSharers(row, in: board)
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
                ("diff 범위", diffScopeLabel(scope: nil, sharers: sharers)),
            ],
            workspace: s.cwd,
            conversation: [("나", s.lastUser), ("에이전트", s.lastAssistant)],
            ide: s.tmux != nil,
            tasks: workerTaskLine(row, team: team), worker: row.worker?.workerName)
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
            conversation: [("최근 프롬프트", h.lastPrompt ?? "")],
            ide: false,
            tasks: nil)
    }

    /// The worker's unfinished tasks on its team's board (design §1, pm decision 6); nil without a board or a read.
    private func workerTaskLine(_ row: LiveRow, team: Team?) -> WorkerTaskLine? {
        guard let team, team.hasTaskBoard, let name = row.worker?.workerName,
              let status = taskBoards[team.name]?.status else { return nil }
        return WorkerTaskLine(team: team.name, tasks: workerTasks(name, in: status))
    }

    /// `ide`: a session in a tmux pane has its head over the IDE area, which fills the rest; another scrolls, its
    /// recent conversation under the head.
    private func detailBody(title: String, @ViewBuilder badges: () -> some View,
                            facts: [(String, String)], workspace: String, conversation: [(String, String)],
                            ide: Bool, tasks: WorkerTaskLine?, worker: String? = nil) -> some View {
        let head = VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).scaledFont(.title2, weight: .bold).lineLimit(1)
                badges()
                Spacer(minLength: 8)
                // the diff is read in its own window, never on a selection (T72)
                Button("변경 보기 (⌘D)", systemImage: "plus.forwardslash.minus") {
                    openWindow(id: "diff", value: DiffTarget(workspace: workspace))
                }
                .help("이 워크스페이스의 diff와 폴더 트리를 새 창에서 봅니다")
            }
            if let tasks {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("작업").foregroundStyle(.secondary)
                    WorkerTasksView(line: tasks) { openTask(TaskRef(team: tasks.team, task: $0)) }
                }
            }
            DetailInfoView(facts: facts.filter { !$0.1.isEmpty })
        }
        return Group {
            if ide {
                VStack(alignment: .leading, spacing: 12) {
                    head
                    IdeArea(root: workspace, worker: worker, at: board.at, state: self.ide)
                        .frame(maxHeight: .infinity)
                }
                .padding(16)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        head
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
                }
            }
        }
    }
}

/// The detail's facts folded to one line, "정보" and their values; open, the facts as a table. Open or folded is
/// one choice for every session, kept across launches.
struct DetailInfoView: View {
    let facts: [(String, String)]
    @AppStorage(DetailInfo.storageKey) private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(facts, id: \.0) { k, v in
                    GridRow {
                        Text(k).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        // a line cap: unbounded, a value asked for its least size grows a line every few characters,
                        // and that height became the board window's least height (T80)
                        Text(v).textSelection(.enabled).lineLimit(2).truncationMode(.middle).help(v)
                            .scaledFont(.body, design: monoFacts.contains(k) ? .monospaced : .default)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Text("정보")
                if let summary = DetailInfo.summary(facts, expanded: expanded) {
                    Text(summary).scaledFont(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}

enum DetailInfo {
    static let storageKey = "detailInfoExpanded"

    /// Beside "정보" while folded: each fact's value, in order. Open, the table shows them instead.
    static func summary(_ facts: [(String, String)], expanded: Bool) -> String? {
        expanded ? nil : facts.map(\.1).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct Pill: View {
    let text: String

    var body: some View {
        Text(text).scaledFont(.caption1)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Color(nsColor: .quaternaryLabelColor), in: .capsule)
    }
}

/// Detail facts that are paths or identifiers.
private let monoFacts: Set = ["워크스페이스", "branch", "tmux"]

private struct BoardWindowBehavior: View {
    var body: some View {
        if testInstanceWindows == nil { FullScreenCapable() } else { TestWindowPlacement() }
    }
}

/// Lets the board window take its own Space in full screen (green button, ⌃⌘F). Left to AppKit's own
/// choice, the board window of this menu bar app (LSUIElement) did not go full screen.
struct FullScreenCapable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { makeProbe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeProbe() -> NSView { Probe() }

    private static func allow(_ window: NSWindow?) {
        guard let window else { return }
        // at most one of each group may be set; SwiftUI marks the accessory app's board .auxiliary
        var behavior = window.collectionBehavior
        behavior.subtract([.fullScreenNone, .fullScreenAuxiliary, .auxiliary, .canJoinAllApplications])
        behavior.insert([.fullScreenPrimary, .primary])
        if behavior != window.collectionBehavior { window.collectionBehavior = behavior }
    }

    /// Each write the probe sees, at debug level: kept off the disk unless `log stream --level debug` asks for it.
    private static let log = Logger(subsystem: "local.control-tower", category: "fullscreen")

    /// Whether the board was in full screen when it went away. Closing ends the full screen space, and macOS puts a
    /// reopened window on the space in view, over a full screen Ghostty; a board closed in full screen goes back.
    static var defaults = UserDefaults.standard
    static let fullScreenKey = "boardFullScreen"
    /// How long after leaving full screen the window must still be up for that to be the user's choice: closing a
    /// full screen window leaves full screen too, with the window gone.
    static var settle: Duration = .seconds(1)

    private final class Probe: NSView {
        /// SwiftUI writes its own behavior back after the board mounts (T38b log), so each write is undone.
        private var rewrite: NSKeyValueObservation?
        private var observers: [NSObjectProtocol] = []
        private var restored = false

        override func viewDidMoveToWindow() {
            FullScreenCapable.allow(window)
            rewrite = window?.observe(\.collectionBehavior) { [weak window] _, _ in
                MainActor.assumeIsolated {
                    FullScreenCapable.log.debug("behavior written: \(window?.collectionBehavior.rawValue ?? 0, privacy: .public)")
                    FullScreenCapable.allow(window)
                }
            }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            restored = false
            guard let window else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { FullScreenCapable.defaults.set(true, forKey: FullScreenCapable.fullScreenKey) }
                },
                center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.keepWindowedIfStillUp() }
                },
                center.addObserver(forName: NSWindow.didBecomeMainNotification, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window, !self.restored else { return }
                        self.restored = true
                        if FullScreenCapable.defaults.bool(forKey: FullScreenCapable.fullScreenKey),
                           !window.styleMask.contains(.fullScreen) {
                            window.toggleFullScreen(nil)
                        }
                    }
                },
            ]
        }

        /// Left full screen: the user's choice if the window is still up a moment later, a close otherwise.
        private func keepWindowedIfStillUp() {
            Task { [weak self] in
                try? await Task.sleep(for: FullScreenCapable.settle)
                if self?.window?.isVisible == true { FullScreenCapable.defaults.set(false, forKey: FullScreenCapable.fullScreenKey) }
            }
        }
    }
}

/// The board's search box: AppKit's search field, with its clear button. `.searchable` cannot take the keyboard
/// from a shortcut before macOS 15 (`searchFocused`), and the package supports 14.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    /// A new value puts the keyboard in the field.
    let focusRequest: Int

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focused != focusRequest {
            context.coordinator.focused = focusRequest
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focused: focusRequest) }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var focused: Int

        init(text: Binding<String>, focused: Int) {
            self.text = text
            self.focused = focused
        }

        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSSearchField { text.wrappedValue = field.stringValue }
        }
    }
}

/// 팀 종료's confirmation: 취소 is the default button, so Return never shuts a team down; only 팀 종료 does.
private struct ShutdownConfirmation: ViewModifier {
    let tower: Tower

    func body(content: Content) -> some View {
        // closing the dialog (the binding's set, before or after a button's action, or any other way) only hides it;
        // 팀 종료 still finds the team it was asked about, and 취소 forgets it (TeamShutdowns)
        content.alert("“\(tower.shutdowns.asking ?? "")” 팀을 종료할까요?",
                      isPresented: Binding { tower.shutdowns.asking != nil } set: { if !$0 { tower.closeShutdown() } },
                      presenting: tower.shutdowns.asking) { team in
            Button("취소", role: .cancel) { tower.cancelShutdown() }
                .keyboardShortcut(.defaultAction)
            Button("팀 종료", role: .destructive) { tower.confirmShutdown(team) }
        } message: { team in
            Text(shutdownMessage(workers: tower.board?.teams.first { $0.name == team }?.workers.count ?? 0))
        }
    }
}

/// A team 팀 실행 asked to start, at the top of the running teams until the board sees it run.
private struct LaunchingTeamLine: View {
    let team: String
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini).frame(width: 26 * scale, alignment: .leading)
            Text(team).scaledFont(.headline, weight: .semibold).foregroundStyle(.primary).lineLimit(1)
            Spacer(minLength: 8)
            Text("띄우는 중").scaledFont(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 3).padding(.leading, 6)
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(team), 띄우는 중")
    }
}
