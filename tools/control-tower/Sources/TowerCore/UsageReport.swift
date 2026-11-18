import Foundation

private let hourSeconds = 3600.0
// ponytail: Claude Code's default `cleanupPeriodDays`. Read the setting if users turn out to change it.
private let transcriptRetention = 30 * 24 * hourSeconds

func usageReport(_ period: UsagePeriod, now: Date, calendar: Calendar, rows: [UsageRowKey: UsageRow],
                 compactions: [UsageCompactionKey: Int], projects: [String: String], since: Date?, computedAt: Date?,
                 progress: UsageProgress) -> UsageReport {
    func start(_ hour: Int) -> Date { Date(timeIntervalSince1970: Double(hour) * hourSeconds) }
    func hour(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / hourSeconds).rounded(.down)) }
    func days(_ n: Int, from date: Date) -> Date { calendar.date(byAdding: .day, value: n, to: date) ?? date }

    let today = calendar.startOfDay(for: now)
    let from = switch period {
    case .today: today
    case .week: days(-6, from: today)
    case .month: days(-29, from: today)
    }

    var hourOutput: [Int: Int] = [:]
    var dayOutput: [Date: Int] = [:]
    var dayOfHour: [Int: Date] = [:]
    func day(_ hour: Int) -> Date {
        if let d = dayOfHour[hour] { return d }
        let d = calendar.startOfDay(for: start(hour))
        dayOfHour[hour] = d
        return d
    }
    for (key, row) in rows {
        hourOutput[key.hour, default: 0] += row.tokens.output
        dayOutput[day(key.hour), default: 0] += row.tokens.output
    }

    var totals = UsageTokens()
    var byProject: [String: UsageTokens] = [:], byModel: [String: UsageTokens] = [:], byKind: [UsageKind: UsageTokens] = [:]
    var rewritten = UsageRewrittenCache()
    var sessions: [String: UsageSession] = [:]
    var activeDays: Set<Date> = []
    for (key, row) in rows where start(key.hour) >= from && start(key.hour) <= now {
        let project = projects[key.session] ?? ""
        totals += row.tokens
        byProject[project, default: UsageTokens()] += row.tokens
        byModel[key.model, default: UsageTokens()] += row.tokens
        byKind[key.kind, default: UsageTokens()] += row.tokens
        rewritten.tokens += row.rewrittenCache
        rewritten.responses += row.rewrittenResponses
        activeDays.insert(day(key.hour))
        var session = sessions[key.session] ?? UsageSession(transcriptPath: key.session, project: project, lastActive: .distantPast,
                                                             output: 0, rewrittenCache: 0, compactions: 0)
        session.output += row.tokens.output
        session.rewrittenCache += row.rewrittenCache
        session.lastActive = max(session.lastActive, Date(timeIntervalSince1970: Double(row.last)))
        sessions[key.session] = session
    }
    rewritten.sessions = sessions.values.count { $0.rewrittenCache > 0 }

    var compacted: [String: Int] = [:]
    for (key, count) in compactions where start(key.hour) >= from && start(key.hour) <= now {
        compacted[key.session, default: 0] += count
    }
    // a session compacted in the period that answered nothing in it is not one of the period's sessions
    compacted = compacted.filter { sessions[$0.key] != nil }
    for (session, count) in compacted { sessions[session]?.compactions = count }

    let buckets: [UsageBucket] = switch period {
    case .today: (hour(from)...hour(now)).map { UsageBucket(start: start($0), output: hourOutput[$0] ?? 0) }
    case .week, .month: (0..<(period == .week ? 7 : 30)).map { i in
            let d = days(i, from: from)
            return UsageBucket(start: d, output: dayOutput[d] ?? 0)
        }
    }

    func inFull(_ day: Date) -> Bool {
        since.map { day > $0.addingTimeInterval(-transcriptRetention) } ?? false
    }
    func span(_ range: Range<Int>) -> (output: Int, active: Int, days: Int) {
        let there = range.map { days($0, from: from) }.filter(inFull)
        let outputs = there.compactMap { dayOutput[$0] }
        return (outputs.reduce(0, +), outputs.count, there.count)
    }
    let baseline: UsageBaseline
    switch period {
    case .today:
        let elapsed = now.timeIntervalSince(from)
        let nowHour = hour(now), fraction = (now.timeIntervalSince1970 - Double(nowHour) * hourSeconds) / hourSeconds
        let usual: [[Int]] = (1...7).compactMap { back in
            let d = days(-back, from: from)
            guard dayOutput[d] != nil, inFull(d) else { return nil }
            let first = hour(d), last = hour(d.addingTimeInterval(elapsed))
            return (first...max(first, last)).map { hourOutput[$0] ?? 0 }
        }
        if usual.count >= 3 {
            let upToNow = usual.map { hours in
                Double(hours.dropLast().reduce(0, +)) + Double(hours.last ?? 0) * fraction
            }
            baseline = UsageBaseline(
                basis: .sameTimeLast7Days, output: Int(upToNow.reduce(0, +) / Double(usual.count)), coveredDays: span(-7..<0).days, activeDays: usual.count,
                requiredDays: 3,
                buckets: buckets.enumerated().map { i, b in
                    UsageBucket(start: b.start, output: usual.map { i < $0.count ? $0[i] : 0 }.reduce(0, +) / usual.count)
                })
        } else {
            baseline = UsageBaseline(basis: .sameTimeLast7Days, output: nil, coveredDays: span(-7..<0).days,
                                     activeDays: usual.count, requiredDays: 3, buckets: [])
        }
    case .week:
        let before = span(-28..<0)
        let output = before.active >= 14 ? before.output * 7 / before.days : nil
        baseline = UsageBaseline(basis: .weeklyAverageLast4Weeks, output: output, coveredDays: before.days,
                                 activeDays: before.active, requiredDays: 14,
                                 buckets: output.map { o in buckets.map { UsageBucket(start: $0.start, output: o / 7) } } ?? [])
    case .month:
        let before = span(-30..<0)
        let output = before.days == 30 && before.active >= 1 ? before.output : nil
        baseline = UsageBaseline(basis: .previous30Days, output: output, coveredDays: before.days,
                                 activeDays: before.active, requiredDays: 1,
                                 buckets: output.map { o in buckets.map { UsageBucket(start: $0.start, output: o / 30) } } ?? [])
    }

    func ranking(_ sums: [String: UsageTokens]) -> [UsageRank] {
        sums.map { UsageRank(name: $0.key, tokens: $0.value) }
            .sorted { a, b in a.tokens.output != b.tokens.output ? a.tokens.output > b.tokens.output : a.name < b.name }
    }
    return UsageReport(
        period: period, from: from, to: now, buckets: buckets, totals: totals, activeDays: activeDays.count, baseline: baseline,
        projects: ranking(byProject), models: ranking(byModel),
        kinds: UsageKind.allCases.compactMap { kind in byKind[kind].map { UsageKindTotal(kind: kind, tokens: $0) } },
        rewrittenCache: rewritten,
        compactions: Dictionary(grouping: compacted.values, by: { $0 }).map { UsageCompactionGroup(compactions: $0.key, sessions: $0.value.count) }
            .sorted { $0.compactions < $1.compactions },
        sessions: sessions.values.sorted { a, b in a.output != b.output ? a.output > b.output : a.transcriptPath < b.transcriptPath },
        computedAt: computedAt, progress: progress
    )
}
