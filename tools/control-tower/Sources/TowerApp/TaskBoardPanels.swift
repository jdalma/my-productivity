import AppKit
import SwiftUI
import TowerCore
import UniformTypeIdentifiers

// The task list as panels by state (T152; design: task-board-visual-v4.md §7, task-board-visual-v4-hig.md §7).
// A scroll view of boxes, not a `List`: picking, the arrows, the selection's colors and VoiceOver's reading are made
// here (hig §7.3).

/// How a panel looks (v4 §7.8): its icon, name and color. The done panel is gray (S2).
struct TaskPanelStyle {
    var label: String
    var symbol: String
    var color: Color

    static func of(_ p: TaskPanel) -> TaskPanelStyle {
        switch p {
        case .start: TaskPanelStyle(label: "시작 전", symbol: "circle", color: TaskColor.gray)
        case .decisions: TaskPanelStyle(label: "사용자 결정", symbol: "person.fill.questionmark", color: TaskColor.pink)
        case .doing: TaskPanelStyle(label: "진행 중", symbol: "circle.lefthalf.filled", color: TaskColor.blue)
        case .review: TaskPanelStyle(label: "리뷰 중", symbol: "eye.circle.fill", color: TaskColor.purple)
        case .held: TaskPanelStyle(label: "보류", symbol: "pause.circle.fill", color: TaskColor.red)
        case .done: TaskPanelStyle(label: "끝남", symbol: "checkmark.circle.fill", color: TaskColor.gray)
        }
    }

    /// The head's tint, and a tag's.
    static let bandOpacity = 0.15
    static let tagOpacity = 0.16
}

// MARK: - Words (pure: tested)

/// What a line is within its panel (S1): the word its panel's head counts.
func lineKind(_ t: TaskBoardTask) -> String {
    switch t.state {
    case "waiting": "결정 대기"
    case "new": "담당 없음"
    case "ready": "배정됨"
    case "doing": "작업 중"
    case "changes": "수정 요청"
    case "review": "리뷰 중"
    case "held": "보류"
    case "done": "끝남"
    case "cancelled": "취소됨"
    default: TaskStateStyle.of(t.state).label
    }
}

private let kindOrder = ["담당 없음", "배정됨", "작업 중", "수정 요청", "결정 대기", "리뷰 중", "보류", "끝남", "취소됨"]

/// The kinds a line shows a tag for (S1): the others are what its panel says, a wait has its decision's tag and an
/// unassigned task pm's.
let taggedKinds: Set = ["수정 요청", "취소됨"]

/// A panel head's breakdown (v4 §7.5 S1), `작업 중 3 · 수정 요청 1 · 결정 대기 1`; nothing when every line is one kind.
func panelBreakdown(_ lines: [TaskLine]) -> String {
    let counts = Dictionary(grouping: lines, by: { lineKind($0.task) }).mapValues(\.count)
    guard counts.count > 1 else { return "" }
    return counts.sorted { (kindOrder.firstIndex(of: $0.key) ?? 99, $0.key) < (kindOrder.firstIndex(of: $1.key) ?? 99, $1.key) }
        .map { "\($0.key) \($0.value)" }.joined(separator: " · ")
}

/// A line's `pm 차례` tag (S2): what pm has to do.
func pmTurnText(_ r: ActionReason) -> String {
    switch r {
    case .held: "pm 차례 · 풀거나 취소"
    case .unassigned: "pm 차례 · 담당 정하기"
    case .openFindings: "pm 정리"
    case .incompleteReview(let missing):
        "pm 차례 · " + withParticle(missing.map { ["ticket_path": "티켓", "constraints": "제약"][$0] ?? $0 }.joined(separator: ", "), "을", "를") + " 채움"
    }
}

/// A line's to-do items (v4 §7.2): done of the ticket's, or only the done when the ticket's are unknown; nothing for a
/// task over or with nothing to show.
func todoProgress(_ t: TaskBoardTask, total: Int?) -> (done: Int, total: Int)? {
    guard !["done", "cancelled"].contains(t.state) else { return nil }
    let done = Set(t.progressSummary?.doneItems ?? []).count
    if let total, total > 0 { return (min(done, total), total) }
    return done > 0 ? (done, 0) : nil
}

/// All the to-do done and not submitted yet (v4 §7.2 `제출 직전`).
func nearlySubmitted(_ t: TaskBoardTask, total: Int?) -> Bool {
    t.state == "doing" && todoProgress(t, total: total).map { $0.total > 0 && $0.done == $0.total } == true
}

/// `할 일 4/6`, or `할 일 2개 끝남`.
func todoText(_ p: (done: Int, total: Int)) -> String {
    p.total > 0 ? "할 일 \(p.done)/\(p.total)" : "할 일 \(p.done)개 끝남"
}

/// A line's second line in a wide panel (v4 §7.2): the last progress record, its time and who wrote it first.
func lastRecord(_ t: TaskBoardTask) -> String? {
    guard let s = t.progressSummary, let note = s.lastNote, !note.isEmpty else { return nil }
    let at = parseISO(s.lastAt).map { boardClock(Date(timeIntervalSince1970: $0 / 1000)) }
    return [at, t.history?.lastProgressBy, note.split(whereSeparator: \.isNewline).joined(separator: " ")].compactMap { $0 }.joined(separator: " · ")
}

/// `↺ 수정 2회`: how often a review sent the task back (T157); nil when it never did, or the board does not say.
func reworkText(_ t: TaskBoardTask) -> String? {
    t.history.flatMap { $0.changes > 0 ? "↺ 수정 \($0.changes)회" : nil }
}

/// `3차 제출`: which submission is under review (T157); nil outside a review, or when the board does not say.
func submissionOrdinal(_ t: TaskBoardTask) -> String? {
    t.state == "review" ? t.history.flatMap { $0.landings > 0 ? "\($0.landings)차 제출" : nil } : nil
}

/// What an event was, said of who did it: `core가 3차 제출`, `reviewer가 수정 요청`.
func eventText(_ e: TaskEvent, landings: Int) -> String {
    let what: String
    switch (e.action, e.verdict) {
    case ("add", _): what = "등록"
    case ("assign", _): what = "배정"
    case ("take", _): what = e.stateFrom == "changes" ? "고치기 시작" : "시작"
    case ("land", _): what = landings > 0 ? "\(landings)차 제출" : "제출"
    case ("verdict", "approve"?): what = "승인"
    case ("verdict", "changes"?): what = "수정 요청"
    case ("verdict", "hold"?): what = "보류"
    case ("verdict", _): what = "판정"
    case ("wait", _): what = "사용자 결정 요청"
    case ("answer", _): what = "사용자 결정 기록"
    case ("cancel", _): what = "취소"
    default: what = e.action
    }
    return (e.by.map { subject($0) + " " } ?? "") + what
}

/// A line's second line when the last event came after the last progress record (v4 §7.2): `16:30 · core가 2차 제출`.
/// None for a task that is over: its state and its time already say how it ended, and a line under each finished
/// task would double the height of the longest panel.
func lastEventLine(_ t: TaskBoardTask) -> String? {
    guard !["done", "cancelled"].contains(t.state), let e = eventAfterProgress(t) else { return nil }
    let at = parseISO(e.at).map { boardClock(Date(timeIntervalSince1970: $0 / 1000)) }
    return [at, eventText(e, landings: t.history?.landings ?? 0)].compactMap { $0 }.joined(separator: " · ")
}

/// A line's second line: the later of the last event and the last progress record.
func secondLine(_ t: TaskBoardTask) -> String? { lastEventLine(t) ?? lastRecord(t) }

/// The words of a step (v4 §7.2).
let stepText: [TaskStep: String] = [.registered: "등록", .assigned: "배정", .working: "작업", .review: "리뷰", .done: "끝"]

/// Where a task is among the steps, in words: `단계 작업`, or for a cancelled task where it stopped, `리뷰 단계에서 멈춤`;
/// `단계 모름` and `멈춘 단계 모름` when the board does not say. The one place these words are made (R19 L1): VoiceOver
/// and the step dots' tooltip both say this, so "stopped" is said of a cancelled task only, in both.
func stepPhrase(_ t: TaskBoardTask) -> String {
    let step = taskStep(t).flatMap { stepText[$0] }
    if t.state == "cancelled" { return step.map { "\($0) 단계에서 멈춤" } ?? "멈춘 단계 모름" }
    return step.map { "단계 \($0)" } ?? "단계 모름"
}

/// What a folded panel's head still says (v4 §7.7): its lines' warnings, gathered. `nearly` counts the lines all
/// done and not submitted.
func foldedSummary(_ p: TaskPanel, lines: [TaskLine], decisions: [BoardDecision], nearly: Int = 0, now: Date) -> [String] {
    let pm = lines.filter { !$0.reasons.isEmpty }.count
    let longest = lines.compactMap { elapsedMinutes($0.task, now: now) }.max().map { "가장 오래 \(shortDuration(minutes: $0))째" }
    switch p {
    case .start, .held: return [pm > 0 ? "pm 차례 \(pm)" : nil, longest].compactMap { $0 }
    case .decisions:
        guard let d = decisions.first else { return [] }
        let waited = parseISO(d.brief.askedAt).map { shortDuration(minutes: max(0, Int((now.timeIntervalSince1970 * 1000 - $0) / 60_000))) + "째" }
        return [questionHead(d.brief.question), waited].compactMap { $0 }.filter { !$0.isEmpty }
    case .doing:
        let waits = lines.filter { !$0.decisions.isEmpty }.count
        let top = lines.flatMap(\.severities).min { (severityRanks[$0.severity] ?? 3) < (severityRanks[$1.severity] ?? 3) }?.severity
        let topCount = top.map { s in lines.flatMap(\.severities).filter { $0.severity == s }.map(\.count).reduce(0, +) }
        return [waits > 0 ? "결정 대기 \(waits)" : nil, top.flatMap { s in topCount.map { severityCount(s, $0) } },
                nearly > 0 ? "제출 직전 \(nearly)" : nil].compactMap { $0 }
    case .review: return [longest].compactMap { $0 }
    case .done: return pm > 0 ? ["pm 정리 \(pm)"] : []
    }
}

private let severityRanks = ["must": 0, "should": 1, "low": 2]

/// What VoiceOver says after a line's title (H6): where it is, how far it has come, who holds it, its tags and its
/// last record.
func taskAccessibilityValue(_ line: TaskLine, now: Date, todoTotal: Int? = nil) -> String {
    let t = line.task
    var parts: [String] = []
    if line.child, let parent = t.parentId { parts.append("\(parent)의 하위 작업") }
    parts.append([lineKind(t), taskTime(t, now: now)].filter { !$0.isEmpty }.joined(separator: ", "))
    parts.append(stepPhrase(t))
    if let n = t.history?.changes, n > 0 { parts.append("수정 요청 \(n)회") }
    if let nth = submissionOrdinal(t) { parts.append(nth) }
    if let p = todoProgress(t, total: todoTotal) { parts.append(todoText(p)) }
    parts.append(["담당 \(t.assignee ?? "없음")", t.reviewer.map { "리뷰어 \($0)" }].compactMap { $0 }.joined(separator: ", "))
    if !line.decisions.isEmpty { parts.append("결정 \(line.decisions.joined(separator: ", ")) 대기") }
    if !line.severities.isEmpty { parts.append("열린 지적 \(severityCounts(line.severities))") }
    parts += line.reasons.map(pmTurnText)
    if nearlySubmitted(t, total: todoTotal) { parts.append("제출 직전") }
    if let e = lastEventLine(t) { parts.append("마지막 사건 \(e)") } else if let r = lastRecord(t) { parts.append("마지막 기록 \(r)") }
    return parts.joined(separator: ". ")
}

// MARK: - The list

/// What a panel's or a line's drag carries: this app's own type, seen only by this app, so a drop here takes nothing
/// from another app and Finder makes no clipping of it (R17 S1, L5).
let boardItemType = UTType(exportedAs: "local.control-tower.board-item")

func boardItem(_ id: String) -> NSItemProvider {
    let item = NSItemProvider()
    item.registerDataRepresentation(forTypeIdentifier: boardItemType.identifier, visibility: .ownProcess) { done in
        done(Data(id.utf8), nil)
        return nil
    }
    return item
}

/// What is being dragged in the list (hig §8.2): a panel by its head, or a task's line within its panel. Kept here
/// because a drop target cannot read the dragged item before it is dropped.
enum PanelDragging: Equatable {
    case panel(TaskPanel)
    case line(TaskPanel, String)
}

/// Where a drop would go: before the panel at a slot of a column on screen or before the line at an index of a
/// panel's lines, each drawn as a line; or a new column past the last, drawn as a strip.
enum PanelDropMark: Equatable {
    case panel(column: Int, slot: Int)
    case newColumn
    case line(TaskPanel, Int)
}

/// `6개 중 4번째`, or with columns on screen `2단 중 1번째 단, 3개 중 2번째` (hig §7.4): where a panel is, for VoiceOver.
func panelPlaceText(_ p: TaskPanel, in prefs: TaskPanelPrefs, room: Int) -> String {
    let cols = prefs.shownColumns(room: room)
    guard let c = cols.firstIndex(where: { $0.contains(p) }), let i = cols[c].firstIndex(of: p) else { return "" }
    let row = "\(cols[c].count)개 중 \(i + 1)번째"
    return cols.count > 1 ? "\(cols.count)단 중 \(c + 1)번째 단, \(row)" : row
}

/// What a menu's move scrolls to (R17a S1).
enum Follow: Equatable {
    case none
    case line(String)
    case panel(TaskPanel)
}

/// How far a panel with its own height is scrolled inside. Only `MoreBelow` reads it, so a scroll redraws that label
/// and not the list (R17a L3).
@MainActor @Observable final class InnerScroll {
    var offset: CGFloat = 0
}

/// The `↓ n개 더` band's height at a font scale: fixed, so what it covers is known before it is drawn (T168).
func moreBelowBand(scale: CGFloat) -> CGFloat { 20 * scale }

/// The rule `↓ n개 더` counts by (T168, R24 L1): a line is hidden below when its bottom is past the visible part, the
/// panel's height less the band's strip under it, by more than half a point. A line cut at the strip, however little,
/// is hidden; so are the ones past it. Scrolled to the end, the last line's bottom is the visible part's, and the
/// count is 0 there (R22 L1).
func linesBelow(bottoms: [CGFloat], offset: CGFloat, height: CGFloat, band: CGFloat) -> Int {
    bottoms.filter { $0 > offset + height - band + 0.5 }.count
}

/// The lines whole on screen by the same rule: top not above the scroll, bottom not past the visible part. With the
/// lines cut at the top, they and `linesBelow` add up to every line (T168).
func linesWhole(tops: [CGFloat], bottoms: [CGFloat], offset: CGFloat, height: CGFloat, band: CGFloat) -> Int {
    zip(tops, bottoms).filter { $0.0 >= offset - 0.5 && $0.1 <= offset + height - band + 0.5 }.count
}

/// A panel's lines in a height of their own (v4 §7.9.5): they scroll inside it, and `↓ n개 더` counts the lines
/// hidden below (`linesBelow`). A panel that shows up with a picked line in it scrolls to it (R17 S5).
private struct SizedLines<Content: View>: View {
    let height: CGFloat
    /// Each line's bottom in the lines' own space.
    let bottoms: [CGFloat]
    let ids: [String]
    let selected: String?
    /// A line the list scrolls to, as a menu's move does: its panel's inside follows it too (R17b L1).
    var request: (id: String, serial: Int) = ("", 0)
    @ViewBuilder let content: Content
    @State private var scroll = InnerScroll()
    @Environment(\.boardFontScale) private var fontScale

    var body: some View {
        let band = moreBelowBand(scale: fontScale)
        // the band has a strip of its own under the lines, not over them: what scrolls into view is whole in what
        // the count calls visible, a scroll to a line and the end of the scroll alike (T168, R22 L1)
        ScrollViewReader { inner in
            VStack(spacing: 0) {
                ScrollView {
                    content.background(ScrollOffsetProbe { [scroll] in scroll.offset = $0 })
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.visible)
                .frame(height: max(0, height - band))
                MoreBelow(scroll: scroll, bottoms: bottoms, height: height).frame(height: band)
            }
            .onChange(of: selected, initial: true) { _, id in
                if let id, ids.contains(id) { inner.scrollTo(id) }
            }
            .onChange(of: request.serial) {
                if ids.contains(request.id) { inner.scrollTo(request.id) }
            }
        }
    }
}

private struct MoreBelow: View {
    let scroll: InnerScroll
    let bottoms: [CGFloat]
    let height: CGFloat
    @Environment(\.boardFontScale) private var fontScale

    var body: some View {
        let band = moreBelowBand(scale: fontScale)
        let below = linesBelow(bottoms: bottoms, offset: scroll.offset, height: height, band: band)
        if below > 0 {
            Text("↓ \(below)개 더").scaledFont(.caption1, weight: .semibold).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
                .allowsHitTesting(false)
        } else {
            Color.clear
        }
    }
}

/// The column a box goes in, told to `PanelColumns`.
private struct PanelColumn: LayoutValueKey {
    static let defaultValue = 0
}

/// Columns of boxes side by side (v4 §7.8): as wide as each other, each as tall as its own boxes, 12 pt between two
/// boxes. The boxes come in reading order, each with its column.
private struct PanelColumns: Layout {
    let count: Int
    private let rowGap: CGFloat = 12

    private func columnWidth(_ width: CGFloat) -> CGFloat {
        max(0, (width - panelColumnGap * CGFloat(count - 1)) / CGFloat(max(count, 1)))
    }

    /// Each box's top in its column, and each column's height.
    private func tops(_ subviews: Subviews, width: CGFloat) -> (tops: [CGFloat], heights: [CGFloat]) {
        var heights = [CGFloat](repeating: 0, count: max(count, 1)), tops: [CGFloat] = []
        for v in subviews {
            let c = min(max(v[PanelColumn.self], 0), heights.count - 1)
            let top = heights[c] == 0 ? 0 : heights[c] + rowGap
            tops.append(top)
            heights[c] = top + v.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        return (tops, heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? CGFloat(count) * panelColumnWidth
        return CGSize(width: width, height: tops(subviews, width: columnWidth(width)).heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = columnWidth(bounds.width), at = tops(subviews, width: w).tops
        for (v, top) in zip(subviews, at) {
            let c = min(max(v[PanelColumn.self], 0), max(count, 1) - 1)
            v.place(at: CGPoint(x: bounds.minX + CGFloat(c) * (w + panelColumnGap), y: bounds.minY + top),
                    proposal: ProposedViewSize(width: w, height: nil))
        }
    }
}

/// The panels in their places, each a box with its lines (v4 §7.8, §7.9): columns side by side while the list has
/// room for them, else one column in reading order (T154).
struct TaskPanelList: View {
    let team: String
    let status: TaskBoardStatus
    let query: String
    let now: Date
    let selected: String?
    let pick: (String?) -> Void
    @Binding var prefs: TaskPanelPrefs
    @Binding var doneOpen: Bool
    @Binding var pastOpen: Bool
    /// The panel whose head the user last worked: the 보기 › 묶음 menu's target (pm 6).
    @Binding var headTarget: TaskPanel?
    /// A layout change the user can take back with ⌘Z, under its name.
    let arrange: (TaskPanelPrefs, String) -> Void
    /// A new value scrolls to what a layout change moved: the picked line, else the panel last worked (R17 L4).
    var moveRequest = 0
    /// The to-do count of each ticket read so far, by path.
    let todoTotals: [String: Int]
    let workerRow: (String?) -> LiveRow?
    let select: (RowID) -> Void
    /// A new value scrolls to the decisions panel (the toolbar's 결정 button).
    var decisionsRequest = 0
    /// How many columns the list has room for, told to the window for its 보기 › 묶음 menu (T154).
    @Binding var columnRoom: Int
    @FocusState private var focused: Bool
    @State private var dragging: PanelDragging?
    @State private var dropMark: PanelDropMark?
    /// Measured: each box, each line, each panel's lines together, each head; the lines' tops in their panel's scroll.
    @State private var boxHeights: [TaskPanel: CGFloat] = [:]
    @State private var lineHeights: [String: CGFloat] = [:]
    @State private var contentHeights: [TaskPanel: CGFloat] = [:]
    @State private var headHeights: [TaskPanel: CGFloat] = [:]
    /// Each line's bottom in its panel's lines, for `↓ n개 더` (T168).
    @State private var lineBottoms: [String: CGFloat] = [:]
    /// A move from a panel's or a line's menu, to scroll to what moved (R17a S1).
    @State private var follow: (target: Follow, serial: Int) = (.none, 0)
    /// Each drag's number: a drag that ends clears only itself, not one started right after (R17a L2).
    @State private var dragSerial = 0
    /// The last line the list scrolled to, for the panel it is in to follow inside (R17b L1).
    @State private var innerRequest: (id: String, serial: Int) = ("", 0)
    @State private var listHeight: CGFloat = 0
    /// A height being dragged, and where the drag started.
    @State private var liveHeight: (panel: TaskPanel, height: CGFloat, base: CGFloat)?
    /// The panel whose bottom edge set the resize cursor, to take it back once (R17 L3), and the edge under the
    /// pointer: the cursor stays while either holds, so a drag past the edge keeps it (R17a L5).
    @State private var resizeCursor: TaskPanel?
    @State private var handleHover: TaskPanel?
    @Environment(\.controlActiveState) private var active
    @Environment(\.boardFontScale) private var scale

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let panels = taskPanels(status)
        let found = panels.mapValues { $0.filter { taskMatches($0, query: query, findings: status.openFindings) } }
        let arranged = Dictionary(uniqueKeysWithValues: found.map { p, ls in (p, prefs.arranging(ls, in: p)) })
        let open = openDecisions(status).filter { decisionMatches($0, query: query) }
        let past = pastDecisions(status).filter { decisionMatches($0, query: query) }
        let shownPast = showsPast(past)
        let order = prefs.order
        let ids = visibleIds(order: order, panels: arranged.mapValues { $0.top + $0.rest },
                             decisions: open.map(\.id) + (shownPast ? past.map(\.id) : []),
                             prefs: prefs, searching: searching, doneOpen: doneOpen)
        GeometryReader { geo in
            // by the list's own width, so a detail opened beside it takes columns away (T154 item 4)
            let room = panelColumnsFitting(width: geo.size.width - 24, scale: scale)
            let columns = prefs.shownColumns(room: room)
            let columnWidth = (geo.size.width - 24 - panelColumnGap * CGFloat(columns.count - 1)) / CGFloat(columns.count)
            let compact = columnWidth < 760 * scale
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let a = status.announcements.last { announcement(a) }
                        if prefs.hasLayout {
                            HStack {
                                Spacer()
                                link("↺ 배치 되돌리기", subject: "작업판") { arrange(prefs.resetLayout, "기본 배치로 되돌리기") }
                                    .help("영역 순서, 직접 올린 작업, 영역 높이를 처음으로. 접힘은 그대로")
                            }
                            .padding(.bottom, -8)
                        }
                        // the columns are as wide as each other and as tall as their own panels; the list scrolls as one.
                        // Every box is a child of the one layout, known by its panel alone: moved to another column it
                        // is the same view, and what it holds (how far its lines are scrolled) stays (R21 L3)
                        PanelColumns(count: columns.count) {
                            ForEach(order, id: \.self) { p in
                                let c = columns.firstIndex { $0.contains(p) } ?? 0
                                let i = columns[c].firstIndex(of: p) ?? 0
                                box(p, column: c, index: i, all: panels[p] ?? [], arranged: arranged[p] ?? ([], []),
                                    found: found[p] ?? [], open: open, past: past, compact: compact)
                                    .overlay(alignment: .top) {
                                        if dropMark == .panel(column: c, slot: i) { dropLine(full: true).offset(y: -7) }
                                    }
                                    .overlay(alignment: .bottom) {
                                        if i == columns[c].count - 1, dropMark == .panel(column: c, slot: columns[c].count) {
                                            dropLine(full: true).offset(y: 7)
                                        }
                                    }
                                    .layoutValue(key: PanelColumn.self, value: c)
                                    .id(p)
                            }
                        }
                    }
                    .padding(12)
                }
                // over the list's own frame, not its content: its words stay on screen however long the list (R21 L2)
                .overlay(alignment: .trailing) { if makesColumn(room: room) { newColumnStrip().padding(12) } }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.upArrow) { move(ids, -1) }
                .onKeyPress(.downArrow) { move(ids, 1) }
                .onChange(of: decisionsRequest) { withAnimation { proxy.scrollTo(TaskPanel.decisions, anchor: .top) } }
                .onChange(of: moveRequest) {
                    if let p = headTarget { proxy.scrollTo(p) } else if let id = selected { scroll(proxy, toLine: id) }
                }
                .onChange(of: follow.serial) {
                    switch follow.target {
                    case .line(let id): scroll(proxy, toLine: id)
                    case .panel(let p): proxy.scrollTo(p)
                    case .none: break
                    }
                }
                .onChange(of: selected, initial: true) { _, id in
                    guard let id else { return }
                    scroll(proxy, toLine: id)
                    headTarget = nil
                }
            }
            .onAppear { listHeight = geo.size.height }
            .onChange(of: geo.size.height) { _, h in listHeight = h }
            .onChange(of: room, initial: true) { _, n in columnRoom = n }
        }
        // ⌘C here is the system's Copy, which always writes the user's clipboard: off in the test instance (T97)
        .copyable(towerDryRun != nil ? [] : selected.flatMap { id in
            status.tasks.first { $0.id == id }.map { "\($0.id) \($0.title)" }
                ?? boardDecisions(status).first { $0.id == id }.map { "\($0.id) \($0.brief.question)" }
        }.map { [$0] } ?? [])
        .overlay {
            if status.tasks.isEmpty && boardDecisions(status).isEmpty {
                ContentUnavailableView("아직 작업이 없습니다", systemImage: "tray", description: Text("pm이 작업을 등록하면 여기에 보입니다"))
            }
        }
    }

    /// A line on screen: one in a panel with its own height, that panel first; its own scroll does the rest.
    private func scroll(_ proxy: ScrollViewProxy, toLine id: String) {
        if let t = status.tasks.first(where: { $0.id == id }), prefs.height(panel(of: t)) != nil {
            proxy.scrollTo(panel(of: t))
            innerRequest = (id, innerRequest.serial + 1)
        } else {
            proxy.scrollTo(id)
        }
    }

    private func followMove(_ target: Follow) { follow = (target, follow.serial + 1) }

    /// 지난 결정 show once asked for in an unfolded panel, and while a search finds some.
    private func showsPast(_ past: [BoardDecision]) -> Bool {
        !past.isEmpty && (searching || (pastOpen && !prefs.isFolded(.decisions)))
    }

    private func move(_ ids: [String], _ by: Int) -> KeyPress.Result {
        guard let next = step(ids, from: selected, by: by) else { return .ignored }
        pick(next)
        return .handled
    }

    /// The latest announcement, one line at the top (v4 §7.4); all of them are in the team overview.
    private func announcement(_ a: TaskBoardAnnouncement) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "megaphone.fill").foregroundStyle(.secondary)
            // its inline marks drawn, as the overview and the detail draw them (T153 item 0)
            Text(inlineMarkdown(a.body.split(whereSeparator: \.isNewline).joined(separator: " "))).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            Text("\(a.createdBy ?? "?") · \(relativeTime(a.createdAt, now: now))").foregroundStyle(.secondary).fixedSize()
        }
        .scaledFont(.callout)
        .padding(.horizontal, 10)
        .help(a.body)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("공지")
        .accessibilityValue(a.body)
    }

    /// Where a drop goes (hig §7.3): an accent line with a dot at its start, a panel's across the column, a line's from
    /// where its text starts (hig D12).
    private func dropLine(full: Bool) -> some View {
        HStack(spacing: 0) {
            Circle().stroke(Color.accentColor, lineWidth: 2).frame(width: 6, height: 6)
            Rectangle().fill(Color.accentColor).frame(height: 2)
        }
        .padding(.leading, full ? 0 : 28 * scale)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Panel

    /// While a panel is dragged and the list has room for one more column than it shows (v4 §7.8): not for a panel
    /// alone in its column, whose new column would be the one it has.
    private func makesColumn(room: Int) -> Bool {
        guard case .panel(let p) = dragging, prefs.layout.count < room else { return false }
        return prefs.dropping(p, column: prefs.layout.count, at: 0) != nil
    }

    /// Where a dragged panel is dropped to make a new column: a dashed strip over the list's trailing edge, as tall as
    /// what shows of the list, so nothing in the list moves while it shows.
    private func newColumnStrip() -> some View {
        let on = dropMark == .newColumn
        return Text("여기에 놓으면\n새 단").scaledFont(.callout, weight: .semibold).multilineTextAlignment(.center)
            .foregroundStyle(on ? Color.accentColor : .secondary)
            .frame(width: 110 * scale).frame(maxHeight: .infinity)
            .background((on ? Color.accentColor.opacity(0.15) : Color(nsColor: .windowBackgroundColor).opacity(0.92)), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Color.accentColor : Color.secondary,
                                                                       style: StrokeStyle(lineWidth: on ? 2 : 1, dash: [5, 4])))
            .onDrop(of: [boardItemType], delegate: NewColumnDrop(dragging: dragging, mark: $dropMark) { q in
                drop(panel: q, column: prefs.layout.count, at: 0)
            })
            .accessibilityHidden(true)
    }

    private func box(_ p: TaskPanel, column: Int, index: Int, all: [TaskLine], arranged: (top: [TaskLine], rest: [TaskLine]),
                     found: [TaskLine], open: [BoardDecision], past: [BoardDecision], compact: Bool) -> some View {
        let st = TaskPanelStyle.of(p)
        let count = p == .decisions ? openDecisions(status).count : all.count
        let shows = count > 0 && showsLines(open: !prefs.isFolded(p), query: query)
        let lines = arranged.top + arranged.rest
        let shownLines = p == .done && !(doneOpen || searching) ? Array(lines.prefix(finishedShown)) : lines
        let sized = sizedHeight(p)
        return VStack(alignment: .leading, spacing: 0) {
            head(p, st, count: count, all: all, open: open, past: past, shown: shows,
                 hiddenDone: lines.count - shownLines.count)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headHeights[p] = $0 }
            if shows || (p == .decisions && (count == 0 || showsPast(past))) {
                rows(p, column: column, index: index, count: count, top: arranged.top.count, lines: shownLines, open: open, past: past,
                     compact: compact, sized: sized)
            }
            if searching && count > 0 && (p == .decisions ? open.isEmpty && past.isEmpty : found.isEmpty) {
                emptyLine("찾은 것 없음")
            }
            if shows {
                // the lines on screen: the decisions' past ones too, when shown (R17a L1)
                heightHandle(p, sized: sized, lines: p == .decisions ? open.count + (showsPast(past) ? past.count : 0) : shownLines.count)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { st.color.frame(height: 3) }
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .modifier(IncreasedContrastBorder(color: st.color, radius: 10))
        .opacity(dragging == .panel(p) ? 0.35 : 1)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { boxHeights[p] = $0 }
        .onDrop(of: [boardItemType], delegate: PanelDrop(column: column, index: index, height: boxHeights[p] ?? 1, dragging: dragging,
                                                         mark: $dropMark, lands: { dropped($0, column: column, at: $1) != nil },
                                                         drop: { drop(panel: $0, column: column, at: $1) }))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(st.label)
    }

    /// The height a panel shows its lines in, in points at this font scale; nil fits them.
    private func sizedHeight(_ p: TaskPanel) -> CGFloat? {
        if let live = liveHeight, live.panel == p { return live.height }
        return prefs.height(p).map { CGFloat($0) * scale }
    }

    @ViewBuilder
    private func rows(_ p: TaskPanel, column: Int, index: Int, count: Int, top: Int, lines: [TaskLine], open: [BoardDecision],
                      past: [BoardDecision], compact: Bool, sized: CGFloat?) -> some View {
        let stack = VStack(alignment: .leading, spacing: 0) {
            if p == .decisions {
                if count == 0 && !searching { emptyLine("답을 기다리는 결정 없음") }
                decisionLines(open: prefs.isFolded(p) && !searching ? [] : open, past: showsPast(past) ? past : [])
            } else {
                ForEach(Array(lines.enumerated()), id: \.element.task.id) { i, line in
                    if i == top, top > 0 { pinnedDivider(p, count: top) }
                    lineRow(p, index: i, column: column, panelIndex: index, count: lines.count, top: top, line: line, pinned: i < top, compact: compact)
                }
            }
        }
        .padding(.bottom, 6)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeights[p] = $0 }
        if let sized {
            SizedLines(height: sized, bottoms: lines.map { lineBottoms[$0.task.id] ?? 0 }, ids: lines.map(\.task.id), selected: selected,
                       request: innerRequest) {
                stack.coordinateSpace(.named("lines-\(p.rawValue)"))
            }
        } else {
            stack
        }
    }

    /// The line between the tasks put on top and the rest (v4 §7.9.2).
    private func pinnedDivider(_ p: TaskPanel, count: Int) -> some View {
        HStack(spacing: 6) {
            Text("↑ 직접 올린 작업 \(count) · 아래는 기본 순서").scaledFont(.caption1).foregroundStyle(.secondary)
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            link("작업 순서 되돌리기", subject: TaskPanelStyle.of(p).label) { resetPins(p) }
        }
        .padding(.horizontal, 12).padding(.vertical, 2)
    }

    private func resetPins(_ p: TaskPanel) {
        var next = prefs
        for id in prefs.pins(p) { next = next.moving(task: id, in: p, .unpin) ?? next }
        arrange(next, "작업 순서 되돌리기")
    }

    private func lineRow(_ p: TaskPanel, index i: Int, column: Int, panelIndex: Int, count: Int, top: Int, line: TaskLine, pinned: Bool,
                         compact: Bool) -> some View {
        let id = line.task.id
        let movable = ordersLines(p) && !searching
        let items = taskMenuItems(line.task) + (movable ? TaskMove.allCases.map { .move($0) } : [])
        return selectable(id) {
            TaskPanelRow(line: line, team: team, now: now, todoTotal: todoTotal(line.task), compact: compact,
                         workerRow: workerRow, pinned: pinned)
                // the line's own bottom, not its pick's padding: whole means its words show (T168)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("lines-\(p.rawValue)")).maxY } action: { lineBottoms[id] = $0 }
        }
        .modifier(TaskActions(items: items, run: { run($0, line.task, in: p) }, can: { can($0, line.task, in: p) }))
        .opacity(dragging == .line(p, id) ? 0.35 : 1)
        .overlay(alignment: .top) { if dropMark == .line(p, i) { dropLine(full: false) } }
        .overlay(alignment: .bottom) { if i == count - 1, dropMark == .line(p, count) { dropLine(full: false) } }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lineHeights[id] = $0 }
        .modifier(LineDrag(enabled: movable, start: { begin(.line(p, id)) }, id: id))
        .onDrop(of: [boardItemType], delegate: LineDrop(panel: p, index: i, count: count, column: column, panelIndex: panelIndex,
                                                        height: lineHeights[id] ?? 1, dragging: dragging, mark: $dropMark,
                                                        landing: { landing($0, in: p, top: top, at: $1) },
                                                        drop: { drop(line: $0, in: p, at: $1) },
                                                        lands: { dropped($0, column: column, at: $1) != nil },
                                                        dropPanel: { drop(panel: $0, column: column, at: $1) }))
    }

    /// A drag starts: what is dragged is kept until the mouse button is up, dropped or not, cancelled or refused
    /// (R17 S1); SwiftUI tells the drop, not the end of the drag.
    private func begin(_ d: PanelDragging) {
        dragSerial += 1
        let mine = dragSerial
        dragging = d
        Task { @MainActor in
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(100)) }
            // a drop is told at the button's release too: let it go first
            try? await Task.sleep(for: .milliseconds(100))
            if dragSerial == mine { dragging = nil; dropMark = nil }
        }
    }

    /// The layout once `q` is dropped before slot `slot` of column `column` on screen; nil when nothing changes. With
    /// the columns shown as one for lack of room the slot is a place in the reading order, and the panel goes to the
    /// column of the panel it is put before (v4 §7.8).
    private func dropped(_ q: TaskPanel, column: Int, at slot: Int) -> TaskPanelPrefs? {
        prefs.layout.count <= columnRoom ? prefs.dropping(q, column: column, at: slot) : prefs.placing(q, at: slot)
    }

    private func drop(panel q: TaskPanel, column: Int, at slot: Int) {
        defer { dragging = nil; dropMark = nil }
        guard let next = dropped(q, column: column, at: slot) else { return }
        arrange(next, "묶음 이동")
        headTarget = q
        announcePanel(q, in: next, room: columnRoom)
    }

    /// A panel moved by its head's menu or VoiceOver: taken back with ⌘Z, its new place said, and the list scrolled to
    /// it (R17a S1). A drop does not scroll: the panel is where the pointer is.
    private func move(_ p: TaskPanel, to next: TaskPanelPrefs) {
        arrange(next, "묶음 이동")
        announcePanel(p, in: next, room: columnRoom)
        followMove(.panel(p))
    }

    private func drop(line id: String, in p: TaskPanel, at slot: Int) {
        defer { dragging = nil; dropMark = nil }
        guard let next = prefs.dropping(task: id, in: p, at: slot) else { return }
        arrange(next, "작업 순서 바꾸기")
        pick(id)
        announceTask(id, in: p, next)
    }

    /// Where the line for dropping `id` before line `slot` goes (R17 L2, v4 §7.9.1): where it will land, the end of
    /// the tasks on top for a line from the rest; nowhere when nothing would change.
    private func landing(_ id: String, in p: TaskPanel, top: Int, at slot: Int) -> Int? {
        guard prefs.dropping(task: id, in: p, at: slot) != nil else { return nil }
        return slot > top && !prefs.pins(p).contains(id) ? top : slot
    }

    /// The head (v4 §7.7, §7.8): fold mark, icon, name, count, breakdown, and once folded the lines' warnings. A click
    /// anywhere on it folds or unfolds; with Option, every panel. Dragged, it moves the panel; its menu does the same.
    private func head(_ p: TaskPanel, _ st: TaskPanelStyle, count: Int, all: [TaskLine], open: [BoardDecision],
                      past: [BoardDecision], shown: Bool, hiddenDone: Int) -> some View {
        let folded = prefs.isFolded(p)
        // a folded panel always unfolds; the decisions panel folds while it has past ones too (R9 S2)
        let foldable = count > 0 || folded || (p == .decisions && !past.isEmpty)
        let breakdown = panelBreakdown(all)
        let summary = folded && count > 0
            ? foldedSummary(p, lines: all, decisions: openDecisions(status), nearly: all.filter { nearlySubmitted($0.task, total: todoTotal($0.task)) }.count, now: now)
            : []
        let up = prefs.moving(p, by: -1, room: columnRoom)
        let down = prefs.moving(p, by: 1, room: columnRoom)
        let left = prefs.moving(p, toColumn: -1, room: columnRoom)
        let right = prefs.moving(p, toColumn: 1, room: columnRoom)
        let position = panelPlaceText(p, in: prefs, room: columnRoom)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                headTarget = p
                guard foldable else { return }
                if NSEvent.modifierFlags.contains(.option) {
                    for q in TaskPanel.allCases { prefs.setFolded(q, !folded) }
                } else {
                    prefs.setFolded(p, !folded)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: folded ? "chevron.right" : "chevron.down")
                        .scaledFont(.caption1, weight: .semibold).foregroundStyle(.secondary)
                        .frame(width: 12 * scale)
                        .opacity(foldable ? 1 : 0)
                    Image(systemName: st.symbol).foregroundStyle(st.color)
                    Text(st.label).fontWeight(.bold)
                    Text("\(count)").fontWeight(.bold).monospacedDigit().foregroundStyle(st.color)
                    if count == 0 && p != .decisions { Text("· 없음").foregroundStyle(.secondary) }
                    if !breakdown.isEmpty { Text("· " + breakdown).scaledFont(.callout).foregroundStyle(.secondary).lineLimit(1) }
                    ForEach(summary, id: \.self) { s in
                        Text(s).scaledFont(.caption1, weight: .semibold).lineLimit(1)
                            .foregroundStyle(p == .decisions ? TaskColor.pink : TaskColor.orange)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Capsule().strokeBorder(p == .decisions ? TaskColor.pink : TaskColor.orange))
                    }
                    Spacer(minLength: 8)
                }
                .scaledFont(.headline)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help((!foldable ? "" : folded ? "펼치기 (Option: 모두). " : "접기 (Option: 모두). ") + "끌어서 묶음 자리 바꾸기")
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel("\(st.label) \(count)")
            .accessibilityValue([breakdown, !foldable ? "" : folded ? "접힘" : "펼쳐짐", position, summary.joined(separator: ", ")]
                .filter { !$0.isEmpty }.joined(separator: ". "))
            // only the moves it can make, and then where it went (R17 L1)
            .accessibilityActions {
                if let up { Button("위로 옮기기") { move(p, to: up) } }
                if let down { Button("아래로 옮기기") { move(p, to: down) } }
                if let left { Button("왼쪽 단으로") { move(p, to: left) } }
                if let right { Button("오른쪽 단으로") { move(p, to: right) } }
            }
            if prefs.height(p) != nil {
                Text("높이 고정").scaledFont(.caption2, weight: .semibold).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
                    .help("두 번 눌러 자동 높이로")
                    .onTapGesture(count: 2) { arrange(prefs.setting(height: nil, for: p), "높이 자동으로") }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("\(st.label) 높이 고정")
                    .accessibilityAction(named: "높이 자동으로") { arrange(prefs.setting(height: nil, for: p), "높이 자동으로") }
            }
            if p == .done, shown, hiddenDone > 0 || doneOpen, !searching {
                link(doneOpen ? "최근 \(finishedShown)개만" : "모두 보기 (\(hiddenDone)개 더)", subject: st.label) { doneOpen.toggle() }
            }
            if p == .decisions, !past.isEmpty, !searching {
                let showing = pastOpen && !folded
                link(showing ? "지난 결정 숨기기" : "지난 결정 \(past.count)", subject: st.label) {
                    // shown in a folded panel too: the link opens it (R9 S2)
                    pastOpen = !showing
                    if !showing { prefs.setFolded(.decisions, false) }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(st.color.opacity(TaskPanelStyle.bandOpacity))
        .onDrag {
            begin(.panel(p))
            headTarget = p
            return boardItem(p.rawValue)
        } preview: {
            Label(st.label, systemImage: st.symbol).scaledFont(.headline).padding(.horizontal, 10).padding(.vertical, 6)
                .background(st.color.opacity(0.3), in: .rect(cornerRadius: 6))
        }
        .contextMenu {
            Button("\(st.label) 묶음을 위로") { if let up { move(p, to: up) } }.disabled(up == nil)
            Button("\(st.label) 묶음을 아래로") { if let down { move(p, to: down) } }.disabled(down == nil)
            Button("\(st.label) 묶음을 왼쪽 단으로") { if let left { move(p, to: left) } }.disabled(left == nil)
            Button("\(st.label) 묶음을 오른쪽 단으로") { if let right { move(p, to: right) } }.disabled(right == nil)
            Divider()
            Button("작업 순서 되돌리기") { resetPins(p) }.disabled(prefs.pins(p).isEmpty)
            Button("높이 자동으로") { arrange(prefs.setting(height: nil, for: p), "높이 자동으로") }.disabled(prefs.height(p) == nil)
            Divider()
            Button("기본 배치로 되돌리기") { arrange(prefs.resetLayout, "기본 배치로 되돌리기") }.disabled(!prefs.hasLayout)
        }
    }

    /// The panel's bottom edge (v4 §7.9.5, hig §8.3): dragged, the panel's height; twice clicked, its lines' height.
    /// `shown`: the lines on screen in the panel, so three of them is the least even for 끝남's last few or a search
    /// (R17 S4).
    private func heightHandle(_ p: TaskPanel, sized: CGFloat?, lines shown: Int) -> some View {
        let content = contentHeights[p] ?? 0
        let lines = max(1, shown)
        let least = content / CGFloat(lines) * CGFloat(min(lines, 3))
        let most = max(least, listHeight - (headHeights[p] ?? 0) - 24)
        return Color.clear
            .frame(height: 9)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .overlay {
                if let live = liveHeight, live.panel == p {
                    Text(TaskPanelPrefs.fitted(Double(live.height), least: Double(least), content: Double(content), most: Double(most))
                        .map { "높이 \(Int($0 / scale))pt" } ?? "자동 높이")
                        .scaledFont(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 10)
                }
            }
            .onHover { inside in
                if inside { handleHover = p } else if handleHover == p { handleHover = nil }
                syncResizeCursor()
            }
            .onDisappear {
                // folded or gone under the cursor: its cursor goes with it (R17 L3)
                if handleHover == p { handleHover = nil }
                if liveHeight?.panel == p { liveHeight = nil }
                syncResizeCursor()
            }
            // global: the edge moves down as the panel grows, which would halve a local drag (R17 S6)
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { g in
                    let base = liveHeight?.base ?? sized ?? content
                    liveHeight = (p, max(0, base + g.translation.height), base)
                    syncResizeCursor()
                }
                .onEnded { _ in
                    defer { liveHeight = nil; syncResizeCursor() }
                    guard let live = liveHeight else { return }
                    let h = TaskPanelPrefs.fitted(Double(live.height), least: Double(least), content: Double(content), most: Double(most))
                    arrange(prefs.setting(height: h.map { $0 / Double(scale) }, for: p), "높이 바꾸기")
                })
            .simultaneousGesture(TapGesture(count: 2).onEnded { arrange(prefs.setting(height: nil, for: p), "높이 자동으로") })
            .help("끌어서 높이 바꾸기 · 두 번 눌러 자동 높이")
            .accessibilityHidden(true)
    }

    /// The resize cursor while the pointer is on an edge or an edge is being dragged, set once and taken back once.
    private func syncResizeCursor() {
        let wanted = handleHover ?? liveHeight?.panel
        if let wanted, resizeCursor == nil {
            NSCursor.resizeUpDown.push()
            resizeCursor = wanted
        } else if wanted == nil, resizeCursor != nil {
            NSCursor.pop()
            resizeCursor = nil
        }
    }

    private func link(_ label: String, subject: String, _ run: @escaping () -> Void) -> some View {
        Button(label, action: run).buttonStyle(.link).scaledFont(.callout).fixedSize().accessibilityLabel("\(subject) \(label)")
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).scaledFont(.callout).foregroundStyle(.secondary).padding(.horizontal, 32).padding(.vertical, 6)
    }

    @ViewBuilder
    private func decisionLines(open: [BoardDecision], past: [BoardDecision]) -> some View {
        ForEach(open, id: \.id) { d in selectable(d.id) { DecisionRow(decision: d, tasks: status.tasks, team: team, now: now) } }
        if !past.isEmpty {
            Text("지난 결정").scaledFont(.callout, weight: .semibold).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 6).accessibilityAddTraits(.isHeader)
            ForEach(past, id: \.id) { d in selectable(d.id) { DecisionRow(decision: d, tasks: status.tasks, team: team, now: now) } }
        }
    }

    /// A line the user picks by a click or the arrows, in the selection's colors (hig §7.3): the accent while the
    /// list has the keyboard in the front window, gray otherwise, as a list's.
    private func selectable<Row: View>(_ id: String, @ViewBuilder _ row: () -> Row) -> some View {
        let on = selected == id
        let emphasized = on && focused && active == .key
        return row()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.backgroundProminence, emphasized ? .increased : .standard)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(emphasized ? Color(nsColor: .selectedContentBackgroundColor) : Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                }
            }
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                pick(id)
                headTarget = nil
                focused = true
            }
            .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
            .accessibilityAction { pick(id) }
            .id(id)
    }

    private func todoTotal(_ t: TaskBoardTask) -> Int? { t.ticketPath.flatMap { todoTotals[$0] } }

    private func can(_ item: TaskMenuItem, _ t: TaskBoardTask, in p: TaskPanel) -> Bool {
        switch item {
        case .showAssignee(let n), .showReviewer(let n): workerRow(n) != nil
        case .move(let m): prefs.moving(task: t.id, in: p, m) != nil
        default: true
        }
    }

    private func run(_ item: TaskMenuItem, _ t: TaskBoardTask, in p: TaskPanel) {
        switch item {
        case .copyTaskId: copy(t.id)
        case .copyTicketPath: copy(t.ticketPath ?? "")
        case .showAssignee(let n), .showReviewer(let n): if let row = workerRow(n) { select(row.id) }
        case .move(let m):
            guard let next = prefs.moving(task: t.id, in: p, m) else { return }
            arrange(next, "작업 순서 바꾸기")
            announceTask(t.id, in: p, next)
            followMove(.line(t.id))
        }
    }
}

/// A line's drag (hig §8.2): off for 끝남, the decisions and while a search runs.
private struct LineDrag: ViewModifier {
    let enabled: Bool
    let start: () -> Void
    let id: String

    func body(content: Content) -> some View {
        if enabled {
            content.onDrag {
                start()
                return boardItem(id)
            }
        } else {
            content
        }
    }
}

/// A panel as a drop target (hig §7.3): a panel dragged over its upper half goes before it, over its lower half after.
/// A line dragged here, out of its own panel, cannot go (hig D11).
private struct PanelDrop: DropDelegate {
    let column: Int
    let index: Int
    let height: CGFloat
    let dragging: PanelDragging?
    @Binding var mark: PanelDropMark?
    /// Whether dropping the panel before a slot changes anything: no line is drawn where it does not (hig D3).
    let lands: (TaskPanel, Int) -> Bool
    let drop: (TaskPanel, Int) -> Void

    private func slot(_ info: DropInfo) -> Int { info.location.y < height / 2 ? index : index + 1 }

    /// The panel dragged, when this app's drag is what came (R17 S1).
    private func dragged(_ info: DropInfo) -> TaskPanel? {
        guard info.hasItemsConforming(to: [boardItemType]), case .panel(let p) = dragging else { return nil }
        return p
    }

    func validateDrop(info: DropInfo) -> Bool { dragged(info) != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let p = dragged(info) else {
            mark = nil
            return DropProposal(operation: .forbidden)
        }
        mark = lands(p, slot(info)) ? .panel(column: column, slot: slot(info)) : nil
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { mark = nil }

    func performDrop(info: DropInfo) -> Bool {
        guard let p = dragged(info) else { return false }
        drop(p, slot(info))
        return true
    }
}

/// The strip past the last column as a drop target (v4 §7.8): a panel dropped on it starts a new column.
private struct NewColumnDrop: DropDelegate {
    let dragging: PanelDragging?
    @Binding var mark: PanelDropMark?
    let drop: (TaskPanel) -> Void

    private func dragged(_ info: DropInfo) -> TaskPanel? {
        guard info.hasItemsConforming(to: [boardItemType]), case .panel(let p) = dragging else { return nil }
        return p
    }

    func validateDrop(info: DropInfo) -> Bool { dragged(info) != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        mark = dragged(info) == nil ? nil : .newColumn
        return DropProposal(operation: mark == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { mark = nil }

    func performDrop(info: DropInfo) -> Bool {
        guard let p = dragged(info) else { return false }
        drop(p)
        return true
    }
}

/// A line as a drop target (v4 §7.9.1, hig §8.2): a line of the same panel goes before or after it; one of another
/// panel cannot go; a panel dragged over the lines goes before or after their panel, by which half.
private struct LineDrop: DropDelegate {
    let panel: TaskPanel
    let index: Int
    let count: Int
    let column: Int
    let panelIndex: Int
    let height: CGFloat
    let dragging: PanelDragging?
    @Binding var mark: PanelDropMark?
    /// Where the line is drawn for a drop before a slot; nil when the drop changes nothing (R17 L2).
    let landing: (String, Int) -> Int?
    let drop: (String, Int) -> Void
    let lands: (TaskPanel, Int) -> Bool
    let dropPanel: (TaskPanel, Int) -> Void

    private func slot(_ info: DropInfo) -> Int { info.location.y < height / 2 ? index : index + 1 }
    private var panelSlot: Int { index < count / 2 ? panelIndex : panelIndex + 1 }

    /// This app's drag, when it is what came (R17 S1).
    private func dragged(_ info: DropInfo) -> PanelDragging? {
        info.hasItemsConforming(to: [boardItemType]) ? dragging : nil
    }

    func validateDrop(info: DropInfo) -> Bool {
        switch dragged(info) {
        case .line(let p, _): p == panel
        case .panel: true
        case nil: false
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        switch dragged(info) {
        case .line(let p, let id) where p == panel:
            mark = landing(id, slot(info)).map { .line(panel, $0) }
            return DropProposal(operation: .move)
        case .panel(let q):
            mark = lands(q, panelSlot) ? .panel(column: column, slot: panelSlot) : nil
            return DropProposal(operation: .move)
        default:
            mark = nil
            return DropProposal(operation: .forbidden)
        }
    }

    func dropExited(info: DropInfo) { mark = nil }

    func performDrop(info: DropInfo) -> Bool {
        switch dragged(info) {
        case .line(let p, let id) where p == panel: drop(id, slot(info))
        case .panel(let q): dropPanel(q, panelSlot)
        default: return false
        }
        return true
    }
}

// MARK: - A line

/// A task's line (v4 §7.2). Wide: icon, id, title, then step, to-do, people and tags, the time; under them the last
/// record. Compact (a narrow panel, or the detail beside it): icon, id, title and time, then step, to-do, tags and
/// people; the last record is in the detail.
struct TaskPanelRow: View {
    let line: TaskLine
    let team: String
    let now: Date
    let todoTotal: Int?
    let compact: Bool
    let workerRow: (String?) -> LiveRow?
    /// Put on top of its panel by the user (v4 §7.9.2).
    var pinned = false
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        let t = line.task
        let over = ["done", "cancelled"].contains(t.state)
        let title = shownTitle(t.title, team: team)
        let indent = StatusIconView.size(.body, scale: scale).rounded(.up) + 6
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TaskStateIcon(state: t.state, muted: over)
                Text(t.id).scaledFont(.callout, design: .monospaced).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Text(title).strikethrough(t.state == "cancelled").scaledFont(.body, weight: over ? .regular : .semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(compact ? 2 : 1).truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                if !compact { facts(t) }
                Text(taskTime(t, now: now)).scaledFont(.callout).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    .help(over ? "끝난 때" : "\(lineKind(t)) 상태로 있은 시간")
                if pinned {
                    Image(systemName: "pin.fill").scaledFont(.caption1).foregroundStyle(.secondary)
                        .help("직접 올린 자리 · 오른쪽 클릭 › 원래 자리로")
                }
            }
            if compact {
                facts(t).padding(.leading, indent)
            } else if let record = secondLine(t) {
                // its inline marks drawn, as the detail draws a progress note (T153)
                Text(inlineMarkdown(record)).scaledFont(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    .padding(.leading, indent).help(record)
            }
        }
        .padding(.leading, line.child ? 16 * scale : 0)
        .help(taskTooltip(t))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(taskAccessibilityValue(line, now: now, todoTotal: todoTotal))
        .accessibilityCustomContent("id", t.id)
        .accessibilityCustomContent("자리", pinned ? "직접 올림" : "기본 순서")
    }

    private func facts(_ t: TaskBoardTask) -> some View {
        HStack(alignment: .center, spacing: 6) {
            StepDots(task: t)
            if let p = todoProgress(t, total: todoTotal) {
                if p.total > 0 { TodoBar(done: p.done, total: p.total, compact: true) }
                else { Text(todoText(p)).scaledFont(.caption1).foregroundStyle(.secondary) }
            }
            people(t)
            tags(t)
        }
        .fixedSize()
    }

    /// The people on a line; none on a cancelled task nobody held.
    @ViewBuilder
    private func people(_ t: TaskBoardTask) -> some View {
        if t.state != "cancelled" || t.assignee != nil { HStack(spacing: 3) {
            if let a = t.assignee { PersonTag(name: a, compact: true, initialOnly: compact, row: workerRow(a)) }
            else { LineTag(text: "담당 없음", color: TaskColor.orange) }
            if let r = t.reviewer {
                Image(systemName: "arrow.right").scaledFont(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                PersonTag(name: r, compact: true, initialOnly: compact, row: workerRow(r))
            }
        } }
    }

    @ViewBuilder
    private func tags(_ t: TaskBoardTask) -> some View {
        if !line.decisions.isEmpty {
            LineTag(text: "결정 " + line.decisions.joined(separator: ", "), symbol: "person.fill.questionmark", color: TaskColor.pink, filled: true)
        }
        ForEach(line.severities, id: \.severity) { SeverityTag(tag: $0) }
        ForEach(line.reasons, id: \.self) { LineTag(text: pmTurnText($0), color: TaskColor.orange) }
        // the count says a task sent back was sent back: with it, the plain `수정 요청` is the same thing twice
        if let rework = reworkText(t) {
            LineTag(text: rework, color: t.state == "changes" ? TaskColor.orange : TaskColor.gray)
                .help("리뷰에서 수정 요청을 \(t.history?.changes ?? 0)번 받음")
        }
        if let nth = submissionOrdinal(t) { LineTag(text: nth, color: TaskColor.purple).help("지금 리뷰 중인 제출") }
        if taggedKinds.contains(lineKind(t)), !(t.state == "changes" && reworkText(t) != nil) {
            LineTag(text: lineKind(t), color: t.state == "changes" ? TaskColor.orange : TaskColor.gray)
        }
        if nearlySubmitted(t, total: todoTotal) { LineTag(text: "제출 직전", color: TaskColor.blue) }
    }

    private func taskTooltip(_ t: TaskBoardTask) -> String {
        [t.title, t.ticketPath.map { "티켓: \($0)" },
         "등록: \(t.createdBy ?? "?") · \(fullTime(t.createdAt))",
         "담당: \(t.assignee ?? "없음") · 리뷰어: \(t.reviewer ?? "없음")"].compactMap { $0 }.joined(separator: "\n")
    }
}

/// 등록 → 배정 → 작업 → 리뷰 → 끝 (v4 §7.2): passed steps green, the current one a larger dot in the state's color,
/// the rest hollow. A cancelled task's are gray up to where it stopped (T157), all hollow when the board does not say.
struct StepDots: View {
    let task: TaskBoardTask
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        let now = taskStep(task)
        let cancelled = task.state == "cancelled"
        let color = cancelled ? TaskColor.gray : TaskStateStyle.of(standingState(task)).color
        HStack(spacing: 2 * scale) {
            ForEach(TaskStep.allCases, id: \.self) { s in
                let d = (s == now ? 8 : 6) * scale
                Group {
                    if let now, s.rawValue < now.rawValue { Circle().fill(cancelled ? TaskColor.gray : TaskColor.green) }
                    else if s == now { Circle().fill(color) }
                    else { Circle().strokeBorder(TaskColor.gray, lineWidth: 1) }
                }
                .frame(width: d, height: d)
            }
        }
        .help(TaskStep.allCases.compactMap { stepText[$0] }.joined(separator: " → ") + "\n" + stepPhrase(task))
        .accessibilityHidden(true)
    }
}

/// A word on a line: a decision filled, the rest outlined.
struct LineTag: View {
    let text: String
    var symbol: String?
    let color: Color
    var filled = false

    var body: some View {
        HStack(spacing: 2) {
            if let symbol { Image(systemName: symbol) }
            Text(text)
        }
        .scaledFont(.caption1, weight: .bold)
        .lineLimit(1)
        .foregroundStyle(filled ? TaskColor.onRed : color)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(filled ? color : .clear, in: .rect(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color, lineWidth: filled ? 0 : 1))
        .fixedSize()
        .accessibilityHidden(true)
    }
}

/// How far the scroll view around it is scrolled, as it scrolls (R17 S3). SwiftUI on macOS 14 does not tell a scroll
/// view's offset (`onScrollGeometryChange` is macOS 15), so this asks the AppKit scroll view under it.
private struct ScrollOffsetProbe: NSViewRepresentable {
    let changed: (CGFloat) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.changed = changed }

    final class Probe: NSView {
        var changed: (CGFloat) -> Void = { _ in }
        private weak var watched: NSClipView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            rewire()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            rewire()
        }

        /// Watches the clip view it is in now, and no other: moved out of a window, or into another scroll view in the
        /// same window, the old watch goes (R17a L4). A selector observer: the notification center drops it when the
        /// probe goes, however it goes (R17b L2).
        private func rewire() {
            let clip = window == nil ? nil : enclosingScrollView?.contentView
            guard clip !== watched else { return }
            if let watched { NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: watched) }
            watched = clip
            guard let clip else { return }
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled), name: NSView.boundsDidChangeNotification,
                                                   object: clip)
            report()
        }

        /// AppKit posts a clip view's bounds change on the main thread, where it scrolls.
        @objc private func clipScrolled(_ note: Notification) { report() }

        /// On the next turn: a scroll SwiftUI makes (`scrollTo`) moves the clip view inside a view update, where a
        /// state change is dropped.
        private func report() {
            guard let clip = enclosingScrollView?.contentView else { return }
            let y = clip.bounds.origin.y
            DispatchQueue.main.async { [weak self] in self?.changed(y) }
        }
    }
}
