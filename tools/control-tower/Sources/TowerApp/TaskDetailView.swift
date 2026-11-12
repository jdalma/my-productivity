import SwiftUI
import TowerCore

// One task picked on a task board (T70a; design §3.3, §4.2, §4.3): its facts, its family, the open findings,
// every landing of the family with its verdicts and their findings, and the notes. Paths and commands are copied,
// never opened (pm decision 5).

/// How a verdict looks (design §4.2).
struct VerdictStyle: Equatable {
    var label: String
    var symbol: String
    var color: Color

    static func of(_ verdict: String) -> VerdictStyle {
        switch verdict {
        case "approve": VerdictStyle(label: "승인", symbol: "checkmark.seal.fill", color: .green)
        case "changes": VerdictStyle(label: "수정 요청", symbol: "arrow.uturn.backward.circle.fill", color: .orange)
        case "hold": VerdictStyle(label: "보류", symbol: "pause.circle.fill", color: .red)
        default: VerdictStyle(label: verdict, symbol: "questionmark.circle", color: .secondary)
        }
    }
}

/// How a finding's state looks (design §4.3): only open ones are strong.
struct FindingStyle: Equatable {
    var label: String
    var symbol: String
    var color: Color
    var struck = false

    static func of(_ s: FindingStatus) -> FindingStyle {
        switch s {
        case .open: FindingStyle(label: "열림", symbol: "smallcircle.filled.circle", color: .red)
        case .fixedPending: FindingStyle(label: "수정됨 · 승인 대기", symbol: "checkmark", color: .secondary)
        case .fixedApproved(let l): FindingStyle(label: "수정됨 (\(l))", symbol: "checkmark", color: .green)
        case .backlog: FindingStyle(label: "나중에", symbol: "tray.and.arrow.down", color: .secondary)
        case .acceptedLimit: FindingStyle(label: "한계 인정", symbol: "minus.circle", color: .secondary)
        case .rejected: FindingStyle(label: "기각", symbol: "xmark", color: .secondary, struck: true)
        case .other(let state): FindingStyle(label: state, symbol: "questionmark.circle", color: .secondary)
        }
    }
}

/// `작성자 · MM/dd HH:mm` for a record.
func byLine(_ who: String?, _ at: String?) -> String {
    let time = parseISO(at).map { Date(timeIntervalSince1970: $0 / 1000).formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
    return [who, time].compactMap { $0 }.joined(separator: " · ")
}

struct TaskDetailView: View {
    let team: String
    /// The task as the list has it: the head draws from it before the family is read (U6).
    let line: TaskLine
    let family: TaskFamilyState?
    let now: Date
    let workerRow: (String?) -> LiveRow?
    let pick: (String?) -> Void
    let select: (RowID) -> Void
    /// Shown in place of the list: the way back to it.
    let back: (() -> Void)?
    /// Superseded cards opened by the user.
    @State private var openLandings: Set<String> = []
    @Environment(\.boardFontScale) private var scale

    private var detail: TaskDetail? { family?.family.flatMap { taskDetail($0, task: line.task.id) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let back {
                    Button("← \(team) 작업판 (Esc)", action: back).buttonStyle(.link).scaledFont(.caption1)
                }
                head(detail?.task ?? line.task)
                if let d = detail {
                    family(d)
                    if !d.openFindings.isEmpty { openFindings(d) }
                    cards(d)
                    notes(d)
                } else if let failure = family?.failure {
                    let p = taskBoardProblem(failure, bin: myTeamBin)
                    Label("\(p.title) · \(p.detail)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .scaledFont(.callout).textSelection(.enabled)
                } else {
                    Text("읽는 중…").foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: detail) { _, d in if let d { openLandings = keepOpenLandings(openLandings, in: d) } }
    }

    private func head(_ t: TaskBoardTask) -> some View {
        let style = TaskStateStyle.of(t.state)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(t.id).scaledFont(.title2, weight: .bold, design: .monospaced).textSelection(.enabled)
                Text(t.title).scaledFont(.title2, weight: .bold).lineLimit(3).textSelection(.enabled)
            }
            HStack(spacing: 6) {
                TaskStateIcon(state: t.state, style: .callout)
                Text("\(style.label) \(taskElapsed(t, now: now))").scaledFont(.callout).foregroundStyle(.secondary)
                if !line.reasons.isEmpty {
                    Text(line.reasons.map(actionReasonText).joined(separator: " · ")).scaledFont(.callout).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { label("담당"); person(t.assignee) }
                GridRow { label("판정자"); person(t.reviewer) }
                if let p = t.ticketPath?.nonEmptyText { GridRow { label("티켓"); CopyText(text: p) } }
                GridRow { label("제약"); Text(t.constraints?.nonEmptyText ?? "없음").scaledFont(.callout).textSelection(.enabled) }
                GridRow { label("우선순위"); Text("\(t.priority)").scaledFont(.callout) }
                if let b = t.baseCommit?.nonEmptyText { GridRow { label("base"); CopyText(text: b, shown: String(b.prefix(7))) } }
                GridRow { label("만든 사람"); Text(byLine(t.createdBy, t.createdAt)).scaledFont(.callout) }
            }
        }
    }

    private func label(_ s: String) -> some View { Text(s).scaledFont(.callout).foregroundStyle(.secondary) }

    @ViewBuilder
    private func person(_ name: String?) -> some View {
        if let name {
            let row = workerRow(name)
            Button { if let row { select(row.id) } } label: {
                HStack(spacing: 3) {
                    if let row { StatusIconView(badge: row.badge, style: .caption1) }
                    Text(name).scaledFont(.callout)
                }
            }
            .buttonStyle(.plain)
            .disabled(row == nil)
        } else {
            Text("없음").scaledFont(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func family(_ d: TaskDetail) -> some View {
        if d.family.count > 1 {
            section("계열 \(d.family.count)")
            ForEach(d.family, id: \.id) { t in
                Button { pick(t.id) } label: {
                    HStack(spacing: 6) {
                        if t.parentId != nil { Text("↳").foregroundStyle(.secondary) }
                        TaskStateIcon(state: t.state, style: .callout)
                        Text(t.id).scaledFont(.callout, design: .monospaced)
                        Text(t.title).scaledFont(.callout).lineLimit(1)
                    }
                    .fontWeight(t.id == line.task.id ? .semibold : .regular)
                }
                .buttonStyle(.plain)
                .disabled(t.id == line.task.id)
            }
        }
    }

    private func openFindings(_ d: TaskDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            section("열린 지적 \(d.openFindings.count)")
            ForEach(d.openFindings, id: \.id) { findingRow($0, approved: d.approvedLandings) }
        }
    }

    @ViewBuilder
    private func cards(_ d: TaskDetail) -> some View {
        section("완료 기록과 판정 \(d.cards.count)")
        if d.cards.isEmpty { Text("아직 완료 기록이 없습니다").scaledFont(.callout).foregroundStyle(.secondary) }
        ForEach(d.cards, id: \.landing.id) { card($0, approved: d.approvedLandings) }
    }

    private func card(_ c: LandingCard, approved: Set<String>) -> some View {
        let l = c.landing
        let folded = l.supersededBy != nil && !openLandings.contains(l.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(l.id).scaledFont(.headline, weight: .semibold, design: .monospaced)
                Text(byLine(l.createdBy, l.createdAt)).scaledFont(.caption1).foregroundStyle(.secondary)
                CopyText(text: l.commit, shown: String(l.commit.prefix(7)))
                if l.deployed { Text("설치됨").scaledFont(.caption1).foregroundStyle(.green) }
                Spacer(minLength: 8)
                if let by = l.supersededBy {
                    Button(folded ? "\(by)로 대체됨 · 펼치기" : "\(by)로 대체됨 · 접기") {
                        if folded { openLandings.insert(l.id) } else { openLandings.remove(l.id) }
                    }
                    .buttonStyle(.link).scaledFont(.caption1)
                }
            }
            if !folded {
                if let cmd = l.checkCmd?.nonEmptyText {
                    fact("확인", CopyText(text: cmd, mono: true), tail: l.checkResult.map { "→ \($0)" })
                }
                if !l.focus.isEmpty { fact("볼 곳", Text(l.focus.joined(separator: "\n")).scaledFont(.callout).textSelection(.enabled)) }
                if !l.closes.isEmpty { fact("닫은 지적", Text(l.closes.joined(separator: ", ")).scaledFont(.callout, design: .monospaced)) }
                if let p = l.reportPath?.nonEmptyText { fact("보고서", CopyText(text: p)) }
                if !l.leftOut.isEmpty {
                    fact("빠진 커밋", Text("\(l.leftOut.count)개").scaledFont(.callout).foregroundStyle(.orange)
                        .help(l.leftOut.joined(separator: "\n")))
                }
                ForEach(c.verdicts, id: \.verdict.id) { verdict($0, reviewReport: l.reviewReportPath, approved: approved) }
            }
        }
        .padding(10)
        .background(DiffColors.header, in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DiffColors.border))
        .opacity(l.supersededBy != nil ? 0.8 : 1)
    }

    private func verdict(_ v: VerdictCard, reviewReport: String?, approved: Set<String>) -> some View {
        let style = VerdictStyle.of(v.verdict.verdict)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: style.symbol).foregroundStyle(style.color).accessibilityLabel(style.label)
                Text("\(v.verdict.id) \(style.label)").scaledFont(.callout, weight: .semibold)
                Text(byLine(v.verdict.createdBy, v.verdict.createdAt)).scaledFont(.caption1).foregroundStyle(.secondary)
            }
            if let cmd = v.verdict.rerunCmd?.nonEmptyText {
                fact("재실행", CopyText(text: cmd, mono: true), tail: v.verdict.rerunResult.map { "→ \($0)" })
            }
            if let p = (v.verdict.reportPath ?? reviewReport)?.nonEmptyText { fact("리뷰 보고서", CopyText(text: p)) }
            if let n = v.verdict.sideNotes?.nonEmptyText { fact("덧붙인 말", Text(n).scaledFont(.callout).textSelection(.enabled)) }
            ForEach(v.findings, id: \.id) { findingRow($0, approved: approved) }
        }
        .padding(.leading, 16)
    }

    private func findingRow(_ f: TaskBoardFinding, approved: Set<String>) -> some View {
        let style = FindingStyle.of(findingStatus(f, approved: approved))
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: style.symbol).foregroundStyle(style.color).accessibilityLabel(style.label)
                Text(f.id).scaledFont(.callout, design: .monospaced).fixedSize()
                SeverityTag(severity: f.severity, count: 1)
                Text(style.label).scaledFont(.caption1).foregroundStyle(style.color == .secondary ? .secondary : style.color).fixedSize()
                Text(f.summary).scaledFont(.callout).strikethrough(style.struck).textSelection(.enabled)
            }
            if let repro = f.repro?.nonEmptyText {
                CopyText(text: repro, mono: true).padding(.leading, StatusIconView.size(.callout, scale: scale) + 6)
            }
        }
    }

    @ViewBuilder
    private func notes(_ d: TaskDetail) -> some View {
        if !d.notes.isEmpty {
            section("메모 \(d.notes.count)")
            ForEach(d.notes, id: \.seq) { n in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(n.createdBy ?? "?") → \(n.to.joined(separator: ", ")) · \(byLine(nil, n.createdAt))\(n.taskId.map { $0 == line.task.id ? "" : " · \($0)" } ?? "")")
                        .scaledFont(.caption1).foregroundStyle(.secondary)
                    Text(n.body).scaledFont(.callout).textSelection(.enabled)
                }
            }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).scaledFont(.headline, weight: .semibold).padding(.top, 4)
    }

    private func fact(_ name: String, _ value: some View, tail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).scaledFont(.caption1).foregroundStyle(.secondary).frame(minWidth: 64 * scale, alignment: .leading)
            value
            if let tail { Text(tail).scaledFont(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }
}

/// Text that can be selected, with a button that copies all of it (design §3.3: paths, commands, commits).
struct CopyText: View {
    let text: String
    var shown: String?
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(shown ?? text)
                .scaledFont(.callout, design: mono || shown != nil || text.hasPrefix("/") ? .monospaced : .default)
                .lineLimit(shown == nil ? 3 : 1).truncationMode(.middle)
                .textSelection(.enabled)
                .help(text)
            Button { copy(text) } label: { Image(systemName: "doc.on.doc").scaledFont(.caption1) }
                .buttonStyle(.borderless)
                .help("복사: \(text)")
                .accessibilityLabel("복사")
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
