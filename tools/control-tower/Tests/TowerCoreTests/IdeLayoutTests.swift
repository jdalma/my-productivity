import Foundation
import Testing
@testable import TowerCore

// The board's IDE area (G4 I5): editor over terminal by a ratio kept per worktree, the tree's width kept for all,
// the tree shown or folded away.

@Test func theEditorAndTerminalShareTheHeightByTheWorktreesRatio() {
    var layout = IdeLayout()
    #expect(layout.ratio(for: "/w/a") == IdeLayout.standardRatio)
    layout.setRatio(0.7, for: "/w/a")
    #expect(layout.ratio(for: "/w/a") == 0.7)
    #expect(layout.ratio(for: "/w/b") == IdeLayout.standardRatio)  // another worktree keeps its own

    let h = IdeLayout.heights(total: 601, ratio: 0.7)
    #expect(h.editor + h.terminal + IdeLayout.line == 601)
    #expect(h.editor == 420)
}

@Test func neitherPaneGoesUnderItsLeastHeightWhileThereIsRoom() {
    let min = IdeLayout.minHeight
    #expect(IdeLayout.heights(total: 1001, ratio: 0.01).editor == min)
    #expect(IdeLayout.heights(total: 1001, ratio: 0.99).terminal == min)
    // too short for both: the ratio alone
    let short = IdeLayout.heights(total: 101, ratio: 0.5)
    #expect(short == (editor: 50, terminal: 50))
    // a stored ratio outside 0...1 is the standard one
    #expect(IdeLayout.heights(total: 1001, ratio: .nan) == IdeLayout.heights(total: 1001, ratio: IdeLayout.standardRatio))
}

@Test func aDragOfTheLineGivesTheRatio() {
    #expect(IdeLayout.ratio(editor: 300, total: 601) == 0.5)
    #expect(IdeLayout.ratio(editor: -50, total: 601) == 0)
    #expect(IdeLayout.ratio(editor: 900, total: 601) == 1)
}

@Test func theTreesWidthStaysBetweenItsBoundsAndLeavesTheEditorRoom() {
    #expect(IdeLayout.treeWidth(100, total: 1000) == IdeLayout.minTreeWidth)
    #expect(IdeLayout.treeWidth(900, total: 2000) == IdeLayout.maxTreeWidth)
    #expect(IdeLayout.treeWidth(300, total: 1000) == 300)
    // a narrow area: the editor keeps its least width, the tree gives way
    #expect(IdeLayout.treeWidth(300, total: 400) == 400 - IdeLayout.minEditorWidth)
}

@Test func theLayoutIsKeptAsTextAndABadValueIsTheStandardOne() {
    var layout = IdeLayout()
    layout.setRatio(0.3, for: "/w/a")
    layout.treeWidth = 320
    layout.treeShown = false
    #expect(IdeLayout(stored: layout.stored) == layout)
    #expect(IdeLayout(stored: "") == IdeLayout())
    #expect(IdeLayout(stored: "{not json") == IdeLayout())
}
