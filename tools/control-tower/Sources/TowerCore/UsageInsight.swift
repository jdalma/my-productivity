import Foundation

// The dashboard's sentences (T177 item 7, T179 §4). Each rule is a pure function of a report that returns nil
// unless its sample is large enough: a wrong sentence costs the user's trust in the whole dashboard.
// The thresholds are guesses; tune them here.

/// Smallest difference from the usual output, in whole percent, that is worth a sentence.
private let unusualMinPercent = 30
/// Fewest active days of a week or month report before its output is compared with the usual.
private let unusualMinActiveDays = 3
/// Fewest responses today before today's output is compared with the usual: a day barely begun is 100% fewer
/// every morning, and that is not a pattern.
private let unusualMinResponsesToday = 20
/// Fewest responses in the period before a project's share means anything.
private let concentratedMinResponses = 200
private let concentratedMinProjects = 2
/// The shares are whole percents as shown, so a sentence and its group never disagree at 49.6%.
private let concentratedMinPercent = 50
/// Fewest rewritten-cache responses before their share of cache creation means anything.
private let rewrittenCacheMinResponses = 20
private let rewrittenCacheMinPercent = 30
/// A session compacted at least this many times counts as compacted repeatedly, in the sentence and on the page.
public let usageRepeatedCompactions = 3
private let compactionsMinSessions = 2
private let maxInsights = 3

/// The dashboard group a sentence's evidence is in.
public enum UsageSection: String, Sendable, CaseIterable { case usage, breakdown, leaks }

public struct UsageInsight: Hashable, Sendable {
    public enum Rule: String, Sendable { case unusual, concentrated, rewrittenCache, compactions }

    public var rule: Rule
    /// The whole Korean sentence shown.
    public var text: String
    /// The tokens the sentence is about; larger first.
    public var weight: Int
    public var section: UsageSection
}

private let rules: [@Sendable (UsageReport) -> UsageInsight?] = [unusualInsight, concentratedInsight, rewrittenCacheInsight, compactionsInsight]

/// At most 3, largest weight first; ties keep the rule order unusual, concentrated, rewrittenCache, compactions.
public func usageInsights(_ report: UsageReport) -> [UsageInsight] {
    // the sort is stable, so equal weights stay in the rules' order
    Array(rules.compactMap { $0(report) }.sorted { $0.weight > $1.weight }.prefix(maxInsights))
}

/// Why the period is not compared with the usual; nil when it is.
public func usageComparisonNotice(_ report: UsageReport) -> String? {
    let baseline = report.baseline
    guard baseline.output == nil else { return nil }
    guard baseline.basis == .previous30Days else {
        return "평소와 비교하려면 활동한 날이 \(baseline.requiredDays)일 필요하고 지금 \(baseline.activeDays)일입니다."
    }
    // a day the ledger does not have in full is not a day without activity: say which of the two it is
    if baseline.coveredDays == 0 { return "그 앞 30일의 기록이 없어 평소와 비교하지 않았습니다." }
    if baseline.coveredDays < baseline.spanDays {
        return "그 앞 30일 가운데 기록이 온전한 날이 \(baseline.coveredDays)일뿐이라 평소와 비교하지 않았습니다."
    }
    return "그 앞 30일에 활동한 날이 없어 평소와 비교하지 않았습니다."
}

/// The line under the sentences: why there is no comparison, whatever sentences there are (T180 §3.8), or, with a
/// comparison and no sentence, that nothing stands out. nil with a comparison and sentences.
public func usageInsightNote(_ report: UsageReport, sentences: Int) -> String? {
    usageComparisonNotice(report) ?? (sentences == 0 ? "이번 기간에 평소와 크게 다른 점이 없습니다." : nil)
}

/// "950", "12.3K", "14.4M", "212M", "9.2B": under 100 of a unit one decimal with a trailing ".0" dropped, 100 and over none.
public func usageTokenText(_ n: Int) -> String {
    guard n >= 1000 else { return "\(n)" }
    let units: [(suffix: String, size: Double)] = [("K", 1e3), ("M", 1e6), ("B", 1e9)]
    for (i, unit) in units.enumerated() {
        let tenths = (Double(n) / unit.size * 10).rounded()
        if tenths >= 1000 {
            let whole = (Double(n) / unit.size).rounded()
            // 999.95K rounds up to 1000K: show it in the next unit instead
            if whole >= 1000, i < units.count - 1 { continue }
            return "\(Int(whole))\(unit.suffix)"
        }
        let whole = Int(tenths) / 10, fraction = Int(tenths) % 10
        return fraction == 0 ? "\(whole)\(unit.suffix)" : "\(whole).\(fraction)\(unit.suffix)"
    }
    return "\(n)"
}

/// A project as the dashboard names it: the last folder of its path. A report names a project by its repository's
/// path, which is too long for a line and a sentence.
/// Among projects whose last folders are the same it takes as many parent folders as tell it apart: "a/app", "b/app".
public func usageProjectName(_ project: String, among others: [String] = []) -> String {
    // a transcript that never recorded its working folder has no project path
    if project.isEmpty { return "폴더 없음" }
    let folders = project.split(separator: "/")
    // "/" is a folder, and not the same as none
    guard !folders.isEmpty else { return project }
    let rest = others.filter { $0 != project }.map { $0.split(separator: "/") }
    for n in 1...folders.count where !rest.contains(where: { $0.suffix(n) == folders.suffix(n) }) {
        return folders.suffix(n).joined(separator: "/")
    }
    return project
}

/// What a period's output is compared with, as words.
public func usageBasisText(_ basis: UsageBaseline.Basis) -> String {
    switch basis {
    case .sameTimeLast7Days: "지난 7일의 같은 시각까지 평균"
    case .weeklyAverageLast4Weeks: "이전 4주의 주 평균"
    case .previous30Days: "그 앞 30일"
    }
}

/// The comparison with the usual output: nil without a baseline (`baseline.output` nil or 0).
/// percent is the rounded whole-number difference, more = output above the baseline.
public func usageComparison(_ report: UsageReport) -> (percent: Int, more: Bool)? {
    guard let usual = report.baseline.output, usual > 0 else { return nil }
    let ratio = Double(report.totals.output - usual) / Double(usual)
    return (Int((abs(ratio) * 100).rounded()), ratio > 0)
}

/// How the output stands against the usual, in the words every place uses: "이전 4주의 주 평균보다 38% 많습니다", or
/// without `sentence` "… 많음". A rounded 0% is "비슷", ten times and over is "N배": "16567% 많음" says nothing.
public func usageComparisonText(_ report: UsageReport, sentence: Bool) -> String? {
    guard let usual = report.baseline.output, let comparison = usageComparison(report) else { return nil }
    let basis = usageBasisText(report.baseline.basis)
    if comparison.percent == 0 { return "\(basis)과 비슷\(sentence ? "합니다" : "함")" }
    // 100% fewer is nothing at all
    if comparison.percent == 100, !comparison.more, report.totals.output > 0 {
        return "\(basis)보다 99% 넘게 적\(sentence ? "습니다" : "음")"
    }
    let times = Double(report.totals.output) / Double(usual)
    if times >= 10 { return "\(basis)의 \(Int(times.rounded()))배\(sentence ? "입니다" : "")" }
    return "\(basis)보다 \(comparison.percent)% \(comparison.more ? "많" : "적")\(sentence ? "습니다" : "음")"
}

/// A share as a whole percent. A part that is not the whole never reads 100.
public func usageSharePercent(_ share: Double) -> Int {
    let percent = Int((share * 100).rounded())
    return share < 1 ? min(percent, 99) : percent
}

private func unusualInsight(_ report: UsageReport) -> UsageInsight? {
    guard let usual = report.baseline.output, let comparison = usageComparison(report),
          let words = usageComparisonText(report, sentence: true) else { return nil }
    // decided on the percent as shown, so the sentence and the 사용량 group never disagree at 29.96%
    guard comparison.percent >= unusualMinPercent else { return nil }
    if report.period == .today ? report.totals.responses < unusualMinResponsesToday : report.activeDays < unusualMinActiveDays { return nil }
    return UsageInsight(
        rule: .unusual,
        text: "출력 토큰이 \(words). \(usageTokenText(report.totals.output)), 평소 \(usageTokenText(usual)).",
        weight: abs(report.totals.output - usual), section: .usage)
}

private func concentratedInsight(_ report: UsageReport) -> UsageInsight? {
    guard report.totals.responses >= concentratedMinResponses, report.projects.count >= concentratedMinProjects,
          report.totals.output > 0, let top = report.projects.first else { return nil }
    let share = Double(top.tokens.output) / Double(report.totals.output)
    guard usageSharePercent(share) >= concentratedMinPercent else { return nil }
    let name = usageProjectName(top.name, among: report.projects.map(\.name))
    return UsageInsight(
        rule: .concentrated, text: "출력 토큰의 \(usageSharePercent(share))%가 한 프로젝트(\(name))에서 나왔습니다.",
        weight: top.tokens.output, section: .breakdown)
}

private func rewrittenCacheInsight(_ report: UsageReport) -> UsageInsight? {
    let rewritten = report.rewrittenCache
    guard rewritten.responses >= rewrittenCacheMinResponses, report.totals.cacheCreation > 0 else { return nil }
    let share = Double(rewritten.tokens) / Double(report.totals.cacheCreation)
    guard usageSharePercent(share) >= rewrittenCacheMinPercent else { return nil }
    return UsageInsight(
        rule: .rewrittenCache,
        text: "cache 생성의 \(usageSharePercent(share))%가 cache 유지 시간을 넘겨 쉰 뒤 이어 쓴 세션에서 나왔습니다. \(usageTokenText(rewritten.tokens)), 세션 \(rewritten.sessions)개.",
        weight: rewritten.tokens, section: .leaks)
}

private func compactionsInsight(_ report: UsageReport) -> UsageInsight? {
    let repeated = report.compactions.filter { $0.compactions >= usageRepeatedCompactions }
    let count = repeated.reduce(0) { $0 + $1.sessions }
    guard count >= compactionsMinSessions, let most = repeated.map(\.compactions).max() else { return nil }
    let weight = report.sessions.filter { $0.compactions >= usageRepeatedCompactions }.reduce(0) { $0 + $1.output }
    return UsageInsight(
        rule: .compactions, text: "압축이 \(usageRepeatedCompactions)번 이상 일어난 세션이 \(count)개입니다. 가장 많은 세션은 \(most)번.",
        weight: weight, section: .leaks)
}
