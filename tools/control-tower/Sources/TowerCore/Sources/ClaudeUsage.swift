import Foundation

struct UsageFile {
    var path: String
    var session: String
    var isSubagent: Bool
    var size: Int
    var created: Date
}

/// `<projects>/<dir>/<session>.jsonl` and everything under `<projects>/<dir>/<session>/subagents/`, the oldest
/// file first: a resumed or forked session's file starts with a copy of the original's records, and the original
/// is the one to count them in.
func usageFiles(_ projects: String) -> [UsageFile] {
    let fm = FileManager.default
    func file(_ path: String, session: String, isSubagent: Bool) -> UsageFile? {
        guard let a = try? fm.attributesOfItem(atPath: path), a[.type] as? FileAttributeType == .typeRegular else { return nil }
        return UsageFile(path: path, session: session, isSubagent: isSubagent, size: (a[.size] as? NSNumber)?.intValue ?? 0,
                         created: a[.creationDate] as? Date ?? .distantPast)
    }
    var files: [UsageFile] = []
    for dir in (try? fm.contentsOfDirectory(atPath: projects)) ?? [] {
        for entry in (try? fm.contentsOfDirectory(atPath: "\(projects)/\(dir)")) ?? [] {
            let path = "\(projects)/\(dir)/\(entry)"
            if entry.hasSuffix(".jsonl") {
                if let f = file(path, session: path, isSubagent: false) { files.append(f) }
            } else if !entry.contains(".") {
                let subagents = "\(path)/subagents"
                for sub in fm.enumerator(atPath: subagents)?.allObjects as? [String] ?? [] where sub.hasSuffix(".jsonl") {
                    if let f = file("\(subagents)/\(sub)", session: "\(path).jsonl", isSubagent: true) { files.append(f) }
                }
            }
        }
    }
    return files.sorted { a, b in a.created != b.created ? a.created < b.created : a.path < b.path }
}

/// One line of an API response. A response is one line per content block, all with the same `id`.
struct UsageResponse {
    var id: String
    var at: Double
    var model: String
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheCreation: Int
    var cacheLifetime: TimeInterval
}

enum UsageEvent {
    case response(UsageResponse)
    case compaction(uuid: String, at: Double)
}

struct UsageChunk {
    var events: [UsageEvent] = []
    var bytesThroughLastNewline = 0
    var cwd: String?
    var entrypoint: String?
}

private let assistantValue = Array(#""assistant""#.utf8)
private let typeKeys = [#""type":"#, #""type": "#].map { Array($0.utf8) }
private let compactionNeedle = Array(#""compact_boundary""#.utf8)

private let typeFirst = Array(#"{"type":""#.utf8)
private let usageTypesFirst = [#"{"type":"assistant""#, #"{"type":"system""#].map { Array($0.utf8) }

/// For speed, a line whose first key is `type` is taken at its word: when the value is spelled any other way than
/// `assistant` or `system`, the line is not looked at further. Claude Code writes neither an escaped type nor a
/// second `type` key, and a line this skips is not counted.
private func mayBeUsage(_ line: UnsafeRawPointer, _ length: Int) -> Bool {
    if length >= typeFirst.count, memcmp(line, typeFirst, typeFirst.count) == 0,
       !usageTypesFirst.contains(where: { length >= $0.count && memcmp(line, $0, $0.count) == 0 }) { return false }
    var from = 0
    while let found = memmem(line + from, length - from, assistantValue, assistantValue.count) {
        let at = line.distance(to: UnsafeRawPointer(found))
        if typeKeys.contains(where: { at >= $0.count && memcmp(line + at - $0.count, $0, $0.count) == 0 }) { return true }
        from = at + 1
    }
    return memmem(line, length, compactionNeedle, compactionNeedle.count) != nil
}

func parseUsageChunk(_ data: Data) -> UsageChunk {
    var chunk = UsageChunk()
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var pos = 0
        while pos < raw.count, let nl = memchr(base + pos, 0x0A, raw.count - pos) {
            let end = base.distance(to: UnsafeRawPointer(nl))
            let length = end - pos
            if mayBeUsage(base + pos, length) {
                let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + pos), count: length, deallocator: .none)
                if let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    add(record, to: &chunk)
                }
            }
            pos = end + 1
        }
        chunk.bytesThroughLastNewline = pos
    }
    return chunk
}

private func add(_ record: [String: Any], to chunk: inout UsageChunk) {
    guard let at = parseISO(record["timestamp"] as? String).map({ $0 / 1000 }) else { return }
    switch record["type"] as? String {
    case "assistant":
        guard let message = record["message"] as? [String: Any], let id = message["id"] as? String,
              let model = message["model"] as? String, model != "<synthetic>" else { return }
        if chunk.cwd == nil { chunk.cwd = record["cwd"] as? String }
        if chunk.entrypoint == nil { chunk.entrypoint = record["entrypoint"] as? String }
        let usage = message["usage"] as? [String: Any] ?? [:]
        let oneHour = (usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0
        // a count no response can have, negative or beyond a billion, is a damaged line: sums stay sums
        func tokens(_ key: String) -> Int {
            (usage[key] as? Int).flatMap { (0...1_000_000_000).contains($0) ? $0 : nil } ?? 0
        }
        chunk.events.append(.response(UsageResponse(
            id: id, at: at, model: model, input: tokens("input_tokens"), output: tokens("output_tokens"),
            cacheRead: tokens("cache_read_input_tokens"), cacheCreation: tokens("cache_creation_input_tokens"),
            cacheLifetime: oneHour > 0 ? 3600 : 300
        )))
    case "system":
        guard record["subtype"] as? String == "compact_boundary", let uuid = record["uuid"] as? String else { return }
        chunk.events.append(.compaction(uuid: uuid, at: at))
    default:
        return
    }
}

func gitRepoRoot(_ path: String) -> String? {
    var dir = path
    while dir.count > 1 {
        if FileManager.default.fileExists(atPath: dir + "/.git") { return dir }
        dir = (dir as NSString).deletingLastPathComponent
    }
    return nil
}

func usageProject(cwd: String, repoRoot: (String) -> String?) -> String {
    var base = cwd
    for cut in ["/.worktrees/", "/.claude/worktrees/"] {
        if let r = base.range(of: cut) { base = String(base[..<r.lowerBound]) }
    }
    return repoRoot(base) ?? base
}
