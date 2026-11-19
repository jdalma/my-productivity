import AppKit
import Foundation
import SwiftUI
import Testing
import TowerCore
@testable import TowerApp

// The task board in the sidebar and its wording (T70). The data and its groups are TowerCore's TaskBoardTests.

private func taskBoard(_ tasks: String, findings: String = "") throws -> TaskBoardStatus {
    let json = """
        {"tasks":[\(tasks)],"workers":[],"open_findings":[\(findings)],"recent":[],"announcements":[]}
        """
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return try d.decode(TaskBoardStatus.self, from: Data(json.utf8))
}

private func task(_ id: String, _ state: String) -> String {
    #"{"id":"\#(id)","parent_id":null,"title":"t","ticket_path":"/tmp/example/t.md","state":"\#(state)","assignee":"dev","reviewer":"rv","priority":100,"constraints":"none"}"#
}

private func team(_ name: String, board: Bool) -> Team {
    var t = Team(name: name, sessionName: "my-team-\(name)", startedAt: nil, attached: true, workers: [])
    t.hasTaskBoard = board
    return t
}

@Test func onlyATaskBoardTeamGetsTheButtonAndItsCounts() throws {
    let board = Board(at: "2026-11-12T00:00:00.000Z", teams: [team("plain", board: false), team("boarded", board: true)], loose: [])
    let s = try taskBoard([task("T1", "held"), task("T2", "review"), task("T3", "doing"), task("T4", "ready")].joined(separator: ","))
    let m = sidebarModel(board: board, history: [], query: "", filter: .claude, historyLimit: historyPageSize, home: "/Users/me",
                         taskBoards: ["boarded": s, "plain": s])
    let plain = try #require(m.teams.first { $0.name == "plain" })
    let boarded = try #require(m.teams.first { $0.name == "boarded" })
    #expect(!plain.hasTaskBoard && plain.taskCounts == nil, "a team without a board gets no button, whatever was read")
    #expect(boarded.hasTaskBoard)
    #expect(boarded.taskCounts == TaskCounts(start: 1, doing: 1, review: 1, held: 1))
    #expect(teamLine(boarded, .full).board == .words && teamLine(boarded, .full).decisions == 0,
            "the line counts decisions only; the panels are the button's tooltip (T152, T184)")
    #expect(teamLine(plain, .full).board == nil && teamLine(plain, .full).decisions == 0)

    let unread = sidebarModel(board: board, history: [], query: "", filter: .claude, historyLimit: historyPageSize, home: "/Users/me")
    #expect(unread.teams.first { $0.name == "boarded" }?.hasTaskBoard == true, "the button shows before the first read")
    let calm = try taskBoard(task("T2", "review"))
    #expect(teamLine(TeamGroup(name: "x", myTurn: 0, rows: [], hasTaskBoard: true,
                               taskCounts: TaskCounts(calm)), .full).decisions == 0, "0 is not shown")
}

/// T184: the task board button's tooltip is the counts, the failure, or the first read; only a failed read changes its shape and wording.
@Test func theTaskBoardButtonTellsReadFailedAndNotYetReadApart() {
    let counts = TaskCounts(user: 1, start: 2, doing: 0, review: 0)
    let read = TaskBoardButtonState(counts: counts, problem: nil)
    #expect(read.tooltip == taskCountsText(counts) && !read.failed && read.label == "작업판 열기")
    let reading = TaskBoardButtonState(counts: nil, problem: nil)
    #expect(reading.tooltip == "작업판을 읽는 중" && !reading.failed && reading.symbol == read.symbol)
    let failed = TaskBoardButtonState(counts: nil, problem: "my-team을 찾지 못함\n경로를 확인하세요")
    #expect(failed.tooltip == "my-team을 찾지 못함\n경로를 확인하세요" && failed.failed)
    #expect(failed.symbol != read.symbol && failed.label != read.label, "not color alone")
    #expect(TaskBoardButtonState(counts: counts, problem: "x").tooltip == read.tooltip, "a read that worked keeps its counts")
    #expect(!TaskBoardButtonState(counts: counts, problem: "x").failed, "a read that worked is not a failed one (R11 L6)")
    // what VoiceOver hears of the board in the team line's label (T189, R11 S3)
    #expect(read.spoken == "작업판 시작 전 2 · 진행 중 0 · 리뷰 중 0", "the line's name says the decisions itself (R11a L4)")
    #expect(reading.spoken == "작업판을 읽는 중")
    #expect(failed.spoken == "my-team을 찾지 못함, 경로를 확인하세요")
}

@Test func aSidebarLineOpensItsTeamsWindowKeepingThePickAndATaskLinePicksItsTask() {
    var p = TaskBoardPicks()
    #expect(p.open("t") == TaskBoardTarget(team: "t"))
    #expect(p.task(of: "t") == nil)
    // a worker's task line: the team's window, the task picked
    #expect(p.open("t", task: "T5") == TaskBoardTarget(team: "t"))
    #expect(p.task(of: "t") == "T5")
    // the sidebar line again: the same window as it was
    #expect(p.open("t") == TaskBoardTarget(team: "t"))
    #expect(p.task(of: "t") == "T5")
    // one pick per team
    p.pick("U1", on: "u")
    p.pick(nil, on: "t")
    #expect(p.task(of: "t") == nil && p.task(of: "u") == "U1")
}

@Test func onlyTheOpenWindowsPicksAreReadAndNoneWithoutAWindow() {
    var p = TaskBoardPicks()
    _ = p.open("t", task: "T5")
    _ = p.open("u", task: "U1")
    #expect(p.reads(open: []).isEmpty)
    #expect(p.reads(open: ["u"]) == [TaskRef(team: "u", task: "U1")])
    #expect(p.reads(open: ["t", "u", "v"]) == [TaskRef(team: "t", task: "T5"), TaskRef(team: "u", task: "U1")])
    // the board window alone reads the boards for the sidebar's counts, never a task's detail
    var w = OpenWindows(board: true)
    #expect(w.readsTaskBoards && p.reads(open: w.taskBoards).isEmpty)
    w.board = false
    #expect(!w.readsTaskBoards)
    w.taskBoards = ["t"]
    #expect(w.readsTaskBoards)
}

@Test func everyTaskStateHasItsOwnShapeAndTheSymbolsExist() {
    let styles = TaskStateStyle.all.map(TaskStateStyle.of)
    #expect(Set(styles.map(\.symbol)).count == styles.count, "a shape each: color is never the only cue")
    #expect(Set(styles.map(\.label)).count == styles.count)
    let panels = TaskPanel.allCases.map { TaskPanelStyle.of($0).symbol }
    for name in styles.map(\.symbol) + panels + ["list.bullet.rectangle", "megaphone.fill", "person.3", "chevron.right", "chevron.down"] {
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) on this macOS")
    }
}

@Test func pmsTagSaysWhatPmDoes() {
    #expect(pmTurnText(.held) == "pm 차례 · 풀거나 취소")
    #expect(pmTurnText(.unassigned) == "pm 차례 · 담당 정하기", "the person tag already says 담당 없음")
    #expect(pmTurnText(.openFindings(2)) == "pm 정리")
    #expect(pmTurnText(.incompleteReview(missing: ["ticket_path", "constraints"])) == "pm 차례 · 티켓, 제약을 채움")
}

// T70a: the task detail's styles and the family read state.

@Test func verdictsAndFindingStatesHaveTheirOwnShapesAndTheSymbolsExist() {
    let verdicts = ["approve", "changes", "hold"].map(VerdictStyle.of)
    #expect(Set(verdicts.map(\.symbol)).count == 3 && verdicts.map(\.label) == ["승인", "수정 요청", "보류"])
    let findings = [FindingStatus.open, .fixedPending("T1#1"), .fixedApproved("T1#2"), .backlog, .acceptedLimit, .rejected].map(FindingStyle.of)
    #expect(Set(findings.map(\.label)).count == 6)
    #expect(findings.map(\.label) == ["열림", "고침 · 리뷰 대기", "수정됨", "나중에 하기로", "한계로 받아들임", "지적 아님"] && findings[5].struck)
    #expect(findings.filter { $0.color != .secondary }.map(\.label) == ["열림", "고침 · 리뷰 대기", "수정됨"], "only what is open or fixed stands out")
    for name in verdicts.map(\.symbol) + findings.map(\.symbol) + ["doc.on.doc"] {
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) on this macOS")
    }
}

@Test func aFailedFamilyReadKeepsTheLastFamily() throws {
    let json = """
        {"root":\(task("T1", "doing")),"tasks":[\(task("T1", "doing"))],"landings":[],"verdicts":[],"findings":[],"notes":[]}
        """
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    let fam = try d.decode(TaskFamily.self, from: Data(json.utf8))
    let ref = TaskRef(team: "t", task: "T1")
    let first = Optional<TaskFamilyState>.none.applying(.success(fam), to: ref)
    let failed = Optional(first).applying(.failure(.timeout), to: ref)
    #expect(failed.family == fam && failed.failure == .timeout, "the detail stays on screen with the failure beside it")
    #expect(Optional(failed).applying(.success(fam), to: ref).failure == nil)
}

// T91: the task board window's words (design v3 D §2.3, §2.4, §2.6, §2.7; H6). Example names only.

private func event(_ seq: Int = 1, _ action: String, ref: String, actor: String = "dev", at: String = "2026-11-11T07:50:00.000Z",
                   from: String? = nil, to: String? = nil, detail: String = "null") throws -> TaskBoardEvent {
    func q(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
    let json = #"{"seq":\#(seq),"at":"\#(at)","actor":"\#(actor)","action":"\#(action)","ref":"\#(ref)","state_from":\#(q(from)),"state_to":\#(q(to)),"detail":\#(detail)}"#
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return try d.decode(TaskBoardEvent.self, from: Data(json.utf8))
}

private func line(_ id: String, _ state: String, assignee: String? = "dev", reviewer: String? = "rv", ticket: String? = "/tmp/example/t.md",
                  title: String = "t", updated: String? = nil, findings: String = "") throws -> (TaskLine, TaskPanel) {
    func q(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
    let t = #"{"id":"\#(id)","parent_id":null,"title":"\#(title)","ticket_path":\#(q(ticket)),"state":"\#(state)","assignee":\#(q(assignee)),"reviewer":\#(q(reviewer)),"priority":100,"constraints":"none","created_by":"pm","created_at":"2026-11-11T07:00:00.000Z","updated_at":\#(q(updated))}"#
    let panels = taskPanels(try taskBoard(t, findings: findings))
    return try #require(panels.lazy.flatMap { p, ls in ls.map { ($0, p) } }.first { $0.0.task.id == id })
}

private func day(_ iso: String) throws -> Date { Date(timeIntervalSince1970: try #require(parseISO(iso)) / 1000) }

private func finding(_ id: String, task: String, _ severity: String) -> String {
    #"{"id":"\#(id)","task_id":"\#(task)","severity":"\#(severity)","summary":"example summary of \#(id)","state":"open"}"#
}

/// T152 (v4 §7.5 S1): a panel's head counts its kinds when it has more than one; a line tags only a few of them.
@Test func aPanelHeadCountsItsKinds() throws {
    let s = try taskBoard([task("T1", "doing"), task("T2", "doing"), task("T3", "changes"), task("T4", "doing"), task("T5", "review"),
                           waitingTask].joined(separator: ","))
    let p = taskPanels(s)
    #expect(panelBreakdown(p[.doing] ?? []) == "작업 중 3 · 수정 요청 1 · 결정 대기 1")
    #expect(panelBreakdown(p[.review] ?? []) == "", "one kind: the panel's name says it")
    let kinds = try ["new", "ready", "cancelled", "waiting"].map { lineKind(try #require(try taskBoard(task("T1", $0)).tasks.first)) }
    #expect(kinds == ["담당 없음", "배정됨", "취소됨", "결정 대기"])
    #expect(taggedKinds == ["수정 요청", "취소됨"])
}

@Test func aParticleFollowsHowTheWordEnds() {
    #expect(withParticle("pm", "이", "가") == "pm이")
    #expect(withParticle("core", "이", "가") == "core가")
    #expect(withParticle("T89", "을", "를") == "T89를")
    #expect(withParticle("T88", "을", "를") == "T88을")
    #expect(withParticle("담당", "이", "가") == "담당이")
    #expect(withParticle("리뷰어", "이", "가") == "리뷰어가")
}

/// T91 R19 L1: the list and the detail put the same particle after the same name, by one rule
@Test func everyNameEndingTakesOneParticleInTheListAndTheDetail() {
    let latin: [(String, String)] = [
        ("detail", "이"), ("pm", "이"), ("design", "이"), ("ping", "이"), ("PING", "이"),
        ("lists", "가"), ("reviewer", "가"), ("core", "가"), ("dev", "가"), ("book", "가"), ("bug", "가"),
    ]
    let hangul: [(String, String)] = [("담당", "이"), ("관제탑", "이"), ("리뷰어", "가"), ("코어", "가")]
    let digits: [(String, String)] = [
        ("w0", "이"), ("w1", "이"), ("w2", "가"), ("w3", "이"), ("w4", "가"),
        ("w5", "가"), ("w6", "이"), ("w7", "이"), ("w8", "이"), ("w9", "가"),
    ]
    for (name, particle) in latin + hangul + digits {
        #expect(withParticle(name, "이", "가") == name + particle, "\(name)")
        #expect(subject(name) == name + particle, "\(name)")
    }
}

/// (c) D §2.7's example, seq 72~82 in shape: one person's five finding changes in a minute are one line
@Test func recentActivityReadsAsSentencesAndMergesAMinutesFindingChanges() throws {
    let base = "2026-11-11T02:4"
    var events = [try event(72, "verdict", ref: "R15", actor: "reviewer", at: base + "6:31.000Z", from: "review", to: "done",
                            detail: #"{"landing":"T87#1","verdict":"approve"}"#)]
    for (i, ref) in ["R1 S1", "R1 L2", "R2 L1", "R4 L1", "R9 S1"].enumerated() {
        events.append(try event(73 + i, "finding", ref: ref, actor: "pm", at: base + "6:5\(i).000Z", from: "open", to: "fixed"))
    }
    events += [try event(78, "add", ref: "T88", actor: "pm", at: base + "7:12.000Z", to: "ready"),
               try event(79, "take", ref: "T88", actor: "core", at: base + "7:21.000Z", from: "ready", to: "doing"),
               try event(80, "land", ref: "T88#1", actor: "core", at: "2026-11-11T02:51:58.000Z", from: "doing", to: "review",
                         detail: #"{"task":"T88","superseded":null}"#),
               try event(81, "verdict", ref: "R16", actor: "reviewer", at: "2026-11-11T02:54:30.000Z", from: "review", to: "done",
                         detail: #"{"landing":"T88#1","verdict":"approve"}"#),
               try event(82, "add", ref: "T89", actor: "pm", at: "2026-11-11T03:46:59.000Z", to: "ready")]
    let now = try day("2026-11-11T04:00:00.000Z")
    let lines = activityLines(events.shuffled(), now: now)
    #expect(lines.map { "\($0.who) \($0.what)" } == [
        "pm T89를 등록",
        "reviewer T88 승인 → 완료",
        "core T88 제출 (1차)",
        "core T88 시작",
        "pm T88을 등록",
        "pm 지적 5건 → 수정됨 (R1 S1, R1 L2, R2 L1, R4 L1, R9 S1)",
        "reviewer T87 승인 → 완료",
    ])
    let changes = try event(1, "verdict", ref: "R1", from: "review", to: "changes", detail: #"{"landing":"T1#2","verdict":"changes"}"#)
    #expect(activityLines([changes], now: now)[0].what == "T1 수정 요청", "the state says it once")
    let other = try event(2, "finding", ref: "R2 L1", actor: "pm", at: "2026-11-11T03:00:00.000Z", from: "open", to: "backlog")
    let two = activityLines([try event(1, "finding", ref: "R1 L1", actor: "pm", at: "2026-11-11T03:00:01.000Z", from: "open", to: "fixed"), other], now: now)
    #expect(two.count == 2, "another state is another line")
    #expect(activityLines([try event(1, "note", ref: "-")], now: now)[0].what == "메모")
}

/// (d) `째` while it goes on, `끝남` once over, and the day's boundary
@Test func aLineTellsHowLongItHasGoneOnOrWhenItEnded() throws {
    let now = try day("2026-11-12T12:00:00.000Z")
    let doing = try line("T1", "doing", updated: "2026-11-12T11:50:00.000Z").0.task
    #expect(taskTime(doing, now: now) == "10분째")
    let longer = try line("T1", "doing", updated: "2026-11-10T11:00:00.000Z").0.task
    #expect(taskTime(longer, now: now) == "2일째")
    let done = try line("T1", "done", updated: "2026-11-12T11:00:00.000Z").0.task
    #expect(taskTime(done, now: now) == "1시간 전 끝남")
    let leftOver = try line("T1", "done", updated: "2026-11-12T11:00:00.000Z", findings: finding("R1 S1", task: "T1", "should"))
    #expect(leftOver.1 == .done && taskTime(leftOver.0.task, now: now) == "1시간 전 끝남", "done with pm's tidying still ended")
    let edge = try line("T1", "done", updated: "2026-11-11T12:00:01.000Z").0.task
    #expect(taskTime(edge, now: now) == "23시간 전 끝남", "just under a day")
    let old = try line("T1", "done", updated: "2026-11-11T11:59:00.000Z").0.task
    let end = try day("2026-11-11T11:59:00.000Z")
    #expect(taskTime(old, now: now) == boardClock(end, withDay: true) + " 끝남", "a day or more: the date")
}

/// (e) only the team's own name and its colon
@Test func aTitleLosesOnlyItsOwnTeamsPrefix() {
    #expect(shownTitle("example: 목록을 고친다", team: "example") == "목록을 고친다")
    #expect(shownTitle("other: 목록을 고친다", team: "example") == "other: 목록을 고친다")
    #expect(shownTitle("example 목록", team: "example") == "example 목록")
    #expect(shownTitle("example: ", team: "example") == "example: ", "nothing left: as it is")
}

/// (f) id, title, assignee, reviewer, finding summaries
@Test func searchLooksInTheLinesWords() throws {
    let s = try taskBoard([task("T1", "doing"), task("T2", "done"), task("T3", "done")].joined(separator: ","),
                          findings: finding("R1 L1", task: "T1", "low"))
    let lines = taskPanels(s).values.flatMap { $0 }
    func found(_ q: String) -> [String] { lines.filter { taskMatches($0, query: q, findings: s.openFindings) }.map(\.task.id).sorted() }
    #expect(found("") == ["T1", "T2", "T3"] && found("  ") == ["T1", "T2", "T3"])
    #expect(found("t3") == ["T3"], "the id, any case")
    #expect(found("SUMMARY of r1") == ["T1"], "a finding's summary")
    #expect(found("rv").count == 3, "the reviewer")
    #expect(found("nothing").isEmpty)
}

/// (h) what VoiceOver reads after the title (T152): where it is, how far, who, its tags, its last record
@Test func voiceOverReadsTheKindTheStepThePeopleAndTheTags() throws {
    let now = try day("2026-11-12T12:00:00.000Z")
    var l = try line("T1", "doing", updated: "2026-11-12T11:27:00.000Z", findings: finding("R1 M1", task: "T1", "must") + "," + finding("R1 L1", task: "T1", "low"))
    l.0.task.progressSummary = ProgressSummary(doneItems: [1, 2], lastNote: "읽기 함수를 썼다", lastAt: "2026-11-12T11:40:00.000Z")
    let at = boardClock(try day("2026-11-12T11:40:00.000Z"))
    #expect(taskAccessibilityValue(l.0, now: now, todoTotal: 5)
            == "작업 중, 33분째. 단계 작업. 할 일 2/5. 담당 dev, 리뷰어 rv. 열린 지적 필수 1 · 낮음 1. 마지막 기록 \(at) · 읽기 함수를 썼다")
    let done = try line("T2", "done", updated: "2026-11-12T11:00:00.000Z", findings: finding("R2 L1", task: "T2", "low"))
    #expect(taskAccessibilityValue(done.0, now: now) == "끝남, 1시간 전 끝남. 단계 끝. 담당 dev, 리뷰어 rv. 열린 지적 낮음 1. pm 정리")
    let cancelled = try line("T3", "cancelled", reviewer: nil)
    #expect(taskAccessibilityValue(cancelled.0, now: now).hasPrefix("취소됨") && taskAccessibilityValue(cancelled.0, now: now).contains("단계 모름"))
}

@Test func aTaskLineOffersItsTicketWhenItHasOneAndItsPeople() throws {
    let t = try #require(taskBoard(task("T1", "doing")).tasks.first)
    #expect(taskMenuItems(t) == [.copyTaskId, .copyTicketPath, .showAssignee("dev"), .showReviewer("rv")])
    #expect(taskMenuItems(t).map(\.title) == ["id 복사", "티켓 경로 복사", "담당 dev 보기", "리뷰어 rv 보기"])
    var bare = t
    bare.ticketPath = ""
    bare.assignee = nil
    bare.reviewer = nil
    #expect(taskMenuItems(bare) == [.copyTaskId])
}

@Test func theStateAndSeverityWordsAreKorean() {
    #expect(["ready", "review", "cancelled"].map { TaskStateStyle.of($0).label } == ["시작 전", "리뷰 중", "취소됨"])
    #expect(TaskPanel.allCases.map { TaskPanelStyle.of($0).label } == ["시작 전", "사용자 결정", "진행 중", "리뷰 중", "보류", "끝남"])
    #expect(["must", "should", "low"].compactMap { severityText[$0] } == ["필수", "권장", "낮음"])
}

@Test func theSubtitleCountsEveryPanelAndSaysWhenItWasRead() throws {
    var st = TaskBoardState()
    let at = Date(timeIntervalSince1970: 1_000_000)
    st.apply(.ok(try taskBoard([task("T1", "doing"), task("T2", "done")].joined(separator: ","))), at: at)
    #expect(taskBoardSubtitle(st) == "시작 전 0 · 진행 중 1 · 리뷰 중 0 · \(boardClock(at))에 읽음", "보류 only when it has one; done not counted")
    st.apply(.ok(try taskBoard([task("T1", "doing"), task("T2", "held")].joined(separator: ","))), at: at)
    #expect(taskBoardSubtitle(st).hasPrefix("시작 전 0 · 진행 중 1 · 리뷰 중 0 · 보류 1 · "))
    st.apply(.failed(.timeout), at: at)
    #expect(taskBoardSubtitle(st).hasSuffix("· 다시 읽지 못함"))
    #expect(taskBoardSubtitle(nil) == "")
}

@Test func aStoredListWidthComesBackHeldToBothSidesLeastWidths() {
    let l = SplitLimits(scale: 1)
    #expect(l.listWidth(stored: nil, total: 1000) == 500)  // never dragged: half
    #expect(l.listWidth(stored: 450, total: 1000) == 450)
    #expect(l.listWidth(stored: 50, total: 1000) == l.minList)
    #expect(l.listWidth(stored: 900, total: 1000) == 1000 - l.minDetail)
    #expect(l.listWidth(stored: 450, total: 600) == l.minList)  // too narrow for both: the list keeps its least
}

@Test func bothLeastWidthsFitWhereTheDetailStopsTakingTheListsPlace() {
    for scale in [0.8, 1, 2.0] {
        let l = SplitLimits(scale: scale)
        #expect(l.minList + l.minDetail + 1 <= l.beside)
        #expect(l.listWidth(stored: nil, total: l.beside) >= l.minList)
        #expect(l.beside - l.listWidth(stored: nil, total: l.beside) >= l.minDetail)
    }
}

@MainActor private final class SeenNavigation { static var reload: Bool? }

private struct NavigationReader: View {
    @FocusedValue(\.windowNavigation) private var nav
    var body: some View {
        TextField("", text: .constant("")).onChange(of: nav?.reload != nil, initial: true) { _, v in SeenNavigation.reload = v }
    }
}

/// T89 R17 L1, T92 R18 L1: a side of the wide split is a SwiftUI graph of its own and does not see the value the
/// window publishes; the split publishes it again, so with the keyboard in a side the window's actions still reach it.
/// The window is never shown (a shown one made a pixel test flaky); the keyboard is put in the side's field by the window itself.
@MainActor @Test func theWindowsActionsReachTheKeyboardInsideASideOfTheSplit() async throws {
    for republished in [false, true] {
        SeenNavigation.reload = nil
        let split = TaskBoardSplit(limits: SplitLimits(scale: 1), stored: nil, save: { _ in },
                                   navigation: republished ? WindowNavigation(reload: {}) : nil,
                                   list: NavigationReader(), detail: Text("d"))
        let w = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: split.focusedSceneValue(\.windowNavigation, WindowNavigation(reload: {})))
        defer { w.contentView = nil }
        func fields(_ v: NSView) -> [NSTextField] { (v as? NSTextField).map { [$0] } ?? v.subviews.flatMap(fields) }
        // laid out and published when the run loop gets to it: later under a loaded run (T130)
        let deadline = Date().addingTimeInterval(10)
        while fields(w.contentView!).isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let field = try #require(fields(w.contentView!).first)
        #expect(w.makeFirstResponder(field))
        try await Task.sleep(for: .milliseconds(200))
        while republished, SeenNavigation.reload != true, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(SeenNavigation.reload == republished, "republished \(republished)")
    }
}

/// T152 (pm 11-16): the sidebar counts by panel; what was pm's and tidy is a tag on the line now.
@Test func theSidebarCountsByPanel() throws {
    let s = try taskBoard([task("T1", "held"), task("T2", "done"), task("T3", "new"), task("T4", "doing")].joined(separator: ","),
                          findings: [finding("R1 L1", task: "T2", "low")].joined(separator: ","))
    #expect(TaskCounts(s) == TaskCounts(start: 1, doing: 1, review: 0, held: 1))
    #expect(TaskCounts(s).panels.map(\.panel) == [.start, .doing, .review, .held])
    #expect(TaskCounts(try taskBoard(task("T1", "doing"))).panels.map(\.panel) == [.start, .doing, .review], "보류 hidden at 0")
}

/// T94 (e): a search opens a folded panel.
@Test func aSearchOpensTheFoldedPanels() {
    #expect(!showsLines(open: false, query: ""))
    #expect(!showsLines(open: false, query: "  "))
    #expect(showsLines(open: false, query: "T2"))
    #expect(showsLines(open: true, query: ""))
}

/// T107 (E2E F2), T152: a line's tags count each severity on its own, on every line.
@MainActor @Test func eachSeverityTagCountsOnlyItsOwnFindings() throws {
    func findings(_ sevs: [String]) -> String {
        sevs.enumerated().map { finding("R1 \($0.offset)", task: "T1", $0.element) }.joined(separator: ",")
    }
    func tags(_ l: (TaskLine, TaskPanel)) -> [String] { l.0.severities.map { SeverityTag(tag: $0).text } }
    #expect(try tags(line("T1", "review", findings: findings(["low", "should"]))) == ["권장 1", "낮음 1"])
    #expect(try tags(line("T1", "held", findings: findings(["must", "must"]))) == ["필수 2"])
    #expect(try tags(line("T1", "changes", findings: findings(["low", "should", "must"]))) == ["필수 1", "권장 1", "낮음 1"])
    #expect(try tags(line("T1", "review")) == [], "no finding, no tag")
    #expect(SeverityTag(severity: "should", count: 1).text == "권장", "the detail's one-finding tag stays a word")
}

/// T108 F3: the detail's head drops the team prefix the list drops, by the same `shownTitle`; the full title is the tooltip.
@MainActor @Test func theDetailsTitleDropsTheTeamPrefixAsTheListDoes() throws {
    let full = "example: 상세 제목을 고친다"
    let json = #"{"id":"T3","parent_id":null,"title":"\#(full)","ticket_path":"/tmp/example/t.md","state":"doing","assignee":"dev","reviewer":"rv","priority":100,"constraints":"none"}"#
    let task = try #require(taskBoard(json).tasks.first)
    #expect(TaskDetailHead(task: task, team: "example").title == "상세 제목을 고친다")
    #expect(TaskDetailHead(task: task, team: "other").title == full, "another team's prefix stays")
}

private let waitingTask = #"{"id":"T9","parent_id":null,"title":"t","ticket_path":"/tmp/example/t.md","state":"waiting","assignee":"dev","reviewer":"rv","priority":100,"constraints":"none","updated_at":"2026-11-12T11:00:00.000Z","waiting":{"question":"Should the example list keep going past the first error, or stop there?\nMore below.","options":[{"label":"A"},{"label":"B"}],"asked_by":"dev","asked_at":"2026-11-12T11:35:00.000Z","resume_state":"doing"}}"#

/// T116, T152: a waiting task stays in the panel it goes back to, with its decision tag; it has waited since it asked.
@Test func aWaitingLineKeepsItsPlaceAndTellsItsDecision() throws {
    let now = try day("2026-11-12T12:00:00.000Z")
    let line = try #require(taskPanels(try taskBoard(waitingTask))[.doing]?.first)
    #expect(line.decisions == ["T9:?"])
    #expect(taskTime(line.task, now: now) == "25분째", "asked_at, not updated_at (60분)")
    #expect(questionHead("Short?") == "Short?" && questionHead("") == "")
    #expect(taskMatches(line, query: "first error", findings: []), "a search finds the question")
    #expect(taskAccessibilityValue(line, now: now).contains("결정 T9:? 대기"))
}

/// T116, T152: the user's decisions are counted first in the sidebar and the subtitle; a board without one reads without.
@Test func theUsersDecisionsAreCountedFirst() throws {
    let s = try taskBoard([waitingTask, task("T1", "held"), task("T2", "doing")].joined(separator: ","))
    #expect(TaskCounts(s) == TaskCounts(user: 1, start: 0, doing: 2, review: 0, held: 1))
    let g = TeamGroup(name: "x", myTurn: 0, rows: [], hasTaskBoard: true, taskCounts: TaskCounts(s))
    #expect(teamLine(g, .full).decisions == 1)
    var st = TaskBoardState()
    let at = Date(timeIntervalSince1970: 1_000_000)
    st.apply(.ok(s), at: at)
    #expect(taskBoardSubtitle(st).hasPrefix("사용자 결정 1 · 시작 전 0 · 진행 중 2 · "))
    let old = try taskBoard([task("T1", "held"), task("T2", "doing")].joined(separator: ","))
    #expect(TaskCounts(old).user == 0)
    st.apply(.ok(old), at: at)
    #expect(taskBoardSubtitle(st) == "시작 전 0 · 진행 중 1 · 리뷰 중 0 · 보류 1 · \(boardClock(at))에 읽음", "no waiting: no decision count")
}

/// T128, T152: a line's to-do items, of the ticket's when read; the last record under it; 제출 직전 when all are done.
@Test func aLineSaysItsToDoAndItsLastRecord() throws {
    var (doing, _) = try line("T1", "doing")
    #expect(todoProgress(doing.task, total: nil) == nil && lastRecord(doing.task) == nil, "no progress: nothing")
    #expect(todoProgress(doing.task, total: 4).map { "\($0.done)/\($0.total)" } == "0/4", "a ticket read: none done yet")
    doing.task.progressSummary = ProgressSummary(doneItems: [1, 2, 2], lastNote: "읽기 함수를\n썼다", lastAt: nil)
    #expect(todoProgress(doing.task, total: 5).map(todoText) == "할 일 2/5")
    #expect(todoProgress(doing.task, total: nil).map(todoText) == "할 일 2개 끝남", "the ticket not read yet")
    #expect(todoProgress(doing.task, total: 0).map(todoText) == "할 일 2개 끝남", "a ticket without a numbered list")
    #expect(lastRecord(doing.task) == "읽기 함수를 썼다", "one line; no time without one")
    #expect(!nearlySubmitted(doing.task, total: 5) && nearlySubmitted(doing.task, total: 2))
    var (review, _) = try line("T3", "review")
    review.task.progressSummary = ProgressSummary(doneItems: [1, 2], lastNote: "n", lastAt: nil)
    #expect(!nearlySubmitted(review.task, total: 2), "submitted already")
    var (done, _) = try line("T4", "done")
    done.task.progressSummary = ProgressSummary(doneItems: [1], lastNote: "n", lastAt: nil)
    #expect(todoProgress(done.task, total: 2) == nil, "over: no to-do")
}

/// T152 (v4 §7.7): a folded panel's head gathers its lines' warnings.
@Test func aFoldedHeadGathersItsLinesWarnings() throws {
    let now = try day("2026-11-12T12:00:00.000Z")
    func lines(_ tasks: [String], findings: String = "") throws -> [TaskPanel: [TaskLine]] {
        taskPanels(try taskBoard(tasks.joined(separator: ","), findings: findings))
    }
    func at(_ t: String, _ updated: String) -> String { t.replacingOccurrences(of: #""constraints":"none""#, with: #""constraints":"none","updated_at":"\#(updated)""#) }
    let start = try lines([at(task("T1", "new"), "2026-11-12T10:00:00.000Z"), at(task("T2", "ready"), "2026-11-12T11:30:00.000Z")])
    #expect(foldedSummary(.start, lines: start[.start]!, decisions: [], now: now) == ["pm 차례 1", "가장 오래 2시간째"])
    let doing = try lines([waitingTask, task("T1", "doing"), task("T2", "changes")],
                          findings: [finding("R1 S1", task: "T1", "should"), finding("R2 S1", task: "T2", "should"), finding("R2 L1", task: "T2", "low")].joined(separator: ","))
    #expect(foldedSummary(.doing, lines: doing[.doing]!, decisions: [], nearly: 1, now: now) == ["결정 대기 1", "권장 2", "제출 직전 1"])
    let s = try taskBoard(waitingTask)
    #expect(foldedSummary(.decisions, lines: [], decisions: openDecisions(s), now: now) == ["Should the example list keep going past …", "25분째"])
    let done = try lines([task("T1", "done"), task("T2", "done")], findings: finding("R1 L1", task: "T1", "low"))
    #expect(foldedSummary(.done, lines: done[.done]!, decisions: [], now: now) == ["pm 정리 1"])
    #expect(foldedSummary(.done, lines: [], decisions: [], now: now) == [])
}

@Test func eachToDoMarkHasItsWord() {
    #expect([TodoStatus.done, .doing, .notYet].map { TodoStyle.of($0).label } == ["끝남", "진행 중", "아직"])
    #expect(Set([TodoStatus.done, .doing, .notYet].map { TodoStyle.of($0).symbol }).count == 3)
}

/// T123 R3 L1: with no history, the 이동 menu's 뒤로/앞으로 are off, as the toolbar's chevrons are.
@Test func backAndForwardAreOffWhereTheHistoryHasNowhereToGo() {
    let board = ScreenHistory()
    #expect(WindowNavigation.step(board.canGoBack) {} == nil)
    #expect(WindowNavigation.step(board.canGoForward) {} == nil)
    var code = CodeHistory()
    #expect(WindowNavigation.step(code.canGoBack) {} == nil)
    code.open(CodeLocation(path: "a.swift", line: 1))
    #expect(WindowNavigation.step(code.canGoBack) {} != nil)
    #expect(WindowNavigation.step(code.canGoForward) {} == nil)
    code.back()
    #expect(WindowNavigation.step(code.canGoForward) {} != nil)
}

/// T123 (E2E 2nd pass, low): with the text bigger, the worker detail's task link reads whole (`T1 보류`), not `T1…`.
/// A link button cut its label when the state icon's width had a fraction (13.2 points at 1.1).
@MainActor @Test func aTaskLinkReadsWholeAtEveryTextSize() throws {
    let s = try taskBoard(task("T1", "held").replacingOccurrences(of: "\"assignee\":\"dev\"", with: "\"assignee\":\"alpha\""))
    let line = WorkerTaskLine(team: "example", tasks: workerTasks("alpha", in: s))
    for scale in [1.0, 1.1, 1.3] {
        let whole = NSHostingController(rootView: HStack(spacing: 3) {
            TaskStateIcon(state: "held", style: .callout)
            Text("T1 \(TaskStateStyle.of("held").label)").scaledFont(.body)
        }.environment(\.boardFontScale, scale)).sizeThatFits(in: CGSize(width: 1000, height: 1000)).width
        let v = NSHostingView(rootView: WorkerTasksView(line: line) { _ in }.environment(\.boardFontScale, scale)
            .frame(width: 400, height: 60, alignment: .topLeading).background(Color.white))
        v.frame = CGRect(x: 0, y: 0, width: 400, height: 60)
        let w = NSWindow(contentRect: v.frame, styleMask: .borderless, backing: .buffered, defer: true)
        w.contentView = v
        defer { w.contentView = nil }
        v.layoutSubtreeIfNeeded()
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        // the rightmost inked column, in points: a cut label ends well short of the whole one
        let perPoint = CGFloat(rep.pixelsWide) / v.bounds.width
        var right = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)).map({ min($0.redComponent, $0.greenComponent, $0.blueComponent) < 0.8 }) ?? false {
                right = x
                break
            }
        }
        #expect(CGFloat(right) / perPoint > whole - 4, "scale \(scale): ink ends at \(CGFloat(right) / perPoint), whole \(whole)")
    }
}

/// T123 R3 L3: with a task's detail open, Esc in the search field clears what was typed and leaves the detail open;
/// in an empty field, or with the keyboard elsewhere, Esc closes the detail as before.
@MainActor @Test func escapeClearsATypedSearchBeforeItClosesTheDetail() async throws {
    final class Seen: NSObject, NSSearchFieldDelegate {
        var text: String?
        func controlTextDidChange(_ note: Notification) { text = (note.object as? NSSearchField)?.stringValue }
    }
    let seen = Seen()
    let field = NSSearchField(frame: CGRect(x: 10, y: 10, width: 200, height: 24))
    field.delegate = seen
    let w = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    w.contentView?.addSubview(field)
    #expect(w.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.insertText("example", replacementRange: editor.selectedRange())
    #expect(field.stringValue == "example")

    #expect(clearSearchForEscape(in: w), "typed text: the field's Esc, not the detail's")
    #expect(field.stringValue == "")
    #expect(seen.text == "", "the delegate hears it, as the board's query binding does")
    #expect(!clearSearchForEscape(in: w), "empty: Esc closes the detail")
    w.makeFirstResponder(nil)
    #expect(!clearSearchForEscape(in: w), "keyboard elsewhere: Esc closes the detail")
}

/// S5, R9 L2: an announcement's line gets the body of the one made nearest its time, within 2 s.
@Test func anAnnouncementsLineGetsTheBodyMadeNearestIt() throws {
    func ann(_ seq: Int, _ body: String, _ at: String) throws -> TaskBoardAnnouncement {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(TaskBoardAnnouncement.self, from: Data(#"{"seq":\#(seq),"body":"\#(body)","created_at":"\#(at)","created_by":"pm"}"#.utf8))
    }
    let anns = [try ann(1, "first", "2026-11-11T07:50:00.000Z"), try ann(2, "second", "2026-11-11T07:50:01.000Z"),
                try ann(3, "much later", "2026-11-11T08:50:00.000Z")]
    let events = [try event(1, "announce", ref: "-", actor: "pm", at: "2026-11-11T07:50:00.001Z"),
                  try event(2, "announce", ref: "-", actor: "pm", at: "2026-11-11T07:50:01.002Z"),
                  try event(3, "announce", ref: "-", actor: "pm", at: "2026-11-11T09:00:00.000Z")]
    let lines = activityLines(events, now: try day("2026-11-11T09:00:00.000Z"), announcements: anns)
    #expect(lines.map(\.what) == ["공지", "공지: second", "공지: first"], "each its own; none within 2 s, no body")
}

/// T168 (R24 L1, R22 L1): one rule for `↓ n개 더`, pinned at its edges. Lines are given by their heights, stacked
/// from 0; the panel shows `height` less the band.
private func edges(_ heights: [CGFloat]) -> (tops: [CGFloat], bottoms: [CGFloat]) {
    var y: CGFloat = 0
    var tops: [CGFloat] = []
    var bottoms: [CGFloat] = []
    for h in heights { tops.append(y); y += h; bottoms.append(y) }
    return (tops, bottoms)
}

@Test func moreBelowCountsALineCutByTheBandAndNothingAtTheEnd() {
    let band = moreBelowBand(scale: 1)
    #expect(band == 20)
    let e = edges([25, 25, 25, 25])  // bottoms 25 50 75 100
    // 70 pt panel: 50 pt visible above the band
    #expect(linesBelow(bottoms: e.bottoms, offset: 0, height: 70, band: band) == 2, "bottom exactly at the band's edge: whole, not counted")
    #expect(linesBelow(bottoms: e.bottoms, offset: 0, height: 69, band: band) == 3, "1 pt short: the second line is cut, counted")
    // R24 L1: 110 pt, the third line's top above the band, its bottom under it
    let r24 = edges([25, 42, 47, 47])  // bottoms 25 67 114 161
    #expect(linesBelow(bottoms: r24.bottoms, offset: 0, height: 110, band: band) == 2, "T11 (top 67, under the band) and T6")
    // scrolled to the end: the lines scroll in the height less the band's strip, so the last line's bottom is its end
    #expect(linesBelow(bottoms: r24.bottoms, offset: r24.bottoms.last! - (110 - band), height: 110, band: band) == 0, "the end: 0")
    // R22 L1: a band taller than a line, at the end
    let tall: CGFloat = 26
    let short = edges([25, 25, 25, 25, 25])
    #expect(linesBelow(bottoms: short.bottoms, offset: short.bottoms.last! + tall - 80, height: 80, band: tall) == 0)
    #expect(linesBelow(bottoms: [], offset: 0, height: 80, band: band) == 0)
}

@Test func moreBelowHoldsAtAnotherFontScale() {
    for scale: CGFloat in [0.8, 1, 1.25, 1.6] {
        let band = moreBelowBand(scale: scale)
        let e = edges([25, 42, 47, 47].map { $0 * scale })
        #expect(linesBelow(bottoms: e.bottoms, offset: 0, height: 110 * scale, band: band) == 2, "scale \(scale)")
        #expect(linesBelow(bottoms: e.bottoms, offset: e.bottoms.last! + band - 110 * scale, height: 110 * scale, band: band) == 0)
    }
}

/// Whole on screen, cut at the top, and hidden below add up to every line, at any scroll and height.
@Test func wholeCutAndBelowAddUpToEveryLine() {
    let e = edges([25, 42, 47, 25, 47, 25])
    let band = moreBelowBand(scale: 1)
    for height: CGFloat in [60, 80, 110, 150, 240] {
        let end = max(0, e.bottoms.last! + band - height)
        for offset in stride(from: CGFloat(0), through: end, by: 3) {
            let whole = linesWhole(tops: e.tops, bottoms: e.bottoms, offset: offset, height: height, band: band)
            let below = linesBelow(bottoms: e.bottoms, offset: offset, height: height, band: band)
            let cutAbove = zip(e.tops, e.bottoms).filter { $0.0 < offset - 0.5 && $0.1 <= offset + height - band + 0.5 }.count
            #expect(whole + cutAbove + below == e.tops.count, "height \(height), offset \(offset)")
        }
    }
}

/// T154 (hig §7.4): where a panel is, as VoiceOver hears it: its place in the one column, or with columns on screen
/// its column too. A layout of two columns in a list with room for one is one column in reading order.
@Test func aPanelsPlaceIsSaidWithItsColumnWhileColumnsAreOnScreen() throws {
    #expect(panelPlaceText(.review, in: TaskPanelPrefs(), room: 1) == "6개 중 4번째")
    #expect(panelPlaceText(.review, in: TaskPanelPrefs(), room: 3) == "6개 중 4번째", "one column kept: one column shown")
    let two = try #require(readPanelPrefs(#"{"t":{"columns":[["start","doing","held"],["decisions","review","done"]]}}"#)["t"])
    #expect(panelPlaceText(.review, in: two, room: 2) == "2단 중 2번째 단, 3개 중 2번째")
    #expect(panelPlaceText(.start, in: two, room: 2) == "2단 중 1번째 단, 3개 중 1번째")
    #expect(panelPlaceText(.review, in: two, room: 1) == "6개 중 5번째", "shown as one column: its place in reading order")
}
