// The board model, field for field the JSON that `tower-cli --once` prints.
// Optional fields encode as an explicit `null`, never as a missing key, so every
// record of a kind has the same key set.

public enum AgentKind: String, Codable, Sendable {
    case claude, codex
}

/// busy: working on a turn. wait: finished its turn, idle at the prompt.
/// unknown: no reliable signal (dead worker, unrecognized process, unresolved rollout).
public enum Status: String, Codable, Sendable {
    case busy, wait, unknown
}

/// `session` is the tmux session name, `window` the window id (`@5`), `pane` the pane id (`%42`).
public struct TmuxRef: Codable, Hashable, Sendable {
    public var session: String
    public var window: String
    public var pane: String

    public init(session: String, window: String, pane: String) {
        self.session = session
        self.window = window
        self.pane = pane
    }
}

/// A worker's self-reported `workers/<name>/status.json`. A hint only; the worker LLM writes it.
public struct StateFile: Codable, Hashable, Sendable {
    public var state: String?
    public var reason: String?
    public var updatedAt: String?

    public init(state: String?, reason: String?, updatedAt: String?) {
        self.state = state
        self.reason = reason
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case state, reason
        case updatedAt = "updated_at"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encode(reason, forKey: .reason)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

/// One running agent process. Timestamps are ISO 8601 UTC strings with milliseconds.
///
/// `handle` is the id a focus request names: `pane:<session>:<pane>` inside tmux,
/// `pid:<pid>` outside. Workers always use the pane form, even when dead.
public struct Session: Codable, Hashable, Sendable {
    public var handle: String
    public var agent: AgentKind
    public var pid: Int
    public var cwd: String
    public var startedAt: String?
    public var status: Status
    public var myTurn: Bool
    /// When the current status began.
    public var since: String?
    /// A permission or trust modal is on screen.
    public var permissionPrompt: Bool
    public var title: String
    public var tmux: TmuxRef?
    public var transcript: String?
    /// ≤ 300 UTF-16 units, '' when none.
    public var lastUser: String
    public var lastAssistant: String
    /// TERM_PROGRAM of the process; used to focus a session outside tmux.
    public var termProgram: String?
    /// Open in a terminal: its tmux session has a client, or outside tmux its process has a tty.
    /// Set for loose sessions only (a team's is `Team.attached`). Not in the JSON.
    public var inTerminal = true

    public init(
        handle: String, agent: AgentKind, pid: Int, cwd: String, startedAt: String?,
        status: Status, myTurn: Bool, since: String?, permissionPrompt: Bool, title: String,
        tmux: TmuxRef?, transcript: String?, lastUser: String, lastAssistant: String, termProgram: String?
    ) {
        self.handle = handle
        self.agent = agent
        self.pid = pid
        self.cwd = cwd
        self.startedAt = startedAt
        self.status = status
        self.myTurn = myTurn
        self.since = since
        self.permissionPrompt = permissionPrompt
        self.title = title
        self.tmux = tmux
        self.transcript = transcript
        self.lastUser = lastUser
        self.lastAssistant = lastAssistant
        self.termProgram = termProgram
    }

    enum CodingKeys: String, CodingKey {
        case handle, agent, pid, cwd
        case startedAt = "started_at"
        case status
        case myTurn = "my_turn"
        case since
        case permissionPrompt = "permission_prompt"
        case title, tmux, transcript
        case lastUser = "last_user"
        case lastAssistant = "last_assistant"
        case termProgram = "term_program"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(handle, forKey: .handle)
        try c.encode(agent, forKey: .agent)
        try c.encode(pid, forKey: .pid)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(status, forKey: .status)
        try c.encode(myTurn, forKey: .myTurn)
        try c.encode(since, forKey: .since)
        try c.encode(permissionPrompt, forKey: .permissionPrompt)
        try c.encode(title, forKey: .title)
        try c.encode(tmux, forKey: .tmux)
        try c.encode(transcript, forKey: .transcript)
        try c.encode(lastUser, forKey: .lastUser)
        try c.encode(lastAssistant, forKey: .lastAssistant)
        try c.encode(termProgram, forKey: .termProgram)
    }
}

/// A my-team worker: a Session plus what my-team knows. In JSON the session
/// fields sit flat next to the worker fields. A dead worker stays
/// on the board so the user sees the hole in the team.
@dynamicMemberLookup
public struct Worker: Codable, Hashable, Sendable {
    public var session: Session
    public var workerName: String
    /// `orchestrator`, `worker`, or nil; passed through from my-team unchanged.
    public var role: String?
    public var description: String
    public var paneId: String
    public var alive: Bool
    public var spool: Int
    public var inbox: Int
    public var sentPending: Int
    public var oldestPendingAt: String?
    public var stateFile: StateFile?

    public init(
        session: Session, workerName: String, role: String?, description: String, paneId: String,
        alive: Bool, spool: Int, inbox: Int, sentPending: Int, oldestPendingAt: String?, stateFile: StateFile?
    ) {
        self.session = session
        self.workerName = workerName
        self.role = role
        self.description = description
        self.paneId = paneId
        self.alive = alive
        self.spool = spool
        self.inbox = inbox
        self.sentPending = sentPending
        self.oldestPendingAt = oldestPendingAt
        self.stateFile = stateFile
    }

    public subscript<T>(dynamicMember keyPath: WritableKeyPath<Session, T>) -> T {
        get { session[keyPath: keyPath] }
        set { session[keyPath: keyPath] = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case workerName = "worker_name"
        case role, description
        case paneId = "pane_id"
        case alive, spool, inbox
        case sentPending = "sent_pending"
        case oldestPendingAt = "oldest_pending_at"
        case stateFile = "state_file"
    }

    public init(from decoder: any Decoder) throws {
        session = try Session(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workerName = try c.decode(String.self, forKey: .workerName)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        description = try c.decode(String.self, forKey: .description)
        paneId = try c.decode(String.self, forKey: .paneId)
        alive = try c.decode(Bool.self, forKey: .alive)
        spool = try c.decode(Int.self, forKey: .spool)
        inbox = try c.decode(Int.self, forKey: .inbox)
        sentPending = try c.decode(Int.self, forKey: .sentPending)
        oldestPendingAt = try c.decodeIfPresent(String.self, forKey: .oldestPendingAt)
        stateFile = try c.decodeIfPresent(StateFile.self, forKey: .stateFile)
    }

    public func encode(to encoder: any Encoder) throws {
        try session.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(workerName, forKey: .workerName)
        try c.encode(role, forKey: .role)
        try c.encode(description, forKey: .description)
        try c.encode(paneId, forKey: .paneId)
        try c.encode(alive, forKey: .alive)
        try c.encode(spool, forKey: .spool)
        try c.encode(inbox, forKey: .inbox)
        try c.encode(sentPending, forKey: .sentPending)
        try c.encode(oldestPendingAt, forKey: .oldestPendingAt)
        try c.encode(stateFile, forKey: .stateFile)
    }
}

public struct Team: Codable, Hashable, Sendable {
    public var name: String
    /// tmux session name without the `:0` suffix.
    public var sessionName: String
    public var startedAt: String?
    /// At least one tmux client is attached to the session.
    public var attached: Bool
    public var workers: [Worker]

    public init(name: String, sessionName: String, startedAt: String?, attached: Bool, workers: [Worker]) {
        self.name = name
        self.sessionName = sessionName
        self.startedAt = startedAt
        self.attached = attached
        self.workers = workers
    }

    enum CodingKeys: String, CodingKey {
        case name
        case sessionName = "session_name"
        case startedAt = "started_at"
        case attached, workers
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(sessionName, forKey: .sessionName)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(attached, forKey: .attached)
        try c.encode(workers, forKey: .workers)
    }
}

public struct Board: Codable, Hashable, Sendable {
    /// When this snapshot was collected.
    public var at: String
    /// Live teams only: manifest present and tmux session exists.
    public var teams: [Team]
    /// Sessions that belong to no live team.
    public var loose: [Session]

    public init(at: String, teams: [Team], loose: [Session]) {
        self.at = at
        self.teams = teams
        self.loose = loose
    }
}

public func handleOf(_ tmux: TmuxRef?, pid: Int) -> String {
    if let tmux { return "pane:\(tmux.session):\(tmux.pane)" }
    return "pid:\(pid)"
}

/// Parses the `tmux` field of `~/.claude/sessions/<pid>.json`, e.g. `my-team-x-abc:@5.%42`.
public func parseTmuxTarget(_ value: String?) -> TmuxRef? {
    guard let value, let m = value.wholeMatch(of: #/(.+):(@\d+)\.(%\d+)/#) else { return nil }
    return TmuxRef(session: String(m.1), window: String(m.2), pane: String(m.3))
}
