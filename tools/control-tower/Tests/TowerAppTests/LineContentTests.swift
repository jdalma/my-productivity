import AppKit
import SwiftUI
import Testing
@testable import TowerCore
@testable import TowerApp

private func runs(_ a: AttributedString) -> [(text: String, fg: Color?, bg: Color?)] {
    a.runs.map { (String(a[$0.range].characters), $0.foregroundColor, $0.backgroundColor) }
}

/// sRGB hex of a dynamic color drawn light and dark.
private func hex(_ c: Color?) -> [String] {
    guard let c else { return [] }
    return [NSAppearance.Name.aqua, .darkAqua].map { name in
        var out = ""
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let s = NSColor(c).usingColorSpace(.sRGB)!
            out = String(format: "%02x%02x%02x", Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()), Int((s.blueComponent * 255).rounded()))
        }
        return out
    }
}

@Test func syntaxColorsTheTextAndChangedWordsKeepOnlyColorsThatRead() {
    var line = DiffLine(kind: .added, old: nil, new: 1, text: "let x = \"b\"")
    line.syntax = [SyntaxSpan(range: 0..<3, kind: .keyword), SyntaxSpan(range: 8..<11, kind: .string)]
    line.changes = [0..<3, 9..<10]
    let r = runs(lineContent(line))
    #expect(r.map(\.text).joined() == "let x = \"b\"")
    // GitHub's own syntax colors off a changed word
    #expect(hex(r.first { $0.text == "\"" }?.fg) == ["0a3069", "a5d6ff"])
    // a changed keyword reads under 4.5:1 in that color, so it takes the body color; a string keeps its own
    let kw = r.first { $0.text == "let" }, b = r.first { $0.text == "b" }
    #expect(hex(kw?.bg) == hex(DiffColors.addedWord))
    #expect(hex(kw?.fg) == ["1f2328", "f0f6fc"])
    #expect(hex(b?.fg) == ["0a3069", "a5d6ff"])
    // dark heading falls back to the constant color
    #expect(hex(DiffColors.syntax(.heading)) == ["0550ae", "79c0ff"])
}

@Test func tabsStillExpandAndLongLinesStayWhole() {
    var line = DiffLine(kind: .context, old: 1, new: 1, text: "\tlet\ta")
    line.syntax = [SyntaxSpan(range: 1..<4, kind: .keyword)]
    #expect(String(lineContent(line).characters) == "    let    a")
    let long = String(repeating: "x = 1; ", count: 2000)
    var l2 = DiffLine(kind: .removed, old: 1, new: nil, text: long)
    l2.syntax = [SyntaxSpan(range: 4..<5, kind: .constant)]
    #expect(String(lineContent(l2).characters) == long)
    #expect(String(lineContent(DiffLine(kind: .context, old: 1, new: 1, text: "")).characters) == "")
}

/// Tens of thousands of spans (a minified line) take linear time, not quadratic.
@Test func manySpansStayLinear() {
    var line = DiffLine(kind: .added, old: nil, new: 1, text: String(repeating: "ab", count: 40_000))
    line.syntax = stride(from: 0, to: 80_000, by: 2).map { SyntaxSpan(range: $0..<$0 + 1, kind: .keyword) }
    line.changes = [10..<20, 50_000..<50_010]
    let t = ContinuousClock().measure { #expect(String(lineContent(line).characters).count == 80_000) }
    // 0.5 s alone in debug, 3.6 s seen under a parallel run at load 10; the quadratic version took minutes
    #expect(t < .seconds(20))
}

@Test func aCRLFLineDrawsWithoutItsCarriageReturn() {
    // a "\r" left in the text lays out as a second line, so a CRLF row would be drawn twice as tall
    var line = DiffLine(kind: .added, old: nil, new: 1, text: "val s = \"a\"\r")
    line.syntax = [SyntaxSpan(range: 0..<3, kind: .keyword), SyntaxSpan(range: 8..<12, kind: .string)]
    line.changes = [8..<12]
    let r = runs(lineContent(line))
    #expect(r.map(\.text).joined() == "val s = \"a\"")
    #expect(r.last?.text == "\"a\"" && r.last?.bg != nil)  // the word mark ends with the shown text
    #expect(String(lineContent(DiffLine(kind: .context, old: 1, new: 1, text: "\r")).characters) == "")
    #expect(String(lineContent(DiffLine(kind: .context, old: 1, new: 1, text: "a\rb")).characters) == "a\rb")  // only a trailing one
}
