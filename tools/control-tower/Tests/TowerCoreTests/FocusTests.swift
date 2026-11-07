import Foundation
import Testing
@testable import TowerCore

private let clients = [TmuxClient(session: "my-team-demo-team-mvtepzfv", pid: 111, tty: "/dev/ttys001")]
private func fixtureBoard() throws -> Board { try JSONDecoder().decode(Board.self, from: fixtureData("board.json")) }

@Test func attachedSessionSelectsWindowAndPaneThenActivatesGhostty() throws {
    #expect(planFocus(handle: "pane:my-team-demo-team-mvtepzfv:%39", board: try fixtureBoard(), clients: clients)
        == FocusPlan(kind: .attached, commands: [
            ["tmux", "select-window", "-t", "my-team-demo-team-mvtepzfv:@5"],
            ["tmux", "select-pane", "-t", "%39"],
            ["open", "-a", "Ghostty"],
        ]))
}

@Test func detachedSessionOpensANewGhosttyWindowAttaching() throws {
    #expect(planFocus(handle: "pane:my-team-detached-team-mvrtwe47:%29", board: try fixtureBoard(), clients: clients, tmuxBin: "tmux")
        == FocusPlan(kind: .detached, commands: [
            ["tmux", "select-window", "-t", "my-team-detached-team-mvrtwe47:@4"],
            ["tmux", "select-pane", "-t", "%29"],
            planTerminal(in: NSHomeDirectory(), commandLine: "'tmux' 'attach' '-t' 'my-team-detached-team-mvrtwe47'",
                         keepOpen: false),
        ]))
    // Ghostty 1.3 takes `open --args -e` as files to open (user report, 2026-11-06): no such launch is planned
    let attach = planFocus(handle: "pane:my-team-detached-team-mvrtwe47:%29", board: try fixtureBoard(), clients: clients)
    #expect(!attach.commands.joined().contains("--args"))
    #expect(attach.commands.last?.dropLast(3).joined().contains("wait after command:false") == true)  // detaching closes it
}

@Test func outsideTmuxOpensByTermProgram() throws {
    var b = try fixtureBoard()
    #expect(planFocus(handle: "pid:54524", board: b, clients: clients) == FocusPlan(kind: .outside, commands: [["open", "-a", "Ghostty"]]))
    b.loose[0].termProgram = "Apple_Terminal"
    #expect(planFocus(handle: "pid:54524", board: b, clients: clients) == FocusPlan(kind: .outside, commands: [["open", "-a", "Terminal"]]))
    b.loose[0].termProgram = nil
    #expect(planFocus(handle: "pid:54524", board: b, clients: clients) == .none)
}

@Test func deadWorkerAndUnknownHandlePlanNothing() throws {
    let b = try fixtureBoard()
    #expect(planFocus(handle: "pane:my-team-demo-team-mvtepzfv:%41", board: b, clients: clients) == .none)
    #expect(planFocus(handle: "pane:nope:%1", board: b, clients: clients) == .none)
    #expect(planFocus(handle: "pid:1", board: b, clients: clients) == .none)
}

/// The read-only invariant: TowerCore never types into, ends, or runs focus on a session,
/// and never goes through a shell. `select-*` may appear only as planFocus argv literals.
@Test func towerCoreNeverTypesIntoOrEndsASession() throws {
    let dir = URL(fileURLWithPath: #filePath).appending(path: "../../../Sources/TowerCore").standardizedFileURL
    let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    #expect(files.count > 5)
    for f in files {
        let src = try String(contentsOf: f, encoding: .utf8)
        for banned in ["send-keys", "send-text", "kill-session", "kill-pane", "kill-server", "kill-window", "/bin/sh", "/bin/bash", "\"-c\""] {
            #expect(!src.contains(banned), "\(f.lastPathComponent) contains \(banned)")
        }
        if f.lastPathComponent != "Focus.swift" { #expect(!src.contains("select-"), "\(f.lastPathComponent)") }
    }
}

@Test func tmuxBinIsAbsoluteWhenTmuxIsOnPath() {
    #expect(towerTmuxBin == "tmux" || towerTmuxBin.hasPrefix("/"))
}

private func term(_ id: String, _ name: String, _ cwd: String = "/w") -> GhosttyTerminal { GhosttyTerminal(id: id, name: name, cwd: cwd) }

@Test func tmuxSessionPicksTheTabAttachedToIt() {
    let ts = [term("1", "tmux attach -t my-team-a"), term("2", "tmux attach -t my-team-ab"), term("3", "✳ my-team-a")]
    #expect(pickTerminal(ts, tmuxSession: "my-team-ab", title: nil, cwd: "/w") == "2")
    #expect(pickTerminal(ts, tmuxSession: "my-team-a", title: nil, cwd: "/w") == "1")
    #expect(pickTerminal(ts, tmuxSession: "my-team", title: nil, cwd: "/w") == nil)
    #expect(pickTerminal(ts + [term("4", "tmux attach -t my-team-a")], tmuxSession: "my-team-a", title: nil, cwd: "/w") == nil)
}

@Test func standaloneSessionPicksByTitleThenCwd() {
    let ts = [term("1", "✳ 문서 정리", "/a"), term("2", "⠐ 문서 정리", "/b"), term("3", "✳ 다른 일", "/a"), term("4", "/a", "/a")]
    #expect(pickTerminal(ts, tmuxSession: nil, title: "다른 일", cwd: "/a") == "3")
    #expect(pickTerminal(ts, tmuxSession: nil, title: "문서 정리", cwd: "/b") == "2")
    #expect(pickTerminal(ts, tmuxSession: nil, title: "문서 정리", cwd: "/z") == nil)
    #expect(pickTerminal(ts, tmuxSession: nil, title: "없는 제목", cwd: "/a") == nil)
    #expect(pickTerminal(ts, tmuxSession: nil, title: nil, cwd: "/a") == nil)
    #expect(pickTerminal(ts, tmuxSession: nil, title: "", cwd: "/a") == nil)
    #expect(pickTerminal([term("5", "문서 정리", "/z")], tmuxSession: nil, title: "문서 정리", cwd: "/z") == "5")
    #expect(pickTerminal([term("6", "A 문서 정리", "/z")], tmuxSession: nil, title: "문서 정리", cwd: "/z") == nil)
}

@Test func aSameTitledTabInAnotherDirectoryIsNotTheSession() {
    #expect(pickTerminal([term("a", "✳ X", "/a")], tmuxSession: nil, title: "X", cwd: "/b") == nil)
    #expect(pickTerminal([term("a", "✳ X", "missing value")], tmuxSession: nil, title: "X", cwd: "/b") == "a")
    #expect(pickTerminal([term("a", "✳ X", "")], tmuxSession: nil, title: "X", cwd: "/b") == "a")
    #expect(pickTerminal([term("a", "✳ X", "/a"), term("b", "✳ X", "missing value")], tmuxSession: nil, title: "X", cwd: "/b") == "b")
}

@Test func ghosttyListingParsesTabSeparatedLines() {
    let text = "ID-1\ttmux attach -t s\t/Users/me\nID-2\t✳ 제목\tmissing value\nbroken line\n"
    #expect(parseGhosttyTerminals(text) == [term("ID-1", "tmux attach -t s", "/Users/me"), term("ID-2", "✳ 제목", "missing value")])
}

@Test func ghosttyFocusPassesTheIdAsAnArgument() {
    let argv = ghosttyFocusArgv("x\" & do shell script \"y")
    #expect(argv.first == "osascript")
    #expect(argv.last == "x\" & do shell script \"y")
    #expect(!argv.dropLast().contains { $0.contains("x\"") })
}
