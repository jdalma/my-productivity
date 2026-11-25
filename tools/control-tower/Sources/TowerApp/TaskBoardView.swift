import AppKit
import SwiftUI
import TowerCore

// A team's task board (T70, v2 T70b; design: ~/.my-team/docs/control-tower/design/board-view.md §3.1, §3.2, §4, §5,
// and board-view-v2.md §A.3, §B). Read only: nothing here writes to the board. Paths are copied, never opened
// (pm decision 5).

/// The board's state colors, light and dark: Primer foreground values one step darker in light and lighter in dark
/// than the system colors, so a word in the color reads at 4.5:1 on its own tint (T70b report).
enum TaskColor {
    static let orange = pair(0x953800ff, 0xf0883eff)
    static let blue = pair(0x0550aeff, 0x79c0ffff)
    static let purple = pair(0x6639baff, 0xd2a8ffff)
    static let red = pair(0xa40e26ff, 0xff7b72ff)
    static let green = pair(0x116329ff, 0x56d364ff)
    static let gray = DiffColors.mutedText
    /// Secondary words on the sidebar (T132): the board's gray in light, lighter in dark, where the sidebar's material
    /// (`#37393a` in a dark capture) is lighter than the window and `gray` would read under 4.5:1.
    static let sidebarGray = pair(0x59636eff, 0xb7bdc4ff)
    /// The user's decisions (T116): a hue no other state or group uses.
    static let pink = pair(0x99286eff, 0xff9bceff)
    /// The word on a filled red tag: white on the light red, near black on the dark one.
    static let onRed = pair(0xffffffff, 0x0d1117ff)

    private static func pair(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { DiffColors.rgba($0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light) })
    }
}

/// How a task state looks (design §4.1): each shape differs, so color is never the only cue.
struct TaskStateStyle: Equatable {
    var label: String
    var symbol: String
    var color: Color

    static func of(_ state: String) -> TaskStateStyle {
        switch state {
        case "new": TaskStateStyle(label: "미배정", symbol: "circle.dashed", color: TaskColor.orange)
        case "ready": TaskStateStyle(label: "시작 전", symbol: "circle", color: TaskColor.gray)
        case "doing": TaskStateStyle(label: "진행 중", symbol: "circle.lefthalf.filled", color: TaskColor.blue)
        case "review": TaskStateStyle(label: "리뷰 중", symbol: "eye.circle.fill", color: TaskColor.purple)
        case "changes": TaskStateStyle(label: "수정 요청", symbol: "arrow.uturn.backward.circle.fill", color: TaskColor.orange)
        case "held": TaskStateStyle(label: "보류", symbol: "pause.circle.fill", color: TaskColor.red)
        case "done": TaskStateStyle(label: "완료", symbol: "checkmark.circle.fill", color: TaskColor.green)
        case "cancelled": TaskStateStyle(label: "취소됨", symbol: "xmark.circle", color: TaskColor.gray)
        case "waiting": TaskStateStyle(label: "결정 대기", symbol: "person.fill.questionmark", color: TaskColor.pink)
        default: TaskStateStyle(label: state, symbol: "questionmark.circle", color: TaskColor.gray)
        }
    }

    static let all = ["new", "ready", "doing", "review", "changes", "held", "waiting", "done", "cancelled"]
}

// MARK: - Words (T91; design v3 D §2.3, §2.4, §2.6, §2.7)

let severityText = ["must": "필수", "should": "권장", "low": "낮음"]

/// A name or id with 이/가 (or 을/를 …) as it reads aloud: a Hangul syllable by its final consonant, a digit by its
/// Korean reading (일, 삼, 육, 칠, 팔, 영 end in one), a Latin ending l, m, n or ng as 일, 엠, 엔, 응.
/// ponytail: the last letters only, so "book" takes 가; a pronunciation table if names ever need it.
func withParticle(_ word: String, _ afterConsonant: String, _ afterVowel: String) -> String {
    guard let last = word.unicodeScalars.last else { return word }
    let v = last.value
    let final: Bool
    if (0xAC00...0xD7A3).contains(v) { final = (v - 0xAC00) % 28 != 0 }
    else if let d = Int(String(last)) { final = [0, 1, 3, 6, 7, 8].contains(d) }
    else { final = "lmnLMN".unicodeScalars.contains(last) || word.lowercased().hasSuffix("ng") }
    return word + (final ? afterConsonant : afterVowel)
}

/// `pm이`, `lists가`.
func subject(_ name: String) -> String { withParticle(name, "이", "가") }

/// A title without the `<team>: ` the window's own title already says (D §2.3); the full title is the tooltip.
func shownTitle(_ title: String, team: String) -> String {
    let prefix = team + ": "
    return title.hasPrefix(prefix) && title.count > prefix.count ? String(title.dropFirst(prefix.count)) : title
}

/// `권장 1`: one severity and its own count, the words a line's tag and its sentence share (D §2.3).
func severityCount(_ severity: String, _ count: Int) -> String { "\(severityText[severity] ?? severity) \(count)" }

/// `필수 1 · 권장 1`
func severityCounts(_ counts: [SeverityCount]) -> String {
    counts.map { severityCount($0.severity, $0.count) }.joined(separator: " · ")
}

/// A question's head for a list line (T116): its first 40 characters.
func questionHead(_ q: String) -> String {
    let one = q.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return one.count > 40 ? one.prefix(40) + "…" : one
}

/// A line's time (D §2.4): how long it has been as it is, `10분째`; a done or cancelled one, in whatever group, when it ended, `1시간 전 끝남`
/// within a day, else `11/12 21:07 끝남`.
func taskTime(_ t: TaskBoardTask, now: Date) -> String {
    if !["done", "cancelled"].contains(t.state) {
        let e = taskElapsed(t, now: now)
        return e.isEmpty ? "" : e + "째"
    }
    let iso = stateSince(t)
    guard let ms = parseISO(iso) else { return "" }
    let end = Date(timeIntervalSince1970: ms / 1000)
    return (now.timeIntervalSince(end) < 86400 ? relativeTime(iso, now: now) : boardClock(end, withDay: true)) + " 끝남"
}

/// One line of the recent activity (D §2.7, H13): when, who, and what in a phrase.
struct ActivityLine: Equatable {
    var time: String
    var who: String
    var what: String
}

private let findingStateText = ["open": "열림", "fixed": "수정됨", "backlog": "나중에 하기", "accepted-limit": "한계로 받아들임",
                                "rejected": "지적 아님"]

/// The recent activity newest first, in the screen's words; one person's finding changes to one state within a
/// minute become one line (D §2.7).
/// An announcement's event carries no body; the announcement made with it gives its first 40 characters (S5).
func activityLines(_ events: [TaskBoardEvent], now: Date, announcements: [TaskBoardAnnouncement] = []) -> [ActivityLine] {
    var out: [(line: ActivityLine, merge: String?, refs: [String])] = []
    for e in events.sorted(by: { $0.seq > $1.seq }) {
        let ms = parseISO(e.at)
        let at = ms.map { Date(timeIntervalSince1970: $0 / 1000) }
        let time = at.map { boardClock($0, withDay: !Calendar.current.isDate($0, inSameDayAs: now)) } ?? ""
        let who = e.actor ?? "?"
        let ref = e.ref == "-" ? nil : e.ref
        if e.action == "finding" {
            let key = "\(who)|\(Int((ms ?? 0) / 60_000))|\(e.stateTo ?? "")"
            let refs = (out.last?.merge == key ? out.removeLast().refs : []) + [ref ?? "?"]
            let to = e.stateTo.map { findingStateText[$0] ?? $0 } ?? "?"
            out.append((ActivityLine(time: time, who: who, what: "지적 \(refs.count)건 → \(to) (\(refs.reversed().joined(separator: ", ")))"),
                        key, refs))
            continue
        }
        let what: String
        switch e.action {
        case "add": what = withParticle(ref ?? "작업", "을", "를") + " 등록"
        case "assign": what = "\(ref ?? "작업") 담당 지정" + (e.detail.map { ": \($0)" } ?? "")
        case "take": what = "\(ref ?? "작업") 시작"
        case "land":
            let parts = (ref ?? "").split(separator: "#")
            what = "\(e.task ?? parts.first.map(String.init) ?? "작업") 제출" + (parts.count == 2 ? " (\(parts[1])차)" : "")
        case "verdict":
            let task = e.landing?.split(separator: "#").first.map(String.init) ?? ref ?? "?"
            let label = VerdictStyle.of(e.verdict ?? "").label
            let to = e.stateTo.map { TaskStateStyle.of($0).label }
            what = "\(task) \(label)" + (to.map { $0 == label ? "" : " → \($0)" } ?? "")
        case "note": what = [ref, "메모"].compactMap { $0 }.joined(separator: " ")
        case "announce":
            // the nearest made within 2 s: two announcements a second apart each find their own (R9 L2)
            let body = e.detail ?? ms.flatMap { at in
                announcements.compactMap { a in parseISO(a.createdAt).map { (gap: abs($0 - at), body: a.body) } }
                    .filter { $0.gap <= 2_000 }.min { $0.gap < $1.gap }?.body
            }
            what = "공지" + (body.map { ": " + oneLineHead($0, 40) } ?? "")
        case "cancel": what = "\(ref ?? "작업") 취소"
        case "wait": what = "\(ref ?? "작업") 사용자에게 결정 요청"
        case "answer": what = "\(ref ?? "작업") 사용자 결정"
        default: what = [ref, e.action].compactMap { $0 }.joined(separator: " ")
        }
        out.append((ActivityLine(time: time, who: who, what: what), nil, []))
    }
    return out.map(\.line)
}

/// How long a task has been as it is, in minutes: since it asked the user (T116), else since it entered its state
/// (T157), which without the board's `history` is `updated_at`, else `created_at`.
func elapsedMinutes(_ t: TaskBoardTask, now: Date) -> Int? {
    parseISO(t.waiting?.askedAt ?? stateSince(t)).map { max(0, Int((now.timeIntervalSince1970 * 1000 - $0) / 60_000)) }
}

func taskElapsed(_ t: TaskBoardTask, now: Date) -> String {
    elapsedMinutes(t, now: now).map { shortDuration(minutes: $0) } ?? ""
}

/// A task line's context menu and VoiceOver actions (H9, H15): the ticket's path only when the task names one,
/// and the way to the assignee's and the reviewer's worker, since names on a line are text.
enum TaskMenuItem: Hashable {
    case copyTaskId, copyTicketPath
    case showAssignee(String), showReviewer(String)
    /// Its place within its panel (T153; v4 §7.9.1).
    case move(TaskMove)

    var title: String {
        switch self {
        case .copyTaskId: "id 복사"
        case .copyTicketPath: "티켓 경로 복사"
        case .showAssignee(let n): "담당 \(n) 보기"
        case .showReviewer(let n): "리뷰어 \(n) 보기"
        case .move(let m): taskMoveTitle(m)
        }
    }
}

func taskMoveTitle(_ m: TaskMove) -> String {
    switch m {
    case .up: "위로"
    case .down: "아래로"
    case .top: "맨 위로"
    case .unpin: "원래 자리로"
    }
}

/// The 보기 › 묶음 menu's target (T153; pm 6): the panel whose head the user last worked, else the picked task's line.
/// A move it cannot make is nil, so its item is off.
struct PanelArrange {
    var subject: String?
    var up: (() -> Void)?
    var down: (() -> Void)?
    /// A panel to the column on its left or right (T154); nil for a task line, and where the panel cannot go.
    var left: (() -> Void)?
    var right: (() -> Void)?
    var reset: (() -> Void)?
}

extension FocusedValues {
    @Entry var panelArrange: PanelArrange?
}

/// VoiceOver's word on where a moved panel or task now is (hig §7.4).
@MainActor func announcePanel(_ p: TaskPanel, in prefs: TaskPanelPrefs, room: Int) {
    AccessibilityNotification.Announcement("\(TaskPanelStyle.of(p).label) 묶음, \(panelPlaceText(p, in: prefs, room: room))로 옮김").post()
}

@MainActor func announceTask(_ id: String, in p: TaskPanel, _ prefs: TaskPanelPrefs) {
    let place = prefs.pins(p).firstIndex(of: id).map { "\($0 + 1)번째" } ?? "원래 자리"
    AccessibilityNotification.Announcement("\(id), \(TaskPanelStyle.of(p).label) \(place)").post()
}

/// Layout changes the user can take back with ⌘Z (hig D6, D14), each under its own name in Edit's undo item. Undo puts
/// back the layout alone, on the prefs as they are then, so a fold made since stays (R17 S2).
@MainActor final class LayoutUndo {
    func change(to new: TaskPanelPrefs, name: String, undo: UndoManager?, read: @escaping () -> TaskPanelPrefs,
                write: @escaping (TaskPanelPrefs) -> Void) {
        let old = read()
        write(new)
        undo?.registerUndo(withTarget: self) { box in
            // AppKit runs undo on the main thread, from the Edit menu or ⌘Z
            MainActor.assumeIsolated {
                box.change(to: read().withLayout(of: old), name: name, undo: undo, read: read, write: write)
            }
        }
        undo?.setActionName(name)
    }
}

func taskMenuItems(_ t: TaskBoardTask) -> [TaskMenuItem] {
    [.copyTaskId] + ((t.ticketPath ?? "").isEmpty ? [] : [.copyTicketPath])
        + (t.assignee.map { [.showAssignee($0)] } ?? []) + (t.reviewer.map { [.showReviewer($0)] } ?? [])
}

struct TaskStateIcon: View {
    let state: String
    var style: NSFont.TextStyle = .body
    /// Gray: a task that is over (S2).
    var muted = false
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        let s = TaskStateStyle.of(state)
        // whole points: a link button cuts its label to '…' when the label's width has a fraction (T123, E2 L1)
        let size = StatusIconView.size(style, scale: scale).rounded(.up)
        Image(systemName: s.symbol).font(.system(size: size)).foregroundStyle(muted ? TaskColor.gray : s.color)
            .frame(width: size, height: size)
            .help(s.label)
            .accessibilityLabel(s.label)
    }
}

/// What the team line's task board button says (T184): the tooltip is the counts once read, the failure's title and
/// detail when no read has worked (D9), else `작업판을 읽는 중`. A failed read has its own icon shape and wording.
struct TaskBoardButtonState: Equatable {
    var tooltip: String
    var failed: Bool
    /// What VoiceOver reads of the task board in the team line's label (T189, R11 S3): `작업판 시작 전 2 · 진행 중 5`,
    /// the failure's title and detail, or `작업판을 읽는 중`.
    var spoken: String

    init(counts: TaskCounts?, problem: String?) {
        tooltip = counts.map(taskCountsText) ?? problem ?? "작업판을 읽는 중"
        failed = counts == nil && problem != nil
        spoken = counts.map { "작업판 " + taskPanelsText($0) } ?? tooltip.replacingOccurrences(of: "\n", with: ", ")
    }

    var symbol: String { failed ? "exclamationmark.triangle" : "list.bullet.rectangle" }
    /// The name of the team line's accessibility action that opens the task board.
    var label: String { failed ? "작업판 열기, 읽지 못함" : "작업판 열기" }
}

/// The team line's button that opens the team's task board window: an icon, with `작업판` beside it when `showsWord`.
/// It does not fold the team. The team line hides it from accessibility and speaks for it (`TeamHeader`).
struct TaskBoardButton: View {
    let state: TaskBoardButtonState
    let showsWord: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 3) {
                Image(systemName: state.symbol)
                if showsWord { Text("작업판") }
            }
            .scaledFont(.callout)
            .foregroundStyle(TaskColor.sidebarGray)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(TaskColor.sidebarGray.opacity(0.15), in: .capsule)
            .fixedSize()
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(state.tooltip)
    }
}

/// `사용자 결정 3 · 시작 전 2 · 진행 중 5 · 리뷰 중 2 · 보류 1`: the decisions first when any wait, then the panels.
func taskCountsText(_ c: TaskCounts) -> String {
    ((c.user > 0 ? ["\(TaskPanelStyle.of(.decisions).label) \(c.user)"] : []) + [taskPanelsText(c)]).joined(separator: " · ")
}

/// `시작 전 2 · 진행 중 5 · 리뷰 중 2 · 보류 1`
func taskPanelsText(_ c: TaskCounts) -> String {
    c.panels.map { "\(TaskPanelStyle.of($0.panel).label) \($0.count)" }.joined(separator: " · ")
}

/// A task line's words the search looks in (H5, §1.5): id, title, assignee, reviewer, its open findings' summaries.
func taskMatches(_ line: TaskLine, query: String, findings: [TaskBoardFinding]) -> Bool {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return true }
    let t = line.task
    let words = [t.id, t.title, t.assignee, t.reviewer, t.waiting?.question].compactMap { $0 } + findings.filter { $0.taskId == t.id }.map(\.summary)
    return words.contains { $0.localizedCaseInsensitiveContains(q) }
}

/// A folded panel shows its lines once opened, and always while a search runs (T94 (e)).
func showsLines(open: Bool, query: String) -> Bool {
    open || !query.trimmingCharacters(in: .whitespaces).isEmpty
}

/// A decision the search finds: by id, question, or a task it is tied to.
func decisionMatches(_ d: BoardDecision, query: String) -> Bool {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return true }
    return ([d.id, d.brief.question] + d.related).contains { $0.localizedCaseInsensitiveContains(q) }
}

/// The window's subtitle (H4, v4 §7.5 S2): the counts the sidebar shows, and when the board was read.
func taskBoardSubtitle(_ state: TaskBoardState?) -> String {
    guard let state, let s = state.status else { return "" }
    let read = state.lastOK.map { "\(boardClock($0))에 읽음" }
    return ([taskCountsText(TaskCounts(s))] + [read, state.shownFailure == nil ? nil : "다시 읽지 못함"].compactMap { $0 })
        .joined(separator: " · ")
}

/// Where each team's folds and layout are kept (v4 §7.7, §7.9.6).
let taskPanelPrefsKey = "taskBoardPanels"

struct TaskBoardView: View {
    let team: String
    let state: TaskBoardState?
    let model: SidebarModel
    /// The picked task on this board, and its family's last read.
    let selectedTask: String?
    let family: TaskFamilyState?
    let pick: (String?) -> Void
    let select: (RowID) -> Void
    /// A link's file for the board window's editor of that row's worktree (D#17).
    let openInBoard: (IdeOpenRequest, RowID) -> Void
    let reload: () -> Void
    /// The window's menu actions, published again inside the split's sides.
    var navigation: WindowNavigation?
    /// ⌘F: a new value puts the keyboard in the search field.
    var searchFocus = 0
    /// The team's goal order (T214); nil before the first read.
    var goalOrder: GoalOrderRead?
    @State private var query = ""
    /// A new value scrolls the 순서 view to the picked task's card.
    @State private var orderScrollTo: OrderScroll?
    @State private var doneOpen = false
    /// 지난 결정 shown under the waiting ones (T147).
    @State private var pastOpen = false
    /// The team overview in the detail's place (v4 §7.4).
    @State private var overviewShown = false
    @State private var decisionsRequest = 0
    /// The open decisions at the last read; nil before the first, which tells nothing new (v4 §7.7).
    @State private var seenDecisions: Set<String>?
    @State private var allAnnouncements = false
    @State private var allRecent = false
    @State private var allWorkers = false
    /// Too narrow for the list and the detail side by side.
    @State private var narrow = false
    /// The to-do item count of each unfinished task's ticket, by path (T128): read off the main thread, once each.
    @State private var ticketItems: [String: Int] = [:]
    /// The list's width beside the detail, app-wide; 0 until the divider is first dragged (T89).
    @AppStorage("taskBoardListWidth") private var storedListWidth = 0.0
    /// Each team's folded panels, kept across launches (v4 §7.7).
    @AppStorage(taskPanelPrefsKey) private var storedPrefs = ""
    /// The panel whose head the user last worked: the 보기 › 묶음 menu's target (pm 6).
    @State private var headTarget: TaskPanel?
    @State private var layoutUndo = LayoutUndo()
    /// A new value scrolls the list to what the 묶음 menu or its shortcut moved (R17 L4); no other layout change
    /// scrolls (R17a S1).
    @State private var moveRequest = 0
    /// How many columns of panels the list has room for, as the list measures it (T154).
    @State private var columnRoom = 1
    @State private var documents: TeamDocuments?
    @State private var shownPage: DocumentPage?
    @State private var documentFileOpens: [Int: DocumentFileOpen] = [:]
    @State private var documentNotice: String?
    @AppStorage(fileEditorKey) private var storedEditor = ""
    @State private var listHeight: CGFloat = 0
    @Environment(\.undoManager) private var undoManager
    @Environment(\.boardFontScale) private var scale

    private var prefs: Binding<TaskPanelPrefs> {
        Binding {
            readPanelPrefs(storedPrefs)[team] ?? TaskPanelPrefs()
        } set: { p in
            var all = readPanelPrefs(storedPrefs)
            all[team] = p
            storedPrefs = storedPanelPrefs(all)
        }
    }

    /// The view shown: 순서 only where my-team answers goal-order (design §3); before the first read, as stored.
    private var mode: TaskBoardMode {
        TaskBoardMode.shown(stored: prefs.wrappedValue.view, supported: goalOrder != .unsupported)
    }

    /// The 상태별 | 순서 control shows once my-team is known to answer goal-order.
    private var modeSupported: Bool { if case .unsupported = goalOrder { false } else { goalOrder != nil } }

    /// Choosing a view closes the team overview, as the overview toggle clears the pick (design §1).
    private func setMode(_ m: TaskBoardMode) {
        overviewShown = false
        prefs.wrappedValue.view = m.rawValue
    }

    private var modeControl: BoardModeControl {
        BoardModeControl(mode: mode, supported: modeSupported, set: setMode)
    }

    private var goals: [GoalOrder] { if case .ok(let g)? = goalOrder { g } else { [] } }

    var body: some View {
        let open = state?.status.map { openDecisions($0).count } ?? 0
        TimelineView(.periodic(from: .now, by: 15)) { context in
            content(now: context.date)
        }
        .navigationSubtitle(taskBoardSubtitle(state))
        .focusedSceneValue(\.windowNavigation, shownNavigation)
        .focusedSceneValue(\.panelArrange, mode == .order ? nil : arrangement)
        .focusedSceneValue(\.boardMode, modeControl)
        .toolbar {
            if narrow && detailOpen {
                ToolbarItem(placement: .navigation) {
                    Button("작업 목록", systemImage: "chevron.backward") { closeDetail() }.help("작업 목록으로 (Esc)")
                }
            }
            ToolbarItemGroup {
                // design §1: first in the toolbar, icons only; not while the detail takes the list's place
                if modeSupported && !(narrow && detailOpen) {
                    Picker("보기", selection: Binding { mode } set: { setMode($0) }) {
                        ForEach(TaskBoardMode.allCases, id: \.self) { m in
                            Image(systemName: m.symbol).accessibilityLabel(m.menuTitle).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help(mode == .panels ? "순서로 보기 (⌘2)" : "상태별로 보기 (⌘1)")
                }
                if open > 0 {
                    Button { showDecisions() } label: {
                        Label("결정 \(open)", systemImage: "person.fill.questionmark").labelStyle(.titleAndIcon)
                            .foregroundStyle(TaskColor.onRed)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(TaskColor.pink, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .help("답을 기다리는 결정 \(open)개로")
                    .accessibilityLabel("답을 기다리는 결정 \(open)")
                }
                Toggle(isOn: Binding { overviewShown } set: { on in
                    if on { pick(nil); shownPage = nil }
                    overviewShown = on
                }) { Label("팀 개요", systemImage: "person.3") }
                    .help(overviewShown ? "팀 개요 닫기" : "팀 개요: 공지, 워커별 맡은 일, 최근 활동")
                Button("다시 읽기", systemImage: "arrow.clockwise", action: reload).help("다시 읽기 (⌘R)")
            }
            ToolbarItem {
                SearchField(text: $query, prompt: "작업 검색", focusRequest: searchFocus)
                    .frame(width: 200)
                    .help("id, 제목, 담당, 리뷰어, 지적에서 찾기 (⌘F)")
            }
        }
        // initial: the decisions open when the window opens are not new, the next one is (R9 S1)
        .onChange(of: state?.status, initial: true) { _, s in
            guard let s else { return }
            if selectedTask != nil, keepTaskSelection(selectedTask, in: s) == nil { pick(nil) }
            let now = Set(openDecisions(s).map(\.id))
            let p = unfoldingForNewDecisions(prefs.wrappedValue, before: seenDecisions, now: now)
            if p != prefs.wrappedValue { prefs.wrappedValue = p }
            seenDecisions = now
        }
        .onChange(of: selectedTask, initial: true) { _, id in
            // a task picked from elsewhere opens its panel (v4 §7.7); one picked here is in an open panel already
            guard let id, let s = state?.status else { return }
            overviewShown = false
            shownPage = nil
            let p = unfoldingForPick(prefs.wrappedValue, pick: id, in: s, searching: !query.trimmingCharacters(in: .whitespaces).isEmpty)
            if p != prefs.wrappedValue { prefs.wrappedValue = p }
        }
        .task(id: [state?.lastOK.map { "\($0.timeIntervalSinceReferenceDate)" }, storedEditor]) {
            guard state?.lastOK != nil else { return }
            let (team, known, stored) = (team, documents, storedEditor)
            (documents, documentFileOpens) = await Task.detached {
                let d = readTeamDocuments(team: team, known: known)
                return (d, fileOpensByRow(d, stored: stored))
            }.value
        }
    }

    private var detailOpen: Bool { selectedTask != nil || overviewShown || shownPage != nil }

    /// A layout change (T153), taken back by ⌘Z under `name`.
    private func arrange(_ next: TaskPanelPrefs, _ name: String) {
        let binding = prefs
        layoutUndo.change(to: next, name: name, undo: undoManager, read: { binding.wrappedValue }) { binding.wrappedValue = $0 }
    }

    /// The 보기 › 묶음 menu (pm 6): the panel whose head was last worked, else the picked task's line in a panel whose
    /// lines move; 기본 배치로 되돌리기 always, while there is a layout to undo.
    private var arrangement: PanelArrange {
        let p = prefs.wrappedValue
        let reset = p.hasLayout ? { arrange(p.resetLayout, "기본 배치로 되돌리기") } : nil
        // the list is not on screen while the detail takes its place: nothing there to move (R17 L4)
        if narrow && detailOpen { return PanelArrange(reset: reset) }
        if let h = headTarget {
            func go(_ n: TaskPanelPrefs) -> () -> Void {
                { arrange(n, "묶음 이동"); announcePanel(h, in: n, room: columnRoom); moveRequest += 1 }
            }
            return PanelArrange(subject: "\(TaskPanelStyle.of(h).label) 묶음", up: p.moving(h, by: -1, room: columnRoom).map(go),
                                down: p.moving(h, by: 1, room: columnRoom).map(go),
                                left: p.moving(h, toColumn: -1, room: columnRoom).map(go),
                                right: p.moving(h, toColumn: 1, room: columnRoom).map(go), reset: reset)
        }
        if let id = selectedTask, query.trimmingCharacters(in: .whitespaces).isEmpty,
           let t = state?.status?.tasks.first(where: { $0.id == id }), ordersLines(panel(of: t)) {
            let at = panel(of: t)
            func go(_ n: TaskPanelPrefs) -> () -> Void {
                { arrange(n, "작업 순서 바꾸기"); announceTask(id, in: at, n); moveRequest += 1 }
            }
            return PanelArrange(subject: id, up: p.moving(task: id, in: at, .up).map(go),
                                down: p.moving(task: id, in: at, .down).map(go), reset: reset)
        }
        return PanelArrange(reset: reset)
    }

    /// Esc closes the overview or a document as it closes a task's detail.
    private var shownNavigation: WindowNavigation? {
        guard overviewShown || shownPage != nil, selectedTask == nil, var n = navigation else { return navigation }
        n.escape = shownPage != nil ? ("문서 닫기", { shownPage = nil }) : ("팀 개요 닫기", { overviewShown = false })
        return n
    }

    private func closeDetail() {
        overviewShown = false
        shownPage = nil
        pick(nil)
    }

    /// The toolbar's 결정 button (v4 §7.1a): the decisions panel, unfolded, its first decision picked.
    private func showDecisions() {
        prefs.wrappedValue.setFolded(.decisions, false)
        overviewShown = false
        if let first = state?.status.flatMap({ openDecisions($0).first }) { pick(first.id) }
        decisionsRequest += 1
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let state, let status = state.status {
            VStack(spacing: 0) {
                if let note = state.problem(now: now) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(TaskColor.orange)
                        Text(note).lineLimit(1).truncationMode(.tail).help(note)
                        Spacer(minLength: 8)
                        Button("다시 읽기", action: reload).buttonStyle(.link)
                    }
                    .scaledFont(.callout).padding(.horizontal, 16).padding(.vertical, 6)
                    Divider()
                }
                GeometryReader { geo in
                    let limits = SplitLimits(scale: scale)
                    let line = selectedTask.flatMap { id in taskPanels(status).values.joined().first { $0.task.id == id } }
                    let decision = selectedTask.flatMap { id in boardDecisions(status).first { $0.id == id } }
                    let detailShown = line != nil || decision != nil || overviewShown || shownPage != nil
                    // v4 §7.4: wide, the detail beside the list, and with nothing picked the list takes the window; the
                    // list stays the same view either way, so a pick keeps its keyboard and its scroll (R9 M1).
                    // Narrow, the detail takes the list's place.
                    if geo.size.width >= limits.beside {
                        TaskBoardSplit(limits: limits,
                                       stored: storedListWidth > 0 ? storedListWidth : nil,
                                       save: { storedListWidth = $0 },
                                       navigation: shownNavigation,
                                       arrangement: mode == .order ? nil : arrangement,
                                       boardMode: modeControl,
                                       detailShown: detailShown,
                                       list: list(status, now: now).scaledFont(.body).environment(\.boardFontScale, scale),
                                       detail: Group {
                                           if detailShown { detail(status, line: line, decision: decision, now: now) }
                                       }
                                       .scaledFont(.body).environment(\.boardFontScale, scale))
                    } else if !detailShown {
                        list(status, now: now)
                    } else {
                        detail(status, line: line, decision: decision, now: now)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { narrow = $0 < SplitLimits(scale: scale).beside }
            }
            .task(id: ticketsToCount(status)) {
                let paths = ticketsToCount(status).filter { ticketItems[$0] == nil }
                guard !paths.isEmpty else { return }
                let counts = await Task.detached {
                    paths.map { p -> (String, Int) in
                        if case .read(let o, _) = readTicket(p) { (p, o.items.count) } else { (p, 0) }
                    }
                }.value
                for (p, n) in counts { ticketItems[p] = n }
            }
        } else if let failure = state?.shownFailure {
            failed(failure)
        } else {
            ProgressView("작업판을 읽는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func list(_ s: TaskBoardStatus, now: Date) -> some View {
        VStack(spacing: 0) {
            if mode == .order {
                GoalOrderList(read: goalOrder, query: query, selected: selectedTask, pick: pick, prefs: prefs,
                              openGoalFile: openGoalFile, reload: reload,
                              scrollTo: orderScrollTo, scrolled: { orderScrollTo = nil })
            } else {
                TaskPanelList(team: team, status: s, query: query, now: now, selected: selectedTask, pick: pick,
                              prefs: prefs, doneOpen: $doneOpen, pastOpen: $pastOpen, headTarget: $headTarget, arrange: arrange,
                              moveRequest: moveRequest,
                              todoTotals: ticketItems,
                              workerRow: workerRow, select: select, decisionsRequest: decisionsRequest, columnRoom: $columnRoom)
            }
            Divider()
            DocumentsArea(documents: documents, fileOpens: documentFileOpens, storedEditor: storedEditor, notice: documentNotice,
                          shownPagePath: shownPage?.path, maxHeight: listHeight * DocumentsArea.listShare) { row in
                guard let folder = documents?.folder else { return }
                documentNotice = openDocument(row, folder: folder, index: documents?.rows ?? [], stored: storedEditor,
                                              failed: { why in Task { @MainActor in documentNotice = why } }) { path in
                    pick(nil)
                    overviewShown = false
                    shownPage = DocumentPage(title: row.line.title, path: path, folder: folder)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
    }

    @ViewBuilder
    private func detail(_ s: TaskBoardStatus, line: TaskLine?, decision: BoardDecision?, now: Date) -> some View {
        if let page = shownPage {
            DocumentPageView(title: page.title, path: page.path, folder: page.folder) { shownPage = nil }
        } else if let decision {
            DecisionDetailView(decision: decision, tasks: s.tasks, team: team, now: now, pick: pick)
        } else if let line {
            let shownFamily = family?.ref == TaskRef(team: team, task: line.task.id) ? family : nil
            // the board window has an editor for a worker in a tmux pane: links open there, else they stay text (D#17)
            let row = workerRow(line.task.assignee).flatMap { $0.session.tmux == nil ? nil : $0 }
            let places = findingPlaces(line.task, family: shownFamily)
            TaskDetailView(team: team, line: line, family: shownFamily,
                           decisions: decisions(of: line.task.id, in: s), listsDecisions: s.decisions != nil,
                           now: now, workerRow: workerRow, pick: pick, select: select, reload: reload,
                           goalLinks: goalLinks(of: line.task.id, in: goals),
                           boardTasks: Dictionary(s.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                           showInOrder: { showInOrder(OrderScroll(task: line.task.id, goal: $0)) })
                .environment(\.openTargetInIde, row.map { row in
                    { target in openInBoard(IdeOpenRequest(root: row.session.cwd, target: target, findings: places), row.id) }
                })
        } else {
            overview(s, now: now)
        }
    }

    /// The task's open findings and the landings they were raised on: the board editor's markers (G4 W5).
    private func findingPlaces(_ t: TaskBoardTask, family: TaskFamilyState?) -> [FindingPlace] {
        guard let d = family?.family.flatMap({ taskDetail($0, task: t.id) }) else { return [] }
        return d.findings.filter { $0.pile == .open }.map { f in
            let landing = f.raisedIn.flatMap { id in d.cards.first { $0.landing.id == id }?.landing }
            return FindingPlace(id: f.finding.id, severity: f.finding.severity, summary: f.finding.summary, repro: f.finding.repro,
                                repo: landing?.repo, commit: landing?.commit.nonEmptyText)
        }
    }

    /// The detail's 목표 line (design §4): the 순서 view, the task's card scrolled into view. Narrow, the detail has the
    /// list's place, so it closes for the list to show (T214 R1 S1).
    private func showInOrder(_ to: OrderScroll) {
        setMode(.order)
        if narrow { pick(nil) }
        // a search the card does not match keeps its goal folded: the link asks for the card, so the search goes (R2 L2)
        query = ""
        orderScrollTo = to
    }

    /// A goal's file in the detail's place, as a document of the team's folder opens (design §2 목표 파일 열기).
    private func openGoalFile(_ g: GoalOrder) {
        pick(nil)
        overviewShown = false
        shownPage = DocumentPage(title: [g.id, g.title].compactMap { $0 }.joined(separator: " "), path: g.path,
                                 folder: documents?.folder ?? (g.path as NSString).deletingLastPathComponent)
    }

    /// The tickets whose to-do count the lines show: every unfinished task's (v4 §7.2).
    private func ticketsToCount(_ s: TaskBoardStatus) -> [String] {
        s.tasks.filter { !["done", "cancelled"].contains($0.state) }.compactMap(\.ticketPath).sorted()
    }

    private var teamGroup: TeamGroup? { model.teams.first { $0.name == team } }

    func workerRow(_ name: String?) -> LiveRow? {
        name.flatMap { n in teamGroup?.rows.first { $0.worker?.workerName == n } }
    }

    private func failed(_ f: TaskBoardFailure) -> some View {
        let p = taskBoardProblem(f, bin: myTeamBin)
        return ContentUnavailableView {
            Label(p.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(p.detail).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
        } actions: {
            Button("다시 읽기", action: reload).help("다시 읽기 (⌘R)")
            Button("오류 내용 복사") { copy("\(p.title)\n\(p.detail)") }
        }
    }

    // MARK: Overview (H §1.3, pm decision 1: announcements D §2.5, workers D §2.5 P11, recent activity D §2.7 + H13)

    private func overview(_ s: TaskBoardStatus, now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("팀 개요").scaledFont(.title3, weight: .bold).accessibilityAddTraits(.isHeader)
                announcements(s.announcements, now: now)
                workers(s.workers)
                recent(activityLines(s.recent, now: now, announcements: s.announcements))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `subject` names the link for VoiceOver when `text` carries a count that changes (`공지 2` → 공지 모두 보기).
    private func heading(_ text: String, subject: String? = nil, more: (label: String, run: () -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).scaledFont(.headline, weight: .semibold).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let more { Button(more.label, action: more.run).buttonStyle(.link).scaledFont(.callout).accessibilityLabel("\(subject ?? text) \(more.label)") }
        }
    }

    /// The newest first, two lines of it until 모두 보기 (D §2.5).
    @ViewBuilder
    private func announcements(_ items: [TaskBoardAnnouncement], now: Date) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                heading("공지 \(items.count)", subject: "공지", more: items.count > 1 || !allAnnouncements
                        ? (allAnnouncements ? "접기" : "모두 보기", { allAnnouncements.toggle() }) : nil)
                ForEach(Array(items.reversed().prefix(allAnnouncements ? items.count : 1)), id: \.seq) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(inlineMarkdown(a.body)).scaledFont(.body).lineLimit(allAnnouncements ? nil : 2).truncationMode(.tail)
                            .textSelection(.enabled).help(a.body)
                        Text("\(a.createdBy ?? "?") · \(relativeTime(a.createdAt, now: now))").scaledFont(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Workers with something to do, one per line; the rest behind `+ n명 일 없음` (D P11, H14).
    @ViewBuilder
    private func workers(_ all: [TaskBoardWorker]) -> some View {
        if !all.isEmpty {
            let busy = all.filter { $0.assigned + $0.reviewing > 0 }
            let idle = all.count - busy.count
            VStack(alignment: .leading, spacing: 6) {
                heading("워커별 맡은 일", more: idle > 0 ? (allWorkers ? "일 있는 워커만" : "+ \(idle)명 일 없음", { allWorkers.toggle() }) : nil)
                if busy.isEmpty && !allWorkers {
                    Text("맡은 일이 있는 워커가 없습니다").scaledFont(.callout).foregroundStyle(.secondary)
                }
                ForEach(allWorkers ? all : busy, id: \.name) { w in workerLine(w) }
            }
        }
    }

    private func workerLine(_ w: TaskBoardWorker) -> some View {
        let row = workerRow(w.name)
        let counts = [w.assigned > 0 ? "담당 \(w.assigned)" : nil, w.reviewing > 0 ? "리뷰 \(w.reviewing)" : nil].compactMap { $0 }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let row { StatusIconView(badge: row.badge, style: .callout) }
            Text(w.name).scaledFont(.body, weight: .semibold)
            Text(counts.isEmpty ? "일 없음" : counts.joined(separator: " · ")).scaledFont(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("보드에서 보기", systemImage: "arrow.up.forward.square") { if let row { select(row.id) } }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .accessibilityLabel("보드에서 \(w.name) 보기")
                .disabled(row == nil)
                .help(row == nil ? "\(w.name): 실행 중인 워커가 아닙니다" : "보드에서 \(w.name) 보기")
        }
    }

    /// Three columns, when | who | what (H13), three lines until 모두 보기.
    @ViewBuilder
    private func recent(_ lines: [ActivityLine]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                heading("최근 활동", more: lines.count > 3 ? (allRecent ? "접기" : "모두 보기", { allRecent.toggle() }) : nil)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(Array(lines.prefix(allRecent ? lines.count : 3).enumerated()), id: \.offset) { _, l in
                        GridRow {
                            Text(l.time).monospacedDigit().foregroundStyle(.secondary)
                            Text(l.who).fontWeight(.semibold)
                            Text(l.what).lineLimit(2).help(l.what)
                        }
                        .scaledFont(.callout)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

/// A task line's menu and its VoiceOver actions: the same items (H9, H15).
struct TaskActions: ViewModifier {
    let items: [TaskMenuItem]
    let run: (TaskMenuItem) -> Void
    let can: (TaskMenuItem) -> Bool

    func body(content: Content) -> some View {
        items.reduce(AnyView(content)) { view, item in
            can(item) ? AnyView(view.accessibilityAction(named: item.title) { run(item) }) : view
        }
        .contextMenu {
            ForEach(items, id: \.self) { item in
                Button(item.title) { run(item) }.disabled(!can(item))
            }
        }
    }
}

/// A state color's 1 pt edge on a tint when Increase Contrast is on (H17).
struct IncreasedContrastBorder: ViewModifier {
    let color: Color
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.overlay {
            if contrast == .increased { RoundedRectangle(cornerRadius: radius).strokeBorder(color, lineWidth: 1) }
        }
    }
}

/// A finding's severity (design §4.3, D §2.6): 필수 filled red, 권장 orange outline, 낮음 gray outline, in colors that
/// read 4.5:1 (H7).
struct SeverityTag: View {
    let severity: String
    let count: Int
    /// A list line's tag says its own severity's count even when it is 1 (`권장 1`).
    var counted = false

    init(severity: String, count: Int) {
        self.severity = severity
        self.count = count
    }

    init(tag: SeverityCount) {
        self.init(severity: tag.severity, count: tag.count)
        counted = true
    }

    var text: String { counted || count > 1 ? severityCount(severity, count) : severityText[severity] ?? severity }

    var body: some View {
        let must = severity == "must"
        let color: Color = must ? TaskColor.red : severity == "should" ? TaskColor.orange : TaskColor.gray
        let word = severityText[severity] ?? severity
        Text(text)
            .scaledFont(.caption1, weight: .bold)
            .foregroundStyle(must ? TaskColor.onRed : color)
            .padding(.horizontal, 4)
            .background(must ? color : .clear, in: .rect(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color, lineWidth: must ? 0 : 1))
            .fixedSize()
            .help(counted ? "열린 \(word) 지적 \(count)건" : "열린 지적 \(count)건, 가장 높은 심각도 \(word)")
            .accessibilityLabel(counted ? "열린 \(word) 지적 \(count)건" : "열린 지적 \(count)건, 가장 높은 것은 \(word)")
    }
}

/// Lays its views left to right and wraps to the next line when the width runs out (design §8 R7).
struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.items + [i], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([i], size.width, size.height))
            }
        }
        return rows
    }
}

/// Where the list and a task's detail sit side by side (T89). Narrower than `beside`, the detail takes the list's
/// place (design §8 R3). Beside each other, the list keeps its tag, id and a readable title, the detail its body.
struct SplitLimits: Equatable {
    var beside: CGFloat
    var minList: CGFloat
    var minDetail: CGFloat

    init(scale: Double) {
        beside = 760 * scale
        minList = 320 * scale
        minDetail = 380 * scale
    }

    /// The list's width in a split `total` wide (divider excluded): the stored width, or half without one,
    /// held so neither side falls under its least width. A split too narrow for both gives the list its least.
    func listWidth(stored: CGFloat?, total: CGFloat) -> CGFloat {
        max(minList, min(stored ?? total / 2, total - minDetail))
    }
}

/// The task list beside the picked task's detail in the system split view (T89): the divider drags with its own
/// resize cursor, each side holds its least width, and a dragged width is saved for the next board.
/// A window resize goes to the detail; the list keeps its width.
/// Each side is a SwiftUI graph of its own, so the window's menu actions are published again inside it: with the
/// keyboard in the list or the detail, Esc, ⌘R and the detail's 다시 읽기 still reach the window (T93).
struct TaskBoardSplit<List: View, Detail: View>: NSViewRepresentable {
    let limits: SplitLimits
    let stored: CGFloat?
    let save: (CGFloat) -> Void
    var navigation: WindowNavigation?
    /// The 보기 › 묶음 menu's target, published again inside each side as the navigation is.
    var arrangement: PanelArrange?
    /// The View menu's 상태별 / 순서 items (T214), published again as the navigation is.
    var boardMode: BoardModeControl?
    /// Without a detail, the list takes the whole width and the divider goes.
    var detailShown = true
    let list: List
    let detail: Detail

    struct Side<Content: View>: View {
        let content: Content
        let navigation: WindowNavigation?
        var arrangement: PanelArrange?
        var boardMode: BoardModeControl?
        var body: some View {
            content.focusedSceneValue(\.windowNavigation, navigation).focusedSceneValue(\.panelArrange, arrangement)
                .focusedSceneValue(\.boardMode, boardMode)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(list: NSHostingView(rootView: Side(content: list, navigation: navigation, arrangement: arrangement, boardMode: boardMode)),
                    detail: NSHostingView(rootView: Side(content: detail, navigation: navigation, arrangement: arrangement, boardMode: boardMode)))
    }

    func makeNSView(context: Context) -> Split {
        let c = context.coordinator
        let split = Split()
        split.isVertical = true
        split.dividerStyle = .thin
        // the least widths come from the constraints below, not from the content
        c.list.sizingOptions = []
        c.detail.sizingOptions = []
        split.addArrangedSubview(c.list)
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        c.minList.priority = .defaultHigh + 49
        c.minDetail.priority = .defaultHigh + 49
        c.minList.isActive = true
        updateNSView(split, context: context)
        return split
    }

    /// All the space offered: with the list alone in it, the split would otherwise take the list's width (R9 M1).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Split, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSView(_ split: Split, context: Context) {
        let c = context.coordinator
        c.list.rootView = Side(content: list, navigation: navigation, arrangement: arrangement, boardMode: boardMode)
        c.detail.rootView = Side(content: detail, navigation: navigation, arrangement: arrangement, boardMode: boardMode)
        c.minList.constant = limits.minList
        c.minDetail.constant = limits.minDetail
        split.dragged = save
        if c.shown != detailShown {
            // without a detail its view leaves the split, and the list takes the whole width; the list's view stays
            // the same one either way. Back, the divider goes back to its place.
            c.shown = detailShown
            if detailShown {
                split.addArrangedSubview(c.detail)
                split.setHoldingPriority(.defaultLow, forSubviewAt: 1)
                c.minDetail.isActive = true
            } else {
                c.minDetail.isActive = false
                split.removeArrangedSubview(c.detail)
                c.detail.removeFromSuperview()
            }
            if detailShown {
                split.place = { [weak split] in
                    guard let split else { return }
                    split.setPosition(limits.listWidth(stored: stored, total: split.bounds.width - split.dividerThickness), ofDividerAt: 0)
                }
                split.needsLayout = true
            }
        }
    }

    @MainActor final class Coordinator {
        let list: NSHostingView<Side<List>>
        let detail: NSHostingView<Side<Detail>>
        let minList: NSLayoutConstraint
        let minDetail: NSLayoutConstraint
        /// Whether the detail side shows; nil before the first update.
        var shown: Bool?

        init(list: NSHostingView<Side<List>>, detail: NSHostingView<Side<Detail>>) {
            self.list = list
            self.detail = detail
            minList = list.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
            minDetail = detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        }
    }

    /// Puts the divider once, at the first layout that has a width, and saves the list's width after each drag.
    /// A split view gets mouse down only on its divider and tracks the drag inside it, so a layout or a window
    /// resize never saves.
    final class Split: NSSplitView {
        var place: (() -> Void)?
        var dragged: (CGFloat) -> Void = { _ in }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            dragged(arrangedSubviews[0].frame.width)
        }

        override func layout() {
            super.layout()
            guard bounds.width > 0, let p = place else { return }
            place = nil
            p()
        }
    }
}
