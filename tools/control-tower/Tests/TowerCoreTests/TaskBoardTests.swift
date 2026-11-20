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
    #expect(st.problem(now: afternoon.addingTimeInterval(120))?.contains("16:50에 읽은 내용입니다(2분 전)") == true)
}



/// T152: every one of the nine states in its panel; the decisions panel lists no task.
@Test func eachStateGoesToItsPanel() throws {
    let s = try status(statusJSON(tasks: [
        task("T1", "new", assignee: nil), task("T2", "ready"), task("T3", "doing"), task("T4", "changes"),
        task("T5", "review"), task("T6", "held"), task("T7", "done"), task("T8", "cancelled"), task("T9", "paused"),
    ]))
    let p = taskPanels(s)
    #expect(p[.start]?.map(\.task.id) == ["T1", "T2"])
    #expect(p[.doing]?.map(\.task.id) == ["T3", "T4", "T9"], "an unknown state goes on as in progress")
    #expect(p[.review]?.map(\.task.id) == ["T5"])
    #expect(p[.held]?.map(\.task.id) == ["T6"])
    #expect(p[.done]?.map(\.task.id) == ["T7", "T8"])
    #expect(p[.decisions] == [])
    #expect(TaskPanel.allCases == [.start, .decisions, .doing, .review, .held, .done], "the user's default order")
    #expect(Set(p.keys) == Set(TaskPanel.allCases), "a panel with no task is there, empty")
}

/// T152 (S2): pm's move is a tag on the line, for what was the pm group and the tidy one.
@Test func pmsMoveIsOnTheLine() throws {
    let s = try status(statusJSON(tasks: [
        task("T1", "held"), task("T2", "new", assignee: nil), task("T3", "done"), task("T4", "review", ticket: nil),
        task("T5", "review", constraints: "  "), task("T6", "review"), task("T7", "done"), task("T8", "doing"),
    ], findings: [finding("R1 L1", task: "T3"), finding("R1 L2", task: "T3", severity: "should"),
                  finding("R2 L1", task: "T7", state: "fixed")]))
    let lines = Dictionary(uniqueKeysWithValues: taskPanels(s).values.joined().map { ($0.task.id, $0) })
    #expect(lines["T1"]?.reasons == [.held] && lines["T2"]?.reasons == [.unassigned])
    #expect(lines["T3"]?.reasons == [.openFindings(2)] && lines["T3"]?.severities.first?.severity == "should")
    #expect(lines["T7"]?.reasons == [.openFindings(1)], "low only, and fixed in a landing no approve covers yet: still pm's to tidy")
    #expect(lines["T4"]?.reasons == [.incompleteReview(missing: ["ticket_path"])])
    #expect(lines["T5"]?.reasons == [.incompleteReview(missing: ["constraints"])])
    #expect(lines["T6"]?.reasons == [] && lines["T8"]?.reasons == [])
}

/// The board's order in a panel: priority, then id; a child right under its parent when both are in the panel.
@Test func aPanelFollowsTheBoardsOrderWithAChildUnderItsParent() throws {
    let s = try status(statusJSON(tasks: [
        task("T9", "doing", priority: 50), task("T1", "doing", priority: 100), task("T1b", "changes", parent: "T1", priority: 100),
        task("T1a", "held", parent: "T1", priority: 10),
    ]))
    let p = taskPanels(s)
    #expect(p[.doing]?.map(\.task.id) == ["T9", "T1", "T1b"] && p[.doing]?.map(\.child) == [false, false, true])
    #expect(p[.held]?.map(\.child) == [false], "a child in another panel than its parent stands alone")
}

/// T152 (v4 §7.2): the step a line shows from its state; a waiting task's from where it goes back to.
@Test func eachStateIsAStepAndACancelledOneHasNone() throws {
    let s = try status(statusJSON(tasks: ["new", "ready", "doing", "changes", "review", "held", "done", "cancelled"].map { task($0, $0) }))
    #expect(s.tasks.map(taskStep) == [.registered, .assigned, .working, .working, .review, .review, .done, nil])
}

/// T152 (v4 §7.7): folds kept by team in one string, a name the app does not know left out, and the decisions
/// panel opened once by a decision not seen.
@Test func foldsAreKeptByTeamAndANewDecisionOpensTheirPanel() {
    var a = TaskPanelPrefs()
    a.setFolded(.done, true)
    a.setFolded(.decisions, true)
    let stored = storedPanelPrefs(["alpha": a, "beta": TaskPanelPrefs()])
    let read = readPanelPrefs(stored)
    #expect(read["alpha"]?.folded == [.done, .decisions] && read["beta"]?.folded == [])
    #expect(readPanelPrefs(#"{"alpha":{"folded":["done","gone"]}}"#)["alpha"]?.folded == [.done], "an unknown panel is left out")
    #expect(readPanelPrefs("").isEmpty && readPanelPrefs("{").isEmpty)
    #expect(unfoldingForNewDecisions(a, before: nil, now: ["D#1"]) == a, "the window's first read tells nothing new")
    #expect(unfoldingForNewDecisions(a, before: ["D#1"], now: ["D#1"]) == a)
    #expect(unfoldingForNewDecisions(a, before: ["D#1"], now: []) == a, "an answered one opens nothing")
    #expect(unfoldingForNewDecisions(a, before: ["D#1"], now: ["D#1", "D#2"]).folded == [.done])
}

/// A task waiting on the user, going back to `resume` once answered.
private func waiting(_ id: String, resume: String) -> String {
    task(id, "waiting").replacingOccurrences(of: #""version":1}"#,
                                             with: #""version":1,"waiting":{"question":"Q?","resume_state":"\#(resume)"}}"#)
}

/// R9 L5: a waiting task's step and panel are those of the state it goes back to, `new` too.
@Test func aWaitingTasksStepAndPanelAreWhereItGoesBack() throws {
    let s = try status(statusJSON(tasks: [waiting("T1", resume: "new"), waiting("T2", resume: "review"), waiting("T3", resume: "doing")]))
    #expect(s.tasks.map(taskStep) == [.registered, .review, .working])
    #expect(s.tasks.map(panel(of:)) == [.start, .review, .doing])
}

/// R9 L1, L5: a pick from elsewhere opens its folded panel, a decision's too; not while a search shows it anyway.
@Test func aPickFromElsewhereOpensItsPanelButASearchDoesNot() throws {
    let s = try status(statusJSON(tasks: [task("T1", "doing"), task("T2", "done")]))
    let folded = TaskPanelPrefs(folded: [.doing, .decisions, .done])
    #expect(unfoldingForPick(folded, pick: "T1", in: s, searching: false).folded == [.decisions, .done])
    #expect(unfoldingForPick(folded, pick: "D#1", in: s, searching: false).folded == [.doing, .done])
    #expect(unfoldingForPick(folded, pick: "T1", in: s, searching: true) == folded, "the search shows it; cleared, it folds back")
    #expect(unfoldingForPick(folded, pick: "T9", in: s, searching: false) == folded, "not on the board")
    #expect(unfoldingForPick(folded, pick: nil, in: s, searching: false) == folded)
}

/// R9 L3: one team's value that does not read loses only that team's folds.
@Test func oneTeamsBadPrefsLoseOnlyThatTeams() {
    let read = readPanelPrefs(#"{"a":{},"b":{"folded":["done"]},"c":3,"d":{"folded":"done"}}"#)
    #expect(read["b"]?.folded == [.done])
    #expect(read["a"]?.folded == [] && read["d"]?.folded == [])
}

// T153: the layout the user sets (v4 §7.9, pm 11-16): the panels' order, the tasks on top, the heights.

/// Stored and read back; an unknown panel dropped, a missing one at the end, a repeated one once.
@Test func aLayoutIsKeptAndReadsWhateverItHolds() throws {
    var a = try #require(TaskPanelPrefs().moving(.done, by: -1))
    #expect(a.order == [.start, .decisions, .doing, .review, .done, .held])
    a = a.setting(height: 236, for: .doing)
    a = try #require(a.moving(task: "T2", in: .doing, .top))
    a.setFolded(.held, true)
    let read = try #require(readPanelPrefs(storedPanelPrefs(["t": a]))["t"])
    #expect(read == a)
    let odd = try #require(readPanelPrefs(#"{"t":{"columns":[["done","gone","done","review"]],"heights":"x"}}"#)["t"])
    #expect(odd.order == [.done, .review, .start, .decisions, .doing, .held])
    #expect(odd.height(.doing) == nil, "a field that does not read is nothing")
    #expect(!TaskPanelPrefs().hasLayout && storedPanelPrefs(["t": TaskPanelPrefs()]) == #"{"t":{"folded":[]}}"#)
}

@Test func aPanelMovesUpDownAndIsPlacedAndTheLayoutResetsButNotTheFolds() throws {
    let p = TaskPanelPrefs()
    #expect(p.moving(.start, by: -1) == nil && p.moving(.done, by: 1) == nil, "nowhere to go")
    #expect(p.moving(.review, by: -1)?.order == [.start, .decisions, .review, .doing, .held, .done])
    #expect(p.placing(.done, at: 0)?.order == [.done, .start, .decisions, .doing, .review, .held])
    #expect(p.placing(.start, at: 6)?.order == [.decisions, .doing, .review, .held, .done, .start], "past the last")
    #expect(p.placing(.doing, at: 2) == nil && p.placing(.doing, at: 3) == nil, "its own place, either side")
    var moved = try #require(p.moving(.done, by: -1)).setting(height: 100, for: .start)
    moved.setFolded(.review, true)
    #expect(moved.resetLayout.order == TaskPanel.allCases && moved.resetLayout.height(.start) == nil)
    #expect(moved.resetLayout.folded == [.review] && !moved.resetLayout.hasLayout)
}

private func lines(_ ids: [String], parent: [String: String] = [:]) throws -> [TaskLine] {
    let s = try status(statusJSON(tasks: ids.map { task($0, "doing", parent: parent[$0]) }))
    return taskPanels(s)[.doing] ?? []
}

/// v4 §7.9.1: the tasks on top first in the user's order, the rest in the board's; the menu's moves.
@Test func theTasksOnTopComeFirstAndTheMenuMovesThem() throws {
    let all = try lines(["T1", "T2", "T3", "T4"])
    var p = try #require(TaskPanelPrefs().moving(task: "T3", in: .doing, .up))
    #expect(p.pins(.doing) == ["T3"], "up from the rest: the end of the ones on top")
    p = try #require(p.moving(task: "T4", in: .doing, .top))
    let a = p.arranging(all, in: .doing)
    #expect(a.top.map(\.task.id) == ["T4", "T3"] && a.rest.map(\.task.id) == ["T1", "T2"])
    #expect(p.moving(task: "T4", in: .doing, .up) == nil && p.moving(task: "T4", in: .doing, .top) == nil, "first already")
    #expect(p.moving(task: "T3", in: .doing, .down) == nil, "the last on top: down is unpin's job")
    #expect(p.moving(task: "T1", in: .doing, .down) == nil && p.moving(task: "T1", in: .doing, .unpin) == nil)
    #expect(p.moving(task: "T4", in: .doing, .down)?.pins(.doing) == ["T3", "T4"])
    #expect(p.moving(task: "T4", in: .doing, .unpin)?.pins(.doing) == ["T3"])
    #expect(p.moving(task: "T3", in: .review, .up)?.pins(.doing) == ["T4", "T3"], "each panel its own")
}

/// v4 §7.9.1 table: where a dropped line goes.
@Test func aDroppedLineGoesWhereTheTableSays() throws {
    let p = try #require(TaskPanelPrefs().moving(task: "T3", in: .doing, .up)?.moving(task: "T4", in: .doing, .up))
    // on screen: T3 T4 | T1 T2 (slots 0…4)
    #expect(p.dropping(task: "T1", in: .doing, at: 1)?.pins(.doing) == ["T3", "T1", "T4"], "from the rest in among the top")
    #expect(p.dropping(task: "T1", in: .doing, at: 2)?.pins(.doing) == ["T3", "T4", "T1"], "at the boundary")
    #expect(p.dropping(task: "T2", in: .doing, at: 3)?.pins(.doing) == ["T3", "T4", "T2"], "in the rest: the end of the top")
    #expect(p.dropping(task: "T4", in: .doing, at: 0)?.pins(.doing) == ["T4", "T3"], "within the top")
    #expect(p.dropping(task: "T3", in: .doing, at: 2)?.pins(.doing) == ["T4", "T3"], "to the end of the top")
    #expect(p.dropping(task: "T3", in: .doing, at: 4)?.pins(.doing) == ["T4"], "from the top into the rest: back to its place")
    #expect(p.dropping(task: "T3", in: .doing, at: 0) == nil && p.dropping(task: "T3", in: .doing, at: 1) == nil, "its own place")
}

/// v4 §7.9.3: a task that leaves its panel, or the board, is no longer on top, and is not again when it comes back.
@Test func aTaskThatLeavesItsPanelIsNoLongerOnTop() throws {
    let p = try #require(TaskPanelPrefs().moving(task: "T1", in: .doing, .up)?.moving(task: "T2", in: .doing, .up))
    let s = try status(statusJSON(tasks: [task("T1", "review"), task("T2", "changes")]))
    let cleaned = p.cleaned(taskPanels(s))
    #expect(cleaned.pins(.doing) == ["T2"], "T1 went to review; T2 is still in progress (changes)")
    let back = try status(statusJSON(tasks: [task("T1", "doing"), task("T2", "doing")]))
    #expect(cleaned.cleaned(taskPanels(back)).pins(.doing) == ["T2"], "back in progress, T1 is not on top again")
    #expect(p.cleaned([:]).pins(.doing) == [], "gone from the board")
}

/// A child put on top stands alone; one whose parent went on top does too.
@Test func aChildOnTopOrUnderAParentOnTopStandsAlone() throws {
    let all = try lines(["T1", "T1a", "T2"], parent: ["T1a": "T1"])
    let up = try #require(TaskPanelPrefs().moving(task: "T1", in: .doing, .up))
    let a = up.arranging(all, in: .doing)
    #expect(a.rest.map(\.task.id) == ["T1a", "T2"] && a.rest.map(\.child) == [false, false])
    #expect(try #require(TaskPanelPrefs().moving(task: "T1a", in: .doing, .up)).arranging(all, in: .doing).top.map(\.child) == [false])
}

/// v4 §7.9.5, pm 5: a dragged height between three lines and the list less a head; as tall as the lines, it fits them.
@Test func aDraggedHeightIsHeldAndFitsItsLinesWhenTallEnough() {
    #expect(TaskPanelPrefs.fitted(150, least: 90, content: 400, most: 600) == 150)
    #expect(TaskPanelPrefs.fitted(40, least: 90, content: 400, most: 600) == 90, "three lines at least")
    #expect(TaskPanelPrefs.fitted(400, least: 90, content: 400, most: 600) == nil, "as tall as its lines: fits them")
    #expect(TaskPanelPrefs.fitted(500, least: 90, content: 800, most: 450) == 450, "the list less a head at most")
    #expect(TaskPanelPrefs.fitted(60, least: 90, content: 70, most: 600) == nil, "fewer lines than three: fits them")
    #expect(!ordersLines(.done) && !ordersLines(.decisions) && ordersLines(.doing))
}

/// R17 S2: ⌘Z puts back the layout and keeps what was folded since.
@Test func undoingALayoutKeepsTheFoldsMadeSince() throws {
    let before = TaskPanelPrefs()
    var now = try #require(before.moving(.done, by: -1)?.setting(height: 120, for: .doing).moving(task: "T1", in: .doing, .up))
    now.setFolded(.review, true)
    let back = now.withLayout(of: before)
    #expect(back.order == TaskPanel.allCases && back.height(.doing) == nil && back.pins(.doing).isEmpty)
    #expect(back.folded == [.review], "the fold made after the move stays")
}

// MARK: - columns of panels (T154; v4 §7.8, hig §7.3)

private func twoColumns() throws -> TaskPanelPrefs {
    try #require(readPanelPrefs(#"{"t":{"columns":[["start","doing","held"],["decisions","review","done"]]}}"#)["t"])
}

@Test func aListHasRoomForAsManyColumnsAsItsWidthHolds() {
    #expect(panelColumnsFitting(width: 519, scale: 1) == 1 && panelColumnsFitting(width: 0, scale: 1) == 1, "one at least")
    #expect(panelColumnsFitting(width: 520, scale: 1) == 1)
    #expect(panelColumnsFitting(width: 1051, scale: 1) == 1, "two columns and the gap between them need 1052")
    #expect(panelColumnsFitting(width: 1052, scale: 1) == 2)
    #expect(panelColumnsFitting(width: 1416, scale: 1) == 2, "a 1440 window without the detail")
    #expect(panelColumnsFitting(width: 1896, scale: 1) == 3, "a 1920 screen")
    #expect(panelColumnsFitting(width: 1416, scale: 1.5) == 1, "larger text needs wider columns")
}

/// What T153 kept (one column) reads as one column; what this keeps reads back, and reads in reading order where
/// only the order is asked.
@Test func aLayoutOfColumnsIsKeptAndTheOneColumnOfBeforeStillReads() throws {
    let before = try #require(readPanelPrefs(#"{"t":{"columns":[["review","start"]],"pinned":{"doing":["T1"]}}}"#)["t"])
    #expect(before.layout == [[.review, .start, .decisions, .doing, .held, .done]] && before.pins(.doing) == ["T1"])
    let two = try twoColumns()
    #expect(two.layout == [[.start, .doing, .held], [.decisions, .review, .done]])
    #expect(two.order == [.start, .doing, .held, .decisions, .review, .done], "the first column, then the next")
    #expect(try #require(readPanelPrefs(storedPanelPrefs(["t": two]))["t"]) == two)
    #expect(TaskPanelPrefs().layout == [TaskPanel.allCases])
    let odd = try #require(readPanelPrefs(#"{"t":{"columns":[["done","gone"],[],["gone"],["review","done"]]}}"#)["t"])
    #expect(odd.layout == [[.done], [.review, .start, .decisions, .doing, .held]], "no empty column; what is missing ends the last")
}

/// hig D8: a list too narrow for the columns shows them as one, first column first, and keeps what is stored.
@Test func aNarrowListShowsTheColumnsAsOneInReadingOrderAndKeepsThem() throws {
    let two = try twoColumns()
    #expect(two.shownColumns(room: 2) == two.layout && two.shownColumns(room: 3) == two.layout)
    #expect(two.shownColumns(room: 1) == [[.start, .doing, .held, .decisions, .review, .done]])
    let three = try #require(two.moving(.done, toColumn: 1, room: 3))
    #expect(three.layout.count == 3 && three.shownColumns(room: 2) == [three.order], "three do not fit in two: one column")
    #expect(two.shownColumns(room: 1) != two.layout && two.layout.count == 2, "what is kept is not changed by asking")
}

@Test func aPanelMovesWithinItsColumnAndToTheNextColumn() throws {
    let two = try twoColumns()
    #expect(two.moving(.doing, by: -1, room: 2)?.layout == [[.doing, .start, .held], [.decisions, .review, .done]])
    #expect(two.moving(.decisions, by: -1, room: 2) == nil && two.moving(.held, by: 1, room: 2) == nil, "the ends of a column")
    #expect(two.moving(.doing, toColumn: 1, room: 2)?.layout == [[.start, .held], [.decisions, .doing, .review, .done]], "as far down as it was")
    #expect(two.moving(.held, toColumn: 1, room: 2)?.layout == [[.start, .doing], [.decisions, .review, .held, .done]])
    #expect(two.moving(.review, toColumn: -1, room: 2)?.layout == [[.start, .review, .doing, .held], [.decisions, .done]])
    #expect(two.moving(.start, toColumn: -1, room: 2) == nil, "nothing on the left")
    #expect(two.moving(.done, toColumn: 1, room: 2) == nil, "no room for a third column")
    #expect(two.moving(.done, toColumn: 1, room: 3)?.layout == [[.start, .doing, .held], [.decisions, .review], [.done]], "a new column")
    let one = TaskPanelPrefs()
    #expect(one.moving(.review, toColumn: 1, room: 1) == nil)
    #expect(one.moving(.review, toColumn: 1, room: 2)?.layout == [[.start, .decisions, .doing, .held, .done], [.review]])
    let alone = try #require(one.moving(.review, toColumn: 1, room: 2))
    #expect(alone.moving(.review, toColumn: 1, room: 3) == nil, "alone in its column: a new one would be the same")
    #expect(alone.moving(.review, toColumn: -1, room: 2)?.layout == [[.review, .start, .decisions, .doing, .held, .done]], "as far down as it was, and its column is gone with it")
    #expect(two.moving(.doing, toColumn: 1, room: 1) == nil, "shown as one column: there is no next column")
}

/// v4 §7.8: in a list too narrow for the columns a move goes by reading order and lands in the column of the panel
/// it is put before, so the order made there fits the columns once the list is wide again.
@Test func aMoveInANarrowListGoesByReadingOrderAndFitsTheColumns() throws {
    let two = try twoColumns()
    #expect(two.moving(.held, by: 1)?.layout == [[.start, .doing], [.decisions, .held, .review, .done]], "past the first of the next column")
    #expect(two.moving(.decisions, by: -1)?.layout == [[.start, .doing, .decisions, .held], [.review, .done]], "before the last of the column before")
    #expect(two.moving(.start, by: -1) == nil && two.moving(.done, by: 1) == nil)
    // R21 L1: two panels of one column swap and both stay in it
    #expect(two.moving(.doing, by: 1)?.layout == [[.start, .held, .doing], [.decisions, .review, .done]])
    #expect(two.moving(.held, by: -1)?.layout == [[.start, .held, .doing], [.decisions, .review, .done]])
    #expect(two.moving(.start, by: 1)?.layout == [[.doing, .start, .held], [.decisions, .review, .done]])
    #expect(two.moving(.done, by: -1)?.layout == [[.start, .doing, .held], [.decisions, .done, .review]])
    #expect(two.moving(.start, by: 2)?.layout == [[.doing, .held, .start], [.decisions, .review, .done]], "two places, one at a time")
    #expect(two.placing(.start, at: 6)?.layout == [[.doing, .held], [.decisions, .review, .done, .start]], "past the last: the end of the last column")
    #expect(two.placing(.done, at: 1)?.layout == [[.start, .done, .doing, .held], [.decisions, .review]])
    #expect(two.placing(.held, at: 3) == nil, "before the first of the next column: the order stays, and so does the layout")
    #expect(two.placing(.held, at: 2) == nil)
}

@Test func aPanelDroppedInAColumnGoesWhereItWasDropped() throws {
    let two = try twoColumns()
    #expect(two.dropping(.done, column: 0, at: 0)?.layout == [[.done, .start, .doing, .held], [.decisions, .review]])
    #expect(two.dropping(.done, column: 0, at: 9)?.layout == [[.start, .doing, .held, .done], [.decisions, .review]], "past the last: the end")
    #expect(two.dropping(.start, column: 0, at: 3)?.layout == [[.doing, .held, .start], [.decisions, .review, .done]], "down its own column")
    #expect(two.dropping(.doing, column: 0, at: 1) == nil && two.dropping(.doing, column: 0, at: 2) == nil, "its own place, either side")
    #expect(two.dropping(.held, column: 1, at: 0)?.layout == [[.start, .doing], [.held, .decisions, .review, .done]], "the same reading order, another column")
    #expect(two.dropping(.review, column: 2, at: 0)?.layout == [[.start, .doing, .held], [.decisions, .done], [.review]], "a new column")
    #expect(two.dropping(.review, column: 3, at: 0) == nil, "no such column")
    let alone = try #require(TaskPanelPrefs().moving(.review, toColumn: 1, room: 2))
    #expect(alone.dropping(.review, column: 2, at: 0) == nil, "alone in its column")
    #expect(alone.dropping(.review, column: 0, at: 0)?.layout == [[.review, .start, .decisions, .doing, .held, .done]])
    #expect(two.dropping(.done, column: 0, at: 0)?.resetLayout.layout == [TaskPanel.allCases])
}

/// R17 S2 holds for columns: ⌘Z takes the columns back and keeps a fold made since.
@Test func undoingAMoveToAnotherColumnKeepsTheFoldsMadeSince() throws {
    let before = try twoColumns()
    var after = try #require(before.moving(.doing, toColumn: 1, room: 2))
    after.setFolded(.held, true)
    let undone = after.withLayout(of: before)
    #expect(undone.layout == before.layout && undone.folded == [.held])
}

/// R21 L1: for every panel of every layout of two columns, a move up or down in a list shown as one column swaps it
/// with the panel next to it in reading order, and only the moved panel may change column, and only to the column of
/// the panel it passed.
@Test func aMoveInANarrowListChangesNoColumnButTheMovedPanelsOwn() throws {
    let all = TaskPanel.allCases
    for split in 1..<all.count {
        var p = TaskPanelPrefs()
        for q in all[split...] { p = try #require(p.dropping(q, column: 1, at: 9) ?? p.moving(q, toColumn: 1, room: 2)) }
        #expect(p.layout == [Array(all[..<split]), Array(all[split...])])
        let column = { (prefs: TaskPanelPrefs, q: TaskPanel) in prefs.layout.firstIndex { $0.contains(q) } }
        for (i, q) in p.order.enumerated() {
            for by in [-1, 1] {
                guard p.order.indices.contains(i + by) else { #expect(p.moving(q, by: by) == nil); continue }
                let next = try #require(p.moving(q, by: by), "\(q) by \(by) at split \(split)")
                var swapped = p.order
                swapped.swapAt(i, i + by)
                #expect(next.order == swapped, "\(q) by \(by) at split \(split)")
                let neighbor = p.order[i + by]
                for other in all where other != q { #expect(column(next, other) == column(p, other) || next.layout.count < p.layout.count, "\(other) stays") }
                #expect(next.layout.joined().contains(q) && (column(next, q) == column(p, q) || next.layout.first { $0.contains(q) }?.contains(neighbor) == true))
            }
        }
    }
}

// MARK: - history (T157; my-team T156)

private func decodeTask(_ history: String?) throws -> TaskBoardTask {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return try d.decode(TaskBoardTask.self, from: Data(#"{"id":"T1","title":"t","state":"review","priority":100\#(history.map { #","history":\#($0)"# } ?? "")}"#.utf8))
}

@Test func aTasksHistoryIsReadAndAnOlderBoardHasNone() throws {
    let t = try decodeTask(#"{"landings":3,"verdicts":{"approve":0,"changes":2,"hold":1},"last_event":{"action":"land","verdict":null,"by":"core","at":"2026-11-11T00:00:31.000Z","state_from":"doing","state_to":"review"},"state_since":"2026-11-11T00:00:31.000Z","last_progress_by":"core","cancelled_from":null}"#)
    let h = try #require(t.history)
    #expect(h.landings == 3 && h.changes == 2 && h.stateSince == "2026-11-11T00:00:31.000Z" && h.lastProgressBy == "core" && h.cancelledFrom == nil)
    #expect(h.lastEvent == TaskEvent(action: "land", verdict: nil, by: "core", at: "2026-11-11T00:00:31.000Z", stateFrom: "doing", stateTo: "review"))
    #expect(try decodeTask(nil).history == nil)
    #expect(try decodeTask("null").history == nil)
}

/// One task's history of the wrong shape does not fail the board's read: what does not read is as if it were absent.
@Test func aHistoryOfTheWrongShapeKeepsTheTaskAndWhatReads() throws {
    let partial = try #require(try decodeTask(#"{"landings":"three","verdicts":[],"last_event":{"by":"core"},"state_since":7,"cancelled_from":"doing"}"#).history)
    #expect(partial.landings == 0 && partial.changes == 0 && partial.lastEvent == nil && partial.stateSince == nil && partial.cancelledFrom == "doing")
    let odd = try #require(try decodeTask(#""soon""#).history)
    #expect(odd.landings == 0 && odd.lastEvent == nil)
    #expect(try #require(try decodeTask("{}").history).landings == 0)
}

@Test func theStateSinceIsTheBoardsOwnWordElseTheLastChange() throws {
    #expect(stateSince(try decodeTask(#"{"state_since":"2026-11-11T00:00:31.000Z"}"#)) == "2026-11-11T00:00:31.000Z")
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    let old = try d.decode(TaskBoardTask.self, from: Data(#"{"id":"T1","title":"t","state":"doing","priority":100,"created_at":"a","updated_at":"b"}"#.utf8))
    #expect(stateSince(old) == nil, "neither reads as a time")
}

/// R18 L1: a `state_since` that is empty or no time falls back to `updated_at`, then to `created_at`.
@Test func aStateSinceThatIsNoTimeFallsBackToTheLastChange() throws {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    func since(_ history: String, updated: String = "2026-11-11T09:00:00.000Z") throws -> String? {
        stateSince(try d.decode(TaskBoardTask.self, from: Data(#"{"id":"T1","title":"t","state":"doing","priority":1,"created_at":"2026-11-11T07:00:00.000Z","updated_at":"\#(updated)","history":\#(history)}"#.utf8)))
    }
    #expect(try since(#"{"state_since":""}"#) == "2026-11-11T09:00:00.000Z")
    #expect(try since(#"{"state_since":"soon"}"#) == "2026-11-11T09:00:00.000Z")
    #expect(try since(#"{"state_since":"2026-11-11T08:00:00.000Z"}"#) == "2026-11-11T08:00:00.000Z")
    #expect(try since(#"{"state_since":""}"#, updated: "") == "2026-11-11T07:00:00.000Z", "then when it was made")
}

@Test func theBoardsViewAndGoalFoldsAreKeptBesideThePanels() {
    // T214: the 순서 view and its goals' folds go in the same per-team prefs; one that does not read is nothing
    var p = TaskPanelPrefs(folded: [.done])
    p.view = "order"
    p.goalFolds = ["/tmp/example/G3.md": true]
    let back = readPanelPrefs(storedPanelPrefs(["shop": p]))["shop"]
    #expect(back?.view == "order" && back?.goalFolds == ["/tmp/example/G3.md": true] && back?.isFolded(.done) == true)
    #expect(p.resetLayout.view == "order" && p.resetLayout.goalFolds == p.goalFolds)
    let old = readPanelPrefs(#"{"shop":{"folded":["done"]}}"#)["shop"]
    #expect(old?.view == nil && old?.goalFolds.isEmpty == true)
    let odd = readPanelPrefs(#"{"shop":{"folded":["done"],"view":3,"goal_folds":"x"}}"#)["shop"]
    #expect(odd?.isFolded(.done) == true && odd?.view == nil && odd?.goalFolds.isEmpty == true)
}
