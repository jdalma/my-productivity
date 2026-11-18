import AppKit
import SwiftUI
import Testing
import TowerCore
@testable import TowerApp

// The dashboard as drawn (T177): header and page hosted in a window never shown, read back as a bitmap. With
// CT_DASHBOARD_SHOTS naming a directory, each case is also written there as a PNG to look at.

/// Invented reports: names and numbers made up for the public repo.
enum DashboardSamples {
    static let calendar = Calendar.current
    /// Tuesday 2026-11-17, 16:42 local.
    static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 16, minute: 42))!
    static let today = calendar.startOfDay(for: now)

    static func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
    static func hour(_ h: Int) -> Date { calendar.date(byAdding: .hour, value: h, to: today)! }

    static let projectNames = ["notes-app", "cli-tools", "blog", "parser", "sandbox", "dotfiles", "web-shop", "a-project-with-a-rather-long-folder-name"]

    static func rank(_ name: String, _ output: Int, responses: Int = 100) -> UsageRank {
        UsageRank(name: name, tokens: UsageTokens(output: output, cacheRead: output * 240, cacheCreation: output * 5, input: output / 160, responses: responses))
    }

    static func session(_ n: Int, project: String, output: Int, rewritten: Int, compactions: Int) -> UsageSession {
        UsageSession(transcriptPath: "/sample/\(project)/s\(n).jsonl", project: project, lastActive: day(-n % 7), output: output,
                     rewrittenCache: rewritten, compactions: compactions)
    }

    static func report(_ period: UsagePeriod, buckets: [UsageBucket], usual: [UsageBucket]?, totals: UsageTokens,
                       activeDays: Int, projects: [UsageRank] = [], models: [UsageRank] = [],
                       rewritten: UsageRewrittenCache = UsageRewrittenCache(), compactions: [UsageCompactionGroup] = [],
                       sessions: [UsageSession] = [], computedAt: Date? = now,
                       progress: UsageProgress = UsageProgress(filesTotal: 412, filesRead: 412)) -> UsageReport {
        let basis: UsageBaseline.Basis = switch period {
        case .today: .sameTimeLast7Days
        case .week: .weeklyAverageLast4Weeks
        case .month: .previous30Days
        }
        let required = period == .today ? 3 : period == .week ? 14 : 1
        let baseline = UsageBaseline(basis: basis, output: usual.map { $0.reduce(0) { $0 + $1.output } },
                                     activeDays: usual == nil ? 2 : 24, requiredDays: required, buckets: usual ?? [])
        return UsageReport(period: period, from: buckets.first?.start ?? today, to: now, buckets: buckets, totals: totals,
                           activeDays: activeDays, baseline: baseline, projects: projects, models: models, kinds: [],
                           rewrittenCache: rewritten, compactions: compactions, sessions: sessions, computedAt: computedAt,
                           progress: progress)
    }

    static let weekOutputs = [1_700_000, 1_650_000, 2_100_000, 900_000, 2_050_000, 2_700_000, 1_300_000]

    /// A week with a baseline and every list longer than 5.
    static let week: UsageReport = {
        let buckets = weekOutputs.enumerated().map { UsageBucket(start: day($0.offset - 6), output: $0.element) }
        let usual = (0..<7).map { UsageBucket(start: day($0 - 6), output: 1_490_000) }
        let outputs = [4_900_000, 3_000_000, 2_000_000, 1_300_000, 863_000, 720_000, 610_000, 1_007_000]
        let projects = zip(projectNames, outputs).map { rank($0, $1) }
        let models = [rank("model-a", 10_100_000), rank("model-b", 3_000_000), rank("model-c", 1_300_000)]
        let sessions = [
            session(1, project: "notes-app", output: 2_100_000, rewritten: 12_300_000, compactions: 4),
            session(2, project: "cli-tools", output: 1_200_000, rewritten: 8_000_000, compactions: 0),
            session(3, project: "blog", output: 900_000, rewritten: 0, compactions: 11),
            session(4, project: "parser", output: 800_000, rewritten: 5_100_000, compactions: 3),
            session(5, project: "sandbox", output: 700_000, rewritten: 4_000_000, compactions: 1),
            session(6, project: "notes-app", output: 600_000, rewritten: 3_000_000, compactions: 5),
            session(7, project: "dotfiles", output: 500_000, rewritten: 0, compactions: 1),
        ]
        return report(.week, buckets: buckets, usual: usual,
                      totals: UsageTokens(output: weekOutputs.reduce(0, +), cacheRead: 3_500_000_000, cacheCreation: 79_100_000,
                                          input: 86_000, responses: 11_234),
                      activeDays: 7, projects: projects, models: models,
                      rewritten: UsageRewrittenCache(tokens: 32_400_000, responses: 40, sessions: 12),
                      compactions: [UsageCompactionGroup(compactions: 1, sessions: 8), UsageCompactionGroup(compactions: 3, sessions: 3),
                                    UsageCompactionGroup(compactions: 5, sessions: 1), UsageCompactionGroup(compactions: 11, sessions: 1)],
                      sessions: sessions)
    }()

    /// Today by the hour up to 16:00, the 16 o'clock bar in progress.
    static let todayReport: UsageReport = {
        let outputs = [0, 0, 0, 0, 0, 0, 0, 0, 0, 120_000, 310_000, 280_000, 90_000, 260_000, 320_000, 410_000, 150_000]
        let buckets = outputs.enumerated().map { UsageBucket(start: hour($0.offset), output: $0.element) }
        let usual = outputs.indices.map { UsageBucket(start: hour($0), output: $0 < 9 ? 0 : 180_000) }
        return report(.today, buckets: buckets, usual: usual,
                      totals: UsageTokens(output: outputs.reduce(0, +), cacheRead: 500_000_000, cacheCreation: 9_000_000, input: 9_000, responses: 940),
                      activeDays: 1, projects: [rank("notes-app", 1_200_000), rank("blog", 740_000)], models: [rank("model-a", 1_940_000)],
                      sessions: [session(1, project: "notes-app", output: 900_000, rewritten: 2_000_000, compactions: 0)])
    }()

    /// Thirty days, no comparison: the 30 days before were not kept.
    static let month: UsageReport = {
        let buckets = (0..<30).map { UsageBucket(start: day($0 - 29), output: $0 % 7 == 5 ? 0 : 600_000 + ($0 * 337_000) % 2_400_000) }
        return report(.month, buckets: buckets, usual: nil,
                      totals: UsageTokens(output: buckets.reduce(0) { $0 + $1.output }, cacheRead: 14_000_000_000, cacheCreation: 310_000_000,
                                          input: 410_000, responses: 48_210),
                      activeDays: 26, projects: Array(week.projects.prefix(4)), models: week.models,
                      rewritten: UsageRewrittenCache(tokens: 90_000_000, responses: 160, sessions: 31),
                      compactions: week.compactions, sessions: week.sessions)
    }()

    /// Two active days, no baseline.
    static let sparse: UsageReport = {
        let outputs = [0, 0, 0, 0, 0, 420_000, 180_000]
        let buckets = outputs.enumerated().map { UsageBucket(start: day($0.offset - 6), output: $0.element) }
        return report(.week, buckets: buckets, usual: nil,
                      totals: UsageTokens(output: 600_000, cacheRead: 90_000_000, cacheCreation: 4_000_000, input: 2_000, responses: 130),
                      activeDays: 2, projects: [rank("sandbox", 600_000)], models: [rank("model-a", 600_000)],
                      progress: UsageProgress(filesTotal: 6, filesRead: 6))
    }()

    /// Nothing today, responses earlier in the month.
    static let emptyPeriod: UsageReport = {
        let buckets = (0..<17).map { UsageBucket(start: hour($0), output: 0) }
        return report(.today, buckets: buckets, usual: nil, totals: UsageTokens(), activeDays: 0,
                      progress: UsageProgress(filesTotal: 40, filesRead: 40))
    }()

    static let none = report(.week, buckets: [], usual: nil, totals: UsageTokens(), activeDays: 0, progress: UsageProgress())

    static let reading: UsageReport = {
        var r = week
        r.computedAt = nil
        r.progress = UsageProgress(filesTotal: 412, filesRead: 180)
        return r
    }()
}

@MainActor private final class Shot {
    let window: NSWindow
    private let suite = "dashboard-render-\(UUID().uuidString)"

    let usage: UsageDashboard
    let advisor: UsageAdvisor

    init(_ report: UsageReport, month: UsageReport?, width: CGFloat, height: CGFloat, scale: Double, dark: Bool,
         scrolled: DashboardBlock? = nil) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(report.period.rawValue, forKey: UsageDashboard.periodKey)
        let usage = UsageDashboard(defaults: defaults, read: {}, answer: { $0 == .month ? month ?? report : report })
        usage.scrolled = scrolled
        self.usage = usage
        // the day's run is off, so a page is drawn the same whenever it is drawn
        defaults.set(false, forKey: UsageAdvisor.autoKey)
        let advisor = UsageAdvisor(defaults: defaults, store: UsageAdviceStore(path: NSTemporaryDirectory() + suite + "/advice.json"),
                                   run: { _ in .failure(UsageAdviceFailure(reason: "a render test ran the analysis")) })
        self.advisor = advisor
        let view = DashboardView(usage: usage, advisor: advisor, openProject: { _ in }, openSession: { $0.hasSuffix("s2.jsonl") ? nil : {} },
                                 sessionTitle: { $0.hasSuffix("s1.jsonl") ? "parser 속도 개선" : nil })
            .environment(\.boardFontScale, scale)
            .frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
        window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: width, height: height), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: view)
    }

    func settle() async throws {
        for _ in 0..<10 {
            window.contentView!.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    func bitmap() throws -> NSBitmapImageRep {
        let v = window.contentView!
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep
    }

    func tables() -> [NSTableView] {
        func all(_ v: NSView) -> [NSTableView] { ((v as? NSTableView).map { [$0] } ?? []) + v.subviews.flatMap(all) }
        return all(window.contentView!)
    }

    /// How far the page is scrolled down.
    func offset() -> CGFloat {
        func all(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(all) }
        return all(window.contentView!).map { $0.contentView.bounds.minY }.max() ?? 0
    }

    func close() {
        window.contentView = nil
        UserDefaults().removePersistentDomain(forName: suite)
    }
}

private func isFlat(_ rep: NSBitmapImageRep) -> Bool {
    var lo: CGFloat = 1, hi: CGFloat = 0
    for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let l = (c.redComponent + c.greenComponent + c.blueComponent) / 3
            lo = min(lo, l); hi = max(hi, l)
        }
    }
    return hi - lo < 0.15
}

/// Pixels of the page under the header that are a bar's color (blue or orange) and that are text (near black on
/// the light appearance).
private func ink(_ rep: NSBitmapImageRep) -> (colored: Int, dark: Int) {
    var colored = 0, dark = 0
    for y in stride(from: rep.pixelsHigh / 14, to: rep.pixelsHigh, by: 2) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let parts = [c.redComponent, c.greenComponent, c.blueComponent]
            if parts.max()! - parts.min()! > 0.35 { colored += 1 } else if parts.max()! < 0.35 { dark += 1 }
        }
    }
    return (colored, dark)
}

@MainActor private func ink(of report: UsageReport) async throws -> (colored: Int, dark: Int) {
    let shot = Shot(report, month: nil, width: 840, height: 1400, scale: 1, dark: false)
    defer { shot.close() }
    try await shot.settle()
    return ink(try shot.bitmap())
}

/// A half-read period's bars and numbers would read as its values (R12 S3): the page keeps its sizes and shows none.
@MainActor @Test func aFirstReadingDrawsNoBarAndNoValue() async throws {
    let shown = try await ink(of: DashboardSamples.week)
    let reading = try await ink(of: DashboardSamples.reading)
    #expect(shown.colored > 500, "the finished page has its bars: \(shown)")
    #expect(reading.colored == 0, "no bar of a half-read period: \(reading)")
    #expect(reading.dark * 3 < shown.dark, "only the titles stay as text: \(reading) against \(shown)")
}

/// The detail view is built again each time the dashboard is selected: the page comes back where it was left (R12 L2).
@MainActor @Test func aPageBuiltAgainIsScrolledWhereItWasLeft() async throws {
    let shot = Shot(DashboardSamples.week, month: nil, width: 400, height: 500, scale: 1, dark: false, scrolled: .section(.leaks))
    defer { shot.close() }
    try await shot.settle()
    #expect(shot.offset() > 300, "the 새는 곳 group is past the first 500 pt of a one-column page")
    #expect(shot.usage.scrolled == .section(.leaks))
}

private struct ShotCase {
    var name: String
    var report: UsageReport
    var width: CGFloat
    var scale: Double
    var dark: Bool
    /// The first line of each list picked, as a click would.
    var selectFirstRows = false
    /// What the last 30 days hold when the report's own period holds nothing.
    var month: UsageReport?

    var file: String { "\(name)-\(dark ? "dark" : "light")-w\(Int(width))-s\(String(format: "%.1f", scale)).png" }
}

private let cases: [ShotCase] = {
    var all: [ShotCase] = []
    for dark in [false, true] {
        for width in [400.0, 840, 1560] {
            for scale in [0.8, 1.0, 2.0] { all.append(ShotCase(name: "normal", report: DashboardSamples.week, width: width, scale: scale, dark: dark)) }
        }
    }
    return all + [
        ShotCase(name: "today", report: DashboardSamples.todayReport, width: 840, scale: 1, dark: true),
        ShotCase(name: "month", report: DashboardSamples.month, width: 1560, scale: 2, dark: false),
        ShotCase(name: "none", report: DashboardSamples.none, width: 840, scale: 1, dark: true),
        ShotCase(name: "reading", report: DashboardSamples.reading, width: 840, scale: 1, dark: false),
        ShotCase(name: "sparse", report: DashboardSamples.sparse, width: 840, scale: 1, dark: false),
        ShotCase(name: "empty-period", report: DashboardSamples.emptyPeriod, width: 840, scale: 1, dark: true, month: DashboardSamples.month),
        ShotCase(name: "selected", report: DashboardSamples.week, width: 1560, scale: 1, dark: false, selectFirstRows: true),
        ShotCase(name: "selected", report: DashboardSamples.week, width: 1560, scale: 1, dark: true, selectFirstRows: true),
    ]
}()

@MainActor @Test func everyDashboardCaseDrawsSomething() async throws {
    let dir = ProcessInfo.processInfo.environment["CT_DASHBOARD_SHOTS"].map { URL(fileURLWithPath: $0) }
    if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    for c in cases {
        let shot = Shot(c.report, month: c.month, width: c.width, height: c.width < 600 ? 2800 : 1400, scale: c.scale, dark: c.dark)
        try await shot.settle()
        if c.selectFirstRows {
            shot.tables().forEach { $0.selectRowIndexes([0], byExtendingSelection: false) }
            try await shot.settle()
        }
        let rep = try shot.bitmap()
        #expect(!isFlat(rep), "\(c.file) is one flat color")
        if let dir { try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(c.file)) }
        shot.close()
    }
}

/// The rows and columns a hover changed, in points: the rule is 1 pt wide, so only the text's box makes a row or a
/// column with 12 changed points in it.
private func changedBox(_ before: NSBitmapImageRep, _ after: NSBitmapImageRep) -> CGSize {
    let per = CGFloat(after.pixelsWide) / after.size.width
    var rows = [Int](repeating: 0, count: after.pixelsHigh), columns = [Int](repeating: 0, count: after.pixelsWide)
    let a = before.bitmapData!, b = after.bitmapData!, step = after.bitsPerPixel / 8
    for y in 0..<after.pixelsHigh where memcmp(a + y * after.bytesPerRow, b + y * after.bytesPerRow, after.bytesPerRow) != 0 {
        for x in 0..<after.pixelsWide where memcmp(a + y * after.bytesPerRow + x * step, b + y * after.bytesPerRow + x * step, step) != 0 {
            rows[y] += 1
            columns[x] += 1
        }
    }
    let least = Int(12 * per)
    return CGSize(width: CGFloat(columns.filter { $0 >= least }.count) / per, height: CGFloat(rows.filter { $0 >= least }.count) / per)
}

/// A bar's text under the pointer is drawn whole: the highest bar and both end bars of each period, at 2.0 and in a
/// narrow window too (T200). With CT_DASHBOARD_SHOTS each is written as hover-….png.
@MainActor @Test func aHoveredBarsTextIsDrawnWhole() async throws {
    let dir = ProcessInfo.processInfo.environment["CT_DASHBOARD_SHOTS"].map { URL(fileURLWithPath: $0) }
    if let dir { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    let reports = [("today", DashboardSamples.todayReport), ("week", DashboardSamples.week), ("month", DashboardSamples.month)]
    for (name, report) in reports {
        for (width, scale) in [(840.0, 1.0), (840, 2), (400, 1), (400, 2)] {
            let shot = Shot(report, month: nil, width: width, height: 700, scale: scale, dark: false)
            defer { shot.close() }
            try await shot.settle()
            let plain = try shot.bitmap()
            let highest = report.buckets.max { $0.output < $1.output }!
            for (which, bucket) in [("first", report.buckets.first!), ("highest", highest), ("last", report.buckets.last!)] {
                shot.usage.hoveredBar = bucket.start
                try await shot.settle()
                let rep = try shot.bitmap()
                let file = "hover-\(name)-\(which)-w\(Int(width))-s\(String(format: "%.1f", scale)).png"
                if let dir { try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(file)) }
                let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize * scale)
                let text = (bucketHoverText(bucket, period: report.period) as NSString).size(withAttributes: [.font: font])
                let box = changedBox(plain, rep)
                #expect(box.width >= text.width + 8 && box.height >= text.height + 2, "\(file): \(box) for a text of \(text)")
            }
        }
    }
}
