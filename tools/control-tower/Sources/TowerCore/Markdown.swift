import Foundation

// A ticket's whole text as Markdown (T136): the blocks these tickets use, each line in exactly one block, so nothing
// the reader wrote disappears. What is not read as one of these blocks is a paragraph, or, for a table whose rows do not
// line up, its lines as written.

public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// `marker` is `•` for `-`, `*`, `+`; a number keeps its own (`1.`, `2)`). `depth` counts two spaces of indent.
    case listItem(depth: Int, marker: String, text: String)
    /// A list item that opens with `[ ]` or `[x]`: a check box in place of its marker.
    case task(depth: Int, done: Bool, text: String)
    /// `language` is the word after the opening fence (```` ```swift ````), nil without one.
    case code(language: String?, lines: [String])
    case table(header: [String], rows: [[String]])
    case quote(String)
    /// A quote whose first line is `[!NOTE]` or another of GitHub's five kinds; `text` is the lines after it.
    case callout(CalloutKind, text: String)
    /// `---`, `***` or `___` alone on a line; `---` right under a paragraph is that paragraph as a heading instead.
    case rule
    case paragraph(String)
    /// Lines shown as written, in a fixed-width font.
    case raw([String])
}

public enum CalloutKind: String, CaseIterable, Sendable {
    case note, tip, important, warning, caution
}

private func indentWidth(_ line: Substring) -> Int {
    line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
}

private func heading(_ line: String) -> MarkdownBlock? {
    line.wholeMatch(of: #/(#{1,6})\s+(.*)/#).map { .heading(level: $0.1.count, text: String($0.2).trimmingCharacters(in: .whitespaces)) }
}

private func listItem(_ line: String) -> MarkdownBlock? {
    guard let m = line.wholeMatch(of: #/([ \t]*)([-*+]|\d{1,9}[.)])(?:[ \t]+(.*))?/#) else { return nil }
    let marker = String(m.2).count == 1 && "-*+".contains(m.2) ? "•" : String(m.2)
    let depth = indentWidth(m.1) / 2, text = String(m.3 ?? "")
    if let box = text.wholeMatch(of: #/\[([ xX])\](?:[ \t]+(.*))?/#) {
        return .task(depth: depth, done: box.1 != " ", text: String(box.2 ?? ""))
    }
    return .listItem(depth: depth, marker: marker, text: text)
}

/// Three or more of one of `-`, `*`, `_`, with nothing else on the line but spaces between them.
private func isRule(_ line: String) -> Bool { line.wholeMatch(of: #/ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*/#) != nil }

/// Dashes alone right under a paragraph make it a heading (CommonMark's setext heading), not a rule (R12 L1).
private func underlinesHeading(_ line: String) -> Bool { line.wholeMatch(of: #/ {0,3}-{3,}[ \t]*/#) != nil }

/// `[!NOTE]` alone on a quote's first line, in any case.
private func calloutKind(_ line: String) -> CalloutKind? {
    line.trimmingCharacters(in: .whitespaces).wholeMatch(of: #/\[!([A-Za-z]+)\]/#).flatMap { CalloutKind(rawValue: $0.1.lowercased()) }
}

/// A line that opens a code block: three or more backticks and an info string with none (R53 S2): "```foo``` is…"
/// opens and closes inline code on one line and is a paragraph.
private func opensFence(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).wholeMatch(of: #/`{3,}[^`]*/#) != nil }
/// A line that closes one: backticks alone. "``` trailing" is a line of the code, so its text stays.
private func closesFence(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).wholeMatch(of: #/`{3,}/#) != nil }
private func isQuote(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
private func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

private func isTableSeparator(_ line: String) -> Bool {
    line.wholeMatch(of: #/\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*/#) != nil && line.contains("|")
}

/// A table row's cells: the outer pipes dropped, split at each pipe that no backslash escapes, each cell trimmed.
func tableCells(_ line: String) -> [String] {
    var s = line.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("|") { s.removeFirst() }
    if s.hasSuffix("|") && !s.hasSuffix("\\|") { s.removeLast() }
    var cells = [""], escaped = false
    for c in s {
        if c == "|" && !escaped { cells.append("") } else { cells[cells.count - 1].append(c) }
        escaped = c == "\\" && !escaped
    }
    return cells.map { $0.trimmingCharacters(in: .whitespaces) }
}

private func startsBlock(_ lines: [String], _ i: Int) -> Bool {
    let l = lines[i]
    return heading(l) != nil || isRule(l) || listItem(l) != nil || opensFence(l) || isQuote(l)
        || (l.contains("|") && i + 1 < lines.count && isTableSeparator(lines[i + 1]))
}

public func markdownBlocks(_ text: String) -> [MarkdownBlock] {
    let lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    var blocks: [MarkdownBlock] = []
    var i = 0
    while i < lines.count {
        let line = lines[i]
        if isBlank(line) {
            i += 1
        } else if opensFence(line) {
            var code: [String] = []
            // the first word only: the rest of the line (`swift title="a.swift"`) is not the language (R12 L3)
            let language = line.trimmingCharacters(in: .whitespaces).drop { $0 == "`" }.split(whereSeparator: \.isWhitespace).first.map(String.init)
            i += 1
            while i < lines.count, !closesFence(lines[i]) { code.append(lines[i]); i += 1 }
            i += 1  // the closing fence; past the end when there is none, and the block keeps every line
            blocks.append(.code(language: language, lines: code))
        } else if let h = heading(line) {
            blocks.append(h)
            i += 1
        } else if line.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
            var j = i + 2
            while j < lines.count, !isBlank(lines[j]), lines[j].contains("|") { j += 1 }
            let header = tableCells(line), rows = lines[(i + 2)..<j].map(tableCells)
            blocks.append(rows.allSatisfy { $0.count == header.count } ? .table(header: header, rows: rows) : .raw(Array(lines[i..<j])))
            i = j
        } else if isRule(line) {
            blocks.append(.rule)
            i += 1
        } else if let first = listItem(line) {
            var more = ""
            i += 1
            // an indented line under an item that starts nothing of its own goes on with the item
            while i < lines.count, !isBlank(lines[i]), indentWidth(lines[i][...]) > 0, !startsBlock(lines, i) {
                more += "\n" + lines[i].trimmingCharacters(in: .whitespaces)
                i += 1
            }
            switch first {
            case .task(let depth, let done, let text): blocks.append(.task(depth: depth, done: done, text: text + more))
            case .listItem(let depth, let marker, let text): blocks.append(.listItem(depth: depth, marker: marker, text: text + more))
            default: blocks.append(first)
            }
        } else if isQuote(line) {
            var quoted: [String] = []
            while i < lines.count, isQuote(lines[i]) {
                let body = lines[i].trimmingCharacters(in: .whitespaces).dropFirst()
                quoted.append(String(body.hasPrefix(" ") ? body.dropFirst() : body))
                i += 1
            }
            // a kind with nothing under it, or only blank lines (R12 L2), stays a quote, so its line is still shown
            if quoted.dropFirst().contains(where: { !isBlank($0) }), let kind = calloutKind(quoted[0]) {
                blocks.append(.callout(kind, text: quoted.dropFirst().joined(separator: "\n")))
            } else {
                blocks.append(.quote(quoted.joined(separator: "\n")))
            }
        } else {
            var para = [line.trimmingCharacters(in: .whitespaces)]
            i += 1
            while i < lines.count, !isBlank(lines[i]), !startsBlock(lines, i) {
                para.append(lines[i].trimmingCharacters(in: .whitespaces))
                i += 1
            }
            if i < lines.count, underlinesHeading(lines[i]) {
                blocks.append(.heading(level: 2, text: para.joined(separator: "\n")))
                i += 1
            } else {
                blocks.append(.paragraph(para.joined(separator: "\n")))
            }
        }
    }
    return blocks
}

/// A line of Markdown with its inline marks read (bold, italic, code, http and https links), its line breaks kept; a mark left open
/// stays as written, and text the reader cannot take at all is shown plain.
public func inlineMarkdown(_ s: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                         failurePolicy: .returnPartiallyParsedIfPossible)
    var text = (try? AttributedString(markdown: s, options: options)) ?? AttributedString(s)
    // only a web link opens (R53 S1): a `file://` address or an app's own scheme in a ticket stays text
    for run in text.runs where run.link.map({ !["http", "https"].contains($0.scheme?.lowercased() ?? "") }) == true {
        text[run.range].link = nil
    }
    return text
}
