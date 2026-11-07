import Foundation
import TowerCore

// The sidebar's data, projected from a board and the history list. No view code, so the
// grouping, wording and search are testable.

enum RowID: Hashable {
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

    /// Counted in a group header's `N 대기`: waiting on me, a permission prompt, or idle.
    var waits: Bool {
        switch self {
        case .waitingForUser, .permission, .idle: true
        case .working, .done: false
        }
    }
}

enum StatusIcon: Equatable {
    case spinner, waiting, alert, check, idle
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
    /// The state reason or last message, newlines kept.
    var message: String
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
    /// The header's tooltip.
    var summary: String
    /// Workers waiting on me (permission and idle included), shown on the header.
    var waiting: Int
    var rows: [LiveRow]
}

/// Sessions outside teams, one group per agent.
struct AgentGroup: Equatable {
    var agent: AgentKind
    /// The header's tooltip.
    var summary: String
    var waiting: Int
    var rows: [LiveRow]
}

struct SidebarModel: Equatable {
    var teams: [TeamGroup]
    /// Claude Code, then Codex; an agent with no session has no group.
    var agents: [AgentGroup]
    /// One page or more of the filtered history as the list shows it, running sessions listed above left out.
    var historyItems: [HistoryItem]
    /// Filtered history lines past `historyItems`.
    var historyRemaining: Int
    /// Every live row waiting on me, search ignored, longest wait first; a row without a start time last.
    var queue: [LiveRow]
    /// Live rows at work, search ignored: the empty queue's note.
    var working: Int

    var liveRows: [LiveRow] { teams.flatMap(\.rows) + agents.flatMap(\.rows) }
    /// The page's my-team teams and single terminals, apart, each newest first.
    var historyTeams: [TeamHistory] {
        historyItems.compactMap { if case .team(let t) = $0 { t } else { nil } }
    }
    var historySingles: [HistorySession] {
        historyItems.compactMap { if case .session(let h) = $0 { h } else { nil } }
    }
    /// Every session in `historyItems`, in list order.
    var history: [HistorySession] {
        historyItems.flatMap { item -> [HistorySession] in
            switch item {
            case .session(let h): [h]
            case .team(let t): t.sessions
            }
        }
    }
    /// The running list's areas, top to bottom: one my-team area over all its teams, then one per agent.
    var liveAreas: [LineKind] { (teams.isEmpty ? [] : [.team]) + agents.map { .agent($0.agent) } }
}

/// Team sections folded in the sidebar, by team name; every team is open by default.
/// Stored as a JSON array, so any name round-trips; a team that stops running keeps its name here, matched by nothing.
struct CollapsedTeams: Equatable {
    static let storageKey = "collapsedTeams"

    private(set) var names: Set<String>

    init(stored: String) {
        names = Set((try? JSONDecoder().decode([String].self, from: Data(stored.utf8))) ?? [])
    }

    var stored: String { String(decoding: (try? JSONEncoder().encode(names.sorted())) ?? Data(), as: UTF8.self) }

    /// A search shows every team's matches, folded or not; the folds return once it is cleared.
    func isExpanded(_ team: String, query: String) -> Bool { isSearching(query) || !names.contains(team) }

    /// A disclosure click during a search changes nothing: the section stays open for the search.
    mutating func set(_ team: String, expanded: Bool, query: String) {
        guard !isSearching(query) else { return }
        if expanded { names.remove(team) } else { names.insert(team) }
    }

    /// A click on the team's name: the same fold its disclosure would make.
    mutating func toggle(_ team: String, query: String) { set(team, expanded: !isExpanded(team, query: query), query: query) }

    /// Opens the team holding a row selected from outside the sidebar (menu bar, queue card).
    mutating func reveal(_ id: RowID, in board: Board) {
        guard case .live(let rowID) = id,
              let team = board.teams.first(where: { $0.workers.contains { $0.session.rowID == rowID } }) else { return }
        names.remove(team.name)
    }

    private func isSearching(_ query: String) -> Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The teams with a live worker: a team named like one of these cannot be started again.
func runningTeams(_ board: Board) -> Set<String> {
    Set(board.teams.filter { $0.workers.contains(where: \.alive) }.map(\.name))
}

/// One line of the history list: a session alone, or the ended sessions of one my-team team.
enum HistoryItem: Equatable {
    case session(HistorySession)
    case team(TeamHistory)

    var id: String {
        switch self {
        case .session(let h): h.transcriptPath
        case .team(let t): "team:\(t.run.team)@\(t.run.start.map { String(Int($0)) } ?? "?")"
        }
    }
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

/// One run of a my-team team in the history: its ended sessions, found by the prompt my-team typed into each worker first.
struct TeamHistory: Equatable {
    var run: TeamRun
    /// Newest first.
    var sessions: [HistorySession]
    /// The team runs now: there is nothing to resume.
    var running: Bool
}

/// `sessions` (newest first) as list lines: a team run's sessions gathered on one line, where its newest one was.
func historyLines(_ sessions: [HistorySession], runs: [String: TeamRun], running: Set<String>) -> [HistoryItem] {
    var lines: [HistoryItem] = []
    var runLine: [TeamRun: Int] = [:]
    for h in sessions {
        guard let run = runs[h.transcriptPath] else {
            lines.append(.session(h))
            continue
        }
        if let i = runLine[run], case .team(var t) = lines[i] {
            t.sessions.append(h)
            lines[i] = .team(t)
        } else {
            runLine[run] = lines.count
            lines.append(.team(TeamHistory(run: run, sessions: [h], running: running.contains(run.team))))
        }
    }
    return lines
}

/// What the history list shows: ended my-team teams, or single terminals of one agent. A team's workers are
/// never single terminals, whatever agent they ran.
enum HistoryFilter: Hashable {
    case team, claude, codex

    func shows(_ h: HistorySession) -> Bool {
        switch self {
        case .team: h.member != nil
        case .claude: h.member == nil && h.agent == .claude
        case .codex: h.member == nil && h.agent == .codex
        }
    }
}

let historyPageSize = 30

func sidebarModel(board: Board, history: [HistorySession], query: String, filter: HistoryFilter, historyLimit: Int,
                  home: String) -> SidebarModel {
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
            let reason = w.stateFile?.reason ?? ""
            return LiveRow(id: .live(w.session.rowID), session: w.session, worker: w, teamName: team.name,
                           title: w.cardName, folder: basename(w.session.cwd), path: abbreviate(w.session.cwd, home: home),
                           message: reason.isEmpty ? w.lastAssistant : reason,
                           badge: badge, matched: w.transcript.flatMap { byTranscript[$0] })
        }
        listed.formUnion(rows.compactMap(\.session.transcript))
        all += rows
        let teamHit = hit([team.name])
        let shown = rows.filter { teamHit || matches($0) }
        if q.isEmpty || !shown.isEmpty {
            teams.append(TeamGroup(name: team.name, summary: teamSummaryLine(team), waiting: rows.filter(\.badge.waits).count,
                                   rows: shown))
        }
    }

    var agents: [AgentGroup] = []
    for agent in [AgentKind.claude, .codex] {
        let rows = sortCards(board.loose.filter { $0.agent == agent }).map { s in
            let matched = s.transcript.flatMap { byTranscript[$0] }
            return LiveRow(id: .live(s.rowID), session: s, worker: nil, teamName: nil,
                           title: matched.map(historyTitle) ?? basename(s.cwd), folder: basename(s.cwd),
                           path: abbreviate(s.cwd, home: home),
                           message: s.lastAssistant.isEmpty ? s.lastUser : s.lastAssistant,
                           badge: badge(displayState(s), at: board.at) ?? .idle(minutes: nil), matched: matched)
        }
        all += rows
        let agentHit = hit([LineKind.agent(agent).text])
        let shown = rows.filter { agentHit || matches($0) }
        if !shown.isEmpty {
            agents.append(AgentGroup(agent: agent, summary: sessionSummaryLine(rows), waiting: rows.filter(\.badge.waits).count,
                                     rows: shown))
        }
    }

    let past = history.filter { h in
        !listed.contains(h.transcriptPath)
            && filter.shows(h)
            && hit([h.title, h.workspace, h.branch, h.member?.team])
    }
    let items = historyLines(past, runs: teamRuns(history), running: runningTeams(board))
    let queue = all.filter(\.session.myTurn).enumerated().sorted { a, b in
        switch (parseISO(a.element.session.since), parseISO(b.element.session.since)) {
        case let (x?, y?) where x != y: x < y
        case (_?, nil): true
        case (nil, _?): false
        default: a.offset < b.offset
        }
    }.map(\.element)
    return SidebarModel(teams: teams, agents: agents,
                        historyItems: Array(items.prefix(historyLimit)), historyRemaining: max(0, items.count - historyLimit),
                        queue: queue, working: all.filter { $0.badge == .working }.count)
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
        var waiting: Int
        /// The row the board selects for this line: a worker waiting on me, else the first; nil when none is listed.
        var select: RowID?
    }

    /// A sidebar agent group cut to the sessions open in a terminal.
    struct AgentLine: Equatable {
        var agent: AgentKind
        /// Of the rows listed here.
        var waiting: Int
        var rows: [LiveRow]
    }

    var teams: [TeamLine]
    /// Never holds a line without rows.
    var agents: [AgentLine]

    var isEmpty: Bool { teams.isEmpty && agents.isEmpty }
}

func menuModel(_ board: Board, history: [HistorySession], home: String) -> MenuModel {
    // no history page: the dropdown shows running sessions only
    let side = sidebarModel(board: board, history: history, query: "", filter: .team, historyLimit: 0, home: home)
    let attached = Set(board.teams.filter(\.attached).map(\.name))
    return MenuModel(
        teams: side.teams.filter { attached.contains($0.name) }.map { t in
            MenuModel.TeamLine(name: t.name, waiting: t.waiting, select: (t.rows.first { $0.session.myTurn } ?? t.rows.first)?.id)
        },
        agents: side.agents.compactMap { g in
            let rows = g.rows.filter(\.session.inTerminal)
            return rows.isEmpty ? nil : MenuModel.AgentLine(agent: g.agent, waiting: rows.filter(\.badge.waits).count, rows: rows)
        })
}

/// `N 대기`; nil at 0.
func waitingText(_ n: Int) -> String? { n > 0 ? "\(n) 대기" : nil }

/// A team header's counts, of the rows it lists (so a search's matches): "워커 3 · 1 대기".
func teamHeaderDetail(_ team: TeamGroup) -> String {
    (["워커 \(team.rows.count)"] + [waitingText(team.rows.filter(\.badge.waits).count)].compactMap { $0 }).joined(separator: " · ")
}

func teamSummaryLine(_ team: Team) -> String {
    let (total, by) = stateCounts(team)
    let waiting = by[.waitingForUser, default: 0] + by[.idle, default: 0]
    var parts = ["워커 \(total)"]
    if let n = by[.working], n > 0 { parts.append("작업 중 \(n)") }
    if waiting > 0 { parts.append("대기 \(waiting)") }
    if let n = by[.done], n > 0 { parts.append("완료 \(n)") }
    if let n = by[.stopped], n > 0 { parts.append("멈춤 \(n) 숨김") }
    return parts.joined(separator: " · ")
}

/// `세션 N · 작업 중 N · 대기 N`, zero segments left out.
func sessionSummaryLine(_ rows: [LiveRow]) -> String {
    let working = rows.filter { $0.badge == .working }.count, waiting = rows.filter(\.badge.waits).count
    return (["세션 \(rows.count)"] + (working > 0 ? ["작업 중 \(working)"] : []) + (waiting > 0 ? ["대기 \(waiting)"] : []))
        .joined(separator: " · ")
}

func badgeLabel(_ b: RowBadge) -> String {
    switch b {
    case .waitingForUser(let m): m.map { "사용자 대기 \(duration(minutes: $0))" } ?? "사용자 대기"
    case .permission(let m): m.map { "권한 요청 \(duration(minutes: $0))" } ?? "권한 요청"
    case .working: "작업 중"
    case .done(let m): m.map { "\(duration(minutes: $0)) 전 완료" } ?? "완료"
    case .idle(let m): m.map { "대기 \(duration(minutes: $0))" } ?? "대기"
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
    [fullTime(h.updatedAt), abbreviate(h.workspace, home: home)].filter { !$0.isEmpty }.joined(separator: "\n")
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
    func shown(_ selection: RowID?) -> RowID? { selection.flatMap { holds($0) ? $0 : nil } }

    /// The board's selection after this list sets `new`: a pick replaces any selection, and a list clearing
    /// its own selection does not clear the other list's.
    func select(_ new: RowID?, current: RowID?) -> RowID? {
        new ?? (shown(current) == nil ? current : nil)
    }

    private func holds(_ id: RowID) -> Bool {
        switch id {
        case .live: self == .live
        case .history: self == .history
        }
    }
}
