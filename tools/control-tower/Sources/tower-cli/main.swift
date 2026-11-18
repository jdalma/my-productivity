import Foundation
import TowerCore

// --once: one board snapshot as JSON, the same shape as `control-tower --once`.
// --count: the my-turn count for a tmux status badge; prints nothing when zero.
// --history [--limit N]: interactive Claude Code / Codex sessions on disk as JSON, newest first.
// --diff <dir>: how the git workspace at <dir> differs from its base branch, as JSON.
// --usage [today|week|month] [--timing]: Claude Code token usage for the period (week when not given) as JSON, after
//   reading what is new in the transcripts. --timing: the seconds and the files of that reading on stderr, and of
//   one more right after it.
let args = Array(CommandLine.arguments.dropFirst())

func printJSON(_ value: some Encodable, dates: JSONEncoder.DateEncodingStrategy = .deferredToDate) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = dates
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

/// `--diff` output. Optional fields print as `null`, like the rest of the CLI's JSON.
struct DiffSummary: Encodable {
    var toplevel: String
    var base: String?
    var mergeBase: String?
    var committedFiles: Int?
    var committedAdded: Int?
    var committedRemoved: Int?
    var uncommittedFiles: Int
    var untracked: [String]
    var totalAdded: Int?
    var totalRemoved: Int?

    enum CodingKeys: String, CodingKey {
        case toplevel, base, untracked
        case totalAdded = "added", totalRemoved = "removed"
        case mergeBase = "merge_base"
        case committedFiles = "committed_files", committedAdded = "committed_added", committedRemoved = "committed_removed"
        case uncommittedFiles = "uncommitted_files"
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toplevel, forKey: .toplevel)
        try c.encode(base, forKey: .base)
        try c.encode(mergeBase, forKey: .mergeBase)
        try c.encode(committedFiles, forKey: .committedFiles)
        try c.encode(committedAdded, forKey: .committedAdded)
        try c.encode(committedRemoved, forKey: .committedRemoved)
        try c.encode(uncommittedFiles, forKey: .uncommittedFiles)
        try c.encode(untracked, forKey: .untracked)
        try c.encode(totalAdded, forKey: .totalAdded)
        try c.encode(totalRemoved, forKey: .totalRemoved)
    }
}

if args.contains("--count") {
    let n = myTurnCount(await collect())
    if n > 0 { print(n) }
} else if args.contains("--once") {
    try printJSON(await collect())
} else if args.contains("--history") {
    let limit = args.firstIndex(of: "--limit").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil }
    let history = await collectHistory(board: await collect())
    try printJSON(limit.map { Array(history.prefix($0)) } ?? history)
} else if let i = args.firstIndex(of: "--diff"), args.indices.contains(i + 1) {
    guard case .diff(let d) = workspaceDiff(at: args[i + 1], pinnedBase: nil) else {
        FileHandle.standardError.write(Data("not a git repository: \(args[i + 1])\n".utf8))
        exit(1)
    }
    var ref: String?, mergeBase: String?
    if case .resolved(let r, let m) = d.base { (ref, mergeBase) = (r, m) }
    let total = diffTotal(at: args[i + 1])
    try printJSON(DiffSummary(toplevel: d.toplevel, base: ref, mergeBase: mergeBase,
                              committedFiles: d.committed?.files.count, committedAdded: d.committed?.added,
                              committedRemoved: d.committed?.removed, uncommittedFiles: d.uncommitted.files.count,
                              untracked: d.uncommitted.untracked, totalAdded: total?.added, totalRemoved: total?.removed))
} else if let i = args.firstIndex(of: "--usage") {
    let named = args.indices.contains(i + 1) && !args[i + 1].hasPrefix("--") ? args[i + 1] : nil
    guard let period = named.map(UsagePeriod.init(rawValue:)) ?? .week else {
        FileHandle.standardError.write(Data("--usage takes today, week or month, not '\(named ?? "")'\n".utf8))
        exit(2)
    }
    let ledger = UsageLedger.shared
    for _ in 0..<(args.contains("--timing") ? 2 : 1) {
        let started = Date()
        await ledger.refresh()
        if args.contains("--timing") {
            let files = ledger.report(.today).progress.filesTotal
            FileHandle.standardError.write(Data(String(format: "read %.2fs files %d\n", Date().timeIntervalSince(started), files).utf8))
        }
    }
    try printJSON(ledger.report(period), dates: .iso8601)
} else {
    FileHandle.standardError.write(Data("usage: tower-cli --once | --count | --history [--limit N] | --diff <dir> | --usage [today|week|month] [--timing]\n".utf8))
    exit(2)
}
