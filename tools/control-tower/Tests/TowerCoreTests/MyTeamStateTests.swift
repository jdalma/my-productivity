import Foundation
import Testing
@testable import TowerCore

// my-team's state files read directly, against tools/my-team/src/commands/status.js.

func myTeamBase() throws -> String {
    let d = FileManager.default.temporaryDirectory.appending(path: "ct-myteam-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

func write(_ path: String, _ text: String) throws {
    try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

/// `<base>/<dir>/manifest.json` whose state_root is `root` (default `<base>/<dir>`). Returns the state root.
@discardableResult
func writeTeam(_ base: String, _ dir: String, session: String = "my-team-s:0", workers: [String] = ["w"],
               root: String? = nil) throws -> String {
    let root = root ?? "\(base)/\(dir)"
    let ws = workers.enumerated().map { #"{"name":"\#($1)","pane_id":"%\#($0 + 1)","cwd":"/c","agent_type":"claude"}"# }
    try write("\(base)/\(dir)/manifest.json", """
        {"team_name":"\(dir)","state_root":"\(root)","session_name":"\(session)","session_mode":"detached-session",
         "started_at":"2026-11-01T00:00:00.000Z","workers":[\(ws.joined(separator: ","))]}
        """)
    return root
}

private func pane(_ session: String, _ id: String, _ worker: String?) -> Pane {
    Pane(session: session, window: "@1", pane: id, pid: 1, dead: false, workerName: worker, title: "", cwd: "/")
}

@Test func stateRootBaseHonoursTheOverrideLikeMyTeam() {
    let home = ["HOME": "/h/me"]
    #expect(stateRootBase(home) == "/h/me/.my-team/sessions")
    #expect(stateRootBase(home.merging(["MY_TEAM_STATE_ROOT_BASE": "  "]) { $1 }) == "/h/me/.my-team/sessions")
    #expect(stateRootBase(home.merging(["MY_TEAM_STATE_ROOT_BASE": " ~/x/../teams \n"]) { $1 }) == "/h/me/teams")
    #expect(stateRootBase(home.merging(["MY_TEAM_STATE_ROOT_BASE": "~"]) { $1 }) == "/h/me")
    #expect(stateRootBase(home.merging(["MY_TEAM_STATE_ROOT_BASE": "/tmp/t"]) { $1 }) == "/tmp/t")
}

@Test func teamDirsSkipBakOmcAndPlainFilesAndComeSorted() throws {
    let base = try myTeamBase()
    defer { try? FileManager.default.removeItem(atPath: base) }
    for d in ["b-team", "a-team", "a-team.bak", ".omc"] { try writeTeam(base, d) }
    try write("\(base)/c-file", "{}")
    #expect(try loadTeams(base: base, panes: []).map(\.teamName) == ["a-team", "b-team"])
}

@Test func aMissingOrBrokenManifestSkipsOnlyThatTeam() throws {
    let base = try myTeamBase()
    defer { try? FileManager.default.removeItem(atPath: base) }
    try writeTeam(base, "ok")
    try FileManager.default.createDirectory(atPath: "\(base)/no-manifest", withIntermediateDirectories: true)
    try write("\(base)/broken/manifest.json", "{not json")
    try write("\(base)/no-session/manifest.json", #"{"team_name":"x","state_root":"/x","workers":[]}"#)
    #expect(try loadTeams(base: base, panes: []).map(\.teamName) == ["ok"])
}

@Test func noBaseMeansNoTeamsButAnUnreadableBaseThrows() throws {
    let base = try myTeamBase()
    defer { try? FileManager.default.removeItem(atPath: base) }
    #expect(try loadTeams(base: "\(base)/missing", panes: []).isEmpty)
    try write("\(base)/file", "")
    #expect { try loadTeams(base: "\(base)/file", panes: []) } throws: {
        "\($0)".hasPrefix("cannot read my-team state dir \(base)/file")
    }
}

@Test func filesAreReadUnderTheManifestStateRootNotTheTeamDir() throws {
    let base = try myTeamBase()
    defer { try? FileManager.default.removeItem(atPath: base) }
    let root = try writeTeam(base, "t", root: "\(base)/elsewhere")
    try write("\(root)/workers/w/status.json", #"{"state":"blocked","reason":"need input"}"#)
    try write("\(base)/t/workers/w/status.json", #"{"state":"wrong"}"#)
    let w = try loadTeams(base: base, panes: [])[0].workers[0]
    #expect(w.state == "blocked" && w.reason == "need input")
}

@Test func spoolUnreadAndSentPendingAreCounted() throws {
    let base = try myTeamBase()
    defer { try? FileManager.default.removeItem(atPath: base) }
    let root = try writeTeam(base, "t")
    for f in ["a.json", "b.json", "c.tmp"] { try write("\(root)/incoming-spool/w/\(f)", "{}") }
    try write("\(root)/mailbox/w.json", """
        {"schema_version":2,"worker":"w","inbox":{"m1":{},"m2":{},"m3":{}},
         "sent_pending":{"q1":{"sent_at":"2026-11-02T03:00:00.000Z"},"q2":{"sent_at":"2026-11-01T09:00:00.000Z"},"q3":{}}}
        """)
    let w = try loadTeams(base: base, panes: [])[0].workers[0]
    #expect(w.spool == 2)
    #expect(w.unread == 3)
    #expect(w.sentPending == 3)
    #expect(w.oldestPendingAt == "2026-11-01T09:00:00.000Z")
    #expect(w.reason == nil)
}

@Test func noMailboxIsAnEmptyOneNotAnError() throws {
    let base = try myTeamBase()
    defer { try? FileManager.default.removeItem(atPath: base) }
    try writeTeam(base, "t")
    let w = try loadTeams(base: base, panes: [])[0].workers[0]
    #expect(w.unread == 0 && w.sentPending == 0 && w.oldestPendingAt == nil && w.spool == 0)
    #expect(w.state == nil && w.reason == nil)
}

@Test func anUnreadableMailboxBecomesTheReasonUnlessStatusGaveOne() throws {
    let base = try myTeamBase()
    defer { try? FileManager.default.removeItem(atPath: base) }
    let root = try writeTeam(base, "t", workers: ["old", "bad", "said"])
    try write("\(root)/mailbox/old.json", #"{"schema_version":1,"inbox":{"m":{}}}"#)
    try write("\(root)/mailbox/bad.json", "{oops")
    try write("\(root)/mailbox/said.json", "[]")
    try write("\(root)/workers/said/status.json", #"{"state":"blocked","reason":"waiting on pm"}"#)
    let w = try loadTeams(base: base, panes: [])[0].workers
    #expect(w[0].reason == "mailbox unreadable: Mailbox at \(root)/mailbox/old.json has schema_version=1, expected 2. "
        + "Shutdown the team (my-team shutdown) and restart to begin with a fresh schema; automatic migration is not supported.")
    #expect(w[0].unread == 0)
    #expect(w[1].reason?.hasPrefix("mailbox unreadable: Mailbox at \(root)/mailbox/bad.json is not valid JSON") == true)
    #expect(w[2].reason == "waiting on pm")
}

@Test func aTeamIsAliveWhileOneOfItsWorkersIsLikeMyTeam() throws {
    // my-team src/lib/team-liveness.js: a split-pane team's session is someone else's and outlives the team (T216)
    let base = try myTeamBase()
    defer { try? FileManager.default.removeItem(atPath: base) }
    try writeTeam(base, "guest", session: "my-team-host-abc:0", workers: ["a", "b"])
    try writeTeam(base, "own", session: "my-team-own-abc:0", workers: ["a", "b"])
    func alive(_ panes: [Pane]) throws -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: try loadTeams(base: base, panes: panes).map { ($0.teamName, $0.teamAlive) })
    }
    let host = [pane("my-team-host-abc", "%50", "pm"), pane("my-team-host-abc", "%51", nil)]
    #expect(try alive(host) == ["guest": false, "own": false], "the host session lives on, the guest's workers are gone")
    #expect(try alive(host + [pane("my-team-host-abc", "%2", "b")]) == ["guest": true, "own": false], "one guest worker left")
    #expect(try alive([pane("my-team-own-abc", "%1", "a"), pane("my-team-own-abc", "%2", "b")]) == ["guest": false, "own": true])
    #expect(try alive([pane("my-team-own-abc", "%7", nil)]) == ["guest": false, "own": false], "own session with no worker pane")
}

@Test func aNullMailboxIsEmptyLikeMyTeamReadsIt() throws {
    #expect(try mailCounts(Data("null".utf8), path: "p") == (0, 0, nil))
    #expect { try mailCounts(Data("[]".utf8), path: "p") } throws: { "\($0)".contains("schema_version=missing") }
}

@Test func aWorkerIsAliveOnlyWithItsSessionNameAndPane() throws {
    let base = try myTeamBase()
    defer { try? FileManager.default.removeItem(atPath: base) }
    try writeTeam(base, "t", session: "my-team-t-abc:0", workers: ["a", "b", "c", "d"])
    let panes = [
        pane("my-team-t-abc", "%1", "a"),        // all three match
        pane("my-team-other", "%2", "b"),        // wrong session
        pane("my-team-t-abc", "%3", "someone"),  // wrong @worker_name
        pane("my-team-t-abc", "%99", "d"),       // re-spawned: manifest pane id is stale
    ]
    let team = try loadTeams(base: base, panes: panes)[0]
    #expect(team.teamAlive)
    #expect(team.workers.map(\.alive) == [true, false, false, false])
    let gone = try loadTeams(base: base, panes: [pane("my-team-other", "%1", "a")])[0]
    #expect(!gone.teamAlive)
    #expect(gone.workers.map(\.alive) == [false, false, false, false])
}

@Test func theManifestsGroupReachesTheTeamAndABlankOneIsNone() throws {
    let base = NSTemporaryDirectory() + "mt-group-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: base) }
    try writeTeam(base, "plain")
    for (dir, group) in [("grouped", "nudake"), ("blank", "  ")] {
        try write("\(base)/\(dir)/manifest.json", """
            {"team_name":"\(dir)","group":"\(group)","state_root":"\(base)/\(dir)","session_name":"s:0","session_mode":"detached-session",
             "workers":[{"name":"w","pane_id":"%1","cwd":"/c","agent_type":"claude"}]}
            """)
    }
    let teams = try loadTeams(base: base, panes: [])
    let groups = Dictionary(uniqueKeysWithValues: teams.map { ($0.teamName, $0.group) })
    #expect(groups == ["plain": nil, "grouped": "nudake", "blank": nil])
    #expect(toTeam(teams.first { $0.teamName == "grouped" }!, clients: []).group == "nudake")
}
