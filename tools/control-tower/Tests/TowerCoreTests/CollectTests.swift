import Foundation
import Testing
@testable import TowerCore

struct CollectInput: Decodable {
    var teams: [TeamSeed]
    var panes: [Pane]
    var clients: [TmuxClient]
    var claude: [ClaudeRecord]
    var codex: [CodexRecord]
    var rows: [PsRow]
}

private let at = "2026-10-31T06:00:00.000Z"

private func input() throws -> CollectInput {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(CollectInput.self, from: fixtureData("collect-input.json"))
}

private func board(_ i: CollectInput) -> Board {
    join(teams: i.teams, panes: i.panes, claude: i.claude, codex: i.codex, rows: i.rows, at: at)
}

private func board() throws -> Board { board(try input()) }

private func worker(_ b: Board, _ name: String) -> Worker {
    b.teams[0].workers.first { $0.workerName == name }!
}

private func deps(
    capturePane: @escaping (String) -> String = { _ in "" },
    lastMessages: @escaping (String, AgentKind) -> LastMessages = { _, _ in LastMessages() },
    envOf: @escaping (Int, [String]) -> [String: String] = { _, _ in [:] }
) -> CollectDeps {
    var d = CollectDeps.stub
    d.capturePane = capturePane
    d.lastMessages = lastMessages
    d.envOf = envOf
    return d
}

@Test func everyWorkerCarriesTheFullWorkerShape() throws {
    let fixture = try JSONSerialization.jsonObject(with: fixtureData("board.json")) as! [String: Any]
    let wantKeys = Set((((fixture["teams"] as! [[String: Any]])[0])["workers"] as! [[String: Any]])[0].keys)
    let b = try board()
    for w in b.teams[0].workers {
        let keys = Set((try JSONSerialization.jsonObject(with: JSONEncoder().encode(w)) as! [String: Any]).keys)
        #expect(keys == wantKeys, "\(w.workerName)")
    }
    #expect(b.at == at)
}

@Test func workerMatchedByClaudePane() throws {
    let w = worker(try board(), "alpha")
    #expect(w.pid == 101)
    #expect(w.agent == .claude)
    #expect(w.status == .wait)
    #expect(w.myTurn == true)
    #expect(w.title == "alpha title")
    #expect(w.transcript == "/Users/me/.claude/projects/a/s1.jsonl")
    #expect(w.tmux == TmuxRef(session: "my-team-demo-team-abc", window: "@1", pane: "%1"))
    #expect(w.handle == "pane:my-team-demo-team-abc:%1")
}

@Test func workerMatchedByCodexViaAncestorShellPid() throws {
    let b = try board()
    let w = worker(b, "beta")
    #expect(w.pid == 202)
    #expect(w.agent == .codex)
    #expect(w.status == .busy)
    #expect(w.termProgram == nil)
    #expect(w.tmux == TmuxRef(session: "my-team-demo-team-abc", window: "@1", pane: "%2"))
    #expect(!b.loose.contains { $0.pid == 202 })
}

@Test func deadWorkerHasPid0UnknownAndNoTmux() throws {
    let w = worker(try board(), "gamma")
    #expect(w.pid == 0)
    #expect(w.status == .unknown)
    #expect(w.tmux == nil)
    #expect(w.myTurn == false)
    #expect(w.cwd == "/Users/me/gamma")
}

@Test func aliveWorkerWithoutARecognizedProcessIsUnknownWithTmux() throws {
    let w = worker(try board(), "delta")
    #expect(w.pid == 0)
    #expect(w.status == .unknown)
    #expect(w.tmux == TmuxRef(session: "my-team-demo-team-abc", window: "@1", pane: "%4"))
    #expect(w.title == "gemini")
    #expect(w.transcript == nil)
}

@Test func myTurnFalseWhileSpoolIsPositive() throws {
    let w = worker(try board(), "epsilon")
    #expect(w.status == .wait)
    #expect(w.myTurn == false)
    #expect(w.title == "eps-name")
}

@Test func looseSessionsGetPidOrPaneHandles() throws {
    let loose = try board().loose
    #expect(loose.map(\.handle).sorted() == ["pane:scratch:%9", "pid:701"])
    let out = loose.first { $0.pid == 701 }!
    #expect(out.tmux == nil)
    #expect(out.termProgram == nil)
    #expect(out.title == "outside-name")
    #expect(out.myTurn == false)
    let scratch = loose.first { $0.pid == 901 }!
    #expect(scratch.title == "scratch title")
    #expect(scratch.myTurn == true)
}

@Test func enrichFillsLastMessagesPermissionAndTermProgram() throws {
    var calls: [String] = []
    let b = enrich(try board(), deps: deps(
        capturePane: { $0 == "%5" ? "Do you want to proceed?\n❯ 1. Yes\n  2. No" : "" },
        lastMessages: { path, agent in LastMessages(lastUser: "u:\(agent.rawValue)", lastAssistant: "a:\(path)") },
        envOf: { pid, keys in
            calls.append("\(pid) \(keys)")
            return ["TERM_PROGRAM": "ghostty"]
        }
    ))
    let beta = worker(b, "beta")
    #expect(beta.lastUser == "u:codex")
    #expect(beta.lastAssistant == "a:/Users/me/.codex/sessions/rollout-b.jsonl")
    #expect(worker(b, "delta").lastUser == "")
    let eps = worker(b, "epsilon")
    #expect(eps.permissionPrompt == true)
    #expect(eps.myTurn == true)
    #expect(worker(b, "alpha").permissionPrompt == false)
    #expect(calls == ["701 [\"TERM_PROGRAM\"]"])
    #expect(b.loose.first { $0.pid == 701 }?.termProgram == "ghostty")
}

@Test func aSessionsFileWhosePidWasReusedIsIgnored() throws {
    var i = try input()
    let idx = i.claude.firstIndex { $0.pid == 101 }!
    i.claude[idx].procStart = "2026-10-31T01:00:00.000Z"
    i.rows.append(PsRow(pid: 101, ppid: 1, lstart: "2026-10-31T04:00:00.000Z")) // a different, later process
    let w = worker(board(i), "alpha")
    #expect(w.pid == 0)
    #expect(w.status == .unknown)
}

@Test func aDeadWorkerIsNeverMyTurnEvenIfAProcessStillSitsInItsPane() throws {
    var i = try input()
    let gamma = i.teams[0].workers.first { $0.workerName == "gamma" }!
    var ghost = i.claude.first { $0.pid == 101 }!
    ghost.pid = 303
    ghost.status = .wait
    ghost.tmux = TmuxRef(session: "my-team-demo-team-abc", window: "@1", pane: gamma.paneId)
    i.claude.append(ghost)
    let b = board(i)
    #expect(worker(b, "gamma").pid == 303)
    #expect(worker(b, "gamma").myTurn == false)
    #expect(worker(enrich(b, deps: deps()), "gamma").myTurn == false)
}

@Test func failingMyTeamDegradesToNoTeams() throws {
    let i = try input()
    var d = deps()
    d.psSnapshot = { i.rows }
    d.loadTeams = { _ in throw MyTeamError(description: "boom") }
    d.loadCodexSessions = { _ in i.codex }
    d.listPanes = { i.panes }
    d.loadClaudeSessions = { i.claude }
    let b = snapshot(deps: d).board
    #expect(b.teams.isEmpty)
    #expect(b.loose.map(\.pid).sorted() == [101, 202, 501, 701, 901])
}

@Test func aLooseSessionIsInATerminalWhenItsTmuxIsAttachedOrItHasATty() {
    func loose(_ pid: Int, tmux: String?) -> Session {
        Session(handle: "h\(pid)", agent: .claude, pid: pid, cwd: "/w", startedAt: nil, status: .wait, myTurn: false,
                since: nil, permissionPrompt: false, title: "", tmux: tmux.map { TmuxRef(session: $0, window: "0", pane: "%\(pid)") },
                transcript: nil, lastUser: "", lastAssistant: "", termProgram: nil)
    }
    let b = Board(at: at, teams: [], loose: [loose(1, tmux: "on"), loose(2, tmux: "off"), loose(3, tmux: nil), loose(4, tmux: nil)])
    let rows = [PsRow(pid: 1, ppid: 0, hasTTY: false), PsRow(pid: 2, ppid: 0, hasTTY: true),
                PsRow(pid: 3, ppid: 0, hasTTY: true), PsRow(pid: 4, ppid: 0)]
    let marked = markTerminals(b, rows: rows, clients: [TmuxClient(session: "on", pid: 9, tty: "/dev/ttys001")])
    // tmux decides for a session inside it, the process's own tty for one outside
    #expect(marked.loose.map(\.inTerminal) == [true, false, true, false])
}

/// T111: Claude Code does not always write `tmux` to sessions/<pid>.json. Without it the session's pane is the one
/// above it among its ancestors, as for Codex; with it, the value stands.
@Test func aClaudeSessionWithoutItsTmuxValueJoinsItsWorkerByItsAncestors() throws {
    var i = try input()
    var bare = i.claude.first { $0.pid == 101 }!
    bare.pid = 401
    bare.tmux = nil
    i.claude.append(bare)
    i.rows += [PsRow(pid: 401, ppid: 400)]  // claude under delta's pane shell
    let b = board(i)
    // (a) by its ancestors: the worker's, and not loose
    #expect(worker(b, "delta").pid == 401)
    #expect(worker(b, "delta").agent == .claude)
    #expect(worker(b, "delta").tmux == TmuxRef(session: "my-team-demo-team-abc", window: "@1", pane: "%4"))
    #expect(!b.loose.contains { $0.pid == 401 })
    // (b) a session with the value is joined as before
    #expect(worker(b, "alpha").pid == 101)
}

@Test func theTmuxValueWinsOverTheAncestors() throws {
    var i = try input()
    var s = i.claude.first { $0.pid == 101 }!
    s.pid = 402
    s.tmux = TmuxRef(session: "my-team-demo-team-abc", window: "@1", pane: "%4")
    i.claude.append(s)
    i.rows += [PsRow(pid: 402, ppid: 900)]  // under the scratch pane's shell
    let b = board(i)
    #expect(worker(b, "delta").pid == 402)
    #expect(!b.loose.contains { $0.pid == 402 })
}

@Test func aClaudeSessionWithNeitherValueNorPaneAboveStaysLoose() throws {
    var i = try input()
    var s = i.claude.first { $0.pid == 701 }!
    s.pid = 702
    i.claude.append(s)
    i.rows += [PsRow(pid: 702, ppid: 650), PsRow(pid: 650, ppid: 1)]  // a terminal app's shell, no pane
    let b = board(i)
    // (c) loose, by pid
    let loose = try #require(b.loose.first { $0.pid == 702 })
    #expect(loose.tmux == nil)
    #expect(loose.handle == "pid:702")
    #expect(b.teams[0].workers.allSatisfy { $0.pid != 702 })
}

@Test func aSecondClaudeAboveAClaimedWorkerPaneFallsThroughToLoose() throws {
    var i = try input()
    var first = i.claude.first { $0.pid == 101 }!
    first.tmux = nil
    var a = first, c = first
    a.pid = 411
    c.pid = 412
    i.claude += [a, c]
    i.rows += [PsRow(pid: 411, ppid: 400), PsRow(pid: 412, ppid: 400)]
    let b = board(i)
    // (d) the first claims delta's pane; the second is loose, in that pane
    #expect(worker(b, "delta").pid == 411)
    let second = try #require(b.loose.first { $0.pid == 412 })
    #expect(second.handle == "pane:my-team-demo-team-abc:%4")
}

/// R37 S1: a Claude started inside a worker's Claude, without its value, is that Claude's child: it does not reach the
/// worker pane through its ancestors, whatever the order of the session files, and stays loose as before.
@Test func aClaudeStartedInsideAWorkersClaudeDoesNotTakeItsPane() throws {
    var i = try input()
    var parent = i.claude.first { $0.pid == 101 }!
    parent.pid = 420
    parent.tmux = TmuxRef(session: "my-team-demo-team-abc", window: "@1", pane: "%4")
    var child = parent
    child.pid = 3999
    child.tmux = nil
    i.claude = [child] + i.claude + [parent]
    i.rows += [PsRow(pid: 3999, ppid: 3998), PsRow(pid: 3998, ppid: 420), PsRow(pid: 420, ppid: 400)]
    let b = board(i)
    #expect(worker(b, "delta").pid == 420)
    let loose = try #require(b.loose.first { $0.pid == 3999 })
    #expect(loose.handle == "pid:3999")
}

/// R37 L1: a value whose pane is not among the listed panes stays the value; the ancestors are not asked.
@Test func aTmuxValueWithAnUnlistedPaneIsNotReplacedByTheAncestors() throws {
    var i = try input()
    var s = i.claude.first { $0.pid == 101 }!
    s.pid = 403
    s.tmux = TmuxRef(session: "elsewhere", window: "@7", pane: "%77")
    i.claude.append(s)
    i.rows += [PsRow(pid: 403, ppid: 400)]  // under delta's pane shell
    let b = board(i)
    #expect(worker(b, "delta").pid == 0)
    #expect(b.loose.first { $0.pid == 403 }?.tmux == TmuxRef(session: "elsewhere", window: "@7", pane: "%77"))
    #expect(b.loose.first { $0.pid == 403 }?.title == "alpha-name", "its own name, not the title of the pane above it")
}

/// R37 L2: without a value, a Claude in a pane outside every team is loose in that pane.
@Test func aClaudeWithoutItsValueInAPaneOutsideTheTeamsIsLooseInThatPane() throws {
    var i = try input()
    var s = i.claude.first { $0.pid == 701 }!
    s.pid = 902
    i.claude.append(s)
    i.rows += [PsRow(pid: 902, ppid: 900)]  // under the scratch pane's shell
    let loose = try #require(board(i).loose.first { $0.pid == 902 })
    #expect(loose.handle == "pane:scratch:%9")
    #expect(loose.tmux == TmuxRef(session: "scratch", window: "@9", pane: "%9"))
}
