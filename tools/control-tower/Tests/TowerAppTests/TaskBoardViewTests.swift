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
