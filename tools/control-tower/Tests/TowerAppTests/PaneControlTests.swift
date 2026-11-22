import AppKit
import Testing
@testable import TowerApp
import SwiftTerm
import TowerCore

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

// MARK: - SwiftTerm's side

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

// MARK: - the terminal's scroll

@Test func theFirstViewShowsTheCursorRowAsLowAsItFits() {
    // 40 rows of 10 points in a 300-point view: 100 points of overflow
    #expect(scrollToCursorRow(row: 0, rows: 40, document: 400, visible: 300) == 0)
    #expect(scrollToCursorRow(row: 29, rows: 40, document: 400, visible: 300) == 0)
    #expect(scrollToCursorRow(row: 34, rows: 40, document: 400, visible: 300) == 50)
    #expect(scrollToCursorRow(row: 39, rows: 40, document: 400, visible: 300) == 100)
    #expect(scrollToCursorRow(row: 60, rows: 40, document: 400, visible: 300) == 100)
    #expect(scrollToCursorRow(row: 5, rows: 10, document: 100, visible: 300) == 0)  // fits: no scroll
    #expect(scrollToCursorRow(row: 5, rows: 0, document: 400, visible: 300) == 0)
}

@Test func aScrollAlongAnOverflowingAxisMovesThePaneElseTheScrollback() {
    let visible = CGSize(width: 400, height: 300)
    let wide = CGSize(width: 900, height: 200), tall = CGSize(width: 300, height: 700), small = CGSize(width: 300, height: 200)
    #expect(wheelScrollsThePane(delta: CGVector(dx: 5, dy: 1), document: wide, visible: visible))
    #expect(!wheelScrollsThePane(delta: CGVector(dx: 1, dy: 5), document: wide, visible: visible))  // its scrollback
    #expect(wheelScrollsThePane(delta: CGVector(dx: 0, dy: -5), document: tall, visible: visible))
    #expect(!wheelScrollsThePane(delta: CGVector(dx: 5, dy: 0), document: tall, visible: visible))
    #expect(!wheelScrollsThePane(delta: CGVector(dx: 0, dy: 5), document: small, visible: visible))
}

// MARK: - a control mode client against a throwaway tmux server (`tmux -L`), never the user's
// Serialized: each test waits on its own tmux server with short timeouts; run side by side, a dozen servers
// and their clients slowed every test past them (R52c L5).
@MainActor @Suite(.serialized)
struct PaneTmuxTests {
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

    @MainActor private func until(_ seconds: Double = 15, _ done: () -> Bool) async -> Bool {
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
        server.run("new-session", "-d", "-s", "w", "-x", "70", "-y", "12", "printf 'before\\n'; stty raw -echo; exec od -An -tx1 -v")
        let pane = server.run("list-panes", "-t", "w", "-F", "#{pane_id}")
        var seen: [UInt8] = []
        var size: (cols: Int, rows: Int)?
        let stream = PaneStream(ref: TmuxRef(session: "w", window: "0", pane: pane), tmux: server.tmux)
        stream.onOutput = { seen += $0 }
        stream.onSize = { size = ($0, $1); _ = $2 }
        stream.start()
        #expect(await until { String(decoding: seen, as: UTF8.self).contains("before") })  // the screen as it was
        #expect(size?.cols == 70 && size?.rows == 12)
        #expect(await until { server.run("display-message", "-p", "-t", pane, "#{pane_current_command}") == "od" })
        stream.send(Array("한a".utf8) + [0x1b, 0x0d] + Array(repeating: 0x41, count: 10))
        #expect(await until { String(decoding: seen, as: UTF8.self).contains("ed  95  9c  61  1b  0d") })  // live output
        stream.stop()
        #expect(await until { server.run("list-clients").isEmpty })
    }

    /// T106 (E2E F1): a pane in a window the session is not showing streams like any other, and watching it leaves
    /// the session's active window as it was.
    @MainActor @Test func aPaneInAnInactiveWindowShowsItsScreenAndOutput() async throws {
        let server = ScratchServer()
        server.run("new-session", "-d", "-s", "w", "-x", "80", "-y", "12", "-n", "front", "exec sleep 600")
        server.run("new-window", "-d", "-t", "w:", "-n", "back", "printf 'from the back window\\n'; exec cat")
        let pane = server.run("list-panes", "-t", "w:back", "-F", "#{pane_id}")
        let windows = { server.run("list-windows", "-t", "w", "-F", "#{window_name} #{window_active}") }
        let before = windows()
        #expect(before == "front 1\nback 0")
        var seen: [UInt8] = []
        let stream = PaneStream(ref: TmuxRef(session: "w", window: "1", pane: pane), tmux: server.tmux)
        stream.onOutput = { seen += $0 }
        stream.start()
        #expect(await until { String(decoding: seen, as: UTF8.self).contains("from the back window") })  // the screen
        stream.send(Array("typed-in-back\r".utf8))
        #expect(await until { String(decoding: seen, as: UTF8.self).contains("typed-in-back") })  // live output
        #expect(windows() == before, "the session still shows the window it showed")
        stream.stop()
        #expect(await until { server.run("list-clients").isEmpty })
    }

    @MainActor @Test func aPasteIsBracketedOnlyWhenThePaneAskedForIt() async throws {
        let server = ScratchServer()
        server.run("new-session", "-d", "-s", "w", "-x", "70", "-y", "12", "stty raw -echo; printf '\\033[?2004h'; exec od -An -tx1 -v")
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
        stream.onSize = { c, _, _ in cols = c }
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
        // stopped for 10 s: a paste that waited for the server would take that long (T130: 2 s and a 0.5 s bound
        // were too close for a loaded run)
        Thread { Thread.sleep(forTimeInterval: 10); kill(tmuxd, SIGCONT) }.start()
        let started = Date()
        stream.paste(String(repeating: "x", count: 1 << 20))
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(await until(30) { ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int) == 1 << 20 })
        stream.stop()
    }

    @MainActor @Test func stoppingRightAfterSendingStillDeliversWhatWasSent() async throws {
        let server = ScratchServer()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ct-stop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        server.run("new-session", "-d", "-s", "w", "-x", "80", "-y", "10", "stty raw -echo; exec cat > '\(file.path)'")
        let pane = server.run("list-panes", "-t", "w", "-F", "#{pane_id}")
        var screens = 0
        let stream = PaneStream(ref: TmuxRef(session: "w", window: "0", pane: pane), tmux: server.tmux)
        stream.onOutput = { _ in screens += 1 }
        stream.start()
        #expect(await until { screens > 0 })
        #expect(await until { server.run("display-message", "-p", "-t", pane, "#{pane_current_command}") == "cat" })
        for _ in 0..<200 { stream.send(Array("y".utf8)) }
        // bigger than a pipe holds, so the paste is still being written when stop() comes
        stream.paste(String(repeating: "x", count: 200 * 1024))
        stream.stop()
        let want = String(repeating: "y", count: 200) + String(repeating: "x", count: 200 * 1024)
        #expect(await until(10) { (try? String(contentsOf: file, encoding: .utf8)) == want })
        #expect(await until { server.run("list-clients").isEmpty })
    }


    /// Option+Enter is the newline in Claude Code's input, in Ghostty as here: the pane gets ESC CR. Enter and
    /// Shift+Enter both send CR. The key events go straight to the view object; nothing is posted to the system.
    @MainActor @Test func optionEnterReachesThePaneAsEscapeReturn() async throws {
        let server = ScratchServer()
        server.run("new-session", "-d", "-s", "w", "-x", "70", "-y", "12", "stty raw -echo; exec od -An -tx1 -v")
        let pane = server.run("list-panes", "-t", "w", "-F", "#{pane_id}")
        let view = PaneTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        view.attach(PaneStream(ref: TmuxRef(session: "w", window: "0", pane: pane), tmux: server.tmux), link: PaneLink())
        defer { view.detach() }
        #expect(await until { server.run("display-message", "-p", "-t", pane, "#{pane_current_command}") == "od" })
        for mods: NSEvent.ModifierFlags in [[], .option, .shift] {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                         windowNumber: 0, context: nil, characters: "\r",
                                         charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            view.keyDown(with: event)
        }
        view.send(source: view, data: Array(repeating: 0x42, count: 12)[...])  // od prints a line per 16 bytes
        #expect(await until { server.run("capture-pane", "-p", "-t", pane).contains("0d  1b  0d  0d  42") })
    }

    @MainActor @Test func theTerminalViewTakesThePaneSizeAndSendsWhatIsTyped() async throws {
        let server = ScratchServer()
        server.run("new-session", "-d", "-s", "w", "-x", "70", "-y", "12", "stty raw -echo; exec od -An -tx1 -v")
        let pane = server.run("list-panes", "-t", "w", "-F", "#{pane_id}")
        let link = PaneLink()
        let view = PaneTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        view.attach(PaneStream(ref: TmuxRef(session: "w", window: "0", pane: pane), tmux: server.tmux), link: link)
        #expect(await until { view.frame.width > 0 })
        let cell = view.frame.height / 12
        #expect(cell > 10 && cell < 20)  // 12 rows of a 12-point font
        #expect(await until { server.run("display-message", "-p", "-t", pane, "#{pane_current_command}") == "od" })
        // what SwiftTerm hands its delegate for a key press goes to the pane as it is
        view.send(source: view, data: (Array("가".utf8) + [0x1b] + Array(repeating: 0x42, count: 12))[...])
        #expect(await until { server.run("capture-pane", "-p", "-t", pane).contains("ea  b0  80  1b  42") })
        view.detach()
        #expect(await until { server.run("list-clients").isEmpty })
    }

    /// A terminal on `pane` of `server` at `size` points, in `window` when given; nil when it never took the pane's size.
    @MainActor private func terminal(_ server: ScratchServer, _ pane: String, size: CGFloat,
                                     in window: NSWindow? = nil) async -> PaneTerminalView? {
        let view = PaneTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: size, weight: .regular))
        window?.contentView?.addSubview(view)
        view.attach(PaneStream(ref: TmuxRef(session: "w", window: "0", pane: pane), tmux: server.tmux), link: PaneLink())
        let sized = await until { view.frame.width > 0 }
        guard sized else { view.detach(); return nil }
        return view
    }

    /// T83: every pane at the board's text size, its own columns and rows kept; the board's ⌘+/- moves it.
    @MainActor @Test func everyPaneTakesTheBoardsTextSizeAndLeavesDragsToSelection() async throws {
        let server = ScratchServer()
        server.run("new-session", "-d", "-s", "w", "-x", "120", "-y", "12", "cat")
        server.run("split-window", "-h", "-t", "w", "-l", "40", "cat")
        let panes = server.run("list-panes", "-t", "w", "-F", "#{pane_id}").split(separator: "\n").map(String.init)
        try #require(panes.count == 2)
        let window = Density(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                             backing: .buffered, defer: true)
        let wide = try #require(await terminal(server, panes[0], size: 13, in: window))
        let narrow = try #require(await terminal(server, panes[1], size: 13, in: window))
        defer { wide.detach(); narrow.detach() }
        #expect(!wide.allowMouseReporting)
        #expect(wide.font.pointSize == 13 && narrow.font.pointSize == 13)
        let cols = { (p: String) in Int(server.run("display-message", "-p", "-t", p, "#{pane_width}")) ?? 0 }
        #expect(abs(wide.frame.width / CGFloat(cols(panes[0])) - narrow.frame.width / CGFloat(cols(panes[1]))) < 0.01)
        #expect(wide.frame == wide.getOptimalFrameSize())
        let before = wide.frame.size
        wide.setFontSize(19.5)  // ⌘+ twice
        #expect(wide.font.pointSize == 19.5)
        #expect(wide.frame.width > before.width && wide.frame.height > before.height)
        #expect(wide.frame == wide.getOptimalFrameSize())
        #expect(cols(panes[0]) > 0 && server.run("display-message", "-p", "-t", panes[0], "#{pane_height}") == "12")
    }

    /// T106: a pane larger than the space first shows its cursor's row, as low as it fits: the top while the screen is
    /// short (an inactive window's pane, a fresh shell), the last rows when the cursor is there (a full program).
    @MainActor @Test func aPaneLargerThanTheSpaceScrollsToItsCursorRowAndASmallerOneSitsTopLeft() async throws {
        let server = ScratchServer()
        server.run("new-session", "-d", "-s", "w", "-x", "120", "-y", "40", "printf 'top line\\n'; exec cat")
        server.run("new-window", "-d", "-t", "w:", "printf '%s\\n' $(seq 1 60); exec cat")
        let panes = server.run("list-panes", "-s", "-t", "w", "-F", "#{pane_id}").split(separator: "\n").map(String.init)
        try #require(panes.count == 2)
        let window = Density(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                             backing: .buffered, defer: true)
        func shown(_ pane: String) async throws -> (PaneTerminalView, PaneScrollView) {
            let view = PaneTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
            let scroll = PaneScrollView(terminal: view)
            scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
            window.contentView?.addSubview(scroll)
            let stream = PaneStream(ref: TmuxRef(session: "w", window: "0", pane: pane), tmux: server.tmux)
            view.attach(stream, link: PaneLink())
            // lay out the moment the pane's size is known, before its screen comes: the first scroll is the one seen
            let size = stream.onSize
            stream.onSize = { size($0, $1, $2); scroll.layoutSubtreeIfNeeded() }
            #expect(await until { view.frame.width > 0 })
            return (view, scroll)
        }
        let (top, topScroll) = try await shown(panes[0])
        defer { top.detach() }
        let visible = topScroll.contentView.bounds
        #expect(top.frame.width > visible.width && top.frame.height > visible.height)
        #expect(top.cursorRow == 1)
        #expect(visible.origin == .zero, "the cursor on row 1: the top, where the text is")

        let (full, fullScroll) = try await shown(panes[1])
        defer { full.detach() }
        #expect(full.cursorRow == 39)
        #expect(abs(fullScroll.contentView.bounds.maxY - full.frame.height) < 1, "the cursor on the last row: the last rows")

        server.run("resize-window", "-t", "w:0", "-x", "20", "-y", "5")
        #expect(await until { top.frame.width > 0 && top.frame.width < 400 && top.frame.height < 300 })
        topScroll.layoutSubtreeIfNeeded()
        #expect(top.frame.origin == .zero)
        #expect(topScroll.contentView.bounds.origin == .zero)
        #expect(topScroll.contentView.isFlipped)  // so origin zero is the top left

        // T108 F4: below and right of the small pane, the space is the terminal's background, not a band
        let rep = try #require(topScroll.bitmapImageRepForCachingDisplay(in: topScroll.bounds))
        topScroll.cacheDisplay(in: topScroll.bounds, to: rep)
        let terminalBackground = try #require(top.nativeBackgroundColor.usingColorSpace(.sRGB))
        for (x, y) in [(rep.pixelsWide / 2, rep.pixelsHigh * 3 / 4), (rep.pixelsWide * 3 / 4, rep.pixelsHigh / 2)] {
            let c = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            #expect(c.alphaComponent > 0.99 && abs(c.redComponent - terminalBackground.redComponent) < 0.02
                    && abs(c.greenComponent - terminalBackground.greenComponent) < 0.02
                    && abs(c.blueComponent - terminalBackground.blueComponent) < 0.02, "(\(x), \(y)): \(c) vs \(terminalBackground)")
        }
    }

    /// A window never shown that is key when the test says.
    private final class Key: NSWindow {
        var key = true
        override var isKeyWindow: Bool { key }
    }

    @MainActor @Test func theTerminalSaysWhileItHasTheKeyboard() async throws {
        let server = ScratchServer()
        server.run("new-session", "-d", "-s", "w", "-x", "80", "-y", "12", "cat")
        let pane = server.run("list-panes", "-t", "w", "-F", "#{pane_id}")
        let link = PaneLink()
        let window = Key(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                         backing: .buffered, defer: true)
        let view = PaneTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.attach(PaneStream(ref: TmuxRef(session: "w", window: "0", pane: pane), tmux: server.tmux), link: link)
        defer { view.detach() }
        window.contentView?.addSubview(view)
        #expect(!link.typing)
        window.makeFirstResponder(view)
        #expect(link.typing)
        // another app comes in front: the window stays the terminal's, the keys go elsewhere
        window.key = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!link.typing)
        window.key = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(link.typing)
        window.makeFirstResponder(nil)
        #expect(!link.typing)
    }

    /// A window never shown, on a screen of whatever pixel density the test says.
    private final class Density: NSWindow {
        var scale: CGFloat = 2
        override var backingScaleFactor: CGFloat { scale }
    }

    /// T78, T83: the size is the board's on a 1x or a 2x screen; only SwiftTerm's pixel snapping of a cell differs.
    @MainActor @Test func theTextSizeIsTheSameOnEveryScreenDensity() async throws {
        let server = ScratchServer()
        server.run("new-session", "-d", "-s", "w", "-x", "120", "-y", "12", "cat")
        let pane = server.run("list-panes", "-t", "w", "-F", "#{pane_id}")
        let window = Density(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                             backing: .buffered, defer: true)
        let view = try #require(await terminal(server, pane, size: 13, in: window))
        defer { view.detach() }
        #expect(view.font.pointSize == 13)
        // AppKit tells the view when its window moves to a 1x screen
        window.scale = 1
        view.viewDidChangeBackingProperties()
        #expect(view.font.pointSize == 13)
        #expect(view.frame == view.getOptimalFrameSize())
    }

    /// What reaches the stdin of a pane program that writes terminal queries once `go` exists, until it quits.
    @MainActor private func stdinAfterQueries(_ watcher: Watcher) async throws -> String {
        let server = ScratchServer()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ct-q-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let go = dir.appendingPathComponent("go").path, got = dir.appendingPathComponent("stdin")
        // DA1, DSR, DA2, OSC 11 background, kitty keyboard query, focus reporting on
        server.run("new-session", "-d", "-s", "w", "-x", "70", "-y", "12", """
            stty raw -echo; while [ ! -e '\(go)' ]; do sleep 0.05; done
            printf '\\033[c\\033[6n\\033[>c\\033]11;?\\007\\033[?u\\033[?1004h'; (sleep 1.5; kill $$) & exec cat > '\(got.path)'
            """)
        let pane = server.run("list-panes", "-t", "w", "-F", "#{pane_id}")
        let ref = TmuxRef(session: "w", window: "0", pane: pane)
        let view = PaneTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        let stream = PaneStream(ref: ref, tmux: server.tmux)
        var screens = 0
        switch watcher {
        case .stream:
            stream.onOutput = { _ in screens += 1 }
            stream.start()
            #expect(await until { screens > 0 })
        case .view:
            let link = PaneLink()
            view.attach(stream, link: link)
            #expect(await until { view.frame.width > 0 })
        }
        FileManager.default.createFile(atPath: go, contents: nil)
        #expect(await until(5) { server.run("list-panes", "-a").isEmpty })  // the program quit
        try await Task.sleep(for: .milliseconds(300))  // anything the view still had queued
        view.detach()
        stream.stop()
        return String(decoding: (try? Data(contentsOf: got)) ?? Data(), as: UTF8.self)
    }

    private enum Watcher { case stream, view }

    @MainActor @Test func theTerminalViewAnswersNoQueryOfThePaneProgram() async throws {
        // tmux is the pane's terminal and answers for itself (OSC 11 only while a client is attached, so the
        // control is a bare control mode client); the view adds nothing of its own
        let bare = try await stdinAfterQueries(.stream)
        #expect(bare.contains("\u{1b}[?1;2;4c"))  // tmux's DA1
        let viewed = try await stdinAfterQueries(.view)
        #expect(viewed == bare)
    }

    @MainActor @Test func whatTheUserTypesAndCommitsThroughTheInputMethodStillReachesThePane() async throws {
        let server = ScratchServer()
        server.run("new-session", "-d", "-s", "w", "-x", "70", "-y", "12", "stty raw -echo; exec od -An -tx1 -v")
        let pane = server.run("list-panes", "-t", "w", "-F", "#{pane_id}")
        let link = PaneLink()
        let view = PaneTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        view.attach(PaneStream(ref: TmuxRef(session: "w", window: "0", pane: pane), tmux: server.tmux), link: link)
        #expect(await until { view.frame.width > 0 })
        #expect(await until { server.run("display-message", "-p", "-t", pane, "#{pane_current_command}") == "od" })
        view.send(data: Array("a".utf8)[...])  // SwiftTerm's own input path, as its key handling uses it
        view.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))  // what an IME commits
        view.send(data: Array(repeating: 0x42, count: 15)[...])
        #expect(await until { server.run("capture-pane", "-p", "-t", pane).contains("61  ed  95  9c  42") })
        view.detach()
    }
}

/// T123 R11 L1: a diagonal trackpad gesture over a pane wider than the space, not taller, goes to one place: where
/// its first moving event went, through its momentum; the next gesture decides again. A mouse wheel decides per event.
@Test func oneTrackpadGestureScrollsOnePlace() {
    let doc = CGSize(width: 1000, height: 200), vis = CGSize(width: 400, height: 300)
    var g = WheelGesture()
    func r(_ p: NSEvent.Phase, _ m: NSEvent.Phase = [], _ dx: CGFloat, _ dy: CGFloat) -> Bool {
        g.route(phase: p, momentum: m, delta: CGVector(dx: dx, dy: dy), document: doc, visible: vis)
    }
    // sideways first: the scroll view, even when the gesture turns mostly vertical
    #expect(r(.began, [], 0, 0) == false)
    #expect(r(.changed, [], 6, 2) == true)
    #expect(r(.changed, [], 1, 8) == true)
    #expect(r(.ended, [], 0, 0) == true)
    #expect(r([], .began, 1, 6) == true)
    #expect(r([], .changed, 0, 4) == true)
    // a new gesture, down first: the scrollback, even when it turns sideways
    #expect(r(.began, [], 0, 0) == false)
    #expect(r(.changed, [], 1, 7) == false)
    #expect(r(.changed, [], 9, 1) == false)
    // a mouse wheel: each event on its own
    #expect(r([], [], 5, 0) == true)
    #expect(r([], [], 0, 5) == false)
}

/// R46 L1: a gesture that starts away from the pane clears the gesture before's decision, so when the pane comes under
/// the pointer mid-gesture its first moving event decides there.
@Test func aGestureStartedAwayFromThePaneDecidesAfreshWhenThePaneComesUnderIt() {
    let doc = CGSize(width: 1000, height: 200), vis = CGSize(width: 400, height: 300)
    var g = WheelGesture()
    // through `take`, the wheel monitor's whole decision (R56 L1)
    func r(_ p: NSEvent.Phase, _ dx: CGFloat, _ dy: CGFloat, over: Bool) -> Bool {
        g.take(WheelEvent(inWindow: true, over: over, phase: p, delta: CGVector(dx: dx, dy: dy)), document: doc, visible: vis)
    }
    // a sideways gesture over the pane: the pane scrolls
    #expect(r(.began, 0, 0, over: true) == false)
    #expect(r(.changed, 6, 1, over: true) == true)
    #expect(r(.ended, 0, 0, over: true) == true)
    // the next gesture starts beside the pane, then the pane comes under the pointer while it goes down
    #expect(r(.began, 0, 0, over: false) == false)
    #expect(r(.changed, 0, 7, over: false) == false)
    #expect(r(.changed, 0, 7, over: true) == false)
    // another window's event, or a pane with no scroll view, is never taken
    #expect(g.take(WheelEvent(inWindow: false, over: true, delta: CGVector(dx: 6, dy: 0)), document: doc, visible: vis) == false)
    #expect(g.take(WheelEvent(inWindow: true, over: true, delta: CGVector(dx: 6, dy: 0)), document: doc, visible: nil) == false)
    #expect(g.take(WheelEvent(inWindow: true, over: true, delta: CGVector(dx: 6, dy: 0)), document: doc, visible: vis) == true)
}
