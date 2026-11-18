import AppKit
import os
import SwiftUI
import Testing
import TowerCore
@testable import TowerApp

// The dashboard's analysis and advice (T201). The run is always a stand-in: no test starts `claude`.

/// Counts the runs and answers each with what the test set, or holds it until the test lets go.
private final class Runs: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var answer: Result<String, UsageAdviceFailure> = .success("## 분석\n- 가\n\n## 조언\n- 나")
    private var holding = false

    var count: Int { lock.withLock { requests.count } }
    var last: String? { lock.withLock { requests.last } }
    func answer(_ result: Result<String, UsageAdviceFailure>) { lock.withLock { answer = result } }
    func hold() { lock.withLock { holding = true } }
    func release() {
        let waiting = lock.withLock {
            holding = false
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    func run(_ request: String) async -> Result<String, UsageAdviceFailure> {
        let wait = lock.withLock {
            requests.append(request)
            return holding
        }
        if wait {
            await withCheckedContinuation { c in
                let go = lock.withLock {
                    if holding { held.append(c) }
                    return !holding
                }
                if go { c.resume() }
            }
        }
        return lock.withLock { answer }
    }
}

@MainActor private final class Bench {
    let runs = Runs()
    let suite = "advice-\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: UsageAdviceStore
    var now = DashboardSamples.now

    init() {
        defaults = UserDefaults(suiteName: suite)!
        store = UsageAdviceStore(path: NSTemporaryDirectory() + suite + "/advice/v1.json")
    }

    func advisor() -> UsageAdvisor {
        UsageAdvisor(defaults: defaults, store: store, now: { [unowned self] in now }, run: { [runs] in await runs.run($0) })
    }

    func close() {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + suite)
    }
}

@MainActor @Test func theDaysRunHappensOnceWhetherItWorkedOrNot() async {
    let bench = Bench()
    defer { bench.close() }
    let advisor = bench.advisor()
    bench.runs.answer(.failure(UsageAdviceFailure(reason: "멈췄습니다")))
    await advisor.analyzeIfDue(DashboardSamples.week)
    await advisor.analyzeIfDue(DashboardSamples.week)
    #expect(bench.runs.count == 1, "a failed run is still the day's run")
    #expect(advisor.record.failed?.reason == "멈췄습니다")

    bench.now = DashboardSamples.now.addingTimeInterval(86_400)
    bench.runs.answer(.success("## 분석"))
    await advisor.analyzeIfDue(DashboardSamples.week)
    await advisor.analyzeIfDue(DashboardSamples.week)
    #expect(bench.runs.count == 2, "once more on the next local day")
    #expect(advisor.record.advice?.body == "## 분석")
    #expect(advisor.record.failed == nil)
}

@MainActor @Test func aRunByHandIsTheDaysRunToo() async {
    let bench = Bench()
    defer { bench.close() }
    let advisor = bench.advisor()
    await advisor.analyze(DashboardSamples.week)
    await advisor.analyzeIfDue(DashboardSamples.week)
    #expect(bench.runs.count == 1)
}

@MainActor @Test func withTheSettingOffNothingRunsByItselfAndTheButtonStillDoes() async {
    let bench = Bench()
    defer { bench.close() }
    bench.defaults.set(false, forKey: UsageAdvisor.autoKey)
    let advisor = bench.advisor()
    await advisor.analyzeIfDue(DashboardSamples.week)
    #expect(bench.runs.count == 0)
    #expect(advisor.record.attemptedAt == nil)
    await advisor.analyze(DashboardSamples.week)
    #expect(bench.runs.count == 1)
    #expect(advisor.record.advice != nil)
}

@MainActor @Test func askingAgainWhileOneRunsStartsNoSecondRun() async {
    let bench = Bench()
    defer { bench.close() }
    let advisor = bench.advisor()
    bench.runs.hold()
    let first = Task { await advisor.analyze(DashboardSamples.week) }
    while bench.runs.count == 0 { await Task.yield() }
    #expect(advisor.running)
    await advisor.analyze(DashboardSamples.week)
    await advisor.analyzeIfDue(DashboardSamples.week)
    #expect(bench.runs.count == 1)
    bench.runs.release()
    await first.value
    #expect(!advisor.running)
    #expect(advisor.record.advice?.period == .week)
}

@MainActor @Test func aHalfReadOrEmptyReportIsNotAnalysedAndDoesNotUseUpTheDay() async {
    let bench = Bench()
    defer { bench.close() }
    let advisor = bench.advisor()
    await advisor.analyzeIfDue(DashboardSamples.reading)
    await advisor.analyze(DashboardSamples.emptyPeriod)
    #expect(bench.runs.count == 0)
    #expect(advisor.record.attemptedAt == nil)
    await advisor.analyzeIfDue(DashboardSamples.week)
    #expect(bench.runs.count == 1)
}

@MainActor @Test func whatWasWrittenIsThereAfterTheAppStartsAgain() async {
    let bench = Bench()
    defer { bench.close() }
    await bench.advisor().analyze(DashboardSamples.month)
    let again = bench.advisor()
    #expect(again.record.advice?.body == "## 분석\n- 가\n\n## 조언\n- 나")
    #expect(again.record.advice.map { adviceStampText($0) } == "지난 30일의 값으로 11월 17일 16:42에 분석")
    await again.analyzeIfDue(DashboardSamples.month)
    #expect(bench.runs.count == 1, "the day's run is remembered across a restart")
}

@MainActor @Test func theRunIsGivenTheSumsAndNoTitleAndNoTranscriptPath() async {
    let bench = Bench()
    defer { bench.close() }
    await bench.advisor().analyze(DashboardSamples.week)
    let request = try! #require(bench.runs.last)
    #expect(request.contains("- notes-app: 출력 4900000"))
    #expect(!request.contains(".jsonl") && !request.contains("/sample/"), "no transcript path")
    #expect(!request.contains("parser 속도 개선"), "no session title")
}

/// The dashboard on screen through a reading that takes `reading` seconds; taken off the screen after `shown`.
@MainActor private func runsStarted(reading: Double, shown: Double, bench: Bench) async throws -> Int {
    let read = OSAllocatedUnfairLock(initialState: false)
    let finished = DashboardSamples.week
    var copy = finished
    copy.computedAt = nil
    let unread = copy
    let usage = UsageDashboard(defaults: bench.defaults, read: {
        try? await Task.sleep(for: .seconds(reading))
        read.withLock { $0 = true }
    }, answer: { _ in read.withLock { $0 } ? finished : unread })
    let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 840, height: 700), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: DashboardView(usage: usage, advisor: bench.advisor(), openProject: { _ in },
                                                               openSession: { _ in nil }, sessionTitle: { _ in nil }))
    window.contentView!.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .seconds(shown))
    window.contentView = nil
    try await Task.sleep(for: .seconds(max(0, reading - shown) + 1))
    return bench.runs.count
}

/// The day's run starts for a dashboard that is on screen when its reading ends, and not for one that left meanwhile:
/// the reading goes to its end either way (R22 S1).
@MainActor @Test func noRunStartsOnceTheDashboardHasLeftTheScreen() async throws {
    let stayed = Bench()
    defer { stayed.close() }
    #expect(try await runsStarted(reading: 0.3, shown: 1.5, bench: stayed) == 1)

    let left = Bench()
    defer { left.close() }
    #expect(try await runsStarted(reading: 1.0, shown: 0.3, bench: left) == 0)
    #expect(left.store.load().attemptedAt == nil, "the day's run is still to come")
}

/// The sheet as drawn, for CT_DASHBOARD_SHOTS: an analysis, a failed try over an older analysis, and the first run.
@MainActor @Test func theAdviceSheetDrawsEachState() async throws {
    let dir = ProcessInfo.processInfo.environment["CT_DASHBOARD_SHOTS"].map { URL(fileURLWithPath: $0) }
    if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    let body = """
    ## 분석
    - **쉰 뒤 다시 쓴 cache가 큽니다.** 32.4M으로 cache 생성의 41%이고 세션 12개에서 나왔습니다.
    - **notes-app에 몰려 있습니다.** 출력 4.9M으로 전체의 40%입니다.

    ## 조언
    - **쉬기 전에 세션을 마무리합니다.** (다시 쓴 cache 32.4M) 자리를 오래 비울 때는 새 세션에서 짧은 요약으로 시작합니다.
    - **주제가 바뀌면 `/clear`를 씁니다.** (압축 3번 이상 세션 5개)
    """
    for (name, scale, dark) in [("written", 1.0, false), ("written", 2.0, true), ("failed", 1.0, false), ("first", 1.0, true)] {
        let bench = Bench()
        defer { bench.close() }
        if name != "first" {
            bench.runs.answer(.success(body))
            await bench.advisor().analyze(DashboardSamples.week)
        }
        let advisor = bench.advisor()
        if name == "failed" {
            bench.runs.answer(.failure(UsageAdviceFailure(reason: "120초 안에 끝나지 않아 멈췄습니다.")))
            await advisor.analyze(DashboardSamples.week)
        }
        var first: Task<Void, Never>?
        if name == "first" {
            bench.runs.hold()
            first = Task { await advisor.analyze(DashboardSamples.week) }
            while bench.runs.count == 0 { await Task.yield() }
        }
        let side = 560 * (0.6 + 0.4 * scale)
        let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: side, height: side), styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: AdviceSheet(advisor: advisor, report: DashboardSamples.week)
            .environment(\.boardFontScale, scale).background(Color(nsColor: .windowBackgroundColor)))
        for _ in 0..<10 {
            window.contentView!.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        let v = window.contentView!
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        #expect(rep.pixelsWide > 0)
        if let dir {
            try rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("advice-\(name)-\(dark ? "dark" : "light")-s\(String(format: "%.1f", scale)).png"))
        }
        window.contentView = nil
        bench.runs.release()
        await first?.value
    }
}
