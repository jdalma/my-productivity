import Foundation
import Testing
@testable import TowerCore

// The task board (T70): `my-team api board-status --json` read into a model, grouped by who has to move.
// No test runs the real my-team: fixtures, and a fake executable where the process itself matters.

private func task(_ id: String, _ state: String, parent: String? = nil, priority: Int = 100, assignee: String? = "dev",
                  reviewer: String? = "rv", ticket: String? = "/tmp/example/T.md", constraints: String? = "none",
                  updated: String? = "2026-11-12T00:00:00.000Z") -> String {
    func q(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
    return """
        {"id":"\(id)","parent_id":\(q(parent)),"title":"title \(id)","ticket_path":\(q(ticket)),"state":"\(state)",
         "assignee":\(q(assignee)),"reviewer":\(q(reviewer)),"priority":\(priority),"base_commit":null,
         "constraints":\(q(constraints)),"assigned_at":null,"created_at":"2026-11-11T00:00:00.000Z","created_by":"pm",
         "updated_at":\(q(updated)),"updated_by":"pm","version":1}
        """
}

private func finding(_ id: String, task: String, severity: String = "low", state: String = "open") -> String {
    #"{"id":"\#(id)","verdict_id":"R1","task_id":"\#(task)","severity":"\#(severity)","summary":"s","repro":"r","state":"\#(state)","fixed_in":null,"created_at":"2026-11-11T00:00:00.000Z"}"#
}

private func statusJSON(tasks: [String], findings: [String] = []) -> String {
    """
    {"ok":true,"store":{"adapter":"sqlite","schema_version":3,"location":"/tmp/example/board.db","board_id":"b"},
     "tasks":[\(tasks.joined(separator: ","))],
     "workers":[{"name":"pm","role":"orchestrator","assigned":0,"reviewing":0},{"name":"dev","role":"worker","assigned":2,"reviewing":0}],
     "open_findings":[\(findings.joined(separator: ","))],
     "recent":[{"seq":7,"at":"2026-11-11T01:00:00.000Z","actor":"rv","action":"verdict","kind":"verdict","ref":"R1","state_from":"review","state_to":"changes","detail":null},
               {"seq":8,"at":"2026-11-11T01:00:01.000Z","actor":"pm","action":"note","kind":"note","ref":"T1","state_from":null,"state_to":null,"detail":{"to":["dev"]}}],
     "announcements":[{"seq":1,"body":"example announcement","created_at":"2026-11-11T00:00:00.000Z","created_by":"pm"}]}
    """
}

private func ok(_ json: String) -> CommandResult { CommandResult(status: 0, stdout: json, stderr: "") }

private func status(_ json: String) throws -> TaskBoardStatus {
    guard case .ok(let s) = parseTaskBoard(ok(json)) else { throw MyTeamError(description: "not ok") }
    return s
}

@Test func boardStatusJSONBecomesTheModel() throws {
    let s = try status(statusJSON(tasks: [task("T1", "doing"), task("T1a", "ready", parent: "T1", assignee: nil, reviewer: nil)],
                                  findings: [finding("R1 L1", task: "T1", severity: "must")]))
    #expect(s.tasks.map(\.id) == ["T1", "T1a"])
    #expect(s.tasks[1].parentId == "T1" && s.tasks[1].assignee == nil)
    #expect(s.tasks[0].ticketPath == "/tmp/example/T.md" && s.tasks[0].priority == 100 && s.tasks[0].createdBy == "pm")
    #expect(s.workers.map(\.name) == ["pm", "dev"] && s.workers[1].assigned == 2)
    #expect(s.openFindings.map(\.severity) == ["must"] && s.openFindings[0].taskId == "T1")
    #expect(s.recent.map(\.seq) == [7, 8] && s.recent[0].stateTo == "changes")
    #expect(s.recent[1].detail == nil, "a detail that is not a string is left out, not a parse failure")
    #expect(s.announcements.first?.body == "example announcement")
}

@Test func eachActionReasonPutsATaskInTheActionGroup() throws {
    let s = try status(statusJSON(tasks: [
        task("T1", "held"),
        task("T2", "new", assignee: nil),
        task("T3", "done"),
        task("T4", "review", ticket: nil),
        task("T5", "review", constraints: "  "),
        task("T6", "review"),
        task("T7", "changes"), task("T8", "doing"), task("T9", "ready"),
        task("T10", "cancelled"),
    ], findings: [finding("R1 L1", task: "T3"), finding("R1 L2", task: "T3", severity: "should")]))
    let g = taskGroups(s)
    #expect(g[.action]?.map(\.task.id) == ["T1", "T2", "T3", "T4", "T5"])
    #expect(g[.action]?.map(\.reasons) == [[.held], [.unassigned], [.openFindings(2)],
                                           [.incompleteReview(missing: ["ticket_path"])],
                                           [.incompleteReview(missing: ["constraints"])]])
    #expect(g[.review]?.map(\.task.id) == ["T6"])
    #expect(g[.active]?.map(\.task.id) == ["T7", "T8", "T9"])
    #expect(g[.finished]?.map(\.task.id) == ["T10"])
    #expect(actionCount(s) == 5)
    #expect(g[.action]?[2].worstSeverity == "should" && g[.action]?[2].findingCount == 2)
}

@Test func theActionGroupWinsWhenReasonsOverlapAndOrderFollowsTheBoard() throws {
    // a done task with an open finding is action, not finished; a held child shows alone, its parent is in progress
    let s = try status(statusJSON(tasks: [
        task("T9", "doing", priority: 50),
        task("T2", "done", priority: 100),
        task("T1", "doing", priority: 100),
        task("T1b", "ready", parent: "T1", priority: 100),
        task("T1a", "held", parent: "T1", priority: 10),
        task("T3", "done", priority: 100),
    ], findings: [finding("R1 L1", task: "T2", state: "open")]))
    let g = taskGroups(s)
    #expect(g[.action]?.map(\.task.id) == ["T1a", "T2"])
    #expect(g[.action]?.map(\.child) == [false, false], "a child in another group than its parent stands alone")
    #expect(g[.active]?.map(\.task.id) == ["T9", "T1", "T1b"], "priority first, then id; a child right under its parent")
    #expect(g[.active]?.map(\.child) == [false, false, true])
    #expect(g[.finished]?.map(\.task.id) == ["T3"])
}

@Test func failuresAreToldApartByWhatTheProcessGave() {
    func read(_ status: Int32, _ out: String, _ err: String = "") -> TaskBoardRead { parseTaskBoard(CommandResult(status: status, stdout: out, stderr: err)) }
    func code(_ c: String) -> String { #"{"ok":false,"code":"\#(c)","message":"m \#(c)"}"# }
    #expect(read(1, code("board-unavailable")) == .failed(.code("board-unavailable", "m board-unavailable")))
    #expect(read(1, code("forbidden")) == .failed(.code("forbidden", "m forbidden")))
    #expect(read(0, "not json") == .failed(.unreadable("not json")))
    #expect(read(127, "", "env: node: No such file or directory") == .failed(.launch("env: node: No such file or directory")))
    #expect(read(Int32(SIGTERM), "", "") == .failed(.timeout), "runCommand's kill after its timeout")

    #expect(taskBoardProblem(.launch("x"), bin: "/opt/example/my-team").title == "my-team을 실행하지 못했습니다")
    #expect(taskBoardProblem(.launch("x"), bin: "/opt/example/my-team").detail.contains("/opt/example/my-team"))
    #expect(taskBoardProblem(.code("board-unavailable", ""), bin: "").title.contains("Node 22.13"))
    #expect(taskBoardProblem(.code("schema-too-new", ""), bin: "").title.contains("더 새 my-team"))
    #expect(taskBoardProblem(.code("forbidden", ""), bin: "").title == "앱이 다른 팀 워커의 환경으로 실행됐습니다")
    #expect(taskBoardProblem(.code("other-code", "msg"), bin: "").title == "작업판을 읽지 못했습니다")
    #expect(taskBoardProblem(.code("other-code", "msg"), bin: "").detail.contains("other-code"))
    #expect(taskBoardProblem(.unreadable("x"), bin: "").title == "작업판을 읽지 못했습니다")
    #expect(taskBoardProblem(.timeout, bin: "").title == "작업판을 읽지 못했습니다")
}

@Test func oneBusyIsQuietAndOldDataStaysWithALine() throws {
    let s = try status(statusJSON(tasks: [task("T1", "doing")]))
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var st = TaskBoardState()
    st.apply(.ok(s), at: t0)
    #expect(st.problem(now: t0) == nil)
    st.apply(.failed(.code("busy", "")), at: t0.addingTimeInterval(5))
    #expect(st.problem(now: t0.addingTimeInterval(5)) == nil, "one busy is passed over quietly")
    st.apply(.failed(.code("busy", "")), at: t0.addingTimeInterval(10))
    #expect(st.problem(now: t0.addingTimeInterval(10)) != nil, "two in a row show")
    #expect(st.status == s, "the last data stays")
    st.apply(.ok(s), at: t0.addingTimeInterval(15))
    #expect(st.problem(now: t0.addingTimeInterval(15)) == nil)
    #expect(st.problem(now: t0.addingTimeInterval(46))?.contains("전") == true, "older than 30 s: says when it is from")
    st.apply(.failed(.code("forbidden", "")), at: t0.addingTimeInterval(50))
    #expect(st.problem(now: t0.addingTimeInterval(50)) != nil, "anything else shows at once")
    #expect(st.shownFailure == .code("forbidden", ""))
}

@Test func aFirstReadThatIsBusyStillSaysReadingAndAgeUnderAMinuteIsInSeconds() throws {
    // R6 L1: no data yet and one busy: nothing to show as a failure, so the board keeps saying it is reading
    var st = TaskBoardState()
    st.apply(.failed(.code("busy", "")), at: Date())
    #expect(st.status == nil && st.shownFailure == nil)
    st.apply(.failed(.code("busy", "")), at: Date())
    #expect(st.shownFailure == .code("busy", ""))
    // R6 L2: 45 s old is not "0분 전"
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var ok = TaskBoardState()
    ok.apply(.ok(try status(statusJSON(tasks: []))), at: t0)
    let line = try #require(ok.problem(now: t0.addingTimeInterval(45)))
    #expect(line.contains("45초 전") && !line.contains("0분 전"), "\(line)")
    #expect(ok.problem(now: t0.addingTimeInterval(130))?.contains("2분 전") == true)
}

@Test func noTaskBoardTeamMeansMyTeamNeverRuns() throws {
    let plain = Team(name: "plain", sessionName: "my-team-plain", startedAt: nil, attached: false, workers: [])
    var boarded = Team(name: "boarded", sessionName: "my-team-boarded", startedAt: nil, attached: false, workers: [])
    boarded.hasTaskBoard = true
    var calls: [[String]] = []
    let run: TaskBoardRunner = { argv, _, _ in calls.append(argv); return ok(statusJSON(tasks: [])) }
    #expect(readTaskBoards(Board(at: "", teams: [plain], loose: []), bin: "/opt/example/my-team", run: run).isEmpty)
    #expect(calls.isEmpty)
    let reads = readTaskBoards(Board(at: "", teams: [plain, boarded], loose: []), bin: "/opt/example/my-team", run: run)
    #expect(Array(reads.keys) == ["boarded"])
    #expect(calls == [["/opt/example/my-team", "api", "board-status", "--input", #"{"team_name":"boarded"}"#, "--json"]])
}

@Test func theManifestBoardKeyMarksATaskBoardTeam() throws {
    let base = try myTeamBase()
    try writeTeam(base, "plain")
    try write("\(base)/boarded/manifest.json", """
        {"team_name":"boarded","state_root":"\(base)/boarded","session_name":"my-team-b:0","board":{"store":"sqlite"},"workers":[]}
        """)
    let teams = try loadTeams(base: base, panes: [])
    #expect(teams.map(\.hasTaskBoard) == [true, false])
    #expect(toTeam(teams[0], clients: []).hasTaskBoard)
}

@Test func theCallLeavesWorkerVariablesOut() throws {
    // a fake my-team that prints the environment it got
    let dir = try myTeamBase()
    let fake = "\(dir)/my-team"
    try write(fake, "#!/bin/sh\nenv\n")
    chmod(fake, 0o755)
    setenv("MY_TEAM_WORKER", "example/w", 1)
    setenv("MY_TEAM_STATE_ROOT", "/tmp/example", 1)
    setenv("OMC_TEAM_WORKER", "example/w", 1)
    defer { unsetenv("MY_TEAM_WORKER"); unsetenv("MY_TEAM_STATE_ROOT"); unsetenv("OMC_TEAM_WORKER") }
    let r = try liveTaskBoardRunner([fake], 3, Set(taskBoardUnset))
    #expect(!r.stdout.contains("MY_TEAM_WORKER="))
    #expect(!r.stdout.contains("MY_TEAM_STATE_ROOT="))
    #expect(!r.stdout.contains("OMC_TEAM_WORKER="))
    #expect(r.stdout.contains("PATH="))
}

@Test func aReadKeepsTheSelectedTaskWhileItIsThere() throws {
    let a = try status(statusJSON(tasks: [task("T1", "doing"), task("T2", "review")]))
    let b = try status(statusJSON(tasks: [task("T1", "review"), task("T2", "done")]))
    let c = try status(statusJSON(tasks: [task("T2", "done")]))
    #expect(keepTaskSelection("T1", in: a) == "T1")
    #expect(keepTaskSelection("T1", in: b) == "T1", "the task moved to another group: still selected")
    #expect(keepTaskSelection("T1", in: c) == nil, "gone from the board")
    #expect(keepTaskSelection(nil, in: a) == nil)
}

@Test func boardTimesAreTwentyFourHour() throws {
    // D1 (designer review): 16:50 must not read as 04:50
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    let afternoon = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 16, minute: 50)))
    #expect(boardClock(afternoon) == "16:50")
    #expect(boardClock(afternoon, withDay: true) == "11/03 16:50")
    let morning = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 4, minute: 5)))
    #expect(boardClock(morning) == "04:05")
    var st = TaskBoardState()
    st.apply(.ok(try status(statusJSON(tasks: []))), at: afternoon)
    #expect(st.problem(now: afternoon.addingTimeInterval(120))?.contains("(16:50)") == true)
}
