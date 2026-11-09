import Foundation

// A workspace's changes against its base branch: committed (`<base>...HEAD`) and uncommitted
// (`git diff HEAD` plus untracked files, read as all-added diffs). Read-only: git runs only through `git(_:_:in:)`.

/// The only git subcommands TowerCore may run. Read-only by construction.
enum GitRead: String, CaseIterable {
    case diff, lsFiles = "ls-files", mergeBase = "merge-base", revParse = "rev-parse"
    case symbolicRef = "symbolic-ref", forEachRef = "for-each-ref"
    /// The uncommitted diff. Porcelain `git diff HEAD` refreshes and rewrites the index
    /// even under `--no-optional-locks`; this plumbing command never does.
    case diffIndex = "diff-index"
}

/// `-C dir` with the argument list as argv elements, never a shell. `--no-optional-locks` keeps
/// a status-like read from taking the index lock; `core.quotepath=off` (set through the environment,
/// so argv has no config flag) keeps paths unescaped.
func git(_ cmd: GitRead, _ args: [String], in dir: String) throws -> CommandResult {
    try runCommand(["git", "--no-optional-locks", "-C", dir, cmd.rawValue] + args,
                   timeout: 20, env: ["GIT_OPTIONAL_LOCKS": "0", "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.quotepath", "GIT_CONFIG_VALUE_0": "off"])
}

/// Stdout of a successful run; nil when git is missing or exits non-zero.
func out(_ cmd: GitRead, _ args: [String], in dir: String) -> String? {
    guard let r = try? git(cmd, args, in: dir), r.status == 0 else { return nil }
    return r.stdout
}

public struct DiffLine: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case hunk, context, added, removed }
    public var kind: Kind
    public var old: Int?
    public var new: Int?
    /// The line without its `+`/`-`/space marker; the whole `@@ … @@` header for a hunk.
    public var text: String
    /// Character offsets of `text` that differ from the paired line, computed once at parse time (WordDiff.swift).
    public var changes: [Range<Int>] = []
    /// Syntax colors, filled after parsing by `highlighted(_:)` (Syntax.swift).
    public var syntax: [SyntaxSpan] = []
}

public struct FileDiff: Hashable, Sendable {
    public var path: String
    public var added: Int
    public var removed: Int
    public var binary: Bool
    public var lines: [DiffLine]
    /// Lines past the per-file limit, left out of `lines`.
    public var hiddenLines = 0
    /// The side-by-side rows of `lines`, computed with the word changes from the same pairs.
    public var split: [SplitRow] = []
}

public struct DiffSection: Hashable, Sendable {
    public var files: [FileDiff]
    public var untracked: [String]
    /// Untracked files read as all-added diffs, in `untracked` order. A path without one here (a symlink,
    /// an unreadable or oversized file, or one past `newFileLimit`) shows as a path only.
    public var newFiles: [FileDiff] = []
    /// Counts untracked lines too, as `git diff` does after `git add -N`.
    public var added: Int { (files + newFiles).reduce(0) { $0 + $1.added } }
    public var removed: Int { files.reduce(0) { $0 + $1.removed } }
}

public enum BaseChoice: Hashable, Sendable {
    case resolved(ref: String, mergeBase: String)
    /// The pinned base no longer exists. Never replaced by another base.
    case pinnedMissing(String)
    case none
}

public struct WorkspaceDiff: Hashable, Sendable {
    public var toplevel: String
    public var base: BaseChoice
    /// nil unless the base resolved.
    public var committed: DiffSection?
    public var uncommitted: DiffSection
}

public enum WorkspaceDiffResult: Hashable, Sendable {
    case notARepo
    case diff(WorkspaceDiff)
}

// MARK: - Entry points

public func repoToplevel(at path: String) -> String? {
    out(.revParse, ["--show-toplevel"], in: path)?.trimmed.nonEmpty
}

/// `lineLimit` caps each file on its own: a large file never empties the files after it.
public func workspaceDiff(at path: String, pinnedBase: String?, lineLimit: Int = 2000) -> WorkspaceDiffResult {
    guard let top = repoToplevel(at: path) else { return .notARepo }
    let base = resolveBase(top: top, pinned: pinnedBase)

    var committed: DiffSection?
    if case .resolved(let ref, _) = base {
        committed = DiffSection(files: parseMemo.files(.committed, diffText(.diff, ["\(ref)...HEAD"], top), lineLimit), untracked: [])
    }
    let files = parseMemo.files(.uncommitted, diffText(.diffIndex, ["-p", "HEAD"], top), lineLimit)
    let untracked = (out(.lsFiles, ["--others", "--exclude-standard", "-z"], in: top) ?? "")
        .split(separator: "\0").map(String.init)
    return .diff(WorkspaceDiff(toplevel: top, base: base, committed: committed,
                               uncommitted: DiffSection(files: files, untracked: untracked,
                                                        newFiles: newFileMemo.files(top: top, paths: untracked, limit: lineLimit))))
}

/// Local heads and remote-tracking branches, for the base picker. Never `origin/HEAD`.
public func baseCandidates(toplevel: String) -> [String] {
    let refs = (out(.forEachRef, ["--format=%(refname)", "refs/heads", "refs/remotes"], in: toplevel) ?? "")
        .split(separator: "\n").map(String.init)
    return refs.compactMap { ref in
        if let b = ref.stripPrefix("refs/heads/") { return b }
        guard let r = ref.stripPrefix("refs/remotes/"), !r.hasSuffix("/HEAD") else { return nil }
        return r
    }.sorted()
}

private extension String {
    func stripPrefix(_ p: String) -> String? { hasPrefix(p) ? String(dropFirst(p.count)) : nil }
}

// MARK: - Base resolution

private func diffText(_ cmd: GitRead, _ revs: [String], _ top: String) -> String {
    out(cmd, ["--no-color", "--no-ext-diff", "--no-textconv", "-M", "--src-prefix=a/", "--dst-prefix=b/"] + revs + ["--"], in: top) ?? ""
}

private func hasRef(_ full: String, _ top: String) -> Bool {
    out(.revParse, ["--verify", "--quiet", "\(full)^{commit}"], in: top) != nil
}

private func mergeBase(_ ref: String, _ top: String) -> String? {
    out(.mergeBase, ["HEAD", ref], in: top)?.trimmed.nonEmpty
}

/// Pinned base first and final, exactly the ref that was picked; else origin/HEAD's branch, `main`, `master`.
func resolveBase(top: String, pinned: String?) -> BaseChoice {
    if let pinned {
        guard hasRef("refs/heads/\(pinned)", top) || hasRef("refs/remotes/\(pinned)", top) else { return .pinnedMissing(pinned) }
        return mergeBase(pinned, top).map { .resolved(ref: pinned, mergeBase: $0) } ?? .none
    }
    let head = out(.symbolicRef, ["--quiet", "refs/remotes/origin/HEAD"], in: top)?.trimmed.stripPrefix("refs/remotes/origin/")
    for name in [head, "main", "master"].compactMap({ $0 }) {
        if let b = pickNamed(name, top) { return b }
    }
    return .none
}

/// A branch name `b` exists as `refs/heads/b` and/or `refs/remotes/origin/b`. With both, the ref
/// whose merge-base with HEAD is newer wins; a tie goes to the local one.
private func pickNamed(_ b: String, _ top: String) -> BaseChoice? {
    let local = hasRef("refs/heads/\(b)", top) ? mergeBase(b, top) : nil
    let remote = hasRef("refs/remotes/origin/\(b)", top) ? mergeBase("origin/\(b)", top) : nil
    switch (local, remote) {
    case (let l?, let r?):
        let remoteNewer = l != r && out(.mergeBase, ["--is-ancestor", l, r], in: top) != nil
        return remoteNewer ? .resolved(ref: "origin/\(b)", mergeBase: r) : .resolved(ref: b, mergeBase: l)
    case (let l?, nil): return .resolved(ref: b, mergeBase: l)
    case (nil, let r?): return .resolved(ref: "origin/\(b)", mergeBase: r)
    case (nil, nil): return nil
    }
}

// MARK: - Cap

/// Keeps at most `limit` lines of each file; counts stay whole. Word changes and split rows are computed
/// on the kept lines only, so lines nobody sees cost nothing.
private func cap(_ files: [FileDiff], _ limit: Int) -> [FileDiff] {
    files.map { f in
        var cut = f
        if f.lines.count > limit {
            cut.hiddenLines = f.lines.count - limit
            cut.lines = Array(f.lines.prefix(limit))
        }
        let runs = changeRuns(cut.lines)
        markWordChanges(&cut.lines, runs)
        cut.split = splitRows(cut.lines, runs)
        return cut
    }
}

/// The last parsed, capped and word-marked files of each section's raw text, so a 5 s refresh of an
/// unchanged diff computes nothing.
final class ParseMemo: @unchecked Sendable {
    enum Slot { case committed, uncommitted }
    private let lock = NSLock()
    private var slots: [Slot: (text: String, limit: Int, files: [FileDiff])] = [:]
    /// Read outside the lock, by tests only, after the calls they count have returned.
    private(set) var parses = 0

    func files(_ slot: Slot, _ text: String, _ limit: Int) -> [FileDiff] {
        lock.withLock {
            if let s = slots[slot], s.text == text, s.limit == limit { return s.files }
            parses += 1
            let files = cap(parseUnifiedDiff(text), limit)
            slots[slot] = (text, limit, files)
            return files
        }
    }
}

let parseMemo = ParseMemo()

// MARK: - Untracked files

/// Untracked paths looked at per refresh, and the largest file read; the rest show as paths, so a tree of
/// unignored build output costs a bounded read.
let newFileLimit = 200
let newFileByteLimit = 1 << 20

/// Sendable because every read and write of `byTop` holds `lock`, as in `ParseMemo`.
/// The last diff of each untracked file by toplevel, kept while its size and modification date hold,
/// so a 5 s refresh only stats them.
final class NewFileMemo: @unchecked Sendable {
    private struct Entry { var size: Int, date: Date, limit: Int, file: FileDiff? }
    private let lock = NSLock()
    private var byTop: [String: [String: Entry]] = [:]

    func files(top: String, paths: [String], limit: Int) -> [FileDiff] {
        lock.withLock {
            let old = byTop[top] ?? [:]
            var kept: [String: Entry] = [:]
            for path in paths.prefix(newFileLimit) {
                let full = URL(fileURLWithPath: top).appending(path: path).path
                // attributes of the path itself: a symlink is not followed
                guard let a = try? FileManager.default.attributesOfItem(atPath: full), a[.type] as? FileAttributeType == .typeRegular,
                      let size = a[.size] as? Int, let date = a[.modificationDate] as? Date else { continue }
                if let e = old[path], e.size == size, e.date == date, e.limit == limit { kept[path] = e; continue }
                let data = size <= newFileByteLimit ? try? Data(contentsOf: URL(fileURLWithPath: full)) : nil
                kept[path] = Entry(size: size, date: date, limit: limit,
                                   file: data.flatMap { $0.count <= newFileByteLimit ? newFileDiff(path, $0, limit) : nil })
            }
            byTop[top] = kept
            return paths.prefix(newFileLimit).compactMap { kept[$0]?.file }
        }
    }
}

let newFileMemo = NewFileMemo()

/// A new file as `git diff` shows it: one `@@ -0,0 +1,n @@` hunk of added lines, none when empty.
/// Binary as git decides it: a NUL in the first 8000 bytes; text that is not UTF-8 counts too.
func newFileDiff(_ path: String, _ data: Data, _ limit: Int) -> FileDiff {
    guard !data.prefix(8000).contains(0), let text = String(data: data, encoding: .utf8) else {
        return FileDiff(path: path, added: 0, removed: 0, binary: true, lines: [])
    }
    // "\r\n" is one Character, so a Character split would leave a CRLF file one line; the tracked parser keeps "a\r"
    var all = text.components(separatedBy: "\n")
    if all.last?.isEmpty == true { all.removeLast() }
    guard !all.isEmpty else { return FileDiff(path: path, added: 0, removed: 0, binary: false, lines: []) }
    let hunk = DiffLine(kind: .hunk, old: nil, new: nil, text: "@@ -0,0 +1\(all.count == 1 ? "" : ",\(all.count)") @@")
    let lines = all.enumerated().map { DiffLine(kind: .added, old: nil, new: $0.offset + 1, text: $0.element) }
    return cap([FileDiff(path: path, added: all.count, removed: 0, binary: false, lines: [hunk] + lines)], limit)[0]
}

// MARK: - Parser

/// Parses `git diff` output (unified, no color, `a/` `b/` prefixes). Line numbers come from hunk headers.
func parseUnifiedDiff(_ text: String) -> [FileDiff] {
    var files: [FileDiff] = []
    var cur: FileDiff?
    var inHunk = false
    var old = 0, new = 0

    for line in text.components(separatedBy: "\n") {
        if let rest = line.stripPrefix("diff --git ") {
            if let f = cur { files.append(f) }
            cur = FileDiff(path: headerPath(rest), added: 0, removed: 0, binary: false, lines: [])
            inHunk = false
            continue
        }
        guard cur != nil, !line.isEmpty else { continue }
        if line.hasPrefix("@@ ") {
            (old, new) = hunkStarts(line)
            cur?.lines.append(DiffLine(kind: .hunk, old: nil, new: nil, text: line))
            inHunk = true
        } else if inHunk {
            switch line.first {
            case "+":
                cur?.lines.append(DiffLine(kind: .added, old: nil, new: new, text: String(line.dropFirst())))
                cur?.added += 1
                new += 1
            case "-":
                cur?.lines.append(DiffLine(kind: .removed, old: old, new: nil, text: String(line.dropFirst())))
                cur?.removed += 1
                old += 1
            case " ":
                cur?.lines.append(DiffLine(kind: .context, old: old, new: new, text: String(line.dropFirst())))
                old += 1
                new += 1
            default: break  // "\ No newline at end of file"
            }
        } else if let p = line.stripPrefix("rename to ") {
            cur?.path = unquotePath(p)
        } else if let p = line.stripPrefix("+++ "), p != "/dev/null" {
            let path = unquotePath(p.hasSuffix("\t") ? String(p.dropLast()) : p)
            cur?.path = path.stripPrefix("b/") ?? path
        } else if line.hasPrefix("Binary files ") {
            cur?.binary = true
        }
    }
    if let f = cur { files.append(f) }
    return files
}

/// The part after `diff --git `: `a/P b/P`, `a/old b/new`, or C-quoted `"a/…" "b/…"`.
/// Renames and text files are corrected by later headers.
private func headerPath(_ header: String) -> String {
    if header.hasPrefix("\""), let second = header.dropFirst().firstRange(of: "\" ")?.upperBound {
        let b = unquotePath(String(header[second...]))
        return b.stripPrefix("b/") ?? b
    }
    let rest = header.stripPrefix("a/") ?? header
    let n = rest.count
    if (n - 3) % 2 == 0, n >= 3 {
        let p = rest.prefix((n - 3) / 2)
        if rest == "\(p) b/\(p)" { return String(p) }
    }
    return rest.range(of: " b/").map { String(rest[$0.upperBound...]) } ?? rest
}

/// `@@ -12,3 +14,4 @@ …` → (12, 14).
func hunkStarts(_ header: String) -> (Int, Int) {
    let parts = header.split(separator: " ")
    func start(_ s: Substring) -> Int { Int(s.dropFirst().split(separator: ",").first ?? "") ?? 0 }
    return parts.count >= 3 ? (start(parts[1]), start(parts[2])) : (0, 0)
}

/// git C-quotes a path holding `"`, `\\` or a control character: `"a/q\\"uote"`, octal bytes like `\\355`.
/// Anything not wrapped in quotes is returned unchanged.
func unquotePath(_ s: String) -> String {
    guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
    let escapes: [UInt8: UInt8] = [UInt8(ascii: "a"): 7, UInt8(ascii: "b"): 8, UInt8(ascii: "t"): 9, UInt8(ascii: "n"): 10,
                                   UInt8(ascii: "v"): 11, UInt8(ascii: "f"): 12, UInt8(ascii: "r"): 13]
    let body = Array(s.utf8.dropFirst().dropLast())
    var bytes: [UInt8] = []
    var i = 0
    while i < body.count {
        let c = body[i]
        i += 1
        guard c == UInt8(ascii: "\\"), i < body.count else { bytes.append(c); continue }
        let e = body[i]
        if (UInt8(ascii: "0")...UInt8(ascii: "3")).contains(e), i + 3 <= body.count {
            bytes.append(body[i..<i + 3].reduce(0) { $0 &* 8 &+ ($1 &- UInt8(ascii: "0")) })
            i += 3
        } else {
            bytes.append(escapes[e] ?? e)
            i += 1
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}
