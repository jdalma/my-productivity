import Foundation

// Code navigation from the diff: where a Command-click lands, which word it hit, and the back/forward
// history of the file view. Read-only; the working tree is read, never written.

/// A line of a file in the workspace's working tree, `path` relative to the repo toplevel.
public struct CodeLocation: Hashable, Sendable {
    public var path: String
    public var line: Int

    public init(path: String, line: Int) {
        self.path = path
        self.line = line
    }
}

/// Back and forward through opened locations, like a browser. Position 0 is the diff itself.
public struct CodeHistory: Equatable, Sendable {
    private var entries: [CodeLocation] = []
    private var index = 0

    public init() {}

    /// nil: the diff is shown.
    public var current: CodeLocation? { index == 0 ? nil : entries[index - 1] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index < entries.count }

    /// Opens `location` after the current one, dropping everything forward of it. `from` replaces the
    /// current entry first, so going back returns to the line the jump started from.
    public mutating func open(_ location: CodeLocation, from: CodeLocation? = nil) {
        if let from, index > 0 { entries[index - 1] = from }
        entries = Array(entries.prefix(index)) + [location]
        index = entries.count
    }

    public mutating func back() { if canGoBack { index -= 1 } }
    public mutating func forward() { if canGoForward { index += 1 } }
    /// Back to the diff; forward still returns to where the file view was.
    public mutating func toDiff() { index = 0 }
}

/// The working-tree line `lines[i]` stands for. Added and context lines: their new number. A removed
/// line is not in the working tree: the new-side line where it was, one past the hunk's last new-side
/// line before it. A hunk header: its new start. Never below 1.
public func fileLine(at i: Int, in lines: [DiffLine]) -> Int {
    if let n = lines[i].new { return n }
    var j = i
    while lines[j].kind != .hunk {
        guard j > 0 else { return 1 }
        j -= 1
        if let n = lines[j].new { return n + 1 }
    }
    return max(1, hunkStarts(lines[j].text).1)
}

/// A word of a line, `range` in Character offsets.
public struct CodeWord: Hashable, Sendable {
    public var name: String
    public var range: Range<Int>
}

/// The Java/Kotlin identifier holding Character `offset` of `line`: letters, digits, `_` and, for Java,
/// `$`, not starting with a digit. Kotlin names never hold `$`, so `"Hello $user"` gives `user`. Purely
/// lexical: a word inside a string or a comment counts too. Backticked Kotlin names are not one name.
public func identifier(in line: String, at offset: Int, dollar: Bool = true) -> CodeWord? {
    let chars = Array(line)
    func part(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || (dollar && c == "$") }
    guard chars.indices.contains(offset), part(chars[offset]) else { return nil }
    var lo = offset, hi = offset + 1
    while lo > 0, part(chars[lo - 1]) { lo -= 1 }
    while hi < chars.count, part(chars[hi]) { hi += 1 }
    guard !chars[lo].isNumber else { return nil }
    return CodeWord(name: String(chars[lo..<hi]), range: lo..<hi)
}

/// A working-tree file as the file view shows it.
public enum WorkingFile: Hashable, Sendable {
    /// Gone from the working tree (a deleted file), or not a regular readable file.
    case missing
    case binary
    /// At most `lineLimit` lines around the asked-for line, each a context line numbered on the new
    /// side; `total` is the file's line count.
    case text(lines: [DiffLine], total: Int)
}

/// Reads `path` under `toplevel`, keeping the window of `lineLimit` lines that holds `line`.
/// Binary as git decides it: a NUL in the first 8000 bytes; text that is not UTF-8 counts too.
public func readWorkingFile(toplevel: String, path: String, around line: Int, lineLimit: Int = 2000) -> WorkingFile {
    let url = URL(fileURLWithPath: toplevel).appending(path: path)
    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
          let data = try? Data(contentsOf: url) else { return .missing }
    guard !data.prefix(8000).contains(0), let text = String(data: data, encoding: .utf8) else { return .binary }
    // "\r\n" is one Character: split by Character, a CRLF file would be one line
    var all = text.components(separatedBy: "\n")
    if text.utf8.last == UInt8(ascii: "\n") { all.removeLast() }
    let total = all.count
    let first = max(1, min(line - lineLimit / 2, total - lineLimit + 1))
    let shown = all.dropFirst(first - 1).prefix(lineLimit)
    let lines = shown.enumerated().map { DiffLine(kind: .context, old: nil, new: first + $0.offset, text: String($0.element)) }
    return .text(lines: lines, total: total)
}
