import SwiftUI
import TowerCore

/// The usage dashboard (T177): a fixed header with the period, then one scrolling page read sentence first, then
/// number, then chart (T180 §2.2 C1). It reads only while it is on screen and never on the board's 5 s loop.
struct DashboardView: View {
    @Bindable var usage: UsageDashboard
    @Bindable var advisor: UsageAdvisor
    /// The live teams, for the 실행 중인 워커 group.
    let teams: [Team]
    /// Puts a project's name in the sidebar search.
    let openProject: (String) -> Void
    /// What opens a session's row on the board; nil when the board has no row for that transcript.
    let openSession: (String) -> (() -> Void)?
    /// A session's title from the history; nil when the history has no entry for that transcript.
    let sessionTitle: (String) -> String?
    @Environment(\.boardFontScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The period the refresh loop last ran for: a change is a reason to read at once, a first showing is not.
    @State private var loopPeriod: UsagePeriod?

    var body: some View {
        let phase = dashboardPhase(usage.report, hasRecords: usage.hasRecords)
        Group {
            if phase == .noRecords {
                ContentUnavailableView("아직 사용 기록이 없습니다", systemImage: "chart.bar", description: Text(
                    "claude 세션을 쓰면 여기에 사용량이 나옵니다. 기록은 이 Mac 밖으로 나가지 않습니다."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geo in page(phase, columns: dashboardColumns(width: geo.size.width, scale: scale)) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { DashboardHeader(usage: usage, phase: phase) }
        .task(id: usage.period) { await keepFresh() }
        .onChange(of: workerTranscripts(teams), initial: true) { usage.workerTranscripts = $1 }
        .sheet(isPresented: $advisor.shown) { AdviceSheet(advisor: advisor, report: usage.report) }
    }

    private func page(_ phase: DashboardPhase, columns: Int) -> some View {
        let report = usage.report
        return ScrollViewReader { proxy in ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                insights(report, columns: columns).id(DashboardBlock.insights)
                UsageGroup(report: report, hovered: $usage.hoveredBar).id(DashboardBlock.section(.usage))
                if columns == 2 {
                    // one scroll target for the row: scrollPosition sees only the stack's own children
                    Grid(alignment: .topLeading, horizontalSpacing: 16) {
                        GridRow {
                            BreakdownGroup(report: report, openProject: openProject).frame(maxHeight: .infinity, alignment: .top)
                            LeaksGroup(report: report, advisor: advisor, openSession: openSession, sessionTitle: sessionTitle)
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .id(DashboardBlock.section(.breakdown))
                } else {
                    BreakdownGroup(report: report, openProject: openProject).id(DashboardBlock.section(.breakdown))
                    LeaksGroup(report: report, advisor: advisor, openSession: openSession, sessionTitle: sessionTitle)
                        .id(DashboardBlock.section(.leaks))
                }
                WorkersCacheGroup(teams: workerCacheTeams(teams, totals: usage.workerTotals), openSession: openSession)
            }
            .scrollTargetLayout()
            .redacted(reason: phase == .shown ? [] : .placeholder)
            // redaction is for the eye: VoiceOver would still read a half-read period's values
            .accessibilityHidden(phase != .shown)
            .frame(maxWidth: 1240 * scale, alignment: .leading)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            // R1: a timed refresh never moves the page; only a period the user picked animates
            .animation(reduceMotion ? nil : .default, value: usage.period)
            .transaction { $0.animation = nil }
            // a page built again starts at the top whatever the position's binding holds: put it back (R12 L2)
            .onAppear { proxy.scrollTo(usage.scrolled, anchor: .top) }
        }
        .scrollPosition(id: $usage.scrolled, anchor: .top) }
    }

    private func insights(_ report: UsageReport, columns: Int) -> some View {
        let lines = usageInsights(report)
        return VStack(alignment: .leading, spacing: 6) {
            Text(insightsTitle(report.period)).scaledFont(.headline, weight: .semibold).unredacted()
            ForEach(lines, id: \.self) { insight in
                Button { show(insight.section, columns: columns) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(insight.text).scaledFont(.body).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(sectionLink(insight.section)).scaledFont(.body).foregroundStyle(.secondary).fixedSize()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            if let note = usageInsightNote(report, sentences: lines.count) {
                Text(note).scaledFont(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func show(_ section: UsageSection, columns: Int) {
        let block = columns == 2 && section == .leaks ? DashboardBlock.section(.breakdown) : .section(section)
        withAnimation(reduceMotion ? nil : .default) { usage.scrolled = block }
    }

    /// Reads at once when the period changed or the last reading is older than the period's interval, then again
    /// each time it falls due. SwiftUI cancels it when the dashboard leaves the screen.
    private func keepFresh() async {
        let changed = loopPeriod.map { $0 != usage.period } ?? false
        loopPeriod = usage.period
        if changed { await usage.refresh() }
        while !Task.isCancelled {
            if usageRefreshDue(period: usage.period, last: usage.lastRefresh, now: Date()) { await usage.refresh() }
            // a reading goes to its end after the dashboard left the screen: nothing starts for another screen (R22 S1)
            guard !Task.isCancelled else { return }
            // not awaited: the run takes seconds, and it ends on its own if the dashboard leaves the screen meanwhile
            let report = usage.report
            Task { await advisor.analyzeIfDue(report) }
            let wait = usage.lastRefresh.map { usageRefreshInterval(usage.period) - Date().timeIntervalSince($0) } ?? 1
            do { try await Task.sleep(for: .seconds(max(1, wait))) } catch { return }
        }
    }
}

private func sectionLink(_ section: UsageSection) -> String {
    switch section {
    case .usage: "사용량 ›"
    case .breakdown: "어디에 ›"
    case .leaks: "새는 곳 ›"
    }
}

/// The period, when it was read, and the one control of the page. At a narrow width the picker drops under the title.
private struct DashboardHeader: View {
    @Bindable var usage: UsageDashboard
    let phase: DashboardPhase
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    title
                    Spacer(minLength: 12)
                    picker
                }
                VStack(alignment: .leading, spacing: 8) {
                    title
                    picker
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(periodName(usage.period)).scaledFont(.headline, weight: .semibold)
            switch phase {
            case .reading(let progress) where progress.filesTotal > 0:
                ProgressView(value: Double(min(progress.filesRead, progress.filesTotal)), total: Double(progress.filesTotal))
                    .progressViewStyle(.linear).frame(width: 120 * scale).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] }
                Text("집계 중… 기록 \(progress.filesTotal)개 중 \(progress.filesRead)개").scaledFont(.callout).foregroundStyle(.secondary)
            case .reading:
                ProgressView().controlSize(.small)
                Text("집계 중…").scaledFont(.callout).foregroundStyle(.secondary)
            case .noRecords, .shown:
                if let at = usage.report.computedAt {
                    Text("\(dashboardTimeText(at)) 집계").scaledFont(.callout).foregroundStyle(.secondary)
                }
                if usage.refreshing {
                    ProgressView().controlSize(.small).accessibilityLabel("다시 집계 중")
                }
            }
        }
        .fixedSize()
    }

    private var picker: some View {
        Picker("기간", selection: $usage.period) {
            ForEach(UsagePeriod.allCases, id: \.self) { Text(periodLabel($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}
