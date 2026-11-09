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
