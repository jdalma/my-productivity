import SwiftUI
import TowerCore

// The board's decisions in the task board window (T147): one row each in 사용자 결정 필요 and 지난 결정, a detail
// when one is picked, and the decisions of a task in its detail.

/// `T1 결정 목록 화면`, every task a decision is tied to; `작업 없음` for one asked of no task.
func decisionTasksText(_ d: BoardDecision, tasks: [TaskBoardTask], team: String) -> String {
    guard !d.related.isEmpty else { return "작업 없음" }
    return d.related.map { id in
        tasks.first { $0.id == id }.map { "\(id) \(shownTitle($0.title, team: team))" } ?? id
    }.joined(separator: ", ")
}

/// `D#6, 질문…`: what a decision's tooltip and VoiceOver label begin with, so the user can name it (T219).
func decisionHeadline(_ d: BoardDecision) -> String {
    "\(d.id), \(decisionQuestion(d))"
}

/// The question, or what stands for it when the board kept none (a waiting task without a brief, R4 S1).
func decisionQuestion(_ d: BoardDecision) -> String {
    d.brief.question.nonEmptyText ?? d.taskId.map { "\($0)의 결정 (질문이 기록되지 않음)" } ?? "질문이 기록되지 않은 결정"
}

/// `A — 사용자: 전부 보여 준다`, `철회 — 계획이 바뀜`, or the answer alone without a choice.
func decisionAnswerText(_ d: BoardDecision) -> String {
    let answer = d.answer?.nonEmptyText
    guard let chosen = d.chosen?.nonEmptyText else { return answer ?? "" }
    return chosen + (answer.map { " — \($0)" } ?? "")
}

/// `pm이 기록 · 14:02`: who recorded the answer and when.
func decisionAnsweredLine(_ d: BoardDecision, now: Date) -> String? {
    let when = detailClock(d.answeredAt, now: now)
    guard d.answeredBy != nil || when != nil else { return nil }
    return [d.answeredBy.map { withParticle($0, "이", "가") + " 기록" }, when].compactMap { $0 }.joined(separator: " · ")
}

/// What VoiceOver reads after a decision row's question: its tasks, and its answer or who asked it.
func decisionAccessibilityValue(_ d: BoardDecision, tasks: [TaskBoardTask], team: String, now: Date) -> String {
    let state = d.open ? "답을 기다림" : "답함, \(decisionAnswerText(d))"
    return [state, decisionTasksText(d, tasks: tasks, team: team), askedLine(d.brief, now: now)].compactMap { $0 }.joined(separator: ", ")
}

/// A decision's list row: its id, the question, then its tasks and who asked (an open one) or what was chosen (a past one).
struct DecisionRow: View {
    let decision: BoardDecision
    let tasks: [TaskBoardTask]
    let team: String
    let now: Date
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        let d = decision
        let taskText = decisionTasksText(d, tasks: tasks, team: team)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: d.open ? "person.fill.questionmark" : "checkmark.bubble")
                    .foregroundStyle(d.open ? TaskColor.pink : TaskColor.gray).accessibilityHidden(true)
                // where a task line shows its id (T219)
                Text(d.id).scaledFont(.callout, design: .monospaced).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Text(decisionQuestion(d)).scaledFont(.body, weight: d.open ? .semibold : .regular)
                    .lineLimit(2).truncationMode(.tail)
                Spacer(minLength: 8)
                Text(detailClock(d.open ? d.brief.askedAt : d.answeredAt, now: now) ?? "")
                    .scaledFont(.callout).monospacedDigit().foregroundStyle(.secondary).fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                tasksLine(d).scaledFont(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Text(d.open ? (askedLine(d.brief, now: now).map { "· \($0)" } ?? "") : "· \(decisionAnswerText(d))")
                    .scaledFont(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .padding(.leading, 22 * scale)
        }
        .padding(.vertical, 3)
        .help([decisionHeadline(d), taskText, d.open ? nil : decisionAnswerText(d)].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(decisionHeadline(d))
        .accessibilityValue(decisionAccessibilityValue(d, tasks: tasks, team: team, now: now))
    }

    /// The tasks with their ids monospaced, as the task rows show ids; `작업 없음` when there is none.
    private func tasksLine(_ d: BoardDecision) -> Text {
        guard !d.related.isEmpty else { return Text("작업 없음") }
        return d.related.enumerated().reduce(Text("")) { line, item in
            let (i, id) = item
            let title = tasks.first { $0.id == id }.map { " " + shownTitle($0.title, team: team) } ?? ""
            return line + Text(i == 0 ? "" : ", ") + Text(id).monospaced() + Text(title)
        }
    }
}

/// A picked decision, read as a document (T155): where it is, its properties, the answer when there is one, and
/// the brief.
struct DecisionDetailView: View {
    let decision: BoardDecision
    let tasks: [TaskBoardTask]
    let team: String
    let now: Date
    let pick: (String?) -> Void

    var body: some View {
        let d = decision
        let color = d.open ? TaskColor.pink : TaskColor.gray
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailLocation(parts: ["\(team) 작업판", "결정", d.id])
                PropertyGrid {
                    GridRow {
                        PropertyName("상태", symbol: "circle.lefthalf.filled")
                        Label(d.open ? "답을 기다림" : "답함", systemImage: d.open ? "person.fill.questionmark" : "checkmark.bubble")
                            .scaledFont(.callout, weight: .semibold).foregroundStyle(color)
                    }
                    GridRow {
                        PropertyName("물은 사람", symbol: "person")
                        if let by = d.brief.askedBy { PersonTag(name: by) } else { Text("기록 없음").scaledFont(.callout).foregroundStyle(.secondary) }
                    }
                    GridRow {
                        PropertyName("물은 때", symbol: "clock")
                        Text(detailClock(d.brief.askedAt, now: now) ?? "기록 없음").scaledFont(.callout).textSelection(.enabled)
                    }
                    GridRow {
                        PropertyName("관련 작업", symbol: "arrow.left.arrow.right")
                        VStack(alignment: .leading, spacing: 4) {
                            if d.related.isEmpty { Text("작업 없음").scaledFont(.callout).foregroundStyle(.secondary) }
                            ForEach(d.related, id: \.self) { id in
                                TaskLink(id: id, task: tasks.first { $0.id == id }, team: team, pick: pick)
                            }
                        }
                    }
                }
                Divider()
                if !d.open { DecisionAnswerView(decision: d, now: now) }
                DecisionBriefView(brief: d.brief, now: now, showsAsked: false)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(TaskPanelStyle.bandOpacity), in: .rect(cornerRadius: 8))
                    .modifier(IncreasedContrastBorder(color: color, radius: 8))
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(d.id)
    }
}

/// What the user chose, in their words, and who recorded it when.
struct DecisionAnswerView: View {
    let decision: BoardDecision
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("사용자 결정").scaledFont(.callout, weight: .semibold).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            Text(decisionAnswerText(decision)).scaledFont(.body, weight: .semibold).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let line = decisionAnsweredLine(decision, now: now) {
                Text(line).scaledFont(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(TaskColor.green, lineWidth: 2))
        .accessibilityElement(children: .combine)
    }
}

/// The decisions of a task that wait for the user, in its detail: each whole on a pink ground, as the user decides
/// from it (T155). The answered ones are tags among the task's properties.
struct TaskDecisionsView: View {
    let decisions: [BoardDecision]
    let now: Date

    var body: some View {
        ForEach(decisions.filter(\.open), id: \.id) { d in
            DecisionBriefView(brief: d.brief, now: now)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TaskColor.pink.opacity(TaskPanelStyle.bandOpacity), in: .rect(cornerRadius: 8))
                .modifier(IncreasedContrastBorder(color: TaskColor.pink, radius: 8))
        }
    }
}
