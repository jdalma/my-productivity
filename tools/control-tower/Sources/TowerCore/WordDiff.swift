/// In-line change highlighting: which parts of a removed line and the added line that replaced it differ.
/// Ranges are Character offsets into `DiffLine.text`, so a Hangul syllable or an emoji is never cut.

/// A run of removed lines and the run of added lines right after it (either may be empty), as line indices.
/// Their n-th lines pair: word changes compare them, and the split view puts them side by side.
struct ChangeRun: Equatable {
    var removed: Range<Int>
    var added: Range<Int>
}

func changeRuns(_ lines: [DiffLine]) -> [ChangeRun] {
    var runs: [ChangeRun] = []
    var i = 0
    while i < lines.count {
        guard lines[i].kind == .removed || lines[i].kind == .added else { i += 1; continue }
        var j = i
        while j < lines.count, lines[j].kind == .removed { j += 1 }
        var k = j
        while k < lines.count, lines[k].kind == .added { k += 1 }
        runs.append(ChangeRun(removed: i..<j, added: j..<k))
        i = k
    }
    return runs
}

/// Marks the changed ranges of every pair similar enough to compare. Unpaired lines stay unmarked.
func markWordChanges(_ lines: inout [DiffLine], _ runs: [ChangeRun]) {
    for run in runs {
        for (o, n) in zip(run.removed, run.added) {
            if let (old, new) = changedRanges(lines[o].text, lines[n].text) {
                lines[o].changes = old
                lines[n].changes = new
            }
        }
    }
}

func markWordChanges(_ lines: inout [DiffLine]) { markWordChanges(&lines, changeRuns(lines)) }

/// Word-level differences of two lines, or nil when they share under half of their non-space characters
/// (a rewrite, where highlighting everything says nothing) or the comparison would be too large.
func changedRanges(_ a: String, _ b: String) -> (old: [Range<Int>], new: [Range<Int>])? {
    let x = tokens(a), y = tokens(b)
    guard let (keepX, keepY) = commonTokens(x, y) else { return nil }
    let solid = { (ts: [Token]) in ts.reduce(0) { $0 + ($1.space ? 0 : $1.range.count) } }
    let shared = zip(x, keepX).reduce(0) { $0 + ($1.1 && !$1.0.space ? $1.0.range.count : 0) }
    let total = solid(x) + solid(y)
    guard total > 0, shared * 4 >= total else { return nil }  // 2·shared / (a + b) ≥ 1/2
    let old = unkept(x, keepX), new = unkept(y, keepY)
    return old.isEmpty && new.isEmpty ? nil : (old, new)
}

private struct Token {
    var text: Substring
    var range: Range<Int>
    var space: Bool
}

private enum Class { case word, space, other }

/// Words (letters, digits, `_`), whitespace runs, and every other character on its own.
/// An ASCII line, most code, walks bytes: there each byte is one Character, and that is 5x faster.
private func tokens(_ s: String) -> [Token] {
    if s.utf8.allSatisfy({ $0 < 0x80 }) {
        return tokens(s, zip(s.utf8.indices, s.utf8)) { b in
            switch b {
            case 0x30...0x39, 0x41...0x5a, 0x61...0x7a, 0x5f: .word
            case 0x20, 0x09...0x0d: .space
            default: .other
            }
        }
    }
    return tokens(s, zip(s.indices, s)) { c in
        c.isLetter || c.isNumber || c == "_" ? .word : c.isWhitespace ? .space : .other
    }
}

private func tokens<Units: Sequence<(String.Index, U)>, U>(_ s: String, _ units: Units, _ cls: (U) -> Class) -> [Token] {
    var out: [Token] = []
    var start = s.startIndex, offset = 0, startOffset = 0
    var current: Class?
    for (idx, c) in units {
        let k = cls(c)
        if let cur = current, cur != k || k == .other {
            out.append(Token(text: s[start..<idx], range: startOffset..<offset, space: cur == .space))
            start = idx
            startOffset = offset
        }
        current = k
        offset += 1
    }
    if let cur = current { out.append(Token(text: s[start...], range: startOffset..<offset, space: cur == .space)) }
    return out
}

/// Which tokens of each side belong to a longest common subsequence. Common head and tail are taken
/// first; the middle runs an O(n·m) table, refused past 10,000 cells (about 100 changed tokens a side),
/// so a diff of long rewritten lines stays in the milliseconds.
private func commonTokens(_ x: [Token], _ y: [Token]) -> ([Bool], [Bool])? {
    var keepX = [Bool](repeating: false, count: x.count), keepY = [Bool](repeating: false, count: y.count)
    var head = 0
    while head < x.count, head < y.count, x[head].text == y[head].text {
        keepX[head] = true; keepY[head] = true; head += 1
    }
    var tail = 0
    while tail < x.count - head, tail < y.count - head, x[x.count - 1 - tail].text == y[y.count - 1 - tail].text {
        keepX[x.count - 1 - tail] = true; keepY[y.count - 1 - tail] = true; tail += 1
    }
    let n = x.count - head - tail, m = y.count - head - tail
    guard n > 0, m > 0 else { return (keepX, keepY) }
    guard n * m <= 10_000 else { return nil }
    // lcs[i][j] = LCS length of x[head+i...] and y[head+j...] (middle part only)
    var lcs = [Int32](repeating: 0, count: (n + 1) * (m + 1))
    for i in stride(from: n - 1, through: 0, by: -1) {
        for j in stride(from: m - 1, through: 0, by: -1) {
            lcs[i * (m + 1) + j] = x[head + i].text == y[head + j].text
                ? lcs[(i + 1) * (m + 1) + j + 1] + 1
                : max(lcs[(i + 1) * (m + 1) + j], lcs[i * (m + 1) + j + 1])
        }
    }
    var i = 0, j = 0
    while i < n, j < m {
        if x[head + i].text == y[head + j].text {
            keepX[head + i] = true; keepY[head + j] = true; i += 1; j += 1
        } else if lcs[(i + 1) * (m + 1) + j] >= lcs[i * (m + 1) + j + 1] {
            i += 1
        } else {
            j += 1
        }
    }
    return (keepX, keepY)
}

/// The ranges of tokens outside the common subsequence, neighbors merged.
private func unkept(_ ts: [Token], _ keep: [Bool]) -> [Range<Int>] {
    var out: [Range<Int>] = []
    for (t, k) in zip(ts, keep) where !k {
        if let last = out.last, last.upperBound == t.range.lowerBound {
            out[out.count - 1] = last.lowerBound..<t.range.upperBound
        } else {
            out.append(t.range)
        }
    }
    return out
}
