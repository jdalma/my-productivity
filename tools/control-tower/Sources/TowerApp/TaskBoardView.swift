import SwiftUI
import TowerCore

// A team's task board (T70; design: ~/.my-team/docs/control-tower/design/board-view.md §3.1, §3.2, §4, §5).
// Read only: nothing here writes to the board. Paths are copied, never opened (pm decision 5).

/// How a task state looks (design §4.1): each shape differs, so color is never the only cue.
struct TaskStateStyle: Equatable {
    var label: String
    var symbol: String
    var color: Color

    static func of(_ state: String) -> TaskStateStyle {
        switch state {
        case "new": TaskStateStyle(label: "미배정", symbol: "circle.dashed", color: .orange)
        case "ready": TaskStateStyle(label: "착수 전", symbol: "circle", color: .secondary)
        case "doing": TaskStateStyle(label: "진행 중", symbol: "circle.lefthalf.filled", color: .blue)
        case "review": TaskStateStyle(label: "리뷰 대기", symbol: "eye.circle.fill", color: .purple)
        case "changes": TaskStateStyle(label: "수정 요청", symbol: "arrow.uturn.backward.circle.fill", color: .orange)
        case "held": TaskStateStyle(label: "보류", symbol: "pause.circle.fill", color: .red)
        case "done": TaskStateStyle(label: "완료", symbol: "checkmark.circle.fill", color: .green)
        case "cancelled": TaskStateStyle(label: "취소", symbol: "xmark.circle", color: .secondary)
        default: TaskStateStyle(label: state, symbol: "questionmark.circle", color: .secondary)
        }
    }

    static let all = ["new", "ready", "doing", "review", "changes", "held", "done", "cancelled"]
}

/// A group's head (design §2): its icon, name and whose move it is.
struct TaskGroupStyle {
    var label: String
    var symbol: String
    var color: Color
    var whose: String

    static func of(_ g: TaskGroup) -> TaskGroupStyle {
        switch g {
        case .action: TaskGroupStyle(label: "조치 필요", symbol: "exclamationmark.triangle.fill", color: .orange, whose: "pm 차례")
        case .review: TaskGroupStyle(label: "리뷰 대기", symbol: "eye.circle.fill", color: .purple, whose: "판정자 차례")
        case .active: TaskGroupStyle(label: "진행 중", symbol: "circle.lefthalf.filled", color: .blue, whose: "담당 차례")
        case .finished: TaskGroupStyle(label: "끝남", symbol: "checkmark.circle.fill", color: .green, whose: "")
        }
    }
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

/// `시각 누가 · 대상 행동 (이전 → 다음)` (design §3.2, 최근 활동).
func recentLine(_ e: TaskBoardEvent) -> String {
    let time = parseISO(e.at).map { boardClock(Date(timeIntervalSince1970: $0 / 1000)) } ?? ""
    var line = "\(time) \(e.actor ?? "?") · \([e.ref, e.action].compactMap { $0 }.joined(separator: " "))"
    if let from = e.stateFrom, let to = e.stateTo { line += " (\(from) → \(to))" }
    else if let to = e.stateTo { line += " (→ \(to))" }
    return line
}

/// How long a task has been as it is: since `updated_at`, else `created_at`.
func taskElapsed(_ t: TaskBoardTask, now: Date) -> String {
    guard let ms = parseISO(t.updatedAt ?? t.createdAt) else { return "" }
    return shortDuration(minutes: max(0, Int((now.timeIntervalSince1970 * 1000 - ms) / 60_000)))
}

/// Shown at most in the finished group until "펼치기" (pm decision 7).
let finishedShown = 5

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

/// The sidebar's `작업판` line under a team (design §3.1): action (hidden at 0), review and active counts.
struct TaskBoardSidebarRow: View {
    let counts: TaskCounts?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle").scaledFont(.body).foregroundStyle(.secondary)
            Text("작업판").scaledFont(.body)
            Spacer(minLength: 8)
            if let c = counts {
                if c.action > 0 { count(c.action, "exclamationmark.triangle.fill", .orange, "조치 필요") }
                count(c.review, "eye.circle.fill", .purple, "리뷰 대기")
                count(c.active, "circle.lefthalf.filled", .blue, "진행 중")
            }
        }
        .help(counts.map { "조치 필요 \($0.action) · 리뷰 대기 \($0.review) · 진행 중 \($0.active)" } ?? "작업판을 읽는 중")
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
                                ScrollView { list(status, now: context.date, narrow: geo.size.width * 0.5 < 520 * scale) }
                                    .frame(width: geo.size.width * 0.5)
                                Divider()
                                detail(line, now: context.date, back: false)
                            }
                        } else if let line {
                            detail(line, now: context.date, back: true)
                        } else {
                            ScrollView { list(status, now: context.date, narrow: geo.size.width < 520 * scale) }
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
        VStack(alignment: .leading, spacing: 14) {
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
                    let open = finishedOpen || [TaskGroup.action, .review, .active].allSatisfy { groups[$0] == nil }
                    section(.finished, open ? done : Array(done.prefix(finishedShown)), count: done.count, now: now, narrow: narrow,
                            more: done.count > finishedShown && !open ? { finishedOpen = true } : nil)
                }
                recent(s.recent)
            }
        }
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
                        }
                    }
                }
            }
        }
    }

    private func section(_ g: TaskGroup, _ lines: [TaskLine], count: Int? = nil, now: Date, narrow: Bool,
                         more: (() -> Void)? = nil) -> some View {
        let st = TaskGroupStyle.of(g)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: st.symbol).foregroundStyle(st.color)
                Text("\(st.label) \(count ?? lines.count)").scaledFont(.headline, weight: .semibold)
                Spacer(minLength: 8)
                Text(st.whose).scaledFont(.caption1).foregroundStyle(.secondary)
            }
            ForEach(lines, id: \.task.id) { line in taskRow(line, now: now, narrow: narrow) }
            if let more { Button("펼치기 (\((count ?? 0) - lines.count)개 더)", action: more).buttonStyle(.link).scaledFont(.caption1) }
        }
    }

    private func taskRow(_ line: TaskLine, now: Date, narrow: Bool) -> some View {
        let t = line.task
        let head = HStack(alignment: .firstTextBaseline, spacing: 6) {
            if line.child { Text("↳").foregroundStyle(.secondary) }
            TaskStateIcon(state: t.state)
            Text(t.id).scaledFont(.callout, design: .monospaced).fixedSize()
            Text(t.title).scaledFont(.body).lineLimit(narrow ? 2 : 1).truncationMode(.tail)
                .strikethrough(t.state == "cancelled")
                .help(t.title)
        }
        let tail = HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let sev = line.worstSeverity { SeverityTag(severity: sev, count: line.findingCount) }
            people(t)
            Text(taskElapsed(t, now: now)).scaledFont(.caption1).foregroundStyle(.secondary).fixedSize()
                .help("\(TaskStateStyle.of(t.state).label) 상태로 있은 시간")
        }
        return VStack(alignment: .leading, spacing: 2) {
            if narrow {
                head
                tail.padding(.leading, StatusIconView.size(.body, scale: scale) + 6)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) { head; Spacer(minLength: 8); tail }
            }
            if !line.reasons.isEmpty {
                Text(line.reasons.map(actionReasonText).joined(separator: " · "))
                    .scaledFont(.callout).foregroundStyle(.secondary)
                    .padding(.leading, StatusIconView.size(.body, scale: scale) + 6)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(selectedTask == t.id ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 5))
        .contentShape(.rect)
        .onTapGesture { pick(t.id) }
        .help(taskTooltip(t))
        .contextMenu {
            Button("id 복사") { copy(t.id) }
            Button("티켓 경로 복사") { if let p = t.ticketPath { copy(p) } }.disabled(t.ticketPath?.isEmpty ?? true)
        }
    }

    private func taskTooltip(_ t: TaskBoardTask) -> String {
        [t.ticketPath.map { "티켓: \($0)" }, t.constraints.map { "제약: \($0)" },
         "만든 사람: \(t.createdBy ?? "?") · \(t.createdAt ?? "")"].compactMap { $0 }.joined(separator: "\n")
    }

    /// `담당 → 판정자`, each with the worker's state icon (pm decision 4); a click selects that worker.
    private func people(_ t: TaskBoardTask) -> some View {
        HStack(spacing: 3) {
            person(t.assignee)
            if t.reviewer != nil {
                Text("→").scaledFont(.callout).foregroundStyle(.secondary)
                person(t.reviewer)
            }
        }
    }

    @ViewBuilder
    private func person(_ name: String?) -> some View {
        if let name {
            let row = workerRow(name)
            Button { if let row { select(row.id) } } label: {
                HStack(spacing: 2) {
                    if let row { StatusIconView(badge: row.badge, style: .caption1) }
                    Text(name).scaledFont(.callout)
                }
            }
            .buttonStyle(.plain)
            .disabled(row == nil)
        } else {
            Text("담당 없음").scaledFont(.callout).foregroundStyle(.secondary)
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
