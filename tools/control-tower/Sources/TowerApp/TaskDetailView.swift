import SwiftUI
import TowerCore

// One task picked on a task board (T70a; v3 T92, design task-board-window-v3.md §3 and its HIG pair H6–H11), read as
// a document (T155): where it is, its title, its properties, the decision waiting, then a section each for the to-do
// list, the history, the ticket's text, the findings and the notes, and the task's own facts folded. Paths and commands are copied, never opened
// (pm decision 5). Original ids (`T75#2`, `R4`) are in tooltips and copies only.

/// How a verdict looks: the word in a color that reads at 4.5:1 in both modes (H7).
struct VerdictStyle: Equatable {
    var label: String
    var symbol: String
    var color: Color

    static func of(_ verdict: String) -> VerdictStyle {
        switch verdict {
        case "approve": VerdictStyle(label: "승인", symbol: "checkmark.seal.fill", color: TaskColor.green)
        case "changes": VerdictStyle(label: "수정 요청", symbol: "arrow.uturn.backward.circle.fill", color: TaskColor.orange)
        case "hold": VerdictStyle(label: "보류", symbol: "pause.circle.fill", color: TaskColor.red)
        default: VerdictStyle(label: verdict, symbol: "questionmark.circle", color: .secondary)
        }
    }
}

/// How a finding's state looks (design v3 §2.6, §3.3): open red, fixed green, the rest plain.
struct FindingStyle: Equatable {
    var label: String
    var symbol: String
    var color: Color
    var struck = false

    static func of(_ s: FindingStatus) -> FindingStyle {
        switch s {
        case .open: FindingStyle(label: "열림", symbol: "smallcircle.filled.circle", color: TaskColor.red)
        case .fixedPending: FindingStyle(label: "고침 · 리뷰 대기", symbol: "checkmark.circle", color: TaskColor.orange)
        case .fixedApproved: FindingStyle(label: "수정됨", symbol: "checkmark", color: TaskColor.green)
        case .backlog: FindingStyle(label: "나중에 하기로", symbol: "tray.and.arrow.down", color: .secondary)
        case .acceptedLimit: FindingStyle(label: "한계로 받아들임", symbol: "minus.circle", color: .secondary)
        case .rejected: FindingStyle(label: "지적 아님", symbol: "xmark", color: .secondary, struck: true)
        case .other(let state): FindingStyle(label: state, symbol: "questionmark.circle", color: .secondary)
        }
    }
}

// MARK: - Words

/// `HH:mm` today, else `MM/dd HH:mm` (design v3 §2.4); nil without a time.
func detailClock(_ iso: String?, now: Date) -> String? {
    guard let ms = parseISO(iso) else { return nil }
    let d = Date(timeIntervalSince1970: ms / 1000)
    return boardClock(d, withDay: !Calendar.current.isDate(d, inSameDayAs: now))
}

/// `2차 제출`, or `T5a 1차 제출` for another task's landing in the family.
func submissionText(_ landing: String, of task: String) -> String {
    let n = submissionNumber(landing).map { "\($0)차 제출" } ?? landing
    return landingTask(landing) == task ? n : "\(landingTask(landing)) \(n)"
}

func findingSeverityWord(_ s: String) -> String { severityText[s] ?? s }

/// `필수 1 · 낮음 2`, most severe first.
func severityCounts(_ fs: [DetailFinding]) -> String {
    let by = Dictionary(grouping: fs.map(\.finding.severity), by: { $0 }).mapValues(\.count)
    let order = ["must", "should", "low"]
    return (order + by.keys.filter { !order.contains($0) }.sorted()).compactMap { s in by[s].map { "\(findingSeverityWord(s)) \($0)" } }
        .joined(separator: " · ")
}

/// The summary's first line (design v3 §3.2): when the last thing happened, what it was, and what is left.
struct TaskSummary: Equatable {
    var at: String?
    var event: String
    var rest: String?
}

func taskSummary(_ d: TaskDetail) -> TaskSummary {
    let t = d.task
    let a = t.assignee ?? "담당", r = t.reviewer ?? "리뷰어"
    let last = d.submissions.last
    let n = last.map { submissionText($0.landing.id, of: t.id) } ?? ""
    let verdict = last?.verdicts.last?.verdict
    let open = d.pile(.open)
    let openTail = open.isEmpty ? "" : " · \(severityCounts(open)) 열림"
    switch t.state {
    case "new":
        return TaskSummary(at: t.createdAt, event: "\(subject(t.createdBy ?? "pm")) 등록했습니다", rest: "pm이 담당을 정할 차례입니다")
    case "ready":
        return TaskSummary(at: t.assignedAt ?? t.updatedAt, event: "\(a)에게 맡겼습니다", rest: "\(subject(a)) 시작할 차례입니다")
    case "doing":
        guard last != nil else { return TaskSummary(at: t.updatedAt, event: "\(subject(a)) 작업 중입니다", rest: "아직 제출 없음") }
        // taken again after a request for changes (design v3 §3.2 leaves this to the changes row)
        if verdict?.verdict == "changes" {
            return TaskSummary(at: t.updatedAt, event: "\(subject(a)) 고치는 중입니다", rest: "\(n)에 수정 요청" + openTail)
        }
        return TaskSummary(at: t.updatedAt, event: "\(subject(a)) 작업 중입니다", rest: "\(n)까지 냈습니다")
    case "review":
        guard let last else { return TaskSummary(at: t.updatedAt, event: "\(subject(a)) 리뷰를 요청했습니다", rest: "\(subject(r)) 리뷰할 차례입니다") }
        return TaskSummary(at: last.landing.createdAt, event: "\(n)을 \(subject(a)) 냈습니다", rest: "\(subject(r)) 리뷰할 차례입니다")
    case "changes":
        let v = verdict?.verdict == "changes" ? verdict : nil
        return TaskSummary(at: v?.createdAt ?? t.updatedAt, event: "\(subject(v?.createdBy ?? r)) \(n)에 수정을 요청했습니다",
                           rest: "\(subject(a)) 고칠 차례입니다" + openTail)
    case "held":
        let v = verdict?.verdict == "hold" ? verdict : nil
        return TaskSummary(at: v?.createdAt ?? t.updatedAt, event: "\(subject(v?.createdBy ?? t.updatedBy ?? "pm")) 보류했습니다",
                           rest: "pm이 풀거나 취소할 차례입니다")
    case "done":
        let rest: String
        if open.isEmpty {
            rest = "남은 지적 없음"
        } else {
            let severities = Set(open.map(\.finding.severity))
            let what = severities.count == 1 ? "\(findingSeverityWord(severities.first!)) 지적 \(open.count)건이"
                : "지적 \(open.count)건(\(severityCounts(open)))이"
            rest = "\(what) 열려 있어 pm 정리 대기"
        }
        guard let approve = d.submissions.flatMap(\.verdicts).map(\.verdict).last(where: { $0.verdict == "approve" }) else {
            return TaskSummary(at: t.updatedAt, event: "완료됐습니다", rest: rest)
        }
        return TaskSummary(at: approve.createdAt,
                           event: "\(subject(approve.createdBy ?? r)) \(submissionText(approve.landingId, of: t.id))을 승인했습니다", rest: rest)
    case "cancelled":
        return TaskSummary(at: t.updatedAt, event: "\(subject(t.updatedBy ?? "pm")) 취소했습니다", rest: nil)
    case "waiting":
        let by = t.waiting?.askedBy ?? t.updatedBy ?? "pm"
        return TaskSummary(at: t.waiting?.askedAt ?? t.updatedAt, event: "\(subject(by)) 사용자에게 결정을 요청했습니다",
                           rest: "사용자가 정할 차례입니다")
    default:
        return TaskSummary(at: t.updatedAt, event: TaskStateStyle.of(t.state).label, rest: nil)
    }
}

/// A finding's second line (design v3 §3.3): the review it came from, and where it was fixed or how it was settled.
func findingOrigin(_ f: DetailFinding, task: String) -> String {
    func place(_ l: String) -> String {
        landingTask(l) == task ? "\(submissionText(l, of: task))에서" : "\(landingTask(l))에서"
    }
    var parts = f.raisedIn.map { ["\(submissionText($0, of: task)) 리뷰에서"] } ?? []
    switch f.status {
    case .open: break
    case .fixedPending(let l): parts.append("\(place(l)) 고침 · 리뷰 대기")
    case .fixedApproved(let l): parts.append("\(place(l)) 수정됨")
    default: parts.append(FindingStyle.of(f.status).label)
    }
    return parts.joined(separator: " · ")
}

/// What a history line folds under "자세히".
enum HistoryDetail: Equatable {
    case submission(TaskBoardLanding)
    case verdict(TaskBoardVerdict, reviewReport: String?)
    /// The brief the user decided from, as it was.
    case decision(TaskWaiting)
}

/// One line of the history (design v3 §3.4): `시각 · 누가 무엇을`.
struct HistoryLine: Equatable, Identifiable {
    var id: String
    var at: String?
    var text: String
    /// The board's own id, for the tooltip and the copy.
    var ref: String?
    var detail: HistoryDetail?
}

/// The family's history in time order: registered, every submission and the reviews of it, then fixes made in
/// other tasks, which the board keeps no time of.
func taskHistory(_ d: TaskDetail) -> [HistoryLine] {
    let t = d.task
    var lines: [HistoryLine] = []
    let made = parseISO(t.createdAt), assigned = parseISO(t.assignedAt)
    let apart = made.flatMap { m in assigned.map { $0 - m >= 60_000 } } ?? false
    lines.append(HistoryLine(id: "made", at: t.createdAt,
                             text: "\(subject(t.createdBy ?? "?")) 등록" + (t.assignee.map { apart ? "" : ", 담당 \($0)" } ?? "")))
    if apart, let a = t.assignee { lines.append(HistoryLine(id: "assigned", at: t.assignedAt, text: "담당 지정 · \(a)")) }
    let landings = Dictionary(d.cards.map { ($0.landing.id, $0.landing) }, uniquingKeysWith: { a, _ in a })
    for c in d.cards {
        let l = c.landing
        let name = "\(l.createdBy ?? "?") \(submissionText(l.id, of: t.id))"
        if let by = l.supersededBy, c.verdicts.isEmpty {
            let next = landings[by]
            let gap = parseISO(l.createdAt).flatMap { a in parseISO(next?.createdAt).map { max(0, Int(($0 - a) / 60_000)) } }
            lines.append(HistoryLine(id: l.id, at: l.createdAt, text: name + " → " + (gap.map { "\(shortDuration(minutes: $0)) 뒤 " } ?? "") + "다시 제출",
                                     ref: l.id, detail: next?.focus == l.focus ? nil : .submission(l)))
        } else {
            lines.append(HistoryLine(id: l.id, at: l.createdAt, text: name + (l.closes.isEmpty ? "" : " · 고친 지적 \(l.closes.count)건"),
                                     ref: l.id, detail: .submission(l)))
        }
        for v in c.verdicts {
            let v0 = v.verdict
            let report = (v0.reportPath ?? l.reviewReportPath)?.nonEmptyText
            let has = v0.rerunCmd?.nonEmptyText != nil || report != nil || v0.sideNotes?.nonEmptyText != nil
            lines.append(HistoryLine(id: v0.id, at: v0.createdAt,
                                     text: "\(subject(v0.createdBy ?? "?")) \(VerdictStyle.of(v0.verdict).label)" + (v.findings.isEmpty ? "" : " · 지적 \(v.findings.count)건 ↑"),
                                     ref: v0.id, detail: has ? .verdict(v0, reviewReport: report) : nil))
        }
    }
    // each answer where its time falls (T116): before the first line that came after it; one without a time last,
    // as the board keeps no time of it (R41 L4)
    let answers = d.answers.enumerated().map { i, a in
        let chosen = a.chosen?.nonEmptyText.map { $0 + (a.answer.isEmpty ? "" : " — ") } ?? ""
        return HistoryLine(id: "answer \(i)", at: a.answeredAt, text: "사용자 결정: " + chosen + a.answer,
                           detail: a.brief.map { .decision($0) })
    }
    for line in answers {
        guard let at = line.at else { continue }
        lines.insert(line, at: lines.firstIndex { ($0.at ?? "") > at } ?? lines.count)
    }
    lines += answers.filter { $0.at == nil }
    for e in d.elsewhere {
        lines.append(HistoryLine(id: "elsewhere \(e.landing)", at: nil,
                                 text: "\(e.task)에서 지적 \(e.findings.count)건 수정 (\(e.approved ? "승인됨" : "리뷰 대기"))", ref: e.landing))
    }
    return lines
}

/// The last submission and the reviews of it start open; the rest start folded (design v3 §2.5).
func historyOpenAtFirst(_ d: TaskDetail) -> Set<String> {
    guard let last = d.cards.last else { return [] }
    return Set([last.landing.id] + last.verdicts.map(\.verdict.id))
}

/// Fixed findings start open while there are few of them (design v3 §3.3).
let fixedShownOpen = 3

/// How a to-do item stands, as a check box (T155): done, going (the last record says not done yet), or not started.
struct TodoStyle: Equatable {
    var label: String
    var symbol: String
    var color: Color

    static func of(_ s: TodoStatus) -> TodoStyle {
        switch s {
        case .done: TodoStyle(label: "끝남", symbol: "checkmark.square.fill", color: TaskColor.green)
        case .doing: TodoStyle(label: "진행 중", symbol: "square.lefthalf.filled", color: TaskColor.orange)
        case .notYet: TodoStyle(label: "아직", symbol: "square", color: TaskColor.gray)
        }
    }
}

// MARK: - View

/// The detail's head: id and title, the title without the team prefix the list drops too (T108); the full title is the tooltip.
struct TaskDetailHead: View {
    let task: TaskBoardTask
    let team: String
    var title: String { shownTitle(task.title, team: team) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(task.id).scaledFont(.title1, weight: .bold, design: .monospaced).foregroundStyle(.secondary).textSelection(.enabled)
            Text(title).scaledFont(.title1, weight: .bold).lineLimit(3).textSelection(.enabled).help(task.title)
        }
    }
}

struct TaskDetailView: View {
    let team: String
    /// The task as the list has it: the head draws from it before the family is read (U6).
    let line: TaskLine
    let family: TaskFamilyState?
    /// The board's decisions tied to the task (T147).
    var decisions: [BoardDecision] = []
    /// The board lists its decisions (my-team T146 on): they stand for the family's answers in the history.
    var listsDecisions = false
    let now: Date
    let workerRow: (String?) -> LiveRow?
    let pick: (String?) -> Void
    let select: (RowID) -> Void
    let reload: () -> Void
    /// The goals whose order has this task (T214): a 목표, 선행 and 후행 line each, under 관련 작업.
    var goalLinks: [GoalTaskLinks] = []
    /// The board's tasks by id, for the 선행·후행 links' state and title.
    var boardTasks: [String: TaskBoardTask] = [:]
    /// The 목표 line's link, with that goal's file: the 순서 view, this task's card in that goal picked.
    var showInOrder: ((String) -> Void)?

    var body: some View {
        // one task's folds stay with it: another task starts from the defaults
        TaskDetailBody(team: team, line: line, family: family, decisions: decisions, listsDecisions: listsDecisions, now: now,
                       workerRow: workerRow, pick: pick, select: select, reload: reload, goalLinks: goalLinks,
                       boardTasks: boardTasks, showInOrder: showInOrder)
            .id(line.task.id)
    }
}

private struct TaskDetailBody: View {
    let team: String
    let line: TaskLine
    let family: TaskFamilyState?
    let decisions: [BoardDecision]
    let listsDecisions: Bool
    let now: Date
    let workerRow: (String?) -> LiveRow?
    let pick: (String?) -> Void
    let select: (RowID) -> Void
    let reload: () -> Void
    let goalLinks: [GoalTaskLinks]
    let boardTasks: [String: TaskBoardTask]
    let showInOrder: ((String) -> Void)?
    /// History lines the user opened or folded, against `historyOpenAtFirst`.
    @State private var flipped: Set<String> = []
    @State private var piles: [FindingPile: Bool] = [:]
    /// The task's ticket, read once the detail shows (T128).
    @State private var ticket: TicketRead?
    /// The ticket's whole text as blocks, split once with the read, never while drawing (R53 L2).
    @State private var ticketBlocks: [MarkdownBlock] = []
    /// The ticket's text starts open (T155): it is what the task is.
    @State private var ticketOpen = true
    /// The commits on the assignee's branch since the task's start commit; nil when there is no way to read them.
    @State private var commits: [CommitLine]?
    @Environment(\.boardFontScale) private var scale

    /// One place for the task's decisions (T147): with a board that lists them, the decisions section has the answers
    /// too, and the history leaves them out.
    private var detail: TaskDetail? {
        family?.family.flatMap { taskDetail($0, task: line.task.id) }.map { d in
            var d = d
            if listsDecisions { d.answers = [] }
            return d
        }
    }

    private var outline: TicketOutline? {
        if case .read(let outline, _)? = ticket { outline } else { nil }
    }

    var body: some View {
        let t = detail?.task ?? line.task
        let inProgress = ["doing", "changes"].contains(t.state)
        let dir = workerRow(t.assignee)?.session.cwd
        let record: DetailRecord = detail != nil ? .read : family?.failure != nil ? .failed : .reading
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(detailBlocks(waits: decisions.contains(where: \.open), record: record), id: \.self) { block in
                        switch block {
                        case .head:
                            VStack(alignment: .leading, spacing: 6) {
                                DetailLocation(parts: ["\(team) 작업판", TaskPanelStyle.of(panel(of: t)).label, t.id])
                                TaskDetailHead(task: t, team: team)
                            }
                        case .decisions: TaskDecisionsView(decisions: decisions, now: now)
                        case .properties: properties(t, detail)
                        case .goal: goal()
                        case .todo: if let d = detail { todo(items: outline?.items ?? [], progress: d.progress) }
                        case .ticket: ticketText()
                        case .findings: if let d = detail { findings(d, proxy: proxy) }
                        case .history: if let d = detail { history(d) }
                        case .commits: if inProgress, let commits, !commits.isEmpty { commitFlowView(commits) }
                        case .notes: if let d = detail { notes(d) }
                        case .failed: if let failure = family?.failure { failed(failure) }
                        case .reading:
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("기록을 읽는 중…").scaledFont(.callout).foregroundStyle(.secondary)
                            }
                        case .taskInfo: taskInfo(t)
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: t.ticketPath) {
            let path = t.ticketPath
            (ticket, ticketBlocks) = await Task.detached {
                let read = readTicket(path)
                return if case .read(_, let full) = read { (read, markdownBlocks(full)) } else { (read, []) }
            }.value
        }
        // only while this task is on screen and in progress; again with the board's clock (`now`, every 15 s)
        .task(id: "\(t.id)|\(dir ?? "")|\(t.baseCommit ?? "")|\(inProgress)|\(now.timeIntervalSince1970)") {
            guard inProgress else { commits = nil; return }
            let base = t.baseCommit
            commits = await Task.detached { commitFlow(dir: dir, base: base) }.value
        }
    }

    // MARK: properties

    /// The task's values in two columns (H1): where it stands and whose move it is, who has it, how far the to-do
    /// list is, its decisions, its findings, and the tasks around it. Before the family is read, what the list
    /// already has.
    private func properties(_ t: TaskBoardTask, _ d: TaskDetail?) -> some View {
        PropertyGrid {
            GridRow {
                PropertyName("상태", symbol: "circle.lefthalf.filled")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TaskStateTag(state: t.state, tinted: true).fixedSize()
                    if let d {
                        let s = taskSummary(d)
                        Text([detailClock(s.at, now: now), s.event + "."].compactMap { $0 }.joined(separator: " ") + (s.rest.map { " \($0)." } ?? ""))
                            .scaledFont(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            GridRow { PropertyName("담당", symbol: "person"); person(t.assignee) }
            GridRow { PropertyName("리뷰어", symbol: "eye"); person(t.reviewer) }
            if let d, let items = outline?.items, !items.isEmpty {
                GridRow {
                    PropertyName("할 일", symbol: "checklist")
                    TodoBar(done: todoLines(items: items, progress: d.progress).lines.filter { $0.status == .done }.count, total: items.count)
                }
            }
            if !decisions.isEmpty {
                GridRow {
                    PropertyName("결정", symbol: "person.fill.questionmark")
                    WrapLayout(spacing: 6) {
                        ForEach(decisions, id: \.id) { d in
                            Button { pick(d.id) } label: {
                                ToneTag(text: decisionTagText(d), color: d.open ? TaskColor.pink : TaskColor.gray)
                            }
                            .buttonStyle(.plain)
                            .help(decisionHeadline(d))
                            .accessibilityHint("결정 상세로 갑니다")
                        }
                    }
                }
            }
            if let d, !d.findings.isEmpty {
                GridRow {
                    PropertyName("지적", symbol: "flag")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        ForEach(line.severities, id: \.severity) { SeverityTag(tag: $0) }
                        Text(FindingPile.allCases.compactMap { p in d.pile(p).isEmpty ? nil : "\(pileName(p)) \(d.pile(p).count)" }.joined(separator: " · "))
                            .scaledFont(.callout)
                    }
                }
            }
            if let d, d.family.count > 1 {
                GridRow {
                    PropertyName("관련 작업", symbol: "arrow.left.arrow.right")
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(d.family.filter { $0.id != t.id }, id: \.id) { o in
                            TaskLink(id: o.id, task: o, team: team, relation: relationWord(o, to: t), pick: pick)
                        }
                    }
                }
            }
            // T214 (goal-order-view §4): per goal whose order has the task, its 목표, then what it waits for and what
            // waits for it; the line names the relation, so the links carry none
            ForEach(goalLinks, id: \.goal.path) { g in
                GridRow {
                    PropertyName("목표", symbol: "flag.checkered")
                    Button { showInOrder?(g.goal.path) } label: { Text(g.goalLine).scaledFont(.callout).lineLimit(1) }
                        .buttonStyle(.link)
                        .disabled(showInOrder == nil)
                        .help("순서 보기에서 이 작업으로 갑니다")
                }
                if !g.before.isEmpty {
                    GridRow {
                        PropertyName("선행", symbol: "arrow.turn.up.left")
                        goalRelations(g.before)
                    }
                }
                if !g.after.isEmpty {
                    GridRow {
                        PropertyName("후행", symbol: "arrow.turn.down.right")
                        goalRelations(g.after)
                    }
                }
            }
        }
    }

    private func goalRelations(_ rs: [GoalRelation]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rs, id: \.self) { r in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TaskLink(id: r.task, task: boardTasks[r.task], team: team, pick: pick)
                    if let c = r.caption {
                        Text(c).scaledFont(.caption1).foregroundStyle(.secondary).fixedSize()
                            .accessibilityLabel(r.spoken ?? c)
                    }
                }
            }
        }
    }

    /// A worker's tag, and beside it a button that opens the worker on the board (H9): the tag itself is not a button.
    @ViewBuilder
    private func person(_ name: String?) -> some View {
        if let name {
            HStack(spacing: 4) {
                PersonTag(name: name)
                if let row = workerRow(name) {
                    Button { select(row.id) } label: { Image(systemName: "arrow.up.forward.square").scaledFont(.callout) }
                        .buttonStyle(.borderless)
                        .help("보드에서 \(name) 보기")
                        .accessibilityLabel("보드에서 \(name) 보기")
                }
            }
        } else {
            Text("없음").scaledFont(.callout).foregroundStyle(.secondary)
        }
    }

    private func failed(_ f: TaskBoardFailure) -> some View {
        let p = taskBoardProblem(f, bin: myTeamBin)
        return VStack(alignment: .leading, spacing: 4) {
            Label("기록을 읽지 못했습니다", systemImage: "exclamationmark.triangle.fill").scaledFont(.headline, weight: .semibold)
            Text(p.title).scaledFont(.callout).textSelection(.enabled)
            Text(p.detail).scaledFont(.callout, design: .monospaced).foregroundStyle(.secondary).textSelection(.enabled)
            Button("다시 읽기", action: reload).help("다시 읽기 (⌘R)").padding(.top, 4)
        }
    }

    // MARK: what it is for, how far it has come (T128)

    @ViewBuilder
    private func goal() -> some View {
        if let goal = outline?.goal {
            DetailSection(title: "목표") {
                Text(inlineMarkdown(goal)).documentText().textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The to-do items as check boxes with how each stands, a finished one dimmed, then the progress outside the
    /// list; nothing with neither.
    @ViewBuilder
    private func todo(items: [String], progress: [TaskProgress]) -> some View {
        let (lines, outside) = todoLines(items: items, progress: progress)
        if !lines.isEmpty {
            DetailSection(title: "할 일", count: "\(lines.filter { $0.status == .done }.count)/\(lines.count)") {
                ForEach(lines, id: \.number) { l in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        let style = TodoStyle.of(l.status)
                        Image(systemName: style.symbol).scaledFont(.body).foregroundStyle(style.color).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AttributedString("\(l.number). ") + inlineMarkdown(l.text)).documentText()
                                .foregroundStyle(l.status == .done ? .secondary : .primary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            if let last = l.last { progressNote(last) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(TodoStyle.of(l.status).label)
                }
            }
        }
        if !outside.isEmpty {
            DetailSection(title: lines.isEmpty ? "진행 메모" : "할 일 밖 진행") {
                ForEach(Array(outside.enumerated()), id: \.offset) { _, p in progressNote(p) }
            }
        }
    }

    private func progressNote(_ p: TaskProgress) -> some View {
        let when = [p.by, detailClock(p.at, now: now)].compactMap { $0 }.joined(separator: " ")
        return Text(AttributedString(when.isEmpty ? "" : when + " · ") + inlineMarkdown(p.note)).scaledFont(.callout).foregroundStyle(.secondary)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }

    private func commitFlowView(_ commits: [CommitLine]) -> some View {
        DetailSection(title: "시작 커밋 이후 커밋", count: "\(commits.count)개") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(commits, id: \.sha) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(detailClock(c.at, now: now) ?? "").scaledFont(.callout).monospacedDigit().foregroundStyle(.secondary)
                        Text(String(c.sha.prefix(7))).scaledFont(.callout, design: .monospaced).foregroundStyle(.secondary)
                        Text(c.subject).scaledFont(.callout).lineLimit(2).textSelection(.enabled)
                        if let n = c.files { Text("파일 \(n)개").scaledFont(.callout).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    /// The ticket's whole text, open at first and foldable; why there is none when it could not be read.
    @ViewBuilder
    private func ticketText() -> some View {
        switch ticket {
        case .read?:
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                DisclosureGroup(isExpanded: $ticketOpen) {
                    MarkdownView(blocks: ticketBlocks).padding(.top, 6)
                } label: {
                    DetailSectionTitle(title: "티켓 본문")
                }
            }
            .padding(.top, 6)
        case .unreadable(let why)?:
            DetailSection(title: "티켓 본문") {
                Text(why).scaledFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case .none?, nil:
            EmptyView()
        }
    }

    // MARK: findings

    private func pileOpen(_ p: FindingPile, _ d: TaskDetail) -> Bool {
        piles[p] ?? (p == .open || (p == .fixed && d.pile(.fixed).count <= fixedShownOpen))
    }

    private func findings(_ d: TaskDetail, proxy: ScrollViewProxy) -> some View {
        DetailSection(title: "지적", count: d.findings.isEmpty ? "없음" : nil) {
            if !d.findings.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    ForEach(FindingPile.allCases, id: \.self) { p in
                        Button("\(pileName(p)) \(d.pile(p).count)") {
                            piles[p] = true
                            withAnimation { proxy.scrollTo(p, anchor: .top) }
                        }
                        .buttonStyle(.link).scaledFont(.callout)
                        .disabled(d.pile(p).isEmpty)
                        .help("\(pileName(p)) 지적으로 가기")
                    }
                }
            }
            ForEach(FindingPile.allCases, id: \.self) { p in
                let fs = d.pile(p)
                if !fs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if p == .open {
                            ForEach(fs, id: \.finding.id) { findingRow($0, d) }
                        } else {
                            DisclosureGroup(isExpanded: Binding(get: { pileOpen(p, d) }, set: { piles[p] = $0 })) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(fs, id: \.finding.id) { findingRow($0, d) }
                                }
                                .padding(.top, 4)
                            } label: {
                                Text("\(pileName(p)) \(fs.count)").scaledFont(.callout, weight: .semibold)
                            }
                        }
                    }
                    .id(p)
                }
            }
        }
    }

    private func pileName(_ p: FindingPile) -> String {
        switch p {
        case .open: "열림"
        case .fixed: "수정됨"
        case .settled: "정리됨"
        }
    }

    /// Where a text of the landing `landingId` places a file:line: its repo, then the worker's folder (G4 I12).
    private func refs(_ landingId: String?, _ d: TaskDetail) -> (FileRef) -> FileTarget? {
        let repo = landingId.flatMap { id in d.cards.first { $0.landing.id == id }?.landing.repo }
        let cwd = workerRow(d.task.assignee)?.session.cwd
        return { refTargetNow($0, repo: repo, workerCwd: cwd) }
    }

    private func findingRow(_ f: DetailFinding, _ d: TaskDetail) -> some View {
        let task = d.task.id
        let style = FindingStyle.of(f.status)
        let indent = StatusIconView.size(.callout, scale: scale) + 6
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: style.symbol).foregroundStyle(style.color).frame(width: indent - 6).accessibilityLabel(style.label)
                SeverityTag(severity: f.finding.severity, count: 1)
                RefText(text: f.finding.summary, resolve: refs(f.raisedIn, d)).scaledFont(.callout, weight: f.pile == .open ? .semibold : .regular)
                    .strikethrough(style.struck).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(f.finding.id).scaledFont(.caption1, design: .monospaced).foregroundStyle(.secondary).fixedSize()
                    .textSelection(.enabled)
            }
            let origin = findingOrigin(f, task: task)
            if !origin.isEmpty {
                Text(origin).scaledFont(.callout).foregroundStyle(f.status == .open ? Color.secondary : style.color == .secondary ? .secondary : style.color)
                    .padding(.leading, indent)
            }
            if let repro = f.finding.repro?.nonEmptyText {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        CopyText(text: repro, what: "재현 명령", mono: true)
                        RefLinks(text: repro, resolve: refs(f.raisedIn, d))
                    }
                } label: {
                    Text("재현").scaledFont(.callout)
                }
                .padding(.leading, indent)
            }
        }
    }

    // MARK: history

    /// The history down a line (T155): a dot for each thing that happened, in its kind's color, the line running on
    /// to the next.
    private func history(_ d: TaskDetail) -> some View {
        let lines = taskHistory(d), first = historyOpenAtFirst(d)
        let dot = (StatusIconView.size(.callout, scale: scale) * 0.7).rounded(.up)
        return DetailSection(title: "진행 기록") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { i, h in
                    let open = first.contains(h.id) != flipped.contains(h.id)
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 2) {
                            Circle().fill(historyColor(h)).frame(width: dot, height: dot).padding(.top, dot * 0.45)
                            if i < lines.count - 1 || d.cards.isEmpty { Rectangle().fill(.tertiary).frame(width: 2) }
                        }
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(h.at.flatMap { detailClock($0, now: now) } ?? "다른 작업에서")
                                    .scaledFont(.callout).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(minWidth: 84 * scale, alignment: .leading)
                                Text(inlineMarkdown(h.text)).scaledFont(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                if h.detail != nil {
                                    Button {
                                        if flipped.contains(h.id) { flipped.remove(h.id) } else { flipped.insert(h.id) }
                                    } label: {
                                        Label("자세히", systemImage: open ? "chevron.down" : "chevron.right").labelStyle(.titleAndIcon)
                                    }
                                    .buttonStyle(.borderless).scaledFont(.callout)
                                    .accessibilityValue(open ? "펼침" : "접힘")
                                }
                            }
                            .help(h.ref ?? "")
                            .contextMenu {
                                if let ref = h.ref { Button("id 복사 (\(ref))") { copy(ref) } }
                            }
                            if open, let detail = h.detail {
                                VStack(alignment: .leading, spacing: 6) {
                                    historyDetail(detail, d)
                                    // under the facts, not a row of their grid: a row this wide would spread its columns
                                    if let (p, what) = reportOf(detail), previewsAsMarkdown(p) { ReportPreview(path: p, what: what) }
                                }
                                .padding(.leading, 84 * scale + 10)
                            }
                        }
                        .padding(.bottom, 10)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                if d.cards.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Circle().strokeBorder(.tertiary, lineWidth: 1.5).frame(width: dot, height: dot).padding(.top, dot * 0.45)
                            .accessibilityHidden(true)
                        Text("아직 제출이 없습니다").scaledFont(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The report a history line's detail names, and what it is called.
    private func reportOf(_ detail: HistoryDetail) -> (path: String, what: String)? {
        switch detail {
        case .submission(let l): l.reportPath?.nonEmptyText.map { ($0, "담당 보고서") }
        case .verdict(_, let report): report.map { ($0, "리뷰 보고서") }
        case .decision: nil
        }
    }

    private func historyColor(_ h: HistoryLine) -> Color {
        switch h.detail {
        case .submission?: TaskColor.blue
        case .verdict(let v, _)?: VerdictStyle.of(v.verdict).color
        case .decision?: TaskColor.pink
        case nil: h.id.hasPrefix("answer ") ? TaskColor.pink : TaskColor.gray
        }
    }

    @ViewBuilder
    private func historyDetail(_ detail: HistoryDetail, _ d: TaskDetail) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
            switch detail {
            case .submission(let l):
                GridRow { factName("커밋"); CopyText(text: l.commit, shown: String(l.commit.prefix(7)), what: "커밋") }
                if let cmd = l.checkCmd?.nonEmptyText { GridRow { factName("담당이 돌린 확인"); command(cmd, result: l.checkResult) } }
                if !l.focus.isEmpty {
                    GridRow { factName("리뷰어에게: 볼 곳"); RefText(text: l.focus.joined(separator: "\n"), resolve: refs(l.id, d)).scaledFont(.callout).textSelection(.enabled) }
                }
                if !l.closes.isEmpty {
                    GridRow { factName("이 제출로 고친 지적"); Text(l.closes.joined(separator: ", ")).scaledFont(.callout, design: .monospaced).textSelection(.enabled) }
                }
                if let p = l.reportPath?.nonEmptyText {
                    GridRow { factName("담당 보고서"); path(p, what: "담당 보고서") }
                }
                if l.deployed { GridRow { factName("설치"); Text("설치됨").scaledFont(.callout).foregroundStyle(TaskColor.green) } }
                if !l.leftOut.isEmpty {
                    GridRow {
                        factName("빠진 커밋")
                        Text("제출에 안 들어간 커밋 \(l.leftOut.count)개").scaledFont(.callout).foregroundStyle(TaskColor.orange)
                            .help(l.leftOut.joined(separator: "\n"))
                    }
                }
            case .verdict(let v, let report):
                if let cmd = v.rerunCmd?.nonEmptyText { GridRow { factName("리뷰어가 다시 돌린 확인"); command(cmd, result: v.rerunResult) } }
                if let report {
                    GridRow { factName("리뷰 보고서"); path(report, what: "리뷰 보고서") }
                }
                if let n = v.sideNotes?.nonEmptyText { GridRow { factName("리뷰어 메모"); Text(inlineMarkdown(n)).scaledFont(.callout).textSelection(.enabled) } }
            case .decision(let b):
                GridRow { DecisionBriefView(brief: b, now: now).gridCellColumns(2) }
            }
        }
    }

    /// A command whole, wrapped, never cut (H11), and its result under it.
    private func command(_ cmd: String, result: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            CopyText(text: cmd, what: "명령", mono: true)
            if let result = result?.nonEmptyText { Text("→ \(result)").scaledFont(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }

    /// A path as its file name, opening in the chosen editor (T137); the whole of it in the tooltip and the copy (H11).
    private func path(_ p: String, what: String) -> some View {
        OpenPath(path: p, what: what)
    }

    private func factName(_ s: String) -> some View {
        Text(s).scaledFont(.callout).foregroundStyle(.secondary).gridColumnAlignment(.leading)
    }

    // MARK: notes, task info

    @ViewBuilder
    private func notes(_ d: TaskDetail) -> some View {
        if !d.notes.isEmpty {
            DetailSection(title: "메모", count: "\(d.notes.count)") {
                ForEach(d.notes, id: \.seq) { n in
                    VStack(alignment: .leading, spacing: 2) {
                        let to = n.to.isEmpty ? "" : " → " + n.to.joined(separator: ", ")
                        let other = n.taskId.map { $0 == line.task.id ? "" : " · \($0)" } ?? ""
                        Text("\(n.createdBy ?? "?")\(to)\(detailClock(n.createdAt, now: now).map { " · \($0)" } ?? "")\(other)")
                            .scaledFont(.callout).foregroundStyle(.secondary)
                        Text(inlineMarkdown(n.body)).scaledFont(.callout).textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// The task's own facts, folded (design v3 §2.5, P9): its ticket, when it was registered, the constraints, the
    /// start commit, and the priority only when it is not the default.
    private func taskInfo(_ t: TaskBoardTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            DisclosureGroup {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                    if let p = t.ticketPath?.nonEmptyText { GridRow { factName("티켓"); path(p, what: "티켓") } }
                    GridRow { factName("등록"); Text(registeredText(t, now: now)).scaledFont(.callout).textSelection(.enabled) }
                    GridRow { factName("제약"); Text(t.constraints?.nonEmptyText ?? "없음").scaledFont(.callout).textSelection(.enabled) }
                    if let b = t.baseCommit?.nonEmptyText { GridRow { factName("시작 커밋"); CopyText(text: b, shown: String(b.prefix(7)), what: "시작 커밋") } }
                    if t.priority != defaultTaskPriority { GridRow { factName("우선순위"); Text("\(t.priority) (기본 \(defaultTaskPriority))").scaledFont(.callout) } }
                }
                .padding(.top, 4)
            } label: {
                DetailSectionTitle(title: "작업 정보")
            }
        }
        .padding(.top, 6)
    }
}

enum DetailBlock: Hashable {
    case head, decisions, properties, goal, todo, ticket, findings, history, commits, notes, failed, reading, taskInfo
}

enum DetailRecord { case read, failed, reading }

func detailBlocks(waits: Bool, record: DetailRecord) -> [DetailBlock] {
    let body: [DetailBlock] = switch record {
    case .read: [.goal, .todo, .ticket, .findings, .history, .commits, .notes]
    case .failed: [.failed]
    case .reading: [.reading]
    }
    return [.head] + (waits ? [.decisions] : []) + [.properties] + body + [.taskInfo]
}

/// A decision's tag among a task's properties: `D#2 답을 기다림`, `T5:1 답함 · Text`.
func decisionTagText(_ d: BoardDecision) -> String {
    d.open ? "\(d.id) 답을 기다림" : "\(d.id) 답함" + (d.chosen?.nonEmptyText.map { " · \($0)" } ?? "")
}

/// How another task of the family stands to the one shown: its parent, its child, or neither.
func relationWord(_ other: TaskBoardTask, to t: TaskBoardTask) -> String? {
    if other.id == t.parentId { return "상위" }
    if other.parentId == t.id { return "하위" }
    return nil
}

/// `pm · 11/16 14:02`, and when the assignee was set if that came later: the board keeps no time of the start
/// (design v3 §2.8 C3), so none is claimed.
func registeredText(_ t: TaskBoardTask, now: Date) -> String {
    let made = [t.createdBy, detailClock(t.createdAt, now: now)].compactMap { $0 }.joined(separator: " · ")
    let assigned = t.assignedAt != t.createdAt ? detailClock(t.assignedAt, now: now).map { "담당 지정 \($0)" } : nil
    return [made.nonEmptyText, assigned].compactMap { $0 }.joined(separator: " · ").nonEmptyText ?? "기록 없음"
}

/// The board's priority when none is given (my-team board service: `input.priority ?? 100`).
let defaultTaskPriority = 100

/// Text that can be selected, with a button that copies all of it. Wrapped whole, never cut (H11); `shown` stands
/// in for a long value (a commit's 7 characters, a path's file name) with the whole in the tooltip.
struct CopyText: View {
    let text: String
    var shown: String?
    /// What the button copies, for its label: `커밋 복사` (H6).
    var what: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(shown ?? text)
                .scaledFont(.callout, design: mono || shown != nil ? .monospaced : .default)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(text)
            Button { copy(text) } label: { Image(systemName: "doc.on.doc").scaledFont(.caption1) }
                .buttonStyle(.borderless)
                .help("\(what) 복사: \(text)")
                .accessibilityLabel("\(what) 복사")
        }
    }
}

extension String {
    /// nil when only whitespace.
    var nonEmptyText: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

/// The worker detail's `작업` line: the worker's unfinished tasks on its team's board.
struct WorkerTaskLine: Equatable {
    var team: String
    var tasks: [TaskBoardTask]
}

/// At most this many tasks on the line; the rest is a count.
let workerTasksShown = 3

/// `T5 수정 요청 · T10 착수 전`, each a link to that task on the board (design §1).
struct WorkerTasksView: View {
    let line: WorkerTaskLine
    let open: (String) -> Void

    var body: some View {
        if line.tasks.isEmpty {
            Text("진행 중인 작업 없음").scaledFont(.body).foregroundStyle(.secondary)
        } else {
            WrapLayout(spacing: 8) {
                ForEach(line.tasks.prefix(workerTasksShown), id: \.id) { t in
                    Button { open(t.id) } label: {
                        HStack(spacing: 3) {
                            TaskStateIcon(state: t.state, style: .callout)
                            Text("\(t.id) \(TaskStateStyle.of(t.state).label)").scaledFont(.body)
                        }
                    }
                    .buttonStyle(.link)
                    .help("\(t.title)\n작업판에서 보기")
                }
                if line.tasks.count > workerTasksShown {
                    Button("외 \(line.tasks.count - workerTasksShown)개") { open(line.tasks[workerTasksShown].id) }
                        .buttonStyle(.link).scaledFont(.body)
                        .help(line.tasks.dropFirst(workerTasksShown).map(\.id).joined(separator: ", "))
                }
            }
        }
    }
}
