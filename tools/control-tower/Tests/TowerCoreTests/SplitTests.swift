import Testing
@testable import TowerCore

private func file(_ body: String) -> FileDiff {
    let text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n" + body
    return ParseMemo().files(.uncommitted, text, 2000)[0]
}

@Test func contextPairAndLeftoverMakeFourRowsWithTheirNumbers() {
    let f = file("@@ -1,4 +1,3 @@\n keep\n-call(a)\n-gone\n+call(b)\n tail\n")
    #expect(f.split == [.hunk(0), .pair(old: 1, new: 1), .pair(old: 2, new: 4), .pair(old: 3, new: nil), .pair(old: 5, new: 5)])
    let l = f.lines
    #expect((l[1].old, l[1].new) == (1, 1))
    #expect((l[2].old, l[4].new) == (2, 2))  // the pair: old line 2 beside new line 2
    #expect(l[3].old == 3)                   // removed, an empty cell beside it
    #expect((l[5].old, l[5].new) == (4, 3))
}

@Test func aNewFileFillsOnlyTheRightSide() {
    let f = file("@@ -0,0 +1,2 @@\n+one\n+two\n")
    #expect(f.split == [.hunk(0), .pair(old: nil, new: 1), .pair(old: nil, new: 2)])
    let d = file("@@ -1,2 +0,0 @@\n-one\n-two\n")
    #expect(d.split == [.hunk(0), .pair(old: 1, new: nil), .pair(old: 2, new: nil)])
}

/// Side-by-side rows and word changes come from the same pairs: a row holding both sides is exactly
/// a pair whose lines carry marks, and no marked line sits beside an empty cell.
@Test func splitPairsAreTheWordDiffPairs() {
    let f = file("@@ -1,5 +1,5 @@\n-x(1)\n-y(1)\n-z\n+x(2)\n+y(2)\n c\n+only(new)\n-k(1)\n+k(2)\n")
    for row in f.split {
        guard case .pair(let o?, let n?) = row, o != n else {
            if case .pair(let o, let n) = row { for i in [o, n].compactMap({ $0 }) where f.lines[i].kind != .context { #expect(f.lines[i].changes.isEmpty) } }
            continue
        }
        #expect(!f.lines[o].changes.isEmpty && !f.lines[n].changes.isEmpty, "\(o) \(n)")
    }
    #expect(f.split.count == 1 + 3 + 1 + 1 + 1)  // hunk, run of 3/2, context, added-only, run of 1/1
}

@Test func twoThousandLinesSplitQuickly() async {
    var body = "@@ -1,2000 +1,2000 @@\n"
    for i in 0..<500 { body += " c\(i)\n-old(\(i))\n+new(\(i))\n+more\n" }
    let lines = parseUnifiedDiff("diff --git a/f b/f\n" + body)[0].lines
    let t = await Task.detached { ContinuousClock().measure { _ = splitRows(lines, changeRuns(lines)) } }.value
    print("twoThousandLinesSplitQuickly: \(lines.count) lines \(t)")
    #expect(t < .seconds(1))
}
