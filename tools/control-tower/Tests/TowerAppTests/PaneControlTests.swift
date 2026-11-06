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
