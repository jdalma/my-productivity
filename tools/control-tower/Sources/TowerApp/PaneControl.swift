import Foundation
import TowerCore

/// What a tmux control mode client (`tmux -C`, tmux(1) "CONTROL MODE") reads that the board's pane terminal acts on.
enum ControlEvent: Equatable {
    /// Bytes the watched pane wrote, unescaped. Output of other panes is dropped.
    case output([UInt8])
    /// The lines between `%begin` and `%end` (ok) or `%error`, answering one command, in the order sent.
    case reply([String], ok: Bool)
    /// A window's layout changed: the pane may have a new size.
    case layoutChanged
    /// A window of the attached session closed: the pane may be gone.
    case windowClosed
    /// The client is detached or the server is gone.
    case exit
}

/// Splits a control mode client's stdout into events for one pane. Lines may arrive cut anywhere, so bytes are
/// kept until their newline; a reply's lines are kept until its `%end`.
struct ControlModeParser {
    let pane: String
    private var line: [UInt8] = []
    private var reply: [String]?
    /// The time and command number of the open `%begin`. tmux does not escape a reply's lines, so only the
    /// `%end`/`%error` with the same two closes it (tmux(1), CONTROL MODE: guard lines).
    private var guardID: ArraySlice<Substring> = []

    init(pane: String) { self.pane = pane }

    mutating func feed(_ data: some Sequence<UInt8>) -> [ControlEvent] {
        var events: [ControlEvent] = []
        for b in data {
            if b == 10 {
                if let e = take(line) { events.append(e) }
                line.removeAll(keepingCapacity: true)
            } else {
                line.append(b)
            }
        }
        return events
    }

    private mutating func take(_ line: [UInt8]) -> ControlEvent? {
        if reply != nil {
            let text = String(decoding: line, as: UTF8.self)
            let words = text.split(separator: " ")
            if words.first == "%end" || words.first == "%error", words.dropFirst().prefix(2) == guardID {
                defer { reply = nil }
                return .reply(reply ?? [], ok: words.first == "%end")
            }
            reply?.append(text)
            return nil
        }
        let prefix = Array("%output \(pane) ".utf8)
        if line.starts(with: prefix) { return .output(unescape(line[prefix.count...])) }
        let text = String(decoding: line.prefix(32), as: UTF8.self)
        if text.hasPrefix("%begin ") {
            reply = []
            guardID = String(decoding: line, as: UTF8.self).split(separator: " ").dropFirst().prefix(2)
        }
        else if text.hasPrefix("%layout-change ") { return .layoutChanged }
        else if text.hasPrefix("%window-close ") || text.hasPrefix("%unlinked-window-close ") { return .windowClosed }
        else if text == "%exit" || text.hasPrefix("%exit ") { return .exit }
        return nil
    }
}

/// `%output` data: a byte under 0x20 or a backslash comes as `\` and three octal digits, everything else as itself.
private func unescape(_ s: ArraySlice<UInt8>) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(s.count)
    var i = s.startIndex
    while i < s.endIndex {
        let b = s[i]
        if b == 92, i + 3 < s.endIndex, let v = octal(s[(i + 1)...(i + 3)]) {
            out.append(v)
            i += 4
        } else {
            out.append(b)
            i += 1
        }
    }
    return out
}

private func octal(_ digits: ArraySlice<UInt8>) -> UInt8? {
    var v = 0
    for d in digits {
        guard (48...55).contains(d) else { return nil }
        v = v * 8 + Int(d - 48)
    }
    return v <= 255 ? UInt8(v) : nil
}

/// One tmux control mode client for the board's pane terminal: attached to the session that holds a pane, it shows
/// that pane and types into it.
///
/// What it does to the user's tmux (T46 widens T25's "the app only focuses a pane"):
/// - it attaches with `ignore-size`, so the windows keep the size the user's terminals give them;
/// - it sends a pane only the bytes the user typed or pasted into the terminal view, nothing of its own;
/// - a paste goes through a named buffer that `paste-buffer -d` deletes.
/// Closing its stdin detaches it; the client also exits when the app does, its stdin closing with it.
///
/// The main actor never waits on tmux: commands are written on a queue of their own, so a big paste into a pipe
/// tmux reads slowly does not hold the UI, and the client's output reaches `read` through one stream, in order.
@MainActor
final class PaneStream {
    let ref: TmuxRef
    var onOutput: ([UInt8]) -> Void = { _ in }
    var onSize: (Int, Int) -> Void = { _, _ in }
    var onGone: (String) -> Void = { _ in }

    private let tmux: [String]
    private var process: Process?
    private var input: FileHandle?
    /// Writes to `input`, one at a time and in the order asked; it also closes it, after what was asked before.
    private let writer = DispatchQueue(label: "control-tower.pane-stream.write")
    /// Ends the stream of the client's output; the reading loop then ends the PaneStream.
    private var output: AsyncStream<Data>.Continuation?
    private var parser: ControlModeParser
    /// The commands sent and not yet answered, oldest first: tmux answers in order.
    private var asked: [Ask] = []
    /// Output before the first screen arrives is in that screen already.
    private var showing = false
    private var ended = false

    private enum Ask { case attach, size, screen, other }

    init(ref: TmuxRef, tmux: [String] = [towerTmuxBin]) {
        self.ref = ref
        self.tmux = tmux
        parser = ControlModeParser(pane: ref.pane)
    }

    func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmux[0])
        p.arguments = Array(tmux.dropFirst()) + ["-C", "attach-session", "-t", ref.session, "-f", "ignore-size"]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = Pipe()
        let (chunks, output) = AsyncStream.makeStream(of: Data.self)
        stdout.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { output.finish() } else { output.yield(data) }
        }
        p.terminationHandler = { _ in output.finish() }
        do { try p.run() } catch { return end("tmux를 실행하지 못함") }
        self.output = output
        Task { [weak self] in
            for await data in chunks { self?.read(data) }
            self?.end("tmux 연결이 끊김")
        }
        process = p
        input = stdin.fileHandleForWriting
        // a write after the client exited fails with EPIPE instead of killing the app with SIGPIPE
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        asked = [.attach]  // attaching answers with an empty %begin/%end block
        ask(.size, "display-message -p -t \(ref.pane) '#{pane_width} #{pane_height} #{cursor_x} #{cursor_y}'")
        ask(.screen, "capture-pane -p -e -t \(ref.pane)")
    }

    /// Bytes the user typed in the terminal view, as they are.
    func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        ask(.other, "send-keys -H -t \(ref.pane) " + bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
    }

    /// Text the user pasted: tmux brackets it when the pane's program asked for bracketed paste.
    func paste(_ text: String) {
        let buffer = "control-tower-paste"
        ask(.other, "set-buffer -b \(buffer) -- \(tmuxQuoted(text))")
        ask(.other, "paste-buffer -p -d -b \(buffer) -t \(ref.pane)")
    }

    func stop() {
        ended = true
        if let input { writer.async { try? input.close() } }
        input = nil
        process?.standardOutput.flatMap { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        output?.finish()
    }

    private func ask(_ kind: Ask, _ command: String) {
        guard let input, !ended else { return }
        asked.append(kind)
        let line = Data((command + "\n").utf8), output = output
        writer.async {
            do { try input.write(contentsOf: line) } catch { output?.finish() }
        }
    }

    private func read(_ data: Data) {
        guard !ended else { return }
        for event in parser.feed(data) {
            switch event {
            case .output(let bytes): if showing { onOutput(bytes) }
            case .reply(let lines, let ok): answer(lines, ok: ok)
            case .layoutChanged, .windowClosed:
                ask(.size, "display-message -p -t \(ref.pane) '#{pane_width} #{pane_height} #{cursor_x} #{cursor_y}'")
            case .exit: end("tmux 연결이 끊김")
            }
        }
    }

    private func answer(_ lines: [String], ok: Bool) {
        guard !asked.isEmpty else { return }
        let kind = asked.removeFirst()
        guard ok else {
            if kind != .other { end("pane이 없음 (\(ref.pane))") }
            return
        }
        switch kind {
        case .size:
            let n = (lines.first ?? "").split(separator: " ").compactMap { Int($0) }
            guard n.count == 4 else { return end("pane이 없음 (\(ref.pane))") }
            onSize(n[0], n[1])
            cursor = (n[2], n[3])
        case .screen:
            // the screen as it is, then the cursor where tmux has it
            var bytes = Array("\u{1b}[H\u{1b}[2J".utf8)
            bytes += Array(lines.joined(separator: "\r\n").utf8)
            bytes += Array("\u{1b}[\(cursor.y + 1);\(cursor.x + 1)H".utf8)
            onOutput(bytes)
            showing = true
        case .attach, .other: break
        }
    }

    private var cursor = (x: 0, y: 0)

    private func end(_ why: String) {
        guard !ended else { return }
        stop()
        onGone(why)
    }
}

/// `text` as one tmux double-quoted argument: `\`, `"`, `$` and control bytes escaped, the rest as is.
func tmuxQuoted(_ text: String) -> String {
    var out = "\""
    for u in text.unicodeScalars {
        switch u {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "$": out += "\\$"
        case "\n": out += "\\n"
        case _ where u.value < 0x20 || u.value == 0x7f: out += String(format: "\\%03o", u.value)
        default: out.unicodeScalars.append(u)
        }
    }
    return out + "\""
}
