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

@Test func eachWorkerResumesItsLastClaudeSession() {
    let history = [
        session("pm-old", team: "t", worker: "pm", at: "2026-11-01T00:00:00.000Z"),
        session("pm-new", team: "t", worker: "pm", at: "2026-11-02T00:00:00.000Z"),
        session("core", team: "t", worker: "core", at: "2026-11-01T00:00:00.000Z"),
        session("cx", team: "t", worker: "cx", at: "2026-11-02T00:00:00.000Z", agent: .codex),
        session("other", team: "u", worker: "pm", at: "2026-11-03T00:00:00.000Z"),
        session("loose", team: nil, worker: "pm", at: "2026-11-03T00:00:00.000Z"),
    ]
    #expect(lastSessions(of: "t", in: history) == ["pm": "pm-new", "core": "core"])
}

@Test func aResumeConfigKeepsTheTeamAndAddsEachWorkersResume() throws {
    let base: [String: Any] = [
        "team_name": "t",
        "workers": [
            ["name": "pm", "agent_type": "claude", "cwd": "/w", "extra_prompt": "brief",
             "launch_args": ["--plugin-dir", "/p", "--resume", "stale"]],
            ["name": "core", "agent_type": "claude", "cwd": "/w"],
            ["name": "cx", "agent_type": "codex", "cwd": "/w", "launch_args": ["-m", "x"]],
            ["name": "fresh", "agent_type": "claude", "cwd": "/w"],
        ],
    ]
    let config = resumeConfig(base, sessions: ["pm": "pm-new", "core": "core-1", "cx": "cx-1"])
    let workers = try #require(config["workers"] as? [[String: Any]])
    #expect(config["team_name"] as? String == "t")
    #expect(workers[0]["extra_prompt"] as? String == "brief")  // the rest of the config as it was
    #expect(workers[0]["launch_args"] as? [String] == ["--plugin-dir", "/p", "--resume", "pm-new"])
    #expect(workers[1]["launch_args"] as? [String] == ["--resume", "core-1"])
    #expect(workers[2]["launch_args"] as? [String] == ["-m", "x"])  // codex starts afresh
    #expect(workers[3]["launch_args"] == nil)  // no session: a fresh start
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
