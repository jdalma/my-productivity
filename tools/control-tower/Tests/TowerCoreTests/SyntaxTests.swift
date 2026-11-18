import Foundation
import Testing
@testable import TowerCore

private func kinds(_ line: String, _ spans: [SyntaxSpan]) -> [String: SyntaxKind] {
    let cs = Array(line)
    return Dictionary(spans.map { (String(cs[$0.range]), $0.kind) }, uniquingKeysWith: { a, _ in a })
}

@Test func swiftAndTypeScriptLinesGetKeywordStringAndComment() async throws {
    let swift = #"let s = "hi" // note"#
    let ts = "const x: string = 'a'; // c"
    let sw = try #require(await SyntaxHighlighter.shared.spans([swift], language: "swift"))
    let t = try #require(await SyntaxHighlighter.shared.spans([ts], language: "typescript"))
    let a = kinds(swift, sw[0]), b = kinds(ts, t[0])
    #expect(a["let"] == .keyword)
    #expect(a["\"hi\""] == .string)
    #expect(a["// note"] == .comment)
    #expect(b["const"] == .keyword)
    #expect(b["'a'"] == .string)
    #expect(b["// c"] == .comment)
}

@Test func languagesComeFromTheExtension() {
    #expect(syntaxLanguage(forPath: "Sources/A.swift") == "swift")
    #expect(syntaxLanguage(forPath: "web/x.TSX") == "typescript")
    #expect(syntaxLanguage(forPath: "a/b.yml") == "yaml")
    #expect(syntaxLanguage(forPath: "notes.txt") == nil)
    #expect(syntaxLanguage(forPath: "Makefile") == nil)
}

private func diff(_ path: String, _ text: String) -> WorkspaceDiff {
    let lines = [DiffLine(kind: .hunk, old: nil, new: nil, text: "@@ -1 +1 @@"), DiffLine(kind: .added, old: nil, new: 1, text: text)]
    return WorkspaceDiff(toplevel: "/r", base: .none, committed: nil,
                         uncommitted: DiffSection(files: [FileDiff(path: path, added: 1, removed: 0, binary: false, lines: lines)], untracked: []))
}

@Test func unknownExtensionsAndScriptFailuresStayOneColor() async {
    let known = await highlighted(diff("a.swift", "let x = 1"))
    #expect(known.uncommitted.files[0].lines[1].syntax.isEmpty == false)
    #expect(known.uncommitted.files[0].lines[0].syntax.isEmpty)  // hunk headers are not code
    let unknown = await highlighted(diff("a.txt", "let x = 1"))
    #expect(unknown.uncommitted.files[0].lines.allSatisfy { $0.syntax.isEmpty })
    for broken in [SyntaxHighlighter(source: "throw new Error('boom')"), SyntaxHighlighter(source: nil), SyntaxHighlighter(source: "var hljs = 1")] {
        #expect(await broken.spans(["let x = 1"], language: "swift") == nil)
        let d = await highlighted(diff("a.swift", "let x = 1"), with: broken)
        #expect(d.uncommitted.files[0].lines.allSatisfy { $0.syntax.isEmpty })
    }
}

@Test func anUnknownLanguageNameIsAScriptErrorNotACrash() async {
    #expect(await SyntaxHighlighter.shared.spans(["x"], language: "no-such-language") == nil)
    #expect(await SyntaxHighlighter.shared.spans(["let a = 1"], language: "swift") != nil)  // the context survives it
}

@Test func htmlSpansMapBackToCharacterOffsets() {
    let line = "a < \"한글 👍🏽\" & b"
    let html = "a &lt; <span class=\"hljs-string\">&quot;한글 👍🏽&quot;</span> &amp; <span class=\"hljs-params\">b</span>"
    #expect(syntaxSpans(html: html, line: line) == [SyntaxSpan(range: 4..<10, kind: .string)])
    #expect(syntaxSpans(html: "<span class=\"hljs-keyword\">let</span>", line: "var") == [])  // does not spell the line
    let nested = "<span class=\"hljs-string\">\"a<span class=\"hljs-subst\">\\(b)</span>\"</span>"
    #expect(syntaxSpans(html: nested, line: "\"a\\(b)\"") == [SyntaxSpan(range: 0..<2, kind: .string), SyntaxSpan(range: 6..<7, kind: .string)])
    #expect(syntaxSpans(html: "<span class=\"hljs-variable language_\">self</span>", line: "self") == [SyntaxSpan(range: 0..<4, kind: .keyword)])
}

@Test func anUnchangedDiffTextIsParsedOnce() {
    let memo = ParseMemo()
    let text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a(1)\n+a(2)\n"
    let first = memo.files(.uncommitted, text, 2000)
    #expect(memo.files(.uncommitted, text, 2000) == first)
    #expect(memo.parses == 1)
    #expect(first[0].lines[2].changes == [2..<3])  // capped and word-marked before it is kept
    _ = memo.files(.uncommitted, text + "+b\n", 2000)
    _ = memo.files(.uncommitted, text, 1)
    #expect(memo.parses == 3)
}

@Test func linesPastTheLimitStayOneColor() async {
    let long = "let x = " + String(repeating: "1", count: 1993)  // 2001 characters
    let edge = "let x = " + String(repeating: "1", count: 1992)  // 2000
    #expect(await highlighted(diff("a.swift", long)).uncommitted.files[0].lines[1].syntax.isEmpty)
    #expect(await !highlighted(diff("a.swift", edge)).uncommitted.files[0].lines[1].syntax.isEmpty)
    let wide = "let s = \"" + String(repeating: "한", count: 1500) + "\""  // 1510 characters, 4510 bytes
    #expect(await !highlighted(diff("a.swift", wide)).uncommitted.files[0].lines[1].syntax.isEmpty)
}

@Test func kotlinAndJavaLinesGetKeywordStringAndComment() async throws {
    let kt = #"val s: String = "hi" // note"#
    let java = #"private final String s = "hi"; // c"#
    let template = #"val m = "$name ${a.b}""#
    let kotlin = try #require(syntaxLanguage(forPath: "src/com/example/A.kt"))
    let javaLanguage = try #require(syntaxLanguage(forPath: "src/com/example/B.java"))
    let k = try #require(await SyntaxHighlighter.shared.spans([kt, template], language: kotlin))
    let j = try #require(await SyntaxHighlighter.shared.spans([java], language: javaLanguage))
    let a = kinds(kt, k[0]), b = kinds(java, j[0])
    #expect(a["val"] == .keyword)
    #expect(a["\"hi\""] == .string)
    #expect(a["// note"] == .comment)
    #expect(b["private"] == .keyword)
    #expect(b["\"hi\""] == .string)
    #expect(b["// c"] == .comment)
    #expect(kinds(template, k[1])["val"] == .keyword)  // the template's spans spell the line back
    #expect(syntaxLanguage(forPath: "build.gradle.kts") == "kotlin")
}

@Test func untrackedFilesAreHighlightedToo() async {
    var d = diff("a.txt", "x")
    d.uncommitted.newFiles = [newFileDiff("src/com/example/N.kt", Data("val n = 1\n".utf8), 2000)]
    let h = await highlighted(d)
    #expect(h.uncommitted.newFiles[0].lines[1].syntax.isEmpty == false)
}
