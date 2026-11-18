import Observation
import SwiftUI
import TowerCore

// The 새는 곳 group's analysis and advice (T201): Claude writes it from the sums on the page, once a day when the
// dashboard is first shown and again when asked.

/// The kept analysis and the one run that may be going. Owned by `Tower`, so a run started from the dashboard ends
/// and is saved whatever screen is shown by then.
@MainActor @Observable
final class UsageAdvisor {
    /// The setting that turns the day's automatic run off. On without a stored value.
    static let autoKey = "usageAdviceAuto"

    private(set) var record: UsageAdviceRecord
    private(set) var running = false
    /// The sheet with the analysis is open.
    var shown = false

    private let defaults: UserDefaults
    private let store: UsageAdviceStore
    private let now: () -> Date
    private let run: @Sendable (String) async -> Result<String, UsageAdviceFailure>

    /// `run` gets the request and gives what was written. Only `Tower` passes the one that starts `claude`.
    init(defaults: UserDefaults, store: UsageAdviceStore, now: @escaping () -> Date = Date.init,
         run: @escaping @Sendable (String) async -> Result<String, UsageAdviceFailure>) {
        self.defaults = defaults
        self.store = store
        self.now = now
        self.run = run
        record = store.load()
    }

    /// A report can be analysed once it is read to its end and holds a response.
    static func analysable(_ report: UsageReport) -> Bool { report.computedAt != nil && report.totals.responses > 0 }

    /// One run from `report`'s sums. While one is going, or for a report with nothing in it, it does nothing.
    func analyze(_ report: UsageReport) async {
        guard !running, Self.analysable(report) else { return }
        running = true
        // kept before the run: the day's automatic run is this one, whatever becomes of it
        record.attemptedAt = now()
        store.save(record)
        let result = await run(usageAdviceRequest(report))
        record.take(result, of: report, at: now())
        store.save(record)
        running = false
    }

    /// The day's automatic run, for the dashboard to call each time it has a finished report on screen.
    func analyzeIfDue(_ report: UsageReport) async {
        guard defaults.object(forKey: Self.autoKey) as? Bool ?? true, usageAdviceDue(record, now: now()) else { return }
        await analyze(report)
    }
}

/// The run the app makes: the fixed `claude` call, off the main thread.
let claudeAdviceRun: @Sendable (String) async -> Result<String, UsageAdviceFailure> = { request in
    await Task.detached { runUsageAdvice(request) }.value
}

/// The test instance's run: it writes what it would have started to the actions log and answers with a fixed text.
func dryAdviceRun(log: String) -> @Sendable (String) async -> Result<String, UsageAdviceFailure> {
    { request in
        recordDryRun("advice: claude \(usageAdviceArguments.prefix(3).joined(separator: " ")) … (stdin \(request.utf8.count) bytes)", to: log)
        try? await Task.sleep(for: .seconds(1))
        return .success("## 분석\n- 테스트용 앱은 claude를 실행하지 않습니다. 이 글은 고정된 예시입니다.\n\n## 조언\n- 실제 앱에서 분석을 다시 실행해 보십시오.")
    }
}

/// "지난 7일의 값으로 11월 18일 10:12에 분석"
func adviceStampText(_ advice: UsageAdviceRecord.Advice, calendar: Calendar = .current) -> String {
    "\(periodName(advice.period))의 값으로 \(adviceTimeText(advice.at, calendar: calendar))에 분석"
}

func adviceTimeText(_ date: Date, calendar: Calendar = .current) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ko_KR")
    f.calendar = calendar
    f.timeZone = calendar.timeZone
    f.dateFormat = "M월 d일 HH:mm"
    return f.string(from: date)
}

/// What stands beside the 새는 곳 title: the button that opens the analysis, and a spinner while one is written.
struct AdviceButton: View {
    @Bindable var advisor: UsageAdvisor

    var body: some View {
        HStack(spacing: 8) {
            if advisor.running { ProgressView().controlSize(.small).accessibilityLabel("분석 중") }
            Button("분석과 조언") { advisor.shown = true }.scaledFont(.body)
        }
        .unredacted()
    }
}

/// The analysis as a document, when it was written and from what, and the button that writes it again.
struct AdviceSheet: View {
    @Bindable var advisor: UsageAdvisor
    /// What a new analysis is written from: the period on the page.
    let report: UsageReport
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("새는 곳 분석과 조언").scaledFont(.headline, weight: .semibold).padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let failed = advisor.record.failed, !advisor.running {
                        Label("\(adviceTimeText(failed.at))에 분석하지 못했습니다. \(failed.reason)", systemImage: "exclamationmark.triangle")
                            .scaledFont(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let advice = advisor.record.advice {
                        MarkdownView(blocks: markdownBlocks(advice.body))
                    } else if advisor.running {
                        Text("분석을 쓰는 중입니다. 보통 10초쯤 걸립니다.").scaledFont(.body).foregroundStyle(.secondary)
                    } else if advisor.record.failed == nil {
                        Text("아직 분석이 없습니다.").scaledFont(.body).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            Divider()
            HStack(spacing: 12) {
                Text(footnote).scaledFont(.caption1).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if advisor.running { ProgressView().controlSize(.small).accessibilityLabel("분석 중") }
                Button(advisor.record.advice == nil ? "분석" : "다시 분석") { Task { await advisor.analyze(report) } }
                    .disabled(advisor.running || !UsageAdvisor.analysable(report))
                Button("닫기") { advisor.shown = false }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560 * (0.6 + 0.4 * scale), height: 560 * (0.6 + 0.4 * scale))
    }

    private var footnote: String {
        let source = "Claude(\(usageAdviceModel))가 이 화면의 집계 숫자만 보고 쓴 글입니다."
        return advisor.record.advice.map { "\(adviceStampText($0)). \(source)" } ?? source
    }
}
