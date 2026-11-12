import Foundation

// The task board of a my-team team (T70; design: board-view.md). Read only, through
// `my-team api board-status --json`: the app never opens board.db and never runs a command that writes.
// "Task board" here, since `Board` is this app's snapshot of sessions.

public struct TaskBoardTask: Decodable, Hashable, Sendable {
    public var id: String
    public var parentId: String?
    public var title: String
    public var ticketPath: String?
    public var state: String
    public var assignee: String?
    public var reviewer: String?
    public var priority: Int
    public var constraints: String?
    public var createdAt: String?
    public var createdBy: String?
    public var updatedAt: String?
}

public struct TaskBoardWorker: Decodable, Hashable, Sendable {
    public var name: String
    public var role: String?
    public var assigned: Int
    public var reviewing: Int
}

public struct TaskBoardFinding: Decodable, Hashable, Sendable {
    public var id: String
    public var taskId: String
    public var severity: String
    public var summary: String
    public var state: String
}

public struct TaskBoardEvent: Decodable, Hashable, Sendable {
    public var seq: Int
    public var at: String
    public var actor: String?
    public var action: String
    public var ref: String?
    public var stateFrom: String?
    public var stateTo: String?
    /// A string detail; any other shape is left out.
    public var detail: String?

    enum CodingKeys: String, CodingKey { case seq, at, actor, action, ref, stateFrom, stateTo, detail }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        at = try c.decode(String.self, forKey: .at)
        actor = try c.decodeIfPresent(String.self, forKey: .actor)
        action = try c.decode(String.self, forKey: .action)
        ref = try c.decodeIfPresent(String.self, forKey: .ref)
        stateFrom = try c.decodeIfPresent(String.self, forKey: .stateFrom)
        stateTo = try c.decodeIfPresent(String.self, forKey: .stateTo)
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
    }
}

public struct TaskBoardAnnouncement: Decodable, Hashable, Sendable {
    public var seq: Int
    public var body: String
    public var createdAt: String?
    public var createdBy: String?
}

/// What `board-status` without a task answers (my-team src/board/core/queries.js, boardStatus).
public struct TaskBoardStatus: Decodable, Hashable, Sendable {
    public var tasks: [TaskBoardTask]
    public var workers: [TaskBoardWorker]
    public var openFindings: [TaskBoardFinding]
    public var recent: [TaskBoardEvent]
    public var announcements: [TaskBoardAnnouncement]
}

public enum TaskBoardFailure: Hashable, Sendable {
    /// my-team (or the node it runs on) could not be started.
    case launch(String)
    /// `{"ok":false,"code","message"}`.
    case code(String, String)
    /// Output that is not the answer, as given.
    case unreadable(String)
    /// No answer within the timeout.
    case timeout
}

public enum TaskBoardRead: Hashable, Sendable {
    case ok(TaskBoardStatus)
    case failed(TaskBoardFailure)
}

/// The variables of a worker's pane: with them, my-team answers for that worker's team only (forbidden).
public let taskBoardUnset = ["MY_TEAM_WORKER", "MY_TEAM_STATE_ROOT", "OMC_TEAM_WORKER"]
let taskBoardTimeout: TimeInterval = 3

/// Runs argv within a timeout without the named variables. Tests pass their own.
typealias TaskBoardRunner = (_ argv: [String], _ timeout: TimeInterval, _ unset: Set<String>) throws -> CommandResult

func liveTaskBoardRunner(_ argv: [String], _ timeout: TimeInterval, _ unset: Set<String>) throws -> CommandResult {
    try runCommand(argv, timeout: timeout, unset: unset)
}

func parseTaskBoard(_ r: CommandResult) -> TaskBoardRead {
    // runCommand ends a child that outlived its timeout with SIGTERM
    if r.status == SIGTERM && r.stdout.isEmpty { return .failed(.timeout) }
    // 126 and 127: the shell's "cannot run" and "not found", here `env node` with no node
    if r.status == 126 || r.status == 127 { return .failed(.launch(r.stderr.trimmed.nonEmpty ?? "exit \(r.status)")) }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let data = Data(r.stdout.utf8)
    struct Answer: Decodable { var ok: Bool; var code: String?; var message: String? }
    guard let answer = try? decoder.decode(Answer.self, from: data) else {
        return .failed(.unreadable((r.stdout.trimmed.nonEmpty ?? r.stderr.trimmed).utf16Slice(0, 300)))
    }
    guard answer.ok else { return .failed(.code(answer.code ?? "unknown", answer.message ?? "")) }
    do {
        return .ok(try decoder.decode(TaskBoardStatus.self, from: data))
    } catch {
        return .failed(.unreadable("\(error)".utf16Slice(0, 300)))
    }
}

func readTaskBoard(team: String, bin: String, run: TaskBoardRunner) -> TaskBoardRead {
    let input = String(decoding: try! JSONSerialization.data(withJSONObject: ["team_name": team]), as: UTF8.self)
    do {
        return parseTaskBoard(try run([bin, "api", "board-status", "--input", input, "--json"], taskBoardTimeout, Set(taskBoardUnset)))
    } catch {
        return .failed(.launch("\(error)"))
    }
}

/// One read per team that keeps a task board; with none, my-team is never run.
func readTaskBoards(_ board: Board, bin: String, run: TaskBoardRunner) -> [String: TaskBoardRead] {
    var out: [String: TaskBoardRead] = [:]
    for t in board.teams where t.hasTaskBoard { out[t.name] = readTaskBoard(team: t.name, bin: bin, run: run) }
    return out
}

public func readTaskBoards(_ board: Board) -> [String: TaskBoardRead] {
    readTaskBoards(board, bin: myTeamBin, run: liveTaskBoardRunner)
}

// MARK: - Groups (design §2)

/// Who has to move, top to bottom.
public enum TaskGroup: Int, CaseIterable, Hashable, Sendable {
    case action, review, active, finished
}

/// Why a task needs pm.
public enum ActionReason: Hashable, Sendable {
    case held
    case unassigned
    case openFindings(Int)
    /// A review request the reviewer cannot work from (queries.js REQUIRED_TASK_FIELDS).
    case incompleteReview(missing: [String])
}

public struct TaskLine: Hashable, Sendable {
    public var task: TaskBoardTask
    /// Listed right under its parent, in the same group.
    public var child: Bool
    public var reasons: [ActionReason]
    public var findingCount: Int
    /// must, should or low: the most severe open finding on this task.
    public var worstSeverity: String?
}

private let severityRank = ["must": 0, "should": 1, "low": 2]

func reasons(_ t: TaskBoardTask, findings: Int) -> [ActionReason] {
    switch t.state {
    case "held": return [.held]
    case "new": return [.unassigned]
    case "done": return findings > 0 ? [.openFindings(findings)] : []
    case "review":
        let missing = [("ticket_path", t.ticketPath), ("constraints", t.constraints)].filter { $0.1?.trimmed.nonEmpty == nil }.map(\.0)
        return missing.isEmpty ? [] : [.incompleteReview(missing: missing)]
    default: return []
    }
}

func group(_ t: TaskBoardTask, reasons: [ActionReason]) -> TaskGroup {
    if !reasons.isEmpty { return .action }
    switch t.state {
    case "review": return .review
    case "done", "cancelled": return .finished
    default: return .active
    }
}

/// Every task in its group, by priority then id (the board's own order); a child right under its parent when both
/// are in one group.
public func taskGroups(_ s: TaskBoardStatus) -> [TaskGroup: [TaskLine]] {
    let byTask = Dictionary(grouping: s.openFindings, by: \.taskId)
    let lines = s.tasks.map { t in
        let f = byTask[t.id] ?? []
        let r = reasons(t, findings: f.count)
        return (group(t, reasons: r), TaskLine(task: t, child: false, reasons: r, findingCount: f.count,
                                               worstSeverity: f.map(\.severity).min { severityRank[$0, default: 3] < severityRank[$1, default: 3] }))
    }
    let order = { (a: TaskLine, b: TaskLine) in (a.task.priority, a.task.id) < (b.task.priority, b.task.id) }
    var out: [TaskGroup: [TaskLine]] = [:]
    for g in TaskGroup.allCases {
        let mine = lines.filter { $0.0 == g }.map(\.1)
        let ids = Set(mine.map(\.task.id))
        let tops = mine.filter { $0.task.parentId.map { !ids.contains($0) } ?? true }.sorted(by: order)
        let rows = tops.flatMap { top in
            [top] + mine.filter { $0.task.parentId == top.task.id }.sorted(by: order).map { var c = $0; c.child = true; return c }
        }
        if !rows.isEmpty { out[g] = rows }
    }
    return out
}

public func actionCount(_ s: TaskBoardStatus) -> Int { taskGroups(s)[.action]?.count ?? 0 }

/// A selected task stays selected over a read while the board still has it.
public func keepTaskSelection(_ id: String?, in s: TaskBoardStatus) -> String? {
    id.flatMap { id in s.tasks.contains { $0.id == id } ? id : nil }
}

// MARK: - Problems (design §5.2)

/// What to tell the user when a read fails: a title, and a line with what to do or the code.
public func taskBoardProblem(_ f: TaskBoardFailure, bin: String) -> (title: String, detail: String) {
    switch f {
    case .launch(let why): ("my-team을 실행하지 못했습니다", "\(bin): \(why)")
    case .code("board-unavailable", let m): ("이 Mac의 Node가 작업판을 열 수 없습니다(Node 22.13 이상 필요)", "board-unavailable: \(m)")
    case .code("schema-too-new", let m): ("이 작업판은 더 새 my-team이 썼습니다. 앱이 쓰는 my-team을 업데이트하세요", "schema-too-new: \(m)")
    case .code("forbidden", let m): ("앱이 다른 팀 워커의 환경으로 실행됐습니다", "forbidden: \(m)")
    case .code(let c, let m): ("작업판을 읽지 못했습니다", "\(c): \(m)")
    case .unreadable(let out): ("작업판을 읽지 못했습니다", "읽을 수 없는 출력: \(out)")
    case .timeout: ("작업판을 읽지 못했습니다", "\(Int(taskBoardTimeout))초 안에 응답이 없습니다")
    }
}

/// One team's board over successive reads: the last good answer stays when a read fails.
public struct TaskBoardState: Hashable, Sendable {
    public private(set) var status: TaskBoardStatus?
    public private(set) var lastOK: Date?
    public private(set) var failure: TaskBoardFailure?
    private var busyStreak = 0

    public init() {}

    public mutating func apply(_ read: TaskBoardRead, at now: Date) {
        switch read {
        case .ok(let s):
            status = s
            lastOK = now
            failure = nil
            busyStreak = 0
        case .failed(let f):
            failure = f
            if case .code("busy", _) = f { busyStreak += 1 } else { busyStreak = 0 }
        }
    }

    /// Why the board on screen may be wrong, or nil: a failure (a single busy passes quietly), or data older than 30 s.
    public func problem(now: Date, bin: String = myTeamBin) -> String? {
        var parts: [String] = []
        if let lastOK, now.timeIntervalSince(lastOK) > 30 {
            let minutes = Int(now.timeIntervalSince(lastOK) / 60)
            parts.append("아래는 \(minutes)분 전(\(lastOK.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))) 내용")
        }
        if let failure, busyStreak != 1 {
            let p = taskBoardProblem(failure, bin: bin)
            parts.append("\(p.title) · \(p.detail)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
