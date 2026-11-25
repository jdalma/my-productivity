import Foundation
import Testing
@testable import TowerCore

// The board's IDE area (G4 I5): the tree's width kept for all worktrees, the tree shown or folded away.

@Test func theTreesWidthStaysBetweenItsBoundsAndLeavesTheEditorRoom() {
    #expect(IdeLayout.treeWidth(100, total: 1000) == IdeLayout.minTreeWidth)
    #expect(IdeLayout.treeWidth(900, total: 2000) == IdeLayout.maxTreeWidth)
    #expect(IdeLayout.treeWidth(300, total: 1000) == 300)
    // a narrow area: the editor keeps its least width, the tree gives way
    #expect(IdeLayout.treeWidth(300, total: 400) == 400 - IdeLayout.minEditorWidth)
}

@Test func theLayoutIsKeptAsTextAndABadValueIsTheStandardOne() {
    var layout = IdeLayout()
    layout.treeWidth = 320
    layout.treeShown = false
    #expect(IdeLayout(stored: layout.stored) == layout)
    #expect(IdeLayout(stored: "") == IdeLayout())
    #expect(IdeLayout(stored: "{not json") == IdeLayout())
}

@Test func aLayoutStoredWithTheTerminalsRatiosStillReads() {
    #expect(IdeLayout(stored: #"{"ratios":{"/w/a":0.3},"treeWidth":320,"treeShown":false}"#).treeWidth == 320)
}
