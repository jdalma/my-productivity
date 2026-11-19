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
    /// When the assignee was set: the board keeps no time of `take` (design v3 §2.8 C3).
    public var assignedAt: String?
    public var updatedBy: String?
    /// The question to the user while the task is `waiting` (T115/T116); null, or absent from an older my-team, otherwise.
    public var waiting: TaskWaiting?
    /// The assignee's progress at a glance (T127); null, or absent from an older my-team.
    public var progressSummary: ProgressSummary?
    /// How the task has gone so far (my-team T156); absent from an older my-team, and the line is drawn as before.
    public var history: TaskHistory?
}

/// A task's `history` in `board-status` (my-team T156, tools/my-team/docs/board.md "History"): counted from the
/// board's log. Never throws: a field of the wrong type is as if it were not there, so one bad entry does not fail
/// the whole board's read.
public struct TaskHistory: Decodable, Hashable, Sendable {
    /// The task's `board-land`s, one again while in review included: the open landing is this one.
    public var landings: Int
    /// The `changes` verdicts on those landings: how often the task came back.
    public var changes: Int
    public var lastEvent: TaskEvent?
    /// When the task entered the state it is in; a progress report or a change of reviewer does not move it.
    public var stateSince: String?
    public var lastProgressBy: String?
    /// The state a cancelled task was in; for one cancelled while waiting, the state it waited in.
    public var cancelledFrom: String?

    enum CodingKeys: String, CodingKey { case landings, verdicts, lastEvent, stateSince, lastProgressBy, cancelledFrom }
    enum VerdictKeys: String, CodingKey { case changes }

    public init(from decoder: any Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        landings = (try? c?.decodeIfPresent(Int.self, forKey: .landings)) ?? 0
        changes = (try? c?.nestedContainer(keyedBy: VerdictKeys.self, forKey: .verdicts).decodeIfPresent(Int.self, forKey: .changes)) ?? 0
        lastEvent = try? c?.decodeIfPresent(TaskEvent.self, forKey: .lastEvent)
        stateSince = try? c?.decodeIfPresent(String.self, forKey: .stateSince)
        lastProgressBy = try? c?.decodeIfPresent(String.self, forKey: .lastProgressBy)
        cancelledFrom = try? c?.decodeIfPresent(String.self, forKey: .cancelledFrom)
    }
}

/// The last thing that happened to a task: `action` is add, assign, take, land, verdict, wait, answer or cancel; a
/// progress report, a note and a finding are no event.
public struct TaskEvent: Decodable, Hashable, Sendable {
    public var action: String
    /// approve, changes or hold on a verdict; nil otherwise.
    public var verdict: String?
    public var by: String?
    public var at: String?
    public var stateFrom: String?
    public var stateTo: String?
}

/// When the task entered the state it is in: the board's own word for it (T156), else the last change of the task,
/// which a change of reviewer moves too, else when it was made. A value that does not read as a time is passed
/// over (R18 L1): an empty `state_since` would leave the line without its time.
public func stateSince(_ t: TaskBoardTask) -> String? {
    [t.history?.stateSince, t.updatedAt, t.createdAt].lazy.compactMap { $0 }.first { parseISO($0) != nil }
}

/// The task's last event when it came after its last progress record, or there is no record: what the line's second
/// line says in place of the record (v4 §7.2). nil from a board without `history`.
public func eventAfterProgress(_ t: TaskBoardTask) -> TaskEvent? {
    guard let e = t.history?.lastEvent else { return nil }
    guard let note = t.progressSummary?.lastNote, !note.isEmpty, let recorded = parseISO(t.progressSummary?.lastAt) else { return e }
    return parseISO(e.at).map { $0 > recorded } == true ? e : nil
}

/// A task waiting on the user's decision: a brief to decide from without reading anything else (T116 data contract,
/// announcement 15). Each field may be missing from a board that wrote less; the app shows what there is.
public struct TaskWaiting: Decodable, Hashable, Sendable {
    public var question: String
    /// Why the decision is needed now, what is stopped, the facts already checked.
    public var context: String?
    public var options: [DecisionOption]
    /// Options the board gave that could not be read (R41 L3): left out, and the card says so.
    public var unreadOptions: Int
    public var recommendation: DecisionRecommendation?
    /// What stays stopped while undecided, and what a wrong choice costs to undo.
    public var impact: String?
    public var refs: [String]
    public var askedBy: String?
    public var askedAt: String?
    /// The state the task goes back to once answered.
    public var resumeState: String?

    enum CodingKeys: String, CodingKey { case question, context, options, recommendation, impact, refs, askedBy, askedAt, resumeState }

    /// A brief with nothing in it: a waiting task the board kept no brief for (T147, R4 S1).
    public init(question: String = "") {
        self.question = question
        options = []
        unreadOptions = 0
        refs = []
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
        context = try c.decodeIfPresent(String.self, forKey: .context)
        let all = (try? c.decodeIfPresent([Lossy<DecisionOption>].self, forKey: .options)) ?? []
        options = all.compactMap(\.value)
        unreadOptions = all.count - options.count
        recommendation = try? c.decodeIfPresent(DecisionRecommendation.self, forKey: .recommendation)
        impact = try c.decodeIfPresent(String.self, forKey: .impact)
        refs = (try? c.decodeIfPresent([String].self, forKey: .refs)) ?? []
        askedBy = try c.decodeIfPresent(String.self, forKey: .askedBy)
        askedAt = try c.decodeIfPresent(String.self, forKey: .askedAt)
        resumeState = try c.decodeIfPresent(String.self, forKey: .resumeState)
    }
}

/// One element of a list, or nil when it does not read: the rest of the list still does.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

/// One choice of a decision brief.
public struct DecisionOption: Decodable, Hashable, Sendable {
    public var label: String
    public var detail: String?
    public var pros: [String]
    public var cons: [String]

    enum CodingKeys: String, CodingKey { case label, detail, pros, cons }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? "?"
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        pros = try c.decodeIfPresent([String].self, forKey: .pros) ?? []
        cons = try c.decodeIfPresent([String].self, forKey: .cons) ?? []
    }
}

public struct DecisionRecommendation: Decodable, Hashable, Sendable {
    /// The recommended option's label; nil when the asker recommends none, and says why in `reason`.
    public var option: String?
    public var reason: String?

    public init(option: String?, reason: String?) {
        self.option = option
        self.reason = reason
    }
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
    /// approve, changes or hold: a verdict event's `detail.verdict`.
    public var verdict: String?
    /// The task a land event's landing is for (`detail.task`), or a verdict event's landing (`detail.landing`).
    public var task: String?
    public var landing: String?

    enum CodingKeys: String, CodingKey { case seq, at, actor, action, ref, stateFrom, stateTo, detail }
    private struct Detail: Decodable { var verdict: String?; var task: String?; var landing: String? }

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
        let d = try? c.decodeIfPresent(Detail.self, forKey: .detail)
        verdict = d?.verdict
        task = d?.task
        landing = d?.landing
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
    /// Every decision asked of the user (T146); nil from a my-team before T146, whose waiting tasks stand for them.
    public var decisions: [BoardDecision]? = nil
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
    // runCommand ends a child that outlived its timeout with SIGTERM, and one that ignores it with SIGKILL
    if [SIGTERM, SIGKILL].contains(r.status) && r.stdout.isEmpty { return .failure(.timeout) }
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

/// `my-team api <command>` with `input`, as it came back, or why it could not be started.
func runMyTeamApi(_ command: String, input: [String: String], bin: String, run: TaskBoardRunner) -> Result<CommandResult, TaskBoardFailure> {
    let json = String(decoding: try! JSONSerialization.data(withJSONObject: input, options: .sortedKeys), as: UTF8.self)
    do {
        return .success(try run([bin, "api", command, "--input", json, "--json"], taskBoardTimeout, Set(taskBoardUnset)))
    } catch {
        return .failure(.launch("\(error)"))
    }
}

/// `board-status` for `team`, with `task` for one task's family.
func runBoardStatus<T: Decodable>(team: String, task: String? = nil, bin: String, run: TaskBoardRunner, as: T.Type) -> Result<T, TaskBoardFailure> {
    var input = ["team_name": team]
    input["task"] = task
    return runMyTeamApi("board-status", input: input, bin: bin, run: run).flatMap { parseBoardAnswer($0, as: T.self) }
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

// MARK: - Panels (design v4 §7.1, T152)

/// The board's areas, by task state: what has not started, the user's open decisions (not tasks), what the assignee
/// holds, what the reviewer holds, what is held, what is over. The cases are in the user's default order (11-16).
public enum TaskPanel: String, CaseIterable, Hashable, Sendable {
    case start, decisions, doing, review, held, done
}

/// The state a task is at: a waiting task's is the one it goes back to once answered, since the wait is a stop on
/// top of where it is, not a place of its own (v4 §7.1).
public func standingState(_ t: TaskBoardTask) -> String {
    t.state == "waiting" ? (t.waiting?.resumeState ?? "doing") : t.state
}

/// The panel of a task: an unknown state goes on as in progress, as it did before.
public func panel(of t: TaskBoardTask) -> TaskPanel {
    switch standingState(t) {
    case "new", "ready": .start
    case "review": .review
    case "held": .held
    case "done", "cancelled": .done
    default: .doing
    }
}

/// How far a task has come (v4 §7.2): 등록, 배정, 작업, 리뷰, 끝. A cancelled task's is where it stopped, when the
/// board says what state it was cancelled from (T156); unknown from an older my-team.
public enum TaskStep: Int, CaseIterable, Hashable, Sendable {
    case registered, assigned, working, review, done
}

public func taskStep(_ t: TaskBoardTask) -> TaskStep? {
    t.state == "cancelled" ? t.history?.cancelledFrom.flatMap(step(ofState:)) : step(ofState: standingState(t))
}

private func step(ofState state: String) -> TaskStep? {
    switch state {
    case "new": .registered
    case "ready": .assigned
    case "review", "held": .review
    case "done": .done
    case "cancelled": nil
    default: .working
    }
}

/// Why it is pm's move (v4 §7.1, S2): the line's `pm 차례` tag.
public enum ActionReason: Hashable, Sendable {
    case held
    case unassigned
    case openFindings(Int)
    /// A review request the reviewer cannot work from (queries.js REQUIRED_TASK_FIELDS).
    case incompleteReview(missing: [String])
}

public struct TaskLine: Hashable, Sendable {
    public var task: TaskBoardTask
    /// Listed right under its parent, in the same panel.
    public var child: Bool
    public var reasons: [ActionReason]
    public var findingCount: Int
    /// The open findings by severity, most severe first.
    public var severities: [SeverityCount] = []
    /// The open decisions this task waits on (S6), whether or not the task is `waiting`.
    public var decisions: [String] = []
}

public struct SeverityCount: Hashable, Sendable {
    public var severity: String
    public var count: Int
}

private let severityRank = ["must": 0, "should": 1, "low": 2]

/// A finished task with any open finding is pm's to tidy; a finding fixed in a landing no approve covers yet is open
/// here (the board lists it so).
func reasons(_ t: TaskBoardTask, findings: [TaskBoardFinding]) -> [ActionReason] {
    switch t.state {
    case "held": return [.held]
    case "new": return [.unassigned]
    case "done": return findings.isEmpty ? [] : [.openFindings(findings.count)]
    case "review":
        let missing = [("ticket_path", t.ticketPath), ("constraints", t.constraints)].filter { $0.1?.trimmed.nonEmpty == nil }.map(\.0)
        return missing.isEmpty ? [] : [.incompleteReview(missing: missing)]
    default: return []
    }
}

/// Every task in its panel, by priority then id (the board's own order); a child right under its parent when both
/// are in one panel. `.decisions` has no tasks; a panel with none has an empty list.
public func taskPanels(_ s: TaskBoardStatus) -> [TaskPanel: [TaskLine]] {
    let byTask = Dictionary(grouping: s.openFindings, by: \.taskId)
    let open = openDecisions(s)
    let lines = s.tasks.map { t in
        let f = byTask[t.id] ?? []
        let counts = Dictionary(grouping: f, by: \.severity)
            .map { SeverityCount(severity: $0.key, count: $0.value.count) }
            .sorted { (severityRank[$0.severity, default: 3], $0.severity) < (severityRank[$1.severity, default: 3], $1.severity) }
        return TaskLine(task: t, child: false, reasons: reasons(t, findings: f), findingCount: f.count, severities: counts,
                        decisions: open.filter { $0.related.contains(t.id) }.map(\.id))
    }
    let order = { (a: TaskLine, b: TaskLine) in (a.task.priority, a.task.id) < (b.task.priority, b.task.id) }
    var out: [TaskPanel: [TaskLine]] = [:]
    for p in TaskPanel.allCases {
        let mine = lines.filter { panel(of: $0.task) == p && p != .decisions }
        let ids = Set(mine.map(\.task.id))
        let tops = mine.filter { $0.task.parentId.map { !ids.contains($0) } ?? true }.sorted(by: order)
        out[p] = tops.flatMap { top in
            [top] + mine.filter { $0.task.parentId == top.task.id }.sorted(by: order).map { var c = $0; c.child = true; return c }
        }
    }
    return out
}

/// Shown at most in the done panel until "모두 보기" (pm decision 7).
public let finishedShown = 5

/// What the user set for a team's board, kept across launches (v4 §7.7, §7.9.6): the folded panels, the panels' order,
/// the tasks put on top of each panel, and each panel's height. The app writes none of it to the board.
public struct TaskPanelPrefs: Codable, Hashable, Sendable {
    /// Panel names, so a name a later app drops reads as nothing rather than failing the rest.
    private var foldedNames: [String] = []
    /// The columns left to right, each its panels top to bottom (T154). One column is what T153 kept, and reads as such.
    private var columns: [[String]] = []
    /// Each panel's height in points at font scale 1; a panel not here fits its lines.
    private var heights: [String: Double] = [:]
    /// The tasks the user put on top of each panel, in the user's order (v4 §7.9.1).
    private var pinned: [String: [String]] = [:]
    /// The board's last view, `panels` or `order` (T214, goal-order-view §1); nil for the panels.
    public var view: String?
    /// Each goal the user folded (true) or opened (false) in the 순서 view, by its file's path (goal-order-view §2).
    public var goalFolds: [String: Bool] = [:]

    public init(folded: Set<TaskPanel> = []) { fold(folded) }

    public var folded: Set<TaskPanel> { Set(foldedNames.compactMap(TaskPanel.init(rawValue:))) }

    public func isFolded(_ p: TaskPanel) -> Bool { folded.contains(p) }

    public mutating func setFolded(_ p: TaskPanel, _ on: Bool) {
        foldedNames.removeAll { $0 == p.rawValue }
        if on { foldedNames.append(p.rawValue) }
    }

    private mutating func fold(_ ps: Set<TaskPanel>) { for p in TaskPanel.allCases where ps.contains(p) { setFolded(p, true) } }

    enum CodingKeys: String, CodingKey { case foldedNames = "folded", columns, heights, pinned, view, goalFolds = "goal_folds" }

    /// Never throws: one team's value, or one of its fields, that does not read is nothing for that team or field,
    /// not for every team (R9 L3).
    public init(from decoder: any Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        foldedNames = (try? c?.decodeIfPresent([String].self, forKey: .foldedNames)) ?? []
        columns = (try? c?.decodeIfPresent([[String]].self, forKey: .columns)) ?? []
        heights = (try? c?.decodeIfPresent([String: Double].self, forKey: .heights)) ?? [:]
        pinned = (try? c?.decodeIfPresent([String: [String]].self, forKey: .pinned)) ?? [:]
        view = try? c?.decodeIfPresent(String.self, forKey: .view)
        goalFolds = (try? c?.decodeIfPresent([String: Bool].self, forKey: .goalFolds)) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(foldedNames, forKey: .foldedNames)
        if !columns.isEmpty { try c.encode(columns, forKey: .columns) }
        if !heights.isEmpty { try c.encode(heights, forKey: .heights) }
        if !pinned.isEmpty { try c.encode(pinned, forKey: .pinned) }
        if let view { try c.encode(view, forKey: .view) }
        if !goalFolds.isEmpty { try c.encode(goalFolds, forKey: .goalFolds) }
    }

    // MARK: The panels' places

    /// The columns left to right, each top to bottom (v4 §7.8): the stored ones without unknown or repeated names and
    /// without a column left empty, then the panels they lack at the end of the last column, in the default order.
    public var layout: [[TaskPanel]] {
        var seen = Set<TaskPanel>()
        var cols = columns.map { $0.compactMap(TaskPanel.init(rawValue:)).filter { seen.insert($0).inserted } }.filter { !$0.isEmpty }
        let missing = TaskPanel.allCases.filter { !seen.contains($0) }
        if cols.isEmpty { return [missing] }
        cols[cols.count - 1] += missing
        return cols
    }

    /// The panels in reading order: the first column top to bottom, then the next. What ↑ and ↓ follow, and what a
    /// list too narrow for the columns shows.
    public var order: [TaskPanel] { layout.flatMap { $0 } }

    /// The columns on screen in a list with room for `room` of them: the layout, or, with more columns than fit, all
    /// of it as one column in reading order. What is kept does not change with the window's width (hig D8).
    public func shownColumns(room: Int) -> [[TaskPanel]] { layout.count <= room ? layout : [order] }

    private func with(_ cols: [[TaskPanel]]) -> TaskPanelPrefs {
        var out = self
        out.columns = cols.filter { !$0.isEmpty }.map { $0.map(\.rawValue) }
        return out
    }

    private func place(of p: TaskPanel, in cols: [[TaskPanel]]) -> (column: Int, row: Int)? {
        for (c, col) in cols.enumerated() { if let i = col.firstIndex(of: p) { return (c, i) } }
        return nil
    }

    /// `p` moved `by` places up (−) or down (+): within its column while the columns are on screen (`room` holds
    /// them), by reading order while they are shown as one. Nil where it cannot go.
    public func moving(_ p: TaskPanel, by: Int, room: Int = 1) -> TaskPanelPrefs? {
        guard layout.count <= room else {
            // a place at a time, each past the panel next to it and into that panel's column
            var out = self
            for _ in 0..<abs(by) {
                guard let next = out.passing(p, down: by > 0) else { return nil }
                out = next
            }
            return by == 0 ? nil : out
        }
        var cols = layout
        guard let at = place(of: p, in: cols), cols[at.column].indices.contains(at.row + by) else { return nil }
        cols[at.column].swapAt(at.row, at.row + by)
        return with(cols)
    }

    /// `p` moved past the panel next to it in reading order, into that panel's column: after the one below, or before
    /// the one above. The two swap in what a narrow list shows, and neither changes column unless `p` crosses from
    /// one column to the next (R21 L1). Nil at the ends.
    private func passing(_ p: TaskPanel, down: Bool) -> TaskPanelPrefs? {
        let o = order
        guard let i = o.firstIndex(of: p), o.indices.contains(i + (down ? 1 : -1)) else { return nil }
        let neighbor = o[i + (down ? 1 : -1)]
        var cols = layout.map { $0.filter { $0 != p } }
        guard let at = place(of: neighbor, in: cols) else { return nil }
        cols[at.column].insert(p, at: at.row + (down ? 1 : 0))
        return with(cols)
    }

    /// `p` put before the panel at `index` of the reading order, in that panel's column; past the last, at the end of
    /// the last column (v4 §7.8: an order changed in a narrow list still fits the columns). Nil when the order stays.
    public func placing(_ p: TaskPanel, at index: Int) -> TaskPanelPrefs? {
        let o = order
        guard o.contains(p) else { return nil }
        var cols = layout.map { $0.filter { $0 != p } }
        if o.indices.contains(index), o[index] != p, let at = place(of: o[index], in: cols) {
            cols[at.column].insert(p, at: at.row)
        } else if index >= o.count {
            cols[cols.count - 1].append(p)
        } else {
            return nil
        }
        let next = with(cols)
        return next.order == o ? nil : next
    }

    /// `p` moved to the column on its left (−1) or right (+1), as far down as it was, the column's end at most. One
    /// past the last column makes a new column while `room` has space for it and `p` leaves a panel behind. Nil where
    /// it cannot go, and while the columns are shown as one for lack of room.
    public func moving(_ p: TaskPanel, toColumn by: Int, room: Int) -> TaskPanelPrefs? {
        var cols = layout
        guard cols.count <= room, let at = place(of: p, in: cols) else { return nil }
        let to = at.column + by
        guard to >= 0, to < cols.count || (to == cols.count && cols.count < room && cols[at.column].count > 1) else { return nil }
        cols[at.column].remove(at: at.row)
        if to == cols.count { cols.append([p]) } else { cols[to].insert(p, at: min(at.row, cols[to].count)) }
        return with(cols)
    }

    /// `p` dropped in column `column` before its panel at `slot`, at its end past the last; a column one past the
    /// last is a new one. Nil when nothing changes.
    public func dropping(_ p: TaskPanel, column: Int, at slot: Int) -> TaskPanelPrefs? {
        var cols = layout
        guard let at = place(of: p, in: cols), (0...cols.count).contains(column) else { return nil }
        cols[at.column].remove(at: at.row)
        if column == cols.count {
            guard !cols[at.column].isEmpty else { return nil }
            cols.append([p])
        } else {
            let to = column == at.column && slot > at.row ? slot - 1 : slot
            cols[column].insert(p, at: min(max(to, 0), cols[column].count))
        }
        let next = with(cols)
        return next.layout == layout ? nil : next
    }

    /// The default layout (v4 §7.9.6): the panels' order, every pin and every height back; the folds, the view and
    /// the goals' folds stay.
    public var resetLayout: TaskPanelPrefs {
        var out = TaskPanelPrefs()
        out.foldedNames = foldedNames
        out.view = view
        out.goalFolds = goalFolds
        return out
    }

    public var hasLayout: Bool { !columns.isEmpty || !heights.isEmpty || !pinned.isEmpty }

    /// These prefs with `other`'s layout (order, tasks on top, heights) and their own folds: ⌘Z takes back a layout
    /// change and nothing done since, a fold or a panel a new decision opened (R17 S2).
    public func withLayout(of other: TaskPanelPrefs) -> TaskPanelPrefs {
        var out = self
        out.columns = other.columns
        out.heights = other.heights
        out.pinned = other.pinned
        return out
    }

    // MARK: Heights

    /// The height set for `p`, in points at font scale 1; nil fits its lines.
    public func height(_ p: TaskPanel) -> Double? { heights[p.rawValue] }

    public func setting(height: Double?, for p: TaskPanel) -> TaskPanelPrefs {
        var out = self
        out.heights[p.rawValue] = height
        return out
    }

    /// A height dragged to `h` (v4 §7.9.5, pm 5): held at `least` (three lines) and `most` (the list less a head); as
    /// tall as the lines or taller, it fits them (nil).
    public static func fitted(_ h: Double, least: Double, content: Double, most: Double) -> Double? {
        guard h < content - 0.5 else { return nil }
        let top = min(most, content)
        return least < top ? min(max(h, least), top) : nil
    }

    // MARK: Tasks on top

    /// The tasks put on top of `p`, in order.
    public func pins(_ p: TaskPanel) -> [String] { pinned[p.rawValue] ?? [] }

    /// A panel's lines (v4 §7.9.1): the ones put on top first, in the user's order, then the rest in the board's.
    public func arranging(_ lines: [TaskLine], in p: TaskPanel) -> (top: [TaskLine], rest: [TaskLine]) {
        let mine = pins(p)
        let top = mine.compactMap { id in lines.first { $0.task.id == id } }.map { var l = $0; l.child = false; return l }
        let on = Set(top.map(\.task.id))
        let rest = lines.filter { !on.contains($0.task.id) }
        let restIds = Set(rest.map(\.task.id))
        return (top, rest.map { var l = $0; l.child = l.child && l.task.parentId.map(restIds.contains) == true; return l })
    }

    /// Without the tasks no longer in the panel they were put on top of (v4 §7.9.3): moved to another state, or gone.
    /// Back later, they are not on top again.
    public func cleaned(_ panels: [TaskPanel: [TaskLine]]) -> TaskPanelPrefs {
        var out = self
        for (name, ids) in pinned {
            let here = Set((TaskPanel(rawValue: name).flatMap { panels[$0] } ?? []).map(\.task.id))
            let kept = ids.filter(here.contains)
            out.pinned[name] = kept.isEmpty ? nil : kept
        }
        return out
    }

    /// A task moved within its panel by the menu (v4 §7.9.1): up and to the top put a line from the rest at the end
    /// and at the front of the ones on top; down works on the ones on top; unpin sends it back. Nil where it cannot.
    public func moving(task id: String, in p: TaskPanel, _ move: TaskMove) -> TaskPanelPrefs? {
        var mine = pins(p)
        let i = mine.firstIndex(of: id)
        switch (move, i) {
        case (.up, nil): mine.append(id)
        case (.up, let i?): guard i > 0 else { return nil }; mine.swapAt(i, i - 1)
        case (.down, let i?): guard i < mine.count - 1 else { return nil }; mine.swapAt(i, i + 1)
        case (.down, nil): return nil
        case (.top, let i?): guard i > 0 else { return nil }; mine.remove(at: i); mine.insert(id, at: 0)
        case (.top, nil): mine.insert(id, at: 0)
        case (.unpin, let i?): mine.remove(at: i)
        case (.unpin, nil): return nil
        }
        var out = self
        out.pinned[p.rawValue] = mine.isEmpty ? nil : mine
        return out
    }

    /// A line dropped before the line at `slot` of the panel's lines on screen (top then rest), `slot` past the end
    /// for the last (v4 §7.9.1 table): among the ones on top it goes there; among the rest a line from the rest goes
    /// to the end of the ones on top and one from the top goes back. Nil when that changes nothing.
    public func dropping(task id: String, in p: TaskPanel, at slot: Int) -> TaskPanelPrefs? {
        var mine = pins(p)
        let from = mine.firstIndex(of: id)
        if slot <= mine.count {
            if let from { mine.remove(at: from) }
            mine.insert(id, at: min(from.map { slot > $0 ? slot - 1 : slot } ?? slot, mine.count))
        } else if from != nil {
            mine.removeAll { $0 == id }
        } else {
            mine.append(id)
        }
        guard mine != pins(p) else { return nil }
        var out = self
        out.pinned[p.rawValue] = mine.isEmpty ? nil : mine
        return out
    }
}

/// The least width of a column of panels at font scale 1 (v4 §7.8: a compact line is not cut), and the gap between
/// two columns.
public let panelColumnWidth = 520.0, panelColumnGap = 12.0

/// How many columns of panels a list `width` wide has room for at font scale `scale` (v4 §7.8): one at least.
public func panelColumnsFitting(width: Double, scale: Double) -> Int {
    max(1, Int((width + panelColumnGap) / (panelColumnWidth * scale + panelColumnGap)))
}

/// How the menu moves a task within its panel (v4 §7.9.1).
public enum TaskMove: CaseIterable, Hashable, Sendable {
    case up, down, top, unpin
}

/// The panels whose lines the user can order: not 끝남, whose last few are the latest, and not the decisions, kept
/// in the order asked (pm 4).
public func ordersLines(_ p: TaskPanel) -> Bool { ![.done, .decisions].contains(p) }

/// Every team's prefs as one stored string; one that does not read is no prefs.
public func readPanelPrefs(_ stored: String) -> [String: TaskPanelPrefs] {
    (try? JSONDecoder().decode([String: TaskPanelPrefs].self, from: Data(stored.utf8))) ?? [:]
}

public func storedPanelPrefs(_ prefs: [String: TaskPanelPrefs]) -> String {
    let e = JSONEncoder()
    e.outputFormatting = .sortedKeys
    return (try? e.encode(prefs)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
}

/// Opens the folded decisions panel once when a decision not in `before` comes (v4 §7.7): the user has not seen it.
/// `before` is nil on the window's first read, which tells nothing new.
public func unfoldingForNewDecisions(_ prefs: TaskPanelPrefs, before: Set<String>?, now: Set<String>) -> TaskPanelPrefs {
    guard let before, !now.subtracting(before).isEmpty else { return prefs }
    var p = prefs
    p.setFolded(.decisions, false)
    return p
}

/// Opens the panel of a task or decision picked from elsewhere (v4 §7.7): the user came to see it. Not while a search
/// runs, which shows it anyway and folds back once cleared (R9 L1).
public func unfoldingForPick(_ prefs: TaskPanelPrefs, pick: String?, in s: TaskBoardStatus, searching: Bool) -> TaskPanelPrefs {
    guard let pick, !searching else { return prefs }
    let p: TaskPanel? = isDecisionId(pick) ? .decisions : s.tasks.first { $0.id == pick }.map { panel(of: $0) }
    guard let p, prefs.isFolded(p) else { return prefs }
    var out = prefs
    out.setFolded(p, false)
    return out
}

/// The ids on screen top to bottom, as ↑ and ↓ go through them: the open decisions in their panel, the tasks in
/// theirs; a folded panel's lines are not on screen, unless a search runs. The done panel shows its first
/// `finishedShown` unless `doneOpen`.
public func visibleIds(order: [TaskPanel], panels: [TaskPanel: [TaskLine]], decisions: [String], prefs: TaskPanelPrefs,
                       searching: Bool, doneOpen: Bool) -> [String] {
    order.flatMap { p -> [String] in
        guard searching || !prefs.isFolded(p) else { return [] }
        if p == .decisions { return decisions }
        let ids = (panels[p] ?? []).map(\.task.id)
        return p == .done && !(doneOpen || searching) ? Array(ids.prefix(finishedShown)) : ids
    }
}

/// The id `by` lines from `id` in `ids`, held at the ends; the first (or last, going up) when nothing is picked.
public func step(_ ids: [String], from id: String?, by: Int) -> String? {
    guard !ids.isEmpty else { return nil }
    guard let id, let i = ids.firstIndex(of: id) else { return by < 0 ? ids.last : ids.first }
    return ids[min(max(i + by, 0), ids.count - 1)]
}

/// A selected task or decision stays selected over a read while the board still has it.
public func keepTaskSelection(_ id: String?, in s: TaskBoardStatus) -> String? {
    id.flatMap { id in s.tasks.contains { $0.id == id } || boardDecisions(s).contains { $0.id == id } ? id : nil }
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

    /// Over the list when what it shows may be old (D §2.9), or nil: when it was read and how long ago, once it is
    /// older than 30 s or the last read failed, and why that read failed.
    public func problem(now: Date, bin: String = myTeamBin) -> String? {
        let failure = shownFailure.map { taskBoardProblem($0, bin: bin) }.map { "\($0.title)(\($0.detail))" }
        guard let lastOK else { return failure }
        let age = Int(now.timeIntervalSince(lastOK))
        guard failure != nil || age > 30 else { return nil }
        // under a minute in seconds: "0분 전" read as now (R6 L2)
        let ago = age < 60 ? "\(age)초" : "\(age / 60)분"
        return (["\(boardClock(lastOK))에 읽은 내용입니다(\(ago) 전)"] + (failure.map { [$0] } ?? [])).joined(separator: " · ")
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
    /// The family's findings fixed in other families' landings (T87), whose verdicts `verdicts` does not hold;
    /// nil from a my-team before T87.
    public var fixedElsewhere: [OutsideFix]?
    /// The user's answers to the family's questions (T116); empty from a my-team before T115.
    public var answers: [TaskAnswer]
    /// The asked task's progress records in time order (T127); empty from a my-team before T127.
    public var progress: [TaskProgress]

    enum CodingKeys: String, CodingKey { case root, tasks, landings, verdicts, findings, notes, fixedElsewhere, answers, progress }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decode(TaskBoardTask.self, forKey: .root)
        tasks = try c.decode([TaskBoardTask].self, forKey: .tasks)
        landings = try c.decode([TaskBoardLanding].self, forKey: .landings)
        verdicts = try c.decode([TaskBoardVerdict].self, forKey: .verdicts)
        findings = try c.decode([TaskBoardFinding].self, forKey: .findings)
        notes = try c.decode([TaskBoardNote].self, forKey: .notes)
        fixedElsewhere = try c.decodeIfPresent([OutsideFix].self, forKey: .fixedElsewhere)
        answers = try c.decodeIfPresent([TaskAnswer].self, forKey: .answers) ?? []
        progress = try c.decodeIfPresent([TaskProgress].self, forKey: .progress) ?? []
    }
}

/// The user's answer to a task's question, as pm recorded it (T116 data contract).
public struct TaskAnswer: Decodable, Hashable, Sendable {
    public var taskId: String
    public var question: String?
    /// The option's label the user chose, or "기타".
    public var chosen: String?
    public var answer: String
    public var answeredBy: String?
    public var answeredAt: String?
    /// The brief as it was when answered, when the board keeps it.
    public var brief: TaskWaiting?

    enum CodingKeys: String, CodingKey { case taskId, question, chosen, answer, answeredBy, answeredAt, brief }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try c.decode(String.self, forKey: .taskId)
        question = try c.decodeIfPresent(String.self, forKey: .question)
        chosen = try c.decodeIfPresent(String.self, forKey: .chosen)
        answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
        answeredBy = try c.decodeIfPresent(String.self, forKey: .answeredBy)
        answeredAt = try c.decodeIfPresent(String.self, forKey: .answeredAt)
        brief = try? c.decodeIfPresent(TaskWaiting.self, forKey: .brief)
    }
}

/// A landing of another family that fixed one of this family's findings, and whether a verdict approved it.
public struct OutsideFix: Decodable, Hashable, Sendable {
    public var landing: String
    public var taskId: String?
    public var approved: Bool
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

/// Where a finding stands in the detail (design v3 §3.3): still to do, fixed and approved, or settled without a fix.
public enum FindingPile: CaseIterable, Hashable, Sendable {
    /// Open, or fixed in a submission no approve covers yet.
    case open
    case fixed
    /// Backlog, accepted as a limit, rejected.
    case settled
}

/// One of the selected task's findings: its status and the submission whose review raised it.
public struct DetailFinding: Hashable, Sendable {
    public var finding: TaskBoardFinding
    public var status: FindingStatus
    /// The landing the raising verdict reviewed; nil when the family does not hold that verdict.
    public var raisedIn: String?

    public var pile: FindingPile {
        switch status {
        case .open, .fixedPending: .open
        case .fixedApproved: .fixed
        case .backlog, .acceptedLimit, .rejected, .other: .settled
        }
    }
}

/// Another task's landing that fixed some of the selected task's findings (T87 `fixed_elsewhere`).
public struct FixElsewhere: Hashable, Sendable {
    public var task: String
    public var landing: String
    public var approved: Bool
    public var findings: [String]
}

/// `T75#2` → 2: the n-th submission of its task.
public func submissionNumber(_ landing: String) -> Int? {
    landing.firstIndex(of: "#").flatMap { Int(landing[landing.index(after: $0)...]) }
}

/// `T75#2` → `T75`.
public func landingTask(_ landing: String) -> String {
    landing.firstIndex(of: "#").map { String(landing[..<$0]) } ?? landing
}

public struct TaskDetail: Hashable, Sendable {
    public var task: TaskBoardTask
    /// Root first, then its children by priority and id.
    public var family: [TaskBoardTask]
    /// Every landing of the family in time order, its verdicts and their findings under it.
    public var cards: [LandingCard]
    /// The selected task's findings, in the board's order.
    public var findings: [DetailFinding]
    /// Fixes of the selected task's findings in other families' landings.
    public var elsewhere: [FixElsewhere]
    public var notes: [TaskBoardNote]
    public var approvedLandings: Set<String>
    /// The user's answers to the selected task's questions, in time order.
    public var answers: [TaskAnswer] = []
    /// The assignee's progress records (T127): a family is read for the task it shows.
    public var progress: [TaskProgress] = []

    /// The selected task's findings still open: `open`, or fixed in a landing no approve covers yet.
    public var openFindings: [TaskBoardFinding] { findings.filter { $0.pile == .open }.map(\.finding) }

    /// The selected task's own landings, in time order.
    public var submissions: [LandingCard] { cards.filter { $0.landing.taskId == task.id } }

    public func pile(_ p: FindingPile) -> [DetailFinding] { findings.filter { $0.pile == p } }
}

private func byTime<T>(_ at: @escaping (T) -> String?) -> (T, T) -> Bool { { (at($0) ?? "") < (at($1) ?? "") } }

public func taskDetail(_ f: TaskFamily, task id: String) -> TaskDetail? {
    guard let task = f.tasks.first(where: { $0.id == id }) else { return nil }
    let outside = f.fixedElsewhere ?? []
    let approved = Set(f.verdicts.filter { $0.verdict == "approve" }.map(\.landingId))
        .union(outside.filter(\.approved).map(\.landing))
    let cards = f.landings.sorted(by: byTime(\.createdAt)).map { l in
        LandingCard(landing: l, verdicts: f.verdicts.filter { $0.landingId == l.id }.sorted(by: byTime(\.createdAt)).map { v in
            VerdictCard(verdict: v, findings: f.findings.filter { $0.verdictId == v.id })
        })
    }
    let children = f.tasks.filter { $0.id != f.root.id }.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
    let reviewed = Dictionary(f.verdicts.map { ($0.id, $0.landingId) }, uniquingKeysWith: { a, _ in a })
    let mine = f.findings.filter { $0.taskId == id }
    let findings = mine.map { DetailFinding(finding: $0, status: findingStatus($0, approved: approved), raisedIn: $0.verdictId.flatMap { reviewed[$0] }) }
    let elsewhere = outside.compactMap { o -> FixElsewhere? in
        let fixed = mine.filter { $0.state == "fixed" && $0.fixedIn == o.landing }.map(\.id)
        return fixed.isEmpty ? nil : FixElsewhere(task: o.taskId ?? landingTask(o.landing), landing: o.landing, approved: o.approved, findings: fixed)
    }
    return TaskDetail(task: task, family: [f.root] + children, cards: cards, findings: findings, elsewhere: elsewhere,
                      notes: f.notes.sorted { $0.seq < $1.seq }, approvedLandings: approved,
                      answers: f.answers.filter { $0.taskId == id }.sorted(by: byTime(\.answeredAt)),
                      progress: f.progress)
}

/// The worker detail's `작업` line (design §1): unfinished tasks the worker is assignee or reviewer of, in the
/// panels' order (시작 전, 진행 중, 리뷰 중, 보류; each by priority, then id).
public func workerTasks(_ name: String, in s: TaskBoardStatus) -> [TaskBoardTask] {
    let panels = taskPanels(s)
    return TaskPanel.allCases.flatMap { panels[$0] ?? [] }.map(\.task)
        .filter { !["done", "cancelled"].contains($0.state) && ($0.assignee == name || $0.reviewer == name) }
}

/// `HH:mm`, or `MM/dd HH:mm`, in the local zone on a 24-hour clock whatever the locale (D1: 16:50, not 04:50).
public func boardClock(_ date: Date, withDay: Bool = false) -> String {
    let c = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
    let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    return withDay ? String(format: "%02d/%02d ", c.month ?? 0, c.day ?? 0) + time : time
}
