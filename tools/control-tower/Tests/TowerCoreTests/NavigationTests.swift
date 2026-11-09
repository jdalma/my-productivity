import Foundation
import Testing
@testable import TowerCore

private func lines(_ body: String) -> [DiffLine] {
    parseUnifiedDiff("diff --git a/f b/f\n--- a/f\n+++ b/f\n" + body)[0].lines
}

@Test func addedAndContextLinesOpenTheirNewNumber() {
    let l = lines("@@ -10,3 +20,4 @@ fn\n keep\n+new\n tail\n")
    #expect(fileLine(at: 0, in: l) == 20)  // the hunk header: its new start
    #expect(fileLine(at: 1, in: l) == 20)
    #expect(fileLine(at: 2, in: l) == 21)
    #expect(fileLine(at: 3, in: l) == 22)
}

/// A removed line is not in the working tree: it opens where it was on the new side.
@Test func removedLinesOpenTheNearestNewSideLine() {
    let l = lines("@@ -10,4 +20,3 @@\n keep\n-a\n-b\n+c\n tail\n@@ -40,2 +50,0 @@\n-x\n-y\n")
    #expect(fileLine(at: 2, in: l) == 21)  // after `keep` (20), where `c` now is
    #expect(fileLine(at: 3, in: l) == 21)
    #expect(fileLine(at: 4, in: l) == 21)
    // a hunk that only removes, at its start: the hunk's new start, never 0
    let tail = lines("@@ -1,2 +0,0 @@\n-x\n-y\n")
    #expect(fileLine(at: 1, in: tail) == 1)
    #expect(fileLine(at: 6, in: l) == 50)  // the second hunk, no new-side line before it in its hunk
    let head = lines("@@ -1,2 +1,1 @@\n-gone\n kept\n")
    #expect(fileLine(at: 1, in: head) == 1)
}

@Test func theIdentifierUnderAnOffset() {
    let s = "val list: List<T> = a.b(\"str\") // note"
    func word(_ at: Int) -> String? { identifier(in: s, at: at)?.name }
    #expect(word(0) == "val" && word(2) == "val")
    #expect(word(3) == nil)                        // the space after it
    #expect(word(10) == "List" && word(15) == "T")  // `List<T>`: each side of the bracket
    #expect(word(14) == nil)                        // `<`
    #expect(word(20) == "a" && word(22) == "b")     // `a.b`: the dot splits them
    #expect(word(21) == nil)
    #expect(identifier(in: s, at: 22)?.range == 22..<23)
    // inside a string or a comment a word still counts (lexical only)
    #expect(word(25) == "str" && word(34) == "note")
    #expect(word(s.count - 1) == "note")            // the last character
    #expect(word(s.count) == nil)                   // past the line end
    #expect(word(-1) == nil)
}

@Test func identifierRulesForJavaAndKotlin() {
    #expect(identifier(in: "x = 42", at: 4) == nil)                     // a number
    #expect(identifier(in: "a1b", at: 1)?.name == "a1b")
    #expect(identifier(in: "_id + $ref", at: 0)?.name == "_id")
    #expect(identifier(in: "_id + $ref", at: 7)?.name == "$ref")
    #expect(identifier(in: "이름.length", at: 1) == CodeWord(name: "이름", range: 0..<2))
    #expect(identifier(in: "`is open`", at: 2)?.name == "is")          // backticks: not one name
    // Kotlin: `$` starts a template, never part of a name; Java keeps it
    #expect(identifier(in: "\"Hello $user\"", at: 8, dollar: false) == CodeWord(name: "user", range: 8..<12))
    #expect(identifier(in: "\"Hello $user\"", at: 7, dollar: false) == nil)
    #expect(identifier(in: "\"${foo}\"", at: 3, dollar: false)?.name == "foo")
    #expect(identifier(in: "\"Hello $user\"", at: 8)?.name == "$user")
    #expect(dottedName(in: "\"$a.b\"", at: 4, dollar: false) == ["a", "b"])
}

@Test func historyGoesBackAndForwardAndDropsTheForwardBranch() {
    let a = CodeLocation(path: "A.kt", line: 1), b = CodeLocation(path: "B.kt", line: 2), c = CodeLocation(path: "C.kt", line: 3)
    var h = CodeHistory()
    #expect(h.current == nil && !h.canGoBack && !h.canGoForward)
    h.open(a)
    h.open(b)
    #expect(h.current == b)
    h.back()
    #expect(h.current == a)
    h.back()
    #expect(h.current == nil)  // back to the end is the diff
    h.back()
    #expect(h.current == nil)
    h.forward()
    #expect(h.current == a)
    h.open(c)                  // a new jump drops `b`, ahead of it
    #expect(!h.canGoForward)
    h.back()
    #expect(h.current == a)
    h.forward()
    #expect(h.current == c)
    h.toDiff()                 // Esc: the diff, and forward returns to the file view
    #expect(h.current == nil && h.canGoForward)
    h.forward()
    #expect(h.current == a)
}

/// A jump from a file view line records that line, so back returns there.
@Test func aJumpRecordsWhereItStarted() {
    var h = CodeHistory()
    h.open(CodeLocation(path: "A.kt", line: 1))
    h.open(CodeLocation(path: "B.kt", line: 9), from: CodeLocation(path: "A.kt", line: 30))
    h.back()
    #expect(h.current == CodeLocation(path: "A.kt", line: 30))
    h.toDiff()
    h.open(CodeLocation(path: "C.kt", line: 1), from: CodeLocation(path: "X.kt", line: 5))  // from the diff: nothing to replace
    h.back()
    #expect(h.current == nil)
}

@Test func theWorkingFileIsReadAroundTheLine() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "nav-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appending(path: "src"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let text = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
    try text.write(to: dir.appending(path: "src/A.kt"), atomically: true, encoding: .utf8)
    try Data([0x61, 0, 0x62]).write(to: dir.appending(path: "bin"))
    try Data([0xff, 0xfe, 0x41]).write(to: dir.appending(path: "latin"))
    let top = dir.path

    guard case .text(let all, let total) = readWorkingFile(toplevel: top, path: "src/A.kt", around: 3) else { Issue.record(); return }
    #expect(total == 10 && all.count == 10)
    #expect(all[2] == DiffLine(kind: .context, old: nil, new: 3, text: "line 3"))
    guard case .text(let window, _) = readWorkingFile(toplevel: top, path: "src/A.kt", around: 9, lineLimit: 4) else { Issue.record(); return }
    #expect(window.map(\.new) == [7, 8, 9, 10])
    guard case .text(let head, _) = readWorkingFile(toplevel: top, path: "src/A.kt", around: 1, lineLimit: 4) else { Issue.record(); return }
    #expect(head.map(\.new) == [1, 2, 3, 4])
    guard case .text(let mid, _) = readWorkingFile(toplevel: top, path: "src/A.kt", around: 6, lineLimit: 4) else { Issue.record(); return }
    #expect(mid.map(\.new) == [4, 5, 6, 7])
    #expect(readWorkingFile(toplevel: top, path: "gone.kt", around: 1) == .missing)
    #expect(readWorkingFile(toplevel: top, path: "src", around: 1) == .missing)
    #expect(readWorkingFile(toplevel: top, path: "bin", around: 1) == .binary)
    #expect(readWorkingFile(toplevel: top, path: "latin", around: 1) == .binary)
    try "a\r\nb\r\nc\r\n".write(to: dir.appending(path: "crlf.kt"), atomically: true, encoding: .utf8)
    guard case .text(let crlf, let n) = readWorkingFile(toplevel: top, path: "crlf.kt", around: 1) else { Issue.record(); return }
    #expect(n == 3 && crlf.map(\.text) == ["a\r", "b\r", "c\r"])  // as the diff parser keeps them
}

@Test func fileLinesAreHighlightedLikeDiffLines() async {
    let lines = [DiffLine(kind: .context, old: nil, new: 1, text: "let x = 1")]
    let lit = await highlightedLines(lines, path: "a.swift")
    #expect(lit[0].syntax.contains(SyntaxSpan(range: 0..<3, kind: .keyword)))
    #expect(await highlightedLines(lines, path: "a.unknown") == lines)
}
