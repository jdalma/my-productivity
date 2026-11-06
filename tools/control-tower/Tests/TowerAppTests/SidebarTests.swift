import Foundation
import Testing
import TowerCore
@testable import TowerApp

private let at = "2026-11-02T10:00:00.000Z"
private let ago10 = "2026-11-02T09:50:00.000Z"

private func session(_ handle: String, agent: AgentKind = .claude, cwd: String = "/Users/me/proj", status: Status = .wait,
                     myTurn: Bool = false, since: String? = ago10, permission: Bool = false,
                     transcript: String? = nil, lastUser: String = "", lastAssistant: String = "") -> Session {
    Session(handle: handle, agent: agent, pid: 1, cwd: cwd, startedAt: nil, status: status, myTurn: myTurn, since: since,
            permissionPrompt: permission, title: "", tmux: nil, transcript: transcript,
            lastUser: lastUser, lastAssistant: lastAssistant, termProgram: nil)
}

private func worker(_ name: String, session: Session = session("pane:t:%1"), alive: Bool = true,
                    state: StateFile? = nil, role: String? = "worker") -> Worker {
    Worker(session: session, workerName: name, role: role, description: "", paneId: "%1", alive: alive, spool: 0,
           inbox: 0, sentPending: 0, oldestPendingAt: nil, stateFile: state)
}

private func team(_ name: String, _ workers: [Worker]) -> Team {
    Team(name: name, sessionName: "my-team-\(name)", startedAt: nil, attached: true, workers: workers)
}

private func history(_ title: String, agent: AgentKind = .claude, workspace: String = "/Users/me/proj", branch: String? = "main",
                     path: String = "/t/a.jsonl", live: Bool = false) -> HistorySession {
    HistorySession(id: "id", agent: agent, title: title, workspace: workspace, branch: branch, createdAt: nil,
                   updatedAt: ago10, lastPrompt: nil, transcriptPath: path, live: live, resumeCommand: ["claude", "--resume", "id"])
}

private func model(_ board: Board, history: [HistorySession] = [], query: String = "", filter: AgentFilter = .all,
                   historyLimit: Int = historyPageSize) -> SidebarModel {
    sidebarModel(board: board, history: history, query: query, filter: filter, historyLimit: historyLimit, home: "/Users/me")
}

@Test func teamSummaryCountsStoppedAndOmitsZeroSegments() {
    let done = StateFile(state: "done", reason: nil, updatedAt: ago10)
    let board = Board(at: at, teams: [team("t", [
        worker("a", session: session("pane:t:%1", status: .busy)),
        worker("b", session: session("pane:t:%2", myTurn: true)),
        worker("c", session: session("pane:t:%3"), state: done),
        worker("d", session: session("pane:t:%4"), alive: false),
    ])], loose: [])
    let g = model(board).teams[0]
    #expect(g.summary == "워커 4 · 작업 중 1 · 대기 1 · 완료 1 · 멈춤 1 숨김")
    #expect(g.rows.map(\.title) == ["b", "a", "c"])
}

@Test func summaryOmitsEmptySegments() {
    let board = Board(at: at, teams: [team("t", [worker("a", session: session("pane:t:%1", status: .busy))])], loose: [])
    #expect(model(board).teams[0].summary == "워커 1 · 작업 중 1")
}

@Test func permissionPromptOverridesWorkerBadgeAndDeadWorkerIsDropped() {
    let board = Board(at: at, teams: [team("t", [
        worker("a", session: session("pane:t:%1", status: .busy, permission: true)),
        worker("b", session: session("pane:t:%2", permission: true), alive: false),
    ])], loose: [])
    let rows = model(board).teams[0].rows
    #expect(rows.count == 1)
    #expect(rows[0].badge == .permission(minutes: 10))
}

@Test func workerBadgesCarryMinutes() {
    let board = Board(at: at, teams: [team("t", [worker("a", session: session("pane:t:%1", myTurn: true))])], loose: [])
    #expect(model(board).teams[0].rows[0].badge == .waitingForUser(minutes: 10))
}

@Test func workerMessagePrefersStateReason() {
    let sf = StateFile(state: "working", reason: "writing tests", updatedAt: nil)
    let board = Board(at: at, teams: [team("t", [
        worker("a", session: session("pane:t:%1", lastAssistant: "hello\nworld"), state: sf),
        worker("b", session: session("pane:t:%2", lastAssistant: "hello\nworld")),
    ])], loose: [])
    #expect(model(board).teams[0].rows.map(\.message) == ["writing tests", "hello\nworld"])
}

@Test func looseSessionsGroupByAgentClaudeFirst() {
    let board = Board(at: at, teams: [], loose: [
        session("pid:1", cwd: "/Users/me/proj", lastUser: "hi"),
        session("pid:2", agent: .codex, cwd: "/Users/me/proj", status: .busy, lastAssistant: "ok"),
        session("pid:3", cwd: "/opt/other", myTurn: true),
    ])
    let groups = model(board).agents
    #expect(groups.map(\.agent) == [.claude, .codex])
    #expect(groups[0].rows.map(\.session.handle) == ["pid:3", "pid:1"])
    #expect(groups[0].rows.map(\.folder) == ["other", "proj"])
    #expect(groups[0].rows.map(\.path) == ["/opt/other", "~/proj"])
    #expect(groups[0].rows[0].badge == .waitingForUser(minutes: 10))
    #expect(groups[0].rows[1].message == "hi")
    #expect(groups[1].rows.map(\.folder) == ["proj"])
    #expect(groups[1].rows[0].badge == .working)
}

@Test func anAgentWithNoSessionHasNoGroup() {
    let board = Board(at: at, teams: [], loose: [session("pid:1"), session("pid:2", cwd: "/Users/me/b")])
    #expect(model(board).agents.map(\.agent) == [.claude])
    #expect(model(Board(at: at, teams: [], loose: [])).agents.isEmpty)
}

@Test func searchingAnAgentNameListsItsWholeGroup() {
    let board = Board(at: at, teams: [], loose: [
        session("pid:1", cwd: "/Users/me/api"),
        session("pid:2", agent: .codex, cwd: "/Users/me/web"),
        session("pid:3", agent: .codex, cwd: "/Users/me/cli"),
    ])
    let codex = model(board, query: "Codex").agents
    #expect(codex.map(\.agent) == [.codex])
    #expect(codex[0].rows.count == 2)
    let byFolder = model(board, query: "web").agents
    #expect(byFolder.map(\.agent) == [.codex])
    #expect(byFolder[0].rows.map(\.folder) == ["web"])
}

@Test func agentGroupWaitingFollowsTheTeamRule() {
    let board = Board(at: at, teams: [], loose: [
        session("pid:1", myTurn: true),
        session("pid:2", permission: true),
        session("pid:3"),
        session("pid:4", status: .busy),
        session("pid:5", agent: .codex, status: .busy),
    ])
    let groups = model(board).agents
    #expect(groups.map(\.waiting) == [3, 0])
    #expect(groups.map { waitingText($0.waiting) } == ["3 대기", nil])
    #expect(groups[0].summary == "세션 4 · 작업 중 1 · 대기 3")
    #expect(groups[1].summary == "세션 1 · 작업 중 1")
}

@Test func searchFiltersLiveRowsAndHistory() {
    let board = Board(at: at, teams: [
        team("alpha", [worker("builder", session: session("pane:a:%1"))]),
        team("beta", [worker("other", session: session("pane:b:%1"))]),
    ], loose: [session("pid:9", cwd: "/Users/me/zebra")])
    let hist = [history("alpha · builder", path: "/t/1"), history("misc", workspace: "/Users/me/zebra", branch: "feat/x", path: "/t/2")]

    let byTeam = model(board, history: hist, query: "ALPHA")
    #expect(byTeam.teams.map(\.name) == ["alpha"])
    #expect(byTeam.agents.isEmpty)
    #expect(byTeam.history.map(\.transcriptPath) == ["/t/1"])

    let byCwd = model(board, history: hist, query: "zebra")
    #expect(byCwd.teams.isEmpty)
    #expect(byCwd.agents.flatMap(\.rows).map(\.folder) == ["zebra"])
    #expect(byCwd.history.map(\.transcriptPath) == ["/t/2"])

    #expect(model(board, history: hist, query: "feat/x").history.count == 1)
    #expect(model(board, history: hist, query: "builder").teams[0].rows.map(\.title) == ["builder"])
}

@Test func liveRowBranchComesFromMatchingHistory() {
    let board = Board(at: at, teams: [], loose: [session("pid:1", transcript: "/t/1")])
    let m = model(board, history: [history("x", branch: "feat/live", path: "/t/1", live: true)], query: "feat/live")
    #expect(m.agents.count == 1)
    #expect(m.agents[0].rows[0].matched?.branch == "feat/live")
}

@Test func historyLeavesOutSessionsListedAbove() {
    let board = Board(at: at, teams: [team("t", [
        worker("a", session: session("pane:t:%1", transcript: "/t/1")),
        worker("b", session: session("pane:t:%2", transcript: "/t/2"), alive: false),
    ])], loose: [session("pid:3", transcript: "/t/3")])
    let hist = [history("a", path: "/t/1", live: true), history("b", path: "/t/2", live: true),
                history("c", workspace: "/Users/me/zebra", path: "/t/3", live: true), history("d", path: "/t/4")]
    #expect(model(board, history: hist).history.map(\.transcriptPath) == ["/t/2", "/t/4"])
    // a search that hides a running row still keeps its session out of history
    let searched = model(board, history: hist, query: "zebra")
    #expect(searched.agents.isEmpty)
    #expect(searched.history.isEmpty)
}

@Test func historyShowsAPageAndCountsTheRest() {
    let board = Board(at: at, teams: [], loose: [])
    let many = (0..<75).map { history("h\($0)", path: "/t/\($0)") }

    let first = model(board, history: many)
    #expect(first.history.map(\.transcriptPath) == (0..<30).map { "/t/\($0)" })
    #expect(first.historyRemaining == 45)

    let more = model(board, history: many, historyLimit: historyPageSize * 2)
    #expect(more.history.count == 60)
    #expect(more.historyRemaining == 15)

    let exact = model(board, history: Array(many.prefix(30)))
    #expect(exact.history.count == 30)
    #expect(exact.historyRemaining == 0)
}

@Test func historyPagesAfterFilterAndSearch() {
    let board = Board(at: at, teams: [], loose: [])
    let mixed = (0..<40).map { history("h\($0)", agent: $0 % 2 == 0 ? .claude : .codex, path: "/t/\($0)") }
    let claude = model(board, history: mixed, filter: .claude)
    #expect(claude.history.count == 20)
    #expect(claude.historyRemaining == 0)
    #expect(model(board, history: mixed, query: "h3").historyRemaining == 0)
}

@Test func agentFilterAndEmptyTitleFallback() {
    let board = Board(at: at, teams: [], loose: [])
    let hist = [history("", workspace: "/Users/me/proj", path: "/t/1"), history("c", agent: .codex, path: "/t/2")]
    #expect(model(board, history: hist, filter: .claude).history.map(\.transcriptPath) == ["/t/1"])
    #expect(model(board, history: hist, filter: .codex).history.map(\.transcriptPath) == ["/t/2"])
    #expect(model(board, history: hist).history.count == 2)
    #expect(historyTitle(hist[0]) == "proj")
    #expect(historyTitle(hist[1]) == "c")
}

@Test func historySubtitleAndResumeText() {
    #expect(historySubtitle(history("t", branch: "main")) == "Claude · proj · main · 종료됨")
    #expect(historySubtitle(history("t", agent: .codex, branch: nil, live: true)) == "Codex · proj · 실행 중")
    #expect(resumeCopyText(history("t", workspace: "/a/it's")) == "cd '/a/it'\\''s' && claude --resume id")
}

@Test func relativeTimeBuckets() {
    let now = Date(timeIntervalSince1970: 1_000_000_000)
    func ago(_ s: Int) -> String {
        relativeTime(isoOf(now.addingTimeInterval(-Double(s))), now: now)
    }
    #expect(ago(30) == "방금")
    #expect(ago(5 * 60) == "5분 전")
    #expect(ago(3 * 3600) == "3시간 전")
    #expect(ago(30 * 3600) == "어제")
    #expect(ago(3 * 86400 + 100) == "3일 전")
    #expect(relativeTime(nil, now: now) == "")
}

private func isoOf(_ d: Date) -> String { d.formatted(.iso8601) }

@Test func badgeLabels() {
    #expect(badgeLabel(.waitingForUser(minutes: 12)) == "사용자 대기 12분")
    #expect(badgeLabel(.waitingForUser(minutes: nil)) == "사용자 대기")
    #expect(badgeLabel(.working) == "작업 중")
    #expect(badgeLabel(.done(minutesAgo: 3)) == "3분 전 완료")
    #expect(badgeLabel(.idle(minutes: 7)) == "대기 7분")
    #expect(badgeLabel(.idle(minutes: nil)) == "대기")
}

@Test func abbreviatesHome() {
    #expect(abbreviate("/Users/me", home: "/Users/me") == "~")
    #expect(abbreviate("/Users/me/a", home: "/Users/me") == "~/a")
    #expect(abbreviate("/Users/mex/a", home: "/Users/me") == "/Users/mex/a")
}

@Test func aDoneWorkerOnAPermissionPromptIsWaitingInBothRowAndSummary() {
    let done = StateFile(state: "done", reason: nil, updatedAt: ago10)
    let board = Board(at: at, teams: [team("t", [
        worker("a", session: session("pane:t:%1", myTurn: true, permission: true), state: done),
        worker("b", session: session("pane:t:%2", myTurn: true), state: done),
    ])], loose: [])
    let g = model(board).teams[0]
    #expect(g.rows.first { $0.title == "a" }?.badge == .permission(minutes: 10))
    #expect(g.rows.first { $0.title == "b" }?.badge == .done(minutesAgo: 10))
    #expect(g.summary == "워커 2 · 대기 1 · 완료 1")
}

@Test func theDropdownIsTheSidebarsTeamLinesAndIndividualRows() {
    let done = StateFile(state: "done", reason: nil, updatedAt: ago10)
    let board = Board(at: at, teams: [
        team("t", [worker("a", session: session("pane:t:%1", status: .busy)),
                   worker("b", session: session("pane:t:%2", myTurn: true, permission: true), state: done),
                   worker("c", session: session("pane:t:%3"), alive: false)]),
        team("u", [worker("d", session: session("pane:u:%1", status: .busy))]),
    ], loose: [session("pid:8", cwd: "/Users/me/a"), session("pid:9", cwd: "/Users/me/b", myTurn: true),
               session("pid:7", agent: .codex, cwd: "/Users/me/a", status: .busy)])
    let side = model(board)
    let menu = menuModel(board, history: [], home: "/Users/me")

    #expect(menu.teams.map(\.name) == side.teams.map(\.name))
    // teams first, then the sidebar's agent groups in its order
    #expect(menu.agents.map(\.agent) == side.agents.map(\.agent))
    #expect(menu.agents.map(\.rows) == side.agents.map(\.rows))
    #expect(menu.agents.map(\.agent) == [.claude, .codex])
    #expect(menu.agents[0].rows.map(\.id) == [.live("pid:9#1"), .live("pid:8#1")])
    #expect(menu.agents[0].waiting == 2)
    #expect(menu.agents[1].rows.map(\.id) == [.live("pid:7#1")])
}

@Test func theDropdownListsOnlyWhatIsOpenInATerminal() {
    var detachedTeam = team("u", [worker("d", session: session("pane:u:%1"))])
    detachedTeam.attached = false
    var closed = session("pid:2", cwd: "/Users/me/closed")
    closed.inTerminal = false
    var closedCodex = session("pid:3", agent: .codex, cwd: "/Users/me/closed")
    closedCodex.inTerminal = false
    let board = Board(at: at, teams: [team("t", [worker("a", session: session("pane:t:%1"))]), detachedTeam],
                      loose: [session("pid:1", cwd: "/Users/me/open"), closed, closedCodex])
    let menu = menuModel(board, history: [], home: "/Users/me")
    #expect(menu.teams.map(\.name) == ["t"])
    // the codex group held only a closed session, so it is gone with its header
    #expect(menu.agents.map(\.agent) == [.claude])
    #expect(menu.agents[0].rows.map(\.folder) == ["open"])
    // the sidebar keeps all
    #expect(model(board).teams.map(\.name) == ["t", "u"])
    #expect(model(board).agents.map { $0.rows.map(\.folder) } == [["open", "closed"], ["closed"]])

    var allClosed = board
    allClosed.teams = [detachedTeam]
    allClosed.loose = [closed, closedCodex]
    #expect(menuModel(allClosed, history: [], home: "/Users/me").isEmpty)
}

@Test func aTeamLineSelectsItsWaitingWorkerElseItsFirst() {
    let board = Board(at: at, teams: [
        team("t", [worker("a", session: session("pane:t:%1", status: .busy)),
                   worker("b", session: session("pane:t:%2", myTurn: true))]),
        team("u", [worker("c", session: session("pane:u:%1", status: .busy)),
                   worker("d", session: session("pane:u:%2", status: .busy, since: "2026-11-02T09:00:00.000Z"))]),
        team("v", [worker("e", session: session("pane:v:%1"), alive: false)]),
    ], loose: [])
    let menu = menuModel(board, history: [], home: "/Users/me")
    #expect(menu.teams[0].select == .live("pane:t:%2#1"))
    #expect(menu.teams[1].select == model(board).teams[1].rows.first?.id)
    #expect(menu.teams[2].select == nil)
    #expect(menuModel(Board(at: at, teams: [], loose: []), history: [], home: "/Users/me").isEmpty)
}

@Test func durationsRollUpIntoHoursAndDays() {
    let cases = [(0, "0분"), (59, "59분"), (60, "1시간"), (61, "1시간 1분"), (1439, "23시간 59분"),
                 (1440, "1일"), (1500, "1일 1시간"), (2503, "1일 17시간")]
    for (m, text) in cases { #expect(duration(minutes: m) == text) }
    #expect(badgeLabel(.waitingForUser(minutes: 2503)) == "사용자 대기 1일 17시간")
    #expect(badgeLabel(.done(minutesAgo: 61)) == "1시간 1분 전 완료")
    #expect(badgeLabel(.idle(minutes: 60)) == "대기 1시간")
}

@Test func workerAndSessionRowsBothShowTheirFolder() {
    let board = Board(at: at, teams: [team("t", [worker("a", session: session("pane:t:%1", cwd: "/Users/me/src/api"))])],
                      loose: [session("pid:1", agent: .codex, cwd: "/Users/me/proj"), session("pid:2", cwd: "/Users/me/proj")])
    let m = model(board)
    let w = m.teams[0].rows[0]
    #expect(w.title == "a")
    #expect(w.folder == "api")
    #expect(w.path == "~/src/api")
    #expect(m.agents.map { $0.rows.map(\.folder) } == [["proj"], ["proj"]])
}

@Test func eachBadgeHasItsOwnIcon() {
    #expect(RowBadge.working.icon == .spinner)
    #expect(RowBadge.waitingForUser(minutes: 1).icon == .waiting)
    #expect(RowBadge.permission(minutes: 1).icon == .alert)
    #expect(RowBadge.done(minutesAgo: 1).icon == .check)
    #expect(RowBadge.idle(minutes: 1).icon == .idle)
}

@Test func elapsedShowsTheLargestUnitOnly() {
    let cases = [(0, "0분"), (59, "59분"), (60, "1시간"), (1439, "23시간"), (1440, "1일"), (2503, "1일")]
    for (m, text) in cases {
        #expect(RowBadge.waitingForUser(minutes: m).elapsed == text)
        #expect(RowBadge.done(minutesAgo: m).elapsed == text)
        #expect(RowBadge.idle(minutes: m).elapsed == text)
    }
    #expect(RowBadge.working.elapsed == "")
    #expect(RowBadge.waitingForUser(minutes: nil).elapsed == "")
    #expect(RowBadge.idle(minutes: nil).elapsed == "")
}

@Test func aSessionRowIsTitledByItsHistoryElseItsFolder() {
    let board = Board(at: at, teams: [], loose: [
        session("pid:1", cwd: "/Users/me/search", transcript: "/t/1"),
        session("pid:2", cwd: "/Users/me/search", transcript: "/t/2"),
        session("pid:3", cwd: "/Users/me/search"),
    ])
    let hist = [history("fix ranking", workspace: "/Users/me/search", path: "/t/1", live: true),
                history("  ", workspace: "/Users/me/search", path: "/t/2", live: true)]
    let rows = model(board, history: hist).agents[0].rows
    #expect(Dictionary(uniqueKeysWithValues: rows.map { ($0.session.handle, $0.title) })
        == ["pid:1": "fix ranking", "pid:2": "search", "pid:3": "search"])
}

@Test func twoSessionsInOneFolderGetDifferentDropdownTitles() {
    let board = Board(at: at, teams: [], loose: [
        session("pid:1", cwd: "/Users/me/search", transcript: "/t/1"),
        session("pid:2", cwd: "/Users/me/search", transcript: "/t/2"),
    ])
    let hist = [history("fix ranking", workspace: "/Users/me/search", path: "/t/1", live: true),
                history("add filters", workspace: "/Users/me/search", path: "/t/2", live: true)]
    let menu = menuModel(board, history: hist, home: "/Users/me")
    #expect(Set(menu.agents[0].rows.map(\.title)) == ["fix ranking", "add filters"])
}

@Test func teamWaitingCountsWaitingPermissionAndIdleOnly() {
    let done = StateFile(state: "done", reason: nil, updatedAt: ago10)
    let board = Board(at: at, teams: [
        team("t", [
            worker("a", session: session("pane:t:%1", myTurn: true)),
            worker("b", session: session("pane:t:%2", permission: true)),
            worker("c", session: session("pane:t:%3")),
            worker("d", session: session("pane:t:%4", status: .busy)),
            worker("e", session: session("pane:t:%5"), state: done),
            worker("f", session: session("pane:t:%6", myTurn: true), alive: false),
        ]),
        team("u", [worker("g", session: session("pane:u:%1", status: .busy))]),
    ], loose: [])
    let teams = model(board).teams
    #expect(teams.map(\.waiting) == [3, 0])
    #expect(teams.map { waitingText($0.waiting) } == ["3 대기", nil])
    #expect(menuModel(board, history: [], home: "/Users/me").teams.map(\.waiting) == [3, 0])
}

@Test func aFolderRepeatingTheTitleIsNotShown() {
    let board = Board(at: at, teams: [team("t", [worker("api", session: session("pane:t:%1", cwd: "/Users/me/api")),
                                                 worker("b", session: session("pane:t:%2", cwd: "/Users/me/api"))])],
                      loose: [session("pid:1", cwd: "/Users/me/search", transcript: "/t/1"), session("pid:2", cwd: "/Users/me/search")])
    let m = model(board, history: [history("fix ranking", workspace: "/Users/me/search", path: "/t/1", live: true)])
    #expect(Dictionary(uniqueKeysWithValues: m.teams[0].rows.map { ($0.title, $0.shownFolder) }) == ["api": nil, "b": "api"])
    #expect(Dictionary(uniqueKeysWithValues: m.agents[0].rows.map { ($0.title, $0.shownFolder) })
        == ["fix ranking": "search", "search": nil])
    #expect(m.agents[0].rows.allSatisfy { $0.path == "~/search" })
}

@Test func theQueueHoldsMyTurnRowsLongestWaitFirst() {
    let board = Board(at: at, teams: [team("t", [
        worker("recent", session: session("pane:t:%1", myTurn: true, since: "2026-11-02T09:58:00.000Z")),
        worker("busy", session: session("pane:t:%2", status: .busy)),
        worker("old", session: session("pane:t:%3", myTurn: true, since: "2026-11-02T08:00:00.000Z")),
    ])], loose: [
        session("pid:1", agent: .codex, cwd: "/Users/me/web", myTurn: true, since: nil),
        session("pid:2", cwd: "/Users/me/api", myTurn: true, since: "2026-11-02T09:00:00.000Z"),
        session("pid:3", cwd: "/Users/me/idle"),
    ])
    let q = model(board, query: "nothing matches this").queue
    #expect(q.map(\.title) == ["old", "api", "recent", "web"])
    #expect(q.map(\.group.kind) == [.team, .agent(.claude), .team, .agent(.codex)])
    #expect(q.map(\.group.name) == ["t", nil, "t", nil])
}

@Test func anEmptyQueueCountsWhatIsWorking() {
    let board = Board(at: at, teams: [team("t", [worker("a", session: session("pane:t:%1", status: .busy))])],
                      loose: [session("pid:1", status: .busy), session("pid:2")])
    let m = model(board)
    #expect(m.queue.isEmpty)
    #expect(m.working == 2)
}

@Test func aRowKeepsItsMessageLines() {
    let board = Board(at: at, teams: [], loose: [session("pid:1", myTurn: true, lastAssistant: "one\ntwo\nthree\nfour")])
    #expect(model(board).queue[0].message == "one\ntwo\nthree\nfour")
}

@Test func aPermissionPromptShowsHowLongItHasWaited() {
    let board = Board(at: at, teams: [team("t", [worker("a", session: session("pane:t:%1", permission: true))])],
                      loose: [session("pid:1", since: "2026-11-02T07:00:00.000Z", permission: true),
                              session("pid:2", since: nil, permission: true)])
    let m = model(board)
    let worker = m.teams[0].rows[0].badge
    #expect(worker == .permission(minutes: 10))
    #expect(worker.elapsed == "10분")
    #expect(badgeLabel(worker) == "권한 요청 10분")
    let loose = Dictionary(uniqueKeysWithValues: m.agents[0].rows.map { ($0.session.handle, $0.badge) })
    #expect(loose["pid:1"] == .permission(minutes: 180))
    #expect(loose["pid:1"]?.elapsed == "3시간")
    #expect(loose["pid:2"] == .permission(minutes: nil))
    #expect(loose["pid:2"]?.elapsed == "")
    #expect(loose["pid:2"].map(badgeLabel) == "권한 요청")
}

@Test func theQueueOrdersPermissionPromptsByTheirStart() {
    let board = Board(at: at, teams: [team("t", [
        worker("late", session: session("pane:t:%1", myTurn: true, since: "2026-11-02T09:30:00.000Z", permission: true)),
    ])], loose: [
        session("pid:1", cwd: "/Users/me/early", myTurn: true, since: "2026-11-02T08:00:00.000Z", permission: true),
        session("pid:2", cwd: "/Users/me/mid", myTurn: true, since: "2026-11-02T09:00:00.000Z"),
        session("pid:3", cwd: "/Users/me/none", myTurn: true, since: nil, permission: true),
    ])
    #expect(model(board).queue.map(\.title) == ["early", "mid", "late", "none"])
}

@Test func collapsedTeamsSurviveAStoreRoundTripAndIgnoreJunk() {
    var c = CollapsedTeams(stored: "")
    #expect(c.names.isEmpty)  // the default: every team open
    c.set("b", expanded: false, query: "")
    c.set("a \"x\"\n", expanded: false, query: "")
    #expect(CollapsedTeams(stored: c.stored) == c)
    #expect(CollapsedTeams(stored: "not json").names.isEmpty)
    c.set("b", expanded: true, query: "")
    #expect(CollapsedTeams(stored: c.stored).names == ["a \"x\"\n"])
}

@Test func aSearchOpensFoldedTeamsUntilItIsCleared() {
    var c = CollapsedTeams(stored: "")
    c.set("t", expanded: false, query: "")
    #expect(!c.isExpanded("t", query: ""))
    #expect(!c.isExpanded("t", query: "  "))  // blank is no search, as in the sidebar's filter
    #expect(c.isExpanded("t", query: "a"))
    #expect(c.isExpanded("other", query: ""))
    c.set("t", expanded: true, query: "a")  // the disclosure during a search leaves the stored fold alone
    c.set("u", expanded: false, query: "a")
    #expect(c.names == ["t"])
}

@Test func selectingARowFromElsewhereOpensOnlyItsTeam() {
    let board = Board(at: at, teams: [
        team("a", [worker("w", session: session("pane:a:%1"))]),
        team("b", [worker("v", session: session("pane:b:%2"))]),
    ], loose: [session("pane:x:%3")])
    var c = CollapsedTeams(stored: "")
    for t in ["a", "b", "gone"] { c.set(t, expanded: false, query: "") }
    c.reveal(.live(session("pane:x:%3").rowID), in: board)
    c.reveal(.history("/t/a.jsonl"), in: board)
    #expect(c.names == ["a", "b", "gone"])
    c.reveal(.live(session("pane:a:%1").rowID), in: board)
    #expect(c.names == ["b", "gone"])  // a stored team that no longer runs changes nothing
}

@Test func theSidebarSplitKeepsBothPanesAboveTheirMinimum() {
    #expect(SidebarSplit.heights(total: 501, ratio: 0.6) == (top: 300, bottom: 200))
    #expect(SidebarSplit.heights(total: 501, ratio: 0.99).bottom == SidebarSplit.minHeight)
    #expect(SidebarSplit.heights(total: 501, ratio: 0).top == SidebarSplit.minHeight)
    for junk in [Double.nan, .infinity, -1, 2] {
        #expect(SidebarSplit.heights(total: 501, ratio: junk) == (top: 300, bottom: 200))  // the standard 0.6
    }
    // too short for two minimums: the ratio alone shares what there is
    let small = SidebarSplit.heights(total: 201, ratio: 0.5)
    #expect(small.top + small.bottom == 200 && small.top == 100)
    // the line follows the drag from where it was, so a drag starting off-center does not jump
    #expect(SidebarSplit.ratio(top: 300, total: 501) == 0.6)
    // dragged past either end the share stops at that end, not back at the standard 0.6
    #expect(SidebarSplit.ratio(top: -80, total: 501) == 0 && SidebarSplit.ratio(top: 900, total: 501) == 1)
    #expect(SidebarSplit.heights(total: 501, ratio: SidebarSplit.ratio(top: 900, total: 501)).bottom == SidebarSplit.minHeight)
    #expect(SidebarSplit.heights(total: 501, ratio: SidebarSplit.ratio(top: 300 + 7, total: 501)).top == 307)
    // a window resize keeps the share
    #expect(SidebarSplit.heights(total: 1001, ratio: 0.6).top == 600)
}

@Test func oneSelectionAcrossTheLiveAndHistoryLists() {
    let live = RowID.live("a"), past = RowID.history("/t/a.jsonl")
    #expect(SidebarPane.live.shown(live) == live && SidebarPane.live.shown(past) == nil)
    #expect(SidebarPane.history.shown(past) == past && SidebarPane.history.shown(live) == nil)
    // picking in one list replaces a selection in the other
    #expect(SidebarPane.history.select(past, current: live) == past)
    #expect(SidebarPane.live.select(live, current: past) == live)
    // a list letting go of nothing it showed leaves the other list's selection alone
    #expect(SidebarPane.live.select(nil, current: past) == past)
    #expect(SidebarPane.live.select(nil, current: live) == nil)
    #expect(SidebarPane.history.select(nil, current: past) == nil)
}

@Test func theRunningListHasOneMyTeamAreaAboveItsTeamsThenAgentAreas() {
    let w = { (n: String, h: String) in worker(n, session: session(h, status: .busy)) }
    let none = Board(at: at, teams: [], loose: [session("pane:x:%9", status: .busy)])
    #expect(model(none).liveAreas == [.agent(.claude)])  // no team: no my-team area
    let one = Board(at: at, teams: [team("a", [w("w", "pane:a:%1")])], loose: [])
    #expect(model(one).liveAreas == [.team])
    let many = Board(at: at, teams: [team("a", [w("w", "pane:a:%1")]), team("b", [w("v", "pane:b:%2")])],
                     loose: [session("pane:x:%3", status: .busy), session("pane:y:%4", agent: .codex, status: .busy)])
    #expect(model(many).liveAreas == [.team, .agent(.claude), .agent(.codex)])  // one my-team area, however many teams
    #expect(model(many, query: "b").liveAreas == [.team])  // a search showing no agent session drops those areas
}

@Test func clickingATeamNameFoldsAndUnfoldsLikeItsDisclosure() {
    var c = CollapsedTeams(stored: "")
    c.toggle("t", query: "")
    #expect(!c.isExpanded("t", query: ""))
    c.toggle("t", query: "")
    #expect(c.isExpanded("t", query: "") && c.names.isEmpty)
    c.toggle("t", query: "x")  // during a search, as with the disclosure, nothing changes
    #expect(c.names.isEmpty)
}

@Test func aTeamHeaderCountsTheWorkersItListsAndThoseWaiting() {
    let board = Board(at: at, teams: [team("t", [
        worker("ab", session: session("pane:t:%1", myTurn: true)),
        worker("ac", session: session("pane:t:%2", status: .busy)),
        worker("bd", session: session("pane:t:%3", status: .busy)),
        worker("dead", session: session("pane:t:%4"), alive: false),
    ])], loose: [])
    #expect(teamHeaderDetail(model(board).teams[0]) == "워커 3 · 1 대기")  // a stopped worker is not listed, so not counted
    #expect(teamHeaderDetail(model(board, query: "ac").teams[0]) == "워커 1")  // a search counts the rows it shows
    #expect(teamHeaderDetail(model(board, query: "ab").teams[0]) == "워커 1 · 1 대기")
}

/// R47: the icon cell holds `person.3` at every font scale, and a worker starts one step past the team's name
/// (the header cell sits 2 points left of a row cell in the sidebar style, so the step is 14 + 2).
@MainActor @Test func teamWorkersStartOneStepPastTheTeamName() {
    #expect(TeamHeader.nameInset(1) == 44)
    #expect(TeamHeader.nameInset(2) == 70)
    #expect(TeamHeader.workerInset(1) == 58)
}
