import Foundation

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
            if text.hasPrefix("%end ") || text.hasPrefix("%error ") {
                defer { reply = nil }
                return .reply(reply ?? [], ok: text.hasPrefix("%end "))
            }
            reply?.append(text)
            return nil
        }
        let prefix = Array("%output \(pane) ".utf8)
        if line.starts(with: prefix) { return .output(unescape(line[prefix.count...])) }
        let text = String(decoding: line.prefix(32), as: UTF8.self)
        if text.hasPrefix("%begin ") { reply = [] }
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
