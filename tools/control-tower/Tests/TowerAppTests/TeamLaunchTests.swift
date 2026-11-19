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
        try Data(#"{"team_name":"\#(team)","workers":[{"name":"pm"}]}"#.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
    }
    try write("old.json", "t", 100)
    try write("new.json", "t", 10)
    try write("t.resume.json", "t", 1)  // what the board wrote last time: never the base
    try write("t.bak.json", "t", 0)  // a backup, whatever its suffix (T208)
    try write("other.json", "u", 1)
    try Data("not json".utf8).write(to: URL(fileURLWithPath: "\(dir)/broken.json"))
    #expect(teamConfigPath(named: "t", in: dir) == "\(dir)/new.json")
    // 팀 실행 lists the same file for the team, so it and the resume of a stopped run start from one config
    #expect(teamConfigs(in: dir).configs.first { $0.team == "t" }?.path == teamConfigPath(named: "t", in: dir))
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
    #expect(launches.teams == ["lab"])  // the running list's 띄우는 중 lines
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

// MARK: - T207: 팀 실행 from ~/teams, 팀 종료 with a confirmation

@Test func theLaunchListIsOneConfigATeamWithoutResumeBackupOrBrokenFiles() throws {
    let dir = NSTemporaryDirectory() + "teams-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    func write(_ name: String, _ text: String, age: TimeInterval = 0) throws {
        let path = "\(dir)/\(name)"
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
    }
    let w = #""workers":[{"name":"pm"},{"name":"core"}]"#
    try write("b.json", #"{"team_name":"b",\#(w)}"#)
    try write("a-old.json", #"{"team_name":"a",\#(w)}"#, age: 100)
    try write("a-new.json", #"{"team_name":"a",\#(w)}"#, age: 10)       // same team twice: the newest
    try write("a.resume.json", #"{"team_name":"a",\#(w)}"#)             // the board's resume config
    try write("a.json.bak-2026-11-19", #"{"team_name":"a",\#(w)}"#)     // a backup
    try write("c.bak.json", #"{"team_name":"c",\#(w)}"#)
    try write("notes.json", #"{"title":"not a team"}"#)
    try write("empty.json", #"{"team_name":"e","workers":[]}"#)
    try write("broken.json", "not json")
    try write("list.json", "[1]")
    try write("locked.json", #"{"team_name":"l",\#(w)}"#)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: "\(dir)/locked.json")
    try FileManager.default.createDirectory(atPath: "\(dir)/legacy-teams", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: "\(dir)/folder.json", withIntermediateDirectories: true)
    let list = teamConfigs(in: dir)
    #expect(list.configs.map { [$0.team, $0.file] } == [["a", "a-new.json"], ["b", "b.json"]])
    #expect(list.configs.map(\.workers) == [2, 2])
    #expect(list.unreadable == [
        UnreadableConfig(file: "broken.json", reason: .notJSON),
        UnreadableConfig(file: "empty.json", reason: .noWorkers),
        UnreadableConfig(file: "list.json", reason: .notJSON),
        UnreadableConfig(file: "locked.json", reason: .denied),
        UnreadableConfig(file: "notes.json", reason: .noTeamName),
    ])
    #expect(teamConfigs(in: "\(dir)/missing") == TeamConfigList())
}

@Test func aLaunchLineSaysWhenTheTeamLastRanOrThatItRunsNow() {
    let c = TeamConfig(team: "shop", path: "/t/shop.json", workers: 3, modified: .distantPast)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let ran = TeamLastRun(run: TeamRun(team: "shop", start: nil), updatedAt: Date(timeIntervalSince1970: 1_800_000_000 - 3 * 3600).formatted(.iso8601))
    #expect(launchItemSubtitle(c, last: ran, running: false, launching: false, now: now)
        == "워커 3 · 마지막 실행 " + relativeTime(ran.updatedAt, now: now))  // the history list's clock
    #expect(launchItemSubtitle(c, last: nil, running: false, launching: false, now: now) == "워커 3 · 기록 없음")
    #expect(launchItemSubtitle(c, last: ran, running: true, launching: false, now: now) == "워커 3 · 실행 중")
    #expect(launchItemSubtitle(c, last: ran, running: false, launching: true, now: now) == "워커 3 · 띄우는 중")
}

@Test func eachTeamsLastRunIsItsNewestSessionsRun() {
    // two runs of shop days apart (workers launched minutes apart are one run), one of lab, a single terminal
    let history = [
        session("b-qa", team: "shop", worker: "qa", at: "2026-11-05T11:00:00.000Z"),
        session("b-pm", team: "shop", worker: "pm", at: "2026-11-05T10:00:00.000Z"),
        session("a-pm", team: "shop", worker: "pm", at: "2026-11-02T10:00:00.000Z"),
        session("lab", team: "lab", worker: "pm", at: "2026-11-04T10:00:00.000Z"),
        session("solo", team: nil, worker: "x", at: "2026-11-06T10:00:00.000Z"),
    ].map { h in
        var h = h
        // when each began: shop's two workers of 11-05 four minutes apart, so one run
        h.createdAt = ["b-qa": "2026-11-05T09:04:00.000Z", "b-pm": "2026-11-05T09:00:00.000Z"][h.id] ?? h.updatedAt
        return h
    }
    let last = lastRuns(history)
    #expect(Set(last.keys) == ["shop", "lab"])
    #expect(last["shop"]?.updatedAt == "2026-11-05T11:00:00.000Z")
    #expect(last["shop"]?.run == teamRuns(history)["/t/b-pm.jsonl"])  // the newer run, not the one of 11-02
    #expect(last["shop"]?.run != teamRuns(history)["/t/a-pm.jsonl"])
    let config = { (team: String) in TeamConfig(team: team, path: "/t/\(team).json", workers: 1, modified: .distantPast) }
    // the team run last first, then the ones never run by name
    #expect(launchOrder([config("zeta"), config("lab"), config("alpha"), config("shop")], last: last).map(\.team)
        == ["shop", "lab", "alpha", "zeta"])
}

@Test func aTeamWithAStoppedRunResumesItAndOneWithoutStartsFromItsConfig() {
    let run = TeamRun(team: "shop", start: 1)
    let last = ["shop": TeamLastRun(run: run, updatedAt: "2026-11-05T11:00:00.000Z")]
    let shop = TeamConfig(team: "shop", path: "/h/teams/shop.json", workers: 2, modified: .distantPast)
    let lab = TeamConfig(team: "lab", path: "/h/teams/lab.json", workers: 1, modified: .distantPast)
    #expect(launchPlan(shop, last: last) == .resume(run))  // Tower.resumeTeam: each worker back in its conversation
    #expect(launchPlan(lab, last: last) == .start)          // launchTeamCommand: start --continue
    #expect(launchItemTooltip(shop, plan: .resume(run), home: "/h").contains("마지막 대화를 resume"))
    #expect(launchItemTooltip(lab, plan: .start, home: "/h") == "기록이 없어 config로 띄웁니다 (my-team start --continue).\n~/teams/lab.json")
}

@Test func aFailedShutdownSaysMyTeamsLastLineOrItsExitCode() {
    let said = CommandError(argv: ["my-team"], output: "[my-team] Shutting down…\nerror: no such team", status: 1)
    #expect(shutdownFailure(team: "shop", said) == Failure(
        title: "“shop” 팀을 종료하지 못함", reason: "error: no such team\n터미널에서 my-team shutdown --team shop 을 직접 실행해 보세요."))
    let silent = CommandError(argv: ["my-team"], output: "", status: 2)
    #expect(shutdownFailure(team: "shop", silent).reason.hasPrefix("my-team이 2로 끝났습니다.\n"))
    #expect(shutdownMessage(workers: 4).hasPrefix("워커 4개와 tmux 세션이 바로 끝나고"))
}

@Test func launchingATeamStartsItsConfigWithoutAShellParsingTheName() throws {
    let team = #"a b'"c;$(x)"#
    let argv = launchTeamCommand(team: team, path: "/h/teams/x y.json", myTeam: "/bin/my-team", tmux: "/bin/tmux")
    #expect(argv.first == "/bin/sh" && argv[1] == "-c")
    #expect(!argv[2].contains("x y.json") && !argv[2].contains(team))
    #expect(Array(argv[3...]) == ["sh", "/h/teams/x y.json", "/bin/my-team", "/bin/tmux", team])
}

@Test func aLaunchedTeamStartsWithContinueAndAttachesWritingNoFile() throws {
    let stubs = try Stubs(status: #"{"team_alive":false,"session":"my-team-t-abc:0"}"#)
    let path = "\(stubs.dir)/t.json"
    #expect(try stubs.run(launchTeamCommand(team: "t", path: path, myTeam: "\(stubs.dir)/my-team", tmux: "\(stubs.dir)/tmux")) == 0)
    #expect(stubs.log.contains("my-team start --continue --config \(path)"))
    #expect(stubs.log.contains("tmux attach -t my-team-t-abc:0"))
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func aRunningTeamIsOnlyAttached() throws {
    let stubs = try Stubs(status: #"{"team_alive":true,"session":"my-team-t-abc:0"}"#)
    #expect(try stubs.run(launchTeamCommand(team: "t", path: "/x.json", myTeam: "\(stubs.dir)/my-team", tmux: "\(stubs.dir)/tmux")) == 0)
    #expect(!stubs.log.contains("my-team start"))
    #expect(stubs.log.contains("tmux attach -t my-team-t-abc:0"))
}

@Test func shutdownIsOneArgvPerArgumentAndRunsAsIs() {
    let team = #"a b'"c"#
    let argv = shutdownTeamArgv(team: team, myTeam: "/opt/bin/my-team")
    #expect(argv == ["/opt/bin/my-team", "shutdown", "--team", team])
    #expect(FocusRunner.resolved(argv, tmux: ["/bin/tmux"]) == argv)  // an absolute path is not put under /usr/bin
}

@Test func noTeamIsShutDownWithoutItsConfirmation() {
    var s = TeamShutdowns()
    let unasked = s.confirm("shop")                   // no dialog: nothing to shut down
    #expect(!unasked)
    let asked = s.ask("shop")
    let other = s.confirm("lab")                      // not the team the dialog asks about
    s.cancel()                                       // 취소
    let cancelled = s.confirm("shop")
    #expect(asked && !other && !cancelled && s.running.isEmpty && s.asking == nil)
    _ = s.ask("shop")
    s.close()                                        // the dialog closes before 팀 종료's action runs
    let confirmed = s.confirm("shop")                 // 팀 종료
    let again = s.confirm("shop")                     // once per confirmation
    let second = s.ask("shop")                        // no second dialog while it shuts down
    #expect(confirmed && !again && !second && s.asking == nil)
    s.settle(running: ["shop"])                       // still seen running: still shutting down
    #expect(s.running == ["shop"])
    s.settle(running: [])                            // gone from the board: the menu item is back
    let back = s.ask("shop")
    #expect(back)
    _ = s.confirm("shop")
    s.failed("shop")                                 // the command failed: it can be tried again
    let retry = s.ask("shop")
    #expect(retry)
}

@Test func aDialogClosedAnotherWayDoesNotComeBack() {
    var s = TeamShutdowns()
    _ = s.ask("shop")
    s.close()                                        // closed without a button (the window went away)
    #expect(s.asking == nil && s.running.isEmpty)    // the dialog is not shown again, nothing was shut down
}

@Test func myTeamRunsWithHomebrewOnPathAndNoWorkersVariables() {
    // what launchd gives an app opened from Finder: no Homebrew, where `env node` finds node (T207 review M1, S1)
    let launchd = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/h",
                   "MY_TEAM_WORKER": "pm", "MY_TEAM_STATE_ROOT": "/s", "OMC_TEAM_WORKER": "t/pm"]
    let env = myTeamEnvironment(launchd)
    #expect(env["PATH"]?.split(separator: ":").contains("/opt/homebrew/bin") == true)
    #expect(env["HOME"] == "/h")
    #expect(env["MY_TEAM_WORKER"] == nil && env["MY_TEAM_STATE_ROOT"] == nil && env["OMC_TEAM_WORKER"] == nil)
}

@Test func theShutdownRunsInTheEnvironmentItIsGiven() async throws {
    // a stand-in my-team that logs the PATH and worker it sees; the app's own environment is not what it gets
    let dir = NSTemporaryDirectory() + "env-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let bin = "\(dir)/my-team"
    try "#!/bin/sh\necho \"$PATH|${MY_TEAM_WORKER-unset}|$*\" > \"$(dirname \"$0\")/log\"\n".write(toFile: bin, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin)
    let env = myTeamEnvironment(["PATH": "/usr/bin:/bin", "MY_TEAM_WORKER": "pm"])
    try await FocusRunner.run([shutdownTeamArgv(team: "a b", myTeam: bin)], env: env, dryRun: nil)
    let log = try String(contentsOfFile: "\(dir)/log", encoding: .utf8)
    #expect(log.hasPrefix(env["PATH"]! + "|unset|shutdown --team a b"))
}

@Test func aShutdownThatHangsIsStoppedAndCountsAsFailed() async throws {
    let dir = NSTemporaryDirectory() + "hang-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let bin = "\(dir)/my-team"
    try "#!/bin/sh\nexec sleep 30\n".write(toFile: bin, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin)
    let started = Date()
    do {
        try await FocusRunner.run([shutdownTeamArgv(team: "t", myTeam: bin)], timeout: 1, dryRun: nil)
        Issue.record("a command past its timeout must fail")
    } catch {
        #expect(Date().timeIntervalSince(started) < 10)
        // the alert says so; the line's spinner goes (Tower.confirmShutdown calls `failed`) and 팀 종료 is back
        #expect(shutdownFailure(team: "t", error).reason.hasPrefix("1초 안에 끝나지 않아 멈췄습니다.\n"))
    }
    #expect(shutdownTimeout == 30)
}
