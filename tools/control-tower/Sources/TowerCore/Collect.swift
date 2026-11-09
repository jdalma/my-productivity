import Foundation

/// Every outside read collect makes. `live` runs the real commands; tests swap single fields.
struct CollectDeps {
    var psSnapshot: () -> [PsRow]
    var loadTeams: ([Pane]) throws -> [RawTeam]
    var loadCodexSessions: ([PsRow]) -> [CodexRecord]
    var listPanes: () -> [Pane]
    var listClients: () -> [TmuxClient]
    var loadClaudeSessions: () -> [ClaudeRecord]
    var capturePane: (String) -> String
    var lastMessages: (String, AgentKind) -> LastMessages
    var envOf: (Int, [String]) -> [String: String]

    static var live: CollectDeps {
        CollectDeps(
            psSnapshot: { TowerCore.psSnapshot() },
            loadTeams: { try TowerCore.loadTeams(panes: $0) },
            loadCodexSessions: { TowerCore.loadCodexSessions(rows: $0) },
            listPanes: { TowerCore.listPanes() },
            listClients: { TowerCore.listClients() },
            loadClaudeSessions: { TowerCore.loadClaudeSessions() },
            capturePane: { TowerCore.capturePane($0) },
            lastMessages: { TowerCore.lastMessages($0, agent: $1) },
            envOf: { TowerCore.envOf(pid: $0, keys: $1) }
        )
    }
}

/// The process-level fields join needs, from either a Claude or a Codex record.
struct Proc {
    var pid: Int
    var cwd: String
    var startedAt: String?
    var status: Status
    var since: String?
    var transcript: String?
    var title: String
}

private func tmuxOf(_ p: Pane) -> TmuxRef {
    TmuxRef(session: p.session, window: p.window, pane: p.pane)
}

/// A Session as join builds it; last_* and permission_prompt are filled by enrich.
private func sessionFields(handle: String, agent: AgentKind, proc: Proc?, tmux: TmuxRef?, title: String,
                           spool: Int = 0, termProgram: String? = nil) -> Session {
    let status = proc?.status ?? .unknown
    return Session(
        handle: handle, agent: agent, pid: proc?.pid ?? 0, cwd: proc?.cwd ?? "", startedAt: proc?.startedAt,
        status: status, myTurn: deriveMyTurn(status: status, spool: spool), since: proc?.since,
        permissionPrompt: false, title: title, tmux: tmux, transcript: proc?.transcript,
        lastUser: "", lastAssistant: "", termProgram: termProgram
    )
}

/// Pure join of raw source outputs into a Board, before enrich.
func join(teams: [TeamSeed], panes: [Pane], claude: [ClaudeRecord], codex: [CodexRecord], rows: [PsRow], at: String) -> Board {
    let paneById = Dictionary(panes.map { ($0.pane, $0) }, uniquingKeysWith: { $1 })
    let paneByPid = Dictionary(panes.map { ($0.pid, $0) }, uniquingKeysWith: { $1 })
    let workerKey = { (session: String, pane: String) in "\(session)\t\(pane)" }
    let workerKeys = Set(teams.flatMap { t in t.workers.map { workerKey(t.sessionName, $0.paneId) } })
    var matched: [String: (agent: AgentKind, proc: Proc, tmux: TmuxRef)] = [:]
    var loose: [Session] = []

    // A second process claiming an already-matched worker pane falls through to loose.
    func claim(_ tmux: TmuxRef?, _ agent: AgentKind, _ proc: Proc) -> Bool {
        guard let tmux else { return false }
        let key = workerKey(tmux.session, tmux.pane)
        guard workerKeys.contains(key), matched[key] == nil else { return false }
        matched[key] = (agent, proc, tmux)
        return true
    }

    // A crashed Claude leaves its sessions/<pid>.json behind; if the pid was
    // reused, the ps start time no longer matches procStart and the file is stale.
    let startOf = Dictionary(rows.map { ($0.pid, $0.lstart) }, uniquingKeysWith: { $1 })
    func stale(_ c: ClaudeRecord) -> Bool {
        guard let procStart = parseISO(c.procStart), let entry = startOf[c.pid], let lstart = parseISO(entry) else { return false }
        return abs(lstart - procStart) > 5000
    }

    for c in claude where !stale(c) {
        let pane = c.tmux.flatMap { paneById[$0.pane] }
        let tmux = c.tmux
        let title = pane?.title.nonEmpty ?? c.name.nonEmpty ?? ""
        let proc = Proc(pid: c.pid, cwd: c.cwd, startedAt: c.startedAt, status: c.status, since: c.since,
                        transcript: c.transcript, title: title)
        if claim(tmux, .claude, proc) { continue }
        loose.append(sessionFields(handle: handleOf(tmux, pid: c.pid), agent: .claude, proc: proc, tmux: tmux, title: title))
    }

    for x in codex {
        let pane = ancestors(of: x.pid, in: rows).lazy.compactMap { paneByPid[$0] }.first
        let tmux = pane.map(tmuxOf)
        let title = pane?.title.nonEmpty ?? x.title.nonEmpty ?? ""
        let proc = Proc(pid: x.pid, cwd: x.cwd, startedAt: x.startedAt, status: x.status, since: x.since,
                        transcript: x.transcript, title: title)
        if claim(tmux, .codex, proc) { continue }
        loose.append(sessionFields(handle: handleOf(tmux, pid: x.pid), agent: .codex, proc: proc, tmux: tmux, title: title,
                                   termProgram: tmux == nil ? x.termProgram : nil))
    }

    return Board(at: at, teams: teams.map { team in
        Team(name: team.name, sessionName: team.sessionName, startedAt: team.startedAt, attached: team.attached,
             workers: team.workers.map { w in
                 let m = matched[workerKey(team.sessionName, w.paneId)]
                 let pane = paneById[w.paneId]
                 var s = sessionFields(
                     handle: w.handle, agent: m?.agent ?? w.agent, proc: m?.proc,
                     tmux: m?.tmux ?? (w.alive ? pane.map(tmuxOf) : nil),
                     title: m?.proc.title ?? pane?.title ?? "", spool: w.spool
                 )
                 if !w.alive { s.myTurn = false }
                 s.cwd = m?.proc.cwd.nonEmpty ?? w.cwd.nonEmpty ?? ""
                 return Worker(session: s, workerName: w.workerName, role: w.role, description: w.description,
                               paneId: w.paneId, alive: w.alive, spool: w.spool, inbox: w.inbox,
                               sentPending: w.sentPending, oldestPendingAt: w.oldestPendingAt, stateFile: w.stateFile)
             })
    }, loose: loose)
}

/// Fills last_* (transcript tail), permission_prompt (pane capture) and term_program (outside tmux).
func enrich(_ board: Board, deps: CollectDeps) -> Board {
    func one(_ s: Session, spool: Int, alive: Bool) -> Session {
        var out = s
        if let t = s.transcript {
            let m = deps.lastMessages(t, s.agent)
            out.lastUser = m.lastUser
            out.lastAssistant = m.lastAssistant
        }
        if s.tmux == nil, s.termProgram == nil, s.pid != 0 {
            out.termProgram = deps.envOf(s.pid, ["TERM_PROGRAM"])["TERM_PROGRAM"]
        }
        guard let tmux = s.tmux else { return out }
        var p = applyPermissionPrompt(out, captured: deps.capturePane(tmux.pane))
        p.myTurn = alive && (deriveMyTurn(status: p.status, spool: spool) || p.permissionPrompt)
        return p
    }
    var b = board
    for t in b.teams.indices {
        for w in b.teams[t].workers.indices {
            let worker = b.teams[t].workers[w]
            b.teams[t].workers[w].session = one(worker.session, spool: worker.spool, alive: worker.alive)
        }
    }
    b.loose = b.loose.map { one($0, spool: 0, alive: true) }
    return b
}

/// A board plus why it may be missing teams. The error stays outside Board so
/// `--once` keeps its JSON shape.
public struct Snapshot: Sendable {
    public var board: Board
    /// Set when my-team's state files could not be read and `board.teams` is empty for that reason.
    public var myTeamError: String?
}

/// One full collection pass. Unreadable my-team state degrades to no teams instead of failing the board.
func snapshot(deps: CollectDeps, now: Date = Date()) -> Snapshot {
    let rows = deps.psSnapshot()
    let panes = deps.listPanes()
    let rawTeams: [RawTeam]
    var myTeamError: String?
    do {
        rawTeams = try deps.loadTeams(panes).filter(\.teamAlive)
    } catch {
        myTeamError = "\(error)"
        warn("\(error)")
        rawTeams = []
    }
    let codex = deps.loadCodexSessions(rows)
    let clients = deps.listClients()
    let teams = rawTeams.map { toTeam($0, clients: clients) }
    let board = join(teams: teams, panes: panes, claude: deps.loadClaudeSessions(), codex: codex, rows: rows,
                     at: isoString(now))
    return Snapshot(board: enrich(markTerminals(board, rows: rows, clients: clients), deps: deps), myTeamError: myTeamError)
}

/// Fills `inTerminal` of loose sessions from reads collect already made.
func markTerminals(_ board: Board, rows: [PsRow], clients: [TmuxClient]) -> Board {
    let withTTY = Set(rows.filter(\.hasTTY).map(\.pid))
    let attached = Set(clients.map(\.session))
    var b = board
    for i in b.loose.indices {
        b.loose[i].inTerminal = b.loose[i].tmux.map { attached.contains($0.session) } ?? withTTY.contains(b.loose[i].pid)
    }
    return b
}

/// One snapshot of every my-team worker and local Claude / Codex session.
/// ponytail: sources run one after another, as blocking reads off the caller's
/// executor; run them concurrently if a pass gets slow.
public func collect() async -> Board {
    snapshot(deps: .live).board
}

/// `collect()` plus the my-team failure reason, for a UI that has no stderr to show.
public func collectSnapshot() async -> Snapshot {
    snapshot(deps: .live)
}
