import AppKit
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

private func model(_ board: Board, history: [HistorySession] = [], query: String = "", filter: HistoryFilter = .claude,
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
    #expect(teamLineTooltip(g) == "워커 3 · 내 차례 2 · 답 기다림 1 · 완료 1 · 작업 중 1 · 멈춤 1 숨김")
    #expect(g.rows.map(\.title) == ["b", "a", "c"])
}

@Test func aTeamsGroupLeadsItsTooltipAndASearchForItFindsTheTeam() {
    var t = team("nudake-payment", [worker("a", session: session("pane:t:%1", status: .busy))])
    t.group = "nudake"
    let board = Board(at: at, teams: [t, team("other", [worker("b", session: session("pane:o:%1", status: .busy))])], loose: [])
    #expect(teamLineTooltip(model(board).teams[0]) == "그룹 nudake · 워커 1 · 작업 중 1")
    #expect(model(board, query: "nudake").teams.map(\.name) == ["nudake-payment"])
}

@Test func summaryOmitsEmptySegments() {
    let board = Board(at: at, teams: [team("t", [worker("a", session: session("pane:t:%1", status: .busy))])], loose: [])
    #expect(teamLineTooltip(model(board).teams[0]) == "워커 1 · 작업 중 1")
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

@Test func agentGroupCountsMyTurnLikeTheTeams() {
    let board = Board(at: at, teams: [], loose: [
        session("pid:1", myTurn: true),
        session("pid:2", permission: true),
        session("pid:3"),
        session("pid:4", status: .busy),
        session("pid:5", agent: .codex, status: .busy),
    ])
    let groups = model(board).agents
    #expect(groups.map(\.myTurn) == [1, 0])
    #expect(groups.map { myTurnText($0.myTurn) } == ["내 차례 1", nil])
    #expect(groups[0].summary == "세션 4 · 작업 중 1 · 내 차례 1")
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
    #expect(badgeLabel(.waitingForUser(minutes: 12)) == "답 기다림 12분")
    #expect(badgeLabel(.waitingForUser(minutes: nil)) == "답 기다림")
    #expect(badgeLabel(.working) == "작업 중")
    #expect(badgeLabel(.done(minutesAgo: 3)) == "3분 전 완료")
    #expect(badgeLabel(.idle(minutes: 7)) == "쉬는 중 7분")
    #expect(badgeLabel(.idle(minutes: nil)) == "쉬는 중")
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
    #expect(teamLineTooltip(g) == "워커 2 · 내 차례 2 · 권한 요청 1 · 완료 1")
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
    #expect(menu.agents[0].myTurn == 1)
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
    #expect(menuSections(menuModel(allClosed, history: [], home: "/Users/me")).isEmpty)
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
    #expect(menuSections(menuModel(Board(at: at, teams: [], loose: []), history: [], home: "/Users/me")).isEmpty)
}

@Test func durationsRollUpIntoHoursAndDays() {
    let cases = [(0, "0분"), (59, "59분"), (60, "1시간"), (61, "1시간 1분"), (1439, "23시간 59분"),
                 (1440, "1일"), (1500, "1일 1시간"), (2503, "1일 17시간")]
    for (m, text) in cases { #expect(duration(minutes: m) == text) }
    #expect(badgeLabel(.waitingForUser(minutes: 2503)) == "답 기다림 1일 17시간")
    #expect(badgeLabel(.done(minutesAgo: 61)) == "1시간 1분 전 완료")
    #expect(badgeLabel(.idle(minutes: 60)) == "쉬는 중 1시간")
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

/// One count everywhere (T77): a team's header, its tooltip and its dropdown line count what the 내 차례 list shows
/// of that team, done and permission included. As collected, a permission prompt or a done worker is my turn and a
/// stopped worker is not.
@Test func aTeamsCountIsItsCardsInTheMyTurnList() {
    let done = StateFile(state: "done", reason: nil, updatedAt: ago10)
    let board = Board(at: at, teams: [
        team("t", [
            worker("a", session: session("pane:t:%1", myTurn: true)),
            worker("b", session: session("pane:t:%2", myTurn: true, permission: true)),
            worker("c", session: session("pane:t:%3", myTurn: true), state: done),
            worker("d", session: session("pane:t:%4", status: .busy)),
            worker("e", session: session("pane:t:%5")),
            worker("f", session: session("pane:t:%6"), alive: false),
        ]),
        team("u", [worker("g", session: session("pane:u:%1", status: .busy))]),
    ], loose: [])
    let side = model(board)
    let cards = side.queue.filter { $0.teamName == "t" }.count
    #expect(cards == 3)
    #expect(side.teams.map(\.myTurn) == [cards, 0])
    #expect(teamLine(side.teams[0], .full).workers == 5)
    #expect(teamLineTooltip(side.teams[0]) == "워커 5 · 내 차례 3 · 권한 요청 1 · 답 기다림 1 · 완료 1 · 작업 중 1 · 멈춤 1 숨김")
    #expect(teamLine(side.teams[1], .full).workers == 1)
    #expect(menuModel(board, history: [], home: "/Users/me").teams.map(\.myTurn) == [3, 0])
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

@Test func theQueueHoldsRowsWaitingOnMeLongestWaitFirst() {
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

@Test func theQueuePutsAnswersNeededAboveFinishedWorkLongestWaitFirstInEach() {
    let done = StateFile(state: "done", reason: nil, updatedAt: ago10)
    let board = Board(at: at, teams: [team("t", [
        worker("done-old", session: session("pane:t:%1", myTurn: true, since: "2026-11-02T07:00:00.000Z"), state: done),
        worker("ask-new", session: session("pane:t:%2", myTurn: true, since: "2026-11-02T09:58:00.000Z")),
        worker("done-new", session: session("pane:t:%3", myTurn: true, since: "2026-11-02T09:00:00.000Z"), state: done),
        worker("ask-old", session: session("pane:t:%4", myTurn: true, since: "2026-11-02T08:00:00.000Z", permission: true)),
    ])], loose: [])
    #expect(model(board).queue.map(\.title) == ["ask-old", "ask-new", "done-old", "done-new"])
}

@Test func eachRowKindOffersItsOwnMenu() {
    let board = Board(at: at, teams: [team("t", [worker("a", session: session("pane:t:%1", transcript: "/t/a"))])],
                      loose: [session("pid:1", cwd: "/Users/me/web", myTurn: true)])
    let m = model(board, history: [history("a", path: "/t/a", live: true), history("old", path: "/t/old")])
    let worker = m.teams[0].rows[0], loose = m.agents[0].rows[0]
    #expect(rowMenuItems(worker.id, in: m) == [.focus, .diff, .copyPath, .copyResume])
    // no history entry reads this session's transcript: nothing to resume
    #expect(rowMenuItems(loose.id, in: m) == [.focus, .diff, .copyPath])
    #expect(rowMenuItems(.history("/t/old"), in: m) == [.resume, .copyResume])
    #expect(rowMenuItems(.dashboard, in: m).isEmpty)
    #expect(rowMenuItems(.live("gone"), in: m).isEmpty)
    #expect(RowMenuItem.focus.title == "터미널로 이동")
}

@Test func theBoardStartsOnTheDashboardAndBackReturnsToIt() {
    let board = Board(at: at, teams: [], loose: [session("pid:1", cwd: "/Users/me/web", myTurn: true)])
    let m = model(board)
    var nav = ScreenHistory()
    #expect(nav.current == Screen(.dashboard))
    let live = m.liveRows[0]
    nav.go(Screen(live.id))
    #expect(nav.screens == [Screen(.dashboard), Screen(live.id)])
    nav.back()
    #expect(nav.current == Screen(.dashboard))
    #expect(SidebarPane.live.shown(.dashboard) == .dashboard)
    #expect(screenTitle(Screen(.dashboard), model: m, history: [], usage: UsageLedger().report(.week)).title == "대시보드")
}

@Test func openedTeamsSurviveAStoreRoundTripAndIgnoreJunk() {
    var o = OpenedTeams(stored: "")
    o.set("b", expanded: true, query: "")
    o.set("a \"x\"\n", expanded: true, query: "")
    #expect(OpenedTeams(stored: o.stored) == o)
    #expect(OpenedTeams(stored: "not json").names.isEmpty)
    o.set("b", expanded: false, query: "")
    #expect(OpenedTeams(stored: o.stored).names == ["a \"x\"\n"])
}

/// T184: a fresh install and an install that stored the old `collapsedTeams` (every team open) both start folded.
@Test func everyTeamStartsFoldedOnAFreshInstallAndAfterTheOldKey() throws {
    #expect(OpenedTeams.storageKey != "collapsedTeams")
    let defaults = try #require(UserDefaults(suiteName: "local.control-tower.test-opened-teams"))
    defaults.removePersistentDomain(forName: "local.control-tower.test-opened-teams")
    defer { defaults.removePersistentDomain(forName: "local.control-tower.test-opened-teams") }
    let fresh = OpenedTeams(stored: defaults.string(forKey: OpenedTeams.storageKey) ?? "")
    #expect(!fresh.isExpanded("t", query: ""))
    defaults.set(#"["other"]"#, forKey: "collapsedTeams")
    let updated = OpenedTeams(stored: defaults.string(forKey: OpenedTeams.storageKey) ?? "")
    #expect(!updated.isExpanded("t", query: "") && !updated.isExpanded("other", query: ""))
}

@Test func aSearchOpensFoldedTeamsUntilItIsCleared() {
    var o = OpenedTeams(stored: "")
    o.set("t", expanded: true, query: "")
    #expect(o.isExpanded("t", query: ""))
    #expect(!o.isExpanded("other", query: ""))
    #expect(!o.isExpanded("other", query: "  "))  // blank is no search, as in the sidebar's filter
    #expect(o.isExpanded("other", query: "a"))
    o.set("t", expanded: false, query: "a")  // the disclosure during a search leaves the stored fold alone
    o.set("u", expanded: true, query: "a")
    #expect(o.names == ["t"])
}

@Test func selectingARowFromElsewhereOpensOnlyItsTeam() {
    let board = Board(at: at, teams: [
        team("a", [worker("w", session: session("pane:a:%1"))]),
        team("b", [worker("v", session: session("pane:b:%2"))]),
    ], loose: [session("pane:x:%3")])
    var o = OpenedTeams(stored: "")
    o.set("gone", expanded: true, query: "")
    o.reveal(.live(session("pane:x:%3").rowID), in: board)
    o.reveal(.history("/t/a.jsonl"), in: board)
    #expect(o.names == ["gone"])
    o.reveal(.live(session("pane:a:%1").rowID), in: board)
    #expect(o.names == ["a", "gone"])  // a stored team that no longer runs changes nothing
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
    // the 내 차례 line heads the running list
    #expect(SidebarPane.live.shown(.dashboard) == .dashboard && SidebarPane.history.shown(.dashboard) == nil)
}

@Test func theMyTurnLineAndTheMenuBarIconCountTheSameSessions() {
    let board = Board(at: at, teams: [team("t", [
        worker("a", session: session("pane:t:%1", myTurn: true)),
        worker("b", session: session("pane:t:%2", myTurn: true), alive: false),  // stopped: no card, no count
        worker("c", session: session("pane:t:%3", status: .busy)),
    ])], loose: [session("pid:1", myTurn: true), session("pid:2")])
    #expect(model(board).queue.count == 2)
    #expect(myTurnShown(board) == model(board).queue.count)
    // a search or the history page changes neither
    #expect(myTurnShown(board) == model(board, query: "zzz", historyLimit: 0).queue.count)
}

@Test func backAndForwardWalkTheScreensAndANewMoveDropsThoseAhead() {
    var h = ScreenHistory()
    #expect(h.current == Screen(.dashboard) && !h.canGoBack && !h.canGoForward)
    // task boards are windows of their own (T86): RowID has no task board line, so no screen here is one
    let worker = Screen(.live("w")), board = Screen(.live("v")), task = Screen(.history("/t/b.jsonl"))
    for s in [worker, board, task] { h.go(s) }
    h.back()
    #expect(h.current == board)
    h.back()
    #expect(h.current == worker)
    h.forward()
    #expect(h.current == board && h.canGoForward)
    // from the middle: the screen ahead is dropped
    h.go(Screen(.history("/t/a.jsonl")))
    #expect(!h.canGoForward)
    h.back()
    #expect(h.current == board)
    // the screen shown already is not a new step
    h.go(board)
    h.back()
    #expect(h.current == worker)
}

@Test func theHistoryKeepsItsNewestScreens() {
    var h = ScreenHistory()
    for i in 0..<(ScreenHistory.limit + 20) { h.go(Screen(.live("w\(i)"))) }
    #expect(h.screens.count == ScreenHistory.limit)
    #expect(h.current == Screen(.live("w\(ScreenHistory.limit + 19)")))
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

@Test func clickingATeamLineFoldsAndUnfoldsLikeItsDisclosure() {
    var o = OpenedTeams(stored: "")
    o.toggle("t", query: "")
    #expect(o.isExpanded("t", query: ""))
    o.toggle("t", query: "")
    #expect(!o.isExpanded("t", query: "") && o.names.isEmpty)
    o.toggle("t", query: "x")  // during a search, as with the disclosure, nothing changes
    #expect(o.names.isEmpty)
}

private func line(_ rows: [LiveRow], board: Bool = false, decisions: Int = 0) -> TeamGroup {
    TeamGroup(name: "t", myTurn: 0, rows: rows, hasTaskBoard: board,
              taskCounts: board ? TaskCounts(user: decisions, start: 0, doing: 0, review: 0) : nil)
}

private func liveRow(_ badge: RowBadge) -> LiveRow {
    LiveRow(id: .live("w"), session: session("pane:t:%1"), worker: nil, teamName: "t", title: "w", folder: "w", path: "",
            badge: badge, matched: nil)
}

@Test func aTeamLineCountsTheStatesOfTheRowsItListsInOrderAndDropsZeros() {
    let board = Board(at: at, teams: [team("t", [
        worker("ab", session: session("pane:t:%1", myTurn: true)),
        worker("ac", session: session("pane:t:%2", status: .busy)),
        worker("bd", session: session("pane:t:%3", status: .busy)),
        worker("be", session: session("pane:t:%4", permission: true)),
        worker("dead", session: session("pane:t:%5"), alive: false),
    ])], loose: [])
    func counts(_ g: TeamGroup) -> [[String]] { teamLine(g, .full).statuses.map { [badgeLabel($0.badge), "\($0.count)"] } }
    let all = model(board).teams[0]
    #expect(teamLine(all, .full).workers == 4)  // a stopped worker is not listed, so not counted
    #expect(counts(all) == [["권한 요청", "1"], ["답 기다림", "1"], ["작업 중", "2"]])  // no 완료: zero is not shown
    #expect(counts(model(board, query: "ac").teams[0]) == [["작업 중", "1"]])  // a search counts the rows it shows
    let done = line([liveRow(.done(minutesAgo: 5)), liveRow(.idle(minutes: 3)), liveRow(.done(minutesAgo: nil))])
    #expect(counts(done) == [["완료", "2"]], "idle is not shown")
    #expect(counts(line([liveRow(.working), liveRow(.done(minutesAgo: 1)), liveRow(.waitingForUser(minutes: 2)),
                         liveRow(.permission(minutes: 3))])) == [["권한 요청", "1"], ["답 기다림", "1"], ["완료", "1"], ["작업 중", "1"]])
    #expect(teamLine(line([]), .full).statuses.isEmpty)
}

@Test func eachDensityShowsLessThanTheOneBeforeIt() {
    let rows = [liveRow(.working), liveRow(.permission(minutes: 1)), liveRow(.done(minutesAgo: 3)), liveRow(.waitingForUser(minutes: 2))]
    let boarded = line(rows, board: true, decisions: 2)
    let all = [TeamStatusCount(badge: .permission(minutes: nil), count: 1), TeamStatusCount(badge: .waitingForUser(minutes: nil), count: 1),
               TeamStatusCount(badge: .done(minutesAgo: nil), count: 1), TeamStatusCount(badge: .working, count: 1)]
    #expect(TeamLineDensity.allCases == [.full, .icons, .compact, .noWorkers, .myTurn, .myTurnTotal])
    #expect(teamLine(boarded, .full) == TeamLineParts(
        board: .words, workers: 4, workersForm: .words, decisions: 2, decisionsForm: .words, statuses: all))
    #expect(teamLine(boarded, .icons) == TeamLineParts(
        board: .icon, workers: 4, workersForm: .icon, decisions: 2, decisionsForm: .words, statuses: all))
    #expect(teamLine(boarded, .compact) == TeamLineParts(
        board: .icon, workers: 4, workersForm: .icon, decisions: 2, decisionsForm: .icon, statuses: all))
    #expect(teamLine(boarded, .noWorkers) == TeamLineParts(
        board: .icon, workers: 4, workersForm: nil, decisions: 2, decisionsForm: .icon, statuses: all))
    // what is my turn stays: the button, the decisions, permission requests, answers and done (T189, R11 S2)
    #expect(teamLine(boarded, .myTurn) == TeamLineParts(
        board: .icon, workers: 4, workersForm: nil, decisions: 2, decisionsForm: .icon, statuses: Array(all.prefix(3))))
    // the last step adds those three into one number; the decisions stay their own
    #expect(teamLine(boarded, .myTurnTotal) == TeamLineParts(
        board: .icon, workers: 4, workersForm: nil, decisions: 2, decisionsForm: .icon, statuses: [], myTurnTotal: 3))
    #expect(teamLine(line(rows + [liveRow(.done(minutesAgo: 9)), liveRow(.idle(minutes: 1))]), .myTurnTotal).myTurnTotal == 4)
    // zero counts are dropped at every step, and the order is kept
    let onlyDone = line([liveRow(.done(minutesAgo: 1)), liveRow(.working)])
    #expect(teamLine(onlyDone, .noWorkers).statuses.map(\.badge.icon) == [.check, .spinner])
    #expect(teamLine(onlyDone, .myTurn).statuses.map(\.badge.icon) == [.check])
    #expect(teamLine(onlyDone, .myTurnTotal).myTurnTotal == 1)
    #expect(teamLine(line([liveRow(.working)]), .myTurnTotal).myTurnTotal == 0)
    for d in TeamLineDensity.allCases where d != .myTurnTotal { #expect(teamLine(boarded, d).myTurnTotal == nil) }
    // no task board: no button; no decisions: none shown, in every density
    for d in TeamLineDensity.allCases {
        let plain = teamLine(line(rows), d)
        #expect(plain.board == nil && plain.decisions == 0)
        #expect(teamLine(line(rows, board: true), d).decisions == 0 && teamLine(line(rows, board: true), d).board != nil)
    }
}

@Test func aTeamLineSpellsEveryNumberInWordsForVoiceOver() {
    let rows = [liveRow(.working), liveRow(.working), liveRow(.permission(minutes: 1)), liveRow(.done(minutesAgo: 4))]
    #expect(teamLineLabel(line(rows, board: true, decisions: 3)) == "t, 워커 4, 내 차례 2, 결정 대기 3, 권한 요청 1, 완료 1, 작업 중 2")
    #expect(teamLineLabel(line([liveRow(.idle(minutes: 1))])) == "t, 워커 1")
    #expect(teamLineLabel(line([])) == "t, 워커 0")
    // the label takes no density: the last steps drop the workers and the working count from the line, not from it
    let last = teamLine(line(rows, board: true, decisions: 3), .myTurnTotal)
    #expect(last.workersForm == nil && last.statuses.isEmpty && last.myTurnTotal == 2)
    let label = teamLineLabel(line(rows, board: true, decisions: 3))
    #expect(label.contains("워커 4") && label.contains("완료 1") && label.contains("작업 중 2"))
}

/// R11a L2, L6: the line's tooltip and its VoiceOver name count as the line does, the workers it lists by the state
/// each shows.
@Test func aTeamLinesTooltipAndNameCountWhatTheLineShows() {
    let done = StateFile(state: "done", reason: nil, updatedAt: ago10)
    let board = Board(at: at, teams: [team("t", [
        worker("a", session: session("pane:t:%1", status: .busy)),
        worker("b", session: session("pane:t:%2", myTurn: true)),
        worker("c", session: session("pane:t:%3"), state: done),
        worker("d", session: session("pane:t:%4"), alive: false),
    ])], loose: [])
    let g = model(board).teams[0]
    #expect(g.myTurn == 1 && teamLine(g, .myTurnTotal).myTurnTotal == 2)
    #expect(teamLineTooltip(g) == "워커 3 · 내 차례 2 · 답 기다림 1 · 완료 1 · 작업 중 1 · 멈춤 1 숨김")
    #expect(teamLineLabel(g) == "t, 워커 3, 내 차례 2, 답 기다림 1, 완료 1, 작업 중 1, 멈춤 1 숨김")
}

/// R11 L5: ← folds the selected worker's team and → unfolds it; with no folded team under the selection, → unfolds
/// the first folded team down the list, which no selection can reach.
@Test func anArrowKeyFoldsTheSelectedWorkersTeamAndUnfoldsTheNextFoldedOne() {
    func group(_ name: String, _ row: String) -> TeamGroup {
        var r = liveRow(.working)
        r.id = .live(row)
        return TeamGroup(name: name, myTurn: 0, rows: [r])
    }
    let teams = [group("a", "a1"), group("b", "b1"), group("c", "c1")]
    func team(unfold: Bool, _ selection: RowID?, open: Set<String>) -> String? {
        teamForArrow(unfold: unfold, selection: selection, teams: teams, expanded: open.contains)
    }
    #expect(team(unfold: true, .dashboard, open: []) == "a")
    #expect(team(unfold: true, .dashboard, open: ["a"]) == "b")
    #expect(team(unfold: true, .dashboard, open: ["a", "b", "c"]) == nil)
    #expect(team(unfold: true, .live("c1"), open: ["a"]) == "c", "the selection's own team first")
    #expect(team(unfold: true, .live("a1"), open: ["a"]) == "b")
    #expect(team(unfold: false, .live("b1"), open: ["a", "b"]) == "b")
    #expect(team(unfold: false, .live("b1"), open: ["a"]) == nil)
    #expect(team(unfold: false, .dashboard, open: ["a"]) == nil, "← folds nothing the selection is not in")
}

/// A name cut short is its first four characters and an ellipsis at every font scale; a shorter name is itself whole.
@MainActor @Test func aTeamNameCutShortKeepsItsFirstFourCharacters() {
    for scale in [0.8, 1.0, 2.0] {
        let short = TeamHeader.nameShortWidth("example-team", scale: scale)
        #expect(short > 0 && short < TeamHeader.nameWidth("example-team", scale: scale), "scale \(scale)")
        #expect(short == TeamHeader.nameWidth("exam…", scale: scale))
        #expect(TeamHeader.nameShortWidth("pm", scale: scale) == TeamHeader.nameWidth("pm", scale: scale))
    }
    #expect(TeamHeader.nameShortWidth("example-team", scale: 2.0) > TeamHeader.nameShortWidth("example-team", scale: 1.0))
}

/// R47, T47c, T184: the icon cell holds the fold chevron at every font scale, and a worker's name starts half a step (8) past the
/// team's name. A row cell sits 2 points right of a header cell, and a row's status icon and its spacing come first.
@MainActor @Test func teamWorkerNamesStartHalfAStepPastTheTeamName() {
    #expect(TeamHeader.nameInset(1) == 44)
    #expect(TeamHeader.nameInset(2) == 70)
    for scale in [1.0, 1.3, 2.0] {
        let workerName = 2 + TeamHeader.workerInset(scale) + StatusIconView.size(.body, scale: scale) + 6
        #expect(abs(workerName - (TeamHeader.nameInset(scale) + 8)) < 0.001)
    }
    #expect(TeamHeader.workerInset(1) == 44 - NSFont.preferredFont(forTextStyle: .body).pointSize)
}

private func teamHistory(_ id: String, team: String?, worker: String, at: String, started: String? = nil,
                         joined: Bool = false) -> HistorySession {
    HistorySession(id: id, agent: .claude, title: "\(worker) title", workspace: "/Users/me/proj", branch: nil,
                   createdAt: started ?? at, updatedAt: at, lastPrompt: nil, transcriptPath: "/t/\(id).jsonl", live: false,
                   resumeCommand: ["claude", "--resume", id],
                   member: team.map { TeamWorker(team: $0, worker: worker, joined: joined) })
}

@Test func aTeamsCodexWorkerIsNotACodexTerminal() {
    var worker = teamHistory("cx", team: "shop", worker: "cx", at: "2026-11-02T03:00:00.000Z")
    worker.agent = .codex
    var single = teamHistory("solo", team: nil, worker: "x", at: "2026-11-02T02:00:00.000Z")
    single.agent = .codex
    let board = Board(at: at, teams: [], loose: [])
    #expect(model(board, history: [worker, single], filter: .codex).history.map(\.id) == ["solo"])
}

/// T208 (D#2): the history lists single terminals only; a stopped team is started again from 팀 실행.
@Test func theHistoryHasNoTeamLines() {
    let history = [
        teamHistory("pm2", team: "shop", worker: "pm", at: "2026-11-02T03:00:00.000Z"),
        teamHistory("solo", team: nil, worker: "x", at: "2026-11-02T02:00:00.000Z"),
        teamHistory("solo2", team: nil, worker: "y", at: "2026-11-02T01:00:00.000Z"),
    ]
    let board = Board(at: at, teams: [], loose: [])
    #expect(model(board, history: history, filter: .claude).history.map(\.id) == ["solo", "solo2"])
    let one = model(board, history: history, filter: .claude, historyLimit: 1)
    #expect(one.history.map(\.id) == ["solo"] && one.historyRemaining == 1)
    #expect(model(board, history: history, query: "shop", filter: .claude).history.isEmpty)
}

@Test func aWorkerKnowsWhichTeammatesShareItsFolder() {
    let board = Board(at: at, teams: [team("t", [
        worker("pm", session: session("pane:t:%1", cwd: "/r")),
        worker("core", session: session("pane:t:%2", cwd: "/r")),
        worker("app", session: session("pane:t:%3", cwd: "/r/.worktrees/app")),
        worker("gone", session: session("pane:t:%4", cwd: "/r"), alive: false),
    ])], loose: [session("pid:9", cwd: "/r")])
    let rows = model(board).teams[0].rows
    let row = { (name: String) in rows.first { $0.worker?.workerName == name }! }
    #expect(workspaceSharers(row("core"), in: board) == ["pm"])  // a stopped worker or a loose session does not count
    #expect(workspaceSharers(row("app"), in: board).isEmpty)  // its own worktree: the diff is its own
}

@Test func aDiffTabIsTitledByTheTeamAndWorkersOfItsFolder() {
    let board = Board(at: at, teams: [team("t", [
        worker("pm", session: session("pane:t:%1", cwd: "/r")),
        worker("core", session: session("pane:t:%2", cwd: "/r")),
        worker("app", session: session("pane:t:%3", cwd: "/r/.worktrees/app")),
        worker("gone", session: session("pane:t:%4", cwd: "/r"), alive: false),
    ]), team("u", [worker("dev", session: session("pane:u:%1", cwd: "/r"))])],
    loose: [session("pid:9", cwd: "/home/me/solo")])
    #expect(diffTabTitle(workspace: "/r/.worktrees/app", board: board) == "t · app")
    #expect(diffTabTitle(workspace: "/r", board: board) == "t · pm, core / u · dev")  // a stopped worker does not count
    #expect(diffTabTitle(workspace: "/home/me/solo", board: board) == "solo")  // a session outside a team: the folder
    #expect(diffTabTitle(workspace: "/home/me/solo", board: nil) == "solo")
}

@Test func theDiffScopeNamesTheFolderItIsLimitedTo() {
    #expect(diffScopeLabel(scope: nil, sharers: []) == "")
    #expect(diffScopeLabel(scope: "", sharers: []) == "")  // the whole repo, as before
    #expect(diffScopeLabel(scope: "backend", sharers: []) == "저장소의 backend/ 아래만")
    #expect(diffScopeLabel(scope: "", sharers: ["pm"]) == "팀 공유 폴더 (pm와 함께)")
    #expect(diffScopeLabel(scope: "backend", sharers: ["pm", "qa"]) == "저장소의 backend/ 아래만 · 팀 공유 폴더 (pm, qa와 함께)")
}

@Test func aTranscriptSizeReadsAsFinderShowsIt() {
    #expect(transcriptSizeLabel(nil) == nil)
    #expect(transcriptSizeLabel(1_200_000) == ByteCountFormatter.string(fromByteCount: 1_200_000, countStyle: .file))
}

@Test func aHistoryLinesSizeIsInItsTooltip() {
    var h = history("fix ranking")
    h.size = 1_200_000
    #expect(historyTooltip(h, home: "/Users/me").hasSuffix("크기 " + ByteCountFormatter.string(fromByteCount: 1_200_000, countStyle: .file)))
    h.size = nil
    #expect(!historyTooltip(h, home: "/Users/me").contains("크기"))
}

/// T77: every state reads as its own word, and "대기" is none of them (pm decision 2026-11-12).
@Test func eachStateHasItsOwnWords() {
    let badges: [RowBadge] = [.waitingForUser(minutes: nil), .permission(minutes: nil), .working, .done(minutesAgo: nil), .idle(minutes: nil)]
    let labels = badges.map(badgeLabel)
    #expect(labels == ["답 기다림", "권한 요청", "작업 중", "완료", "쉬는 중"])
    #expect(Set(labels).count == labels.count)
    #expect(labels.allSatisfy { !$0.contains("대기") })
    let timed: [RowBadge] = [.waitingForUser(minutes: 5), .permission(minutes: 5), .done(minutesAgo: 5), .idle(minutes: 5)]
    #expect(Set(timed.map(badgeLabel)).count == timed.count)
}

/// T125: the menu bar menu leads with 내 차례, longest wait first as on the board, hidden at 0, each opening its row on
/// the board as a 내 차례 card does; then the teams, which open the board, then each agent's sessions, which go to
/// their terminal. A line is its title, its state in words
/// and, under 내 차례, where it belongs.
@Test func theMenuBarMenuLeadsWithMyTurnLongestWaitFirst() {
    let board = Board(at: at, teams: [
        team("t", [worker("a", session: session("pane:t:%1", status: .busy)),
                   worker("b", session: session("pane:t:%2", myTurn: true, since: "2026-11-02T09:55:00.000Z"))]),
    ], loose: [session("pid:9", cwd: "/Users/me/b", myTurn: true, since: "2026-11-02T09:40:00.000Z"),
               session("pid:7", agent: .codex, cwd: "/Users/me/a", status: .busy)])
    let menu = menuModel(board, history: [], home: "/Users/me")
    #expect(menu.myTurn.map(\.id) == model(board).queue.map(\.id), "the board's 내 차례 list")
    let sections = menuSections(menu)
    #expect(sections.map(\.title) == ["내 차례 2 · 보드에서 열기", "my-team · 보드에서 열기", "Claude · 내 차례 1 · 터미널로 이동", "Codex · 터미널로 이동"])

    let mine = sections[0].lines
    #expect(mine.map(\.target) == [.board(.live("pid:9#1")), .board(.live("pane:t:%2#1"))], "the longer wait first, on the board")
    #expect(sections[2].lines.map(\.target).contains(.terminal(handle: "pid:9")), "the same session below goes to its terminal")
    #expect(mine[0].title == "\(model(board).queue[0].title) · 답 기다림 20분 · Claude")
    #expect(mine[1].title.hasSuffix(" · 답 기다림 5분 · t"))
    #expect(mine.allSatisfy { $0.symbol == "hand.raised.fill" })

    #expect(sections[1].lines == [MenuItemLine(title: "t · 내 차례 1", symbol: "macwindow", target: .board(.live("pane:t:%2#1")))])
    #expect(sections[3].lines.map(\.symbol) == ["ellipsis.circle"])
    #expect(sections[3].lines[0].title.hasSuffix(" · 작업 중"))
}

@Test func theMenuBarMenuHasNoMyTurnSectionAtZero() {
    let board = Board(at: at, teams: [team("t", [worker("a", session: session("pane:t:%1", status: .busy))])], loose: [])
    let sections = menuSections(menuModel(board, history: [], home: "/Users/me"))
    #expect(sections.map(\.title) == ["my-team · 보드에서 열기"])
    #expect(menuSections(menuModel(Board(at: at, teams: [], loose: []), history: [], home: "/Users/me")).isEmpty)
}

/// R48 L2: each state's menu symbol is its own shape, the menu having no colors.
@Test func everyStateHasItsOwnMenuSymbol() {
    let symbols = StatusIcon.allCases.map(\.symbol)
    #expect(symbols.count == 5 && Set(symbols).count == 5)
}

/// R48 L1: a my-team failure is one short menu line, its first line cut, saying where the whole error is.
@Test func aMyTeamFailureIsOneShortMenuLine() {
    let long = String(repeating: "x", count: 200) + "\nsecond line"
    let title = menuErrorTitle(long)
    #expect(!title.contains("\n") && !title.contains("second"))
    #expect(title == "팀 정보를 읽지 못함: " + String(repeating: "x", count: menuErrorLength - 1) + "… · 보드에서 전체 보기")
    #expect(menuErrorTitle("my-team: not found") == "팀 정보를 읽지 못함: my-team: not found · 보드에서 전체 보기")
}

@Test func lineCountsAreAskedOnlyForTheWorkerFoldersOfUnfoldedTeams() {
    let board = Board(at: at, teams: [
        team("open", [worker("a", session: session("pane:open:%1", cwd: "/w/a")), worker("b", session: session("pane:open:%2", cwd: "/w/a")),
                      worker("c", session: session("pane:open:%3", cwd: "/w/c")), worker("d", session: session("pane:open:%4", cwd: ""))]),
        team("folded", [worker("e", session: session("pane:folded:%5", cwd: "/w/e"))]),
    ], loose: [session("pid:9", cwd: "/w/loose")])
    let teams = model(board).teams
    #expect(diffTotalFolders(teams) { $0 == "open" } == ["/w/a", "/w/c"])
    #expect(diffTotalFolders(teams) { _ in false }.isEmpty)
}

@Test func aWorkerRowsLineCountIsItsFoldersAndNamesWhoSharesIt() throws {
    let board = Board(at: at, teams: [team("t", [
        worker("a", session: session("pane:t:%1", cwd: "/w/a")), worker("b", session: session("pane:t:%2", cwd: "/w/a")),
        worker("c", session: session("pane:t:%3", cwd: "/w/c")), worker("d", session: session("pane:t:%4", cwd: "/w/d")),
        worker("e", session: session("pane:t:%5", cwd: "/w/e")),
    ])], loose: [])
    let rows = model(board).teams[0].rows
    func change(_ name: String) throws -> RowChange? {
        rowChange(try #require(rows.first { $0.title == name }),
                  totals: ["/w/a": DiffTotal(added: 340, removed: 85), "/w/c": DiffTotal(added: 0, removed: 2), "/w/d": DiffTotal()], board: board)
    }
    let own = try #require(try change("c"))
    #expect(own.added == "+0" && own.removed == "−2" && own.words == "더한 줄 0, 뺀 줄 2")
    let shared = try #require(try change("a"))
    #expect(shared.added == "+340" && shared.removed == "−85" && shared.sharers == ["b"])
    #expect(shared.words == "더한 줄 340, 뺀 줄 85 (b와 같은 폴더의 값)")
    #expect(try change("d") == nil, "an unchanged folder shows nothing")
    #expect(try change("e") == nil, "a folder outside git, or not counted yet, shows nothing")
}

@MainActor @Test func gitIsNotRunWithNoWorkerRowOnScreenAndOncePerFolderWithSome() async {
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var folders: [String] = []
        func add(_ f: String) { lock.withLock { folders.append(f) } }
        var all: [String] { lock.withLock { folders } }
    }
    let seen = Seen()
    let totals = WorkerDiffTotals { folder, _ in
        seen.add(folder)
        return folder == "/w/plain" ? nil : DiffTotal(added: 1, removed: 0)
    }
    await totals.refresh()
    #expect(seen.all.isEmpty && totals.byFolder.isEmpty)

    totals.folders = ["/w/a", "/w/plain"]
    await totals.refresh()
    await totals.refresh()
    #expect(totals.byFolder == ["/w/a": DiffTotal(added: 1, removed: 0)])
    #expect(seen.all.filter { $0 == "/w/a" }.count >= 2 && Set(seen.all) == ["/w/a", "/w/plain"])

    let before = seen.all.count
    totals.folders = []
    await totals.refresh()
    #expect(seen.all.count == before && totals.byFolder.isEmpty)
}
