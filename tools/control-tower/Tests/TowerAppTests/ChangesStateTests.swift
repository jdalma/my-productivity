import Testing
@testable import TowerApp

private let a = DiffFileKey(part: .uncommitted, path: "src/a.swift")
private let b = DiffFileKey(part: .committed, path: "src/b.swift")

@MainActor @Test func filesStartFoldedAndANewFileStaysFolded() {
    let s = ChangesState()
    s.select(workspace: "/w")
    #expect(!s.isExpanded(a))
    s.toggle(a)
    #expect(s.isExpanded(a))
    // a file that shows up on a later refresh has no entry, so it is folded
    #expect(!s.isExpanded(b))
    s.toggle(a)
    #expect(!s.isExpanded(a))
}

@MainActor @Test func revealUnfoldsTheFileAndItsSectionAndAsksForAScroll() {
    let s = ChangesState()
    s.showCommitted = false
    s.reveal(b)
    #expect(s.isExpanded(b))
    #expect(s.showCommitted)
    #expect(s.scrollTarget == b)
}

@MainActor @Test func foldingAllAndUnfoldingAllTouchOnlyTheGivenKeys() {
    let s = ChangesState()
    s.toggle(b)
    s.setExpanded([a], true)
    #expect(s.isExpanded(a) && s.isExpanded(b))
    s.setExpanded([a], false)
    #expect(!s.isExpanded(a) && s.isExpanded(b))
}

@MainActor @Test func switchingWorkspaceFoldsEverythingAgain() {
    let s = ChangesState()
    s.select(workspace: "/w1")
    s.toggle(a)
    s.select(workspace: "/w1")
    #expect(s.isExpanded(a))
    s.select(workspace: "/w2")
    #expect(!s.isExpanded(a))
}

@Test func treeWidthStaysWithinBounds() {
    #expect(clampTreeWidth(100) == 160)
    #expect(clampTreeWidth(300) == 300)
    #expect(clampTreeWidth(900) == 480)
}

@testable import TowerCore

private func loaded(_ text: String) -> Loaded {
    let lines = [DiffLine(kind: .hunk, old: nil, new: nil, text: "@@ -1 +1 @@"), DiffLine(kind: .added, old: nil, new: 1, text: text)]
    let d = WorkspaceDiff(toplevel: "/w", base: .none, committed: nil,
                          uncommitted: DiffSection(files: [FileDiff(path: "a.swift", added: 1, removed: 0, binary: false, lines: lines)], untracked: []))
    return Loaded(workspace: "/w", result: .diff(d), candidates: [])
}

@MainActor private func colored(_ s: ChangesState) -> Bool {
    s.diff(for: "/w")?.uncommitted.files[0].lines[1].syntax.isEmpty == false
}

@MainActor @Test func aRefreshOfTheSameDiffDoesNotDropItsHighlight() async {
    let s = ChangesState()
    s.accept(loaded("let a = 1"))
    #expect(!colored(s))  // one color first
    let t = Task { await s.highlight(s.fetched) }
    s.accept(loaded("let a = 1"))  // the 5 s refresh: same diff, nothing reassigned
    await t.value
    #expect(colored(s))
}

@MainActor @Test func aCancelledHighlightIsRedoneAndASupersededOneIsDropped() async {
    let s = ChangesState()
    s.accept(loaded("let a = 1"))
    let t = Task { await s.highlight(s.fetched) }
    t.cancel()
    await t.value
    #expect(!colored(s))
    await s.highlight(s.fetched)  // the task runs again, as .task(id:) does when the view comes back
    #expect(colored(s))

    let a = s.fetched
    let old = Task { await s.highlight(a) }
    s.accept(loaded("let b = 2"))
    await old.value
    #expect(s.diff(for: "/w")?.uncommitted.files[0].lines[1].text == "let b = 2")
    #expect(!colored(s))
}
