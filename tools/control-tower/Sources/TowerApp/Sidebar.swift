import Foundation
import TowerCore

// The sidebar's data, projected from a board and the history list. No view code, so the
// grouping, wording and search are testable.

enum RowID: Hashable {
    /// The sidebar's first line: the usage dashboard.
    case dashboard
    /// `Session.rowID`.
    case live(String)
    /// `HistorySession.transcriptPath`.
    case history(String)
}

enum RowBadge: Equatable {
    case waitingForUser(minutes: Int?)
    case permission(minutes: Int?)
    case working
    case done(minutesAgo: Int?)
    case idle(minutes: Int?)

    /// The row's leading icon. Shapes differ for working, permission and done, so color is not the only cue.
    var icon: StatusIcon {
        switch self {
        case .working: .spinner
        case .waitingForUser: .waiting
        case .permission: .alert
        case .done: .check
        case .idle: .idle
        }
    }

    /// The row's trailing text: elapsed time in its largest unit (`4분`, `3시간`, `1일`); '' while working or unknown.
    var elapsed: String {
        switch self {
        case .working: ""
        case .waitingForUser(let m), .permission(let m), .done(let m), .idle(let m): m.map(shortDuration) ?? ""
        }
    }

    var isDone: Bool { if case .done = self { true } else { false } }
}

enum StatusIcon: Equatable, CaseIterable {
    case spinner, waiting, alert, check, idle

    /// In a system menu, where a symbol has no color of its own: each state its own shape.
    var symbol: String {
        switch self {
        case .spinner: "ellipsis.circle"
        case .waiting: "hand.raised.fill"
        case .alert: "exclamationmark.circle.fill"
        case .check: "checkmark.circle.fill"
        case .idle: "circle"
        }
    }
}

struct LiveRow: Equatable {
    var id: RowID
    var session: Session
    var worker: Worker?
    var teamName: String?
    var title: String
    /// The session's working folder name and its `~` path.
    var folder: String
    var path: String
    var badge: RowBadge
    /// The history entry that reads this session's transcript: source of its branch and resume command.
    var matched: HistorySession?

    /// The folder shown after the title; nil when it would repeat the title.
    var shownFolder: String? { folder == title ? nil : folder }
    /// The label in front of the row's group: `my-team` with the team's name, or the agent alone.
    var group: (kind: LineKind, name: String?) { teamName.map { (.team, $0) } ?? (.agent(session.agent), nil) }
}

struct TeamGroup: Equatable {
    var name: String
    /// Workers whose turn is mine, the menu bar's and the 내 차례 list's count (done and permission included).
    var myTurn: Int
    var rows: [LiveRow]
    /// Stopped workers, which the sidebar lists nowhere.
    var stopped = 0
    /// The team keeps a task board: its line has the button that opens it, with counts in its tooltip once read.
    var hasTaskBoard = false
    var taskCounts: TaskCounts?
    /// The team's group (manifest `group`), shown in its line's tooltip.
    var group: String? = nil
}

/// The task board button's counts (v4 §7.5 S2): the decisions waiting for the user, then each panel's tasks but the
/// done, in the list's order; 보류 only when it has one.
struct TaskCounts: Equatable {
    struct Count: Equatable {
        var panel: TaskPanel
        var count: Int
    }

    /// Decisions waiting for the user (T116, T147): the menu bar's count has them too.
    var user = 0
    var panels: [Count]

    init(user: Int = 0, start: Int, doing: Int, review: Int, held: Int = 0) {
        self.user = user
        panels = [Count(panel: .start, count: start), Count(panel: .doing, count: doing), Count(panel: .review, count: review)]
            + (held > 0 ? [Count(panel: .held, count: held)] : [])
    }

    init(_ s: TaskBoardStatus) {
        let p = taskPanels(s)
        func n(_ panel: TaskPanel) -> Int { p[panel]?.count ?? 0 }
        self.init(user: openDecisions(s).count, start: n(.start), doing: n(.doing), review: n(.review), held: n(.held))
    }
}

/// Sessions outside teams, one group per agent.
struct AgentGroup: Equatable {
    var agent: AgentKind
    /// The header's tooltip.
    var summary: String
    var myTurn: Int
    var rows: [LiveRow]
}

struct SidebarModel: Equatable {
    var teams: [TeamGroup]
    /// Claude Code, then Codex; an agent with no session has no group.
    var agents: [AgentGroup]
    /// One page or more of the filtered history, newest first, running sessions listed above left out.
    var history: [HistorySession]
    /// Filtered history lines past `history`.
    var historyRemaining: Int
    /// Every live row waiting on me, search ignored: those asking for an answer above finished ones, each longest
    /// wait first, a row without a start time last.
    var queue: [LiveRow]

    var liveRows: [LiveRow] { teams.flatMap(\.rows) + agents.flatMap(\.rows) }
    /// The running list's areas, top to bottom: one my-team area over all its teams, then one per agent.
    var liveAreas: [LineKind] { (teams.isEmpty ? [] : [.team]) + agents.map { .agent($0.agent) } }
}

/// Team sections the user opened in the sidebar, by team name; every team is folded by default (T184).
/// Stored as a JSON array, so any name round-trips; a team that stops running keeps its name here, matched by nothing.
struct OpenedTeams: Equatable {
    static let storageKey = "openedTeams"

    private(set) var names: Set<String>

    init(stored: String) {
        names = Set((try? JSONDecoder().decode([String].self, from: Data(stored.utf8))) ?? [])
    }

    var stored: String { String(decoding: (try? JSONEncoder().encode(names.sorted())) ?? Data(), as: UTF8.self) }

    /// A search shows every team's matches, folded or not; the folds return once it is cleared.
    func isExpanded(_ team: String, query: String) -> Bool { isSearching(query) || names.contains(team) }

    /// A disclosure click during a search changes nothing: the section stays open for the search.
    mutating func set(_ team: String, expanded: Bool, query: String) {
        guard !isSearching(query) else { return }
        if expanded { names.insert(team) } else { names.remove(team) }
    }

    /// A click on the team's line: the same fold its disclosure would make.
    mutating func toggle(_ team: String, query: String) { set(team, expanded: !isExpanded(team, query: query), query: query) }

    /// Opens the team holding a row selected from outside the sidebar (menu bar).
    mutating func reveal(_ id: RowID, in board: Board) {
        guard case .live(let rowID) = id,
              let team = board.teams.first(where: { $0.workers.contains { $0.session.rowID == rowID } }) else { return }
        names.insert(team.name)
    }

    private func isSearching(_ query: String) -> Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The other live workers of `row`'s team in the same folder: the diff of that folder is theirs as much as its own.
/// A worker on its own git worktree shares with none.
func workspaceSharers(_ row: LiveRow, in board: Board) -> [String] {
    guard let me = row.worker, let team = board.teams.first(where: { $0.name == row.teamName }) else { return [] }
    return team.workers
        .filter { $0.alive && $0.workerName != me.workerName && $0.session.cwd == row.session.cwd }
        .map(\.workerName)
}

/// The task states a worker is on (T58): taken and not finished.
let inProgressTaskStates: Set<String> = ["doing", "changes", "review", "held", "waiting"]

/// The start commit of the task in progress `worker` took last (T58, D#27); with none in progress, of its task assigned
/// last in any state (D#28); nil when that task has none, the worker has no task, or no board is read.
/// The board keeps no time of a take: a `doing` task was taken when it entered `doing` (its `state_since`), so the
/// latest of those wins; with none doing, the latest assigned.
func workerTaskBase(team: String, worker: String, taskBoards: [String: TaskBoardStatus]) -> String? {
    let mine = (taskBoards[team]?.tasks ?? []).filter { $0.assignee == worker }
    let active = mine.filter { inProgressTaskStates.contains($0.state) }
    let doing = active.filter { $0.state == "doing" }
    let latestAssigned = { (ts: [TaskBoardTask]) in ts.max { ($0.assignedAt ?? "") < ($1.assignedAt ?? "") } }
    let last = doing.isEmpty ? latestAssigned(active.isEmpty ? mine : active)
                             : doing.max { ($0.history?.stateSince ?? "") < ($1.history?.stateSince ?? "") }
    return last?.baseCommit.flatMap { $0.isEmpty ? nil : $0 }
}

func diffKey(_ row: LiveRow, taskBoards: [String: TaskBoardStatus]) -> DiffKey {
    guard let worker = row.worker, let team = row.teamName else { return DiffKey(folder: row.session.cwd) }
    return DiffKey(folder: row.session.cwd, taskBase: workerTaskBase(team: team, worker: worker.workerName, taskBoards: taskBoards))
}

func diffTotalKeys(_ teams: [TeamGroup], taskBoards: [String: TaskBoardStatus] = [:], expanded: (String) -> Bool) -> Set<DiffKey> {
    Set(teams.filter { expanded($0.name) }.flatMap(\.rows).filter { !$0.session.cwd.isEmpty }.map { diffKey($0, taskBoards: taskBoards) })
}

struct RowChange: Equatable {
    var total: DiffTotal
    var sharers: [String] = []

    var added: String { "+\(total.added)" }
    var removed: String { "−\(total.removed)" }
    var words: String {
        "더한 줄 \(total.added), 뺀 줄 \(total.removed)" + (sharers.isEmpty ? "" : " (\(sharers.joined(separator: ", "))와 같은 폴더의 값)")
    }
}

/// Sharers are the workers of the folder counted from the same task base: another base is another count.
func rowChange(_ row: LiveRow, totals: [DiffKey: DiffTotal], board: Board, taskBoards: [String: TaskBoardStatus] = [:]) -> RowChange? {
    let key = diffKey(row, taskBoards: taskBoards)
    guard let total = totals[key], !total.isEmpty else { return nil }
    return RowChange(total: total, sharers: workspaceSharers(row, in: board).filter {
        workerTaskBase(team: row.teamName ?? "", worker: $0, taskBoards: taskBoards) == key.taskBase
    })
}

/// A diff window's tab title (T149): the team and workers of each team working in the folder, or the folder's name
/// when no team does.
func diffTabTitle(workspace: String, board: Board?) -> String {
    let teams = (board?.teams ?? []).compactMap { team -> String? in
        let names = team.workers.filter { $0.alive && $0.session.cwd == workspace }.map(\.workerName)
        return names.isEmpty ? nil : "\(team.name) · \(names.joined(separator: ", "))"
    }
    return teams.isEmpty ? URL(fileURLWithPath: workspace).lastPathComponent : teams.joined(separator: " / ")
}

/// The detail's "diff 범위": the folder of the repo the diff is limited to, and the teammates whose diff is the
/// same because they work in the same folder (a worktree per worker splits it).
func diffScopeLabel(scope: String?, sharers: [String]) -> String {
    [scope.flatMap { $0.isEmpty ? nil : "저장소의 \($0)/ 아래만" },
     sharers.isEmpty ? nil : "팀 공유 폴더 (\(sharers.joined(separator: ", "))와 함께)"]
        .compactMap { $0 }.joined(separator: " · ")
}

/// The teams with a live worker: a team named like one of these cannot be started again.
func runningTeams(_ board: Board) -> Set<String> {
    Set(board.teams.filter { $0.workers.contains(where: \.alive) }.map(\.name))
}

/// One `my-team start` of a team: its name and when the workers it launched began (ms since 1970); nil when
/// none of them is left in the history, only workers added later.
struct TeamRun: Hashable {
    var team: String
    var start: Double?
}

/// Each team session's run, by transcript path. Workers `my-team start` launches begin within minutes of each other,
/// runs hours or days apart (control-tower's history: 5.4 minutes at most within a run), so a start session more
/// than `gap` after the previous one begins a new run. A worker added later belongs to the run begun last before it.
func teamRuns(_ history: [HistorySession], gap: Double = 10 * 60_000) -> [String: TeamRun] {
    var launched: [String: [Double]] = [:]
    for h in history {
        if let m = h.member, !m.joined, let t = parseISO(h.createdAt) { launched[m.team, default: []].append(t) }
    }
    let begun = launched.mapValues { times in
        times.sorted().reduce(into: (starts: [Double](), last: -Double.infinity)) { acc, t in
            if t - acc.last > gap { acc.starts.append(t) }
            acc.last = t
        }.starts
    }
    var runs: [String: TeamRun] = [:]
    for h in history {
        guard let m = h.member else { continue }
        let start = parseISO(h.createdAt).flatMap { t in begun[m.team]?.last { $0 <= t } }
        runs[h.transcriptPath] = TeamRun(team: m.team, start: start)
    }
    return runs
}

/// "1.2 MB", as Finder shows a file's size.
func transcriptSizeLabel(_ bytes: Int?) -> String? {
    bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
}

/// What the history list shows: the single terminals of one agent. A team's workers are never single terminals,
/// whatever agent they ran: a stopped team is started again from 팀 실행 (T208).
enum HistoryFilter: Hashable {
    case claude, codex

    func shows(_ h: HistorySession) -> Bool {
        switch self {
        case .claude: h.member == nil && h.agent == .claude
        case .codex: h.member == nil && h.agent == .codex
        }
    }
}

let historyPageSize = 30

func sidebarModel(board: Board, history: [HistorySession], query: String, filter: HistoryFilter, historyLimit: Int,
                  home: String, taskBoards: [String: TaskBoardStatus] = [:]) -> SidebarModel {
    let byTranscript = Dictionary(history.map { ($0.transcriptPath, $0) }, uniquingKeysWith: { a, _ in a })
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    func hit(_ fields: [String?]) -> Bool {
        q.isEmpty || fields.contains { $0?.lowercased().contains(q) == true }
    }
    func matches(_ r: LiveRow) -> Bool {
        hit([r.teamName, r.worker?.workerName, r.session.cwd, r.title, r.matched?.branch, r.matched?.title])
    }

    // Before search: a row hidden by the query is still listed above, so its session stays out of history.
    var listed = Set(board.loose.compactMap(\.transcript))
    var all: [LiveRow] = []
    var teams: [TeamGroup] = []
    for team in sortTeams(board.teams) {
        let rows = sortCards(team.workers).compactMap { w -> LiveRow? in
            guard let badge = badge(displayState(w), at: board.at) else { return nil }
            return LiveRow(id: .live(w.session.rowID), session: w.session, worker: w, teamName: team.name,
                           title: w.cardName, folder: basename(w.session.cwd), path: abbreviate(w.session.cwd, home: home),
                           badge: badge, matched: w.transcript.flatMap { byTranscript[$0] })
        }
        listed.formUnion(rows.compactMap(\.session.transcript))
        all += rows
        let teamHit = hit([team.name, team.group])
        let shown = rows.filter { teamHit || matches($0) }
        if q.isEmpty || !shown.isEmpty {
            teams.append(TeamGroup(name: team.name, myTurn: rows.filter(\.session.myTurn).count,
                                   rows: shown, stopped: team.workers.count - rows.count, hasTaskBoard: team.hasTaskBoard,
                                   taskCounts: team.hasTaskBoard ? taskBoards[team.name].map(TaskCounts.init) : nil, group: team.group))
        }
    }

    var agents: [AgentGroup] = []
    for agent in [AgentKind.claude, .codex] {
        let rows = sortCards(board.loose.filter { $0.agent == agent }).map { s in
            let matched = s.transcript.flatMap { byTranscript[$0] }
            return LiveRow(id: .live(s.rowID), session: s, worker: nil, teamName: nil,
                           title: matched.map(historyTitle) ?? basename(s.cwd), folder: basename(s.cwd),
                           path: abbreviate(s.cwd, home: home),
                           badge: badge(displayState(s), at: board.at) ?? .idle(minutes: nil), matched: matched)
        }
        all += rows
        let agentHit = hit([LineKind.agent(agent).text])
        let shown = rows.filter { agentHit || matches($0) }
        if !shown.isEmpty {
            agents.append(AgentGroup(agent: agent, summary: sessionSummaryLine(rows), myTurn: rows.filter(\.session.myTurn).count,
                                     rows: shown))
        }
    }

    let past = history.filter { h in
        !listed.contains(h.transcriptPath)
            && filter.shows(h)
            && hit([h.title, h.workspace, h.branch, h.member?.team])
    }
    let queue = all.filter(\.session.myTurn).enumerated().sorted { a, b in
        if a.element.badge.isDone != b.element.badge.isDone { return !a.element.badge.isDone }
        return switch (parseISO(a.element.session.since), parseISO(b.element.session.since)) {
        case let (x?, y?) where x != y: x < y
        case (_?, nil): true
        case (nil, _?): false
        default: a.offset < b.offset
        }
    }.map(\.element)
    return SidebarModel(teams: teams, agents: agents,
                        history: Array(past.prefix(historyLimit)), historyRemaining: max(0, past.count - historyLimit),
                        queue: queue)
}

/// Maps Core's display state to a row badge; nil for a stopped worker (counted in the team summary, not listed).
private func badge(_ state: WorkerDisplayState, at: String) -> RowBadge? {
    switch state {
    case .stopped: nil
    case .permission(let since): .permission(minutes: minutes(from: since, to: at))
    case .done(let since): .done(minutesAgo: minutes(from: since, to: at))
    case .waitingForUser(let since): .waitingForUser(minutes: minutes(from: since, to: at))
    case .working: .working
    case .idle(let since): .idle(minutes: minutes(from: since, to: at))
    }
}

/// The menu bar dropdown: what is open in a terminal, in the sidebar's order, a team folded to one line.
struct MenuModel: Equatable {
    struct TeamLine: Equatable {
        var name: String
        var myTurn: Int
        /// The row the board selects for this line: a worker waiting on me, else the first; nil when none is listed.
        var select: RowID?
    }

    /// A sidebar agent group cut to the sessions open in a terminal.
    struct AgentLine: Equatable {
        var agent: AgentKind
        /// Of the rows listed here.
        var myTurn: Int
        var rows: [LiveRow]
    }

    /// The board's 내 차례 list, longest wait first (T125).
    var myTurn: [LiveRow] = []
    /// The decisions waiting for the user, in the order asked (T147).
    var decisions: [WaitingDecision] = []
    var teams: [TeamLine]
    /// Never holds a line without rows.
    var agents: [AgentLine]
}

/// The menu bar menu (T125), a system menu: sections of lines, each a symbol and words. Where a line goes is in its
/// section's title, a terminal or the board (D1); state is a symbol's shape and its words, never a color alone.
struct MenuSection: Equatable {
    var title: String
    var lines: [MenuItemLine]
}

struct MenuItemLine: Equatable {
    enum Target: Equatable {
        case terminal(handle: String)
        /// The board, with this row selected when there is one.
        case board(RowID?)
        /// The team's task board window, with this decision picked (T147).
        case decision(team: String, id: String)
    }

    var title: String
    var symbol: String
    var target: Target
}

/// 내 차례 first (hidden at 0), then the teams, then each agent's sessions. A 내 차례 line opens its row on the board,
/// as a 내 차례 card does (T84): the row may have no terminal open.
func menuSections(_ m: MenuModel) -> [MenuSection] {
    func line(_ row: LiveRow, group: Bool) -> MenuItemLine {
        let words = [row.title, badgeLabel(row.badge)] + (group ? [row.teamName ?? agentName(row.session.agent)] : [])
        return MenuItemLine(title: words.joined(separator: " · "), symbol: row.badge.icon.symbol,
                            target: group ? .board(row.id) : .terminal(handle: row.session.handle))
    }
    var out: [MenuSection] = []
    if let n = myTurnText(m.myTurn.count) {
        out.append(MenuSection(title: "\(n) · 보드에서 열기", lines: m.myTurn.map { line($0, group: true) }))
    }
    if !m.decisions.isEmpty {
        out.append(MenuSection(title: "결정 대기 \(m.decisions.count) · 작업판에서 열기", lines: m.decisions.map { w in
            MenuItemLine(title: "\(decisionQuestion(w.decision)) · \(w.team)", symbol: "person.fill.questionmark",
                         target: .decision(team: w.team, id: w.decision.id))
        }))
    }
    if !m.teams.isEmpty {
        out.append(MenuSection(title: "my-team · 보드에서 열기", lines: m.teams.map { t in
            MenuItemLine(title: ([t.name] + [myTurnText(t.myTurn)].compactMap { $0 }).joined(separator: " · "),
                         symbol: "macwindow", target: .board(t.select))
        }))
    }
    for g in m.agents {
        // the agent's 내 차례 count, as the board's sidebar group head has it (R48 L4)
        let title = [agentName(g.agent), myTurnText(g.myTurn), "터미널로 이동"].compactMap { $0 }.joined(separator: " · ")
        out.append(MenuSection(title: title, lines: g.rows.map { line($0, group: false) }))
    }
    return out
}

func menuModel(_ board: Board, history: [HistorySession], home: String, taskBoards: [String: TaskBoardStatus] = [:]) -> MenuModel {
    // no history page: the dropdown shows running sessions only
    let side = sidebarModel(board: board, history: history, query: "", filter: .claude, historyLimit: 0, home: home)
    let attached = Set(board.teams.filter(\.attached).map(\.name))
    return MenuModel(
        myTurn: side.queue,
        decisions: waitingDecisions(board, taskBoards: taskBoards),
        teams: side.teams.filter { attached.contains($0.name) }.map { t in
            MenuModel.TeamLine(name: t.name, myTurn: t.myTurn, select: (t.rows.first { $0.session.myTurn } ?? t.rows.first)?.id)
        },
        agents: side.agents.compactMap { g in
            let rows = g.rows.filter(\.session.inTerminal)
            return rows.isEmpty ? nil : MenuModel.AgentLine(agent: g.agent, myTurn: rows.filter(\.session.myTurn).count, rows: rows)
        })
}

/// `내 차례 N`; nil at 0.
func myTurnText(_ n: Int) -> String? { n > 0 ? "내 차례 \(n)" : nil }

/// How much of a team's line is shown, widest first; the sidebar shows the first that fits the name whole (T184).
enum TeamLineDensity: CaseIterable {
    /// The task board button says `작업판`, the worker count `워커`, the decisions are a `결정 대기` tag.
    case full
    /// The button and the worker count are an icon.
    case icons
    /// The decisions are an icon and a number too.
    case compact
    /// As `compact`, without the worker count.
    case noWorkers
    /// As `noWorkers`, and the status counts are the states that are my turn: permission request, waiting for an
    /// answer, done (T189).
    case myTurn
    /// As `myTurn`, its counts added into one number.
    case myTurnTotal
}

/// The workers in one state on a team's line: the state's icon and its number.
struct TeamStatusCount: Equatable {
    /// A badge standing for the state (no minutes): it draws the icon and words the label.
    var badge: RowBadge
    var count: Int
}

/// What a team's line shows right of its name at one density.
struct TeamLineParts: Equatable {
    enum Form: Equatable {
        /// A word and a number.
        case words
        /// An icon and a number, the button's icon alone.
        case icon
    }

    /// The task board button; nil for a team without a task board.
    var board: Form?
    /// The listed workers' count, whether or not `workersForm` shows it.
    var workers: Int
    /// nil: the worker count is not shown.
    var workersForm: Form?
    /// Decisions waiting for the user; 0 is not shown.
    var decisions: Int
    var decisionsForm: Form
    var statuses: [TeamStatusCount]
    /// The my-turn states' counts in one number, shown in place of `statuses`; nil: `statuses` are shown, and 0 is
    /// not shown.
    var myTurnTotal: Int?
}

/// A team line's parts, of the rows it lists (so a search's matches). Status counts run permission request, waiting
/// for an answer, done, working; a zero count and the idle state are left out. `myTurn` keeps the first three, and
/// `myTurnTotal` adds those three up.
func teamLine(_ team: TeamGroup, _ density: TeamLineDensity) -> TeamLineParts {
    let order: [RowBadge] = [.permission(minutes: nil), .waitingForUser(minutes: nil), .done(minutesAgo: nil), .working]
    let kept = [.myTurn, .myTurnTotal].contains(density) ? order.prefix(3) : order[...]
    let statuses = kept.compactMap { badge -> TeamStatusCount? in
        let n = team.rows.filter { $0.badge.icon == badge.icon }.count
        return n > 0 ? TeamStatusCount(badge: badge, count: n) : nil
    }
    let workersForm: TeamLineParts.Form? = switch density {
    case .full: .words
    case .icons, .compact: .icon
    case .noWorkers, .myTurn, .myTurnTotal: nil
    }
    let total = density == .myTurnTotal
    return TeamLineParts(board: team.hasTaskBoard ? (density == .full ? .words : .icon) : nil,
                         workers: team.rows.count, workersForm: workersForm,
                         decisions: team.taskCounts?.user ?? 0, decisionsForm: [.full, .icons].contains(density) ? .words : .icon,
                         statuses: total ? [] : statuses, myTurnTotal: total ? statuses.map(\.count).reduce(0, +) : nil)
}

/// A team's line in words, whatever density is drawn. The numbers are the line's own: the rows it lists, by the
/// state each shows (R11a L2, L6). `멈춤 N 숨김` counts the workers it does not list.
func teamLineWords(_ team: TeamGroup) -> [String] {
    let parts = teamLine(team, .full)
    return ["워커 \(parts.workers)"]
        + [myTurnText(teamLine(team, .myTurnTotal).myTurnTotal ?? 0)].compactMap { $0 }
        + (parts.decisions > 0 ? ["결정 대기 \(parts.decisions)"] : [])
        + parts.statuses.map { "\(badgeLabel($0.badge)) \($0.count)" }
        + (team.stopped > 0 ? ["멈춤 \(team.stopped) 숨김"] : [])
}

/// What VoiceOver reads for a team's line: the name, then the line in words.
func teamLineLabel(_ team: TeamGroup) -> String { ([team.name] + teamLineWords(team)).joined(separator: ", ") }

func teamLineTooltip(_ team: TeamGroup) -> String {
    ((team.group.map { ["그룹 \($0)"] } ?? []) + teamLineWords(team)).joined(separator: " · ")
}

/// The team an arrow key folds or unfolds in the running list (R11 L5): the selected worker's own, and with none to
/// unfold there, → takes the first folded team down the list.
func teamForArrow(unfold: Bool, selection: RowID?, teams: [TeamGroup], expanded: (String) -> Bool) -> String? {
    let own = teams.first { $0.rows.contains { $0.id == selection } }?.name
    if let own, expanded(own) != unfold { return own }
    return unfold ? teams.first { !expanded($0.name) }?.name : nil
}

/// `세션 N · 작업 중 N · 내 차례 N`, zero segments left out.
func sessionSummaryLine(_ rows: [LiveRow]) -> String {
    let working = rows.filter { $0.badge == .working }.count
    return (["세션 \(rows.count)"] + (working > 0 ? ["작업 중 \(working)"] : []) + [myTurnText(rows.filter(\.session.myTurn).count)].compactMap { $0 })
        .joined(separator: " · ")
}

func badgeLabel(_ b: RowBadge) -> String {
    switch b {
    case .waitingForUser(let m): m.map { "답 기다림 \(duration(minutes: $0))" } ?? "답 기다림"
    case .permission(let m): m.map { "권한 요청 \(duration(minutes: $0))" } ?? "권한 요청"
    case .working: "작업 중"
    case .done(let m): m.map { "\(duration(minutes: $0)) 전 완료" } ?? "완료"
    case .idle(let m): m.map { "쉬는 중 \(duration(minutes: $0))" } ?? "쉬는 중"
    }
}

/// `N분` under an hour, `N시간 M분` under a day, then `N일 M시간`; a zero second part is left out.
func duration(minutes m: Int) -> String {
    func join(_ big: Int, _ bigUnit: String, _ small: Int, _ smallUnit: String) -> String {
        small == 0 ? "\(big)\(bigUnit)" : "\(big)\(bigUnit) \(small)\(smallUnit)"
    }
    if m < 60 { return "\(m)분" }
    if m < 1440 { return join(m / 60, "시간", m % 60, "분") }
    return join(m / 1440, "일", (m % 1440) / 60, "시간")
}

/// The largest unit only: `N분`, `N시간`, `N일`.
func shortDuration(minutes m: Int) -> String {
    m < 60 ? "\(m)분" : m < 1440 ? "\(m / 60)시간" : "\(m / 1440)일"
}

/// `방금` under a minute, then `N분 전`, `N시간 전`, `어제`, `N일 전`; '' when the time is unknown.
func relativeTime(_ iso: String?, now: Date) -> String {
    guard let t = date(iso) else { return "" }
    let s = Int(now.timeIntervalSince(t))
    if s < 60 { return "방금" }
    if s < 3600 { return "\(s / 60)분 전" }
    if s < 86400 { return "\(s / 3600)시간 전" }
    let d = s / 86400
    return d == 1 ? "어제" : "\(d)일 전"
}

/// Local `yyyy-MM-dd HH:mm`, for tooltips.
func fullTime(_ iso: String?) -> String {
    guard let t = date(iso) else { return "" }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: t)
}

func historyTitle(_ h: HistorySession) -> String {
    h.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? basename(h.workspace) : h.title
}

func agentName(_ a: AgentKind) -> String { a == .claude ? "Claude" : "Codex" }

/// `에이전트 · workspace · branch · 실행 중|종료됨`.
func historySubtitle(_ h: HistorySession) -> String {
    [agentName(h.agent), basename(h.workspace), h.branch.flatMap { $0.isEmpty ? nil : $0 }, h.live ? "실행 중" : "종료됨"]
        .compactMap { $0 }.joined(separator: " · ")
}

func historyTooltip(_ h: HistorySession, home: String) -> String {
    [fullTime(h.updatedAt), abbreviate(h.workspace, home: home), transcriptSizeLabel(h.size).map { "크기 \($0)" } ?? ""]
        .filter { !$0.isEmpty }.joined(separator: "\n")
}

/// A row's context menu, top to bottom; what does not apply to the row is left out, not dimmed.
enum RowMenuItem: Hashable {
    case focus, diff, copyPath, copyResume, resume

    var title: String {
        switch self {
        case .focus: "터미널로 이동"
        case .diff: "변경 보기"
        case .copyPath: "폴더 경로 복사"
        case .copyResume: "resume 명령 복사"
        case .resume: "이어서 실행"
        }
    }
}

/// The menu of a sidebar row.
func rowMenuItems(_ id: RowID, in model: SidebarModel) -> [RowMenuItem] {
    switch id {
    case .live:
        guard let row = model.liveRows.first(where: { $0.id == id }) else { return [] }
        return [.focus, .diff, .copyPath] + (row.matched == nil ? [] : [.copyResume])
    case .history: return [.resume, .copyResume]
    case .dashboard: return []
    }
}

/// The line the context menu copies: back to the workspace, then the resume command.
func resumeCopyText(_ h: HistorySession) -> String {
    let dir = "'" + h.workspace.replacingOccurrences(of: "'", with: "'\\''") + "'"
    return "cd \(dir) && \(h.resumeCommand.joined(separator: " "))"
}

func abbreviate(_ path: String, home: String) -> String {
    if path == home { return "~" }
    return !home.isEmpty && path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

private func date(_ iso: String?) -> Date? {
    parseISO(iso).map { Date(timeIntervalSince1970: $0 / 1000) }
}

private func minutes(from: String?, to: String) -> Int? {
    guard let a = parseISO(from), let b = parseISO(to) else { return nil }
    return max(0, Int(((b - a) / 60000).rounded(.down)))
}

/// The sidebar's two lists, running sessions above history, and the line between them.
enum SidebarSplit {
    /// The running list's share of the height, kept across launches.
    static let storageKey = "sidebarSplitRatio"
    static let standard = 0.6
    /// Each list's least height: the top one holds the "실행 중" bar, a group header and about two rows at the
    /// standard font size; the history one its filter header and about two rows.
    static let minHeight: CGFloat = 140
    static let line: CGFloat = 1
    /// Room past each list's last row, so a list scrolled to its end shows that row whole (T124, D11).
    static let endMargin: CGFloat = 8

    /// The two lists' heights in a sidebar `total` tall. A stored value outside 0...1 is the standard share;
    /// a sidebar too short for two minimums shares by the ratio alone.
    static func heights(total: CGFloat, ratio: Double) -> (top: CGFloat, bottom: CGFloat) {
        let room = max(0, total - line)
        let share = ratio.isFinite && (0...1).contains(ratio) ? ratio : standard
        var top = (room * share).rounded()
        if room >= 2 * minHeight { top = min(max(top, minHeight), room - minHeight) }
        return (top, room - top)
    }

    /// The share that gives the top list `top` points, for a drag measured from where the line was.
    static func ratio(top: CGFloat, total: CGFloat) -> Double {
        let room = total - line
        return room > 0 ? Double(min(max(top, 0), room) / room) : standard
    }
}

/// Which of the two lists a row belongs to; the board keeps one selection across both.
enum SidebarPane {
    case live, history

    /// The board's selection as this list shows it: nil when the selected row is in the other list.
    func shown(_ selection: RowID) -> RowID? { holds(selection) ? selection : nil }

    private func holds(_ id: RowID) -> Bool {
        switch id {
        case .dashboard, .live: self == .live
        case .history: self == .history
        }
    }
}

/// The count on the sidebar's 내 차례 line and on the menu bar icon: the queue's cards, so a stopped worker
/// that was waiting is in neither.
func myTurnShown(_ board: Board, taskBoards: [String: TaskBoardStatus] = [:]) -> Int {
    sidebarModel(board: board, history: [], query: "", filter: .claude, historyLimit: 0, home: "").queue.count
        + waitingDecisions(board, taskBoards: taskBoards).count
}

/// A decision waiting for the user on a running team's board: it is the user's turn too (T147).
struct WaitingDecision: Equatable {
    var team: String
    var decision: BoardDecision
}

/// The open decisions of the running teams that keep a board, in the order asked.
func waitingDecisions(_ board: Board, taskBoards: [String: TaskBoardStatus]) -> [WaitingDecision] {
    board.teams.filter(\.hasTaskBoard)
        .flatMap { t in (taskBoards[t.name].map(openDecisions) ?? []).map { WaitingDecision(team: t.name, decision: $0) } }
        .sorted { ($0.decision.brief.askedAt ?? "", $0.team, $0.decision.id) < ($1.decision.brief.askedAt ?? "", $1.team, $1.decision.id) }
}

/// The decisions to tell the user about after a read, each team's in the order asked (T147, T148).
func decisionsToNotify(seen: inout SeenDecisions, next: [String: TaskBoardStatus]) -> [WaitingDecision] {
    next.keys.sorted().flatMap { team in seen.news(next[team]!, team: team).map { WaitingDecision(team: team, decision: $0) } }
        .sorted { ($0.decision.brief.askedAt ?? "", $0.team) < ($1.decision.brief.askedAt ?? "", $1.team) }
}

/// One place the board shows: a sidebar row. Task boards are windows of their own (T86), never a screen here.
struct Screen: Hashable {
    var row: RowID

    init(_ row: RowID) { self.row = row }
}

/// The board window's title and subtitle for `screen`: what is shown, then its team and state.
func screenTitle(_ screen: Screen, model: SidebarModel, history: [HistorySession], usage: UsageReport) -> (title: String, subtitle: String) {
    switch screen.row {
    case .dashboard:
        return ("대시보드", dashboardSubtitle(usage))
    case .live:
        guard let row = model.liveRows.first(where: { $0.id == screen.row }) else { break }
        return (row.title, [row.teamName, badgeLabel(row.badge)].compactMap { $0 }.joined(separator: " · "))
    case .history(let path):
        guard let h = (model.history + history).first(where: { $0.transcriptPath == path }) else { break }
        return (historyTitle(h), [h.member?.team ?? agentName(h.agent), h.live ? "실행 중" : "종료됨"].joined(separator: " · "))
    }
    return ("Control Tower", "")
}

/// The board's back and forward (⌘[ ⌘]): every screen gone to, a browser's history. Going somewhere new from
/// the middle drops the screens ahead.
struct ScreenHistory: Equatable {
    static let limit = 100
    private(set) var screens = [Screen(.dashboard)]
    private(set) var index = 0

    var current: Screen { screens[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < screens.count - 1 }

    mutating func go(_ screen: Screen) {
        guard screen != current else { return }
        screens = Array(screens[...index].suffix(Self.limit - 1)) + [screen]
        index = screens.count - 1
    }

    mutating func back() { if canGoBack { index -= 1 } }
    mutating func forward() { if canGoForward { index += 1 } }
}
