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
    public var baseCommit: String?
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
    public var verdictId: String?
    public var taskId: String
    public var severity: String
    public var summary: String
    public var repro: String?
    public var state: String
    /// The landing that fixed it.
    public var fixedIn: String?
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

public enum TaskBoardFailure: Error, Hashable, Sendable {
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

private struct BoardAnswer: Decodable { var ok: Bool; var code: String?; var message: String? }

/// A `board-status` answer of type T, or why there is none.
func parseBoardAnswer<T: Decodable>(_ r: CommandResult, as: T.Type) -> Result<T, TaskBoardFailure> {
    // runCommand ends a child that outlived its timeout with SIGTERM
    if r.status == SIGTERM && r.stdout.isEmpty { return .failure(.timeout) }
    // 126 and 127: the shell's "cannot run" and "not found", here `env node` with no node
    if r.status == 126 || r.status == 127 { return .failure(.launch(r.stderr.trimmed.nonEmpty ?? "exit \(r.status)")) }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let data = Data(r.stdout.utf8)
    guard let answer = try? decoder.decode(BoardAnswer.self, from: data) else {
        return .failure(.unreadable((r.stdout.trimmed.nonEmpty ?? r.stderr.trimmed).utf16Slice(0, 300)))
    }
    guard answer.ok else { return .failure(.code(answer.code ?? "unknown", answer.message ?? "")) }
    do {
        return .success(try decoder.decode(T.self, from: data))
    } catch {
        return .failure(.unreadable("\(error)".utf16Slice(0, 300)))
    }
}

func parseTaskBoard(_ r: CommandResult) -> TaskBoardRead {
    switch parseBoardAnswer(r, as: TaskBoardStatus.self) {
    case .success(let s): .ok(s)
    case .failure(let f): .failed(f)
    }
}

/// `board-status` for `team`, with `task` for one task's family.
func runBoardStatus<T: Decodable>(team: String, task: String? = nil, bin: String, run: TaskBoardRunner, as: T.Type) -> Result<T, TaskBoardFailure> {
    var input = ["team_name": team]
    input["task"] = task
    let json = String(decoding: try! JSONSerialization.data(withJSONObject: input, options: .sortedKeys), as: UTF8.self)
    do {
        return parseBoardAnswer(try run([bin, "api", "board-status", "--input", json, "--json"], taskBoardTimeout, Set(taskBoardUnset)), as: T.self)
    } catch {
        return .failure(.launch("\(error)"))
    }
}

func readTaskBoard(team: String, bin: String, run: TaskBoardRunner) -> TaskBoardRead {
    switch runBoardStatus(team: team, bin: bin, run: run, as: TaskBoardStatus.self) {
    case .success(let s): .ok(s)
    case .failure(let f): .failed(f)
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

    /// The failure to show: a single busy passes quietly, with or without data on screen (R6 L1).
    public var shownFailure: TaskBoardFailure? { busyStreak == 1 ? nil : failure }

    /// Why the board on screen may be wrong, or nil: a shown failure, or data older than 30 s.
    public func problem(now: Date, bin: String = myTeamBin) -> String? {
        var parts: [String] = []
        if let lastOK, now.timeIntervalSince(lastOK) > 30 {
            let age = Int(now.timeIntervalSince(lastOK))
            // under a minute in seconds: "0분 전" read as now (R6 L2)
            let ago = age < 60 ? "\(age)초" : "\(age / 60)분"
            parts.append("아래는 \(ago) 전(\(boardClock(lastOK))) 내용")
        }
        if let failure = shownFailure {
            let p = taskBoardProblem(failure, bin: bin)
            parts.append("\(p.title) · \(p.detail)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - One task's family (T70a; design §3.3)

public struct TaskBoardLanding: Decodable, Hashable, Sendable {
    public var id: String
    public var taskId: String
    public var commit: String
    public var checkCmd: String?
    public var checkResult: String?
    public var focus: [String]
    public var closes: [String]
    public var reportPath: String?
    public var reviewReportPath: String?
    /// Installed: the board keeps a record there; null when not.
    public var deployed: Bool
    public var supersededBy: String?
    /// Commits of the range the landing did not take in.
    public var leftOut: [String]
    public var createdAt: String?
    public var createdBy: String?

    enum CodingKeys: String, CodingKey {
        case id, taskId, commit, checkCmd, checkResult, focus, closes, reportPath, reviewReportPath, deployed, supersededBy,
             leftOut, createdAt, createdBy
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        taskId = try c.decode(String.self, forKey: .taskId)
        commit = try c.decode(String.self, forKey: .commit)
        checkCmd = try c.decodeIfPresent(String.self, forKey: .checkCmd)
        checkResult = try c.decodeIfPresent(String.self, forKey: .checkResult)
        focus = try c.decodeIfPresent([String].self, forKey: .focus) ?? []
        closes = try c.decodeIfPresent([String].self, forKey: .closes) ?? []
        reportPath = try c.decodeIfPresent(String.self, forKey: .reportPath)
        reviewReportPath = try c.decodeIfPresent(String.self, forKey: .reviewReportPath)
        deployed = (try? c.decodeNil(forKey: .deployed)) == false
        supersededBy = try c.decodeIfPresent(String.self, forKey: .supersededBy)
        leftOut = try c.decodeIfPresent([String].self, forKey: .leftOut) ?? []
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
    }
}

public struct TaskBoardVerdict: Decodable, Hashable, Sendable {
    public var id: String
    public var landingId: String
    /// approve, changes or hold.
    public var verdict: String
    public var reportPath: String?
    public var rerunCmd: String?
    public var rerunResult: String?
    /// A string note; any other shape is left out.
    public var sideNotes: String?
    public var createdAt: String?
    public var createdBy: String?

    enum CodingKeys: String, CodingKey { case id, landingId, verdict, reportPath, rerunCmd, rerunResult, sideNotes, createdAt, createdBy }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        landingId = try c.decode(String.self, forKey: .landingId)
        verdict = try c.decode(String.self, forKey: .verdict)
        reportPath = try c.decodeIfPresent(String.self, forKey: .reportPath)
        rerunCmd = try c.decodeIfPresent(String.self, forKey: .rerunCmd)
        rerunResult = try c.decodeIfPresent(String.self, forKey: .rerunResult)
        sideNotes = try? c.decodeIfPresent(String.self, forKey: .sideNotes)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
    }
}

public struct TaskBoardNote: Decodable, Hashable, Sendable {
    public var seq: Int
    public var taskId: String?
    public var body: String
    /// Empty for a note to no one: the board stores that as null (contract.js: `to: list()`, not required; R6a M1).
    public var to: [String]
    public var createdAt: String?
    public var createdBy: String?

    enum CodingKeys: String, CodingKey { case seq, taskId, body, to, createdAt, createdBy }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        taskId = try c.decodeIfPresent(String.self, forKey: .taskId)
        body = try c.decode(String.self, forKey: .body)
        to = try c.decodeIfPresent([String].self, forKey: .to) ?? []
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
    }
}

/// What `board-status` with `task` answers: the task's root and every task under it, and their records.
public struct TaskFamily: Decodable, Hashable, Sendable {
    public var root: TaskBoardTask
    public var tasks: [TaskBoardTask]
    public var landings: [TaskBoardLanding]
    public var verdicts: [TaskBoardVerdict]
    public var findings: [TaskBoardFinding]
    public var notes: [TaskBoardNote]
}

func parseTaskFamily(_ r: CommandResult) -> Result<TaskFamily, TaskBoardFailure> { parseBoardAnswer(r, as: TaskFamily.self) }

public func readTaskFamily(team: String, task: String) -> Result<TaskFamily, TaskBoardFailure> {
    runBoardStatus(team: team, task: task, bin: myTeamBin, run: liveTaskBoardRunner, as: TaskFamily.self)
}

/// A finding as the detail shows it (design §4.3).
public enum FindingStatus: Hashable, Sendable {
    case open
    /// Fixed in this landing, which no approve covers yet.
    case fixedPending(String)
    case fixedApproved(String)
    case backlog
    case acceptedLimit
    case rejected
    case other(String)
}

public func findingStatus(_ f: TaskBoardFinding, approved: Set<String>) -> FindingStatus {
    switch f.state {
    case "open": .open
    case "fixed": f.fixedIn.map { approved.contains($0) ? .fixedApproved($0) : .fixedPending($0) } ?? .fixedPending("?")
    case "backlog": .backlog
    case "accepted-limit": .acceptedLimit
    case "rejected": .rejected
    default: .other(f.state)
    }
}

public struct VerdictCard: Hashable, Sendable {
    public var verdict: TaskBoardVerdict
    public var findings: [TaskBoardFinding]
}

public struct LandingCard: Hashable, Sendable {
    public var landing: TaskBoardLanding
    public var verdicts: [VerdictCard]
}

public struct TaskDetail: Hashable, Sendable {
    public var task: TaskBoardTask
    /// Root first, then its children by priority and id.
    public var family: [TaskBoardTask]
    /// Every landing of the family in time order, its verdicts and their findings under it.
    public var cards: [LandingCard]
    /// The selected task's findings still open: `open`, or fixed in a landing no approve covers yet.
    public var openFindings: [TaskBoardFinding]
    public var notes: [TaskBoardNote]
    public var approvedLandings: Set<String>
}

private func byTime<T>(_ at: @escaping (T) -> String?) -> (T, T) -> Bool { { (at($0) ?? "") < (at($1) ?? "") } }

public func taskDetail(_ f: TaskFamily, task id: String) -> TaskDetail? {
    guard let task = f.tasks.first(where: { $0.id == id }) else { return nil }
    let approved = Set(f.verdicts.filter { $0.verdict == "approve" }.map(\.landingId))
    let cards = f.landings.sorted(by: byTime(\.createdAt)).map { l in
        LandingCard(landing: l, verdicts: f.verdicts.filter { $0.landingId == l.id }.sorted(by: byTime(\.createdAt)).map { v in
            VerdictCard(verdict: v, findings: f.findings.filter { $0.verdictId == v.id })
        })
    }
    let children = f.tasks.filter { $0.id != f.root.id }.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
    let open = f.findings.filter { $0.taskId == id }.filter {
        switch findingStatus($0, approved: approved) {
        case .open, .fixedPending: true
        default: false
        }
    }
    return TaskDetail(task: task, family: [f.root] + children, cards: cards, openFindings: open,
                      notes: f.notes.sorted { $0.seq < $1.seq }, approvedLandings: approved)
}

/// Superseded cards the user opened stay open over a read while the family still has them.
public func keepOpenLandings(_ open: Set<String>, in d: TaskDetail) -> Set<String> {
    open.intersection(d.cards.map(\.landing.id))
}

/// The worker detail's `작업` line (design §1): unfinished tasks the worker is assignee or reviewer of, in the
/// board's order (action, review, active; each by priority, then id).
public func workerTasks(_ name: String, in s: TaskBoardStatus) -> [TaskBoardTask] {
    let groups = taskGroups(s)
    return [TaskGroup.action, .review, .active].flatMap { groups[$0] ?? [] }.map(\.task)
        .filter { !["done", "cancelled"].contains($0.state) && ($0.assignee == name || $0.reviewer == name) }
}

/// `HH:mm`, or `MM/dd HH:mm`, in the local zone on a 24-hour clock whatever the locale (D1: 16:50, not 04:50).
public func boardClock(_ date: Date, withDay: Bool = false) -> String {
    let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
    let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    return withDay ? String(format: "%02d/%02d ", c.month ?? 0, c.day ?? 0) + time : time
}
