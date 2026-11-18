import Foundation

/// A decision asked of the user, as `board-status` lists it in `decisions` (T146 data contract, T147): one of
/// board-ask (`D#1`) or a task's wait (`T5:1`). Every field but the id may be missing; the app shows what there is.
public struct BoardDecision: Decodable, Hashable, Sendable {
    public var id: String
    /// The task it waits on (a wait), or nil (board-ask).
    public var taskId: String?
    /// The tasks it serves; a wait's is its own task.
    public var tasks: [String]
    public var open: Bool
    /// question, context, options, recommendation, impact, refs, asked_by and asked_at, read as a task's waiting brief.
    public var brief: TaskWaiting
    /// The option's label the user chose, `기타`, or `철회` for a decision closed without an answer.
    public var chosen: String?
    public var answer: String?
    public var answeredBy: String?
    public var answeredAt: String?

    enum CodingKeys: String, CodingKey { case id, taskId, tasks, state, chosen, answer, answeredBy, answeredAt }

    /// Never throws: a decision with a field of the wrong type keeps the rest, so one bad entry does not fail the
    /// whole board's read (R4 L2).
    public init(from decoder: any Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        id = (try? c?.decodeIfPresent(String.self, forKey: .id)) ?? "?"
        taskId = try? c?.decodeIfPresent(String.self, forKey: .taskId)
        tasks = (try? c?.decodeIfPresent([String].self, forKey: .tasks)) ?? []
        // only "open" waits: an unknown state is not counted as the user's turn (R4 L3)
        open = (try? c?.decodeIfPresent(String.self, forKey: .state)) == "open"
        brief = (try? TaskWaiting(from: decoder)) ?? TaskWaiting()
        chosen = try? c?.decodeIfPresent(String.self, forKey: .chosen)
        answer = try? c?.decodeIfPresent(String.self, forKey: .answer)
        answeredBy = try? c?.decodeIfPresent(String.self, forKey: .answeredBy)
        answeredAt = try? c?.decodeIfPresent(String.self, forKey: .answeredAt)
    }

    /// A waiting task's question, for a board before T146 that lists no decisions.
    public init(waiting t: TaskBoardTask, brief: TaskWaiting) {
        id = "\(t.id):?"
        taskId = t.id
        tasks = [t.id]
        open = true
        self.brief = brief
    }

    /// Every task it is tied to: the one it waits on, then the ones it serves.
    public var related: [String] {
        var seen = Set<String>()
        return ([taskId].compactMap { $0 } + tasks).filter { seen.insert($0).inserted }
    }
}

/// A list pick that names a decision rather than a task: decision ids carry `#` (D#1) or `:` (T5:1), which a task id
/// never does (my-team TASK_ID).
public func isDecisionId(_ id: String) -> Bool { id.contains("#") || id.contains(":") }

/// The board's decisions: its own list, or from its waiting tasks when it is from a my-team before T146, with or
/// without a brief (R4 S1). Decisions without an id are told apart by their place (R4 L3).
public func boardDecisions(_ s: TaskBoardStatus) -> [BoardDecision] {
    guard let listed = s.decisions else {
        return s.tasks.filter { $0.state == "waiting" }.map { BoardDecision(waiting: $0, brief: $0.waiting ?? TaskWaiting()) }
    }
    return listed.enumerated().map { i, d in
        var d = d
        if d.id == "?" { d.id = "?\(i + 1)" }
        return d
    }
}

/// The decisions waiting for the user, in the order asked.
public func openDecisions(_ s: TaskBoardStatus) -> [BoardDecision] {
    boardDecisions(s).filter(\.open).sorted { ($0.brief.askedAt ?? "", $0.id) < ($1.brief.askedAt ?? "", $1.id) }
}

/// The decisions answered or withdrawn, the latest first.
public func pastDecisions(_ s: TaskBoardStatus) -> [BoardDecision] {
    boardDecisions(s).filter { !$0.open }.sorted { ($0.answeredAt ?? "", $0.id) > ($1.answeredAt ?? "", $1.id) }
}

/// The decisions tied to task `id`, open first in the order asked, then the answered, the latest first.
public func decisions(of id: String, in s: TaskBoardStatus) -> [BoardDecision] {
    let mine = { (d: BoardDecision) in d.related.contains(id) }
    return openDecisions(s).filter(mine) + pastDecisions(s).filter(mine)
}

/// The decisions read in this run of the app, to tell a new one from one seen before (T147, T148).
public struct SeenDecisions: Sendable {
    /// The teams read at least once; a team's first read only fills what was seen (R4a L2).
    private var teams: Set<String> = []
    /// Decisions of board-ask, by team and id.
    private var ids: Set<String> = []
    /// Waits by team, task and question: when each was asked, in ms since 1970.
    private var waits: [String: [Double]] = [:]

    /// How far apart two askings of one wait can be stamped: my-team before T148 stamped the brief and the log with two
    /// clock reads, and a board's id for a wait changes with the version (`T1:?` to `T1:1`, R4 L4, R4a L1).
    public static let sameWait: Double = 2_000

    public init() {}

    /// The open decisions of `team`'s read that were not seen before; every decision read is seen from now on. A
    /// team's first read tells nothing, whether it is read at launch or first read later (R4a L2); a team read
    /// before and started again tells what was asked meanwhile (R4 L1).
    public mutating func news(_ s: TaskBoardStatus, team: String) -> [BoardDecision] {
        let first = teams.insert(team).inserted
        return boardDecisions(s).filter { d in insert(d, team: team) && !first && d.open }
    }

    /// Adds `d`; true when it was not seen before.
    private mutating func insert(_ d: BoardDecision, team: String) -> Bool {
        guard let task = d.taskId else { return ids.insert("\(team)\u{0}\(d.id)").inserted }
        let key = "\(team)\u{0}\(task)\u{0}\(d.brief.question)"
        let at = parseISO(d.brief.askedAt) ?? 0
        if waits[key, default: []].contains(where: { abs($0 - at) <= Self.sameWait }) { return false }
        waits[key, default: []].append(at)
        return true
    }
}
