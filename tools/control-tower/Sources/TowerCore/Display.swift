import Foundation

// The board's display rules, without any view code, so every UI
// shows the same order, labels and summaries.

/// A board card: a loose Session, or a my-team Worker (which can be dead).
public protocol Card {
    var session: Session { get }
    var isAlive: Bool { get }
    /// What the card is called: a worker's name, a loose session's directory.
    var cardName: String { get }
}

extension Session: Card {
    public var session: Session { self }
    public var isAlive: Bool { true }
    public var cardName: String { basename(cwd).nonEmpty ?? handle }

    /// A loose session's second line: a real title only (e.g. a Codex thread name),
    /// not Claude's derived `<cwd basename>-<hex>`.
    public var subtitle: String? {
        let sub = cleanTitle(title)
        return sub.isEmpty || sub.hasPrefix(cardName) ? nil : sub
    }
}

extension Worker: Card {
    public var isAlive: Bool { alive }
    public var cardName: String {
        workerName.nonEmpty ?? cleanTitle(session.title).nonEmpty ?? basename(session.cwd).nonEmpty ?? session.handle
    }
}

/// `12m`, `3h 5m`, `2d 4h`; '' when either side is missing.
public func elapsed(from: String?, to: String?) -> String {
    guard let a = parseISO(from), let b = parseISO(to) else { return "" }
    let m = max(0, Int(((b - a) / 60000).rounded(.down)))
    if m < 60 { return "\(m)m" }
    if m < 48 * 60 { return "\(m / 60)h \(m % 60)m" }
    return "\(m / 1440)d \((m % 1440) / 60)h"
}

/// my_turn first, then the oldest `since`; dead workers last. Stable.
public func sortCards<C: Card>(_ list: [C]) -> [C] {
    func key(_ c: C) -> (Int, Int, Double) {
        (c.isAlive ? 0 : 1, c.session.myTurn ? 0 : 1, parseISO(c.session.since) ?? .infinity)
    }
    return list.enumerated().sorted { a, b in
        let ka = key(a.element), kb = key(b.element)
        return ka != kb ? ka < kb : a.offset < b.offset
    }.map(\.element)
}

/// Pane titles carry a status glyph (`✳ `, spinner) before Claude's own task summary.
public func cleanTitle(_ title: String) -> String {
    title.replacing(#/^[^\p{L}\p{N}]+/#, with: "").trimmed
}

public func basename(_ path: String) -> String {
    var p = path
    while p.hasSuffix("/") { p.removeLast() }
    return p.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init).nonEmpty ?? path
}

/// `spool 1 · inbox 2 · awaiting reply 3 (50m)`; '' when every counter is zero.
public func mailSummary(_ workers: [Worker], at: String) -> String {
    let spool = workers.reduce(0) { $0 + $1.spool }
    let inbox = workers.reduce(0) { $0 + $1.inbox }
    let pending = workers.reduce(0) { $0 + $1.sentPending }
    var out: [String] = []
    if spool != 0 { out.append("spool \(spool)") }
    if inbox != 0 { out.append("inbox \(inbox)") }
    if pending != 0 {
        let t = elapsed(from: workers.compactMap { $0.oldestPendingAt.nonEmpty }.min(), to: at)
        out.append("awaiting reply \(pending)\(t.isEmpty ? "" : " (\(t))")")
    }
    return out.joined(separator: " · ")
}

/// What a team is doing in its own words: the orchestrator's status.json reason
/// and its last reply. Pane titles are left out because Claude names a pane after
/// the boot prompt. When the orchestrator has no reply, the most recently active
/// worker speaks. Both nil means nobody has reported yet.
public struct TeamSummary: Equatable, Sendable {
    public var reason: String?
    public var voice: Worker?
}

/// nil for a team without workers.
public func teamSummary(_ team: Team) -> TeamSummary? {
    guard let lead = team.workers.first(where: { $0.role == "orchestrator" }) ?? team.workers.first else { return nil }
    let recent = team.workers.filter { !$0.lastAssistant.isEmpty }
        .enumerated()
        .max { a, b in
            let ta = parseISO(a.element.since) ?? 0, tb = parseISO(b.element.since) ?? 0
            return ta != tb ? ta < tb : a.offset > b.offset
        }?.element
    return TeamSummary(reason: lead.stateFile?.reason.nonEmpty, voice: lead.lastAssistant.isEmpty ? recent : lead)
}

/// Teams with more my-turn workers first. Stable.
public func sortTeams(_ teams: [Team]) -> [Team] {
    let mine = { (t: Team) in t.workers.filter(\.myTurn).count }
    return teams.enumerated().sorted { a, b in
        let ma = mine(a.element), mb = mine(b.element)
        return ma != mb ? ma > mb : a.offset < b.offset
    }.map(\.element)
}

public func myTurnCount(_ board: Board) -> Int {
    board.teams.reduce(0) { $0 + $1.workers.filter(\.myTurn).count } + board.loose.filter(\.myTurn).count
}

/// Loose sessions per agent, Claude Code first, each sorted; an agent without sessions is left out.
public func looseColumns(_ board: Board) -> [(agent: AgentKind, sessions: [Session])] {
    [AgentKind.claude, .codex].compactMap { agent in
        let list = board.loose.filter { $0.agent == agent }
        return list.isEmpty ? nil : (agent, sortCards(list))
    }
}

/// How the board shows a session or worker. Highest priority first: a dead worker is stopped,
/// a permission prompt always needs the user, a worker that reported `done` stays done even on
/// its turn (unless a busy turn began after that report), then my turn, working, idle.
public enum WorkerDisplayState: Equatable, Sendable {
    case stopped
    /// A permission or trust prompt is on screen. Counted with `waitingForUser`.
    case permission(since: String?)
    case done(since: String?)
    case waitingForUser(since: String?)
    case working
    case idle(since: String?)

    public enum Kind: String, CaseIterable, Sendable {
        case stopped, done, waitingForUser, working, idle
    }

    public var kind: Kind {
        switch self {
        case .stopped: .stopped
        case .done: .done
        case .permission, .waitingForUser: .waitingForUser
        case .working: .working
        case .idle: .idle
        }
    }
}

/// A live session's state, no my-team report involved.
public func displayState(_ s: Session) -> WorkerDisplayState {
    if s.permissionPrompt { return .permission(since: s.since) }
    if s.myTurn { return .waitingForUser(since: s.since) }
    if s.status == .busy { return .working }
    return .idle(since: s.since)
}

public func displayState(_ w: Worker) -> WorkerDisplayState {
    if !w.alive { return .stopped }
    if w.permissionPrompt { return displayState(w.session) }
    if w.stateFile?.state == "done" {
        // For a busy session `since` is when the turn started; an unparseable time keeps done.
        let reported = parseISO(w.stateFile?.updatedAt), turnStart = parseISO(w.since)
        if w.status == .busy, !w.myTurn, let reported, let turnStart, reported < turnStart { return .working }
        return .done(since: w.stateFile?.updatedAt)
    }
    return displayState(w.session)
}

/// Worker count and how many are in each display state, stopped included.
public func stateCounts(_ team: Team) -> (total: Int, byKind: [WorkerDisplayState.Kind: Int]) {
    (team.workers.count, Dictionary(team.workers.map { (displayState($0).kind, 1) }, uniquingKeysWith: +))
}
