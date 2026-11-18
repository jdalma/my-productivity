import Foundation
import os
import Testing
import TowerCore
@testable import TowerApp

// T177: the dashboard's rules and its one stateful object. How the page looks is in DashboardRenderTests.

private typealias S = DashboardSamples

/// A defaults domain of the test's own, removed after.
private final class TestDefaults {
    let name = "dashboard-tests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() { defaults = UserDefaults(suiteName: name)! }
    deinit { UserDefaults().removePersistentDomain(forName: name) }
}

/// A transcript reading that waits until the test lets it end, counting how often it was started.
private actor ReadGate {
    private(set) var calls = 0
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        calls += 1
        guard !open else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        open = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

@Test func refreshIntervalIsAMinuteForTodayAndFiveForLongerPeriods() {
    #expect(usageRefreshInterval(.today) == 60)
    #expect(usageRefreshInterval(.week) == 300)
    #expect(usageRefreshInterval(.month) == 300)
}

@Test func aRefreshIsDueWithoutOneOrOnceTheIntervalHasPassed() {
    let now = S.now
    #expect(usageRefreshDue(period: .week, last: nil, now: now))
    #expect(!usageRefreshDue(period: .today, last: now.addingTimeInterval(-59), now: now))
    #expect(usageRefreshDue(period: .today, last: now.addingTimeInterval(-60), now: now))
    #expect(!usageRefreshDue(period: .week, last: now.addingTimeInterval(-299), now: now))
    #expect(usageRefreshDue(period: .month, last: now.addingTimeInterval(-300), now: now))
}

@Test func twoColumnsFrom880PointsTimesTheTextScale() {
    #expect(dashboardColumns(width: 880, scale: 1) == 2)
    #expect(dashboardColumns(width: 879, scale: 1) == 1)
    #expect(dashboardColumns(width: 1560, scale: 1.7) == 2)
    #expect(dashboardColumns(width: 1560, scale: 2) == 1)
    #expect(dashboardColumns(width: 840, scale: 0.9) == 2)
}

@Test func periodNamesAndPickerLabels() {
    #expect(UsagePeriod.allCases.map(periodName) == ["오늘", "지난 7일", "지난 30일"])
    #expect(UsagePeriod.allCases.map(periodLabel) == ["오늘", "7일", "30일"])
    #expect(UsagePeriod.allCases.map(insightsTitle) == ["오늘 눈에 띄는 것", "이번 7일에 눈에 띄는 것", "이번 30일에 눈에 띄는 것"])
}

@Test func phaseIsReadingUntilTheFirstReadingEndsAndNoneOnlyWithoutAnyRecord() {
    #expect(dashboardPhase(S.reading, hasRecords: false) == .reading(UsageProgress(filesTotal: 412, filesRead: 180)))
    #expect(dashboardPhase(S.none, hasRecords: false) == .noRecords)
    #expect(dashboardPhase(S.emptyPeriod, hasRecords: true) == .shown, "responses earlier in the month: the page, with empty groups")
    #expect(dashboardPhase(S.week, hasRecords: true) == .shown)
}

@Test func phaseIsReadingAfterARestartThoughNoFileIsLeftToRead() {
    // right after a launch the kept values answer with 0 of 0 files: done by the count, not read to the end (R12 S3)
    var kept = S.week
    kept.computedAt = nil
    kept.progress = UsageProgress()
    #expect(kept.progress.done)
    #expect(dashboardPhase(kept, hasRecords: true) == .reading(UsageProgress()))
}

@Test func aProjectWithoutAFolderIsNamedAndOpensNothing() {
    let report = S.report(.week, buckets: [], usual: nil, totals: UsageTokens(output: 110_000, responses: 300), activeDays: 3,
                          projects: [S.rank("", 99_000), S.rank("/Users/me/work/notes-app", 11_000)])
    let rows = usageRankRows(report.projects, total: 110_000, by: .projects)
    #expect(rows.map(\.label) == ["폴더 없음", "notes-app"])
    #expect(breakdownConclusion(report, by: .projects) == "프로젝트 2개 · 가장 큰 곳 폴더 없음 90%")
    #expect(rankSearchText("", rows: rows, by: .projects) == nil, "no folder name to search for")
    #expect(rankSearchText("/Users/me/work/notes-app", rows: rows, by: .projects) == "notes-app")
    #expect(rankSearchText("/Users/me/work/notes-app", rows: rows, by: .models) == nil)
    #expect(rankSearchText(nil, rows: rows, by: .projects) == nil)
}

@Test func comparisonAndLegendWordsAtTheEdges() {
    var same = S.week
    same.baseline.output = same.totals.output
    #expect(usageComparisonText(same) == "· 이전 4주의 주 평균과 비슷함", "not '0% 적음'")
    #expect(sharePercentText(0.996) == "99%")
    #expect(!rewrittenLegendText.contains("1시간 넘게"))
}

@Test func subtitleNamesThePeriodAndItsOutputOrThatItIsReading() {
    #expect(dashboardSubtitle(S.week) == "지난 7일 · 출력 12.4M 토큰")
    #expect(dashboardSubtitle(S.emptyPeriod) == "오늘 · 출력 0 토큰")
    #expect(dashboardSubtitle(S.reading) == "지난 7일 · 집계 중")
}

@Test func readTimeIsOnA24HourClock() {
    #expect(dashboardTimeText(S.now, locale: Locale(identifier: "ko_KR")) == "16:42")
}

@Test func aUsageSessionOpensItsLiveRowFirstThenItsHistoryLine() {
    let live = Session(handle: "pid:1", agent: .claude, pid: 1, cwd: "/sample/notes-app", startedAt: nil, status: .wait, myTurn: false,
                       since: nil, permissionPrompt: false, title: "", tmux: nil, transcript: "/sample/a.jsonl",
                       lastUser: "", lastAssistant: "", termProgram: nil)
    let model = sidebarModel(board: Board(at: "2026-11-17T07:42:00.000Z", teams: [], loose: [live]), history: [], query: "",
                             filter: .claude, historyLimit: historyPageSize, home: "/sample")
    func past(_ path: String) -> HistorySession {
        HistorySession(id: "id", agent: .claude, title: "t", workspace: "/sample/blog", branch: nil, createdAt: nil,
                       updatedAt: "2026-11-17T07:00:00.000Z", lastPrompt: nil, transcriptPath: path, live: false, resumeCommand: [])
    }
    let history = [past("/sample/a.jsonl"), past("/sample/b.jsonl")]
    #expect(usageSessionTarget("/sample/a.jsonl", model: model, history: history) == model.liveRows[0].id)
    #expect(usageSessionTarget("/sample/b.jsonl", model: model, history: history) == .history("/sample/b.jsonl"))
    #expect(usageSessionTarget("/sample/gone.jsonl", model: model, history: history) == nil)
}

@MainActor @Test func thePeriodIsRestoredFromTheDefaultsAndAChangeAnswersAtOnce() {
    let store = TestDefaults()
    store.defaults.set("month", forKey: UsageDashboard.periodKey)
    let usage = UsageDashboard(defaults: store.defaults, read: {}, answer: { p in var r = S.week; r.period = p; return r })
    #expect(usage.period == .month)
    #expect(usage.report.period == .month)
    usage.period = .today
    #expect(usage.report.period == .today, "answered without a reading")
    #expect(store.defaults.string(forKey: UsageDashboard.periodKey) == "today")
    #expect(UsageDashboard(defaults: TestDefaults().defaults, read: {}, answer: { _ in S.week }).period == .week, "nothing stored")
}

@MainActor @Test func thereAreRecordsWhenThePeriodOrTheLast30DaysHoldAResponse() {
    let store = TestDefaults()
    store.defaults.set("today", forKey: UsageDashboard.periodKey)
    // transcripts without usage in them count for nothing: the files are there, the responses are not
    var read = S.none
    read.progress = UsageProgress(filesTotal: 9, filesRead: 9)
    let unused = read
    #expect(!UsageDashboard(defaults: store.defaults, read: {}, answer: { _ in unused }).hasRecords)
    let usage = UsageDashboard(defaults: store.defaults, read: {}, answer: { $0 == .month ? S.month : S.emptyPeriod })
    #expect(usage.hasRecords, "nothing today, responses earlier in the month")
    usage.period = .month
    #expect(usage.hasRecords)
}

@MainActor @Test func aRefreshKeepsTheOldReportUntilItsReadingEndsAndASecondCallDoesNotReadAgain() async {
    let store = TestDefaults()
    let gate = ReadGate()
    let version = OSAllocatedUnfairLock(initialState: 1)
    let usage = UsageDashboard(defaults: store.defaults, read: { await gate.enter() },
                               answer: { _ in var r = S.week; r.totals.output = version.withLock { $0 }; return r })
    let first = Task { await usage.refresh() }
    while await gate.calls == 0 { await Task.yield() }
    version.withLock { $0 = 2 }
    #expect(usage.refreshing)
    await usage.refresh()
    #expect(await gate.calls == 1, "a second call during a reading does not read")
    #expect(usage.report.totals.output == 1, "the old values stay while the reading runs")
    await gate.release()
    await first.value
    #expect(usage.report.totals.output == 2)
    #expect(!usage.refreshing)
    #expect(usage.lastRefresh != nil)
}

@Test func axisTopIsTheNextOneTwoOrFiveTimesAPowerOfTen() {
    #expect(usageAxisTop(0) == 1000)
    #expect(usageAxisTop(1) == 1)
    #expect(usageAxisTop(3) == 5)
    #expect(usageAxisTop(1_000_000) == 1_000_000)
    #expect(usageAxisTop(1_000_001) == 2_000_000)
    #expect(usageAxisTop(2_700_000) == 5_000_000)
    #expect(usageAxisTop(5_000_001) == 10_000_000)
}

@Test func axisLabelsAreThinnedSoEachHas34PointsTimesTheScale() {
    #expect(axisLabelStride(count: 7, width: 800, scale: 2) == 1)
    #expect(axisLabelStride(count: 30, width: 1500, scale: 1) == 1)
    #expect(axisLabelStride(count: 30, width: 1500, scale: 2) == 2)
    #expect(axisLabelStride(count: 30, width: 360, scale: 2) == 6)
    #expect(axisLabelStride(count: 0, width: 360, scale: 1) == 1)
}

@Test func usageGroupWordsAreFunctionsOfTheReport() {
    #expect(usageTotalText(S.week) == "출력 12.4M 토큰")
    #expect(usageComparisonText(S.week) == "· 이전 4주의 주 평균보다 19% 많음")
    #expect(usageComparisonText(S.sparse) == nil, "no baseline: no comparison and no words about it")
    #expect(usageLegendText(S.week) == "막대: 출력 토큰 · 점선: 평소(이전 4주의 주 평균) · 흐린 막대: 진행 중")
    #expect(usageLegendText(S.sparse) == "막대: 출력 토큰 · 흐린 막대: 진행 중")
    #expect(usageNumbersText(S.week) == "응답 11,234 · cache 읽기 3.5B · cache 생성 79.1M · 입력 86K")
    #expect(usageTotalText(S.emptyPeriod) == "출력 0 토큰")
}

private func ranks(_ outputs: [Int]) -> [UsageRank] {
    outputs.enumerated().map { UsageRank(name: "p\($0.offset)", tokens: UsageTokens(output: $0.element)) }
}

@Test func rankRowsAreTheTopFiveThenTheRestSummedIntoOne() {
    let rows = usageRankRows(ranks([40, 20, 10, 10, 5, 5, 5, 5]), total: 100, by: .models)
    #expect(rows.map(\.name) == ["p0", "p1", "p2", "p3", "p4", "그 외 3개"])
    #expect(rows.last == RankRow(name: "그 외 3개", label: "그 외 3개", output: 15, share: 0.15, isRest: true))
    #expect(rows[0].share == 0.4)
    #expect(!rows[0].isRest)
    #expect(usageRankRows(ranks([1, 1, 1, 1, 1]), total: 5, by: .models).map(\.isRest) == [false, false, false, false, false], "exactly 5: no rest line")
    #expect(usageRankRows(ranks([3, 1]), total: 4, by: .models).map(\.name) == ["p0", "p1"])
    #expect(usageRankRows(ranks([3]), total: 0, by: .models)[0].share == 0, "no output: no division by zero")
    let project = usageRankRows([UsageRank(name: "/Users/me/work/notes-app", tokens: UsageTokens(output: 3))], total: 3, by: .projects)[0]
    #expect((project.name, project.label) == ("/Users/me/work/notes-app", "notes-app"), "a project line shows its folder, keeps its path")
}

@Test func breakdownConclusionNamesTheCountAndTheLargest() {
    #expect(breakdownConclusion(S.week, by: .projects) == "프로젝트 8개 · 가장 큰 곳 notes-app 40%")
    #expect(breakdownConclusion(S.week, by: .models) == "모델 3개 · 가장 큰 곳 model-a 81%")
    #expect(breakdownConclusion(S.emptyPeriod, by: .projects) == "이 기간에 기록 없음")
}

@Test func leakSessionsAreRewrittenOrRepeatedlyCompactedLargestRewriteFirstAtMostFive() {
    func s(_ n: Int, rewritten: Int, compactions: Int) -> UsageSession {
        S.session(n, project: "blog", output: 1, rewritten: rewritten, compactions: compactions)
    }
    var r = S.week
    r.sessions = [s(1, rewritten: 0, compactions: 2), s(2, rewritten: 5, compactions: 0), s(3, rewritten: 0, compactions: 11),
                  s(4, rewritten: 9, compactions: 1), s(5, rewritten: 5, compactions: 4), s(6, rewritten: 1, compactions: 0),
                  s(7, rewritten: 0, compactions: 3), s(8, rewritten: 0, compactions: 0)]
    #expect(leakSessions(r).map { ($0.transcriptPath as NSString).lastPathComponent } == ["s4.jsonl", "s5.jsonl", "s2.jsonl", "s6.jsonl", "s3.jsonl"])
    r.sessions = [s(1, rewritten: 0, compactions: 2)]
    #expect(leakSessions(r).isEmpty, "compacted twice and nothing rewritten is not a leak")
}

@Test func leakWordsStateFactsOnly() {
    #expect(rewrittenSummaryText(S.week) == "32.4M · cache 생성의 41% · 세션 12개")
    #expect(rewrittenPieces(S.week) == (46_700_000, 32_400_000))
    #expect(rewrittenSummaryText(S.emptyPeriod) == nil)
    #expect(compactionSummaryText(S.week) == "3번 이상 5개 · 최대 11번")
    #expect(compactionSummaryText(S.sparse) == "3번 이상 일어난 세션 없음")
    #expect(leakSessionFacts(S.session(1, project: "blog", output: 1, rewritten: 12_300_000, compactions: 4)) == ["다시 쓴 cache 12.3M", "압축 4번"])
    #expect(leakSessionFacts(S.session(1, project: "blog", output: 1, rewritten: 0, compactions: 11)) == ["압축 11번"])
}

@Test func barsAreNamedInWordsNeverAsSlashedDates() {
    let monday = S.day(-1)
    #expect(bucketName(monday, period: .week) == "11월 16일 월요일")
    #expect(bucketName(S.hour(14), period: .today) == "14시")
    #expect(bucketAxisLabel(monday, period: .week) == "월")
    #expect(bucketAxisLabel(monday, period: .month) == "16")
    #expect(bucketAxisLabel(S.hour(6), period: .today) == "6")
    #expect(bucketHoverText(UsageBucket(start: monday, output: 1_900_000), period: .week) == "11월 16일 월요일 · 출력 1.9M")
}

@Test func rankLinesTellProjectsWithTheSameFolderNameApart() {
    let report = S.report(.week, buckets: [], usual: nil, totals: UsageTokens(output: 100_000, responses: 300), activeDays: 3,
                          projects: [S.rank("/Users/me/a/app", 60_000), S.rank("/Users/me/b/app", 30_000), S.rank("/Users/me/notes-app", 10_000)])
    let rows = usageRankRows(report.projects, total: 100_000, by: .projects)
    #expect(rows.map(\.label) == ["a/app", "b/app", "notes-app"])
    #expect(breakdownConclusion(report, by: .projects) == "프로젝트 3개 · 가장 큰 곳 a/app 60%")
    #expect(rankSearchText("/Users/me/a/app", rows: rows, by: .projects) == "a/app", "the search finds that folder, not both")
}

@Test func theRootFolderAndNoFolderOpenNothingAndSayWhatTheyAre() {
    let rows = usageRankRows([S.rank("/", 60_000), S.rank("", 30_000), S.rank("/Users/me/notes-app", 10_000)], total: 100_000, by: .projects)
    #expect(rows.map(\.label) == ["/", "폴더 없음", "notes-app"])
    #expect(rankSearchText("/", rows: rows, by: .projects) == nil, "a search for / finds every session")
    #expect(rankSearchText("", rows: rows, by: .projects) == nil)
    #expect(rows.map(rankTooltip) == ["/", "작업 폴더가 기록되지 않은 세션", "/Users/me/notes-app"])
}
