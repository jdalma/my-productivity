import Testing
@testable import TowerCore

private func marked(_ old: [String], _ new: [String]) -> [[Range<Int>]] {
    var lines = old.map { DiffLine(kind: .removed, old: 1, new: nil, text: $0) }
        + new.map { DiffLine(kind: .added, old: nil, new: 1, text: $0) }
    markWordChanges(&lines)
    return lines.map(\.changes)
}

private func cut(_ s: String, _ rs: [Range<Int>]) -> [String] {
    let cs = Array(s)
    return rs.map { String(cs[$0]) }
}

@Test func onlyTheChangedArgumentIsMarked() {
    #expect(marked(["foo(a)"], ["foo(b)"]) == [[4..<5], [4..<5]])
}

@Test func runsPairFirstWithFirstAndLeaveTheRestUnmarked() {
    let m = marked(["let x = 1", "let y = 2"], ["let x = 3"])
    #expect(m == [[8..<9], [], [8..<9]])
}

@Test func unrelatedLinesAreNotMarked() {
    #expect(marked(["return foo(bar)"], ["let x = 1"]) == [[], []])
    #expect(marked(["    a"], ["    b"]) == [[], []])  // shared indentation alone is not similarity
}

@Test func rangesNeverSplitHangulOrEmoji() {
    let a = "상태 아이콘 ✳️ 모양 구분", b = "상태 아이콘 👍🏽 색상 구분"
    let m = marked([a], [b])
    #expect(cut(a, m[0]) == ["✳️", "모양"])
    #expect(cut(b, m[1]) == ["👍🏽", "색상"])
}

@Test func parsedDiffCarriesTheMarks() {
    let text = """
    diff --git a/f.swift b/f.swift
    --- a/f.swift
    +++ b/f.swift
    @@ -1,2 +1,2 @@
     keep
    -call(old)
    +call(new)
    """
    var lines = parseUnifiedDiff(text)[0].lines
    #expect(lines.allSatisfy { $0.changes.isEmpty })  // marking waits for the per-file cap
    markWordChanges(&lines)
    #expect(lines.map(\.changes) == [[], [], [5..<8], [5..<8]])
}

/// About 1000 tokens a line, both ends changed: no common head or tail, so the pair exceeds the
/// 10,000-cell table and is left unmarked, and 1000 such pairs stay fast.
@Test func longRewrittenLinesAreSkippedQuickly() async {
    let words = (0..<500).map { "w\($0)" }
    let old = words.joined(separator: " ")
    var swapped = words
    swapped[0] = "first"; swapped[499] = "last"; swapped.swapAt(200, 300)
    let new = swapped.joined(separator: " ")
    let elapsed = await Task.detached { () -> Duration in
        var lines = Array(repeating: DiffLine(kind: .removed, old: 1, new: nil, text: old), count: 1000)
            + Array(repeating: DiffLine(kind: .added, old: nil, new: 1, text: new), count: 1000)
        let t = ContinuousClock().measure { markWordChanges(&lines) }
        #expect(lines.allSatisfy { $0.changes.isEmpty })
        return t
    }.value
    print("longRewrittenLinesAreSkippedQuickly: \(elapsed)")
    #expect(elapsed < .seconds(4))  // debug build bound with room for a loaded machine (R45a: 2.1-2.2 s at load 11); release is reported separately
}

@Test func contextBetweenRunsBreaksThePairing() {
    var lines = [
        DiffLine(kind: .removed, old: 1, new: nil, text: "a(1)"),
        DiffLine(kind: .context, old: 2, new: 1, text: "mid"),
        DiffLine(kind: .added, old: nil, new: 2, text: "a(2)"),
    ]
    markWordChanges(&lines)
    #expect(lines.allSatisfy { $0.changes.isEmpty })
}
