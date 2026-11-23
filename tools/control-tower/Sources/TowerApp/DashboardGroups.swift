import Charts
import SwiftUI
import TowerCore

/// A dashboard group: its title, and what stands beside the title, over a system box. The title is not the box's
/// label: a `GroupBox` label is one accessibility element, and a control in it could not be reached (the 어디에
/// picker was read as part of the heading "어디에, 나누는 기준").
private struct DashboardGroup<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // as tall as the 어디에 picker, so the boxes of a two-column row start level
                Text(title).scaledFont(.headline, weight: .semibold).unredacted().accessibilityAddTraits(.isHeader)
                    .frame(minHeight: 24)
                Spacer()
                accessory
            }
            .padding(.horizontal, 8)
            GroupBox { content }
        }
    }
}

extension DashboardGroup where Accessory == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, accessory: { EmptyView() }, content: content)
    }
}

/// 사용량: how much, against the usual (T177 item 4). The total is the page's one large number.
struct UsageGroup: View {
    let report: UsageReport
    @Binding var hovered: Date?
    @Environment(\.boardFontScale) private var scale
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        DashboardGroup(title: "사용량") {
            VStack(alignment: .leading, spacing: 10) {
                // one Text, so at a narrow width the comparison wraps under the total instead of squeezing it
                (Text(usageTotalText(report)).font(.system(size: 20 * scale, weight: .semibold))
                    + Text(usageComparisonText(report).map { "  \($0)" } ?? "")
                    .font(.system(size: NSFont.preferredFont(forTextStyle: .body).pointSize * scale)))
                    .fixedSize(horizontal: false, vertical: true)
                Group {
                    if report.totals.responses == 0 {
                        Text("이 기간에 기록 없음").scaledFont(.body).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // redaction covers text only: bars of a half-read period would read as its values
                        UsageChart(report: report, hovered: $hovered).opacity(redaction.contains(.placeholder) ? 0 : 1)
                    }
                }
                .frame(height: 150 * (0.6 + 0.4 * scale))
                Text(usageLegendText(report)).scaledFont(.caption1).foregroundStyle(.secondary)
                Text(usageNumbersText(report)).scaledFont(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

/// Output by hour or day, one color, the bar in progress faint, the usual level dashed. Bars are not buttons: there
/// is no screen of one day's sessions to open (T180 §3).
private struct UsageChart: View {
    let report: UsageReport
    @Environment(\.boardFontScale) private var scale
    @Binding var hovered: Date?

    private var hoveredBucket: UsageBucket? { report.buckets.first { $0.start == hovered } }

    private var unit: Calendar.Component { report.period == .today ? .hour : .day }

    /// Half a bar's span. Days are taken as 24 hours: a daylight saving day is an hour off, under a label's width.
    private var halfBarSpan: TimeInterval { report.period == .today ? 1800 : 43_200 }

    private var xDomain: ClosedRange<Date> {
        let first = report.buckets.first?.start ?? report.from
        let last = report.buckets.last?.start ?? first
        return first...(Calendar.current.date(byAdding: unit, value: 1, to: last) ?? last)
    }

    /// The usual level from each bar's start, and once more at the end of the last, so the line spans every bar.
    private var usualSteps: [UsageBucket] {
        let usual = report.baseline.buckets
        guard let last = usual.last else { return [] }
        return usual + [UsageBucket(start: Calendar.current.date(byAdding: unit, value: 1, to: last.start) ?? last.start, output: last.output)]
    }

    var body: some View {
        let largest = (report.buckets.map(\.output) + (usageShowsUsual(report) ? report.baseline.buckets.map(\.output) : [])).max() ?? 0
        let top = usageAxisTop(largest)
        GeometryReader { geo in
            Chart {
                ForEach(Array(report.buckets.enumerated()), id: \.element.start) { i, bucket in
                    BarMark(x: .value("시각", bucket.start, unit: unit), y: .value("출력", bucket.output))
                        .foregroundStyle(TaskColor.blue.opacity(i == report.buckets.count - 1 ? 0.45 : 1))
                }
                if usageShowsUsual(report) {
                    ForEach(usualSteps, id: \.start) { usual in
                        LineMark(x: .value("시각", usual.start), y: .value("평소", usual.output), series: .value("선", "평소"))
                            .interpolationMethod(.stepEnd)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(Color.secondary)
                            .accessibilityHidden(true)
                    }
                }
                if let hoveredBucket {
                    RuleMark(x: .value("시각", hoveredBucket.start, unit: unit))
                        .foregroundStyle(Color.secondary)
                        .accessibilityHidden(true)
                }
            }
            .chartLegend(.hidden)
            // the whole span of the last bar: an automatic domain ends at its start and drops its x label
            .chartXScale(domain: xDomain)
            .chartYScale(domain: 0...top)
            .chartYAxis {
                AxisMarks(values: [0, top / 2, top]) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.3))
                    AxisValueLabel {
                        Text(usageTokenText(value.as(Int.self) ?? 0)).font(.system(size: 10 * scale)).accessibilityHidden(true)
                    }
                }
            }
            .chartXAxis {
                // ticks at the bars' middles: a centered label on the last bar's start was dropped at the domain's end
                AxisMarks(values: labelled(width: geo.size.width).map { $0.addingTimeInterval(halfBarSpan) }) { value in
                    AxisValueLabel {
                        Text(value.as(Date.self).map { bucketAxisLabel($0.addingTimeInterval(-halfBarSpan), period: report.period) } ?? "")
                            .font(.system(size: 10 * scale)).accessibilityHidden(true)
                    }
                }
            }
            // one element per bar, named by the app: past a dozen bars Charts reads them in groups, in English
            // ("… to …, 3 values"), and the values in the middle of a group are never read
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("출력 토큰 막대")
            .accessibilityChildren {
                HStack {
                    ForEach(report.buckets, id: \.start) { bucket in
                        Rectangle().accessibilityLabel(bucketName(bucket.start, period: report.period))
                            .accessibilityValue("출력 \(usageTokenText(bucket.output)) 토큰")
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { overlay in
                    let plot = proxy.plotFrame.map { overlay[$0] }
                    Rectangle().fill(.clear).contentShape(.rect)
                        .onContinuousHover { phase in
                            guard case .active(let point) = phase, let plot,
                                  let date = proxy.value(atX: point.x - plot.minX, as: Date.self) else {
                                hovered = nil
                                return
                            }
                            hovered = nearest(date)
                        }
                        // placed here, not as the rule's annotation: Charts offers an annotation a width under the
                        // text's at 2.0, and one given its own width is not kept inside the chart (T200)
                        .overlay {
                            if let plot, let bucket = hoveredBucket,
                               let x = proxy.position(forX: bucket.start.addingTimeInterval(halfBarSpan)) {
                                OverBar(x: plot.minX + x, foot: plot.minY - 4) {
                                    Text(bucketHoverText(bucket, period: report.period)).scaledFont(.callout).monospacedDigit()
                                        .padding(.horizontal, 6).padding(.vertical, 3)
                                        .background(.background, in: RoundedRectangle(cornerRadius: 4))
                                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                                }
                                .allowsHitTesting(false)
                                // each bar's own element already says this
                                .accessibilityHidden(true)
                            }
                        }
                        // the page's model outlives this view, and a view taken away is not told the pointer left
                        .onDisappear { hovered = nil }
                }
            }
        }
    }

    /// The starts that get a label. Today's are whole multiples of 3, 6 or 12 hours, so they read as a clock.
    private func labelled(width: CGFloat) -> [Date] {
        let stride = axisLabelStride(count: report.buckets.count, width: width, scale: scale)
        if report.period == .today {
            let hours = [3, 6, 12].first { $0 >= stride } ?? 12
            return report.buckets.map(\.start).filter { Calendar.current.component(.hour, from: $0) % hours == 0 }
        }
        return report.buckets.enumerated().filter { $0.offset % stride == 0 }.map(\.element.start)
    }

    /// The bar whose span is nearest the pointer's date.
    private func nearest(_ date: Date) -> Date? {
        report.buckets.min { abs($0.start.addingTimeInterval(halfBarSpan).timeIntervalSince(date)) < abs($1.start.addingTimeInterval(halfBarSpan).timeIntervalSince(date)) }?.start
    }
}

/// Its one view centered over `x` and moved in from the sides, its foot at `foot`. A view wider than the room wraps.
private struct OverBar: Layout {
    let x: CGFloat
    let foot: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        let left = min(max(x - size.width / 2, 0), max(0, bounds.width - size.width))
        view.place(at: CGPoint(x: bounds.minX + left, y: bounds.minY + foot - size.height), proposal: ProposedViewSize(size))
    }
}

/// 어디에: which projects and models the output went to (T177 item 5).
struct BreakdownGroup: View {
    let report: UsageReport
    let openProject: (String) -> Void
    @AppStorage(UsageBreakdown.storageKey) private var breakdown = UsageBreakdown.projects
    /// By name, so a refresh keeps it (R4).
    @State private var selected: String?
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        let rows = usageRankRows(breakdown == .projects ? report.projects : report.models, total: report.totals.output, by: breakdown)
        let largest = rows.map(\.output).max() ?? 0
        DashboardGroup(title: "어디에") {
            Picker("나누는 기준", selection: $breakdown) {
                ForEach(UsageBreakdown.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().unredacted()
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text(breakdownConclusion(report, by: breakdown)).scaledFont(.body)
                // a system list so selection, arrows, Return, double click and the menu are the system's (T180 §2.1)
                List(selection: $selected) {
                    ForEach(rows, id: \.name) { row in
                        RankLine(row: row, largest: largest).tag(row.name)
                    }
                }
                .dashboardList(rows: 6, scale: scale)
                .accessibilityLabel("\(breakdown.label)별 출력 토큰")
                .contextMenu(forSelectionType: String.self) { names in
                    if let search = rankSearchText(names.first, rows: rows, by: breakdown) { Button("사이드바에서 검색") { openProject(search) } }
                } primaryAction: { names in
                    if let search = rankSearchText(names.first, rows: rows, by: breakdown) { openProject(search) }
                }
            }
            .padding(4)
        }
    }
}

/// One ranked line: the name, its output and share, and under them a bar as long as its share of the largest line.
private struct RankLine: View {
    let row: RankRow
    let largest: Int
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.label).scaledFont(.callout).lineLimit(1).truncationMode(.middle).help(rankTooltip(row))
                Spacer(minLength: 8)
                Text(usageTokenText(row.output)).scaledFont(.callout).monospacedDigit()
                Text(sharePercentText(row.share)).scaledFont(.callout).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 34 * scale, alignment: .trailing)
            }
            ShareBar(fraction: largest > 0 ? Double(row.output) / Double(largest) : 0,
                     color: prominence == .increased ? .white : TaskColor.blue)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.label)
        .accessibilityValue("출력 \(usageTokenText(row.output)) 토큰, \(sharePercentText(row.share))")
    }
}

/// A 4 pt bar from the leading edge. On a selected line it is white, so the selection does not hide it.
private struct ShareBar: View {
    let fraction: Double
    let color: Color
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 2).fill(color)
                .frame(width: max(2, geo.size.width * fraction))
                .modifier(IncreasedContrastBorder(color: TaskColor.blue, radius: 2))
        }
        .frame(height: 4)
        .opacity(redaction.contains(.placeholder) ? 0 : 1)
    }
}

extension View {
    /// A list inside a group: no scroll and no background of its own, always `rows` lines tall so a refresh never
    /// moves what is below (R3).
    func dashboardList(rows: Int, scale: CGFloat) -> some View {
        let height = 34 * scale
        return listStyle(.plain)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, height)
            .frame(height: CGFloat(rows) * height)
    }
}

/// 새는 곳: cache written again after a pause and sessions compacted again and again (T177 item 6).
struct LeaksGroup: View {
    let report: UsageReport
    let advisor: UsageAdvisor
    let openSession: (String) -> (() -> Void)?
    let sessionTitle: (String) -> String?

    /// By transcript path, so a refresh keeps it (R4).
    @State private var selected: String?
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        let sessions = leakSessions(report)
        DashboardGroup(title: "새는 곳", accessory: { AdviceButton(advisor: advisor) }) {
            VStack(alignment: .leading, spacing: 12) {
                rewritten
                HStack(alignment: .firstTextBaseline) {
                    Text("압축이 반복된 세션").scaledFont(.callout, weight: .semibold).fixedSize()
                    Spacer(minLength: 8)
                    Text(compactionSummaryText(report)).scaledFont(.callout).monospacedDigit().multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .combine)
                List(selection: $selected) {
                    ForEach(sessions, id: \.transcriptPath) { s in
                        let project = usageProjectName(s.project, among: report.projects.map(\.name))
                        LeakLine(session: s, title: sessionTitle(s.transcriptPath) ?? project, project: project,
                                 openable: openSession(s.transcriptPath) != nil)
                            .tag(s.transcriptPath)
                    }
                }
                .dashboardList(rows: 5, scale: scale)
                .accessibilityLabel("새는 세션")
                .overlay {
                    if sessions.isEmpty { Text("이 기간에 해당 세션 없음").scaledFont(.body).foregroundStyle(.secondary) }
                }
                .contextMenu(forSelectionType: String.self) { paths in
                    if let open = paths.first.flatMap(openSession) { Button("세션 열기", action: open) }
                } primaryAction: { paths in
                    paths.first.flatMap(openSession)?()
                }
            }
            .padding(4)
        }
    }

    /// Cache written again after a pause: the numbers, a two-piece bar and its legend in words. Without any cache
    /// written the same height holds one line saying so.
    private var rewritten: some View {
        let summary = rewrittenSummaryText(report)
        let pieces = rewrittenPieces(report)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("쉰 뒤 다시 쓴 cache").scaledFont(.callout, weight: .semibold).fixedSize()
                Spacer(minLength: 8)
                Text(summary ?? "").scaledFont(.callout).monospacedDigit().multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 6) {
                TwoPieceBar(first: pieces.continued, second: pieces.rewritten)
                (Text(Image(systemName: "square.fill")).foregroundStyle(TaskColor.blue)
                    + Text(" 이어 쓴 것 \(usageTokenText(pieces.continued))   ")
                    + Text(Image(systemName: "square.fill")).foregroundStyle(TaskColor.orange)
                    + Text(" \(rewrittenLegendText) \(usageTokenText(pieces.rewritten))"))
                    .scaledFont(.caption1).foregroundStyle(.secondary)
            }
            .opacity(summary == nil ? 0 : 1)
            .overlay(alignment: .leading) {
                if summary == nil { Text("이 기간에 cache 생성 없음").scaledFont(.callout).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("쉰 뒤 다시 쓴 cache")
        .accessibilityValue(summary ?? "이 기간에 cache 생성 없음")
    }
}

/// An 8 pt bar in two pieces with a 1 pt gap: blue then orange, each as long as its share of the sum.
private struct TwoPieceBar: View {
    let first: Int
    let second: Int
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        GeometryReader { geo in
            let total = max(1, first + second)
            let gap: CGFloat = first > 0 && second > 0 ? 1 : 0
            let width = geo.size.width - gap
            HStack(spacing: gap) {
                if first > 0 { piece(TaskColor.blue).frame(width: width * CGFloat(first) / CGFloat(total)) }
                if second > 0 { piece(TaskColor.orange).frame(width: width * CGFloat(second) / CGFloat(total)) }
            }
        }
        .frame(height: 8)
        .opacity(redaction.contains(.placeholder) ? 0 : 1)
    }

    private func piece(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(color).modifier(IncreasedContrastBorder(color: color, radius: 2))
    }
}

/// A session behind the leak numbers. One the board has no row for is drawn in secondary and opens nothing.
private struct LeakLine: View {
    let session: UsageSession
    let title: String
    /// The project as the 어디에 lines name it.
    let project: String
    let openable: Bool
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        let facts = leakSessionFacts(session)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // the numbers go first; the title keeps enough to be recognized, the project gives way entirely
            Text(title).scaledFont(.callout).foregroundStyle(openable ? .primary : .secondary).lineLimit(1)
                .frame(minWidth: 60 * scale, alignment: .leading)
            if title != project {
                Text(project).scaledFont(.callout).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
            }
            Spacer(minLength: 8)
            Text(facts.joined(separator: " · ")).scaledFont(.callout).monospacedDigit()
                .foregroundStyle(openable ? .primary : .secondary).lineLimit(1).layoutPriority(1)
        }
        .help(([title, session.project] + facts).joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(([project] + facts).joined(separator: ", "))
    }
}

/// 실행 중인 워커 (T232): each running worker's prompt cache hit rate over its current session, whatever the period.
/// Seven columns, or four when they do not fit, or a worker's values under its name when even four do not; the
/// tooltip and VoiceOver carry all seven either way.
struct WorkersCacheGroup: View {
    let teams: [WorkerCacheTeam]
    /// What opens a transcript's row on the board; nil when the board has no row for it.
    let openSession: (String) -> (() -> Void)?

    var body: some View {
        DashboardGroup(title: "실행 중인 워커") {
            VStack(alignment: .leading, spacing: 8) {
                Text("기간 선택과 상관없이 각 워커의 지금 세션 전체를 셉니다.").scaledFont(.caption1).foregroundStyle(.secondary)
                if teams.isEmpty {
                    Text("실행 중인 my-team 워커가 없습니다").scaledFont(.callout).foregroundStyle(.secondary)
                } else {
                    ViewThatFits(in: .horizontal) {
                        grid(wide: true)
                        grid(wide: false)
                        list
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func grid(wide: Bool) -> some View {
        let columns = wide ? 7 : 4
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
            ForEach(teams, id: \.name) { team in
                if teams.count > 1 {
                    Text(team.name).scaledFont(.callout, weight: .semibold).accessibilityAddTraits(.isHeader)
                        .padding(.top, team == teams.first ? 0 : 8).gridCellColumns(columns)
                }
                if team == teams.first || teams.count > 1 { header(wide: wide) }
                ForEach(team.lines, id: \.name) { row($0, wide: wide) }
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(teams, id: \.name) { team in
                if teams.count > 1 {
                    Text(team.name).scaledFont(.callout, weight: .semibold).accessibilityAddTraits(.isHeader)
                        .padding(.top, team == teams.first ? 0 : 8)
                }
                ForEach(team.lines, id: \.name) { line in
                    let c = workerCacheCells(line.state)
                    VStack(alignment: .leading, spacing: 2) {
                        name(line)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            rate(c.rate, low: c.rateLow, few: c.rateFew)
                            Text("· cache 읽기 \(c.cacheRead) · sub-agent \(c.subagent)").scaledFont(.callout).monospacedDigit()
                                .foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                    }
                    .help(workerCacheTooltip(line))
                }
            }
        }
    }

    private func header(wide: Bool) -> some View {
        GridRow {
            ForEach(wide ? ["워커", "히트율", "cache 읽기", "cache 생성", "입력", "응답", "sub-agent"]
                         : ["워커", "히트율", "cache 읽기", "sub-agent"], id: \.self) { title in
                Text(title).scaledFont(.caption1).foregroundStyle(.secondary)
                    .gridColumnAlignment(title == "워커" || title == "sub-agent" ? .leading : .trailing)
            }
        }
        .accessibilityHidden(true)
    }

    private func row(_ line: WorkerCacheLine, wide: Bool) -> some View {
        let c = workerCacheCells(line.state)
        let tip = workerCacheTooltip(line)
        return GridRow {
            name(line).help(tip)
            rate(c.rate, low: c.rateLow, few: c.rateFew).help(tip)
            number(c.cacheRead).help(tip)
            if wide {
                number(c.cacheCreation).help(tip)
                number(c.input).help(tip)
                number(c.responses).help(tip)
            }
            rate(c.subagent, low: c.subagentLow, few: false).help(tip)
        }
    }

    @ViewBuilder
    private func name(_ line: WorkerCacheLine) -> some View {
        let label = workerCacheAccessibilityLabel(line)
        if let path = line.transcript, let open = openSession(path) {
            Button(action: open) { Text("\(line.name) ›").scaledFont(.callout, weight: .semibold).lineLimit(1) }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityHint("사이드바에서 이 워커를 엽니다")
        } else {
            Text(line.name).scaledFont(.callout, weight: .semibold).lineLimit(1).accessibilityLabel(label)
        }
    }

    private func rate(_ text: String, low: Bool, few: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(text).scaledFont(.callout).monospacedDigit().foregroundStyle(few ? .secondary : .primary)
            if low {
                Label("낮음", systemImage: "exclamationmark.triangle.fill").scaledFont(.caption1).foregroundStyle(TaskColor.orange)
            }
        }
        // a number never breaks: the name gives up its width first
        .fixedSize()
        .accessibilityHidden(true)
    }

    private func number(_ text: String) -> some View {
        Text(text).scaledFont(.callout).monospacedDigit().fixedSize().accessibilityHidden(true)
    }
}
