import Foundation
import Testing
@testable import TowerCore

private func report(
    _ period: UsagePeriod = .week, output: Int = 0, responses: Int = 0, cacheCreation: Int = 0, activeDays: Int = 7,
    baseline: Int? = nil, basis: UsageBaseline.Basis = .weeklyAverageLast4Weeks,
    projects: [UsageRank] = [], rewritten: UsageRewrittenCache = UsageRewrittenCache(),
    compactions: [UsageCompactionGroup] = [], sessions: [UsageSession] = []
) -> UsageReport {
    UsageReport(
        period: period, from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 3600), buckets: [],
        totals: UsageTokens(output: output, cacheCreation: cacheCreation, responses: responses), activeDays: activeDays,
        baseline: UsageBaseline(basis: basis, output: baseline, activeDays: 2, requiredDays: 14, buckets: []),
        projects: projects, models: [], kinds: [], rewrittenCache: rewritten, compactions: compactions, sessions: sessions,
        computedAt: nil, progress: UsageProgress())
}

private func rank(_ name: String, output: Int) -> UsageRank { UsageRank(name: name, tokens: UsageTokens(output: output)) }

private func session(output: Int, compactions: Int) -> UsageSession {
    UsageSession(transcriptPath: "/t/\(output).jsonl", project: "notes-app", lastActive: Date(timeIntervalSince1970: 0),
                 output: output, rewrittenCache: 0, compactions: compactions)
}

private func concentrated(share: Int, name: String = "notes-app", responses: Int = 200, others: Int = 1) -> UsageReport {
    report(output: 1000, responses: responses, projects: [rank(name, output: share * 10)] + (0..<others).map { rank("cli-tools\($0)", output: 1) })
}

@Test func unusualSentenceNamesTheBasisAndBothNumbers() {
    let r = report(output: 14_400_000, baseline: 10_400_000)
    #expect(usageInsights(r).first?.text == "출력 토큰이 이전 4주의 주 평균보다 38% 많습니다. 14.4M, 평소 10.4M.")
    #expect(usageInsights(r).first?.section == .usage)
    #expect(usageInsights(r).first?.weight == 4_000_000)
}

@Test func unusualFiresAtExactlyThirtyPercentAndNotBelow() {
    #expect(usageInsights(report(output: 13_000, baseline: 10_000)).map(\.rule) == [.unusual])
    #expect(usageInsights(report(output: 12_940, baseline: 10_000)).isEmpty)
    #expect(usageInsights(report(output: 12_996, baseline: 10_000)).first?.text == "출력 토큰이 이전 4주의 주 평균보다 30% 많습니다. 13K, 평소 10K.",
            "29.96% is shown as 30%, so it is decided as 30%: the sentence and the 사용량 group agree")
}

@Test func comparisonWordsHaveNoZeroPercentAndNoFiveDigitPercent() {
    #expect(usageComparisonText(report(output: 10_000, baseline: 10_000), sentence: false) == "이전 4주의 주 평균과 비슷함")
    #expect(usageComparisonText(report(output: 9_960, baseline: 10_000), sentence: false) == "이전 4주의 주 평균과 비슷함")
    #expect(usageComparisonText(report(output: 99_000, baseline: 10_000), sentence: false) == "이전 4주의 주 평균보다 890% 많음")
    #expect(usageComparisonText(report(output: 1_000_000, baseline: 6_000), sentence: false) == "이전 4주의 주 평균의 167배")
    #expect(usageInsights(report(output: 1_000_000, baseline: 6_000)).first?.text == "출력 토큰이 이전 4주의 주 평균의 167배입니다. 1M, 평소 6K.")
    #expect(usageComparisonText(report(output: 5_000, baseline: nil), sentence: false) == nil)
}

@Test func aShareThatIsNotTheWholeNeverReads100Percent() {
    #expect(usageSharePercent(0.996) == 99)
    #expect(usageSharePercent(1) == 100)
    #expect(usageSharePercent(0.624) == 62)
    let r = report(output: 100_000, responses: 200, projects: [rank("notes-app", output: 99_600), rank("cli-tools", output: 400)])
    #expect(usageInsights(r).first?.text == "출력 토큰의 99%가 한 프로젝트(notes-app)에서 나왔습니다.")
}

@Test func aProjectWithoutAFolderIsNamedSo() {
    #expect(usageProjectName("") == "폴더 없음")
    #expect(usageInsights(concentrated(share: 90, name: "")).first?.text == "출력 토큰의 90%가 한 프로젝트(폴더 없음)에서 나왔습니다.")
}

@Test func unusualSaysFewerWhenBelowTheBaseline() {
    let r = report(output: 6_000, baseline: 10_000)
    #expect(usageInsights(r).first?.text == "출력 토큰이 이전 4주의 주 평균보다 40% 적습니다. 6K, 평소 10K.")
}

@Test func unusualNeedsABaselineAndThreeActiveDaysOnAWeek() {
    #expect(usageInsights(report(output: 14_000, baseline: nil)).isEmpty)
    #expect(usageInsights(report(output: 14_000, baseline: 0)).isEmpty)
    #expect(usageInsights(report(output: 14_000, activeDays: 2, baseline: 10_000)).isEmpty)
    #expect(usageInsights(report(output: 14_000, activeDays: 3, baseline: 10_000)).count == 1)
}

@Test func unusualOnAMonthAlsoNeedsThreeActiveDays() {
    #expect(usageInsights(report(.month, output: 14_000, activeDays: 2, baseline: 10_000, basis: .previous30Days)).isEmpty)
    #expect(usageInsights(report(.month, output: 14_000, activeDays: 3, baseline: 10_000, basis: .previous30Days)).first?.text
        == "출력 토큰이 그 앞 30일보다 40% 많습니다. 14K, 평소 10K.")
}

@Test func unusualOnTodayFiresWithOneActiveDay() {
    let r = report(.today, output: 14_000, responses: 20, activeDays: 1, baseline: 10_000, basis: .sameTimeLast7Days)
    #expect(usageInsights(r).first?.text == "출력 토큰이 지난 7일의 같은 시각까지 평균보다 40% 많습니다. 14K, 평소 10K.")
}

@Test func concentratedSentenceNamesTheProject() {
    let r = concentrated(share: 62)
    #expect(usageInsights(r).first?.text == "출력 토큰의 62%가 한 프로젝트(notes-app)에서 나왔습니다.")
    #expect(usageInsights(r).first?.section == .breakdown)
    #expect(usageInsights(r).first?.weight == 620)
}

@Test func aProjectIsNamedByTheLastFolderOfItsPath() {
    #expect(usageProjectName("/Users/me/work/notes-app") == "notes-app")
    #expect(usageProjectName("notes-app") == "notes-app")
    #expect(usageInsights(concentrated(share: 62, name: "/Users/me/work/notes-app")).first?.text
        == "출력 토큰의 62%가 한 프로젝트(notes-app)에서 나왔습니다.")
}

@Test func concentratedFiresAtFiftyPercentAndStaysSilentBelow() {
    #expect(usageInsights(concentrated(share: 50)).map(\.rule) == [.concentrated])
    #expect(usageInsights(concentrated(share: 49)).isEmpty)
}

@Test func concentratedNeeds200ResponsesAndTwoProjects() {
    #expect(usageInsights(concentrated(share: 62, responses: 199)).isEmpty)
    #expect(usageInsights(concentrated(share: 62, others: 0)).isEmpty)
}

@Test func aTinyChangeThatKeepsTheRoundedPercentKeepsTheText() {
    let a = report(output: 1_000_000, responses: 200, projects: [rank("notes-app", output: 623_000), rank("cli-tools", output: 1)])
    let b = report(output: 1_000_000, responses: 200, projects: [rank("notes-app", output: 624_000), rank("cli-tools", output: 1)])
    #expect(usageInsights(a).first?.text == usageInsights(b).first?.text)
}

private func rewritten(tokens: Int, responses: Int = 20) -> UsageReport {
    report(cacheCreation: 100, rewritten: UsageRewrittenCache(tokens: tokens, responses: responses, sessions: 12))
}

@Test func rewrittenCacheSentenceGivesShareTokensAndSessions() {
    let r = report(cacheCreation: 78_000_000, rewritten: UsageRewrittenCache(tokens: 32_000_000, responses: 20, sessions: 12))
    // no "1시간": a response whose cache is kept 5 minutes is counted after a 5-minute pause (R12 S1)
    #expect(usageInsights(r).first?.text == "cache 생성의 41%가 cache 유지 시간을 넘겨 쉰 뒤 이어 쓴 세션에서 나왔습니다. 32M, 세션 12개.")
    #expect(usageInsights(r).first?.section == .leaks)
    #expect(usageInsights(r).first?.weight == 32_000_000)
}

@Test func rewrittenCacheFiresAtThirtyPercentAndStaysSilentBelow() {
    #expect(usageInsights(rewritten(tokens: 30)).map(\.rule) == [.rewrittenCache])
    #expect(usageInsights(rewritten(tokens: 29)).isEmpty)
}

@Test func rewrittenCacheNeeds20Responses() {
    #expect(usageInsights(rewritten(tokens: 60, responses: 19)).isEmpty)
}

@Test func compactionsSentenceCountsSessionsAndNamesTheMost() {
    let r = report(compactions: [.init(compactions: 1, sessions: 9), .init(compactions: 3, sessions: 4), .init(compactions: 11, sessions: 1)],
                   sessions: [session(output: 500, compactions: 11), session(output: 300, compactions: 3), session(output: 90, compactions: 1)])
    let found = usageInsights(r).first
    #expect(found?.text == "압축이 3번 이상 일어난 세션이 5개입니다. 가장 많은 세션은 11번.")
    #expect(found?.section == .leaks)
    #expect(found?.weight == 800)
}

@Test func compactionsStaySilentForOneSessionOrFewerThanThreeCompactions() {
    #expect(usageInsights(report(compactions: [.init(compactions: 4, sessions: 1)])).isEmpty)
    #expect(usageInsights(report(compactions: [.init(compactions: 2, sessions: 8)])).isEmpty)
}

@Test func fourFiringRulesReturnThreeLargestWeightFirst() {
    let r = report(
        output: 14_000, responses: 200, cacheCreation: 100, baseline: 10_000,
        projects: [rank("notes-app", output: 9_000), rank("cli-tools", output: 1)],
        rewritten: UsageRewrittenCache(tokens: 50, responses: 20, sessions: 2),
        compactions: [.init(compactions: 3, sessions: 2)],
        sessions: [session(output: 20_000, compactions: 3)])
    // weights: unusual 4000, concentrated 9000 of 14000 output, rewrittenCache 50, compactions 20000
    #expect(usageInsights(r).map(\.rule) == [.compactions, .concentrated, .unusual])
}

@Test func equalWeightsKeepTheRuleOrder() {
    // both weigh 4000: output 8000 against a usual 4000, and a project with 4000 of it
    let tied = report(output: 8_000, responses: 200, baseline: 4_000,
                      projects: [rank("notes-app", output: 4_000), rank("cli-tools", output: 1)])
    #expect(usageInsights(tied).map(\.rule) == [.unusual, .concentrated])
}

@Test func fallbackExplainsMissingHistoryOrSaysNothingStandsOut() {
    #expect(usageInsightNote(report(baseline: nil), sentences: 0) == "평소와 비교하려면 활동한 날이 14일 필요하고 지금 2일입니다.")
    #expect(usageInsightNote(report(baseline: nil), sentences: 2) == "평소와 비교하려면 활동한 날이 14일 필요하고 지금 2일입니다.",
            "sentences about other things do not say why there is no comparison")
    #expect(usageInsightNote(report(baseline: 10_000), sentences: 0) == "이번 기간에 평소와 크게 다른 점이 없습니다.")
    #expect(usageInsightNote(report(baseline: 10_000), sentences: 1) == nil)
}

@Test func aMonthWithoutComparisonSaysWhetherTheRecordOrTheActivityIsMissing() {
    func month(covered: Int, active: Int) -> UsageReport {
        var r = report(.month, baseline: nil, basis: .previous30Days)
        r.baseline.coveredDays = covered
        r.baseline.activeDays = active
        r.baseline.requiredDays = 1
        return r
    }
    #expect(usageComparisonNotice(month(covered: 0, active: 0)) == "그 앞 30일의 기록이 없어 평소와 비교하지 않았습니다.")
    #expect(usageComparisonNotice(month(covered: 12, active: 9)) == "그 앞 30일 가운데 기록이 온전한 날이 12일뿐이라 평소와 비교하지 않았습니다.")
    #expect(usageComparisonNotice(month(covered: 30, active: 0)) == "그 앞 30일에 활동한 날이 없어 평소와 비교하지 않았습니다.")
    #expect(usageComparisonNotice(report(.month, baseline: 10_000, basis: .previous30Days)) == nil)
}

@Test func tokenTextShortensToTwoOrThreeDigits() {
    let cases: [(Int, String)] = [
        (0, "0"), (950, "950"), (1_000, "1K"), (12_345, "12.3K"), (99_949, "99.9K"), (100_000, "100K"),
        (1_900_000, "1.9M"), (14_400_000, "14.4M"), (212_000_000, "212M"), (9_152_000_000, "9.2B"),
    ]
    for (n, text) in cases { #expect(usageTokenText(n) == text) }
}

@Test func tokenTextMovesToTheNextUnitWhenRoundingReachesIt() {
    #expect(usageTokenText(99_950) == "100K")
    #expect(usageTokenText(999_950) == "1M")
    #expect(usageTokenText(215_822) == "216K", "100 and over rounds to the whole, it does not cut the decimal off")
    #expect(usageTokenText(999_499) == "999K")
}

@Test func basisAndComparisonAreWords() {
    #expect(usageBasisText(.sameTimeLast7Days) == "지난 7일의 같은 시각까지 평균")
    #expect(usageBasisText(.weeklyAverageLast4Weeks) == "이전 4주의 주 평균")
    #expect(usageBasisText(.previous30Days) == "그 앞 30일")
    #expect(usageComparison(report(output: 14_400_000, baseline: 10_400_000))?.percent == 38)
    #expect(usageComparison(report(output: 14_400_000, baseline: 10_400_000))?.more == true)
    #expect(usageComparison(report(output: 5_000, baseline: 10_000))?.more == false)
    #expect(usageComparison(report(output: 5_000, baseline: nil)) == nil)
    #expect(usageComparison(report(output: 5_000, baseline: 0)) == nil)
}

@Test func almostNothingAgainstTheUsualIsNotCalled100PercentFewer() {
    #expect(usageComparisonText(report(output: 10, baseline: 10_000), sentence: true) == "이전 4주의 주 평균보다 99% 넘게 적습니다")
    #expect(usageComparisonText(report(output: 10, baseline: 10_000), sentence: false) == "이전 4주의 주 평균보다 99% 넘게 적음")
    #expect(usageComparisonText(report(output: 0, baseline: 10_000), sentence: false) == "이전 4주의 주 평균보다 100% 적음", "nothing at all is 100%")
    #expect(usageInsights(report(output: 10, baseline: 10_000)).first?.text == "출력 토큰이 이전 4주의 주 평균보다 99% 넘게 적습니다. 10, 평소 10K.")
}

@Test func unusualOnTodayNeeds20Responses() {
    func today(output: Int, responses: Int) -> UsageReport {
        report(.today, output: output, responses: responses, activeDays: 1, baseline: 10_000, basis: .sameTimeLast7Days)
    }
    #expect(usageInsights(today(output: 10, responses: 3)).isEmpty, "a day barely begun is not a pattern")
    #expect(usageInsights(today(output: 0, responses: 0)).isEmpty)
    #expect(usageInsights(today(output: 14_000, responses: 19)).isEmpty)
    #expect(usageInsights(today(output: 14_000, responses: 20)).map(\.rule) == [.unusual])
}

@Test func shareRulesAreDecidedOnThePercentShown() {
    // 49.5% and 29.5% are shown as 50% and 30% in the groups: the sentences say so too
    let concentrated = report(output: 1000, responses: 200, projects: [rank("notes-app", output: 495), rank("cli-tools", output: 505)])
    #expect(usageInsights(concentrated).first?.text == "출력 토큰의 50%가 한 프로젝트(notes-app)에서 나왔습니다.")
    #expect(usageInsights(report(output: 1000, responses: 200, projects: [rank("notes-app", output: 494), rank("cli-tools", output: 506)])).isEmpty)
    let rewritten = report(cacheCreation: 1000, rewritten: UsageRewrittenCache(tokens: 295, responses: 20, sessions: 3))
    #expect(usageInsights(rewritten).first?.text == "cache 생성의 30%가 cache 유지 시간을 넘겨 쉰 뒤 이어 쓴 세션에서 나왔습니다. 295, 세션 3개.")
    #expect(usageInsights(report(cacheCreation: 1000, rewritten: UsageRewrittenCache(tokens: 294, responses: 20, sessions: 3))).isEmpty)
}

@Test func projectsWithTheSameFolderNameAreToldApartByTheirParents() {
    let all = ["/Users/me/a/app", "/Users/me/b/app", "/Users/me/work/notes-app", "/x/a/app"]
    #expect(usageProjectName("/Users/me/a/app", among: all) == "me/a/app")
    #expect(usageProjectName("/Users/me/b/app", among: all) == "b/app")
    #expect(usageProjectName("/x/a/app", among: all) == "x/a/app")
    #expect(usageProjectName("/Users/me/work/notes-app", among: all) == "notes-app", "no other notes-app: as before")
    #expect(usageProjectName("/Users/me/a/app", among: ["/Users/me/a/app"]) == "app")
    let r = report(output: 1000, responses: 200, projects: [rank("/Users/me/a/app", output: 620), rank("/Users/me/b/app", output: 380)])
    #expect(usageInsights(r).first?.text == "출력 토큰의 62%가 한 프로젝트(a/app)에서 나왔습니다.")
}

@Test func theRootFolderIsNamedAsItIsAndNotAsNoFolder() {
    #expect(usageProjectName("/") == "/")
    #expect(usageProjectName("") == "폴더 없음")
}
