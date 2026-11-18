import SwiftUI
import TowerCore

/// A decision brief the user decides from without reading anything else (T116, announcement 15): the question
/// largest, why it is asked, each option with what it means and its pros and cons, the recommendation, what stays
/// stopped while undecided, and what to read. The detail shows the open one; a history line folds out an answered one.
struct DecisionBriefView: View {
    let brief: TaskWaiting
    let now: Date
    /// Off where the properties above already say who asked and when.
    var showsAsked = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(brief.question).scaledFont(.title3, weight: .semibold).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if showsAsked, let asked = askedLine(brief, now: now) { Text(asked).scaledFont(.callout).foregroundStyle(.secondary) }
            if let c = brief.context?.nonEmptyText { part("배경") { MarkdownView(short: c) } }
            if let heading = optionsHeading(brief) {
                part(heading) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(brief.options.enumerated()), id: \.offset) { _, o in option(o) }
                        if let missing = unreadOptionsText(brief) {
                            Label(missing, systemImage: "exclamationmark.triangle").scaledFont(.callout).foregroundStyle(TaskColor.orange)
                        }
                    }
                }
            }
            if let r = brief.recommendation { part("추천") { line(recommendationText(r)) } }
            if let i = brief.impact?.nonEmptyText { part("정하지 않으면") { MarkdownView(short: i) } }
            if !brief.refs.isEmpty {
                part("참고 자료") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(brief.refs.enumerated()), id: \.offset) { OpenPath(path: $0.element, what: "참고 자료", mono: true) }
                    }
                }
            }
        }
    }

    private func option(_ o: DecisionOption) -> some View {
        let recommended = brief.recommendation?.option == o.label
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(o.label).scaledFont(.body, weight: .semibold).textSelection(.enabled)
                if recommended {
                    Label("추천", systemImage: "star.fill").scaledFont(.caption1, weight: .bold).foregroundStyle(TaskColor.pink)
                }
            }
            if let d = o.detail?.nonEmptyText { MarkdownView(short: d) }
            points("장점", o.pros, symbol: "plus.circle")
            points("단점", o.cons, symbol: "minus.circle")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(recommended ? TaskColor.pink : DiffColors.border, lineWidth: recommended ? 2 : 1))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func points(_ name: String, _ items: [String], symbol: String) -> some View {
        if !items.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label(name, systemImage: symbol).scaledFont(.callout).foregroundStyle(.secondary).fixedSize()
                VStack(alignment: .leading, spacing: 2) { ForEach(Array(items.enumerated()), id: \.offset) { line($0.element) } }
            }
        }
    }

    private func part(_ name: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).scaledFont(.callout, weight: .semibold).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// One line with its inline marks read; the parts that run to paragraphs and lists are drawn by `MarkdownView`
    /// (T155). The question is never either (H7).
    private func line(_ s: String) -> some View {
        Text(inlineMarkdown(s)).scaledFont(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}

/// What the card says when some options could not be read (R41 L3), so a missing choice is not taken for none.
/// The options part's head, counting the options that could not be read; nil, and no part, when there were none at
/// all. A brief whose options all failed to read keeps the part, so its warning shows (R43 L1).
func optionsHeading(_ b: TaskWaiting) -> String? {
    b.options.isEmpty && b.unreadOptions == 0 ? nil : "선택지 \(b.options.count + b.unreadOptions)"
}

func unreadOptionsText(_ b: TaskWaiting) -> String? {
    b.unreadOptions > 0 ? "선택지 \(b.unreadOptions)개는 읽지 못해 빠졌습니다" : nil
}

/// `A. 두 호출자가 모두 원한다`, or `추천 없음 — <이유>` when the asker recommends none.
func recommendationText(_ r: DecisionRecommendation) -> String {
    let reason = r.reason?.nonEmptyText
    guard let option = r.option else { return "추천 없음" + (reason.map { " — \($0)" } ?? "") }
    return option + (reason.map { ". \($0)" } ?? "")
}

/// `delta가 물음 · 14:02`: who asked and when.
func askedLine(_ b: TaskWaiting, now: Date) -> String? {
    let when = b.askedAt.flatMap { at in detailClock(at, now: now) }
    guard b.askedBy != nil || when != nil else { return nil }
    return [b.askedBy.map { withParticle($0, "이", "가") + " 물음" }, when].compactMap { $0 }.joined(separator: " · ")
}
