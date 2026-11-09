import Foundation
import Testing
@testable import TowerCore

// MARK: - ps

/// The process tree of Fixtures/ps-codex.txt.
private func psRows() -> [PsRow] {
    let bin = "/opt/homebrew/lib/node_modules/@openai/codex/vendor/bin"
    return [
        PsRow(pid: 1, ppid: 0, args: "/sbin/launchd"),
        PsRow(pid: 900, ppid: 1, args: "-zsh"),
        PsRow(pid: 1000, ppid: 900, args: "node /opt/homebrew/bin/codex --dangerously-bypass-approvals-and-sandbox"),
        PsRow(pid: 1001, ppid: 1000, args: "\(bin)/codex --dangerously-bypass-approvals-and-sandbox"),
        PsRow(pid: 1002, ppid: 1001, args: "\(bin)/codex-code-mode-host"),
        PsRow(pid: 2000, ppid: 1, args: "\(bin)/codex app-server --listen stdio"),
        PsRow(pid: 3000, ppid: 1, args: "codex exec --ephemeral -s read-only summarize"),
        PsRow(pid: 4000, ppid: 1, args: "node /tools/control-tower/bin/control-tower"),
        PsRow(pid: 4001, ppid: 4000, args: "codex -m some-model"),
        PsRow(pid: 5000, ppid: 900, args: "codex resume"),
    ]
}

/// A KERN_PROCARGS2 buffer as the kernel lays it out.
private func procArgsBuffer(exec: String, argv: [String], env: [String], apple: [String]) -> [UInt8] {
    var buf = withUnsafeBytes(of: Int32(argv.count).littleEndian, Array.init)
    buf += Array(exec.utf8) + [0, 0, 0, 0]
    for s in argv + env { buf += Array(s.utf8) + [0] }
    buf.append(0)
    for s in apple { buf += Array(s.utf8) + [0] }
    return buf
}

@Test func parseProcArgsSplitsArgvFromTheEnvironment() {
    let buf = procArgsBuffer(
        exec: "/bin/codex", argv: ["/bin/codex", "--x", "FOO=args-not-env"],
        env: ["TERM_PROGRAM=ghostty", "FOO=a b=c", "FOO=second", "EMPTY="],
        apple: ["executable_path=/bin/codex", "ptr_munge="]
    )
    #expect(parseProcArgs(buf) == ProcArgs(
        argv: ["/bin/codex", "--x", "FOO=args-not-env"],
        env: ["TERM_PROGRAM": "ghostty", "FOO": "a b=c", "EMPTY": ""]
    ))
    #expect(parseProcArgs([1, 0]) == nil)
}

@Test func psSnapshotSeesThisProcessWithItsParentArgsAndStart() throws {
    let rows = psSnapshot()
    let me = try #require(rows.first { $0.pid == Int(getpid()) })
    #expect(me.ppid == Int(getppid()))
    #expect(me.args == CommandLine.arguments.joined(separator: " "))
    let started = try #require(parseISO(me.lstart))
    #expect(started <= Date().timeIntervalSince1970 * 1000)
    #expect(started > Date().timeIntervalSince1970 * 1000 - 3_600_000)
    #expect(rows.contains { $0.pid == 1 })
}

// Apple platform binaries (/bin/sleep, /bin/sh) hide their environment, from `ps -E` too;
// codex and this test runner do not.
@Test func envOfReadsTheExecEnvironmentAndOnlyRequestedKeys() throws {
    let env = ProcessInfo.processInfo.environment
    let home = try #require(env["HOME"])
    #expect(envOf(pid: Int(getpid()), keys: ["HOME", "CT_SURELY_UNSET"]) == ["HOME": home])
}

/// codex candidates, loose order and pane claims follow row order, so rows keep ps's (tty, pid) order.
@Test func psSnapshotKeepsPsRowOrder() throws {
    let rows = psSnapshot().map(\.pid)
    let p = Process()
    let out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axo", "pid="]
    p.standardOutput = out
    try p.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    let ps = text.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    let common = Set(rows).intersection(ps)
    #expect(common.count > 10)
    let mine = rows.filter(common.contains), theirs = ps.filter(common.contains)
    let at = zip(mine, theirs).enumerated().first { $0.element.0 != $0.element.1 }?.offset
    #expect(at == nil, "first difference at \(at ?? -1): \(at.map { mine[$0] } ?? 0) vs ps \(at.map { theirs[$0] } ?? 0)")
}

@Test func unreadableOrVanishedPidsAreSkippedQuietly() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try p.run()
    p.waitUntilExit()
    let gone = Int(p.processIdentifier)
    #expect(envOf(pid: gone, keys: ["PATH"]).isEmpty)
    #expect(openFiles(gone) == nil)
    #expect(envOf(pid: 1, keys: ["PATH"]).isEmpty) // launchd: root's, EPERM
    #expect(openFiles(1) == nil)
}

@Test func ancestorsWalksNearestFirstAndStopsBeforeLaunchd() throws {
    let rows = psRows()
    #expect(ancestors(of: 1002, in: rows) == [1001, 1000, 900])
    #expect(ancestors(of: 1, in: rows) == [])
    #expect(ancestors(of: 99999, in: rows) == [])
    #expect(isDescendant(1002, of: 1000, in: rows))
    #expect(!isDescendant(1000, of: 1002, in: rows))
}

@Test func ancestorsStopsOnACycleAfter40Hops() {
    #expect(ancestors(of: 10, in: [PsRow(pid: 10, ppid: 11), PsRow(pid: 11, ppid: 10)]).count == 40)
}

// MARK: - tmux

@Test func paneFormatHasThe8FieldsAndNoPaneCurrentCommand() {
    #expect(paneFormat.split(separator: "\t").count == 8)
    #expect(!paneFormat.contains("pane_current_command"))
}

@Test func parsePanesParsesHostAndWorkerPanes() {
    let text = [
        "my-team-demo-mvtepzfv\t@5\t%40\t4101\t0\t\t✳ 워커 온보딩\t/Users/me/demo",
        "my-team-demo-mvtepzfv\t@5\t%42\t4102\t0\tapi-dev\t⠂ build the api\t/Users/me/demo/api",
        "scratch\t@9\t%77\t4200\t1\t\tzsh\t/tmp",
        "",
    ].joined(separator: "\n")
    #expect(parsePanes(text) == [
        Pane(session: "my-team-demo-mvtepzfv", window: "@5", pane: "%40", pid: 4101, dead: false, workerName: nil, title: "✳ 워커 온보딩", cwd: "/Users/me/demo"),
        Pane(session: "my-team-demo-mvtepzfv", window: "@5", pane: "%42", pid: 4102, dead: false, workerName: "api-dev", title: "⠂ build the api", cwd: "/Users/me/demo/api"),
        Pane(session: "scratch", window: "@9", pane: "%77", pid: 4200, dead: true, workerName: nil, title: "zsh", cwd: "/tmp"),
    ])
}

@Test func parsePanesKeepsATabInsideTheTitle() {
    let p = parsePanes("s\t@1\t%1\t1\t0\tw\ta\tb\t/x\n")[0]
    #expect(p.title == "a\tb")
    #expect(p.cwd == "/x")
}

@Test func parsePanesAndParseClientsOnEmptyOutput() {
    #expect(parsePanes("").isEmpty)
    #expect(parseClients("").isEmpty)
}

@Test func parseClientsParsesSessionPidTty() {
    #expect(parseClients("my-team-demo-mvtepzfv\t5123\t/dev/ttys004\nscratch\t5200\t/dev/ttys007\n") == [
        TmuxClient(session: "my-team-demo-mvtepzfv", pid: 5123, tty: "/dev/ttys004"),
        TmuxClient(session: "scratch", pid: 5200, tty: "/dev/ttys007"),
    ])
}

// MARK: - codex

@Test func pickCandidatesKeepsTheNativeTUIChildOnly() throws {
    let rows = psRows()
    #expect(pickCandidates(rows, selfPid: 4000).map(\.pid) == [1001, 5000])
    // without the self filter the helper under 4000 is a TUI too
    #expect(pickCandidates(rows, selfPid: 1).map(\.pid) == [1001, 4001, 5000])
}

@Test func openFilesGivesTheCwdAndTheOpenRolloutPath() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "ct-\(UUID().uuidString)/sessions/2026/10/29")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
    let rollout = dir.appending(path: "rollout-2026-10-29T21-15-26-aaaa.jsonl")
    FileManager.default.createFile(atPath: rollout.path, contents: Data())
    let fh = try FileHandle(forReadingFrom: rollout)
    defer { try? fh.close() }
    let mine = try #require(openFiles(Int(getpid())))
    #expect(mine.cwd == FileManager.default.currentDirectoryPath)
    let real = rollout.resolvingSymlinksInPath().path
    #expect(mine.paths.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == real })
}

@Test func classifyRolloutCompleteAfterStartedIsWait() throws {
    let r = classifyRollout(try fixture("codex-rollout-tail.jsonl"))
    #expect(r.status == .wait)
    #expect(r.since == "2026-10-29T12:17:05.500Z")
}

@Test func classifyRolloutStartedAfterCompleteIsBusy() {
    let r = classifyRollout([
        #"{"timestamp":"2026-10-29T12:00:00.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
        #"{"timestamp":"2026-10-29T12:05:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
    ].joined(separator: "\n"))
    #expect(r.status == .busy)
    #expect(r.since == "2026-10-29T12:05:00.000Z")
}

@Test func classifyRolloutNeitherMarkerIsUnknownAndACutOffLineGivesNoSince() {
    let none = classifyRollout(#"{"timestamp":"x","type":"response_item"}"# + "\n")
    #expect(none.status == .unknown && none.since == nil)
    // tail cut mid-line before the timestamp: since is nil, status still decided
    let cut = classifyRollout(#"load":{"type":"task_started"}}"#)
    #expect(cut.status == .busy && cut.since == nil)
}

@Test func classifyRolloutTreatsAnAbortedTurnAsFinished() {
    let r = classifyRollout([
        #"{"timestamp":"T1","type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"timestamp":"T2","type":"event_msg","payload":{"type":"turn_aborted"}}"#,
    ].joined(separator: "\n"))
    #expect(r.status == .wait && r.since == "T2")
}

// MARK: - my-team

private let clients = [TmuxClient(session: "my-team-demo-team-mvtepzfv", pid: 1, tty: "/dev/ttys001")]
private func rawWorker(_ name: String, _ pane: String, agent: String?, role: String? = nil, description: String? = nil,
                       alive: Bool = true, state: String? = nil, reason: String? = nil,
                       spool: Int = 0, unread: Int = 0, sentPending: Int = 0, oldest: String? = nil) -> RawWorker {
    RawWorker(name: name, paneId: pane, cwd: "/Users/me/\(name)", agentType: agent, role: role, description: description,
              alive: alive, state: state, reason: reason, spool: spool, unread: unread, sentPending: sentPending,
              oldestPendingAt: oldest)
}

private func rawTeams() -> [RawTeam] {
    [
        RawTeam(teamName: "demo-team", session: "my-team-demo-team-mvtepzfv:0", startedAt: "2026-10-31T01:00:00.000Z",
                teamAlive: true, workers: [
                    rawWorker("alpha", "%38", agent: "claude", role: "orchestrator", description: "Demo orchestrator",
                              state: "idle", reason: "waiting for replies", sentPending: 2, oldest: "2026-10-31T05:10:00.000Z"),
                    rawWorker("beta", "%39", agent: "codex", role: "worker", description: "Demo codex worker", spool: 1, unread: 1),
                    rawWorker("gamma", "%40", agent: "gemini", alive: false, state: "done"),
                ]),
        RawTeam(teamName: "other-team", session: "my-team-other-team-abc12345:0", startedAt: "2026-10-30T09:00:00.000Z",
                teamAlive: true, workers: [rawWorker("alpha", "%5", agent: "claude", role: "worker", description: "", state: "working")]),
    ]
}

@Test func toTeamStripsTheWindowSuffixAndDerivesAttachedFromClients() throws {
    let teams = rawTeams().map { toTeam($0, clients: clients) }
    #expect(teams[0].sessionName == "my-team-demo-team-mvtepzfv")
    #expect(teams[0].attached == true)
    #expect(teams[1].attached == false)
    #expect(teams[0].startedAt == "2026-10-31T01:00:00.000Z")
}

@Test func toTeamMapsWorkerFields() throws {
    let w = toTeam(rawTeams()[0], clients: clients).workers
    #expect(w[0] == WorkerSeed(
        handle: "pane:my-team-demo-team-mvtepzfv:%38", workerName: "alpha", role: "orchestrator",
        description: "Demo orchestrator", paneId: "%38", alive: true, agent: .claude, cwd: "/Users/me/alpha",
        spool: 0, inbox: 0, sentPending: 2, oldestPendingAt: "2026-10-31T05:10:00.000Z",
        stateFile: StateFile(state: "idle", reason: "waiting for replies", updatedAt: nil)
    ))
    // spool + unread, no state/reason
    #expect(w[1].agent == .codex)
    #expect(w[1].spool == 1)
    #expect(w[1].inbox == 1)
    #expect(w[1].stateFile == nil)
    // dead worker, unknown agent type, missing role/description
    #expect(w[2].alive == false)
    #expect(w[2].agent == .claude)
    #expect(w[2].role == nil)
    #expect(w[2].description == "")
    #expect(w[2].handle == "pane:my-team-demo-team-mvtepzfv:%40")
    #expect(w[2].stateFile == StateFile(state: "done", reason: nil, updatedAt: nil))
}

// MARK: - claude

private let sid = "065c71b5-0000-4000-8000-000000000001"
private let base = SessionJson(
    pid: 10005, sessionId: sid, cwd: "/Users/me/x", startedAt: 1793270113003, procStart: "Thu Oct 29 10:35:09 2026",
    status: "idle", statusUpdatedAt: 1793428333676, updatedAt: 1793428333000, name: "x-77", entrypoint: "cli",
    tmux: "my-team-demo-mvtepzfv:@5.%42"
)

@Test func transcriptDirNameReplacesEveryNonAlphanumericChar() {
    #expect(transcriptDirName("/Users/me/my_proj.v2") == "-Users-me-my-proj-v2")
    // UTF-16 units, as JS: an astral char is two dashes, a BMP char one
    #expect(transcriptDirName("/a/한😀") == "-a----")
}

@Test func fromSessionJsonMapsATmuxSession() {
    let want = "/p/-Users-me-x/\(sid).jsonl"
    let rec = fromSessionJson(base, isAlive: { _ in true }, transcriptExists: { $0 == want }, projectsDir: "/p")
    #expect(rec == ClaudeRecord(
        pid: 10005, sessionId: sid, cwd: "/Users/me/x",
        startedAt: "2026-10-29T10:35:13.003Z", procStart: "2026-10-29T10:35:09.000Z", status: .wait,
        since: "2026-10-31T06:32:13.676Z", name: "x-77", entrypoint: "cli",
        tmux: TmuxRef(session: "my-team-demo-mvtepzfv", window: "@5", pane: "%42"), transcript: want
    ))
}

@Test func fromSessionJsonWithoutTmuxBusyUpdatedAtFallbackNoTranscript() {
    var json = base
    json.tmux = nil
    json.statusUpdatedAt = nil
    json.status = "busy"
    let rec = fromSessionJson(json, isAlive: { _ in true }, transcriptExists: { _ in false }, projectsDir: "/nonexistent")
    #expect(rec?.tmux == nil)
    #expect(rec?.status == .busy)
    #expect(rec?.since == "2026-10-31T06:32:13.000Z")
    #expect(rec?.transcript == nil)
}

@Test func fromSessionJsonReturnsNilForADeadPid() {
    #expect(fromSessionJson(base, isAlive: { _ in false }) == nil)
}

@Test func loadClaudeSessionsKeepsLiveOnlySkipsBadJsonAndFindsMovedTranscripts() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ct-claude-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: root) }
    let dir = "\(root)/sessions", projectsDir = "\(root)/projects"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: "\(projectsDir)/moved-dir", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: "\(projectsDir)/moved-dir/\(sid).jsonl", contents: Data())
    let me = Int(ProcessInfo.processInfo.processIdentifier)
    func write(_ name: String, _ text: String) { FileManager.default.createFile(atPath: "\(dir)/\(name)", contents: Data(text.utf8)) }
    let json = { (pid: Int) in #"{"pid":\#(pid),"sessionId":"\#(sid)","cwd":"/Users/me/x","startedAt":1793270113003,"status":"idle"}"# }
    write("\(me).json", json(me))
    write("999999.json", json(999999))
    write("1.json", "{not json")
    write("\(me).abc.key", "x")

    let recs = loadClaudeSessions(dir: dir, projectsDir: projectsDir)
    #expect(recs.map(\.pid) == [me])
    #expect(recs.first?.transcript == "\(projectsDir)/moved-dir/\(sid).jsonl")
}

@Test func loadClaudeSessionsOnAMissingDirReturnsNothing() {
    #expect(loadClaudeSessions(dir: "/nonexistent/sessions").isEmpty)
}
