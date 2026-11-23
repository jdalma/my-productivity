import Foundation
import Observation
import TowerCore

// The usage dashboard's state and the rules its views follow (T177, T180 §4). No view code, so they are testable.

/// What the dashboard shows for a report.
enum DashboardPhase: Equatable {
    /// The first reading is not finished: the page at its final sizes with its values redacted.
    case reading(UsageProgress)
    /// Read to the end, and no response in the last 30 days either: nothing a period could show.
    case noRecords
    case shown
}

func dashboardPhase(_ report: UsageReport, hasRecords: Bool) -> DashboardPhase {
    guard report.computedAt != nil else { return .reading(report.progress) }
    return hasRecords ? .shown : .noRecords
}

/// A block of the page the insight lines scroll to, and the one kept at the top across a visit to another screen.
enum DashboardBlock: Hashable {
    case insights
    case section(UsageSection)
}

/// The dashboard's one report. Owned by `Tower` so that the report, the period and the scroll position outlive the
/// detail view, which is rebuilt each time the dashboard is selected again.
@MainActor @Observable
final class UsageDashboard {
    static let periodKey = "dashboardPeriod"

    private(set) var report: UsageReport {
        didSet { hasRecords = Self.hasRecords(report, answer) }
    }
    /// A response in the period or in the last 30 days. Transcripts without usage in them are not records.
    private(set) var hasRecords: Bool
    /// A reading is running. The values on screen stay.
    private(set) var refreshing = false
    /// Restored at launch; setting it answers at once from what is read.
    var period: UsagePeriod {
        didSet {
            defaults.set(period.rawValue, forKey: Self.periodKey)
            report = answer(period)
        }
    }
    /// The block at the top of the page.
    var scrolled: DashboardBlock?
    /// The chart's bar under the pointer, by its start, so a refresh keeps it (R4).
    var hoveredBar: Date?
    private(set) var lastRefresh: Date?
    /// The running workers' transcripts the 실행 중인 워커 group shows. A new set is answered at once from what is read.
    var workerTranscripts: Set<String> = [] {
        didSet { if workerTranscripts != oldValue { workerTotals = answerTotals() } }
    }
    /// Each of `workerTranscripts`' whole-session sums, answered again at the end of each reading (T232).
    private(set) var workerTotals: [String: UsageSessionTotals] = [:]

    private let defaults: UserDefaults
    private let read: @Sendable () async -> Void
    private let answer: @Sendable (UsagePeriod) -> UsageReport
    private let totals: @Sendable (Set<String>) -> [String: UsageSessionTotals]

    init(defaults: UserDefaults = .standard,
         read: @escaping @Sendable () async -> Void = { await UsageLedger.shared.refresh() },
         answer: @escaping @Sendable (UsagePeriod) -> UsageReport = { UsageLedger.shared.report($0) },
         totals: @escaping @Sendable (Set<String>) -> [String: UsageSessionTotals] = { UsageLedger.shared.sessionTotals($0) }) {
        self.defaults = defaults
        self.read = read
        self.answer = answer
        self.totals = totals
        let period = defaults.string(forKey: Self.periodKey).flatMap(UsagePeriod.init(rawValue:)) ?? .week
        self.period = period
        let report = answer(period)
        self.report = report
        hasRecords = Self.hasRecords(report, answer)
    }

    private static func hasRecords(_ report: UsageReport, _ answer: (UsagePeriod) -> UsageReport) -> Bool {
        report.totals.responses > 0 || (report.period != .month && answer(.month).totals.responses > 0)
    }

    private func answerTotals() -> [String: UsageSessionTotals] {
        workerTranscripts.isEmpty ? [:] : totals(workerTranscripts)
    }

    /// Reads what is new, then answers again. While a reading runs, a second call does nothing.
    /// During the first reading it answers every 250 ms so the progress shows; later readings keep the old report
    /// until they end, so a refresh never shows a half-read period.
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        let reading = Task.detached(operation: read)
        if report.computedAt == nil {
            let polling = Task { [weak self] in
                while true {
                    try await Task.sleep(for: .milliseconds(250))
                    guard let self else { return }
                    report = answer(period)
                }
            }
            await reading.value
            polling.cancel()
        } else {
            await reading.value
        }
        report = answer(period)
        workerTotals = answerTotals()
        lastRefresh = Date()
        refreshing = false
    }
}

/// How often the dashboard reads again while it is shown: today's bars move by the minute, a week's do not.
func usageRefreshInterval(_ period: UsagePeriod) -> TimeInterval {
    period == .today ? 60 : 300
}

func usageRefreshDue(period: UsagePeriod, last: Date?, now: Date) -> Bool {
    guard let last else { return true }
    return now.timeIntervalSince(last) >= usageRefreshInterval(period)
}

/// Two columns from 880 pt of detail at the standard text size (T180 §2.3).
func dashboardColumns(width: CGFloat, scale: CGFloat) -> Int {
    width >= 880 * scale ? 2 : 1
}

func periodName(_ period: UsagePeriod) -> String {
    switch period {
    case .today: "오늘"
    case .week: "지난 7일"
    case .month: "지난 30일"
    }
}

/// The period picker's segment.
func periodLabel(_ period: UsagePeriod) -> String {
    switch period {
    case .today: "오늘"
    case .week: "7일"
    case .month: "30일"
    }
}

/// The window's subtitle on the dashboard: "지난 7일 · 출력 12.4M 토큰".
func dashboardSubtitle(_ report: UsageReport) -> String {
    if report.computedAt == nil { return "\(periodName(report.period)) · 집계 중" }
    return "\(periodName(report.period)) · 출력 \(usageTokenText(report.totals.output)) 토큰"
}

/// The insight block's title.
func insightsTitle(_ period: UsagePeriod) -> String {
    switch period {
    case .today: "오늘 눈에 띄는 것"
    case .week: "이번 7일에 눈에 띄는 것"
    case .month: "이번 30일에 눈에 띄는 것"
    }
}

/// The top of the usage chart's y axis: the smallest 1, 2 or 5 times a power of ten that holds `max`, so a bar that
/// grows a little does not renumber the axis (T180 R2). Nothing to show still gets a scale.
func usageAxisTop(_ max: Int) -> Int {
    guard max > 0 else { return 1000 }
    var power = 1
    while true {
        for m in [1, 2, 5] where m * power >= max { return m * power }
        power *= 10
    }
}

/// Every n-th x label, so each has at least 34 pt times the text scale and none overlap at 2.0 (T180 §1.4).
func axisLabelStride(count: Int, width: CGFloat, scale: CGFloat) -> Int {
    guard count > 0, width > 0 else { return 1 }
    return max(1, Int((34 * scale / (width / CGFloat(count))).rounded(.up)))
}

/// The usage group's large number: "출력 14.4M 토큰".
func usageTotalText(_ report: UsageReport) -> String {
    "출력 \(usageTokenText(report.totals.output)) 토큰"
}

/// "· 이전 4주의 주 평균보다 38% 많음"; nil without a baseline, so nothing says there is no comparison.
func usageComparisonText(_ report: UsageReport) -> String? {
    TowerCore.usageComparisonText(report, sentence: false).map { "· \($0)" }
}

/// Whether the usual level is drawn: only with a baseline that has bars.
func usageShowsUsual(_ report: UsageReport) -> Bool {
    report.baseline.output != nil && !report.baseline.buckets.isEmpty
}

/// The words under the chart, so neither color nor dash is the only cue.
func usageLegendText(_ report: UsageReport) -> String {
    (["막대: 출력 토큰"] + (usageShowsUsual(report) ? ["점선: 평소(\(usageBasisText(report.baseline.basis)))"] : []) + ["흐린 막대: 진행 중"])
        .joined(separator: " · ")
}

/// The other token kinds as numbers only: they are hundreds of times the output and would flatten a shared chart.
func usageNumbersText(_ report: UsageReport) -> String {
    let t = report.totals
    let responses = t.responses.formatted(.number.locale(Locale(identifier: "ko_KR")))
    return "응답 \(responses) · cache 읽기 \(usageTokenText(t.cacheRead)) · cache 생성 \(usageTokenText(t.cacheCreation)) · 입력 \(usageTokenText(t.input))"
}

/// A bar's x label: the hour for today, the weekday for a week, the day of the month for 30 days.
func bucketAxisLabel(_ start: Date, period: UsagePeriod, calendar: Calendar = .current) -> String {
    switch period {
    case .today: "\(calendar.component(.hour, from: start))"
    case .week: koreanDate(start, "EEEEE", calendar)
    case .month: "\(calendar.component(.day, from: start))"
    }
}

/// A bar's name for the pointer and VoiceOver: "14시", "11월 16일 월요일", never "11/16".
func bucketName(_ start: Date, period: UsagePeriod, calendar: Calendar = .current) -> String {
    period == .today ? "\(calendar.component(.hour, from: start))시" : koreanDate(start, "M월 d일 EEEE", calendar)
}

/// The pointer's value box: "11월 16일 월요일 · 출력 1.9M".
func bucketHoverText(_ bucket: UsageBucket, period: UsagePeriod, calendar: Calendar = .current) -> String {
    "\(bucketName(bucket.start, period: period, calendar: calendar)) · 출력 \(usageTokenText(bucket.output))"
}

private func koreanDate(_ date: Date, _ format: String, _ calendar: Calendar) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ko_KR")
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    f.dateFormat = format
    return f.string(from: date)
}

/// What the 어디에 group ranks by.
enum UsageBreakdown: String, CaseIterable {
    case projects, models

    static let storageKey = "dashboardBreakdown"

    var label: String { self == .projects ? "프로젝트" : "모델" }

    /// A line's words: a project's folder name, told apart from the others of the same name, a model's id as it is.
    func label(of name: String, among ranks: [UsageRank]) -> String {
        self == .projects ? usageProjectName(name, among: ranks.map(\.name)) : name
    }
}

/// A line of the 어디에 group: a project or model, or the ones past the top 5 summed into one.
struct RankRow: Hashable {
    /// What the report calls it: a project's path, a model's id.
    var name: String
    /// What the line shows.
    var label: String
    var output: Int
    /// 0...1 of the period's output.
    var share: Double
    var isRest: Bool
}

/// The top 5, then "그 외 n개" for the rest, so the list never grows past 6 lines however many projects there are.
func usageRankRows(_ ranks: [UsageRank], total: Int, by breakdown: UsageBreakdown) -> [RankRow] {
    func row(_ name: String, _ label: String, _ output: Int, rest: Bool) -> RankRow {
        RankRow(name: name, label: label, output: output, share: total > 0 ? Double(output) / Double(total) : 0, isRest: rest)
    }
    let top = ranks.prefix(5).map { row($0.name, breakdown.label(of: $0.name, among: ranks), $0.tokens.output, rest: false) }
    guard ranks.count > 5 else { return top }
    let rest = ranks.dropFirst(5)
    let name = "그 외 \(rest.count)개"
    return top + [row(name, name, rest.reduce(0) { $0 + $1.tokens.output }, rest: true)]
}

/// What opening a line puts in the sidebar search: the project's folders as its line shows them, which the search
/// finds in a session's working folder. A model line and the rest line open nothing, and neither does a project
/// with no folder to name: none recorded, or "/", which every working folder holds.
func rankSearchText(_ name: String?, rows: [RankRow], by breakdown: UsageBreakdown) -> String? {
    guard breakdown == .projects, let row = rows.first(where: { $0.name == name && !$0.isRest }),
          row.name.contains(where: { $0 != "/" }) else { return nil }
    return row.label
}

/// A ranked line's tooltip: the whole path or model id, or why there is no path.
func rankTooltip(_ row: RankRow) -> String { row.name.isEmpty ? "작업 폴더가 기록되지 않은 세션" : row.name }

func sharePercentText(_ share: Double) -> String { "\(usageSharePercent(share))%" }

/// "프로젝트 10개 · 가장 큰 곳 notes-app 34%".
func breakdownConclusion(_ report: UsageReport, by breakdown: UsageBreakdown) -> String {
    let ranks = breakdown == .projects ? report.projects : report.models
    guard let top = ranks.first, report.totals.output > 0 else { return "이 기간에 기록 없음" }
    let share = Double(top.tokens.output) / Double(report.totals.output)
    return "\(breakdown.label) \(ranks.count)개 · 가장 큰 곳 \(breakdown.label(of: top.name, among: ranks)) \(sharePercentText(share))"
}

/// The sessions behind the 새는 곳 numbers: cache written again after a pause, or compacted repeatedly. Largest
/// rewritten cache first, then most compactions, at most 5.
func leakSessions(_ report: UsageReport) -> [UsageSession] {
    let leaking = report.sessions.filter { $0.rewrittenCache > 0 || $0.compactions >= usageRepeatedCompactions }
    let ordered = leaking.sorted { ($0.rewrittenCache, $0.compactions) > ($1.rewrittenCache, $1.compactions) }
    return Array(ordered.prefix(5))
}

/// "32.4M · cache 생성의 41% · 세션 12개"; nil when the period wrote no cache.
func rewrittenSummaryText(_ report: UsageReport) -> String? {
    let total = report.totals.cacheCreation
    guard total > 0 else { return nil }
    let r = report.rewrittenCache
    return "\(usageTokenText(r.tokens)) · cache 생성의 \(sharePercentText(Double(r.tokens) / Double(total))) · 세션 \(r.sessions)개"
}

/// The orange piece's legend. Not "1시간": a response whose cache is kept 5 minutes counts after a 5-minute pause.
let rewrittenLegendText = "cache 유지 시간(5분 또는 1시간)을 넘겨 쉰 뒤 다시 쓴 것"

/// The bar's two pieces: cache written while a session went on, and written again after a pause.
func rewrittenPieces(_ report: UsageReport) -> (continued: Int, rewritten: Int) {
    let rewritten = report.rewrittenCache.tokens
    return (max(0, report.totals.cacheCreation - rewritten), rewritten)
}

/// "3번 이상 5개 · 최대 11번".
func compactionSummaryText(_ report: UsageReport) -> String {
    let repeated = report.compactions.filter { $0.compactions >= usageRepeatedCompactions }
    guard let most = repeated.map(\.compactions).max() else { return "\(usageRepeatedCompactions)번 이상 일어난 세션 없음" }
    return "\(usageRepeatedCompactions)번 이상 \(repeated.reduce(0) { $0 + $1.sessions })개 · 최대 \(most)번"
}

/// A leak line's numbers, each left out when 0: "다시 쓴 cache 12.3M", "압축 4번".
func leakSessionFacts(_ session: UsageSession) -> [String] {
    (session.rewrittenCache > 0 ? ["다시 쓴 cache \(usageTokenText(session.rewrittenCache))"] : [])
        + (session.compactions > 0 ? ["압축 \(session.compactions)번"] : [])
}

/// The board row a usage session opens: its running row while one reads that transcript, else its history line.
func usageSessionTarget(_ path: String, model: SidebarModel, history: [HistorySession]) -> RowID? {
    if let row = model.liveRows.first(where: { $0.session.transcript == path }) { return row.id }
    return history.contains { $0.transcriptPath == path } ? .history(path) : nil
}

/// "16:42": when the report was read to the end, on a 24-hour clock in the user's locale.
func dashboardTimeText(_ date: Date, locale: Locale = .current) -> String {
    let f = DateFormatter()
    f.locale = locale
    f.setLocalizedDateFormatFromTemplate("HHmm")
    return f.string(from: date)
}

// 실행 중인 워커 (T232, design worker-cache-hit-rate.md): each running worker's prompt cache hit rate.

/// A line of the 실행 중인 워커 group.
struct WorkerCacheLine: Hashable {
    var team: String
    var name: String
    var transcript: String?
    var state: WorkerCacheState
}

struct WorkerCacheTeam: Hashable {
    var name: String
    var lines: [WorkerCacheLine]
}

/// The running workers' transcripts, for `UsageDashboard.workerTranscripts`.
func workerTranscripts(_ teams: [Team]) -> Set<String> {
    Set(teams.flatMap(\.workers).filter { $0.alive && $0.session.agent == .claude }.compactMap(\.session.transcript))
}

/// Teams by name, each with its live workers in roster order; a team without one is left out.
func workerCacheTeams(_ teams: [Team], totals: [String: UsageSessionTotals]) -> [WorkerCacheTeam] {
    teams.sorted { $0.name < $1.name }.compactMap { team in
        let lines = team.workers.filter(\.alive).map {
            WorkerCacheLine(team: team.name, name: $0.workerName, transcript: $0.session.transcript,
                            state: workerCacheState($0, totals: totals))
        }
        return lines.isEmpty ? nil : WorkerCacheTeam(name: team.name, lines: lines)
    }
}

/// Why a line has no numbers; nil when it has them.
func workerCacheReason(_ state: WorkerCacheState) -> String? {
    switch state {
    case .counted: nil
    case .codex: "codex 워커는 Claude 사용 기록이 없어 세지 않습니다."
    case .noSession: "이 워커의 Claude 세션을 찾지 못했습니다. ~/.claude/sessions에 이 pane의 프로세스 기록이 없습니다."
    case .noResponses: "아직 응답이 없습니다. 방금 시작했거나 다음 집계 전입니다."
    }
}

/// The line's cells, every one "—" without numbers.
struct WorkerCacheCells: Equatable {
    var rate: String
    var rateLow: Bool
    /// Too few responses for the rate to mean much: shown secondary.
    var rateFew: Bool
    var cacheRead: String
    var cacheCreation: String
    var input: String
    var responses: String
    var subagent: String
    var subagentLow: Bool
}

func workerCacheCells(_ state: WorkerCacheState) -> WorkerCacheCells {
    guard case .counted(let t) = state else {
        return WorkerCacheCells(rate: "—", rateLow: false, rateFew: false, cacheRead: "—", cacheCreation: "—", input: "—",
                                responses: "—", subagent: "—", subagentLow: false)
    }
    return WorkerCacheCells(
        rate: cacheHitRateText(t.main), rateLow: cacheHitIsLow(t.main), rateFew: t.main.responses < cacheHitMinResponses,
        cacheRead: usageTokenText(t.main.cacheRead), cacheCreation: usageTokenText(t.main.cacheCreation),
        input: usageTokenText(t.main.input), responses: koreanCount(t.main.responses),
        subagent: t.subagent.responses == 0 ? "없음" : cacheHitRateText(t.subagent), subagentLow: cacheHitIsLow(t.subagent))
}

private func koreanCount(_ n: Int) -> String { n.formatted(.number.locale(Locale(identifier: "ko_KR"))) }

private func tokenFacts(_ t: UsageTokens) -> String {
    "cache 읽기 \(usageTokenText(t.cacheRead)) · cache 생성 \(usageTokenText(t.cacheCreation)) · 입력 \(usageTokenText(t.input)) · 응답 \(koreanCount(t.responses))"
}

/// The tooltip of every cell of a line: all seven values, so a narrow grid hides none of them.
func workerCacheTooltip(_ line: WorkerCacheLine) -> String {
    let head = "\(line.name) · \(line.team)"
    guard case .counted(let t) = line.state else { return [head, workerCacheReason(line.state) ?? ""].joined(separator: "\n") }
    let leaks = (t.compactions > 0 ? ["압축 \(t.compactions)회"] : [])
        + (t.rewrittenCache > 0 ? ["쉰 뒤 다시 쓴 cache \(usageTokenText(t.rewrittenCache))"] : [])
    return ([head,
             "히트율 \(cacheHitRateText(t.main)) = cache 읽기 ÷ (입력 + cache 생성 + cache 읽기)",
             tokenFacts(t.main),
             t.subagent.responses == 0 ? "sub-agent: 없음" : "sub-agent: 히트율 \(cacheHitRateText(t.subagent)) · \(tokenFacts(t.subagent))"]
            + (leaks.isEmpty ? [] : [leaks.joined(separator: " · ")])
            + (t.main.responses < cacheHitMinResponses ? ["응답이 적어 첫 cache 생성 비중이 큽니다."] : []))
        .joined(separator: "\n")
}

/// What VoiceOver reads for the line: its one element, the name, carries every value.
func workerCacheAccessibilityLabel(_ line: WorkerCacheLine) -> String {
    guard case .counted = line.state else { return "\(line.name), 집계 안 함, \(workerCacheReason(line.state) ?? "")" }
    let c = workerCacheCells(line.state)
    let subagent = c.subagent == "없음" ? "sub-agent 없음" : "sub-agent 히트율 \(c.subagent)\(c.subagentLow ? " 낮음" : "")"
    return "\(line.name), 히트율 \(c.rate)\(c.rateLow ? " 낮음" : ""), cache 읽기 \(c.cacheRead), cache 생성 \(c.cacheCreation), "
        + "입력 \(c.input), 응답 \(c.responses), \(subagent)"
}
