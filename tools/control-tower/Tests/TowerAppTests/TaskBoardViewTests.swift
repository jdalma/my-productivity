import AppKit
import Foundation
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

@Test func onlyATaskBoardTeamGetsTheRowAndItsCounts() throws {
    let board = Board(at: "2026-11-12T00:00:00.000Z", teams: [team("plain", board: false), team("boarded", board: true)], loose: [])
    let s = try taskBoard([task("T1", "held"), task("T2", "review"), task("T3", "doing"), task("T4", "ready")].joined(separator: ","))
    let m = sidebarModel(board: board, history: [], query: "", filter: .team, historyLimit: historyPageSize, home: "/Users/me",
                         taskBoards: ["boarded": s, "plain": s])
    let plain = try #require(m.teams.first { $0.name == "plain" })
    let boarded = try #require(m.teams.first { $0.name == "boarded" })
    #expect(!plain.hasTaskBoard && plain.taskCounts == nil, "a team without a board gets no row, whatever was read")
    #expect(boarded.hasTaskBoard)
    #expect(boarded.taskCounts == TaskCounts(action: 1, review: 1, active: 2))
    #expect(teamHeaderDetail(boarded).hasSuffix("· 조치 1"), "the folded team still shows that the board needs pm")
    #expect(!teamHeaderDetail(plain).contains("조치"))

    let unread = sidebarModel(board: board, history: [], query: "", filter: .team, historyLimit: historyPageSize, home: "/Users/me")
    #expect(unread.teams.first { $0.name == "boarded" }?.hasTaskBoard == true, "the row shows before the first read")
    let calm = try taskBoard(task("T2", "review"))
    #expect(!teamHeaderDetail(TeamGroup(name: "x", summary: "", waiting: 0, rows: [], hasTaskBoard: true,
                                        taskCounts: TaskCounts(calm))).contains("조치"), "0 is not shown")
}

@Test func theTaskBoardRowLivesInTheRunningListAndOpensItsTeam() {
    #expect(SidebarPane.live.shown(.taskBoard("t")) == .taskBoard("t"))
    #expect(SidebarPane.history.shown(.taskBoard("t")) == nil)
    var c = CollapsedTeams(stored: "")
    c.toggle("t", query: "")
    #expect(!c.isExpanded("t", query: ""))
    c.reveal(.taskBoard("t"), in: Board(at: "", teams: [], loose: []))
    #expect(c.isExpanded("t", query: ""))
}

@Test func everyTaskStateHasItsOwnShapeAndTheSymbolsExist() {
    let styles = TaskStateStyle.all.map(TaskStateStyle.of)
    #expect(Set(styles.map(\.symbol)).count == 8, "eight shapes: color is never the only cue")
    #expect(Set(styles.map(\.label)).count == 8)
    let groups = [TaskGroup.action, .review, .active, .finished].map { TaskGroupStyle.of($0).symbol }
    for name in styles.map(\.symbol) + groups + ["list.bullet.rectangle", "megaphone"] {
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) on this macOS")
    }
}

@Test func actionLinesSayWhatFreesThem() {
    #expect(actionReasonText(.held).hasPrefix("보류"))
    #expect(actionReasonText(.unassigned).hasPrefix("미배정"))
    #expect(actionReasonText(.openFindings(2)).contains("열린 지적 2건"))
    #expect(actionReasonText(.incompleteReview(missing: ["ticket_path"])).contains("ticket_path"))
}

// T70a: the task detail's styles and the family read state.

@Test func verdictsAndFindingStatesHaveTheirOwnShapesAndTheSymbolsExist() {
    let verdicts = ["approve", "changes", "hold"].map(VerdictStyle.of)
    #expect(Set(verdicts.map(\.symbol)).count == 3 && verdicts.map(\.label) == ["승인", "수정 요청", "보류"])
    let findings = [FindingStatus.open, .fixedPending("T1#1"), .fixedApproved("T1#2"), .backlog, .acceptedLimit, .rejected].map(FindingStyle.of)
    #expect(Set(findings.map(\.label)).count == 6)
    #expect(findings[2].label == "수정됨 (T1#2)" && findings[5].struck)
    #expect(findings.filter { $0.color != .secondary }.map(\.label) == ["열림", "수정됨 (T1#2)"], "only open and approved fixes stand out")
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

// T70b: the recent activity in the screen's words (D2, D3).

private func event(_ action: String, ref: String, from: String? = nil, to: String? = nil, verdict: String? = nil) throws -> TaskBoardEvent {
    func q(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
    let detail = verdict.map { #"{"landing":"T1#1","verdict":"\#($0)"}"# } ?? "null"
    let json = #"{"seq":1,"at":"2026-11-11T07:50:00.000Z","actor":"dev","action":"\#(action)","ref":"\#(ref)","state_from":\#(q(from)),"state_to":\#(q(to)),"detail":\#(detail)}"#
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return try d.decode(TaskBoardEvent.self, from: Data(json.utf8))
}

@Test func recentActivityReadsInKorean() throws {
    func what(_ e: TaskBoardEvent) -> String { String(recentLine(e).split(separator: " · ", maxSplits: 1)[1]) }
    #expect(try what(event("add", ref: "T1", to: "new")) == "T1 추가 (→ 미배정)")
    #expect(try what(event("assign", ref: "T1", from: "new", to: "ready")) == "T1 배정 (미배정 → 착수 전)")
    #expect(try what(event("take", ref: "T1", from: "ready", to: "doing")) == "T1 착수 (착수 전 → 진행 중)")
    #expect(try what(event("land", ref: "T1#1", from: "doing", to: "review")) == "T1#1 완료 기록 (진행 중 → 리뷰 대기)")
    #expect(try what(event("verdict", ref: "R1", from: "review", to: "done", verdict: "approve")) == "R1 판정 승인 (리뷰 대기 → 완료)")
    #expect(try what(event("verdict", ref: "R1", from: "review", to: "changes", verdict: "changes")) == "R1 판정 수정 요청 (리뷰 대기 → 수정 요청)")
    #expect(try what(event("verdict", ref: "R1", from: "review", to: "held", verdict: "hold")) == "R1 판정 보류 (리뷰 대기 → 보류)")
    #expect(try what(event("finding", ref: "R1 L1", from: "open", to: "backlog")) == "R1 L1 지적 정리 (열림 → 나중에)", "a finding's own states")
    #expect(try what(event("note", ref: "T1")) == "T1 메모")
    #expect(try what(event("note", ref: "-")) == "메모", "no target: left out (D3)")
    #expect(try what(event("announce", ref: "-")) == "공지")
    #expect(try what(event("cancel", ref: "T1", from: "held", to: "cancelled")) == "T1 취소 (보류 → 취소)")
    #expect(try recentLine(event("note", ref: "-")).hasSuffix("dev · 메모"))
}

@Test func peopleRolesHaveTheirWords() {
    #expect([PersonRole.registered, .handled, .assignee, .reviewer].map(personRoleText) == ["등록", "처리", "담당", "판정"])
}
