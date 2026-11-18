import Foundation
import os

// Every number counts an API response once, however many transcript lines and files it is in.

/// What the dashboard looks at: today so far, the last 7 days, the last 30 days. Each ends now and includes today.
public enum UsagePeriod: String, Codable, Sendable, CaseIterable {
    case today, week, month
}

/// Token sums of a set of responses. `input` is the uncached input only: nearly all input is `cacheRead`.
public struct UsageTokens: Codable, Hashable, Sendable {
    public var output: Int
    public var cacheRead: Int
    public var cacheCreation: Int
    public var input: Int
    public var responses: Int

    public init(output: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0, input: Int = 0, responses: Int = 0) {
        self.output = output
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
        self.input = input
        self.responses = responses
    }

    public static func += (a: inout UsageTokens, b: UsageTokens) {
        a.output += b.output
        a.cacheRead += b.cacheRead
        a.cacheCreation += b.cacheCreation
        a.input += b.input
        a.responses += b.responses
    }
}

/// Where a response came from. interactive: a session started in a terminal, entrypoint `cli` (a my-team worker's
/// too). subagent: a file under the session's `subagents/`. sdk: a session started any other way, `claude -p` and
/// the SDK among them.
public enum UsageKind: String, Codable, Sendable, CaseIterable {
    case interactive, subagent, sdk
}

/// One bar of the chart: the output tokens of the hour (today) or the day (week, month) that starts at `start`,
/// in the user's time zone.
public struct UsageBucket: Codable, Hashable, Sendable {
    public var start: Date
    public var output: Int

    public init(start: Date, output: Int) {
        self.start = start
        self.output = output
    }
}

/// What the period's output is compared with, and whether there was enough history to compare.
public struct UsageBaseline: Codable, Hashable, Sendable {
    public enum Basis: String, Codable, Sendable {
        /// today: the average of the last 7 days, each up to this time of day
        case sameTimeLast7Days
        /// week: the average week of the 4 weeks before it
        case weeklyAverageLast4Weeks
        /// month: the 30 days before it
        case previous30Days

        /// How many days the basis looks at.
        public var spanDays: Int {
            switch self {
            case .sameTimeLast7Days: 7
            case .weeklyAverageLast4Weeks: 28
            case .previous30Days: 30
            }
        }
    }

    public var basis: Basis
    /// The usual output for a period like this one. nil: no comparison, because `activeDays` is short of
    /// `requiredDays` or, for `previous30Days`, `coveredDays` is short of `spanDays`.
    public var output: Int?
    public var spanDays: Int { basis.spanDays }
    /// Of those, the days the ledger has in full. Claude Code deletes transcripts after 30 days, so the days more
    /// than 30 before the ledger's first reading are partial and left out of the comparison.
    public var coveredDays: Int
    /// Of `coveredDays`, the days with at least one response.
    public var activeDays: Int
    public var requiredDays: Int
    /// The usual level of each bar, the same starts as `UsageReport.buckets`. Empty when `output` is nil.
    public var buckets: [UsageBucket]

    /// Without `coveredDays` the whole span is covered.
    public init(basis: Basis, output: Int?, coveredDays: Int? = nil, activeDays: Int, requiredDays: Int, buckets: [UsageBucket]) {
        self.basis = basis
        self.output = output
        self.coveredDays = coveredDays ?? basis.spanDays
        self.activeDays = activeDays
        self.requiredDays = requiredDays
        self.buckets = buckets
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(basis, forKey: .basis)
        try c.encode(output, forKey: .output)
        try c.encode(coveredDays, forKey: .coveredDays)
        try c.encode(activeDays, forKey: .activeDays)
        try c.encode(requiredDays, forKey: .requiredDays)
        try c.encode(buckets, forKey: .buckets)
    }
}

/// One row of a ranking: a project or a model, with what its responses used. Rankings are largest output first.
public struct UsageRank: Codable, Hashable, Sendable {
    public var name: String
    public var tokens: UsageTokens

    public init(name: String, tokens: UsageTokens) {
        self.name = name
        self.tokens = tokens
    }
}

public struct UsageKindTotal: Codable, Hashable, Sendable {
    public var kind: UsageKind
    public var tokens: UsageTokens

    public init(kind: UsageKind, tokens: UsageTokens) {
        self.kind = kind
        self.tokens = tokens
    }
}

/// Cache written again after a pause: the `cacheCreation` of responses that came more than the cache's lifetime
/// after the response before them in the same session. Compare `tokens` with the period's `totals.cacheCreation`.
public struct UsageRewrittenCache: Codable, Hashable, Sendable {
    public var tokens: Int
    public var responses: Int
    public var sessions: Int

    public init(tokens: Int = 0, responses: Int = 0, sessions: Int = 0) {
        self.tokens = tokens
        self.responses = responses
        self.sessions = sessions
    }
}

/// How many sessions were compacted `compactions` times in the period. Sessions never compacted are not listed.
public struct UsageCompactionGroup: Codable, Hashable, Sendable {
    public var compactions: Int
    public var sessions: Int

    public init(compactions: Int, sessions: Int) {
        self.compactions = compactions
        self.sessions = sessions
    }
}

/// One session's share of the period, its subagents included. `transcriptPath` is the session's own file, the
/// same path as `HistorySession.transcriptPath`; the file may be gone when Claude Code has cleaned it up.
public struct UsageSession: Codable, Hashable, Sendable {
    public var transcriptPath: String
    public var project: String
    /// The session's last response in the period.
    public var lastActive: Date
    public var output: Int
    public var rewrittenCache: Int
    public var compactions: Int

    public init(transcriptPath: String, project: String, lastActive: Date, output: Int, rewrittenCache: Int, compactions: Int) {
        self.transcriptPath = transcriptPath
        self.project = project
        self.lastActive = lastActive
        self.output = output
        self.rewrittenCache = rewrittenCache
        self.compactions = compactions
    }
}

/// How far the reading under way is. While `filesRead < filesTotal` a report covers only what was read. Before the
/// first reading starts this is 0 of 0: `UsageReport.computedAt` is nil until one has finished.
public struct UsageProgress: Codable, Hashable, Sendable {
    public var filesTotal: Int
    public var filesRead: Int
    /// Transcripts the last reading could not open. The numbers lack what those files hold, and may keep lacking
    /// the part of it that is older than that reading even after the files can be read again.
    public var filesUnreadable: Int

    public init(filesTotal: Int = 0, filesRead: Int = 0, filesUnreadable: Int = 0) {
        self.filesTotal = filesTotal
        self.filesRead = filesRead
        self.filesUnreadable = filesUnreadable
    }

    public var done: Bool { filesRead >= filesTotal }
}

/// The dashboard's numbers for one period.
public struct UsageReport: Codable, Hashable, Sendable {
    public var period: UsagePeriod
    /// The period: from the start of its first day (today: of today) to `to`, the time the report was asked for.
    public var from: Date
    public var to: Date
    /// Every hour of today so far, or every day of the period, oldest first; an hour or day without responses is 0.
    public var buckets: [UsageBucket]
    public var totals: UsageTokens
    /// Days of the period with at least one response.
    public var activeDays: Int
    public var baseline: UsageBaseline
    public var projects: [UsageRank]
    public var models: [UsageRank]
    public var kinds: [UsageKindTotal]
    public var rewrittenCache: UsageRewrittenCache
    /// Fewest compactions first.
    public var compactions: [UsageCompactionGroup]
    /// Largest output first.
    public var sessions: [UsageSession]
    /// When the transcripts were last read to the end; nil before the first reading finishes.
    public var computedAt: Date?
    public var progress: UsageProgress

    public init(period: UsagePeriod, from: Date, to: Date, buckets: [UsageBucket], totals: UsageTokens, activeDays: Int,
                baseline: UsageBaseline, projects: [UsageRank], models: [UsageRank], kinds: [UsageKindTotal],
                rewrittenCache: UsageRewrittenCache, compactions: [UsageCompactionGroup], sessions: [UsageSession],
                computedAt: Date?, progress: UsageProgress) {
        self.period = period
        self.from = from
        self.to = to
        self.buckets = buckets
        self.totals = totals
        self.activeDays = activeDays
        self.baseline = baseline
        self.projects = projects
        self.models = models
        self.kinds = kinds
        self.rewrittenCache = rewrittenCache
        self.compactions = compactions
        self.sessions = sessions
        self.computedAt = computedAt
        self.progress = progress
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(period, forKey: .period)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        try c.encode(buckets, forKey: .buckets)
        try c.encode(totals, forKey: .totals)
        try c.encode(activeDays, forKey: .activeDays)
        try c.encode(baseline, forKey: .baseline)
        try c.encode(projects, forKey: .projects)
        try c.encode(models, forKey: .models)
        try c.encode(kinds, forKey: .kinds)
        try c.encode(rewrittenCache, forKey: .rewrittenCache)
        try c.encode(compactions, forKey: .compactions)
        try c.encode(sessions, forKey: .sessions)
        try c.encode(computedAt, forKey: .computedAt)
        try c.encode(progress, forKey: .progress)
    }
}

/// The user's Claude Code usage: reads the transcripts, keeps daily sums on disk, answers reports.
///
/// `refresh()` reads what is new since the last call and returns when it has; the first call reads every
/// transcript and takes seconds. `report(_:)` never reads a transcript: it answers from what `refresh()` has read
/// so far, so it can be called while a refresh runs, and `progress` says how complete the answer is.
public final class UsageLedger: Sendable {
    public static let shared = UsageLedger()

    private struct FileState {
        var offset = 0
        var lastID: String?
        var lastAt: Double?
        var kind: UsageKind?
    }

    private struct State {
        var loaded = false
        var refreshing = false
        var rows: [UsageRowKey: UsageRow] = [:]
        var compactions: [UsageCompactionKey: Int] = [:]
        var seen: [String: (key: UsageRowKey, output: Int)] = [:]
        var seenCompactions: Set<String> = []
        var files: [String: FileState] = [:]
        var projects: [String: String] = [:]
        var sessionsWithOwnProject: Set<String> = []
        var firstUnsealedHour: Int?
        var storedDays: Set<Int> = []
        /// Responses whose first line is in a sealed hour: a later line of one, in an hour that is not, is not a new response.
        var sealedResponses: Set<String> = []
        var dirtyDays: Set<Int> = []

        func isSealed(_ hour: Int) -> Bool {
            let beforeTheLastCompleteReading = firstUnsealedHour.map { hour < $0 } == true
            let itsDayWasSaved = storedDays.contains(hour / 24)
            return beforeTheLastCompleteReading && itsDayWasSaved
        }
        var since: Date?
        var computedAt: Date?
        var progress = UsageProgress()
    }

    private let projects: String
    private let store: UsageStore
    private let repoRoot: @Sendable (String) -> String?
    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    private let projectOfCwd = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// The transcripts under `CLAUDE_CONFIG_DIR` or `~/.claude`; the sums under the home's Application Support.
    public convenience init() {
        let env = ProcessInfo.processInfo.environment
        self.init(projects: HistoryRoots(env: env).claudeProjects,
                  store: homeDirectory(env) + "/Library/Application Support/ControlTower/usage/v1")
    }

    init(projects: String, store: String, repoRoot: @escaping @Sendable (String) -> String? = gitRepoRoot) {
        self.projects = projects
        self.store = UsageStore(dir: store)
        self.repoRoot = repoRoot
    }

    /// The stored days, once. A response is written to its transcript at its own time, so everything before the
    /// last complete reading is already in the store; a line with an older time that shows up later is a copy in
    /// a resumed or forked session's file. So hours before that reading (less one, for a response that was still
    /// growing) are taken from the store and never counted again, and later hours are read again from the files.
    ///
    /// What this loses: a transcript a reading could not open is skipped (`UsageProgress.filesUnreadable` counts
    /// it), the seal moves on without it, and once it can be read a later start takes its responses from before
    /// that reading for sealed and leaves them out. A session file deleted by hand takes with it what it held of
    /// the hours that are read again. And after the clock is set back, a run counts no response dated before the
    /// seal, the start of the hour before the one the last reading was in, on a day the store has; once a reading
    /// has run with the clock set right again, a later start takes those responses for sealed and leaves them out
    /// for good.
    // ponytail: read under the lock, by whichever of refresh and report comes first. Move it off if years of days
    // make a first report slow.
    private func load(_ s: inout State) {
        guard !s.loaded else { return }
        s.loaded = true
        let stored = store.state(), days = store.days()
        // without a readable state the stored days still stand: all but their last hour, which a quit cut short
        guard let sealed = stored.map({ $0.computedAt / 3600 - 1 }) ?? days.flatMap(\.rows).map(\.hour).max() else { return }
        s.firstUnsealedHour = sealed
        s.since = stored?.since.map { Date(timeIntervalSince1970: Double($0)) }
        for day in days {
            s.storedDays.formUnion(day.rows.map { $0.hour / 24 } + day.compactions.map { $0.hour / 24 })
            for r in day.rows where r.hour < sealed {
                s.rows[UsageRowKey(hour: r.hour, session: r.session, model: r.model, kind: r.kind)] = UsageRow(
                    tokens: UsageTokens(output: r.output, cacheRead: r.cacheRead, cacheCreation: r.cacheCreation,
                                        input: r.input, responses: r.responses),
                    rewrittenCache: r.rewrittenCache, rewrittenResponses: r.rewrittenResponses, last: r.last)
            }
            for c in day.compactions where c.hour < sealed {
                s.compactions[UsageCompactionKey(hour: c.hour, session: c.session)] = c.count
            }
            s.projects.merge(day.projects) { old, _ in old }
        }
    }

    private func project(cwd: String) -> String {
        if let known = projectOfCwd.withLock({ $0[cwd] }) { return known }
        let project = usageProject(cwd: cwd, repoRoot: repoRoot)
        projectOfCwd.withLock { $0[cwd] = project }
        return project
    }

    public func refresh(now: Date = Date()) async {
        let known: [String: FileState]? = state.withLock { s in
            guard !s.refreshing else { return nil }
            s.refreshing = true
            load(&s)
            return s.files
        }
        guard let known else { return }
        let pending = usageFiles(projects).filter { $0.size != known[$0.path]?.offset ?? 0 }
        state.withLock { $0.progress = UsageProgress(filesTotal: pending.count, filesRead: 0) }
        for file in pending {
            let from = known[file.path].map { $0.offset <= file.size ? $0.offset : 0 } ?? 0
            guard let chunk = Self.read(file.path, from: from) else {
                state.withLock { s in
                    s.progress.filesRead += 1
                    s.progress.filesUnreadable += 1
                }
                continue
            }
            let project = chunk.cwd.map(project(cwd:))
            state.withLock { s in
                apply(chunk, of: file, from: from, project: project, to: &s)
                s.progress.filesRead += 1
            }
        }
        let (days, stored) = state.withLock { s in
            s.computedAt = now
            s.since = s.since ?? now
            s.refreshing = false
            defer { s.dirtyDays = [] }
            return (s.dirtyDays.map { day($0, of: s) },
                    StoredUsageState(version: usageStoreVersion, computedAt: Int(now.timeIntervalSince1970),
                                     since: Int((s.since ?? now).timeIntervalSince1970)))
        }
        days.forEach(store.save)
        store.save(stored)
    }

    private static func read(_ path: String, from: Int) -> UsageChunk? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(from))
            return parseUsageChunk(try handle.readToEnd() ?? Data())
        } catch {
            return nil
        }
    }

    private func apply(_ chunk: UsageChunk, of file: UsageFile, from: Int, project: String?, to s: inout State) {
        var fs = from == 0 ? FileState() : s.files[file.path] ?? FileState()
        fs.offset = from + chunk.bytesThroughLastNewline
        if fs.kind == nil, chunk.entrypoint != nil || file.isSubagent {
            fs.kind = file.isSubagent ? .subagent : chunk.entrypoint == "cli" ? .interactive : .sdk
        }
        if let project, !s.sessionsWithOwnProject.contains(file.session), !file.isSubagent || s.projects[file.session] == nil {
            s.projects[file.session] = project
            if !file.isSubagent { s.sessionsWithOwnProject.insert(file.session) }
        }
        for event in chunk.events {
            switch event {
            case .response(let r):
                let hour = Int(r.at) / 3600
                var pause: Double?
                if fs.lastID != r.id {
                    pause = fs.lastAt.map { r.at - $0 }
                    fs.lastID = r.id
                    fs.lastAt = r.at
                }
                if let counted = s.seen[r.id] {
                    if r.output > counted.output {
                        s.rows[counted.key]?.tokens.output += r.output - counted.output
                        s.seen[r.id]?.output = r.output
                        s.dirtyDays.insert(counted.key.hour / 24)
                    }
                    continue
                }
                if s.sealedResponses.contains(r.id) { continue }
                if s.isSealed(hour) {
                    s.sealedResponses.insert(r.id)
                    continue
                }
                let key = UsageRowKey(hour: hour, session: file.session, model: r.model, kind: fs.kind ?? .sdk)
                var row = s.rows[key] ?? UsageRow()
                row.tokens += UsageTokens(output: r.output, cacheRead: r.cacheRead, cacheCreation: r.cacheCreation,
                                          input: r.input, responses: 1)
                row.last = max(row.last, Int(r.at))
                if r.cacheCreation > 0, let pause, pause > r.cacheLifetime {
                    row.rewrittenCache += r.cacheCreation
                    row.rewrittenResponses += 1
                }
                s.rows[key] = row
                s.seen[r.id] = (key, r.output)
                s.dirtyDays.insert(hour / 24)
            case .compaction(let uuid, let at):
                let hour = Int(at) / 3600
                guard s.seenCompactions.insert(uuid).inserted else { continue }
                if s.isSealed(hour) { continue }
                s.compactions[UsageCompactionKey(hour: hour, session: file.session), default: 0] += 1
                s.dirtyDays.insert(hour / 24)
            }
        }
        s.files[file.path] = fs
    }

    private func day(_ day: Int, of s: State) -> StoredUsageDay {
        let rows = s.rows.filter { $0.key.hour / 24 == day }
            .sorted { a, b in (a.key.hour, a.key.session, a.key.model, a.key.kind.rawValue) < (b.key.hour, b.key.session, b.key.model, b.key.kind.rawValue) }
        let compactions = s.compactions.filter { $0.key.hour / 24 == day }.sorted { a, b in (a.key.hour, a.key.session) < (b.key.hour, b.key.session) }
        let sessions = Set(rows.map(\.key.session))
        return StoredUsageDay(
            version: usageStoreVersion, day: usageDayName(day),
            rows: rows.map { key, row in
                .init(hour: key.hour, session: key.session, model: key.model, kind: key.kind, output: row.tokens.output,
                      cacheRead: row.tokens.cacheRead, cacheCreation: row.tokens.cacheCreation, input: row.tokens.input,
                      responses: row.tokens.responses, rewrittenCache: row.rewrittenCache,
                      rewrittenResponses: row.rewrittenResponses, last: row.last)
            },
            compactions: compactions.map { .init(hour: $0.key.hour, session: $0.key.session, count: $0.value) },
            projects: s.projects.filter { sessions.contains($0.key) }
        )
    }

    public func report(_ period: UsagePeriod, now: Date = Date(), calendar: Calendar = .current) -> UsageReport {
        let s = state.withLock { s in
            load(&s)
            return s
        }
        return usageReport(period, now: now, calendar: calendar, rows: s.rows, compactions: s.compactions,
                           projects: s.projects, since: s.since, computedAt: s.computedAt, progress: s.progress)
    }
}
