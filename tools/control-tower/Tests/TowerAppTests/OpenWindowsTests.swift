import AppKit
import Testing
@testable import TowerApp

@Test func noWindowLeavesTheMenuBarIconAlone() {
    #expect(OpenWindows().policy == .accessory)
}

@Test func theBoardOrAnyDiffWindowMakesTheAppRegular() {
    #expect(OpenWindows(board: true).policy == .regular)
    #expect(OpenWindows(diffs: [DiffTarget(workspace: "/w")]).policy == .regular)
    #expect(OpenWindows(board: true, diffs: [DiffTarget(workspace: "/w"), DiffTarget(workspace: "/x")]).policy == .regular)
}

@Test func closingTheLastWindowOfEitherKindGoesBackToAccessory() {
    var w = OpenWindows(board: true, diffs: [DiffTarget(workspace: "/w")])
    w.board = false
    #expect(w.policy == .regular)  // a diff window is still up
    w.diffs.remove(DiffTarget(workspace: "/w"))
    #expect(w.policy == .accessory)
    w.diffs.insert(DiffTarget(workspace: "/x"))
    w.diffs.remove(DiffTarget(workspace: "/x"))
    w.board = true
    w.board = false
    #expect(w.policy == .accessory)
}

@Test func aTaskBoardWindowAloneKeepsTheAppRegular() {
    var w = OpenWindows(taskBoards: ["t"])
    #expect(w.policy == .regular)
    w.board = true
    w.taskBoards = []
    #expect(w.policy == .regular)
    w.board = false
    #expect(w.policy == .accessory)
}
