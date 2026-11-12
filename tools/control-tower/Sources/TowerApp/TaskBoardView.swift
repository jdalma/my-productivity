import AppKit
import SwiftUI
import TowerCore

// A team's task board (T70, v2 T70b; design: ~/.my-team/docs/control-tower/design/board-view.md §3.1, §3.2, §4, §5,
// and board-view-v2.md §A.3, §B). Read only: nothing here writes to the board. Paths are copied, never opened
// (pm decision 5).

/// The board's state colors, light and dark: Primer foreground values one step darker in light and lighter in dark
/// than the system colors, so a word in the color reads at 4.5:1 on its own tint (T70b report).
enum TaskColor {
    static let orange = pair(0x953800ff, 0xf0883eff)
    static let blue = pair(0x0550aeff, 0x79c0ffff)
    static let purple = pair(0x6639baff, 0xd2a8ffff)
    static let red = pair(0xa40e26ff, 0xff7b72ff)
    static let green = pair(0x116329ff, 0x56d364ff)
    static let gray = DiffColors.mutedText

    private static func pair(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { DiffColors.rgba($0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light) })
    }
}

/// How a task state looks (design §4.1): each shape differs, so color is never the only cue.
struct TaskStateStyle: Equatable {
    var label: String
    var symbol: String
    var color: Color

    static func of(_ state: String) -> TaskStateStyle {
        switch state {
        case "new": TaskStateStyle(label: "미배정", symbol: "circle.dashed", color: TaskColor.orange)
        case "ready": TaskStateStyle(label: "착수 전", symbol: "circle", color: TaskColor.gray)
        case "doing": TaskStateStyle(label: "진행 중", symbol: "circle.lefthalf.filled", color: TaskColor.blue)
        case "review": TaskStateStyle(label: "리뷰 대기", symbol: "eye.circle.fill", color: TaskColor.purple)
        case "changes": TaskStateStyle(label: "수정 요청", symbol: "arrow.uturn.backward.circle.fill", color: TaskColor.orange)
        case "held": TaskStateStyle(label: "보류", symbol: "pause.circle.fill", color: TaskColor.red)
        case "done": TaskStateStyle(label: "완료", symbol: "checkmark.circle.fill", color: TaskColor.green)
        case "cancelled": TaskStateStyle(label: "취소", symbol: "xmark.circle", color: TaskColor.gray)
        default: TaskStateStyle(label: state, symbol: "questionmark.circle", color: TaskColor.gray)
        }
    }

    static let all = ["new", "ready", "doing", "review", "changes", "held", "done", "cancelled"]
}

/// A group's head (design §2, v2 §A.3): its icon, name, band color and whose move it is. Finished is gray.
struct TaskGroupStyle {
    var label: String
    var symbol: String
    var color: Color
    var whose: String

    static func of(_ g: TaskGroup) -> TaskGroupStyle {
        switch g {
        case .action: TaskGroupStyle(label: "조치 필요", symbol: "exclamationmark.triangle.fill", color: TaskColor.orange, whose: "pm 차례")
        case .review: TaskGroupStyle(label: "리뷰 대기", symbol: "eye.circle.fill", color: TaskColor.purple, whose: "판정자 차례")
        case .active: TaskGroupStyle(label: "진행 중", symbol: "circle.lefthalf.filled", color: TaskColor.blue, whose: "담당 차례")
        case .finished: TaskGroupStyle(label: "끝남", symbol: "checkmark.circle.fill", color: TaskColor.gray, whose: "")
        }
    }

    /// The band's tint, and the state tag's (v2 §A.3).
    static let bandOpacity = 0.15
    static let tagOpacity = 0.16
}

/// The line under an action row: why it is there and what frees it (design §2).
func actionReasonText(_ r: ActionReason) -> String {
    switch r {
    case .held: "보류: pm이 풀거나 취소해야 진행됩니다"
    case .unassigned: "미배정: pm이 담당을 정해야 시작됩니다"
    case .openFindings(let n): "끝났지만 열린 지적 \(n)건: pm이 정리해야 합니다"
    case .incompleteReview(let missing): "리뷰 요청 불완전(\(missing.joined(separator: ", ")) 없음): pm이 채워야 판정할 수 있습니다"
    }
}

func personRoleText(_ r: PersonRole) -> String {
    switch r {
    case .registered: "등록"
    case .handled: "처리"
    case .assignee: "담당"
    case .reviewer: "판정"
    }
}

private let actionText = ["add": "추가", "assign": "배정", "take": "착수", "land": "완료 기록", "verdict": "판정",
                          "finding": "지적 정리", "note": "메모", "announce": "공지", "cancel": "취소"]
private let findingStateText = ["open": "열림", "fixed": "수정됨", "backlog": "나중에", "accepted-limit": "한계 인정", "rejected": "기각"]

/// `시각 누가 · 대상 행동 (이전 → 다음)` in the screen's words (design §3.2, D2, D3); a `-` target is left out.
func recentLine(_ e: TaskBoardEvent) -> String {
    let time = parseISO(e.at).map { boardClock(Date(timeIntervalSince1970: $0 / 1000)) } ?? ""
    var what = actionText[e.action] ?? e.action
    if e.action == "verdict", let v = e.verdict { what += " " + VerdictStyle.of(v).label }
    let state = { (s: String) in e.action == "finding" ? findingStateText[s] ?? s : TaskStateStyle.of(s).label }
    var line = "\(time) \(e.actor ?? "?") · \([e.ref == "-" ? nil : e.ref, what].compactMap { $0 }.joined(separator: " "))"
    if let from = e.stateFrom, let to = e.stateTo { line += " (\(state(from)) → \(state(to)))" }
    else if let to = e.stateTo { line += " (→ \(state(to)))" }
    return line
}

/// How long a task has been as it is: since `updated_at`, else `created_at`.
func taskElapsed(_ t: TaskBoardTask, now: Date) -> String {
    guard let ms = parseISO(t.updatedAt ?? t.createdAt) else { return "" }
    return shortDuration(minutes: max(0, Int((now.timeIntervalSince1970 * 1000 - ms) / 60_000)))
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct TaskStateIcon: View {
    let state: String
    var style: NSFont.TextStyle = .body
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        let s = TaskStateStyle.of(state)
        let size = StatusIconView.size(style, scale: scale)
        Image(systemName: s.symbol).font(.system(size: size)).foregroundStyle(s.color)
            .frame(width: size, height: size)
            .help(s.label)
            .accessibilityLabel(s.label)
    }
}

/// A line's leading state tag (v2 §A.3): icon and word in a fixed width, on the state's tint unless the task is over.
struct TaskStateTag: View {
    let state: String
    let tinted: Bool
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        let s = TaskStateStyle.of(state)
        HStack(spacing: 3) {
            Image(systemName: s.symbol).font(.system(size: StatusIconView.size(.caption1, scale: scale)))
            Text(s.label).scaledFont(.caption1, weight: .semibold).lineLimit(1)
        }
        .foregroundStyle(s.color)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .frame(width: 92 * scale, alignment: .leading)
        .background(tinted ? s.color.opacity(TaskGroupStyle.tagOpacity) : .clear, in: .rect(cornerRadius: 4))
    }
}

/// The sidebar's `작업판` line under a team (design §3.1): action (hidden at 0), review and active counts; `읽지 못함`
/// with the reason when no read has worked (D9).
struct TaskBoardSidebarRow: View {
    let counts: TaskCounts?
    var problem: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle").scaledFont(.body).foregroundStyle(.secondary)
            Text("작업판").scaledFont(.body).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let c = counts {
                if c.action > 0 { count(c.action, "exclamationmark.triangle.fill", .orange, "조치 필요") }
                count(c.review, "eye.circle.fill", .purple, "리뷰 대기")
                count(c.active, "circle.lefthalf.filled", .blue, "진행 중")
            } else if problem != nil {
                Text("읽지 못함").scaledFont(.caption1).foregroundStyle(.secondary)
            }
        }
        .help(counts.map { "조치 필요 \($0.action) · 리뷰 대기 \($0.review) · 진행 중 \($0.active)" } ?? problem ?? "작업판을 읽는 중")
    }

    private func count(_ n: Int, _ symbol: String, _ color: Color, _ label: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).foregroundStyle(color)
            Text("\(n)").monospacedDigit()
        }
        .scaledFont(.caption1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(n)")
    }
}

struct TaskBoardView: View {
    let team: String
    let state: TaskBoardState?
    let model: SidebarModel
    /// The picked task on this board, and its family's last read.
    let selectedTask: String?
    let family: TaskFamilyState?
    let pick: (String?) -> Void
    let select: (RowID) -> Void
    let reload: () -> Void
    @State private var finishedOpen = false
    @State private var allAnnouncements = false
    @State private var allRecent = false
    @State private var hovered: String?
    @FocusState private var listFocused: Bool
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 0) {
                header
                if let problem = state?.problem(now: context.date), state?.status != nil {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).lineLimit(1).truncationMode(.tail).help(problem)
                        .scaledFont(.callout).padding(.horizontal, 16).padding(.bottom, 6)
                }
                if let status = state?.status {
                    GeometryReader { geo in
                        let line = selectedTask.flatMap { id in taskGroups(status).values.joined().first { $0.task.id == id } }
                        // design §8 R3: beside the list when there is room for both, else in its place
                        if let line, geo.size.width >= 760 * scale {
                            HStack(spacing: 0) {
                                scrolled(status, now: context.date, width: geo.size.width * 0.5)
                                    .frame(width: geo.size.width * 0.5)
                                Divider()
                                detail(line, now: context.date, back: false)
                            }
                        } else if let line {
                            detail(line, now: context.date, back: true)
                        } else {
                            scrolled(status, now: context.date, width: geo.size.width)
                        }
                    }
                } else if let failure = state?.shownFailure {
                    failed(failure)
                } else {
                    Text("읽는 중…").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: state?.status) { _, s in
            if let s, selectedTask != nil, keepTaskSelection(selectedTask, in: s) == nil { pick(nil) }
        }
    }

    /// The list, its arrow keys walking the lines on screen (D7).
    private func scrolled(_ s: TaskBoardStatus, now: Date, width: CGFloat) -> some View {
        ScrollView { list(s, now: now, narrow: min(width, 1040 * scale) < 520 * scale) }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { step(s, 1) }
            .onKeyPress(.upArrow) { step(s, -1) }
    }

    private func step(_ s: TaskBoardStatus, _ delta: Int) -> KeyPress.Result {
        guard let next = stepTask(selectedTask, by: delta, in: visibleTaskIds(taskGroups(s), finishedOpen: finishedOpen)) else { return .ignored }
        pick(next)
        return .handled
    }

    private func detail(_ line: TaskLine, now: Date, back: Bool) -> some View {
        TaskDetailView(team: team, line: line, family: family?.ref == TaskRef(team: team, task: line.task.id) ? family : nil,
                       now: now, workerRow: workerRow, pick: pick, select: select, back: back ? { pick(nil) } : nil)
    }

    private var teamGroup: TeamGroup? { model.teams.first { $0.name == team } }

    func workerRow(_ name: String?) -> LiveRow? {
        name.flatMap { n in teamGroup?.rows.first { $0.worker?.workerName == n } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(team) 작업판").scaledFont(.title2, weight: .bold)
            if let workers = state?.status?.workers, !workers.isEmpty {
                WrapLayout(spacing: 6) {
                    ForEach(workers, id: \.name) { w in workerChip(w) }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    }

    private func workerChip(_ w: TaskBoardWorker) -> some View {
        let row = workerRow(w.name)
        let counts = [w.assigned > 0 ? "담당 \(w.assigned)" : nil, w.reviewing > 0 ? "리뷰 \(w.reviewing)" : nil].compactMap { $0 }
        return Button { if let row { select(row.id) } } label: {
            HStack(spacing: 4) {
                if let row { StatusIconView(badge: row.badge, style: .caption1) }
                Text(([w.name] + counts).joined(separator: " ")).scaledFont(.caption1)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(row == nil)
        .help(row == nil ? "\(w.name): 실행 중인 워커가 아닙니다" : "\(w.name)(으)로 이동")
    }

    private func failed(_ f: TaskBoardFailure) -> some View {
        let p = taskBoardProblem(f, bin: myTeamBin)
        return VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").scaledFont(.title2).foregroundStyle(.orange)
            Text(p.title).scaledFont(.headline, weight: .semibold)
            Text(p.detail).scaledFont(.callout).foregroundStyle(.secondary).textSelection(.enabled).multilineTextAlignment(.center)
            HStack {
                Button("다시 읽기 (⌘R)", action: reload)
                Button("오류 내용 복사") { copy("\(p.title)\n\(p.detail)") }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func list(_ s: TaskBoardStatus, now: Date, narrow: Bool) -> some View {
        let groups = taskGroups(s)
        VStack(alignment: .leading, spacing: 18) {
            announcements(s.announcements, now: now)
            if s.tasks.isEmpty {
                VStack(spacing: 4) {
                    Text("\(team) 작업판에 작업이 없습니다").foregroundStyle(.secondary)
                    Text("pm이 작업을 추가하면 여기에 보입니다").scaledFont(.caption1).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                if [TaskGroup.action, .review, .active].allSatisfy({ groups[$0] == nil }) {
                    Text("진행 중인 작업 없음").foregroundStyle(.secondary)
                }
                ForEach([TaskGroup.action, .review, .active], id: \.self) { g in
                    if let lines = groups[g] { section(g, lines, now: now, narrow: narrow) }
                }
                if let done = groups[.finished] {
                    let shown = Set(visibleTaskIds(groups, finishedOpen: finishedOpen))
                    let lines = done.filter { shown.contains($0.task.id) }
                    section(.finished, lines, count: done.count, now: now, narrow: narrow,
                            more: lines.count < done.count ? { finishedOpen = true } : nil)
                }
                recent(s.recent)
            }
        }
        .frame(maxWidth: 1040 * scale, alignment: .leading)
        .padding(.horizontal, 16).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func announcements(_ items: [TaskBoardAnnouncement], now: Date) -> some View {
        if let newest = items.last {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "megaphone").foregroundStyle(.secondary)
                    Text("공지 \(items.count)").scaledFont(.callout, weight: .semibold)
                    if !allAnnouncements {
                        Text(newest.body).scaledFont(.callout).lineLimit(1).truncationMode(.tail).help(newest.body)
                        Text("\(newest.createdBy ?? "") · \(relativeTime(newest.createdAt, now: now))")
                            .scaledFont(.caption1).foregroundStyle(.secondary).fixedSize()
                    }
                    Spacer(minLength: 8)
                    Button(allAnnouncements ? "접기" : "모두 보기") { allAnnouncements.toggle() }.buttonStyle(.link).scaledFont(.caption1)
                }
                if allAnnouncements {
                    ForEach(items.reversed(), id: \.seq) { a in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(a.createdBy ?? "") · \(relativeTime(a.createdAt, now: now))").scaledFont(.caption1).foregroundStyle(.secondary)
                            Text(a.body).scaledFont(.callout).textSelection(.enabled)
                                .frame(maxWidth: 720 * scale, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: 960 * scale, alignment: .leading)
            .background(DiffColors.header, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DiffColors.border))
        }
    }

    /// A group's box (v2 §A.3): a band in the group's color over its lines, a rule between lines.
    private func section(_ g: TaskGroup, _ lines: [TaskLine], count: Int? = nil, now: Date, narrow: Bool,
                         more: (() -> Void)? = nil) -> some View {
        let st = TaskGroupStyle.of(g)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: st.symbol).font(.system(size: 16 * scale)).foregroundStyle(st.color)
                Text(st.label).font(.system(size: 15 * scale, weight: .bold))
                Text("\(count ?? lines.count)").font(.system(size: 15 * scale, weight: .bold)).monospacedDigit().foregroundStyle(st.color)
                Spacer(minLength: 8)
                Text(st.whose).scaledFont(.caption1).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(st.color.opacity(TaskGroupStyle.bandOpacity))
            .overlay(alignment: .leading) { Rectangle().fill(st.color).frame(width: 5) }
            ForEach(lines, id: \.task.id) { line in
                Divider()
                taskRow(line, in: g, now: now, narrow: narrow)
            }
            if let more {
                Divider()
                Button("펼치기 (\((count ?? 0) - lines.count)개 더)", action: more).buttonStyle(.link).scaledFont(.caption1)
                    .padding(.horizontal, 10).padding(.vertical, 5)
            }
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DiffColors.border))
    }

    private func taskRow(_ line: TaskLine, in g: TaskGroup, now: Date, narrow: Bool) -> some View {
        let t = line.task
        let over = g == .finished
        let lead = 92 * scale + 6
        let head = HStack(alignment: .firstTextBaseline, spacing: 6) {
            TaskStateTag(state: t.state, tinted: !over)
            Text((line.child ? "↳ " : "") + t.id).scaledFont(.callout, weight: over ? .regular : .bold, design: .monospaced)
                .foregroundStyle(over ? .secondary : .primary)
                .lineLimit(1).frame(width: 62 * scale, alignment: .leading)
            Text(t.title).strikethrough(t.state == "cancelled").scaledFont(.body, weight: over ? .regular : .medium)
                .foregroundStyle(over ? .secondary : .primary)
                .lineLimit(narrow ? 2 : 1).truncationMode(.tail)
                .help(t.title)
        }
        let time = Text(over ? relativeTime(t.updatedAt ?? t.createdAt, now: now) : taskElapsed(t, now: now))
            .scaledFont(.caption1).foregroundStyle(.secondary).fixedSize()
            .help(over ? "끝난 때" : "\(TaskStateStyle.of(t.state).label) 상태로 있은 시간")
        let tail = HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let sev = line.worstSeverity { SeverityTag(severity: sev, count: line.findingCount) }
            people(taskPeople(line, in: g), links: !over)
        }
        return VStack(alignment: .leading, spacing: 2) {
            if narrow {
                HStack(alignment: .firstTextBaseline, spacing: 6) { head; Spacer(minLength: 8); time }
                tail.padding(.leading, lead)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) { head; Spacer(minLength: 8); tail; time }
            }
            if !line.reasons.isEmpty {
                Text(line.reasons.map(actionReasonText).joined(separator: " · "))
                    .scaledFont(.callout).foregroundStyle(.secondary)
                    .padding(.leading, lead)
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(selectedTask == t.id ? Color.accentColor.opacity(0.18) : hovered == t.id ? Color.primary.opacity(0.05) : .clear)
        .contentShape(.rect)
        .onHover { inside in hovered = inside ? t.id : hovered == t.id ? nil : hovered }
        .onTapGesture { pick(t.id); listFocused = true }
        .help(taskTooltip(t))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(TaskStateStyle.of(t.state).label), \(t.id), \(t.title)")
        .accessibilityAddTraits(selectedTask == t.id ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { pick(t.id) }
        .contextMenu {
            Button("id 복사") { copy(t.id) }
            Button("티켓 경로 복사") { if let p = t.ticketPath { copy(p) } }.disabled(t.ticketPath?.isEmpty ?? true)
        }
    }

    private func taskTooltip(_ t: TaskBoardTask) -> String {
        [t.ticketPath.map { "티켓: \($0)" }, t.constraints.map { "제약: \($0)" },
         "등록: \(t.createdBy ?? "?") · \(fullTime(t.createdAt))",
         "담당: \(t.assignee ?? "없음") · 판정자: \(t.reviewer ?? "없음")"].compactMap { $0 }.joined(separator: "\n")
    }

    /// `역할 이름 → 역할 이름` (v2 §B): the one whose move it is bold with the worker's state icon, the other muted;
    /// a name selects its worker except on a finished line.
    private func people(_ ps: [TaskPerson], links: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            ForEach(Array(ps.enumerated()), id: \.offset) { i, p in
                if i > 0 { Text("→").scaledFont(.callout).foregroundStyle(.secondary) }
                Text(personRoleText(p.role)).scaledFont(.caption1).foregroundStyle(.secondary)
                person(p, links: links)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private func person(_ p: TaskPerson, links: Bool) -> some View {
        if let name = p.name {
            let row = workerRow(name)
            let label = HStack(spacing: 2) {
                if p.turn, let row { StatusIconView(badge: row.badge, style: .caption1) }
                Text(name).scaledFont(.callout, weight: p.turn ? .bold : .regular)
                    .foregroundStyle(p.turn ? .primary : .secondary)
            }
            if links, let row {
                Button { select(row.id) } label: { label }.buttonStyle(.plain).help("\(name)(으)로 이동")
            } else {
                label
            }
        } else {
            Text("없음").scaledFont(.callout).foregroundStyle(p.role == .assignee ? TaskColor.orange : DiffColors.mutedText)
        }
    }

    @ViewBuilder
    private func recent(_ events: [TaskBoardEvent]) -> some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("최근 활동").scaledFont(.headline, weight: .semibold)
                    Spacer()
                    if events.count > 3 {
                        Button(allRecent ? "접기" : "모두 보기") { allRecent.toggle() }.buttonStyle(.link).scaledFont(.caption1)
                    }
                }
                ForEach(Array(events.reversed().prefix(allRecent ? 20 : 3)), id: \.seq) { e in
                    Text(recentLine(e)).scaledFont(.callout).foregroundStyle(.secondary).lineLimit(1).help(e.detail ?? recentLine(e))
                }
            }
        }
    }
}

/// A finding's severity (design §4.3): must filled red, should orange outline, low gray outline.
struct SeverityTag: View {
    let severity: String
    let count: Int

    var body: some View {
        let color: Color = severity == "must" ? .red : severity == "should" ? .orange : .secondary
        Text(count > 1 ? "\(severity) \(count)" : severity)
            .scaledFont(.caption1, weight: .bold, design: .monospaced)
            .foregroundStyle(severity == "must" ? Color.white : color)
            .padding(.horizontal, 4)
            .background(severity == "must" ? color : .clear, in: .rect(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color, lineWidth: severity == "must" ? 0 : 1))
            .fixedSize()
            .help("열린 지적 \(count)건, 가장 높은 심각도 \(severity)")
    }
}

/// Lays its views left to right and wraps to the next line when the width runs out (design §8 R7).
struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.items + [i], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([i], size.width, size.height))
            }
        }
        return rows
    }
}
