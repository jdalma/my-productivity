import Foundation
import TowerCore

// --once: one board snapshot as JSON, the same shape as `control-tower --once`.
// --count: the my-turn count for a tmux status badge; prints nothing when zero.
// --history [--limit N]: interactive Claude Code / Codex sessions on disk as JSON, newest first.
// --diff <dir>: how the git workspace at <dir> differs from its base branch, as JSON.
let args = Array(CommandLine.arguments.dropFirst())

func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
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

    enum CodingKeys: String, CodingKey {
        case toplevel, base, untracked
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
    try printJSON(DiffSummary(toplevel: d.toplevel, base: ref, mergeBase: mergeBase,
                              committedFiles: d.committed?.files.count, committedAdded: d.committed?.added,
                              committedRemoved: d.committed?.removed, uncommittedFiles: d.uncommitted.files.count,
                              untracked: d.uncommitted.untracked))
} else {
    FileHandle.standardError.write(Data("usage: tower-cli --once | --count | --history [--limit N] | --diff <dir>\n".utf8))
    exit(2)
}
