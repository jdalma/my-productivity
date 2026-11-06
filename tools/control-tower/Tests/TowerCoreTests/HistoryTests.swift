import Foundation
import Testing
@testable import TowerCore

// Session history from transcript files in a temp dir laid out like ~/.claude and ~/.codex.

private struct Homes {
    let dir: String
    var roots: HistoryRoots { HistoryRoots(claudeProjects: "\(dir)/claude/projects", codexHome: "\(dir)/codex") }

    init() throws { dir = try myTeamBase() }

    @discardableResult
    func claude(_ id: String, project: String = "-p", _ records: [String]) throws -> String {
        let path = "\(dir)/claude/projects/\(project)/\(id).jsonl"
        try write(path, records.joined(separator: "\n") + "\n")
        return path
    }

    @discardableResult
    func codex(_ name: String, _ records: [String]) throws -> String {
        let path = "\(dir)/codex/sessions/2026/11/01/rollout-\(name).jsonl"
        try write(path, records.joined(separator: "\n") + "\n")
        return path
    }

    func history(board: Board = Board(at: "", teams: [], loose: [])) -> [HistorySession] {
        collectHistory(board: board, roots: roots, cache: HistoryCache())
    }
}

private func user(_ text: String, entrypoint: String = "cli", at: String = "2026-11-01T01:00:00.000Z",
                  meta: Bool = false) -> String {
    let content = String(decoding: try! JSONSerialization.data(withJSONObject: [text]), as: UTF8.self).dropFirst().dropLast()
    return #"{"type":"user","entrypoint":"\#(entrypoint)","isMeta":\#(meta),"cwd":"/w/app","gitBranch":"main","timestamp":"\#(at)","message":{"role":"user","content":\#(content)}}"#
}

private func meta(_ id: String, originator: String, at: String = "2026-11-01T02:00:00.000Z") -> String {
    #"{"timestamp":"\#(at)","type":"session_meta","payload":{"id":"\#(id)","timestamp":"\#(at)","cwd":"/w/cx","originator":"\#(originator)","git":{"branch":"dev"}}}"#
}

private func userMessage(_ text: String, at: String) -> String {
    #"{"timestamp":"\#(at)","type":"event_msg","payload":{"type":"user_message","message":"\#(text)"}}"#
}

@Test func onlyInteractiveSessionsAreListed() throws {
    let h = try Homes()
    defer { try? FileManager.default.removeItem(atPath: h.dir) }
    try h.claude("cli", [user("hi")])
    try h.claude("sdk", [user("hi", entrypoint: "sdk-cli")])
    for o in ["codex-tui", "codex_cli_rs", "Codex Desktop", "codex_exec", "Claude Code", "codex_sdk_ts"] {
        try h.codex(o, [meta("id-\(o)", originator: o), userMessage("go", at: "2026-11-01T02:00:01.000Z")])
    }
    let got = h.history()
    #expect(got.filter { $0.agent == .claude }.map(\.id) == ["cli"])
    #expect(Set(got.filter { $0.agent == .codex }.map(\.id)) == ["id-codex-tui", "id-codex_cli_rs", "id-Codex Desktop"])
}

@Test func subagentTranscriptsAreSkipped() throws {
    let h = try Homes()
    defer { try? FileManager.default.removeItem(atPath: h.dir) }
    try h.claude("main", [user("hi")])
    try write("\(h.dir)/claude/projects/-p/main/subagents/agent-1.jsonl", user("sub") + "\n")
    #expect(h.history().map(\.id) == ["main"])
}

@Test func claudeTitleIsCustomThenAiThenTheFirstRealPrompt() throws {
    let h = try Homes()
    defer { try? FileManager.default.removeItem(atPath: h.dir) }
    let prompts = [
        user("<local-command-stdout>x</local-command-stdout>"),
        user("caveat text", meta: true),
        user("fix the login bug"),
    ]
    try h.claude("a", prompts + [#"{"type":"ai-title","aiTitle":"Old"}"#, #"{"type":"ai-title","aiTitle":"Login fix"}"#,
                                 #"{"type":"custom-title","customTitle":"Mine"}"#])
    try h.claude("b", prompts + [#"{"type":"ai-title","aiTitle":"Login fix"}"#])
    try h.claude("c", prompts)
    try h.claude("d", [user("<command-message>x</command-message>\n<command-name>/deploy</command-name>\n<command-args>prod now</command-args>")])
    let title = Dictionary(uniqueKeysWithValues: h.history().map { ($0.id, $0.title) })
    #expect(title == ["a": "Mine", "b": "Login fix", "c": "fix the login bug", "d": "/deploy prod now"])
}

@Test func claudeFieldsComeFromTheTranscript() throws {
    let h = try Homes()
    defer { try? FileManager.default.removeItem(atPath: h.dir) }
    let path = try h.claude("s1", project: "-w-app", [
        user("first", at: "2026-11-01T01:00:00.000Z"),
        "{broken json",
        #"{"type":"last-prompt","lastPrompt":"second\n  prompt"}"#,
        #"{"type":"assistant","cwd":"/w/moved","gitBranch":"feat/x","timestamp":"2026-11-01T03:00:00.000Z"}"#,
    ])
    let s = try #require(h.history().first)
    #expect(s == HistorySession(
        id: "s1", agent: .claude, title: "first", workspace: "/w/app", branch: "feat/x",
        createdAt: "2026-11-01T01:00:00.000Z", updatedAt: "2026-11-01T03:00:00.000Z", lastPrompt: "second prompt",
        transcriptPath: path, live: false, resumeCommand: ["claude", "--resume", "s1"]))
}

@Test func claudeWorkspaceIsTheCwdTheTranscriptIsFiledUnderNotALaterCd() throws {
    let h = try Homes()
    defer { try? FileManager.default.removeItem(atPath: h.dir) }
    let cd = { (cwd: String) in #"{"type":"assistant","cwd":"\#(cwd)","timestamp":"2026-11-01T02:00:00.000Z"}"# }
    // filed under -p: /p, even though the first and last cwds are elsewhere
    try h.claude("filed", project: "-p", [cd("/p/sub"), user("x"), cd("/p"), cd("/p/sub/deeper")])
    // no cwd encodes to the project dir: the first cwd
    try h.claude("odd", project: "-elsewhere", [user("x"), cd("/w/app/sub")])
    let ws = Dictionary(uniqueKeysWithValues: h.history().map { ($0.id, $0.workspace) })
    #expect(ws == ["filed": "/p", "odd": "/w/app"])
}

@Test func codexTitleIsTheIndexThreadNameThenTheFirstUserMessage() throws {
    let h = try Homes()
    defer { try? FileManager.default.removeItem(atPath: h.dir) }
    try h.codex("a", [meta("A", originator: "codex-tui"), userMessage("one", at: "2026-11-01T02:00:01.000Z"),
                      #"{"timestamp":"2026-11-01T02:00:02.000Z","type":"turn_context","payload":{"cwd":"/w/cx2"}}"#,
                      userMessage("two", at: "2026-11-01T02:00:03.000Z")])
    try h.codex("b", [meta("B", originator: "codex-tui"), userMessage("only", at: "2026-11-01T02:00:01.000Z")])
    // a rollout without user_message events: user message items, harness injections skipped
    try h.codex("c", [meta("C", originator: "codex-tui"),
                      ##"{"timestamp":"2026-11-01T02:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions"}]}}"##,
                      #"{"timestamp":"2026-11-01T02:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"real ask"}]}}"#])
    try write("\(h.dir)/codex/session_index.jsonl", """
        {"id":"A","thread_name":"Old name"}
        {"id":"A","thread_name":"Named thread"}
        """)
    let byId = Dictionary(uniqueKeysWithValues: h.history().map { ($0.id, $0) })
    #expect(byId["A"]?.title == "Named thread")
    #expect(byId["A"]?.lastPrompt == "two")
    #expect(byId["A"]?.workspace == "/w/cx2")
    #expect(byId["A"]?.branch == "dev")
    #expect(byId["A"]?.resumeCommand == ["codex", "resume", "A"])
    #expect(byId["B"]?.title == "only")
    #expect(byId["C"]?.title == "real ask")
}

@Test func aMyTeamBootstrapPromptBecomesTeamAndWorker() throws {
    let h = try Homes()
    defer { try? FileManager.default.removeItem(atPath: h.dir) }
    let live = "Team is live. Follow /u/.my-team/sessions/shop/workers/be/AGENTS.md for the peer protocol; wait for user input"
    let joined = "You just joined team 'shop'. First action: read /u/.my-team/sessions/shop/workers/fe/AGENTS.md"
    let noPath = "You just joined team 'shop'. First action: say hi"
    for (id, text) in [("live", live), ("joined", joined), ("nopath", noPath), ("named", live)] {
        try h.codex(id, [meta(id, originator: "codex-tui"), userMessage(text, at: "2026-11-01T02:00:01.000Z")])
    }
    try write("\(h.dir)/codex/session_index.jsonl", #"{"id":"named","thread_name":"Named"}"#)
    try h.claude("ai", [user(live), #"{"type":"ai-title","aiTitle":"Ai title"}"#])
    try h.claude("plain", [user(live)])
    let title = Dictionary(uniqueKeysWithValues: h.history().map { ($0.id, $0.title) })
    #expect(title == ["live": "shop · be", "joined": "shop · fe", "nopath": noPath, "named": "Named",
                      "ai": "Ai title", "plain": "shop · be"])
    // the team and worker stay known under any title, for the board's team groups; tower-cli's JSON leaves them out
    let member = Dictionary(uniqueKeysWithValues: h.history().map { ($0.id, $0.member) })
    #expect(member["ai"] == TeamWorker(team: "shop", worker: "be"))
    #expect(member["named"] == TeamWorker(team: "shop", worker: "be"))
    #expect(member["joined"] == TeamWorker(team: "shop", worker: "fe"))
    #expect(member["nopath"] == .some(nil))
    let json = String(decoding: try JSONEncoder().encode(h.history().first { $0.id == "ai" }), as: UTF8.self)
    #expect(!json.contains("shop"))
}

@Test func newestFirstAcrossAgents() throws {
    let h = try Homes()
    defer { try? FileManager.default.removeItem(atPath: h.dir) }
    try h.claude("old", [user("x", at: "2026-10-01T00:00:00.000Z")])
    try h.claude("new", [user("x", at: "2026-11-01T05:00:00.000Z")])
    try h.codex("mid", [meta("mid", originator: "codex-tui", at: "2026-10-15T00:00:00.000Z")])
    #expect(h.history().map(\.id) == ["new", "mid", "old"])
}

@Test func aSessionIsLiveWhenABoardSessionReadsItsTranscript() throws {
    let h = try Homes()
    defer { try? FileManager.default.removeItem(atPath: h.dir) }
    let running = try h.claude("run", [user("x")])
    try h.claude("ended", [user("x")])
    var s = session()
    s.transcript = running
    let live = Dictionary(uniqueKeysWithValues: h.history(board: Board(at: "", teams: [], loose: [s])).map { ($0.id, $0.live) })
    #expect(live == ["run": true, "ended": false])
}

@Test func aBigTranscriptIsReadByItsHeadAndTail() throws {
    let h = try Homes()
    defer { try? FileManager.default.removeItem(atPath: h.dir) }
    let filler = (0..<4000).map { #"{"type":"assistant","n":\#($0),"pad":"\#(String(repeating: "x", count: 200))"}"# }
    try h.claude("big", [user("opening ask", at: "2026-11-01T01:00:00.000Z")] + filler
        + [#"{"type":"ai-title","aiTitle":"Late title"}"#, #"{"type":"assistant","timestamp":"2026-11-01T09:00:00.000Z"}"#])
    let s = try #require(h.history().first)
    #expect(s.title == "Late title")
    #expect(s.createdAt == "2026-11-01T01:00:00.000Z")
    #expect(s.updatedAt == "2026-11-01T09:00:00.000Z")
}

@Test func theCacheParsesOnlyNewOrChangedFiles() throws {
    let h = try Homes()
    defer { try? FileManager.default.removeItem(atPath: h.dir) }
    let a = try h.claude("a", [user("x")])
    let b = try h.claude("b", [user("x")])
    let cache = HistoryCache()
    var parsed: [String] = []
    let run = { () -> [String] in
        cache.facts(transcriptFiles(h.roots)) { parsed.append($0.path); return parseTranscript($0) }.map(\.id).sorted()
    }
    #expect(run() == ["a", "b"])
    #expect(Set(parsed) == [a, b])
    parsed = []
    #expect(run() == ["a", "b"])
    #expect(parsed.isEmpty)
    try write(b, user("x") + "\n" + user("y") + "\n")
    try FileManager.default.removeItem(atPath: a)
    #expect(run() == ["b"])
    #expect(parsed == [b])
}

// MARK: - worker display state

private func worker(alive: Bool = true, state: String? = nil, myTurn: Bool = false, status: Status = .wait) -> Worker {
    var s = session(status: status, myTurn: myTurn)
    s.since = "S"
    return Worker(session: s, workerName: "w", role: nil, description: "", paneId: "%1", alive: alive, spool: 0, inbox: 0,
                  sentPending: 0, oldestPendingAt: nil,
                  stateFile: state.map { StateFile(state: $0, reason: nil, updatedAt: "U") })
}

@Test func workerDisplayStateFollowsItsPriority() {
    #expect(displayState(worker(alive: false, state: "done", myTurn: true)) == .stopped)
    #expect(displayState(worker(state: "done", myTurn: true)) == .done(since: "U"))
    #expect(displayState(worker(state: "done", status: .busy)) == .done(since: "U"))
    #expect(displayState(worker(state: "working", myTurn: true)) == .waitingForUser(since: "S"))
    #expect(displayState(worker(myTurn: false, status: .busy)) == .working)
    #expect(displayState(worker(myTurn: false, status: .wait)) == .idle(since: "S"))
    #expect(displayState(worker(myTurn: false, status: .unknown)) == .idle(since: "S"))
}

@Test func staleDoneGivesWayToANewerBusyTurn() {
    let old = "2026-11-02T04:00:00Z", new = "2026-11-02T05:00:00.000Z"
    func w(updatedAt: String?, since: String?, alive: Bool = true, myTurn: Bool = false, status: Status = .busy) -> Worker {
        var x = worker(alive: alive, state: "done", myTurn: myTurn, status: status)
        x.since = since
        x.stateFile?.updatedAt = updatedAt
        return x
    }
    #expect(displayState(w(updatedAt: old, since: new)) == .working)
    #expect(displayState(w(updatedAt: new, since: old)) == .done(since: new))
    #expect(displayState(w(updatedAt: old, since: nil)) == .done(since: old))
    #expect(displayState(w(updatedAt: "garbage", since: new)) == .done(since: "garbage"))
    #expect(displayState(w(updatedAt: old, since: new, myTurn: true)) == .done(since: old))
    #expect(displayState(w(updatedAt: old, since: new, alive: false)) == .stopped)
    let team = Team(name: "t", sessionName: "s", startedAt: nil, attached: false,
                    workers: [w(updatedAt: old, since: new), w(updatedAt: new, since: old)])
    #expect(stateCounts(team).byKind == [.working: 1, .done: 1])
}

@Test func teamCountsIncludeStoppedWorkers() {
    let team = Team(name: "t", sessionName: "s", startedAt: nil, attached: false, workers: [
        worker(alive: false), worker(state: "done"), worker(myTurn: true), worker(myTurn: true), worker(status: .busy),
    ])
    let c = stateCounts(team)
    #expect(c.total == 5)
    #expect(c.byKind == [.stopped: 1, .done: 1, .waitingForUser: 2, .working: 1])
}

@Test func statusJsonUpdatedAtBecomesTheDoneTime() throws {
    let base = try myTeamBase()
    defer { try? FileManager.default.removeItem(atPath: base) }
    let root = try writeTeam(base, "t")
    try write("\(root)/workers/w/status.json", #"{"state":"done","updated_at":"2026-11-02T04:00:00Z"}"#)
    let w = toTeam(try loadTeams(base: base, panes: [])[0], clients: []).workers[0]
    #expect(w.stateFile == StateFile(state: "done", reason: nil, updatedAt: "2026-11-02T04:00:00Z"))
}

// MARK: - resume

private func ended(_ agent: AgentKind, live: Bool = false, workspace: String = "/w/my app") -> HistorySession {
    HistorySession(id: "S", agent: agent, title: "", workspace: workspace, branch: nil, createdAt: nil, updatedAt: "",
                   lastPrompt: nil, transcriptPath: "/t", live: live,
                   resumeCommand: agent == .claude ? ["claude", "--resume", "S"] : ["codex", "resume", "S"])
}

/// Ghostty 1.3 takes `open -na Ghostty.app --args -e <argv>` as files to open, one window each, and drops the rest
/// (user report, 2026-11-06), so a resume asks Ghostty for a window over AppleScript: the workspace, the command
/// in `direct:` form (no shell), our PATH, and the window kept open when the command ends.
@Test func planResumeOpensANewGhosttyWindowInTheWorkspace() {
    let bins: [AgentKind: String] = [.claude: "/bin/claude", .codex: "/bin/codex"]
    let claude = planResume(ended(.claude), bins: bins, path: "/opt/homebrew/bin:/usr/bin") ?? []
    #expect(claude.first == "osascript")
    #expect(Array(claude.suffix(3)) == ["/w/my app", "direct:/bin/claude --resume S", "PATH=/opt/homebrew/bin:/usr/bin"])
    let script = claude.dropLast(3).joined(separator: "\n")
    #expect(script.contains("tell application \"Ghostty\""))
    #expect(script.contains("new window with configuration {initial working directory:(item 1 of argv), "
        + "command:(item 2 of argv), environment variables:{item 3 of argv}, wait after command:true}"))
    let codex = planResume(ended(.codex), ghosttyApp: "G", bins: bins, path: "/p") ?? []
    #expect(codex.dropLast(3).joined().contains("tell application \"G\""))
    #expect(codex[codex.count - 2] == "direct:/bin/codex resume S")
    // `direct:` splits on spaces: a program path with one cannot be planned
    #expect(planResume(ended(.claude), bins: [.claude: "/my bin/claude"]) == nil)
}

@Test func theResumePathReachesHomebrewWhereNodeLives() {
    #expect(resumePath.split(separator: ":").contains("/opt/homebrew/bin"))
}

@Test func aLiveOrPlacelessSessionIsNotResumed() {
    #expect(planResume(ended(.claude, live: true)) == nil)
    #expect(planResume(ended(.claude, workspace: "")) == nil)
}

@Test func aPermissionPromptOutranksDone() {
    func w(alive: Bool = true, state: String? = "done", myTurn: Bool = false, perm: Bool) -> Worker {
        var x = worker(alive: alive, state: state, myTurn: myTurn)
        x.permissionPrompt = perm
        return x
    }
    #expect(displayState(w(myTurn: true, perm: true)) == .permission(since: "S"))
    #expect(displayState(w(myTurn: true, perm: false)) == .done(since: "U"))
    #expect(displayState(w(alive: false, perm: true)) == .stopped)
    #expect(displayState(w(state: nil, myTurn: true, perm: true)) == .permission(since: "S"))
    #expect(displayState(w(perm: true)).kind == .waitingForUser)

    let team = Team(name: "t", sessionName: "s", startedAt: nil, attached: false, workers: [w(myTurn: true, perm: true)])
    #expect(stateCounts(team).byKind == [.waitingForUser: 1])
}

@Test func aLooseSessionUsesTheSameRules() {
    var s = session(status: .busy, myTurn: false)
    s.since = "S"
    #expect(displayState(s) == .working)
    s.status = .wait; s.myTurn = true
    #expect(displayState(s) == .waitingForUser(since: "S"))
    s.permissionPrompt = true
    #expect(displayState(s) == .permission(since: "S"))
    s = session(status: .unknown, myTurn: false)
    #expect(displayState(s) == .idle(since: s.since))
}
