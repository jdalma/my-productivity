import Foundation

// Read-only: reads my-team's state files the way `my-team status --all --json`
// does (tools/my-team/src/commands/status.js). Nothing here writes, absorbs or consumes.

/// `MY_TEAM_STATE_ROOT_BASE` (trimmed, `~` and `~/` expanded) or `~/.my-team/sessions`, home being `$HOME`.
func stateRootBase(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    let home = homeDirectory(env)
    let path = env["MY_TEAM_STATE_ROOT_BASE"]?.trimmed.nonEmpty.map { o in
        o == "~" ? home : o.hasPrefix("~/") ? home + o.dropFirst() : o
    } ?? "\(home)/.my-team/sessions"
    return URL(fileURLWithPath: path).standardizedFileURL.path
}

/// The fields of `<team>/manifest.json` a status needs.
struct Manifest: Decodable {
    var teamName: String
    var stateRoot: String
    var sessionName: String
    var startedAt: String?
    var workers: [ManifestWorker]
}

struct ManifestWorker: Decodable {
    var name: String
    var paneId: String
    var cwd: String?
    var agentType: String?
    var role: String?
    var description: String?
}

/// One team as `my-team status --all --json` reports it.
struct RawTeam {
    var teamName: String
    var session: String
    var startedAt: String?
    var teamAlive: Bool
    var workers: [RawWorker]
}

struct RawWorker {
    var name: String
    var paneId: String
    var cwd: String?
    var agentType: String?
    var role: String?
    var description: String?
    var alive: Bool
    var state: String?
    var reason: String?
    var stateUpdatedAt: String? = nil
    var spool: Int
    var unread: Int
    var sentPending: Int
    var oldestPendingAt: String?
}

/// The my-team-owned part of a Team; collect adds the process-level Session fields.
struct TeamSeed: Decodable, Hashable {
    var name: String
    var sessionName: String
    var startedAt: String?
    var attached: Bool
    var workers: [WorkerSeed]
}

struct WorkerSeed: Decodable, Hashable {
    var handle: String
    var workerName: String
    var role: String?
    var description: String
    var paneId: String
    var alive: Bool
    var agent: AgentKind
    var cwd: String?
    var spool: Int
    var inbox: Int
    var sentPending: Int
    var oldestPendingAt: String?
    var stateFile: StateFile?
}

struct MyTeamError: Error, CustomStringConvertible {
    var description: String
}

/// Every team under `base`, dead ones included. No base dir means no team was ever started.
/// Throws only when `base` exists but cannot be listed.
func loadTeams(base: String = stateRootBase(), panes: [Pane]) throws -> [RawTeam] {
    let fm = FileManager.default
    let names: [String]
    do {
        names = try fm.contentsOfDirectory(atPath: base)
    } catch CocoaError.fileReadNoSuchFile {
        return []
    } catch {
        throw MyTeamError(description: "cannot read my-team state dir \(base): \(error.localizedDescription)")
    }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return names
        .filter { !$0.hasSuffix(".bak") && $0 != ".omc" }
        .filter { (try? fm.attributesOfItem(atPath: "\(base)/\($0)"))?[.type] as? FileAttributeType == .typeDirectory }
        .sorted()
        .compactMap { name in
            guard let data = fm.contents(atPath: "\(base)/\(name)/manifest.json") else { return nil }
            do {
                return teamStatus(try decoder.decode(Manifest.self, from: data), panes: panes)
            } catch {
                warn("skip \(name): \(error)")
                return nil
            }
        }
}

/// Liveness by (session, @worker_name, pane id): pane ids are server-global and get reused,
/// so a dead team's manifest can point at another team's live pane.
func teamStatus(_ m: Manifest, panes: [Pane]) -> RawTeam {
    let session = String(m.sessionName.prefix { $0 != ":" })
    let inSession = panes.filter { $0.session == session }
    let root = m.stateRoot.trimmed
    return RawTeam(
        teamName: m.teamName,
        session: m.sessionName,
        startedAt: m.startedAt,
        teamAlive: !inSession.isEmpty,
        workers: m.workers.map { w in
            var r = RawWorker(
                name: w.name, paneId: w.paneId, cwd: w.cwd, agentType: w.agentType, role: w.role,
                description: w.description,
                alive: inSession.contains { $0.workerName?.trimmed == w.name && $0.pane == w.paneId },
                spool: spoolCount("\(root)/incoming-spool/\(w.name)"), unread: 0, sentPending: 0
            )
            // a worker LLM writes its own status.json; a non-string value drops that field only
            if let data = FileManager.default.contents(atPath: "\(root)/workers/\(w.name)/status.json"),
               let s = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? [String: Any] {
                r.state = s["state"] as? String
                r.reason = s["reason"] as? String
                r.stateUpdatedAt = s["updated_at"] as? String
            }
            let mailbox = "\(root)/mailbox/\(w.name).json"
            if let data = FileManager.default.contents(atPath: mailbox) {
                do {
                    (r.unread, r.sentPending, r.oldestPendingAt) = try mailCounts(data, path: mailbox)
                } catch {
                    r.reason = r.reason ?? "mailbox unreadable: \(error)"
                }
            }
            return r
        }
    )
}

private func spoolCount(_ dir: String) -> Int {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".json") }.count
}

/// Inbox entries, pending questions and the earliest `sent_at` of a mailbox file.
/// Throws like my-team's readMailboxFile: bad JSON, or a schema other than 2.
func mailCounts(_ data: Data, path: String) throws -> (unread: Int, sentPending: Int, oldestPendingAt: String?) {
    let parsed: Any
    do {
        parsed = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    } catch {
        throw MyTeamError(description: "Mailbox at \(path) is not valid JSON: \(error.localizedDescription)")
    }
    guard parsed is [Any] || parsed is [String: Any] else { return (0, 0, nil) }
    let mb = parsed as? [String: Any] ?? [:]
    guard mb["schema_version"] as? Int == 2 else {
        let v = mb["schema_version"].flatMap { $0 is NSNull ? nil : "\($0)" } ?? "missing"
        throw MyTeamError(description:
            "Mailbox at \(path) has schema_version=\(v), expected 2. " +
            "Shutdown the team (my-team shutdown) and restart to begin with a fresh schema; " +
            "automatic migration is not supported.")
    }
    let entries = { (v: Any?) -> [Any] in (v as? [String: Any]).map { Array($0.values) } ?? (v as? [Any]) ?? [] }
    let pending = entries(mb["sent_pending"])
    let sentAt = pending.compactMap { (($0 as? [String: Any])?["sent_at"] as? String).nonEmpty }
    return (entries(mb["inbox"]).count, pending.count, sentAt.sorted().first)
}

func toTeam(_ t: RawTeam, clients: [TmuxClient]) -> TeamSeed {
    let sessionName = t.session.replacing(#/:\d+$/#, with: "")
    return TeamSeed(
        name: t.teamName,
        sessionName: sessionName,
        startedAt: t.startedAt,
        attached: clients.contains { $0.session == sessionName },
        workers: t.workers.map { w in
            WorkerSeed(
                handle: "pane:\(sessionName):\(w.paneId)",
                workerName: w.name,
                role: w.role,
                description: w.description ?? "",
                paneId: w.paneId,
                alive: w.alive,
                // ponytail: the model only knows claude|codex; gemini/cursor etc. become claude.
                // collect overwrites agent from the matched process anyway.
                agent: w.agentType == "codex" ? .codex : .claude,
                cwd: w.cwd,
                spool: w.spool,
                inbox: w.unread,
                sentPending: w.sentPending,
                oldestPendingAt: w.oldestPendingAt,
                stateFile: w.state.nonEmpty != nil || w.reason.nonEmpty != nil
                    ? StateFile(state: w.state, reason: w.reason, updatedAt: w.stateUpdatedAt) : nil
            )
        }
    )
}
