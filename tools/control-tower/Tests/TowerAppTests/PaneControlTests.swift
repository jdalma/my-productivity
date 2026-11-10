import Foundation
import Testing
@testable import TowerApp

private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

@Test func outputLinesUnescapeOctalAndKeepRawUTF8() {
    var p = ControlModeParser(pane: "%1")
    // tmux escapes bytes under 0x20 and the backslash as \ooo; bytes from 0x80 come raw
    let events = p.feed(bytes("%output %1 a\\033[1mb\\015\\012\\134x 한\n"))
    #expect(events == [.output(bytes("a\u{1b}[1mb\r\n\\x 한"))])
}

@Test func otherPanesOutputIsDropped() {
    var p = ControlModeParser(pane: "%1")
    #expect(p.feed(bytes("%output %2 noise\n%output %10 more\n%output %1 mine\n")) == [.output(bytes("mine"))])
}

@Test func linesSplitAcrossReadsAreJoined() {
    var p = ControlModeParser(pane: "%1")
    #expect(p.feed(bytes("%output %1 ab")).isEmpty)
    #expect(p.feed(bytes("c\\0")).isEmpty)
    #expect(p.feed(bytes("33x\n")) == [.output(bytes("abc\u{1b}x"))])
}

@Test func aCharacterCutBetweenTwoOutputLinesReachesTheTerminalWhole() {
    // tmux may end one %output line inside a UTF-8 sequence; the parser passes bytes through and the
    // terminal joins them, so nothing is lost or replaced
    var p = ControlModeParser(pane: "%1")
    let han = Array("한".utf8)
    var out: [UInt8] = []
    var input = bytes("%output %1 x")
    input += han[0..<2]
    input += bytes("\n%output %1 ")
    input += han[2...]
    input += bytes("y\n")
    for e in p.feed(input) {
        if case .output(let b) = e { out += b }
    }
    #expect(String(decoding: out, as: UTF8.self) == "x한y")
}

@Test func commandRepliesAndNotificationsAreTold() {
    var p = ControlModeParser(pane: "%1")
    let events = p.feed(bytes("""
        %begin 1 2 1
        80 24 3 5
        %end 1 2 1
        %begin 1 3 1
        can't find pane: %9
        %error 1 3 1
        %layout-change @1 abcd,80x24,0,0,1 abcd,80x24,0,0,1 *
        %window-close @1
        %exit

        """))
    #expect(events == [
        .reply(["80 24 3 5"], ok: true),
        .reply(["can't find pane: %9"], ok: false),
        .layoutChanged,
        .windowClosed,
        .exit,
    ])
}

@Test func aReplyEndsOnlyAtItsOwnGuardLine() {
    // tmux does not escape a reply's lines: a pane line that looks like %end or %output is still the reply's
    var p = ControlModeParser(pane: "%0")
    let events = p.feed(bytes("""
        %begin 1700000000 7 1
        top
        %end 1 2 0
        %error 1700000000 8 1
        %output %0 INJECTED
        bottom
        %end 1700000000 7 1
        %output %0 live

        """))
    #expect(events == [
        .reply(["top", "%end 1 2 0", "%error 1700000000 8 1", "%output %0 INJECTED", "bottom"], ok: true),
        .output(bytes("live")),
    ])
}

// MARK: - a control mode client against a throwaway tmux server (`tmux -L`), never the user's

import TowerCore

/// A tmux server on its own socket, killed when the test ends.
private final class ScratchServer {
    let socket = "ct-test-\(UUID().uuidString.prefix(8))"
    var tmux: [String] { [towerTmuxBin, "-L", socket, "-f", "/dev/null"] }

    @discardableResult
    func run(_ args: String...) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmux[0])
        p.arguments = Array(tmux.dropFirst()) + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    deinit {
        run("kill-server")
        // where tmux puts a -L socket; asking the server for it fails once a test has ended the server
        let dir = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/tmp"
        try? FileManager.default.removeItem(atPath: "\(dir)/tmux-\(getuid())/\(socket)")
    }
}

@MainActor private func until(_ seconds: Double = 5, _ done: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !done() {
        if Date() > end { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

@MainActor @Test func aPaneStreamShowsThePaneThenItsOutputAndSendsTypedBytes() async throws {
    let server = ScratchServer()
    // the pane echoes nothing and prints the bytes it reads in hex, so what was typed shows exactly
    server.run("new-session", "-d", "-s", "w", "-x", "70", "-y", "12", "printf 'before\\n'; stty raw -echo; od -An -tx1 -v")
    let pane = server.run("list-panes", "-t", "w", "-F", "#{pane_id}")
    var seen: [UInt8] = []
    var size: (cols: Int, rows: Int)?
    let stream = PaneStream(ref: TmuxRef(session: "w", window: "0", pane: pane), tmux: server.tmux)
    stream.onOutput = { seen += $0 }
    stream.onSize = { size = ($0, $1) }
    stream.start()
    #expect(await until { String(decoding: seen, as: UTF8.self).contains("before") })  // the screen as it was
    #expect(size?.cols == 70 && size?.rows == 12)
    #expect(await until { server.run("display-message", "-p", "-t", pane, "#{pane_current_command}") == "od" })
    stream.send(Array("한a".utf8) + [0x1b, 0x0d] + Array(repeating: 0x41, count: 10))
    #expect(await until { String(decoding: seen, as: UTF8.self).contains("ed  95  9c  61  1b  0d") })  // live output
    stream.stop()
    #expect(await until { server.run("list-clients").isEmpty })
}

@MainActor @Test func aPasteIsBracketedOnlyWhenThePaneAskedForIt() async throws {
    let server = ScratchServer()
    server.run("new-session", "-d", "-s", "w", "-x", "70", "-y", "12", "stty raw -echo; printf '\\033[?2004h'; od -An -tx1 -v")
    let pane = server.run("list-panes", "-t", "w", "-F", "#{pane_id}")
    let stream = PaneStream(ref: TmuxRef(session: "w", window: "0", pane: pane), tmux: server.tmux)
    stream.start()
    #expect(await until { server.run("display-message", "-p", "-t", pane, "#{pane_current_command}") == "od" })
    stream.paste("a\"$\\b 한" + String(repeating: "x", count: 6))
    #expect(await until { server.run("capture-pane", "-p", "-t", pane).contains("1b  5b  32  30  30  7e  61  22  24  5c  62  20  ed  95  9c") })
    #expect(server.run("list-buffers").isEmpty)  // the buffer it used is gone
    stream.stop()
}

@MainActor @Test func watchingAPaneLeavesTheWindowSizeToTheOtherClients() async throws {
    let server = ScratchServer()
    server.run("new-session", "-d", "-s", "w", "-x", "80", "-y", "24")
    server.run("set-option", "-g", "window-size", "latest")
    // another client sized 120x40 stands for the user's terminal
    let other = Process()
    other.executableURL = URL(fileURLWithPath: server.tmux[0])
    other.arguments = Array(server.tmux.dropFirst()) + ["-C", "attach", "-t", "w"]
    let input = Pipe()
    other.standardInput = input
    other.standardOutput = Pipe()
    try other.run()
    input.fileHandleForWriting.write(Data("refresh-client -C 120x40\n".utf8))
    let size = { server.run("display", "-p", "-t", "w", "#{window_width}x#{window_height}") }
    #expect(await until { size() == "120x40" })
    let pane = server.run("list-panes", "-t", "w", "-F", "#{pane_id}")
    let stream = PaneStream(ref: TmuxRef(session: "w", window: "0", pane: pane), tmux: server.tmux)
    var cols = 0
    stream.onSize = { c, _ in cols = c }
    stream.start()
    #expect(await until { cols == 120 })  // it follows the pane
    #expect(server.run("list-clients", "-F", "#{client_flags}").contains("ignore-size"))
    #expect(size() == "120x40")
    stream.stop()
    #expect(size() == "120x40")
    try? input.fileHandleForWriting.close()
    other.waitUntilExit()
}

@MainActor @Test func aPaneThatGoesAwayIsTold() async throws {
    let server = ScratchServer()
    server.run("new-session", "-d", "-s", "w", "-x", "80", "-y", "24")
    server.run("new-window", "-t", "w")
    let pane = server.run("list-panes", "-t", "w:1", "-F", "#{pane_id}")
    var gone: String?
    let stream = PaneStream(ref: TmuxRef(session: "w", window: "1", pane: pane), tmux: server.tmux)
    stream.onGone = { gone = $0 }
    stream.start()
    try await Task.sleep(for: .milliseconds(300))
    server.run("kill-pane", "-t", pane)
    #expect(await until { gone != nil })
    #expect(await until { server.run("list-clients").isEmpty })
    let missing = PaneStream(ref: TmuxRef(session: "nope", window: "0", pane: "%99"), tmux: server.tmux)
    var told: String?
    missing.onGone = { told = $0 }
    missing.start()
    #expect(await until { told != nil })
}

@MainActor @Test func typingRightAfterTheServerDiesEndsTheStreamAndNotTheApp() async throws {
    let server = ScratchServer()
    server.run("new-session", "-d", "-s", "w", "-x", "80", "-y", "10", "cat > /dev/null")
    let pane = server.run("list-panes", "-t", "w", "-F", "#{pane_id}")
    var gone: String?
    let stream = PaneStream(ref: TmuxRef(session: "w", window: "0", pane: pane), tmux: server.tmux)
    stream.onGone = { gone = $0 }
    stream.start()
    try await Task.sleep(for: .milliseconds(300))
    server.run("kill-server")
    // before the stream hears that the client exited: each write goes to a pipe nobody reads any more
    for _ in 0..<50 { stream.send(Array("x".utf8)) }
    #expect(await until { gone != nil })
}

@MainActor @Test func aScreenWithControlModeLinesInItShowsAsItIs() async throws {
    let server = ScratchServer()
    server.run("new-session", "-d", "-s", "w", "-x", "80", "-y", "10",
               "printf 'top\\n%%end 1 2 0\\n%%output %%0 INJECTED\\nbottom\\n'; cat > /dev/null")
    let pane = server.run("list-panes", "-t", "w", "-F", "#{pane_id}")
    #expect(await until { server.run("capture-pane", "-p", "-t", pane).contains("bottom") })
    var shown: [UInt8] = []
    var outputs = 0
    let stream = PaneStream(ref: TmuxRef(session: "w", window: "0", pane: pane), tmux: server.tmux)
    stream.onOutput = { shown += $0; outputs += 1 }
    stream.start()
    #expect(await until { String(decoding: shown, as: UTF8.self).contains("bottom") })
    try await Task.sleep(for: .milliseconds(200))
    let lines = String(decoding: shown, as: UTF8.self).components(separatedBy: "\r\n").prefix(4)
    #expect(Array(lines) == ["\u{1b}[H\u{1b}[2Jtop", "%end 1 2 0", "%output %0 INJECTED", "bottom"])
    #expect(outputs == 1)  // the first screen only, nothing taken for live output
    stream.stop()
}

@MainActor @Test func liveOutputArrivesInTheOrderThePaneWroteIt() async throws {
    let server = ScratchServer()
    server.run("new-session", "-d", "-s", "w", "-x", "80", "-y", "10", "stty -echo; read x; seq 1 20000; cat > /dev/null")
    let pane = server.run("list-panes", "-t", "w", "-F", "#{pane_id}")
    var screens = 0
    var live: [UInt8] = []
    let stream = PaneStream(ref: TmuxRef(session: "w", window: "0", pane: pane), tmux: server.tmux)
    stream.onOutput = { if screens == 0 { screens = 1 } else { live += $0 } }
    stream.start()
    #expect(await until { screens == 1 })
    stream.send([0x0d])
    #expect(await until(10) { String(decoding: live.suffix(16), as: UTF8.self).contains("20000") })
    let numbers = String(decoding: live, as: UTF8.self).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    #expect(numbers == Array(1...20000))
    stream.stop()
}

@MainActor @Test func aBigPasteDoesNotHoldTheMainThreadWhileTmuxIsNotReading() async throws {
    let server = ScratchServer()
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("ct-paste-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    server.run("new-session", "-d", "-s", "w", "-x", "80", "-y", "10", "stty raw -echo; head -c 1048576 > '\(file.path)'")
    let pane = server.run("list-panes", "-t", "w", "-F", "#{pane_id}")
    var screens = 0
    let stream = PaneStream(ref: TmuxRef(session: "w", window: "0", pane: pane), tmux: server.tmux)
    stream.onOutput = { _ in screens += 1 }
    stream.start()
    #expect(await until { screens > 0 })
    // a control client hands its stdin to the server, which reads it: stopped, the scratch server reads
    // nothing and the pipe fills up
    let tmuxd = try #require(pid_t(server.run("display-message", "-p", "#{pid}")))
    kill(tmuxd, SIGSTOP)
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { kill(tmuxd, SIGCONT) }
    let started = Date()
    stream.paste(String(repeating: "x", count: 1 << 20))
    #expect(Date().timeIntervalSince(started) < 0.5)
    #expect(await until(15) { ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int) == 1 << 20 })
    stream.stop()
}

// MARK: - SwiftTerm's side

import SwiftTerm

private final class Quiet: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

@Test func aCharacterCutBetweenTwoOutputLinesDrawsAsOneInTheTerminal() {
    var p = ControlModeParser(pane: "%1")
    let han = Array("한".utf8)
    var input = bytes("%output %1 x")
    input += han[0..<2]
    input += bytes("\n")
    let quiet = Quiet()
    let terminal = Terminal(delegate: quiet)
    for case .output(let b) in p.feed(input) { terminal.feed(byteArray: b) }
    var rest = bytes("%output %1 ")
    rest += han[2...]
    rest += bytes("y\n")
    for case .output(let b) in p.feed(rest) { terminal.feed(byteArray: b) }
    #expect(terminal.getLine(row: 0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) == "x한y")
}

@MainActor @Test func theTerminalViewTakesThePaneSizeAndSendsWhatIsTyped() async throws {
    let server = ScratchServer()
    server.run("new-session", "-d", "-s", "w", "-x", "70", "-y", "12", "stty raw -echo; od -An -tx1 -v")
    let pane = server.run("list-panes", "-t", "w", "-F", "#{pane_id}")
    let link = PaneLink()
    let view = PaneTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
    view.attach(PaneStream(ref: TmuxRef(session: "w", window: "0", pane: pane), tmux: server.tmux), link: link)
    #expect(await until { link.size.width > 0 })
    let cell = link.size.height / 12
    #expect(cell > 10 && cell < 20)  // 12 rows of a 12-point font
    #expect(await until { server.run("display-message", "-p", "-t", pane, "#{pane_current_command}") == "od" })
    // what SwiftTerm hands its delegate for a key press goes to the pane as it is
    view.send(source: view, data: (Array("가".utf8) + [0x1b] + Array(repeating: 0x42, count: 12))[...])
    #expect(await until { server.run("capture-pane", "-p", "-t", pane).contains("ea  b0  80  1b  42") })
    view.detach()
    #expect(await until { server.run("list-clients").isEmpty })
}
