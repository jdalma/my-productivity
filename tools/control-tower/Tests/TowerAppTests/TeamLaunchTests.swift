import Foundation
import Testing
import TowerCore
@testable import TowerApp

private func session(_ id: String, team: String?, worker: String, at: String, agent: AgentKind = .claude,
                     live: Bool = false) -> HistorySession {
    HistorySession(id: id, agent: agent, title: worker, workspace: "/w", branch: nil, createdAt: nil, updatedAt: at,
                   lastPrompt: nil, transcriptPath: "/t/\(id).jsonl", live: live, resumeCommand: ["claude", "--resume", id],
                   member: team.map { TeamWorker(team: $0, worker: worker) })
}

@Test func aRunResumesItsWorkersEachInItsLastClaudeSession() throws {
    // one run's sessions; a worker that left the config since keeps its place, as the run had it
    let run = [
        session("pm-new", team: "t", worker: "pm", at: "2026-11-02T00:00:00.000Z"),
        session("pm-old", team: "t", worker: "pm", at: "2026-11-01T00:00:00.000Z"),
        session("core", team: "t", worker: "core", at: "2026-11-01T00:00:00.000Z"),
        session("cx", team: "t", worker: "cx", at: "2026-11-02T00:00:00.000Z", agent: .codex),
    ]
    let base: [String: Any] = [
        "team_name": "t", "note": "kept",
        "workers": [
            ["name": "pm", "agent_type": "claude", "cwd": "/w", "extra_prompt": "brief",
             "launch_args": ["--plugin-dir", "/p", "--resume", "stale"]],
            ["name": "cx", "agent_type": "codex", "cwd": "/w", "launch_args": ["-m", "x"]],
            ["name": "later", "agent_type": "claude", "cwd": "/w"],  // not in this run
        ],
    ]
    let config = resumeConfig(base, run: run)
    let workers = try #require(config["workers"] as? [[String: Any]])
    #expect(config["note"] as? String == "kept")
    #expect(workers.map { $0["name"] as? String } == ["pm", "cx", "core"])
    #expect(workers[0]["extra_prompt"] as? String == "brief")
    #expect(workers[0]["launch_args"] as? [String] == ["--plugin-dir", "/p", "--resume", "pm-new"])
    #expect(workers[1]["launch_args"] as? [String] == ["-m", "x"])  // codex starts afresh
    #expect(workers[2]["agent_type"] as? String == "claude" && workers[2]["cwd"] as? String == "/w")
    #expect(workers[2]["launch_args"] as? [String] == ["--resume", "core"])
}

@Test func theTeamsConfigIsTheNewestOneThatNamesIt() throws {
    let dir = NSTemporaryDirectory() + "teams-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    func write(_ name: String, _ team: String, _ age: TimeInterval) throws {
        let path = "\(dir)/\(name)"
        try Data(#"{"team_name":"\#(team)","workers":[]}"#.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
    }
    try write("old.json", "t", 100)
    try write("new.json", "t", 10)
    try write("t.resume.json", "t", 1)  // what the board wrote last time: never the base
    try write("other.json", "u", 1)
    try Data("not json".utf8).write(to: URL(fileURLWithPath: "\(dir)/broken.json"))
    #expect(teamConfigPath(named: "t", in: dir) == "\(dir)/new.json")
    #expect(teamConfigPath(named: "none", in: dir) == nil)
}

@Test func resumingATeamWritesItsConfigStartsItAndAttaches() {
    let argv = resumeTeamCommand(team: "t", config: #"{"team_name":"t"}"#, path: "/h/teams/t.resume.json",
                                 myTeam: "/bin/my-team", tmux: "/bin/tmux")
    // the shell script is fixed; the config, path and team go in as arguments, never into the script text
    #expect(argv.first == "/bin/sh" && argv[1] == "-c")
    #expect(!argv[2].contains("t.resume.json") && !argv[2].contains("team_name"))
    #expect(Array(argv[3...]) == ["sh", #"{"team_name":"t"}"#, "/h/teams/t.resume.json", "/bin/my-team", "/bin/tmux", "t"])
}

@Test func aTeamWithoutAConfigStartsFromItsLastManifest() throws {
    let root = NSTemporaryDirectory() + "launch-\(UUID().uuidString)"
    let teams = "\(root)/teams", state = "\(root)/sessions"
    try FileManager.default.createDirectory(atPath: "\(state)/t", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: teams, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    try Data(#"""
        {"team_name":"t","session_name":"my-team-t-x:0","workers":[
          {"name":"pm","pane_id":"%1","cwd":"/w","agent_type":"claude","role":"orchestrator","description":"d",
           "launch_args":["--plugin-dir","/p"],"overlay_path":"/s/AGENTS.md"}]}
        """#.utf8).write(to: URL(fileURLWithPath: "\(state)/t/manifest.json"))
    let base = try #require(teamBase("t", teams: teams, stateBase: state))
    let worker = try #require((base["workers"] as? [[String: Any]])?.first)
    #expect(base["team_name"] as? String == "t")
    #expect(Set(worker.keys) == ["name", "role", "agent_type", "cwd", "description", "launch_args"])  // no pane or path of the old run
    #expect(teamBase("gone", teams: teams, stateBase: state) == nil)
}

@Test func theWorkersAreTheLastRunsWithTheirBriefsFromTheConfig() throws {
    let root = NSTemporaryDirectory() + "launch-\(UUID().uuidString)"
    let teams = "\(root)/teams", state = "\(root)/sessions"
    try FileManager.default.createDirectory(atPath: "\(state)/t", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: teams, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    try Data(#"""
        {"team_name":"t","note":"kept","workers":[
          {"name":"pm","agent_type":"claude","cwd":"/old","extra_prompt":"pm brief"},
          {"name":"removed","agent_type":"claude","cwd":"/w","extra_prompt":"gone"}]}
        """#.utf8).write(to: URL(fileURLWithPath: "\(teams)/t.json"))
    // the run added `added` with add-worker and removed `removed`; pm moved to /w
    try Data(#"""
        {"team_name":"t","workers":[
          {"name":"pm","cwd":"/w","agent_type":"claude","role":"orchestrator","launch_args":["--x"],"pane_id":"%1"},
          {"name":"added","cwd":"/w","agent_type":"claude","role":"worker","launch_args":[],"pane_id":"%2"}]}
        """#.utf8).write(to: URL(fileURLWithPath: "\(state)/t/manifest.json"))
    let base = try #require(teamBase("t", teams: teams, stateBase: state))
    let workers = try #require(base["workers"] as? [[String: Any]])
    #expect(workers.map { $0["name"] as? String } == ["pm", "added"])
    #expect(workers[0]["extra_prompt"] as? String == "pm brief" && workers[0]["cwd"] as? String == "/w")
    #expect(workers[0]["pane_id"] == nil)
    #expect(base["note"] as? String == "kept")
}

@Test func aShellCommandLineQuotesEveryArgument() {
    #expect(shellCommandLine(["/bin/sh", "-c", "echo \"$1\" it's", "sh", #"{"a":"b c"}"#])
        == #"'/bin/sh' '-c' 'echo "$1" it'\''s' 'sh' '{"a":"b c"}'"#)
}

@Test func aTeamIsLaunchedOnceUntilItRunsOrTheWaitRunsOut() {
    let t0 = Date(timeIntervalSince1970: 1_000)
    var launches = TeamLaunches()
    let first = launches.begin("shop", at: t0)
    let again = launches.begin("shop", at: t0.addingTimeInterval(1))  // a second click while the first launch runs
    let other = launches.begin("lab", at: t0)  // another team is its own launch
    #expect(first && !again && other)
    #expect(launches.pending("shop"))
    launches.settle(running: ["shop"], now: t0.addingTimeInterval(20))  // the board sees it run
    #expect(!launches.pending("shop") && launches.pending("lab"))
    launches.settle(running: [], now: t0.addingTimeInterval(TeamLaunches.wait + 1))  // never came up: the button is back
    #expect(!launches.pending("lab"))
    let retry = launches.begin("lab", at: t0.addingTimeInterval(TeamLaunches.wait + 2))
    #expect(retry)
    launches.cancel("lab")  // the terminal did not open
    #expect(!launches.pending("lab"))
}

// MARK: - the scripts the board's terminals run, against stand-in my-team, tmux and claude

/// A folder of stand-in programs that log their arguments, removed when the test ends.
private final class Stubs {
    let dir = NSTemporaryDirectory() + "stubs-\(UUID().uuidString)"
    var log: String { (try? String(contentsOfFile: "\(dir)/log", encoding: .utf8)) ?? "" }

    init(status: String) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try stub("my-team", "case \"$1\" in status) printf '%s' '\(status)';; esac")
        try stub("tmux", "")
        try stub("claude", "pwd >> \"$(dirname \"$0\")/log\"")
    }

    private func stub(_ name: String, _ body: String) throws {
        let path = "\(dir)/\(name)"
        try "#!/bin/sh\necho \"\(name) $*\" >> \"$(dirname \"$0\")/log\"\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// Runs `argv` with stdin closed, so a `read` returns at once; its exit status.
    func run(_ argv: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    deinit { try? FileManager.default.removeItem(atPath: dir) }
}

@Test func aTeamWhoseSessionCannotBeFoundIsNotAttachedToAnother() throws {
    // `tmux attach -t ""` attaches to the most recent session: another team's (R48)
    let stubs = try Stubs(status: #"{"team_alive":false}"#)
    let path = "\(stubs.dir)/teams/t.resume.json"  // ~/teams may not exist yet
    let status = try stubs.run(resumeTeamCommand(team: "t", config: #"{"team_name":"t"}"#, path: path,
                                                 myTeam: "\(stubs.dir)/my-team", tmux: "\(stubs.dir)/tmux"))
    #expect(status != 0)
    // the folder was made and the config written; --continue keeps the stopped team's mail and work files (T51)
    #expect(stubs.log.contains("my-team start --continue --config \(path)"))
    #expect(FileManager.default.fileExists(atPath: path))
    #expect(!stubs.log.contains("tmux attach"))
}

@Test func aStartedTeamIsAttachedByItsSessionName() throws {
    let stubs = try Stubs(status: #"{"team_alive":false,"session":"my-team-t-abc:0"}"#)
    let status = try stubs.run(resumeTeamCommand(team: "t", config: "{}", path: "\(stubs.dir)/t.resume.json",
                                                 myTeam: "\(stubs.dir)/my-team", tmux: "\(stubs.dir)/tmux"))
    #expect(status == 0)
    #expect(stubs.log.contains("tmux attach -t my-team-t-abc:0"))
}

@Test func aNewTeamTerminalMakesTheTeamsFolderAndStartsThere() throws {
    let stubs = try Stubs(status: "")
    let teams = "\(stubs.dir)/teams"
    #expect(try stubs.run(newTeamCommand(teams: teams, claude: "\(stubs.dir)/claude")) == 0)
    #expect(stubs.log.contains("claude \(newTeamPrompt)"))
    #expect(stubs.log.contains(teams))  // claude ran inside it
    #expect(newTeamPrompt.contains(".resume.json"))  // told to leave the board's resume configs out
}

@Test func theClaudeFolderIsAddedWithoutAnEmptyEntry() {
    #expect(pathWithClaude("", home: "/h") == "/h/.local/bin")  // an empty entry would mean the current folder
    #expect(pathWithClaude("/a:/b", home: "/h") == "/a:/b:/h/.local/bin")
}
