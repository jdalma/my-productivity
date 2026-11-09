import Foundation
import Testing
@testable import TowerCore

// Regressions from review R1: places the Swift port parted ways with Node.

@Test func aWorkerWithANonStringStatusReasonKeepsItsTeam() throws {
    let base = try myTeamBase()
    defer { try? FileManager.default.removeItem(atPath: base) }
    let root = try writeTeam(base, "t", workers: ["a", "b"])
    try write("\(root)/workers/a/status.json", #"{"state":"done","reason":{"x":1}}"#)
    try write("\(root)/workers/b/status.json", #"{"state":7,"reason":"fine"}"#)
    let teams = try loadTeams(base: base, panes: [])
    #expect(teams.map(\.teamName) == ["t"])
    let w = toTeam(teams[0], clients: []).workers
    #expect(w.map(\.workerName) == ["a", "b"])
    #expect(w[0].stateFile == StateFile(state: "done", reason: nil, updatedAt: nil))
    #expect(w[1].stateFile == StateFile(state: nil, reason: "fine", updatedAt: nil))
}

@Test func claudeSessionsAreReadInFileNameOrderLikeReaddirSync() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ct-order-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: root) }
    let dir = "\(root)/sessions"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let me = Int(ProcessInfo.processInfo.processIdentifier)
    let names = (0..<40).map { String(format: "%05d", ($0 * 7919) % 100_000) }
    for n in names {
        let json = #"{"pid":\#(me),"sessionId":"s\#(n)","cwd":"/c/\#(n)","status":"idle"}"#
        FileManager.default.createFile(atPath: "\(dir)/\(n).json", contents: Data(json.utf8))
    }
    let got = loadClaudeSessions(dir: dir, projectsDir: "\(root)/projects").map(\.cwd)
    #expect(got == names.sorted().map { "/c/\($0)" })
}

@Test func crlfCapturesStillShowTheModal() {
    #expect(permissionPromptIn("Do you want to proceed?\r\n❯ 1. Yes\r\n  2. No\r\n"))
    #expect(permissionPromptIn(" Do you trust the files in this folder?\r\n ❯ 1. Yes, proceed\r\n   2. No, exit\r\n"))
    #expect(!permissionPromptIn("❯ \r\n  ? for shortcuts\r\n"))
}

@Test func homeFollowsTheHOMEVariableLikeNodeHomedir() {
    #expect(homeDirectory(["HOME": "/tmp/nowhere"]) == "/tmp/nowhere")
    #expect(homeDirectory([:]) == NSHomeDirectory())
}

@Test func aMistypedSessionFieldIsDroppedNotTheWholeFile() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ct-l3-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: root) }
    let dir = "\(root)/sessions"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let me = Int(ProcessInfo.processInfo.processIdentifier)
    let files = [
        "a.json": #"{"pid":\#(me),"cwd":"/c/a","sessionId":5,"startedAt":"x","status":1,"name":123,"tmux":{},"updatedAt":1798000000000}"#,
        "b.json": #"{"pid":\#(me),"sessionId":"s"}"#, // no cwd
        "c.json": #"{"pid":"\#(me)","cwd":"/c/c"}"#, // pid is not a number
    ]
    for (name, json) in files { FileManager.default.createFile(atPath: "\(dir)/\(name)", contents: Data(json.utf8)) }
    let got = loadClaudeSessions(dir: dir, projectsDir: "\(root)/projects")
    #expect(got.map(\.cwd) == ["/c/a"])
    let a = try #require(got.first)
    #expect(a.sessionId == nil && a.startedAt == nil && a.name == nil && a.tmux == nil && a.transcript == nil)
    #expect(a.status == .wait)
    #expect(a.since == isoString(ms: 1_798_000_000_000))
}
