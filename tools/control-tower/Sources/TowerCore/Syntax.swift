import Foundation
import JavaScriptCore

/// GitHub's syntax color roles (Primer `prettylights-syntax-*`). highlight.js scopes map onto them
/// as highlight.js's own styles/github.css does.
public enum SyntaxKind: Hashable, Sendable {
    case keyword, entity, constant, string, variable, comment, entityTag, heading, list
}

/// A colored run of a line, in Character offsets of `DiffLine.text`.
public struct SyntaxSpan: Hashable, Sendable {
    public var range: Range<Int>
    public var kind: SyntaxKind

    public init(range: Range<Int>, kind: SyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

private let languages = [
    "swift": "swift", "ts": "typescript", "tsx": "typescript", "mts": "typescript", "cts": "typescript",
    "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript", "py": "python",
    "sh": "bash", "bash": "bash", "zsh": "bash", "json": "json", "md": "markdown", "markdown": "markdown",
    "yml": "yaml", "yaml": "yaml", "kt": "kotlin", "kts": "kotlin", "java": "java",
]

/// The highlight.js language for a path, by extension; nil leaves the file one color.
public func syntaxLanguage(forPath path: String) -> String? {
    languages[(path as NSString).pathExtension.lowercased()]
}

/// The one JavaScriptCore context, used only from this actor. nil function: the script failed to load,
/// and every file stays one color.
public actor SyntaxHighlighter {
    public static let shared = SyntaxHighlighter(source: bundledScript())

    private let context = JSContext()
    private let highlightLines: JSValue?

    init(source: String?) {
        guard let context, let source else { highlightLines = nil; return }
        context.evaluateScript(source)
        // Lines arrive as an argument; nothing from a diff is ever part of script text.
        let fn = context.evaluateScript("""
            (function (lines, lang) {
                return lines.map(function (l) { return hljs.highlight(l, {language: lang, ignoreIllegals: true}).value })
            })
            """)
        highlightLines = context.exception == nil && fn?.isObject == true ? fn : nil
        context.exception = nil
    }

    /// Spans per line, each line highlighted on its own so a multi-line string or comment cut by a hunk
    /// can only miscolor its own line. nil on any script error.
    public func spans(_ lines: [String], language: String) -> [[SyntaxSpan]]? {
        guard let context, let highlightLines else { return nil }
        let result = highlightLines.call(withArguments: [lines, language])
        defer { context.exception = nil }
        guard context.exception == nil, let html = result?.toArray() as? [String], html.count == lines.count else { return nil }
        return zip(html, lines).map { syntaxSpans(html: $0, line: $1) }
    }
}

/// The app copies the script into Contents/Resources; tests find the SwiftPM resource bundle beside the
/// test bundle. Not `Bundle.module`: it calls fatalError when the bundle is missing, and a missing script
/// must mean one color, not a crash.
private func bundledScript() -> String? {
    // The bundle holding this code: the app itself, or under `swift test` the test bundle beside the resources.
    let swiftPM = [Bundle(for: BundleToken.self), Bundle.main].lazy
        .compactMap { Bundle(url: $0.bundleURL.deletingLastPathComponent().appending(path: "ControlTower_TowerCore.bundle")) }
        .compactMap { $0.url(forResource: "highlight.min", withExtension: "js", subdirectory: "Resources") }
        .first
    let url = Bundle.main.url(forResource: "highlight.min", withExtension: "js") ?? swiftPM
    return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
}

private final class BundleToken {}

/// Lines past this many characters stay one color: a minified line holds tens of thousands of spans,
/// costly to compute and to lay out.
public let syntaxLineLimit = 2000

/// Fills `syntax` for every file whose language is known. Files the script cannot handle stay one color.
/// Stops between files once cancelled; the caller drops a cancelled result.
/// `nil` means `.shared`, first touched here so its script load runs off the caller's actor.
public func highlighted(_ d: WorkspaceDiff, with h: SyntaxHighlighter? = nil) async -> WorkspaceDiff {
    let h = h ?? .shared
    func section(_ s: DiffSection) async -> DiffSection {
        var s = s
        for i in s.files.indices where !Task.isCancelled {
            s.files[i].lines = await highlightedLines(s.files[i].lines, path: s.files[i].path, with: h)
        }
        for i in s.newFiles.indices where !Task.isCancelled {
            s.newFiles[i].lines = await highlightedLines(s.newFiles[i].lines, path: s.newFiles[i].path, with: h)
        }
        return s
    }
    var d = d
    if let c = d.committed { d.committed = await section(c) }
    d.uncommitted = await section(d.uncommitted)
    return d
}

/// One file's lines with `syntax` filled when the path's language is known; unchanged when it is not
/// or the script fails.
public func highlightedLines(_ lines: [DiffLine], path: String, with h: SyntaxHighlighter? = nil) async -> [DiffLine] {
    guard let lang = syntaxLanguage(forPath: path) else { return lines }
    let at = lines.indices.filter { j in
        // utf8 count is O(1) and never below the Character count
        lines[j].kind != .hunk && (lines[j].text.utf8.count <= syntaxLineLimit || lines[j].text.count <= syntaxLineLimit)
    }
    guard let spans = await (h ?? .shared).spans(at.map { lines[$0].text }, language: lang) else { return lines }
    var lines = lines
    for (j, sp) in zip(at, spans) { lines[j].syntax = sp }
    return lines
}

/// `nil` entries are scopes github.css paints in the default color; scopes it does not name inherit.
private let scopeKinds: [String: SyntaxKind?] = {
    var m: [String: SyntaxKind?] = ["subst": SyntaxKind?.none]
    let named: [(SyntaxKind, String)] = [
        (.keyword, "doctag keyword template-tag template-variable type"),
        (.entity, "title"),
        (.constant, "attr attribute literal meta number operator variable selector-attr selector-class selector-id"),
        (.string, "regexp string"),
        (.variable, "built_in symbol"),
        (.comment, "comment code formula"),
        (.entityTag, "name quote selector-tag selector-pseudo"),
        (.heading, "section"),
        (.list, "bullet"),
    ]
    for (kind, scopes) in named {
        for s in scopes.split(separator: " ") { m[String(s)] = .some(kind) }
    }
    return m
}()

/// Reads highlight.js output (`<span class="hljs-…">`, five escaped characters) back into spans of `line`.
/// Output that does not spell `line` exactly yields no spans.
func syntaxSpans(html: String, line: String) -> [SyntaxSpan] {
    var pieces: [(text: String, kind: SyntaxKind?)] = []
    var stack: [SyntaxKind?] = []
    var rest = html[...]
    let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#x27;": "'"]
    func add(_ s: String) {
        let kind = stack.last ?? nil
        if let last = pieces.last, last.kind == kind { pieces[pieces.count - 1].text += s } else { pieces.append((s, kind)) }
    }
    while let c = rest.first {
        if rest.hasPrefix("</span>") {
            _ = stack.popLast()
            rest = rest.dropFirst(7)
        } else if rest.hasPrefix("<span class=\""), let end = rest.firstIndex(of: ">") {
            let classes = rest[rest.index(rest.startIndex, offsetBy: 13)..<rest.index(before: end)].split(separator: " ")
            let name = classes.first.map { String($0.dropFirst("hljs-".count)) } ?? ""
            // `variable language_` is `self`/`this`, a keyword in github.css.
            let kind: SyntaxKind?? = classes.contains("language_") ? .some(.keyword) : scopeKinds[name]
            stack.append(kind ?? (stack.last ?? nil))
            rest = rest[rest.index(after: end)...]
        } else if c == "&", let (entity, ch) = entities.first(where: { rest.hasPrefix($0.key) }) {
            add(ch)
            rest = rest.dropFirst(entity.count)
        } else {
            add(String(c))
            rest = rest.dropFirst()
        }
    }
    guard pieces.map(\.text).joined() == line, pieces.reduce(0, { $0 + $1.text.count }) == line.count else { return [] }
    var out: [SyntaxSpan] = []
    var at = 0
    for p in pieces {
        if let kind = p.kind { out.append(SyntaxSpan(range: at..<at + p.text.count, kind: kind)) }
        at += p.text.count
    }
    return out
}
