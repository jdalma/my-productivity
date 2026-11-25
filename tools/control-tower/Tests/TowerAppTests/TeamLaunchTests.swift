import Foundation
import os
import Testing
import TowerCore
@testable import TowerApp

private func session(_ id: String, team: String?, worker: String, at: String, agent: AgentKind = .claude,
                     live: Bool = false) -> HistorySession {
    HistorySession(id: id, agent: agent, title: worker, workspace: "/", branch: nil, createdAt: nil, updatedAt: at,
                   lastPrompt: nil, transcriptPath: "/t/\(id).jsonl", live: live, resumeCommand: ["claude", "--resume", id],
                   member: team.map { TeamWorker(team: $0, worker: worker) })
}

@Test func aRunStartsItsWorkersAgainEachInANewConversation() throws {
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
            ["name": "pm", "agent_type": "claude", "cwd": "/", "extra_prompt": "brief",
             "launch_args": ["--plugin-dir", "/p", "--resume", "stale"]],
            ["name": "cx", "agent_type": "codex", "cwd": "/", "launch_args": ["-m", "x"]],
            ["name": "later", "agent_type": "claude", "cwd": "/"],  // not in this run
        ],
    ]
    let config = resumeConfig(base, run: run).config
    let workers = try #require(config["workers"] as? [[String: Any]])
    #expect(config["note"] as? String == "kept")
    #expect(workers.map { $0["name"] as? String } == ["pm", "cx", "core"])
    #expect(workers[0]["extra_prompt"] as? String == "brief")
    #expect(workers[0]["launch_args"] as? [String] == ["--plugin-dir", "/p"])  // a stale --resume is taken out
    #expect(workers[1]["launch_args"] as? [String] == ["-m", "x"])
    #expect(workers[2]["agent_type"] as? String == "claude" && workers[2]["cwd"] as? String == "/")
    #expect(workers[2]["launch_args"] == nil)  // no session id added
}

@Test func everyArgThatCarriesAClaudeConversationOverIsTakenOut() {
    #expect(withoutResume(["--resume", "id", "-m", "x"]) == ["-m", "x"])
    #expect(withoutResume(["--resume", "--model", "x"]) == ["--model", "x"])  // a flag after it is not its id
    #expect(withoutResume(["-r", "id", "--resume=id2", "--continue", "-c", "--plugin-dir", "/p"]) == ["--plugin-dir", "/p"])
    #expect(withoutResume(["--resume"]) == [])
}

@Test func aWorkerWhoseFolderIsGoneIsLeftOutOfTheResume() throws {
    // a worker added on a worktree that was removed since: my-team start would refuse the whole config
    var gone = session("app", team: "t", worker: "app", at: "2026-11-02T00:00:00.000Z")
    gone.workspace = "/nonexistent-\(UUID().uuidString)"
    let run = [session("pm", team: "t", worker: "pm", at: "2026-11-02T00:00:00.000Z"), gone]
    let base: [String: Any] = ["workers": [["name": "pm", "agent_type": "claude", "cwd": "~"]]]
    let resumed = resumeConfig(base, run: run)
    #expect(resumed.workers.map { $0["name"] as? String } == ["pm"])
    // R15 L1: the user is told who was left out, and the team still starts
    #expect(resumed.gone == [GoneWorker(name: "app", cwd: gone.workspace)])
    let problem = try #require(resumed.problem(team: "t"))
    #expect(!problem.stops)
    #expect(problem.failure.title == "“t” 팀을 워커 1개 없이 띄움")
    #expect(problem.failure.reason == "작업 폴더가 없어 뺀 워커: app (\(gone.workspace))")
    #expect(resumeConfig(base, run: [run[0]]).problem(team: "t") == nil, "nobody left out, nothing to say")
}

@Test func aResumeWithNoWorkerOrNoOrchestratorLeftDoesNotStartAndNamesTheMissingFolders() throws {
    // R15 L2, L3: my-team would fail with `workers must be a non-empty array` or `no 'orchestrator'`, naming no folder
    let gone = "/nonexistent-\(UUID().uuidString)"
    let run = [session("pm", team: "t", worker: "pm", at: "2026-11-02T00:00:00.000Z"),
               session("dev", team: "t", worker: "dev", at: "2026-11-02T00:00:00.000Z")]
    let none = resumeConfig(["workers": [["name": "pm", "agent_type": "claude", "cwd": gone + "/pm"],
                                         ["name": "dev", "agent_type": "claude", "cwd": gone + "/dev"]]], run: run)
    #expect(none.workers.isEmpty)
    let empty = try #require(none.problem(team: "t"))
    #expect(empty.stops)
    #expect(empty.failure.reason == "모든 워커의 작업 폴더가 없습니다: pm (\(gone)/pm), dev (\(gone)/dev)")

    let roles = resumeConfig(["workers": [["name": "pm", "agent_type": "claude", "cwd": gone, "role": "orchestrator"],
                                          ["name": "dev", "agent_type": "claude", "cwd": "/", "role": "worker"]]], run: run)
    let headless = try #require(roles.problem(team: "t"))
    #expect(headless.stops)
    #expect(headless.failure.title == "“t” 팀을 이어서 띄우지 못함")
    #expect(headless.failure.reason.hasPrefix("orchestrator의 작업 폴더가 없어") && headless.failure.reason.hasSuffix("pm (\(gone))"))

    // R15 L3 (T229 sub-1 L1): only the orchestrator declares a role; the rest would start as peers without it
    let onlyPM = resumeConfig(["workers": [["name": "pm", "agent_type": "claude", "cwd": gone, "role": "orchestrator"],
                                           ["name": "dev", "agent_type": "claude", "cwd": "/"]]], run: run)
    #expect(onlyPM.problem(team: "t")?.stops == true)

    // a peer team (no roles) that lost a worker still starts
    let peers = resumeConfig(["workers": [["name": "pm", "agent_type": "claude", "cwd": gone],
                                          ["name": "dev", "agent_type": "claude", "cwd": "/"]]], run: run)
    #expect(peers.problem(team: "t")?.stops == false)
}

@Test func onlyAFolderOfTheFormMyTeamTakesCanBeGone() throws {
    // my-team config/parser.js: cwd absolute or ~, ~ being $HOME; any other form is my-team's to refuse and report
    let home = NSTemporaryDirectory() + "home-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: home + "/repo", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: home) }
    try Data().write(to: URL(fileURLWithPath: home + "/file"))
    #expect(!folderIsGone("~", home: home) && !folderIsGone("~/repo", home: home) && !folderIsGone(home + "/repo", home: home))
    #expect(folderIsGone("~/gone", home: home) && folderIsGone(home + "/gone", home: home))
    #expect(folderIsGone("~/file", home: home), "a file is not a folder")
    #expect(!folderIsGone("gone", home: home) && !folderIsGone("~other/gone", home: home) && !folderIsGone(nil, home: home))
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
        {"team_name":"t","group":"nudake","session_name":"my-team-t-x:0","workers":[
          {"name":"pm","pane_id":"%1","cwd":"/w","agent_type":"claude","role":"orchestrator","description":"d",
           "launch_args":["--plugin-dir","/p"],"overlay_path":"/s/AGENTS.md"}]}
        """#.utf8).write(to: URL(fileURLWithPath: "\(state)/t/manifest.json"))
    let base = try #require(teamBase("t", teams: teams, stateBase: state))
    let worker = try #require((base["workers"] as? [[String: Any]])?.first)
    #expect(base["team_name"] as? String == "t")
    #expect(base["group"] as? String == "nudake")  // with no config, the group comes from the manifest
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
    try write("b.json", #"{"team_name":"b","group":"nudake",\#(w)}"#)
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
    #expect(list.configs.map(\.others) == [["a-old.json"], []])
    #expect(list.configs.map(\.group) == [nil, "nudake"])  // the config's group, none when it names none
    #expect(list.unreadable == [
        UnreadableConfig(file: "broken.json", reason: .notJSON),
        UnreadableConfig(file: "empty.json", reason: .noWorkers),
        UnreadableConfig(file: "list.json", reason: .notJSON),
        UnreadableConfig(file: "locked.json", reason: .denied),
        UnreadableConfig(file: "notes.json", reason: .noTeamName),
    ])
    #expect(teamConfigs(in: "\(dir)/missing") == TeamConfigList())
}

@Test func aLaunchLineSaysWhenTheTeamLastRanOrThatItRunsNow() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Seoul"))
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 19, minute: 8)))
    func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> String {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!.formatted(.iso8601)
    }
    #expect(lastRunTime(at(2026, 11, 19, 14, 30), now: now, calendar: calendar) == "오늘 14:30")
    #expect(lastRunTime(at(2026, 11, 18, 9, 5), now: now, calendar: calendar) == "어제 09:05")
    #expect(lastRunTime(at(2026, 11, 17, 22, 40), now: now, calendar: calendar) == "11-17 22:40")
    #expect(lastRunTime(at(2025, 12, 3, 8, 0), now: now, calendar: calendar) == "2025-12-03")
    #expect(lastRunTime("not a time", now: now, calendar: calendar) == nil)

    let ran = TeamLastRun(run: TeamRun(team: "shop", start: nil), updatedAt: Date().addingTimeInterval(-60).formatted(.iso8601))
    let real = Date()
    #expect(launchItemSubtitle(workers: 3, last: ran, running: false, launching: false, now: real) == "\(lastRunTime(ran.updatedAt, now: real)!) · 워커 3")
    #expect(launchItemSubtitle(workers: 3, last: nil, running: false, launching: false, now: real) == "기록 없음 · 워커 3")
    #expect(launchItemSubtitle(workers: 3, last: nil, running: false, launching: false, now: real, group: "nudake") == "nudake · 기록 없음 · 워커 3")
    #expect(launchItemSubtitle(workers: 3, last: ran, running: true, launching: false, now: real) == "실행 중 · 워커 3")
    #expect(launchItemSubtitle(workers: 3, last: ran, running: false, launching: true, now: real) == "띄우는 중 · 워커 3")
}

@Test func aLaunchLinesTooltipSaysWhatPickingItDoes() {
    var c = TeamConfig(team: "shop", path: "/h/teams/shop.json", workers: 3, modified: .distantPast)
    let now = Date()
    let ran = TeamLastRun(run: TeamRun(team: "shop", start: nil), updatedAt: now.addingTimeInterval(-3 * 3600).formatted(.iso8601))
    #expect(launchItemTooltip(c, last: ran, running: false, home: "/h", now: now)
        == "~/teams/shop.json\n마지막 실행 \(relativeTime(ran.updatedAt, now: now))\n실행: 작업판을 이어 가고, 워커는 새 대화에서 작업판·마지막 handoff로 이어갑니다")
    #expect(launchItemTooltip(c, last: nil, running: false, home: "/h", now: now)
        == "~/teams/shop.json\n실행: 작업판을 이어 가고, 워커는 새 대화로 시작합니다")
    c.group = "nudake"
    #expect(launchItemTooltip(c, last: nil, running: false, home: "/h", now: now)
        == "~/teams/shop.json\n그룹 nudake\n실행: 작업판을 이어 가고, 워커는 새 대화로 시작합니다")
    c.group = nil
    c.others = ["shop-old.json"]
    #expect(launchItemTooltip(c, last: ran, running: true, home: "/h", now: now)
        == "~/teams/shop.json\n이 팀은 지금 실행 중입니다\n같은 팀 config: shop-old.json (가장 최근 수정 파일로 띄움)")
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
    try "#!/bin/sh\necho $$ > \"$(dirname \"$0\")/pid\"\nexec sleep 30\n".write(toFile: bin, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin)
    let started = Date()
    // T44: the stub's death is timed on a thread of its own, as T228 did for FocusRunnerTests. Timing `run`'s throw
    // also timed the wait for a cooperative thread, which tests run side by side held: 25 to 140 s for a 1 s timeout.
    let died = OSAllocatedUnfairLock<Date?>(initialState: nil), thrown = OSAllocatedUnfairLock(initialState: false)
    let watched = DispatchSemaphore(value: 0)
    Thread {
        func pid() -> pid_t {
            (try? String(contentsOfFile: "\(dir)/pid", encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        }
        var stub = pid()
        // `run` throws only once the stub has ended: read once more after that, then stop looking
        while stub == 0, Date().timeIntervalSince(started) < 40 {
            let ended = thrown.withLock { $0 }
            stub = pid()
            if ended { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        while stub != 0, kill(stub, 0) == 0, Date().timeIntervalSince(started) < 40 { Thread.sleep(forTimeInterval: 0.01) }
        // no pid: it was stopped before its first line ran (a loaded machine), so before any of its 30 s
        let at = stub != 0 ? Date() : started
        died.withLock { $0 = at }
        watched.signal()
    }.start()
    do {
        try await FocusRunner.run([shutdownTeamArgv(team: "t", myTeam: bin)], timeout: 1, dryRun: nil)
        thrown.withLock { $0 = true }
        Issue.record("a command past its timeout must fail")
    } catch {
        thrown.withLock { $0 = true }
        await withCheckedContinuation { c in Thread { watched.wait(); c.resume() }.start() }
        let took = died.withLock { $0 }.map { $0.timeIntervalSince(started) } ?? .infinity
        #expect(took < 25, "the stub died after \(took) s")  // well before the stub's own 30 s, with room for a loaded machine
        // the alert says so; the line's spinner goes (Tower.confirmShutdown calls `failed`) and 팀 종료 is back
        #expect(shutdownFailure(team: "t", error).reason.hasPrefix("1초 안에 끝나지 않아 멈췄습니다.\n"))
    }
    #expect(shutdownTimeout == 30)
}

@Test func aLaunchLineCountsTheWorkersPickingItStarts() throws {
    // T208 R5 S1: shop's config names one worker; its last run had three (two added mid-run), and its resume
    // starts all three. lab never ran: start --continue starts its config's two.
    let root = NSTemporaryDirectory() + "count-\(UUID().uuidString)"
    let teams = "\(root)/teams", state = "\(root)/sessions"
    try FileManager.default.createDirectory(atPath: teams, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    try Data(#"{"team_name":"shop","workers":[{"name":"pm","agent_type":"claude","cwd":"/"}]}"#.utf8)
        .write(to: URL(fileURLWithPath: "\(teams)/shop.json"))
    try Data(#"{"team_name":"lab","workers":[{"name":"a"},{"name":"b"}]}"#.utf8).write(to: URL(fileURLWithPath: "\(teams)/lab.json"))
    let history = ["pm", "core", "qa"].map { w in
        var h = session("s-\(w)", team: "shop", worker: w, at: "2026-11-05T10:00:00.000Z")
        h.createdAt = "2026-11-05T09:00:00.000Z"
        return h
    }
    let configs = teamConfigs(in: teams).configs
    let counts = launchWorkerCounts(configs, history: history, teams: teams, stateBase: state)
    #expect(counts == ["shop": 3, "lab": 2])
    // the same count as the config the resume writes
    let run = try #require(lastRuns(history)["shop"]?.run)
    let resumed = try #require(resumeConfig(for: run, history: history, teams: teams, stateBase: state))
    #expect(resumed.workers.count == counts["shop"])
}

@Test func theDefaultStateBaseHonoursMyTeamStateRootBase() throws {
    let root = NSTemporaryDirectory() + "launch-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: "\(root)/sessions/t", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    try Data(#"{"team_name":"t","workers":[{"name":"pm","cwd":"/w","agent_type":"claude"}]}"#.utf8)
        .write(to: URL(fileURLWithPath: "\(root)/sessions/t/manifest.json"))
    let previous = getenv("MY_TEAM_STATE_ROOT_BASE").map { String(cString: $0) }
    setenv("MY_TEAM_STATE_ROOT_BASE", "\(root)/sessions", 1)
    defer { if let previous { setenv("MY_TEAM_STATE_ROOT_BASE", previous, 1) } else { unsetenv("MY_TEAM_STATE_ROOT_BASE") } }
    let base = try #require(teamBase("t", teams: "\(root)/no-teams"))
    #expect((base["workers"] as? [[String: Any]])?.count == 1)
}
