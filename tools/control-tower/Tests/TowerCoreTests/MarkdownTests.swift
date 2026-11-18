import Foundation
import Testing
@testable import TowerCore

// T136: a ticket's whole text read as Markdown blocks, and its inline marks.

@Test func headingsListsQuotesAndParagraphsAreTheirOwnBlocks() {
    let b = markdownBlocks("""
    # Title
    ## Section (note)
    ### Small

    first line
    second line

    - one
      - one a
        wrapped onto a second line
    1. first
    10) tenth
    > quoted
    > on two lines
    """)
    #expect(b == [
        .heading(level: 1, text: "Title"),
        .heading(level: 2, text: "Section (note)"),
        .heading(level: 3, text: "Small"),
        .paragraph("first line\nsecond line"),
        .listItem(depth: 0, marker: "•", text: "one"),
        .listItem(depth: 1, marker: "•", text: "one a\nwrapped onto a second line"),
        .listItem(depth: 0, marker: "1.", text: "first"),
        .listItem(depth: 0, marker: "10)", text: "tenth"),
        .quote("quoted\non two lines"),
    ])
}

@Test func aCodeBlockKeepsItsLinesAsWritten() {
    let b = markdownBlocks("before\n```swift\nlet a = 1\n\n  # not a heading\n```\nafter")
    #expect(b == [.paragraph("before"), .code(language: "swift", lines: ["let a = 1", "", "  # not a heading"]), .paragraph("after")])
}

@Test func anUnclosedCodeBlockRunsToTheEndAndLosesNothing() {
    #expect(markdownBlocks("```\nx\n- y") == [.code(language: nil, lines: ["x", "- y"])])
}

@Test func aTableIsAHeaderAndRowsOfTheSameWidth() {
    let b = markdownBlocks("""
    | 커밋 | 내용 |
    |---|:---:|
    | `abc` | a \\| b |
    | def |  |
    """)
    #expect(b == [.table(header: ["커밋", "내용"], rows: [["`abc`", "a \\| b"], ["def", ""]])])
}

@Test func aTableWhoseRowsDoNotLineUpIsShownAsWritten() {
    let text = "| a | b |\n|---|---|\n| 1 | 2 | 3 |"
    #expect(markdownBlocks(text) == [.raw(text.components(separatedBy: "\n"))])
}

@Test func pipesWithoutASeparatorLineAreAParagraph() {
    #expect(markdownBlocks("a | b\nc | d") == [.paragraph("a | b\nc | d")])
}

@Test func everyNonBlankLineOfAnyInputSurvives() {
    let text = "#no space\n- \n>\n|---|\n```\n````\n**\n  1.x\n\t- tab\n- [y] box\n> [!NOTE]\n> [!OTHER]\n> under"
    let shown = markdownBlocks(text).flatMap { b -> [String] in
        switch b {
        case .heading(_, let t), .paragraph(let t), .quote(let t), .listItem(_, _, let t), .task(_, _, let t), .callout(_, let t):
            t.components(separatedBy: "\n")
        case .code(_, let l), .raw(let l): l
        case .table(let h, let r): [h.joined()] + r.map { $0.joined() }
        case .rule: []
        }
    }.joined()
    for word in ["#no space", "|---|", "**", "1.x", "tab", "[y] box", "[!OTHER]", "under"] { #expect(shown.contains(word), "\(word)") }
}

@Test func aListItemThatOpensWithABoxIsACheckBox() {
    let b = markdownBlocks("- [ ] todo\n  more\n- [x] done\n  * [X] nested\n1. [ ] numbered\n- [] no box\n- [ ]tight\n- [ ]")
    #expect(b == [
        .task(depth: 0, done: false, text: "todo\nmore"),
        .task(depth: 0, done: true, text: "done"),
        .task(depth: 1, done: true, text: "nested"),
        .task(depth: 0, done: false, text: "numbered"),
        .listItem(depth: 0, marker: "•", text: "[] no box"),
        .listItem(depth: 0, marker: "•", text: "[ ]tight"),
        .task(depth: 0, done: false, text: ""),
    ])
}

@Test(arguments: CalloutKind.allCases)
func aQuoteThatOpensWithAKindIsACallout(_ kind: CalloutKind) {
    let mark = "[!\(kind.rawValue.uppercased())]"
    #expect(markdownBlocks("> \(mark)\n> first **line**\n> second") == [.callout(kind, text: "first **line**\nsecond")])
    #expect(markdownBlocks(">\(mark.lowercased())\n>body\n\nafter") == [.callout(kind, text: "body"), .paragraph("after")])
}

@Test func aKindThatIsNotOneOfTheFiveOrHasNothingUnderItStaysAQuote() {
    #expect(markdownBlocks("> [!HINT]\n> body") == [.quote("[!HINT]\nbody")])
    #expect(markdownBlocks("> [!NOTE]") == [.quote("[!NOTE]")])
    #expect(markdownBlocks("> [!NOTE]\n>\n>  ") == [.quote("[!NOTE]\n\n")], "R12 L2: only blank lines under the kind")
    #expect(markdownBlocks("> [!NOTE]\n>\n> body") == [.callout(.note, text: "\nbody")])
    #expect(markdownBlocks("> [!NOTE] same line\n> body") == [.quote("[!NOTE] same line\nbody")])
    #expect(markdownBlocks("> body\n> [!NOTE]") == [.quote("body\n[!NOTE]")])
}

@Test func threeOrMoreOfOneMarkAloneOnALineIsARule() {
    #expect(markdownBlocks("above\n\n---\nbelow") == [.paragraph("above"), .rule, .paragraph("below")])
    #expect(markdownBlocks("# head\n---\n- item\n---") == [.heading(level: 1, text: "head"), .rule, .listItem(depth: 0, marker: "•", text: "item"), .rule],
            "only a paragraph is underlined")
    for line in ["---", "***", "___", "- - -", "* * *", "-----", "   ---  "] { #expect(markdownBlocks(line) == [.rule], "\(line)") }
    #expect(markdownBlocks("--") == [.paragraph("--")])
    #expect(markdownBlocks("-*-") == [.paragraph("-*-")])
    #expect(markdownBlocks("--- a") == [.paragraph("--- a")])
    #expect(markdownBlocks("- - x") == [.listItem(depth: 0, marker: "•", text: "- x")])
    #expect(markdownBlocks("a | b\n--- | ---\n1 | 2") == [.table(header: ["a", "b"], rows: [["1", "2"]])], "a table's separator is no rule")
}

@Test func aCodeBlockKeepsTheLanguageAfterItsFence() {
    #expect(markdownBlocks("```swift\nx\n```") == [.code(language: "swift", lines: ["x"])])
    #expect(markdownBlocks("``` sh \nx\n```") == [.code(language: "sh", lines: ["x"])])
    #expect(markdownBlocks("```swift title=\"a.swift\"\nx\n```") == [.code(language: "swift", lines: ["x"])], "R12 L3: the first word only")
    #expect(markdownBlocks("```\nx\n```") == [.code(language: nil, lines: ["x"])])
}

@Test func inlineMarksBecomeBoldItalicCodeAndLinks() throws {
    let s = inlineMarkdown("**굵게** *기울임* `코드` [링크](https://example.com)")
    #expect(String(s.characters) == "굵게 기울임 코드 링크")
    let runs = s.runs.map { (String(s[$0.range].characters), $0.inlinePresentationIntent, $0.link) }
    #expect(runs.contains { $0.0 == "굵게" && $0.1 == .stronglyEmphasized })
    #expect(runs.contains { $0.0 == "기울임" && $0.1 == .emphasized })
    #expect(runs.contains { $0.0 == "코드" && $0.1 == .code })
    #expect(runs.contains { $0.0 == "링크" && $0.2 == URL(string: "https://example.com") })
}

@Test func inlineTextKeepsItsLineBreaksAndUnclosedMarks() {
    #expect(String(inlineMarkdown("a\nb").characters) == "a\nb")
    #expect(String(inlineMarkdown("**open `tick").characters) == "**open `tick")
}

/// R53 S2: a line that opens and closes inline code on itself is no fence, and text after a closing fence stays.
@Test func aLineWithBackticksAfterTheFenceIsNoCodeBlockAndNothingIsLost() {
    #expect(markdownBlocks("```foo``` is the command\nnext para") == [.paragraph("```foo``` is the command\nnext para")])
    #expect(markdownBlocks("```\nx\n``` trailing\ny") == [.code(language: nil, lines: ["x", "``` trailing", "y"])])
    #expect(markdownBlocks("```swift\nx\n````\nafter") == [.code(language: "swift", lines: ["x"]), .paragraph("after")])
}

/// R53 S1: only a web link is a link; `file://` and an app's own scheme stay text.
@Test func onlyHttpAndHttpsLinksAreLinks() {
    let s = inlineMarkdown("[a](https://example.com) [b](http://example.com) [c](file:///Applications/Calculator.app) [d](x-app://open) [e](mailto:x@example.com)")
    #expect(String(s.characters) == "a b c d e")
    #expect(s.runs.compactMap(\.link).map(\.absoluteString) == ["https://example.com", "http://example.com"])
}

/// R12 L1: dashes right under a paragraph underline it (CommonMark's setext heading); a rule needs a blank line.
@Test func dashesRightUnderAParagraphMakeItAHeading() {
    #expect(markdownBlocks("Title\n---\nbody") == [.heading(level: 2, text: "Title"), .paragraph("body")])
    #expect(markdownBlocks("Two\nlines\n-----  \nbody") == [.heading(level: 2, text: "Two\nlines"), .paragraph("body")])
    #expect(markdownBlocks("Title\n***\nbody") == [.paragraph("Title"), .rule, .paragraph("body")], "only dashes underline")
    #expect(markdownBlocks("Title\n- - -") == [.paragraph("Title"), .rule])
    #expect(markdownBlocks("Title\n--") == [.paragraph("Title\n--")])
}
