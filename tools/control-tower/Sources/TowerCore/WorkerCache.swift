import Foundation

/// One session's tokens over its whole life, read from the usage ledger (T232). `main` is the session's own
/// responses, interactive or sdk; `subagent` is its subagents'.
public struct UsageSessionTotals: Hashable, Sendable {
    public var main: UsageTokens
    public var subagent: UsageTokens
    public var compactions: Int
    public var rewrittenCache: Int

    public init(main: UsageTokens = UsageTokens(), subagent: UsageTokens = UsageTokens(), compactions: Int = 0, rewrittenCache: Int = 0) {
        self.main = main
        self.subagent = subagent
        self.compactions = compactions
        self.rewrittenCache = rewrittenCache
    }
}

/// cache read ÷ (input + cache creation + cache read); nil when nothing was sent.
public func cacheHitRate(_ t: UsageTokens) -> Double? {
    let sent = t.input + t.cacheCreation + t.cacheRead
    return sent > 0 ? Double(t.cacheRead) / Double(sent) : nil
}

/// "97.6%", never "100.0%" short of all; "—" when there is no rate.
public func cacheHitRateText(_ t: UsageTokens) -> String {
    guard let rate = cacheHitRate(t) else { return "—" }
    let tenths = (rate * 1000).rounded() / 10
    return String(format: "%.1f%%", rate < 1 ? min(tenths, 99.9) : tenths)
}

/// Fewer responses than this and the first cache creation weighs too much for a rate to mean anything.
public let cacheHitMinResponses = 20
/// Below this, with enough responses, a rate is low. A guess to tune (design §1).
public let cacheHitLowRate = 0.90

/// A rate worth a warning: enough responses and under `cacheHitLowRate`.
public func cacheHitIsLow(_ t: UsageTokens) -> Bool {
    guard t.responses >= cacheHitMinResponses, let rate = cacheHitRate(t) else { return false }
    return rate < cacheHitLowRate
}

/// What the dashboard can say of a running worker's cache.
public enum WorkerCacheState: Hashable, Sendable {
    case counted(UsageSessionTotals)
    /// A codex worker: no Claude usage to count.
    case codex
    /// No process record for the pane, so no transcript.
    case noSession
    /// The transcript has no response in the ledger yet.
    case noResponses
}

public func workerCacheState(_ worker: Worker, totals: [String: UsageSessionTotals]) -> WorkerCacheState {
    if worker.session.agent == .codex { return .codex }
    guard let transcript = worker.session.transcript else { return .noSession }
    return totals[transcript].map(WorkerCacheState.counted) ?? .noResponses
}
