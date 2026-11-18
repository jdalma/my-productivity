/// One row of the side-by-side view, as indices into `FileDiff.lines`.
public enum SplitRow: Hashable, Sendable {
    /// A hunk header across both sides.
    case hunk(Int)
    /// Old line on the left, new on the right; nil is an empty cell. A context line sits on both sides.
    case pair(old: Int?, new: Int?)
}

/// GitHub's split layout: context on both sides, the n-th removed line beside the n-th added line of a
/// change run (the pairs word changes compare), the longer side's rest beside empty cells.
func splitRows(_ lines: [DiffLine], _ runs: [ChangeRun]) -> [SplitRow] {
    var rows: [SplitRow] = []
    var next = runs.makeIterator()
    var run = next.next()
    var i = 0
    while i < lines.count {
        // runs come in line order; each starts at its first removed line, or its first added one
        if let r = run, r.removed.lowerBound == i {
            run = next.next()
            for k in 0..<max(r.removed.count, r.added.count) {
                rows.append(.pair(old: k < r.removed.count ? r.removed.lowerBound + k : nil,
                                  new: k < r.added.count ? r.added.lowerBound + k : nil))
            }
            i = r.added.upperBound
            continue
        }
        rows.append(lines[i].kind == .hunk ? .hunk(i) : .pair(old: i, new: i))
        i += 1
    }
    return rows
}
