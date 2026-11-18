import Foundation
import Testing
import TowerCore
@testable import TowerApp

// The test instance's dry run (T96): what the app would do outward is a line in a file, and nothing runs.

private func scratch() throws -> String {
    let dir = FileManager.default.temporaryDirectory.appending(path: "tower-dry-run-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func lines(_ path: String) -> [String] {
    ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

@Test func aFocusCommandGoesToTheTestServersSocket() {
    let tmux = tmuxCommand(["TOWER_TMUX_SOCKET": "/t/tmux.sock"])
    #expect(FocusRunner.resolved(["tmux", "select-pane", "-t", "%1"], tmux: tmux)
        == [towerTmuxBin, "-S", "/t/tmux.sock", "select-pane", "-t", "%1"])
    #expect(FocusRunner.resolved(["tmux", "select-pane", "-t", "%1"], tmux: [towerTmuxBin]) == [towerTmuxBin, "select-pane", "-t", "%1"])
    #expect(FocusRunner.resolved(["open", "-a", "Ghostty"], tmux: tmux) == ["/usr/bin/open", "-a", "Ghostty"])
}

@Test func aDryRunWritesTheCommandAndRunsNothing() async throws {
    let dir = try scratch()
    let made = dir + "/made", log = dir + "/actions.log"
    try await FocusRunner.run([["touch", made]], dryRun: log)
    #expect(!FileManager.default.fileExists(atPath: made))
    #expect(lines(log) == [shellCommandLine(["/usr/bin/touch", made])])

    try await FocusRunner.run([["touch", made]], dryRun: nil)
    #expect(FileManager.default.fileExists(atPath: made), "without a dry run the command runs as before")
    #expect(lines(log).count == 1)
}

@MainActor @Test func aDryRunNotificationIsALineAndNeverReachesTheSystem() throws {
    let log = try scratch() + "/actions.log"
    let n = Notifier(onClick: { _ in }, dryRun: log)
    #expect(n.center == nil)
    var s = Session(handle: "pane:demo:%1", agent: .claude, pid: 1, cwd: "/x", startedAt: nil, status: .wait,
                    myTurn: true, since: nil, permissionPrompt: false, title: "", tmux: nil, transcript: nil,
                    lastUser: "", lastAssistant: "done", termProgram: nil)
    n.post(s, title: "alpha")
    s.lastAssistant = "two\nlines"
    n.post(s, title: "beta")
    #expect(lines(log) == ["notify alpha: done", "notify beta: two lines"])
}

@Test func aDryRunLeavesTheLoginItemAlone() throws {
    let log = try scratch() + "/actions.log"
    var called: [String] = []
    try switchLoginItem(true, dryRun: log, register: { called.append("register") }, unregister: { called.append("unregister") })
    try switchLoginItem(false, dryRun: log, register: { called.append("register") }, unregister: { called.append("unregister") })
    #expect(called.isEmpty)
    #expect(lines(log) == ["login-item register", "login-item unregister"])

    try switchLoginItem(true, dryRun: nil, register: { called.append("register") }, unregister: { called.append("unregister") })
    #expect(called == ["register"])
}
