import Foundation
import Testing
@testable import TowerCore

// The test instance (T96): a tmux server named by its socket and a dry run of outward actions.

private func scratch() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appending(path: "tower-test-instance-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

@Test func aSocketInTheEnvironmentGoesToTmuxAsDashS() {
    #expect(tmuxCommand([:]) == [towerTmuxBin])
    #expect(tmuxCommand(["TOWER_TMUX_SOCKET": ""]) == [towerTmuxBin])
    #expect(tmuxCommand(["TOWER_TMUX_SOCKET": "/t/tmux.sock"]) == [towerTmuxBin, "-S", "/t/tmux.sock"])
}

/// A socket that is not there fails the command; tmux does not fall back to the default server, whose panes would
/// show here otherwise. Read-only: the default server, if any, is only listed by the control line.
@Test func aMissingSocketFailsInsteadOfReachingTheDefaultServer() throws {
    let missing = try scratch() + "/no.sock"
    let r = try runCommand(tmuxCommand(["TOWER_TMUX_SOCKET": missing]) + ["list-panes", "-a"], timeout: 2)
    #expect(r.status != 0)
    #expect(listPanes(tmux: tmuxCommand(["TOWER_TMUX_SOCKET": missing])).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: missing), "a read never makes a server")
}

@Test func aDryRunIsReadFromTheEnvironment() {
    #expect(dryRunLog([:]) == nil)
    #expect(dryRunLog(["TOWER_DRY_RUN": ""]) == nil)
    #expect(dryRunLog(["TOWER_DRY_RUN": "/t/actions.log"]) == "/t/actions.log")
}

@Test func aDryRunLineIsAppendedOneLineEach() throws {
    let log = try scratch() + "/actions.log"
    recordDryRun("first", to: log)
    recordDryRun("second\nline", to: log)
    #expect(try String(contentsOfFile: log, encoding: .utf8) == "first\nsecond line\n")
}

@Test func aDryRunDoesNotAskGhosttyForItsTerminals() throws {
    #expect(listGhosttyTerminals(dryRun: try scratch() + "/actions.log") == nil)
}

// The test instance's task board fixture (T98): fixture.py writes it, fake-my-team.py answers board-status from it.
// Both scripts run here as the test app runs them, and the answers go through the app's own parsers.

private let testInstanceScripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../scripts/test-instance").standardized.path

private func fixtureDir() throws -> String {
    let t = try scratch()
    let panes = ["alpha", "beta", "gamma", "delta", "epsilon"].enumerated()
        .map { "\($1)\texample-team\t@0\t%\($0)\t\(90000 + $0)" }
        + ["eta", "theta", "iota"].enumerated().map { "\($1)\texample-panes\t@2\t%\($0 + 5)\t\(90005 + $0)" }
        + ["solo\tsolo\t@1\t%9\t90009"]
    try (panes.joined(separator: "\n") + "\n").write(toFile: "\(t)/panes.tsv", atomically: true, encoding: .utf8)
    // a hang guard, not a speed bound: under a loaded run the fixture's git calls took past 30 s (T130)
    let r = try runCommand(["python3", "\(testInstanceScripts)/fixture.py", t, "\(t)/panes.tsv"], timeout: 300)
    #expect(r.status == 0, "\(r.stderr)")
    return t
}

private func fakeMyTeam(_ t: String, _ input: [String: String]) throws -> CommandResult {
    let json = String(decoding: try JSONSerialization.data(withJSONObject: input, options: .sortedKeys), as: UTF8.self)
    return try runCommand(["\(t)/bin/my-team", "api", "board-status", "--input", json, "--json"], timeout: 120)
}

@Test func theFakeMyTeamAnswersTheBoardWithEveryPanelAndEachTasksFamily() throws {
    let t = try fixtureDir()
    guard case .ok(let s) = parseTaskBoard(try fakeMyTeam(t, ["team_name": "example-team"])) else {
        Issue.record("the board did not parse"); return
    }
    let panels = taskPanels(s)
    #expect(TaskPanel.allCases.filter { $0 != .decisions }.allSatisfy { panels[$0]?.isEmpty == false }, "every panel has a task")
    #expect(!openDecisions(s).isEmpty, "and a decision waits")
    #expect(Set(["waiting", "changes", "new", "cancelled"]).isSubset(of: Set(s.tasks.map(\.state))),
            "a waiting, a changes, an unassigned and a cancelled task (T152)")
    #expect(s.announcements.count >= 2)
    #expect(s.tasks.contains { $0.parentId != nil }, "a subtask")
    for task in s.tasks {
        guard case .success(let f) = parseTaskFamily(try fakeMyTeam(t, ["team_name": "example-team", "task": task.id])) else {
            Issue.record("\(task.id)'s family did not parse"); continue
        }
        #expect(f.tasks.contains { $0.id == task.id })
    }
    guard case .success(let three) = parseTaskFamily(try fakeMyTeam(t, ["team_name": "example-team", "task": "T3"])) else { return }
    #expect(three.landings.count == 3 && three.verdicts.filter { $0.verdict == "changes" }.count >= 1)
    guard case .success(let seven) = parseTaskFamily(try fakeMyTeam(t, ["team_name": "example-team", "task": "T7"])) else { return }
    #expect(seven.fixedElsewhere?.first?.approved == true, "a finding fixed by another task")
    guard case .success(let eight) = parseTaskFamily(try fakeMyTeam(t, ["team_name": "example-team", "task": "T8"])) else { return }
    #expect(Set(eight.findings.map(\.state)) == ["backlog", "accepted-limit", "rejected"])
}

/// R41 L1: an answer in the fixture has the shape `board-answer` gives it: the option chosen is one of the brief's
/// labels (or 기타), and the brief kept with it is the one that asked that question, without the state to go back to.
@Test func theFixtureAnswerIsOneOfItsOwnBriefsOptions() throws {
    let t = try fixtureDir()
    guard case .success(let five) = parseTaskFamily(try fakeMyTeam(t, ["team_name": "example-team", "task": "T5"])) else {
        Issue.record("T5's family did not parse"); return
    }
    let answer = try #require(five.answers.first)
    let brief = try #require(answer.brief)
    #expect(brief.question == answer.question)
    #expect((brief.options.map(\.label) + ["기타"]).contains(answer.chosen ?? ""), "\(answer.chosen ?? "nil") in \(brief.options.map(\.label))")
    #expect(brief.resumeState == nil, "board-answer keeps the brief without resume_state")
}

/// T128: T5 is in progress with a ticket of four to-do items, progress on two, and commits in beta's folder since its
/// start commit; the list carries its progress summary.
@Test func theFixtureTaskInProgressHasItsTicketProgressAndCommits() throws {
    let t = try fixtureDir()
    guard case .ok(let s) = parseTaskBoard(try fakeMyTeam(t, ["team_name": "example-team"])),
          case .success(let five) = parseTaskFamily(try fakeMyTeam(t, ["team_name": "example-team", "task": "T5"])) else {
        Issue.record("did not parse"); return
    }
    let task = try #require(s.tasks.first { $0.id == "T5" })
    #expect(task.progressSummary?.doneItems == [1])
    #expect(s.tasks.filter { $0.id != "T5" }.allSatisfy { $0.progressSummary == nil })
    guard case .read(let outline, _) = readTicket(task.ticketPath) else { Issue.record("no ticket"); return }
    #expect(outline.items.count == 4 && outline.goal != nil)
    let (lines, outside) = todoLines(items: outline.items, progress: try #require(taskDetail(five, task: "T5")).progress)
    #expect(lines.map(\.status) == [.done, .doing, .notYet, .notYet] && outside.count == 1)
    let commits = try #require(commitFlow(dir: "\(t)/work/beta", base: task.baseCommit))
    #expect(commits.map(\.subject) == ["example: shapes work", "example: area of each shape", "example: tests for the shapes"])
}

@Test func theFakeMyTeamRefusesEverythingElseAndLogsEveryCall() throws {
    let t = try fixtureDir()
    let other = try runCommand(["\(t)/bin/my-team", "api", "board-land", "--input", "{}", "--json"], timeout: 120)
    #expect(other.status != 0)
    #expect(try fakeMyTeam(t, ["team_name": "some-other-team"]).status != 0)
    let log = try String(contentsOfFile: "\(t)/actions.log", encoding: .utf8).split(separator: "\n")
    #expect(log.count == 2 && log.allSatisfy { $0.hasPrefix("fake-my-team api ") })
}

/// History: an ended session and a worker of an ended team, neither running (T98 fixture).
@Test func theFixtureHistoryHasAnEndedSessionAndAnEndedTeamsWorker() throws {
    let t = try fixtureDir()
    let roots = HistoryRoots(claudeProjects: "\(t)/home/.claude/projects", codexHome: "\(t)/home/.codex")
    let history = collectHistory(board: Board(at: "", teams: [], loose: []), roots: roots, cache: HistoryCache())
    #expect(history.contains { $0.title == "example: ended session" && $0.member == nil })
    #expect(history.contains { $0.member == TeamWorker(team: "old-example-team", worker: "zeta") })
}

/// Two workers' folders are git repositories with different changes, so the diff window has something to switch
/// between (T109).
@Test func theFixtureHasTwoWorkspacesWithDifferentChanges() throws {
    let t = try fixtureDir()
    guard case .diff(let alpha) = workspaceDiff(at: "\(t)/work/alpha", pinnedBase: nil),
          case .diff(let beta) = workspaceDiff(at: "\(t)/work/beta", pinnedBase: nil) else {
        Issue.record("work/alpha and work/beta are git repositories"); return
    }
    #expect(alpha.committed?.files.isEmpty == false && !alpha.uncommitted.files.isEmpty)
    // T128 adds T5's commits on beta's branch
    #expect(beta.committed?.files.map(\.path) == ["lib/area.swift", "lib/shapes.swift", "tests/area_test.swift", "tests/shapes_test.swift"])
    #expect(beta.uncommitted.files.map(\.path) == ["README.md"])
    guard case .notARepo = workspaceDiff(at: "\(t)/work/gamma", pinnedBase: nil) else {
        Issue.record("work/gamma stays outside git"); return
    }
}

/// The second team's workers are panes of one tmux window, and it keeps no task board (T109).
@Test func theFixtureHasATeamWhoseWorkersShareOneWindow() throws {
    let t = try fixtureDir()
    func manifest(_ team: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(t)/my-team/sessions/\(team)/manifest.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    let panes = try manifest("example-panes")
    #expect((panes["workers"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["eta", "theta", "iota"])
    #expect(panes["board"] == nil)
    let first = try manifest("example-team")
    #expect((first["workers"] as? [[String: Any]])?.count == 5 && first["board"] != nil)
    for w in ["eta", "theta", "iota"] {
        #expect(FileManager.default.fileExists(atPath: "\(t)/my-team/sessions/example-panes/workers/\(w)/status.json"))
    }
}

/// The AX tool's refusals (T119): what AX answers while the screen is locked is no window, an element in a menu is
/// pressed by menu-press alone, and nothing is done while the screen is locked. `ax.swift self-test` needs no app.
@Test func theAXToolRefusesMenusAndALockedScreen() throws {
    let tool = URL(fileURLWithPath: testInstanceScripts).deletingLastPathComponent().appending(path: "ax.swift").path
    let r = try runCommand(["/usr/bin/env", "swift", tool, "self-test"], timeout: 300)
    #expect(r.status == 0, "\(r.stdout)\(r.stderr)")
    #expect(r.stdout.contains("self-test: ok"))
}

/// T157: every fixture task carries a history the app reads: one sent back twice with its third submission under
/// review, one whose progress record is later than its last event, and a cancelled one that stopped before anyone
/// took it. What a history says agrees with the rest of the board (R18 L3 to L5).
@Test func theFixtureTasksCarryTheirHistory() throws {
    let t = try fixtureDir()
    let answer = try fakeMyTeam(t, ["team_name": "example-team"])
    guard case .ok(let s) = parseTaskBoard(answer) else { Issue.record("did not parse"); return }
    #expect(s.tasks.allSatisfy { $0.history?.lastEvent != nil && $0.history?.stateSince != nil })
    let three = try #require(s.tasks.first { $0.id == "T3" }?.history)
    #expect(three.landings == 3 && three.changes == 2 && three.lastEvent?.action == "land")
    let five = try #require(s.tasks.first { $0.id == "T5" })
    #expect(five.history?.lastProgressBy == "beta" && eventAfterProgress(five) == nil, "the record came after the answer")
    let nine = try #require(s.tasks.first { $0.id == "T9" })
    #expect(nine.history?.cancelledFrom == "new" && taskStep(nine) == .registered && nine.assignee == nil)
    // a verdict as the last event has its landing and is counted; no task is past a review without a landing
    guard case .success(let one) = parseTaskFamily(try fakeMyTeam(t, ["team_name": "example-team", "task": "T1"])) else { Issue.record("T1's family did not parse"); return }
    #expect(one.landings.map(\.id) == ["T1#1"] && one.verdicts.map(\.verdict) == ["hold"])
    // the count of the last verdict's own kind, which the app reads only for `changes`: from the board's JSON (R19 L2)
    let raw = try #require(try JSONSerialization.jsonObject(with: Data(answer.stdout.utf8)) as? [String: Any])
    let rawTasks = try #require(raw["tasks"] as? [[String: Any]])
    #expect(rawTasks.count == s.tasks.count)
    var judged = 0
    for task in rawTasks {
        let h = try #require(task["history"] as? [String: Any]), e = try #require(h["last_event"] as? [String: Any])
        guard e["action"] as? String == "verdict" else { continue }
        let kind = try #require(e["verdict"] as? String), counts = try #require(h["verdicts"] as? [String: Int])
        #expect((counts[kind] ?? 0) > 0, "\(task["id"] ?? "?") ended on a \(kind) verdict its history does not count")
        judged += 1
    }
    #expect(judged >= 3, "the fixture has tasks whose last event is a verdict of each kind")
    #expect(Set(rawTasks.compactMap { (($0["history"] as? [String: Any])?["last_event"] as? [String: Any])?["verdict"] as? String }) == ["approve", "changes", "hold"])
    for task in s.tasks {
        let h = try #require(task.history)
        if h.lastEvent?.action == "verdict" { #expect(h.landings > 0, "\(task.id)") }
        if ["review", "held", "done"].contains(task.state) || ["review", "held"].contains(h.cancelledFrom ?? "") { #expect(h.landings > 0, "\(task.id)") }
        if h.lastEvent?.action == "add" { #expect(h.lastEvent?.at == task.createdAt && h.stateSince == task.createdAt, "\(task.id)") }
        if h.lastEvent?.action == "assign" { #expect(h.lastEvent?.at == task.assignedAt, "\(task.id)") }
    }
}
