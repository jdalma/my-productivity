import Foundation

// Search in a worktree (G4 I10): text by `git grep`, files by a fuzzy match over `workspaceFiles`. Both take a folder
// inside a repository and answer paths from that folder, so a caller joins them to the folder it gave.

public struct SearchHit: Hashable, Sendable {
    /// From the folder searched.
    public var path: String
    public var line: Int
    /// The line, cut at `searchLineLimit` characters.
    public var text: String

    public init(path: String, line: Int, text: String) {
        (self.path, self.line, self.text) = (path, line, text)
    }
}

public struct SearchResult: Equatable, Sendable {
    public var hits: [SearchHit]
    /// There were more hits than `hits` holds.
    public var more: Bool

    public init(hits: [SearchHit], more: Bool) {
        (self.hits, self.more) = (hits, more)
    }
}

/// The longest line a hit shows: a minified file's line is not worth more.
let searchLineLimit = 400

/// The lines of `root` (a folder in a repository) that hold `query`, as typed (no pattern) and in any case: tracked
/// files and untracked ones git does not ignore, binary files left out. At most `limit` hits; nil when git fails
/// (`root` is no repository). An empty query finds nothing.
public func searchText(_ query: String, in root: String, limit: Int = 500) -> SearchResult? {
    guard !query.isEmpty, !query.contains("\n") else { return SearchResult(hits: [], more: false) }
    // A one-letter query in a large repository prints hundreds of megabytes (orca: 415 MB in 49 s): reading stops at
    // `cap`, far past what `limit` lines take, and git ends at its next write. git prints a line whole, so the cap
    // is no less than 2 MB: a minified file's line among the first hits leaves room for the hits after it (R25 S1).
    let cap = max(limit * (searchLineLimit + 200), 2 << 20)
    // `-z`: path NUL line NUL text, the path as it is. `-e`: a query that starts with `-` is no option.
    guard let r = try? git(.grep, ["-n", "-z", "-I", "--untracked", "-F", "-i", "-e", query], in: root, maxOutput: cap) else { return nil }
    let capped = r.stdout.utf8.count >= cap
    // 0: found, 1: nothing found. A capped run ends by a failed write, with a status that says nothing.
    guard capped || r.status == 0 || r.status == 1 else { return nil }
    let hits = parseGrep(r.stdout)
    return SearchResult(hits: Array(hits.prefix(limit)), more: capped || hits.count > limit)
}

/// The hits of `git grep -n -z` output: `path NUL line NUL text LF` each, a CR before the LF not part of the text.
/// The last piece without its line end (output cut off) is left out, unless its text is already longer than a hit
/// shows: then it is a hit, cut like any long line.
func parseGrep(_ out: String) -> [SearchHit] {
    // By byte: a Character holds CR LF as one, so a search for "\n" in the String passes every CRLF line end (R25 M1).
    let b = Array(out.utf8)
    func text(_ range: Range<Int>) -> String {
        // no more bytes than `searchLineLimit` characters can take: a line of megabytes is not decoded whole
        String(String(decoding: b[range.prefix(searchLineLimit * 4)], as: UTF8.self).prefix(searchLineLimit))
    }
    var hits: [SearchHit] = []
    var at = 0
    while let pathEnd = b[at...].firstIndex(of: 0), let numberEnd = b[(pathEnd + 1)...].firstIndex(of: 0),
          let line = Int(String(decoding: b[(pathEnd + 1)..<numberEnd], as: UTF8.self)) {
        let path = String(decoding: b[at..<pathEnd], as: UTF8.self)
        guard var lineEnd = b[(numberEnd + 1)...].firstIndex(of: 0x0A) else {
            let tail = text((numberEnd + 1)..<b.count)
            if tail.count == searchLineLimit { hits.append(SearchHit(path: path, line: line, text: tail)) }
            break
        }
        at = lineEnd + 1
        if lineEnd > numberEnd + 1, b[lineEnd - 1] == 0x0D { lineEnd -= 1 }
        hits.append(SearchHit(path: path, line: line, text: text((numberEnd + 1)..<lineEnd)))
    }
    return hits
}

// MARK: - Quick open

/// How well `path` answers `query` typed to open a file: nil unless every character of the query is in the path in
/// that order, in any case (spaces in the query are skipped). Higher is better: letters in a row, at the start of a
/// word (after `/ . _ -`, or a capital after a small letter) and in the file name count more, a long path less.
// ponytail: the leftmost match from the file name (else from the path's start), not the best alignment, and by
// byte: a query of Hangul may match across two characters. A scoring matrix (fzf's) if the order disappoints.
public func fuzzyScore(_ query: String, _ path: String) -> Int? {
    let q = query.utf8.filter { $0 != 0x20 }.map(lowered)
    guard !q.isEmpty else { return nil }
    let p = Array(path.utf8)
    let name = (p.lastIndex(of: 0x2F).map { $0 + 1 }) ?? 0
    if let s = matchScore(q, p, from: name) {
        // the query as one piece of the file name: what a typed name most often is
        return s + 20 + (holds(p, q, from: name) ? 30 : 0) - p.count / 8
    }
    return matchScore(q, p, from: 0).map { $0 - p.count / 8 }
}

/// The files that answer `query`, best first, then the shorter path, then by name; at most `limit`.
public func quickOpen(_ query: String, files: [String], limit: Int = 50) -> [String] {
    files.compactMap { f in fuzzyScore(query, f).map { (score: $0, path: f) } }
        .sorted { ($1.score, $0.path.utf8.count, $0.path) < ($0.score, $1.path.utf8.count, $1.path) }
        .prefix(limit).map(\.path)
}

private func lowered(_ b: UInt8) -> UInt8 { b >= 0x41 && b <= 0x5A ? b + 0x20 : b }

private func matchScore(_ q: [UInt8], _ p: [UInt8], from start: Int) -> Int? {
    var score = 0, i = start, last = -2
    for c in q {
        while i < p.count, lowered(p[i]) != c { i += 1 }
        guard i < p.count else { return nil }
        score += 1
        if i == last + 1 { score += 8 }
        if i == start || isBreak(p[i - 1]) || (isSmall(p[i - 1]) && isCapital(p[i])) { score += 6 }
        last = i
        i += 1
    }
    return score
}

private func holds(_ p: [UInt8], _ q: [UInt8], from start: Int) -> Bool {
    guard p.count - start >= q.count else { return false }
    return (start...(p.count - q.count)).contains { at in (0..<q.count).allSatisfy { lowered(p[at + $0]) == q[$0] } }
}

private func isBreak(_ b: UInt8) -> Bool { b == 0x2F || b == 0x2E || b == 0x5F || b == 0x2D }
private func isSmall(_ b: UInt8) -> Bool { b >= 0x61 && b <= 0x7A }
private func isCapital(_ b: UInt8) -> Bool { b >= 0x41 && b <= 0x5A }
