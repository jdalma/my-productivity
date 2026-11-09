import Foundation

struct ClaudeRecord: Decodable, Hashable {
    var pid: Int
    var sessionId: String?
    var cwd: String
    var startedAt: String?
    var procStart: String?
    var status: Status
    var since: String?
    var name: String?
    var entrypoint: String?
    var tmux: TmuxRef?
    var transcript: String?
}

/// The raw `~/.claude/sessions/<pid>.json`; times are epoch milliseconds.
struct SessionJson: Decodable {
    var pid: Int
    var sessionId: String?
    var cwd: String
    var startedAt: Double?
    var procStart: String?
    var status: String?
    var statusUpdatedAt: Double?
    var updatedAt: Double?
    var name: String?
    var entrypoint: String?
    var tmux: String?
}

extension SessionJson {
    enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, startedAt, procStart, status, statusUpdatedAt, updatedAt, name, entrypoint, tmux
    }

    /// pid and cwd are required; any other field of an unexpected type reads as absent.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int.self, forKey: .pid)
        cwd = try c.decode(String.self, forKey: .cwd)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        startedAt = try? c.decodeIfPresent(Double.self, forKey: .startedAt)
        procStart = try? c.decodeIfPresent(String.self, forKey: .procStart)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        statusUpdatedAt = try? c.decodeIfPresent(Double.self, forKey: .statusUpdatedAt)
        updatedAt = try? c.decodeIfPresent(Double.self, forKey: .updatedAt)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        entrypoint = try? c.decodeIfPresent(String.self, forKey: .entrypoint)
        tmux = try? c.decodeIfPresent(String.self, forKey: .tmux)
    }
}

/// `$HOME` first, the user database otherwise.
func homeDirectory(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    env["HOME"].nonEmpty ?? NSHomeDirectory()
}

let homeDir = homeDirectory()
let claudeProjectsDir = "\(homeDir)/.claude/projects"

/// JS `cwd.replace(/[^A-Za-z0-9]/g, '-')`, which works on UTF-16 units: an astral char becomes two dashes.
func transcriptDirName(_ cwd: String) -> String {
    String(decoding: cwd.utf16.map { u in
        (0x30...0x39).contains(u) || (0x41...0x5A).contains(u) || (0x61...0x7A).contains(u) ? u : 0x2D
    }, as: UTF16.self)
}

func isAlive(_ pid: Int) -> Bool {
    kill(pid_t(pid), 0) == 0 || errno == EPERM
}

private func findTranscript(projectsDir: String, cwd: String, sessionId: String, exists: (String) -> Bool) -> String? {
    let file = "\(sessionId).jsonl"
    let primary = "\(projectsDir)/\(transcriptDirName(cwd))/\(file)"
    if exists(primary) { return primary }
    guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else { return nil }
    return dirs.map { "\(projectsDir)/\($0)/\(file)" }.first(where: exists)
}

private func iso(_ ms: Double?) -> String? {
    guard let ms, ms.isFinite else { return nil }
    return isoString(ms: Int64(ms))
}

/// `procStart` is UTC in ctime form, e.g. `Thu Oct 29 10:35:09 2026`.
private func procStartISO(_ s: String) -> String? {
    guard let m = s.wholeMatch(of: #/\w{3} (\w{3}) +(\d{1,2}) (\d\d):(\d\d):(\d\d) (\d{4})/#) else { return nil }
    return ctimeISO(month: m.1, day: m.2, hour: m.3, minute: m.4, second: m.5, year: m.6, zone: TimeZone(identifier: "UTC")!)
}

/// One sessions file → record, or nil when its process is gone.
func fromSessionJson(
    _ json: SessionJson,
    isAlive alive: (Int) -> Bool = isAlive,
    transcriptExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    projectsDir: String = claudeProjectsDir
) -> ClaudeRecord? {
    guard alive(json.pid) else { return nil }
    return ClaudeRecord(
        pid: json.pid,
        sessionId: json.sessionId,
        cwd: json.cwd,
        startedAt: iso(json.startedAt),
        procStart: json.procStart.flatMap(procStartISO),
        status: json.status == "busy" ? .busy : .wait,
        since: iso(json.statusUpdatedAt ?? json.updatedAt),
        name: json.name,
        entrypoint: json.entrypoint,
        tmux: parseTmuxTarget(json.tmux),
        transcript: json.sessionId.flatMap {
            findTranscript(projectsDir: projectsDir, cwd: json.cwd, sessionId: $0, exists: transcriptExists)
        }
    )
}

func loadClaudeSessions(dir: String = "\(homeDir)/.claude/sessions", projectsDir: String = claudeProjectsDir) -> [ClaudeRecord] {
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
    // name order: it decides loose order and which of two processes claims a worker pane
    return files.filter { $0.hasSuffix(".json") }.sorted().compactMap { f in
        // unparsable or unexpected shape (e.g. no cwd): skip this file only
        guard let data = FileManager.default.contents(atPath: "\(dir)/\(f)"),
              let json = try? JSONDecoder().decode(SessionJson.self, from: data) else { return nil }
        return fromSessionJson(json, projectsDir: projectsDir)
    }
}
