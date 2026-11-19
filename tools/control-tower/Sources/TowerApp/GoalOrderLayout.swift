import Foundation
import TowerCore

// The task board's 순서 view (T214; design design/goal-order-view.md, T211): what each goal, wave and card says, in
// what order, and the 목표·선행·후행 lines of a task's detail. The app only reads the order (`my-team api goal-order`).

/// The task board's two views of one board (design §1). Kept per team in `TaskPanelPrefs.view`.
enum TaskBoardMode: String, CaseIterable {
    case panels, order

    var label: String { self == .panels ? "상태별" : "순서" }
    var menuTitle: String { self == .panels ? "상태별로 보기" : "순서로 보기" }
    var symbol: String { self == .panels ? "square.stack" : "list.number" }

    /// The stored view, as the window shows it: 순서 only where my-team can answer it (an older one has no
    /// goal-order, design §3); the stored value itself is kept.
    static func shown(stored: String?, supported: Bool) -> TaskBoardMode {
        supported ? TaskBoardMode(rawValue: stored ?? "") ?? .panels : .panels
    }
}

// MARK: - Refs

/// `T181` → `T181`, `T181:1` → `T181 할 일 1`, `T177:4-7` → `T177 할 일 4–7` (design §2 대기 문구).
func goalRefLabel(_ ref: String) -> String {
    let (task, items) = splitRef(ref)
    return items.map { "\(task) 할 일 \($0.replacingOccurrences(of: "-", with: "–"))" } ?? task
}

/// The same for VoiceOver: `4–7` reads as "4 대시 7", so `4에서 7` (design §2 VoiceOver).
func goalRefSpoken(_ ref: String) -> String {
    let (task, items) = splitRef(ref)
    return items.map { "\(task) 할 일 \(spokenRange($0))" } ?? task
}

/// `할 일 4–7` for a node's items, nil for a whole task.
func itemsLabel(_ items: [Int]?) -> String? {
    guard let items, let first = items.first, let last = items.last else { return nil }
    return first == last ? "할 일 \(first)" : "할 일 \(first)–\(last)"
}

private func itemsSpoken(_ items: [Int]?) -> String? {
    guard let items, let first = items.first, let last = items.last else { return nil }
    return first == last ? "할 일 \(first)" : "할 일 \(first)에서 \(last)"
}

private func splitRef(_ ref: String) -> (task: String, items: String?) {
    guard let i = ref.firstIndex(of: ":") else { return (ref, nil) }
    return (String(ref[..<i]), String(ref[ref.index(after: i)...]))
}

private func spokenRange(_ items: String) -> String {
    let parts = items.split(separator: "-")
    return parts.count == 2 ? "\(parts[0])에서 \(parts[1])" : items
}

// MARK: - Cards

/// A card's status line (design §2 카드 표).
enum GoalCardLine: Equatable {
    /// `ready_now` and the task not started (`new`, `ready`): `ready_now` covers under way tasks too.
    case startable
    /// `ready_now` and under way: the task's state name.
    case state(String)
    /// The predecessors not complete yet; `cancelled` the refs whose task was cancelled.
    case waiting(refs: [String], cancelled: Set<String>)
    case done
    case cancelled
    case unregistered

    init(_ n: GoalNode) {
        if n.status == "unregistered" || n.state == nil { self = .unregistered; return }
        if n.state == "cancelled" || n.status == "cancelled" { self = .cancelled; return }
        switch n.status {
        case "done": self = .done
        case "waiting":
            self = .waiting(refs: n.blockedBy.map(\.ref), cancelled: Set(n.blockedBy.filter { $0.state == "cancelled" }.map(\.ref)))
        case "ready_now": self = ["new", "ready"].contains(n.state ?? "") ? .startable : .state(n.state ?? "")
        default: self = n.state == "done" ? .done : .state(n.state ?? n.status)
        }
    }

    /// `지금 시작 가능`, `진행 중`, `대기: T177, T181`, `대기: T179 (취소됨)`, `완료`, `취소됨`, `작업판에 없음`. More than
    /// three predecessors read as `대기: T177, T181 외 2`; `full` lists them all (the tooltip).
    func text(full: Bool = false) -> String {
        switch self {
        case .startable: "지금 시작 가능"
        case .state(let s): TaskStateStyle.of(s).label
        case .waiting(let refs, let cancelled):
            "대기: " + listed(refs.map { goalRefLabel($0) + (cancelled.contains($0) ? " (취소됨)" : "") }, full: full)
        case .done: "완료"
        case .cancelled: "취소됨"
        case .unregistered: "작업판에 없음"
        }
    }

    var spoken: String {
        switch self {
        case .waiting(let refs, let cancelled):
            "대기: " + refs.map { goalRefSpoken($0) + (cancelled.contains($0) ? " 취소됨" : "") }.joined(separator: ", ")
        default: text(full: true)
        }
    }

    /// A predecessor was cancelled: the order cannot go on until pm changes it (design §2, R4 S1).
    var blockedByCancelled: Bool { if case .waiting(_, let c) = self { !c.isEmpty } else { false } }

    /// Where the card stands in its wave (design §2 열 안 카드 순서).
    var rank: Int {
        switch self {
        case .startable: 0
        case .state: 1
        case .waiting: 2
        case .done: 4
        case .cancelled: 5
        case .unregistered: 6
        }
    }
}

private func listed(_ items: [String], full: Bool) -> String {
    guard !full, items.count > 3 else { return items.joined(separator: ", ") }
    return items.prefix(2).joined(separator: ", ") + " 외 \(items.count - 2)"
}

/// A wave's cards, in the order they are drawn: by status line, then by ref.
func waveCards(_ wave: [GoalNode]) -> [GoalNode] {
    wave.sorted { a, b in
        let (x, y) = (GoalCardLine(a).rank, GoalCardLine(b).rank)
        return x != y ? x < y : a.ref.localizedStandardCompare(b.ref) == .orderedAscending
    }
}

/// `T177 할 일 4에서 7, 대시보드 화면, 시작 전, 지금 시작 가능` (design §2 VoiceOver).
func goalCardSpoken(_ n: GoalNode) -> String {
    let head = [n.task, itemsSpoken(n.items)].compactMap { $0 }.joined(separator: " ")
    let state = n.state.map { TaskStateStyle.of($0).label }
    let line = GoalCardLine(n).spoken
    // a status line that only names the state (진행 중, 완료) is not read twice
    return [head, n.title, state, line == state ? nil : line].compactMap { $0 }.joined(separator: ", ")
}

// MARK: - Waves

/// A wave's head: `단계 2`, `2/3`. Done counts complete and cancelled nodes; the check is for a wave all complete.
struct WaveHead: Equatable {
    var number: Int
    var closed: Int
    var total: Int
    var allComplete: Bool

    init(_ wave: [GoalNode], number: Int) {
        let lines = wave.map(GoalCardLine.init)
        self.number = number
        closed = lines.filter { $0 == .done || $0 == .cancelled }.count
        total = wave.count
        allComplete = !lines.isEmpty && lines.allSatisfy { $0 == .done }
    }

    var count: String { "\(closed)/\(total)" }
    var spoken: String { "단계 \(number), 작업 \(total)개 중 \(closed)개 완료" }
}

/// The waves stand side by side only when every one fits at its least width, else they all stack (design §2 좁은 창).
func wavesStack(waves: Int, width: CGFloat, scale: CGFloat) -> Bool {
    let column = waveColumnWidth * scale
    return CGFloat(waves) * column + CGFloat(max(0, waves - 1)) * waveSpacing > width
}

let waveColumnWidth: CGFloat = 200
let waveSpacing: CGFloat = 12

// MARK: - Goals

/// What a goal's head says at its right end, and where the goal stands among the others (design §2 목표 구역, §3).
enum GoalTag: Equatable {
    case cycle
    case noOrder
    /// Syntax errors left nothing to draw.
    case unreadable
    case cancelledPredecessor(Int)
    case startable(Int)
    case underWay(Int)
    case allDone

    init(_ g: GoalOrder) {
        if g.cycle != nil { self = .cycle; return }
        let nodes = g.waves.flatMap { $0 }
        if nodes.isEmpty { self = g.errors.isEmpty ? .noOrder : .unreadable; return }
        let lines = nodes.map(GoalCardLine.init)
        let blocked = lines.filter(\.blockedByCancelled).count
        if lines.allSatisfy({ $0 == .done || $0 == .cancelled }) { self = .allDone; return }
        if blocked > 0 { self = .cancelledPredecessor(blocked); return }
        let startable = lines.filter { $0 == .startable }.count
        if startable > 0 { self = .startable(startable); return }
        self = .underWay(lines.filter { if case .state = $0 { true } else { false } }.count)
    }

    var text: String {
        switch self {
        case .cycle: "순환"
        case .noOrder: "순서 없음"
        case .unreadable: "순서를 읽지 못함"
        case .cancelledPredecessor(let n): "취소된 선행 \(n)"
        case .startable(let n): "지금 시작 가능 \(n)"
        case .underWay(let n): "진행 중 \(n)"
        case .allDone: "모두 끝남"
        }
    }

    /// Goals with a task to start first, then the ones under way (a cycle or a cancelled predecessor too: pm has work
    /// there), then those without an order, then the ones all done.
    var group: Int {
        switch self {
        case .startable: 0
        case .underWay, .cancelledPredecessor, .cycle, .unreadable: 1
        case .noOrder: 2
        case .allDone: 3
        }
    }

    /// A tag that asks pm to act is drawn with a warning triangle, in orange.
    var warns: Bool {
        switch self {
        case .cycle, .cancelledPredecessor, .unreadable: true
        default: false
        }
    }
}

/// The goals as the view lists them.
func goalsInOrder(_ goals: [GoalOrder]) -> [GoalOrder] {
    goals.sorted { a, b in
        let (x, y) = (GoalTag(a).group, GoalTag(b).group)
        if x != y { return x < y }
        let c = a.id.localizedStandardCompare(b.id)
        return c != .orderedSame ? c == .orderedAscending : a.path < b.path
    }
}

/// A goal starts folded only when all its tasks are done; what the user folded or opened stays (by the goal's file).
func goalFolded(_ g: GoalOrder, stored: [String: Bool]) -> Bool {
    stored[g.path] ?? (GoalTag(g) == .allDone)
}

/// `목표 G3, 대시보드: 사용량·인사이트, 지금 시작 가능 1, 단계 5개`
func goalSpoken(_ g: GoalOrder) -> String {
    ["목표 \(g.id)", g.title, GoalTag(g).text, g.waves.isEmpty ? nil : "단계 \(g.waves.count)개"].compactMap { $0 }.joined(separator: ", ")
}

/// `순서 4번째 줄을 읽지 못함: expected …`, then `외 N` for the rest (design §3 문법 오류).
func goalErrorLine(_ errors: [GoalOrderError]) -> String? {
    guard let first = errors.first else { return nil }
    return "순서 \(first.line)번째 줄을 읽지 못함: \(first.reason)" + (errors.count > 1 ? " 외 \(errors.count - 1)" : "")
}

/// A card the search does not find is dimmed and stays in place; a goal none of whose cards it finds shows its head
/// only (design §2 검색). An empty query finds every card.
func goalCardMatches(_ n: GoalNode, query: String) -> Bool {
    let q = query.trimmingCharacters(in: .whitespaces)
    return q.isEmpty || [n.ref, n.task, n.title].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(q) }
}

// MARK: - Moving between cards (design §2 키보드)

enum CardMove { case up, down, left, right }

/// The card ↑↓ (within a wave) and ←→ (the next wave's card at the same height, else its last) go to from `at`,
/// as (wave, index) in the drawn order; nil at an edge.
func movedCard(_ at: (wave: Int, index: Int), _ move: CardMove, sizes: [Int]) -> (wave: Int, index: Int)? {
    switch move {
    case .up: return at.index > 0 ? (at.wave, at.index - 1) : nil
    case .down: return at.index + 1 < sizes[at.wave] ? (at.wave, at.index + 1) : nil
    case .left, .right:
        var w = at.wave + (move == .left ? -1 : 1)
        while w >= 0 && w < sizes.count && sizes[w] == 0 { w += move == .left ? -1 : 1 }
        guard w >= 0 && w < sizes.count else { return nil }
        return (w, min(at.index, sizes[w] - 1))
    }
}

// MARK: - A task's 목표·선행·후행 (design §4)

/// One link of a 선행 or 후행 line: the other task, and which items of either side the relation is about.
struct GoalRelation: Hashable {
    var task: String
    /// `할 일 4–7 · 할 일 1에서`: the waiting side's range, then the item it waits for (R4 L2); nil for whole tasks.
    var caption: String?
    var spoken: String?
}

/// The 목표·선행·후행 lines a task has in one goal.
struct GoalTaskLinks: Hashable {
    var goal: GoalOrder
    /// The first wave the task is in, from 1.
    var wave: Int
    var before: [GoalRelation]
    var after: [GoalRelation]

    /// `G3 대시보드: 사용량·인사이트 · 단계 3/5`
    var goalLine: String {
        [goal.id, goal.title].compactMap { $0 }.joined(separator: " ") + " · 단계 \(wave)/\(goal.waves.count)"
    }
}

/// Each goal whose order has `task`, with what it waits for and what waits for it. One relation reads the same from
/// both ends: `{the waiting side's range} · {the item waited for}에서`.
func goalLinks(of task: String, in goals: [GoalOrder]) -> [GoalTaskLinks] {
    goals.compactMap { g in
        let nodes = g.waves.flatMap { $0 }
        guard let wave = g.waves.firstIndex(where: { $0.contains { $0.task == task } }) else { return nil }
        var before: [GoalRelation] = [], after: [GoalRelation] = []
        for n in nodes {
            for p in n.after {
                if n.task == task, p.task != task { before.append(relation(other: p.task, waiting: n.items, waitedFor: p.items)) }
                if p.task == task, n.task != task { after.append(relation(other: n.task, waiting: n.items, waitedFor: p.items)) }
            }
        }
        return GoalTaskLinks(goal: g, wave: wave + 1, before: unique(before), after: unique(after))
    }
}

private func relation(other: String, waiting: [Int]?, waitedFor: [Int]?) -> GoalRelation {
    let shown = [itemsLabel(waiting), itemsLabel(waitedFor).map { "\($0)에서" }].compactMap { $0 }
    let spoken = [itemsSpoken(waiting), itemsSpoken(waitedFor).map { "\($0) 이후" }].compactMap { $0 }
    return GoalRelation(task: other, caption: shown.isEmpty ? nil : shown.joined(separator: " · "),
                        spoken: spoken.isEmpty ? nil : spoken.joined(separator: ", "))
}

private func unique(_ rs: [GoalRelation]) -> [GoalRelation] {
    var seen = Set<GoalRelation>()
    return rs.filter { seen.insert($0).inserted }
}
