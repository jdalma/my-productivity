import Foundation
import os

// Past Claude Code and Codex sessions from their transcript files, newest first.
// Interactive sessions only: Claude `entrypoint == "cli"`, Codex TUI/CLI/Desktop originators.
// Read-only. Each file is read as its first and last 256 KB, and re-read only when its mtime or size changes.

/// One transcript as the history list shows it. Timestamps are ISO 8601 strings from the transcript.
public struct HistorySession: Codable, Hashable, Sendable {
    public var id: String
    public var agent: AgentKind
    public var title: String
    /// The session's cwd: where a resume has to start.
    public var workspace: String
    public var branch: String?
    public var createdAt: String?
    public var updatedAt: String
    public var lastPrompt: String?
    public var transcriptPath: String
    /// A running Session on the board reads this transcript.
    public var live: Bool
    /// `claude --resume <id>` or `codex resume <id>`, run in `workspace`.
    public var resumeCommand: [String]
    /// The my-team worker this session was, from the prompt my-team typed first. The board's own; not in the JSON.
    public var member: TeamWorker?

    public init(id: String, agent: AgentKind, title: String, workspace: String, branch: String?, createdAt: String?,
                updatedAt: String, lastPrompt: String?, transcriptPath: String, live: Bool, resumeCommand: [String],
                member: TeamWorker? = nil) {
        self.id = id
        self.agent = agent
        self.title = title
        self.workspace = workspace
        self.branch = branch
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastPrompt = lastPrompt
        self.transcriptPath = transcriptPath
        self.live = live
        self.resumeCommand = resumeCommand
        self.member = member
    }

    enum CodingKeys: String, CodingKey {
        case id, agent, title, workspace, branch
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastPrompt = "last_prompt"
        case transcriptPath = "transcript_path"
        case live
        case resumeCommand = "resume_command"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(agent, forKey: .agent)
        try c.encode(title, forKey: .title)
        try c.encode(workspace, forKey: .workspace)
        try c.encode(branch, forKey: .branch)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(lastPrompt, forKey: .lastPrompt)
        try c.encode(transcriptPath, forKey: .transcriptPath)
        try c.encode(live, forKey: .live)
        try c.encode(resumeCommand, forKey: .resumeCommand)
    }
}

/// What one transcript file says, before the Codex index title and the board's live set are applied.
struct TranscriptFacts: Hashable, Sendable {
    var path: String
    var id: String
    var agent: AgentKind
    /// Claude's `custom-title`, else `ai-title`; nil for Codex, whose title lives in session_index.jsonl.
    var title: String?
    var firstPrompt: String?
    var lastPrompt: String?
    var cwd: String
    var branch: String?
    var createdAt: String?
    var updatedAt: String?
}

struct HistoryRoots {
    var claudeProjects: String
    var codexHome: String

    /// `CLAUDE_CONFIG_DIR` and `CODEX_HOME` when set, else under `$HOME`.
    init(env: [String: String] = ProcessInfo.processInfo.environment) {
        let home = homeDirectory(env)
        claudeProjects = (env["CLAUDE_CONFIG_DIR"].nonEmpty ?? "\(home)/.claude") + "/projects"
        codexHome = env["CODEX_HOME"].nonEmpty ?? "\(home)/.codex"
    }

    init(claudeProjects: String, codexHome: String) {
        self.claudeProjects = claudeProjects
        self.codexHome = codexHome
    }
}

let interactiveCodexOriginators: Set<String> = ["codex-tui", "codex_cli_rs", "Codex Desktop"]

private let chunkBytes = 256 * 1024

/// The JSON object lines of a file's first and last `chunkBytes`; a whole small file is both.
/// A line cut by a chunk edge and any line that is not a JSON object are skipped.
func headAndTail(_ path: String, size: Int) -> (head: [[String: Any]], tail: [[String: Any]]) {
    guard let fh = FileHandle(forReadingAtPath: path) else { return ([], []) }
    defer { try? fh.close() }
    func lines(_ data: Data?, dropFirst: Bool, dropLast: Bool) -> [[String: Any]] {
        var parts = (data ?? Data()).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if dropFirst, !parts.isEmpty { parts.removeFirst() }
        if dropLast, !parts.isEmpty { parts.removeLast() }
        return parts.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }
    if size <= 2 * chunkBytes {
        let all = lines(try? fh.readToEnd(), dropFirst: false, dropLast: false)
        return (all, all)
    }
    let head = lines(try? fh.read(upToCount: chunkBytes), dropFirst: false, dropLast: true)
    guard (try? fh.seek(toOffset: UInt64(size - chunkBytes))) != nil else { return (head, []) }
    return (head, lines(try? fh.read(upToCount: chunkBytes), dropFirst: true, dropLast: false))
}

/// The last value `pick` finds: tail first, newest line first, then the head.
private func latest<T>(_ head: [[String: Any]], _ tail: [[String: Any]], _ pick: ([String: Any]) -> T?) -> T? {
    tail.reversed().lazy.compactMap(pick).first ?? head.reversed().lazy.compactMap(pick).first
}

private func string(_ v: Any?) -> String? { (v as? String)?.trimmed.nonEmpty }

/// One line, whitespace collapsed, at most 200 characters.
func oneLine(_ s: String) -> String {
    let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return flat.count > 200 ? String(flat.prefix(199)) + "…" : flat
}

/// Text the harness put in the user's turn: tags, AGENTS.md dumps, interrupt and compaction notices.
/// ponytail: prefix list from what local transcripts show; a new injected shape becomes a title until added here.
func isInjectedPrompt(_ text: String) -> Bool {
    ["<", "# AGENTS.md", "[Request interrupted", "This session is being continued", "Caveat:", "The user interrupted"]
        .contains { text.hasPrefix($0) }
}

/// A typed slash command, which Claude records as `<command-name>/x</command-name>…<command-args>y</command-args>`, as `/x y`.
func slashCommand(_ text: String) -> String? {
    guard let name = text.firstMatch(of: #/<command-name>([^<]*)</command-name>/#)?.1 else { return nil }
    let args = text.firstMatch(of: #/<command-args>([^<]*)</command-args>/#)?.1 ?? ""
    return "\(name) \(args)".trimmed.nonEmpty
}

/// The first text of a message `content`: a plain string or the first text block.
private func messageText(_ content: Any?) -> String? {
    if let s = string(content) { return s }
    return (content as? [[String: Any]])?.lazy
        .filter { ["text", "input_text"].contains($0["type"] as? String) }
        .compactMap { string($0["text"]) }.first
}

func claudeFacts(path: String, head: [[String: Any]], tail: [[String: Any]]) -> TranscriptFacts? {
    let type = { (r: [String: Any]) in r["type"] as? String }
    guard (head + tail).first(where: { type($0) == "user" })?["entrypoint"] as? String == "cli" else { return nil }
    // Claude files a transcript under projects/<encoded start cwd>, and `--resume` looks there:
    // a later `cd` must not move the workspace. No matching cwd: the first one.
    let project = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    let cwds = (head + tail).compactMap { string($0["cwd"]) }
    let firstPrompt = head.lazy
        .filter { type($0) == "user" && $0["isMeta"] as? Bool != true }
        .compactMap { messageText(($0["message"] as? [String: Any])?["content"]).map { slashCommand($0) ?? $0 } }
        .first { !isInjectedPrompt($0) }
    return TranscriptFacts(
        path: path,
        id: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
        agent: .claude,
        title: latest(head, tail) { type($0) == "custom-title" ? string($0["customTitle"]) : nil }
            ?? latest(head, tail) { type($0) == "ai-title" ? string($0["aiTitle"]) : nil },
        firstPrompt: firstPrompt,
        lastPrompt: latest(head, tail) { type($0) == "last-prompt" ? string($0["lastPrompt"]) : nil },
        cwd: cwds.first { transcriptDirName($0) == project } ?? cwds.first ?? "",
        branch: latest(head, tail) { string($0["gitBranch"]) },
        createdAt: head.lazy.compactMap { string($0["timestamp"]) }.first,
        updatedAt: latest(head, tail) { string($0["timestamp"]) }
    )
}

/// The user's own words in a Codex rollout: `user_message` events, or on rollouts that have none,
/// user `message` items that are not harness injections.
private func codexUserTexts(_ records: [[String: Any]]) -> [String] {
    let payloads = records.compactMap { $0["payload"] as? [String: Any] }
    let events = zip(records, payloads).compactMap { r, p in
        r["type"] as? String == "event_msg" && p["type"] as? String == "user_message" ? string(p["message"]) : nil
    }
    if !events.isEmpty { return events }
    return payloads
        .filter { $0["type"] as? String == "message" && $0["role"] as? String == "user" }
        .compactMap { messageText($0["content"]) }
        .filter { !isInjectedPrompt($0) }
}

func codexFacts(path: String, head: [[String: Any]], tail: [[String: Any]]) -> TranscriptFacts? {
    guard let first = head.first, first["type"] as? String == "session_meta",
          let meta = first["payload"] as? [String: Any],
          let originator = meta["originator"] as? String, interactiveCodexOriginators.contains(originator),
          let id = string(meta["id"]) else { return nil }
    let turnCwd = latest(head, tail) { r in
        r["type"] as? String == "turn_context" ? string((r["payload"] as? [String: Any])?["cwd"]) : nil
    }
    return TranscriptFacts(
        path: path,
        id: id,
        agent: .codex,
        title: nil,
        firstPrompt: codexUserTexts(head).first,
        lastPrompt: codexUserTexts(tail).last ?? codexUserTexts(head).last,
        cwd: turnCwd ?? string(meta["cwd"]) ?? "",
        branch: string((meta["git"] as? [String: Any])?["branch"]),
        createdAt: string(meta["timestamp"]) ?? string(first["timestamp"]),
        updatedAt: latest(head, tail) { string($0["timestamp"]) }
    )
}

/// A transcript file found on disk.
struct TranscriptFile: Hashable, Sendable {
    var path: String
    var agent: AgentKind
    var mtime: Date
    var size: Int
}

private func stat(_ path: String) -> (mtime: Date, size: Int, isFile: Bool)? {
    guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
    return (a[.modificationDate] as? Date ?? .distantPast, (a[.size] as? NSNumber)?.intValue ?? 0,
            a[.type] as? FileAttributeType == .typeRegular)
}

/// `<projects>/<dir>/<id>.jsonl` (nothing deeper, so `subagents/` is skipped) and
/// `<codex home>/sessions/**/rollout-*.jsonl`.
func transcriptFiles(_ roots: HistoryRoots) -> [TranscriptFile] {
    let fm = FileManager.default
    let claude = ((try? fm.contentsOfDirectory(atPath: roots.claudeProjects)) ?? []).flatMap { dir in
        ((try? fm.contentsOfDirectory(atPath: "\(roots.claudeProjects)/\(dir)")) ?? [])
            .filter { $0.hasSuffix(".jsonl") }
            .map { "\(roots.claudeProjects)/\(dir)/\($0)" }
    }
    let sessions = "\(roots.codexHome)/sessions"
    let codex = (fm.enumerator(atPath: sessions)?.allObjects as? [String] ?? [])
        .filter { ($0 as NSString).lastPathComponent.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }
        .map { "\(sessions)/\($0)" }
    return (claude.map { ($0, AgentKind.claude) } + codex.map { ($0, AgentKind.codex) }).compactMap { path, agent in
        guard let s = stat(path), s.isFile else { return nil }
        return TranscriptFile(path: path, agent: agent, mtime: s.mtime, size: s.size)
    }
}

/// Parsed facts per path, kept while the file's mtime and size stay the same.
final class HistoryCache: Sendable {
    private struct Entry: Sendable {
        var mtime: Date
        var size: Int
        var facts: TranscriptFacts?
    }

    private let entries = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    /// Facts for every file, parsing only new or changed ones; entries for files gone from disk are dropped.
    func facts(_ files: [TranscriptFile], parse: (TranscriptFile) -> TranscriptFacts?) -> [TranscriptFacts] {
        let known = entries.withLock { $0 }
        var next: [String: Entry] = [:]
        for f in files {
            if let e = known[f.path], e.mtime == f.mtime, e.size == f.size {
                next[f.path] = e
            } else {
                next[f.path] = Entry(mtime: f.mtime, size: f.size, facts: parse(f))
            }
        }
        let result = next
        entries.withLock { $0 = result }
        return files.compactMap { result[$0.path]?.facts }
    }
}

let historyCache = HistoryCache()

func parseTranscript(_ f: TranscriptFile) -> TranscriptFacts? {
    let (head, tail) = headAndTail(f.path, size: f.size)
    let facts = f.agent == .claude ? claudeFacts(path: f.path, head: head, tail: tail) : codexFacts(path: f.path, head: head, tail: tail)
    return facts.map { var x = $0; x.updatedAt = x.updatedAt ?? isoString(f.mtime); return x }
}

/// A my-team team and one of its workers, by name.
public struct TeamWorker: Hashable, Sendable {
    public var team: String
    public var worker: String
    /// Added to a running team (`add-worker`), rather than launched with it by `my-team start`.
    public var joined: Bool

    public init(team: String, worker: String, joined: Bool = false) {
        self.team = team
        self.worker = worker
        self.joined = joined
    }
}

/// The first prompt my-team types into a worker pane (start or add-worker) names its state dir,
/// `…/sessions/<team>/workers/<worker>/`. nil for any other text or when the path is missing.
func myTeamBootstrap(_ prompt: String) -> TeamWorker? {
    guard prompt.hasPrefix("Team is live.") || prompt.hasPrefix("You just joined team "),
          let m = prompt.firstMatch(of: #//sessions/([^/\s]+)/workers/([^/\s]+)//#) else { return nil }
    return TeamWorker(team: String(m.1), worker: String(m.2), joined: prompt.hasPrefix("You just joined team "))
}

/// Facts → sessions, newest first. The Codex title comes from `codexTitles` (session_index.jsonl), then the first prompt.
func historySessions(_ facts: [TranscriptFacts], codexTitles: [String: String],
                     liveTranscripts: Set<String>) -> [HistorySession] {
    let sessions = facts.map { f in
        let member = f.firstPrompt.flatMap(myTeamBootstrap)
        // `<team> · <worker>` says more than the bootstrap sentence, which is the same for every worker
        let title = f.title ?? (f.agent == .codex ? codexTitles[f.id].nonEmpty : nil)
            ?? member.map { "\($0.team) · \($0.worker)" } ?? f.firstPrompt ?? ""
        return HistorySession(
            id: f.id, agent: f.agent, title: oneLine(title), workspace: f.cwd, branch: f.branch,
            createdAt: f.createdAt, updatedAt: f.updatedAt ?? "", lastPrompt: f.lastPrompt.map(oneLine),
            transcriptPath: f.path, live: liveTranscripts.contains(f.path),
            resumeCommand: f.agent == .claude ? ["claude", "--resume", f.id] : ["codex", "resume", f.id],
            member: member
        )
    }
    let keyed = sessions.enumerated().map { (time: parseISO($1.updatedAt) ?? 0, offset: $0, session: $1) }
    return keyed.sorted { a, b in a.time != b.time ? a.time > b.time : a.offset < b.offset }.map(\.session)
}

func collectHistory(board: Board, roots: HistoryRoots, cache: HistoryCache) -> [HistorySession] {
    let facts = cache.facts(transcriptFiles(roots), parse: parseTranscript)
    let live = Set((board.teams.flatMap { $0.workers.map(\.session) } + board.loose).compactMap(\.transcript))
    return historySessions(facts, codexTitles: loadTitles(codexHome: roots.codexHome), liveTranscripts: live)
}

/// Every interactive Claude Code and Codex session on disk, newest first. `board` marks the running ones.
public func collectHistory(board: Board) async -> [HistorySession] {
    collectHistory(board: board, roots: HistoryRoots(), cache: historyCache)
}
