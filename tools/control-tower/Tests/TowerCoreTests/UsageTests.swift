import Foundation
import Testing
@testable import TowerCore

private func at(_ iso: String) -> Date { Date(timeIntervalSince1970: parseISO(iso)! / 1000) }

private func calendar(hoursFromUTC: Int = 0) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(secondsFromGMT: hoursFromUTC * 3600)!
    return c
}

/// One line of a response, as Claude Code writes it: compact JSON, one line per content block.
private func response(_ id: String?, _ time: String, output: Int = 0, input: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0,
                      oneHourCache: Bool = true, model: String = "model-a", cwd: String = "/work/example-project",
                      entrypoint: String = "cli", text: String = "ok") -> String {
    let lifetime = oneHourCache ? #"{"ephemeral_1h_input_tokens":\#(cacheCreation),"ephemeral_5m_input_tokens":0}"#
        : #"{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":\#(cacheCreation)}"#
    return #"{"type":"assistant","timestamp":"\#(time)","cwd":"\#(cwd)","entrypoint":"\#(entrypoint)","message":{"# +
        (id.map { #""id":"\#($0)","# } ?? "") +
        #""model":"\#(model)","content":[{"type":"text","text":"\#(text)"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"# +
        #""cache_read_input_tokens":\#(cacheRead),"cache_creation_input_tokens":\#(cacheCreation),"cache_creation":\#(lifetime)}}}"#
}

private func compaction(_ uuid: String, _ time: String) -> String {
    #"{"type":"system","subtype":"compact_boundary","uuid":"\#(uuid)","timestamp":"\#(time)"}"#
}

private struct Transcripts {
    let dir: String
    var projects: String { "\(dir)/projects" }
    var store: String { "\(dir)/store" }

    init() throws { dir = try myTeamBase() }

    func ledger(repoRoot: @escaping @Sendable (String) -> String? = { _ in nil }) -> UsageLedger {
        UsageLedger(projects: projects, store: store, repoRoot: repoRoot)
    }

    func session(_ name: String) -> String { "\(projects)/-p/\(name).jsonl" }
    func subagent(_ session: String, _ name: String) -> String { "\(projects)/-p/\(session)/subagents/\(name).jsonl" }

    func add(_ path: String, _ lines: [String], created: String? = nil) throws {
        try addRaw(path, lines.map { $0 + "\n" }.joined(), created: created)
    }

    func addRaw(_ path: String, _ text: String, created: String? = nil) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) { try write(path, "") }
        let handle = FileHandle(forWritingAtPath: path)!
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        if let created { try fm.setAttributes([.creationDate: at(created)], ofItemAtPath: path) }
    }
}

private let now = at("2026-03-10T12:30:00Z")

@Test func aResponseOfSeveralLinesCountsOnceWithItsLargestOutput() async throws {
    let t = try Transcripts()
    try t.add(t.session("s1"), [
        response("m1", "2026-03-10T10:00:00Z", output: 5, input: 3, cacheRead: 100, cacheCreation: 10),
        response("m1", "2026-03-10T10:00:01Z", output: 40, input: 3, cacheRead: 100, cacheCreation: 10),
        response("m1", "2026-03-10T10:00:02Z", output: 40, input: 3, cacheRead: 100, cacheCreation: 10),
    ])
    let ledger = t.ledger()
    await ledger.refresh(now: now)
    let report = ledger.report(.today, now: now, calendar: calendar())
    #expect(report.totals == UsageTokens(output: 40, cacheRead: 100, cacheCreation: 10, input: 3, responses: 1))
    #expect(report.computedAt == now)
    #expect(report.progress.done)
}

@Test func aResponseCopiedIntoAResumedSessionsFileCountsOnceInTheOriginal() async throws {
    let t = try Transcripts()
    try t.add(t.session("z-original"), [response("m1", "2026-03-10T09:00:00Z", output: 10)], created: "2026-03-10T09:00:00Z")
    try t.add(t.session("a-resumed"), [
        response("m1", "2026-03-10T09:00:00Z", output: 10),
        response("m2", "2026-03-10T11:00:00Z", output: 7),
    ], created: "2026-03-10T11:00:00Z")
    let ledger = t.ledger()
    await ledger.refresh(now: now)
    let report = ledger.report(.today, now: now, calendar: calendar())
    #expect(report.totals.output == 17)
    #expect(report.totals.responses == 2)
    #expect(report.sessions.map(\.transcriptPath) == [t.session("z-original"), t.session("a-resumed")])
    #expect(report.sessions.map(\.output) == [10, 7])
}

@Test func syntheticResponsesAndLinesWithoutAnIdAreNotCounted() async throws {
    let t = try Transcripts()
    try t.add(t.session("s1"), [
        response("m1", "2026-03-10T10:00:00Z", output: 4),
        response("e1", "2026-03-10T10:01:00Z", output: 50, model: "<synthetic>"),
        response(nil, "2026-03-10T10:02:00Z", output: 60),
        #"{"type":"user","timestamp":"2026-03-10T10:03:00Z","message":{"content":"a line that quotes \"type\":\"assistant\""}}"#,
    ])
    let ledger = t.ledger()
    await ledger.refresh(now: now)
    #expect(ledger.report(.today, now: now, calendar: calendar()).totals == UsageTokens(output: 4, responses: 1))
}

@Test func subagentsAddToTheirSessionAndSdkSessionsAreTheirOwnKind() async throws {
    let t = try Transcripts()
    try t.add(t.session("s1"), [response("m1", "2026-03-10T10:00:00Z", output: 10, cwd: "/work/example-project/.worktrees/x")],
              created: "2026-03-10T10:00:00Z")
    try t.add(t.subagent("s1", "agent-1"), [response("m2", "2026-03-10T10:05:00Z", output: 5, cwd: "/elsewhere")],
              created: "2026-03-10T10:05:00Z")
    try t.add(t.subagent("s1", "workflows/wf_1/agent-2"), [response("m3", "2026-03-10T10:06:00Z", output: 2, cwd: "/elsewhere")],
              created: "2026-03-10T10:06:00Z")
    try t.add(t.session("s2"), [response("m4", "2026-03-10T11:00:00Z", output: 1, cwd: "/work/other", entrypoint: "sdk-cli")],
              created: "2026-03-10T11:00:00Z")
    let ledger = t.ledger()
    await ledger.refresh(now: now)
    let report = ledger.report(.today, now: now, calendar: calendar())
    #expect(report.kinds.map(\.kind) == [.interactive, .subagent, .sdk])
    #expect(report.kinds.map(\.tokens.output) == [10, 7, 1])
    #expect(report.sessions.map(\.transcriptPath) == [t.session("s1"), t.session("s2")])
    #expect(report.sessions.map(\.output) == [17, 1])
    #expect(report.projects.map(\.name) == ["/work/example-project", "/work/other"])
    #expect(report.projects.map(\.tokens.output) == [17, 1])
}

@Test func aDayIsTheUsersDayNotUTCs() async throws {
    let t = try Transcripts()
    try t.add(t.session("s1"), [
        response("m1", "2026-03-09T23:30:00Z", output: 1),
        response("m2", "2026-03-10T00:30:00Z", output: 2),
    ])
    let ledger = t.ledger()
    let noon = at("2026-03-10T12:00:00Z")
    await ledger.refresh(now: noon)

    let utc = ledger.report(.week, now: noon, calendar: calendar())
    #expect(utc.buckets.count == 7)
    #expect(utc.buckets.suffix(2).map(\.output) == [1, 2])
    #expect(utc.activeDays == 2)

    let east = ledger.report(.week, now: noon, calendar: calendar(hoursFromUTC: 9))
    #expect(east.buckets.suffix(2).map(\.output) == [0, 3])
    #expect(east.buckets.last?.start == at("2026-03-09T15:00:00Z"))
    #expect(east.activeDays == 1)

    let today = ledger.report(.today, now: noon, calendar: calendar())
    #expect(today.totals.output == 2)
    #expect(today.buckets.count == 13)
    #expect(today.buckets.first == UsageBucket(start: at("2026-03-10T00:00:00Z"), output: 2))
}

@Test func aRefreshReadsOnlyWhatWasAddedAndALineStillBeingWrittenWaits() async throws {
    let t = try Transcripts()
    let path = t.session("s1")
    let ledger = t.ledger()
    func totals() async -> UsageTokens {
        await ledger.refresh(now: now)
        return ledger.report(.today, now: now, calendar: calendar()).totals
    }

    try t.add(path, [response("m1", "2026-03-10T10:00:00Z", output: 5, cacheRead: 100)])
    #expect(await totals() == UsageTokens(output: 5, cacheRead: 100, responses: 1))

    let second = response("m2", "2026-03-10T10:10:00Z", output: 4, cacheRead: 30)
    let cut = second.index(second.startIndex, offsetBy: second.count / 2)
    try t.add(path, [response("m1", "2026-03-10T10:00:01Z", output: 9, cacheRead: 100)])
    try t.addRaw(path, String(second[..<cut]))
    #expect(await totals() == UsageTokens(output: 9, cacheRead: 100, responses: 1))

    try t.addRaw(path, String(second[cut...]) + "\n")
    #expect(await totals() == UsageTokens(output: 13, cacheRead: 130, responses: 2))
    #expect(await totals() == UsageTokens(output: 13, cacheRead: 130, responses: 2))
}

@Test func aStoredDayOutlivesItsTranscriptAndIsNotCountedAgainFromACopy() async throws {
    let t = try Transcripts()
    try t.add(t.session("s1"), [
        response("m1", "2026-03-08T10:00:00Z", output: 10, cacheCreation: 5),
        compaction("c1", "2026-03-08T10:30:00Z"),
    ])
    let first = t.ledger()
    await first.refresh(now: now)
    try FileManager.default.removeItem(atPath: t.projects)

    let second = t.ledger()
    let stored = second.report(.month, now: now, calendar: calendar())
    #expect(stored.totals == UsageTokens(output: 10, cacheCreation: 5, responses: 1))
    #expect(stored.sessions.map(\.project) == ["/work/example-project"])
    #expect(stored.sessions.map(\.compactions) == [1])

    // a session resumed after the restart: its file starts with a copy of the old records
    try t.add(t.session("s2"), [
        response("m1", "2026-03-08T10:00:00Z", output: 10, cacheCreation: 5),
        compaction("c1", "2026-03-08T10:30:00Z"),
        response("m2", "2026-03-10T12:40:00Z", output: 3),
    ])
    let later = at("2026-03-10T12:50:00Z")
    await second.refresh(now: later)
    let report = second.report(.month, now: later, calendar: calendar())
    #expect(report.totals == UsageTokens(output: 13, cacheCreation: 5, responses: 2))
    #expect(report.compactions == [UsageCompactionGroup(compactions: 1, sessions: 1)])
}

@Test func cacheWrittenAfterAPauseLongerThanItsLifetimeIsRewrittenCache() async throws {
    let t = try Transcripts()
    try t.add(t.session("s1"), [
        response("m1", "2026-03-10T08:00:00Z", cacheCreation: 100),
        response("m2", "2026-03-10T08:59:00Z", cacheCreation: 200),
        response("m3", "2026-03-10T10:00:00Z", cacheCreation: 300),
    ])
    try t.add(t.subagent("s1", "agent-1"), [
        response("a1", "2026-03-10T08:00:00Z", cacheCreation: 10, oneHourCache: false),
        response("a2", "2026-03-10T08:06:00Z", cacheCreation: 20, oneHourCache: false),
        response("a3", "2026-03-10T08:09:00Z", cacheCreation: 40, oneHourCache: false),
    ])
    let ledger = t.ledger()
    await ledger.refresh(now: now)
    let report = ledger.report(.today, now: now, calendar: calendar())
    #expect(report.totals.cacheCreation == 670)
    #expect(report.rewrittenCache == UsageRewrittenCache(tokens: 320, responses: 2, sessions: 1))
    #expect(report.sessions.map(\.rewrittenCache) == [320])
}

@Test func sessionsAreGroupedByHowOftenTheyWereCompacted() async throws {
    let t = try Transcripts()
    try t.add(t.session("a"), [
        response("m1", "2026-03-10T08:00:00Z", output: 3),
        compaction("c1", "2026-03-10T08:10:00Z"), compaction("c2", "2026-03-10T08:20:00Z"), compaction("c3", "2026-03-10T08:30:00Z"),
    ], created: "2026-03-10T08:00:00Z")
    try t.add(t.session("b"), [
        compaction("c1", "2026-03-10T08:10:00Z"),
        response("m2", "2026-03-10T09:00:00Z", output: 2),
        compaction("c4", "2026-03-10T09:10:00Z"),
    ], created: "2026-03-10T09:00:00Z")
    try t.add(t.session("c"), [response("m3", "2026-03-10T09:30:00Z", output: 1), compaction("c5", "2026-03-10T09:40:00Z")],
              created: "2026-03-10T09:30:00Z")
    try t.add(t.session("d"), [response("m4", "2026-03-10T09:50:00Z", output: 1)], created: "2026-03-10T09:50:00Z")
    let ledger = t.ledger()
    await ledger.refresh(now: now)
    let report = ledger.report(.today, now: now, calendar: calendar())
    #expect(report.compactions == [UsageCompactionGroup(compactions: 1, sessions: 2), UsageCompactionGroup(compactions: 3, sessions: 1)])
    #expect(report.sessions.map(\.compactions) == [3, 1, 1, 0])
}

private func daily(_ t: Transcripts, days: [String], _ times: [(String, Int)]) throws {
    try t.add(t.session("history"), days.flatMap { day in
        times.map { time, output in response("\(day)-\(time)", "\(day)T\(time):00Z", output: output) }
    })
}

private func marchDays(_ range: ClosedRange<Int>) -> [String] { range.map { String(format: "2026-03-%02d", $0) } }
private func februaryDays(_ range: ClosedRange<Int>) -> [String] { range.map { String(format: "2026-02-%02d", $0) } }

private let ledgerFirstRead = at("2025-12-01T00:00:00Z")

@Test func todayIsComparedWithTheSameTimeOfTheLastSevenDays() async throws {
    let enough = try Transcripts()
    try daily(enough, days: marchDays(7...9), [("06:00", 100), ("12:00", 60), ("20:00", 1000)])
    let ledger = enough.ledger()
    await ledger.refresh(now: ledgerFirstRead)
    await ledger.refresh(now: now)
    let baseline = ledger.report(.today, now: now, calendar: calendar()).baseline
    #expect(baseline.basis == .sameTimeLast7Days)
    #expect(baseline.output == 130)
    #expect(baseline.activeDays == 3)
    #expect(baseline.requiredDays == 3)
    #expect(baseline.buckets.count == 13)
    #expect(baseline.buckets[6] == UsageBucket(start: at("2026-03-10T06:00:00Z"), output: 100))
    #expect(baseline.buckets[12].output == 60)

    let short = try Transcripts()
    try daily(short, days: marchDays(8...9), [("06:00", 100)])
    let shortLedger = short.ledger()
    await shortLedger.refresh(now: ledgerFirstRead)
    await shortLedger.refresh(now: now)
    let none = shortLedger.report(.today, now: now, calendar: calendar()).baseline
    #expect(none.output == nil)
    #expect(none.activeDays == 2)
    #expect(none.buckets.isEmpty)
}

@Test func aWeekIsComparedWithTheAverageWeekOfTheFourBefore() async throws {
    let enough = try Transcripts()
    try daily(enough, days: februaryDays(4...17), [("09:00", 280)])
    let ledger = enough.ledger()
    await ledger.refresh(now: ledgerFirstRead)
    await ledger.refresh(now: now)
    let report = ledger.report(.week, now: now, calendar: calendar())
    #expect(report.from == at("2026-03-04T00:00:00Z"))
    #expect(report.baseline == UsageBaseline(
        basis: .weeklyAverageLast4Weeks, output: 980, coveredDays: 28, activeDays: 14, requiredDays: 14,
        buckets: report.buckets.map { UsageBucket(start: $0.start, output: 140) }))

    let short = try Transcripts()
    try daily(short, days: februaryDays(4...16) + ["2026-02-03"], [("09:00", 280)])
    let shortLedger = short.ledger()
    await shortLedger.refresh(now: ledgerFirstRead)
    await shortLedger.refresh(now: now)
    let none = shortLedger.report(.week, now: now, calendar: calendar()).baseline
    #expect(none.output == nil)
    #expect(none.activeDays == 13)
    #expect(none.buckets.isEmpty)
}

@Test func thirtyDaysAreComparedWithTheThirtyBefore() async throws {
    let t = try Transcripts()
    try daily(t, days: ["2026-01-09", "2026-01-20", "2026-02-08"], [("09:00", 300)])
    let ledger = t.ledger()
    await ledger.refresh(now: ledgerFirstRead)
    await ledger.refresh(now: now)
    let report = ledger.report(.month, now: now, calendar: calendar())
    #expect(report.from == at("2026-02-09T00:00:00Z"))
    #expect(report.buckets.count == 30)
    #expect(report.totals.output == 0)
    #expect(report.baseline == UsageBaseline(
        basis: .previous30Days, output: 600, coveredDays: 30, activeDays: 2, requiredDays: 1,
        buckets: report.buckets.map { UsageBucket(start: $0.start, output: 20) }))

    let empty = try Transcripts().ledger()
    await empty.refresh(now: ledgerFirstRead)
    await empty.refresh(now: now)
    let none = empty.report(.month, now: now, calendar: calendar()).baseline
    #expect(none.output == nil)
    #expect(none.activeDays == 0)
}

@Test func aComparisonLeavesOutDaysFromBeforeTheLedgerCouldHaveReadThemInFull() async throws {
    let t = try Transcripts()
    try daily(t, days: februaryDays(1...28) + marchDays(1...3), [("09:00", 280)])
    let ledger = t.ledger()
    await ledger.refresh(now: now)
    let week = ledger.report(.week, now: now, calendar: calendar()).baseline
    #expect(week.activeDays == 23)
    #expect([week.spanDays, week.coveredDays] as [Int] == [28, 23])
    #expect(week.output == 1960, "the average week of the 23 days, not 23 days spread over four weeks")

    let month = ledger.report(.month, now: now, calendar: calendar()).baseline
    #expect(month.output == nil, "the 30 days before are not all there")
    #expect(month.activeDays == 0)
    #expect(month.buckets.isEmpty)
}

@Test func aReportWithoutAComparisonOrAReadingSaysNull() throws {
    let report = try Transcripts().ledger().report(.month, now: now, calendar: calendar())
    let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
    #expect(json["computedAt"] is NSNull)
    #expect((json["baseline"] as? [String: Any])?["output"] is NSNull)
    #expect(try JSONDecoder().decode(UsageReport.self, from: JSONEncoder().encode(report)) == report)
}

@Test func aProjectIsTheRepositoryOfTheFolderTheSessionStartedIn() async throws {
    let t = try Transcripts()
    try t.add(t.session("worktree"), [response("m1", "2026-03-10T08:00:00Z", output: 4,
                                                 cwd: "/work/example-project/packages/app/.claude/worktrees/feature-x/src")])
    try t.add(t.session("gone"), [response("m2", "2026-03-10T08:00:00Z", output: 3, cwd: "/gone/folder/.worktrees/w1")])
    let ledger = t.ledger(repoRoot: { $0 == "/work/example-project/packages/app" ? "/work/example-project" : nil })
    await ledger.refresh(now: now)
    #expect(ledger.report(.today, now: now, calendar: calendar()).projects.map(\.name) == ["/work/example-project", "/gone/folder"])

    let repo = try Transcripts()
    try FileManager.default.createDirectory(atPath: "\(repo.dir)/repo/.git", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: "\(repo.dir)/repo/a/b", withIntermediateDirectories: true)
    try repo.add(repo.session("s1"), [response("m3", "2026-03-10T08:00:00Z", output: 1, cwd: "\(repo.dir)/repo/a/b")])
    let onDisk = UsageLedger(projects: repo.projects, store: repo.store)
    await onDisk.refresh(now: now)
    #expect(onDisk.report(.today, now: now, calendar: calendar()).projects.map(\.name) == ["\(repo.dir)/repo"])
}

@Test func theStoreHoldsSumsAndPathsAndNoneOfTheConversation() async throws {
    let t = try Transcripts()
    let marker = "MARKER-OF-A-PROMPT-OR-AN-ANSWER"
    try t.add(t.session("s1"), [
        #"{"type":"user","timestamp":"2026-03-10T09:59:00Z","message":{"content":"\#(marker)"}}"#,
        response("m1", "2026-03-10T10:00:00Z", output: 5, text: marker),
    ])
    let ledger = t.ledger()
    await ledger.refresh(now: now)
    let files = try FileManager.default.contentsOfDirectory(atPath: t.store).sorted()
    #expect(files == ["2026-03-10.json", "state.json"])
    for file in files {
        let text = try String(contentsOfFile: "\(t.store)/\(file)", encoding: .utf8)
        #expect(!text.contains(marker))
        #expect(text.contains(#""version":1"#))
    }
}

// Review R9.

@Test func aResponseWhoseLinesStraddleTheSealedHourCountsOnceAfterARestart() async throws {
    // the first reading is at 12:30, so a restart takes the hours before 11:00 from the store
    let t = try Transcripts()
    try t.add(t.session("s1"), [
        response("m1", "2026-03-10T10:59:59Z", output: 10, cacheRead: 1000),
        response("m1", "2026-03-10T11:00:01Z", output: 40, cacheRead: 1000),
    ])
    await t.ledger().refresh(now: now)

    let restarted = t.ledger()
    let later = at("2026-03-10T12:50:00Z")
    await restarted.refresh(now: later)
    #expect(restarted.report(.today, now: later, calendar: calendar()).totals == UsageTokens(output: 40, cacheRead: 1000, responses: 1))
    #expect(t.ledger().report(.today, now: later, calendar: calendar()).totals == UsageTokens(output: 40, cacheRead: 1000, responses: 1),
            "and what the restart stored says the same")
}

@Test(arguments: [nil, #"{"version":1,"computedAt":1773145800}"#, #"{"version":1,"comp"#])
func storedDaysSurviveAStateFileThatIsGoneOlderOrCut(state: String?) async throws {
    let t = try Transcripts()
    try t.add(t.session("old"), [response("m1", "2026-03-08T10:00:00Z", output: 30)])
    try t.add(t.session("new"), [response("m2", "2026-03-10T12:00:00Z", output: 3)])
    await t.ledger().refresh(now: now)
    try FileManager.default.removeItem(atPath: t.session("old"))
    // a resumed session's copy of the deleted one's records, as on a real disk
    try t.add(t.session("new"), [response("m1", "2026-03-08T10:00:00Z", output: 30)])
    if let state { try write("\(t.store)/state.json", state) } else { try FileManager.default.removeItem(atPath: "\(t.store)/state.json") }

    let restarted = t.ledger()
    #expect(restarted.report(.week, now: now, calendar: calendar()).totals.output == 30, "the stored day, before any reading")
    await restarted.refresh(now: now)
    #expect(restarted.report(.week, now: now, calendar: calendar()).totals.output == 33)
    #expect(t.ledger().report(.week, now: now, calendar: calendar()).totals.output == 30, "and the day file was not replaced")
}

@Test func thirtyDaysAreNotComparedWhenOnlySomeOfTheThirtyBeforeAreThereInFull() async throws {
    // first read on February 20th: in full from January 22nd, 18 of the 30 days before the period
    let t = try Transcripts()
    try daily(t, days: ["2026-01-25", "2026-02-01"], [("09:00", 300)])
    let ledger = t.ledger()
    await ledger.refresh(now: at("2026-02-20T12:30:00Z"))
    await ledger.refresh(now: now)
    let baseline = ledger.report(.month, now: now, calendar: calendar()).baseline
    #expect(baseline.output == nil)
    #expect(baseline.coveredDays == 18)
}

@Test func aPauseOfExactlyTheCachesLifetimeIsNotRewrittenCache() async throws {
    let t = try Transcripts()
    try t.add(t.session("s1"), [
        response("m1", "2026-03-10T08:00:00Z", cacheCreation: 100),
        response("m2", "2026-03-10T09:00:00Z", cacheCreation: 200),
        response("m3", "2026-03-10T10:00:01Z", cacheCreation: 400),
    ])
    let ledger = t.ledger()
    await ledger.refresh(now: now)
    #expect(ledger.report(.today, now: now, calendar: calendar()).rewrittenCache == UsageRewrittenCache(tokens: 400, responses: 1, sessions: 1))
}

/// As the session history does (`claudeFacts`): only a session started as `cli` is interactive.
@Test func onlyACliSessionIsInteractive() async throws {
    let t = try Transcripts()
    try t.add(t.session("typed"), [response("m1", "2026-03-10T10:00:00Z", output: 1)])
    try t.add(t.session("other"), [response("m2", "2026-03-10T10:00:00Z", output: 2, entrypoint: "some-other-client")])
    let ledger = t.ledger()
    await ledger.refresh(now: now)
    #expect(ledger.report(.today, now: now, calendar: calendar()).kinds.map { [$0.kind.rawValue, String($0.tokens.output)] }
            == [["interactive", "1"], ["sdk", "2"]])
}

@Test func aLineWithSpacesAfterItsColonsIsStillAResponse() async throws {
    let t = try Transcripts()
    try t.add(t.session("s1"), [
        #"{"type": "assistant", "timestamp": "2026-03-10T10:00:00Z", "cwd": "/work/example-project", "entrypoint": "cli", "message": {"id": "m1", "model": "model-a", "usage": {"output_tokens": 7}}}"#,
        #"{"type": "system", "subtype": "compact_boundary", "uuid": "c1", "timestamp": "2026-03-10T10:01:00Z"}"#,
    ])
    let ledger = t.ledger()
    await ledger.refresh(now: now)
    let report = ledger.report(.today, now: now, calendar: calendar())
    #expect(report.totals == UsageTokens(output: 7, responses: 1))
    #expect(report.compactions == [UsageCompactionGroup(compactions: 1, sessions: 1)])
}

@Test func aTokenCountThatCannotBeRealCountsAsNothing() async throws {
    let t = try Transcripts()
    try t.add(t.session("s1"), [
        response("m1", "2026-03-10T10:00:00Z", output: -5, input: 3),
        response("m2", "2026-03-10T10:00:01Z", output: Int.max, cacheRead: Int.max),
        response("m3", "2026-03-10T10:00:02Z", output: Int.max),
    ])
    let ledger = t.ledger()
    await ledger.refresh(now: now)
    #expect(ledger.report(.today, now: now, calendar: calendar()).totals == UsageTokens(input: 3, responses: 3))
}

@Test func aSessionOnlyCompactedInThePeriodIsInNeitherTheGroupsNorTheSessions() async throws {
    let t = try Transcripts()
    try t.add(t.session("s1"), [
        response("m1", "2026-03-09T23:00:00Z", output: 1),
        compaction("c1", "2026-03-10T01:00:00Z"),
    ])
    let ledger = t.ledger()
    await ledger.refresh(now: now)
    let report = ledger.report(.today, now: now, calendar: calendar())
    #expect(report.sessions.isEmpty)
    #expect(report.compactions.isEmpty)
}

@Test func aFirstSaveCutShortIsReadAgainWhereItsDaysAreMissing() async throws {
    let t = try Transcripts()
    try t.add(t.session("s1"), [
        response("m1", "2026-03-07T10:00:00Z", output: 100),
        response("m2", "2026-03-08T10:00:00Z", output: 20),
        response("m3", "2026-03-09T10:00:00Z", output: 3),
    ])
    await t.ledger().refresh(now: now)
    try FileManager.default.removeItem(atPath: "\(t.store)/state.json")
    try FileManager.default.removeItem(atPath: "\(t.store)/2026-03-07.json")

    let restarted = t.ledger()
    await restarted.refresh(now: now)
    #expect(restarted.report(.week, now: now, calendar: calendar()).totals == UsageTokens(output: 123, responses: 3))
    #expect(t.ledger().report(.week, now: now, calendar: calendar()).totals.output == 123, "and it is stored now")
}

private func lock(_ path: String) throws { try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path) }
private func unlock(_ path: String, _ mode: Int = 0o644) { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path) }

@Test func aTranscriptThatCannotBeReadIsReportedAndTheRestIsStoredAndKept() async throws {
    let t = try Transcripts()
    try t.add(t.session("open"), [response("m1", "2026-03-08T10:00:00Z", output: 1)])
    try t.add(t.session("locked"), [response("m2", "2026-03-08T11:00:00Z", output: 20)])
    try lock(t.session("locked"))
    defer { unlock(t.session("locked")) }

    let first = t.ledger()
    await first.refresh(now: now)
    let partial = first.report(.week, now: now, calendar: calendar())
    #expect(partial.totals == UsageTokens(output: 1, responses: 1))
    #expect(partial.progress.filesUnreadable == 1)
    #expect(partial.computedAt == now)

    try FileManager.default.removeItem(atPath: t.session("open"))
    for _ in 1...2 {
        let restarted = t.ledger()
        #expect(restarted.report(.week, now: now, calendar: calendar()).totals == UsageTokens(output: 1, responses: 1))
        await restarted.refresh(now: now)
        let report = restarted.report(.week, now: now, calendar: calendar())
        #expect(report.totals == UsageTokens(output: 1, responses: 1))
        #expect(report.computedAt == now)
        #expect(report.progress.filesUnreadable == 1)
    }
}

@Test func aTranscriptReadAndThenUnreadableInTheSameRunIsNotCountedTwiceLater() async throws {
    let t = try Transcripts()
    try t.add(t.session("open"), [response("m0", "2026-03-10T09:00:00Z", output: 1)])
    try t.add(t.session("grows"), [response("m1", "2026-03-10T10:00:00Z", output: 100)])
    let ledger = t.ledger()
    await ledger.refresh(now: now)

    try t.add(t.session("grows"), [response("m2", "2026-03-10T12:35:00Z", output: 20)])
    try lock(t.session("grows"))
    defer { unlock(t.session("grows")) }
    await ledger.refresh(now: at("2026-03-10T12:40:00Z"))
    #expect(ledger.report(.today, now: now, calendar: calendar()).progress.filesUnreadable == 1)

    unlock(t.session("grows"))
    let later = at("2026-03-10T12:50:00Z")
    for _ in 1...3 {
        let restarted = t.ledger()
        await restarted.refresh(now: later)
        let report = restarted.report(.today, now: later, calendar: calendar())
        #expect(report.totals == UsageTokens(output: 121, responses: 3))
        #expect(report.progress.filesUnreadable == 0)
    }
}

@Test func aBaselineMadeWithoutASpanCoversTheWholeSpanOfItsBasis() {
    let month = UsageBaseline(basis: .previous30Days, output: nil, activeDays: 0, requiredDays: 1, buckets: [])
    #expect([month.spanDays, month.coveredDays] as [Int] == [30, 30])
    let week = UsageBaseline(basis: .weeklyAverageLast4Weeks, output: 7, activeDays: 14, requiredDays: 14, buckets: [])
    #expect([week.spanDays, week.coveredDays] as [Int] == [28, 28])
    let today = UsageBaseline(basis: .sameTimeLast7Days, output: 1, coveredDays: 5, activeDays: 3, requiredDays: 3, buckets: [])
    #expect([today.spanDays, today.coveredDays] as [Int] == [7, 5])
}

@Test func aMissingComparisonSaysWhetherTheDaysWereQuietOrNotThere() async throws {
    let quiet = try Transcripts().ledger()
    await quiet.refresh(now: ledgerFirstRead)
    await quiet.refresh(now: now)
    let none = quiet.report(.month, now: now, calendar: calendar()).baseline
    #expect(none.output == nil)
    #expect([none.spanDays, none.coveredDays, none.activeDays] as [Int] == [30, 30, 0])

    let t = try Transcripts()
    try daily(t, days: ["2026-01-25", "2026-02-01"], [("09:00", 300)])
    let short = t.ledger()
    await short.refresh(now: at("2026-02-20T12:30:00Z"))
    await short.refresh(now: now)
    let partial = short.report(.month, now: now, calendar: calendar()).baseline
    #expect(partial.output == nil)
    #expect([partial.spanDays, partial.coveredDays, partial.activeDays] as [Int] == [30, 18, 2])

    let week = short.report(.week, now: now, calendar: calendar()).baseline
    #expect([week.spanDays, week.coveredDays] as [Int] == [28, 28])
    let today = short.report(.today, now: now, calendar: calendar()).baseline
    #expect([today.spanDays, today.coveredDays] as [Int] == [7, 7])
}

// T232: a running worker's cache hit rate, from the ledger's rows only.

@Test func sessionTotalsSumAWholeSessionSplittingItsSubagentsAndReadingNoFile() async throws {
    let t = try Transcripts()
    try t.add(t.session("w1"), [
        response("m1", "2026-03-08T10:00:00Z", input: 10, cacheRead: 0, cacheCreation: 1000),
        response("m2", "2026-03-10T10:00:00Z", input: 5, cacheRead: 9000, cacheCreation: 100),
        compaction("c1", "2026-03-10T10:30:00Z"),
    ], created: "2026-03-08T10:00:00Z")
    try t.add(t.subagent("w1", "agent-1"), [response("m3", "2026-03-10T10:05:00Z", input: 1, cacheRead: 300, cacheCreation: 99)],
              created: "2026-03-10T10:05:00Z")
    try t.add(t.session("other"), [response("m4", "2026-03-10T11:00:00Z", cacheRead: 7)], created: "2026-03-10T11:00:00Z")
    let ledger = t.ledger()
    await ledger.refresh(now: now)
    // a line written after the reading is not counted until the next one: sessionTotals reads no transcript
    try t.add(t.session("w1"), [response("m5", "2026-03-10T12:10:00Z", cacheRead: 1_000_000)])

    let totals = ledger.sessionTotals([t.session("w1"), t.session("gone")])
    #expect(Set(totals.keys) == [t.session("w1")])
    let w1 = try #require(totals[t.session("w1")])
    // both days, whatever period the dashboard shows
    #expect(w1.main == UsageTokens(cacheRead: 9000, cacheCreation: 1100, input: 15, responses: 2))
    #expect(w1.subagent == UsageTokens(cacheRead: 300, cacheCreation: 99, input: 1, responses: 1))
    #expect(w1.compactions == 1)
    #expect(cacheHitRateText(w1.main) == "89.0%")
    #expect(cacheHitRateText(w1.subagent) == "75.0%")
}

@Test func aHitRateHasOneDecimalNeverShowsAHundredShortOfAllAndIsLowOnlyWithEnoughResponses() {
    #expect(cacheHitRate(UsageTokens()) == nil)
    #expect(cacheHitRateText(UsageTokens()) == "—")
    #expect(cacheHitRateText(UsageTokens(cacheRead: 976, cacheCreation: 20, input: 4)) == "97.6%")
    #expect(cacheHitRateText(UsageTokens(cacheRead: 99_999, input: 1)) == "99.9%")
    #expect(cacheHitRateText(UsageTokens(cacheRead: 5)) == "100.0%")
    #expect(cacheHitRateText(UsageTokens(cacheCreation: 5)) == "0.0%")

    let low = UsageTokens(cacheRead: 884, cacheCreation: 116, responses: cacheHitMinResponses)
    #expect(cacheHitIsLow(low))
    #expect(!cacheHitIsLow(UsageTokens(cacheRead: 884, cacheCreation: 116, responses: cacheHitMinResponses - 1)))
    #expect(!cacheHitIsLow(UsageTokens(cacheRead: 900, cacheCreation: 100, responses: 500)))
    #expect(!cacheHitIsLow(UsageTokens(cacheRead: 8996, cacheCreation: 1004, responses: 500)), "89.96% shows as 90.0%: not low")
    #expect(cacheHitIsLow(UsageTokens(cacheRead: 8994, cacheCreation: 1006, responses: 500)), "89.94% shows as 89.9%")
    #expect(!cacheHitIsLow(UsageTokens(responses: 500)))
}

@Test func aWorkersCacheStateTellsCodexAMissingSessionAndNoResponsesYetApart() {
    func worker(_ agent: AgentKind, transcript: String?) -> Worker {
        Worker(session: Session(handle: "pane:t:%1", agent: agent, pid: 1, cwd: "", startedAt: nil, status: .wait, myTurn: false,
                                since: nil, permissionPrompt: false, title: "", tmux: nil, transcript: transcript, lastUser: "",
                                lastAssistant: "", termProgram: nil),
               workerName: "w", role: nil, description: "", paneId: "%1", alive: true, spool: 0, inbox: 0, sentPending: 0,
               oldestPendingAt: nil, stateFile: nil)
    }
    let counted = UsageSessionTotals(main: UsageTokens(cacheRead: 1, responses: 1))
    let totals = ["/p/a.jsonl": counted]
    #expect(workerCacheState(worker(.claude, transcript: "/p/a.jsonl"), totals: totals) == .counted(counted))
    #expect(workerCacheState(worker(.claude, transcript: "/p/b.jsonl"), totals: totals) == .noResponses)
    #expect(workerCacheState(worker(.claude, transcript: nil), totals: totals) == .noSession)
    #expect(workerCacheState(worker(.codex, transcript: "/p/a.jsonl"), totals: totals) == .codex)
}
