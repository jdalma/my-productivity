import Foundation
import os
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

/// Reads that count their calls: the diff is `loaded("let a = 1")`, the file list `files`.
private struct CountedReads {
    let diffs = OSAllocatedUnfairLock(initialState: 0)
    let lists = OSAllocatedUnfairLock(initialState: 0)

    func reads(files: [String] = ["a.swift", "docs/x.md"]) -> DiffReads {
        let (diffs, lists) = (diffs, lists)
        return DiffReads(diff: { _, _ in diffs.withLock { $0 += 1 }; return loaded("let a = 1") },
                         files: { _, _ in lists.withLock { $0 += 1 }; return files })
    }
}

@MainActor @Test func choosingAWorkspaceReadsNothingUntilTheDiffWindowLoadsIt() async {
    let count = CountedReads()
    let s = ChangesState(reads: count.reads())
    // what selecting a worker did before T72: the state learns the workspace
    s.select(workspace: "/w")
    await s.loadFullTree()
    #expect(count.diffs.withLock { $0 } == 0)
    #expect(s.diff(for: "/w") == nil)
    await s.load(workspace: "/w")
    #expect(count.diffs.withLock { $0 } == 1)
    #expect(s.diff(for: "/w")?.uncommitted.files.map(\.path) == ["a.swift"])
}

@MainActor @Test func theFileListIsReadOnlyInTheFullViewAndOncePerDiff() async {
    let count = CountedReads()
    let s = ChangesState(reads: count.reads())
    await s.load(workspace: "/w")
    #expect(s.treeMode == .changed)
    await s.loadFullTree()
    #expect(count.lists.withLock { $0 } == 0)
    #expect(s.fullTree == nil)

    s.treeMode = .all
    await s.loadFullTree()
    #expect(count.lists.withLock { $0 } == 1)
    #expect(s.fullTree?.nodes.map(\.name) == ["docs", "a.swift"])
    #expect(s.fullTree?.changed == [])
    // the 5 s refresh of the same diff, or switching back and forth, lists nothing again
    await s.load(workspace: "/w")
    s.treeMode = .changed
    s.treeMode = .all
    await s.loadFullTree()
    #expect(count.lists.withLock { $0 } == 1)
}

@MainActor @Test func aFailedListSaysSoAndKeepsNoTree() async {
    let s = ChangesState(reads: DiffReads(diff: { _, _ in loaded("let a = 1") }, files: { _, _ in nil }))
    await s.load(workspace: "/w")
    s.treeMode = .all
    await s.loadFullTree()
    #expect(s.fullTree == nil)
    #expect(s.fullTreeFailed)
}

private let docs = TreeLine(ChangeTreeNode(name: "docs", path: "docs", kind: .directory([])), part: nil)

@MainActor @Test func aFolderOpensAndClosesAgainstItsDefault() {
    let s = ChangesState(reads: CountedReads().reads())
    #expect(!s.tree.isOpen(docs, byDefault: false))
    s.tree.setOpen(docs, true, byDefault: false)
    #expect(s.tree.isOpen(docs, byDefault: false))
    #expect(s.tree.flippedFolders == ["a:docs"])
    s.tree.setOpen(docs, false, byDefault: false)
    #expect(s.tree.flippedFolders.isEmpty)
    // closing an open-by-default folder is the flip; reopening it forgets the flip
    s.tree.setOpen(docs, false, byDefault: true)
    #expect(!s.tree.isOpen(docs, byDefault: true))
    s.tree.setOpen(docs, true, byDefault: true)
    #expect(s.tree.flippedFolders.isEmpty)
}

@MainActor @Test func aPickedFileShowsInTheDiffOrTheFileViewAndAFolderShowsNothing() async {
    let s = ChangesState(reads: CountedReads().reads())
    await s.load(workspace: "/w")
    s.pick(docs)
    #expect(s.scrollTarget == nil && s.history.current == nil && s.tree.flippedFolders.isEmpty)

    // a changed file of the full view: found in the uncommitted section
    s.pick(.file("a.swift"))
    #expect(s.scrollTarget == DiffFileKey(part: .uncommitted, path: "a.swift"))
    #expect(s.isExpanded(DiffFileKey(part: .uncommitted, path: "a.swift")))
    #expect(s.history.current == nil)
    // an unchanged file: the file view, from its first line
    s.pick(.file("docs/x.md"))
    #expect(s.history.current == CodeLocation(path: "docs/x.md", line: 1))
    // a changed view's line keeps its own section, and the diff comes back over the file view
    s.pick(.file("b.swift", part: .committed))
    #expect(s.scrollTarget == DiffFileKey(part: .committed, path: "b.swift"))
    #expect(s.history.current == nil)
}

@MainActor @Test func anotherWorkspaceForgetsTheFoldersAndTheFullTree() async {
    let s = ChangesState(reads: CountedReads().reads())
    s.select(workspace: "/w")
    await s.load(workspace: "/w")
    s.treeMode = .all
    await s.loadFullTree()
    s.tree.setOpen(docs, true, byDefault: false)
    s.select(workspace: "/w2")
    #expect(s.tree.flippedFolders.isEmpty)
    #expect(s.fullTree == nil)
}

@MainActor @Test func aNewDiffWindowShowsItsTreeWhateverTheOldStoredChoiceSays() {
    let key = "diffTreeVisible"  // the setting before T80, kept on machines that hid the old right-hand tree
    let old = UserDefaults.standard.object(forKey: key)
    defer { UserDefaults.standard.set(old, forKey: key) }
    UserDefaults.standard.set(false, forKey: key)
    let window = ChangesState()
    #expect(window.treeVisible)
    window.treeVisible = false
    // hiding it in one window leaves the next one alone
    #expect(ChangesState().treeVisible)
}

/// T123 R6 L1: walking the tree with ↑↓ leaves what it passed as it was. A changed file it unfolded folds again when
/// the next file is picked, one the user had open stays open, and unchanged files passed add nothing to the history.
@MainActor @Test func walkingTheTreeLeavesThePassedFilesFoldedAndTheHistoryAsItWas() async {
    let s = ChangesState(reads: CountedReads().reads())
    await s.load(workspace: "/w")
    let a = DiffFileKey(part: .uncommitted, path: "a.swift")
    let b = DiffFileKey(part: .committed, path: "b.swift")
    let c = DiffFileKey(part: .committed, path: "c.swift")
    s.toggle(c)  // the user's own
    s.pick(.file("a.swift"))
    s.pick(.file("b.swift", part: .committed))
    #expect(!s.isExpanded(a), "passed: folded again")
    #expect(s.isExpanded(b), "the picked file is open")
    s.pick(.file("c.swift", part: .committed))
    s.pick(.file("a.swift"))
    #expect(!s.isExpanded(b))
    #expect(s.isExpanded(c), "open before the walk: stays open")
    #expect(s.isExpanded(a))

    for path in ["docs/x.md", "docs/y.md", "docs/z.md"] { s.pick(.file(path)) }
    #expect(s.history.current == CodeLocation(path: "docs/z.md", line: 1))
    s.history.back()
    #expect(s.history.current == nil, "one step back is the diff, not the files passed")
}

/// R46 L2: a file the pick unfolded becomes the user's once the user folds or unfolds it: picking the next file then
/// leaves it as the user left it.
@MainActor @Test func aPickedFileTheUserTogglesStaysAsTheUserLeftIt() async {
    let s = ChangesState(reads: CountedReads().reads())
    await s.load(workspace: "/w")
    let a = DiffFileKey(part: .uncommitted, path: "a.swift")
    s.pick(.file("a.swift"))
    #expect(s.isExpanded(a))
    s.toggle(a)
    s.toggle(a)
    s.pick(.file("b.swift", part: .committed))
    #expect(s.isExpanded(a), "unfolded by the user: stays open")
}
