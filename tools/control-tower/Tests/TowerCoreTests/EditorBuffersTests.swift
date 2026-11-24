import Testing
import TowerCore

private let a = "/w/a.swift"

/// `a` open, unlocked, with the base hash "h1"; dirty when `dirty`.
private func opened(dirty: Bool = false) -> EditorBuffers {
    var b = EditorBuffers()
    b.open(a, hash: "h1", readOnly: true)
    b.setReadOnly(a, false)
    if dirty { #expect(b.setDirty(a, true) == nil) }
    return b
}

@Test func aFileOpensLockedAsATabAndShows() {
    var b = EditorBuffers()
    b.open(a, hash: "h1", readOnly: true)
    b.open("/w/b.swift", hash: "h2", readOnly: true)
    #expect(b.tabs == [a, "/w/b.swift"] && b.shown == "/w/b.swift")
    #expect(b.files[a] == EditorBuffer(base: "h1"))
    #expect(b.files[a]?.readOnly == true && b.unsaved.isEmpty && b.banner == nil)
    // opening it again shows it, and adds no tab
    b.open(a, hash: "h1", readOnly: true)
    #expect(b.tabs == [a, "/w/b.swift"] && b.shown == a)
}

@Test func anOpenFileKeepsItsLockAndItsEditWhenItIsOpenedAgain() {
    var b = opened(dirty: true)
    b.open("/w/b.swift", hash: "h2", readOnly: true)
    b.open(a, hash: "h1", readOnly: true)
    #expect(b.files[a]?.readOnly == false && b.files[a]?.dirty == true && b.unsaved == [a])
    // opened again after the disk changed under the edit: the banner, not a new base
    b.open(a, hash: "h9", readOnly: true)
    #expect(b.files[a]?.base == "h1" && b.banner == .changed(path: a))
}

@Test func aCleanBufferReloadsWhenTheDiskChanges() {
    var b = opened()
    #expect(b.diskChanged(a, hash: "h2") == .reload(path: a, force: false))
    #expect(b.banner == nil, "no banner for a clean buffer")
    b.reloaded(a, hash: "h2", applied: true)
    #expect(b.files[a] == EditorBuffer(base: "h2", readOnly: false))
    #expect(b.diskChanged("/w/not-open.swift", hash: "h2") == nil)
}

@Test func aDirtyBufferKeepsItsTextAndShowsTheBanner() {
    var b = opened(dirty: true)
    #expect(b.diskChanged(a, hash: "h2") == nil, "nothing is sent to the page")
    #expect(b.banner == .changed(path: a))
    #expect(b.files[a]?.base == "h1" && b.files[a]?.dirty == true)
    // the banner is the shown file's
    b.open("/w/b.swift", hash: "hb", readOnly: true)
    #expect(b.banner == nil)
    b.open(a, hash: "h2", readOnly: true)
    #expect(b.banner == .changed(path: a))
}

/// The page is asked to reload a buffer Swift held clean, but a key was typed first: the page keeps the text.
@Test func aReloadThePageRefusedBecomesTheBanner() {
    var b = opened()
    #expect(b.diskChanged(a, hash: "h2") == .reload(path: a, force: false))
    b.reloaded(a, hash: "h2", applied: false)
    #expect(b.files[a]?.dirty == true && b.banner == .changed(path: a))
}

@Test func theAppsOwnSaveAndAChangeUndoneAreNoChange() {
    var b = opened(dirty: true)
    b.saved(a, hash: "h2")
    #expect(b.files[a] == EditorBuffer(base: "h2", readOnly: false))
    #expect(b.setDirty(a, true) == nil)
    // the watch reports the save a moment later, the user already typing again
    #expect(b.diskChanged(a, hash: "h2") == nil && b.banner == nil)
    // a worker's change, then its revert
    #expect(b.diskChanged(a, hash: "h3") == nil && b.banner == .changed(path: a))
    #expect(b.diskChanged(a, hash: "h2") == nil && b.banner == nil)
}

@Test func onlyOverwriteAsksForAWriteAndOnlyOverTheBytesTheBannerWasFor() {
    for choice in BannerChoice.allCases {
        var b = opened(dirty: true)
        _ = b.diskChanged(a, hash: "h2")
        let effect = b.choose(choice, a)
        switch choice {
        case .compare:
            #expect(effect == .compare(path: a))
            #expect(b.banner == .changed(path: a), "comparing decides nothing")
        case .reload:
            #expect(effect == .reload(path: a, force: true))
            b.reloaded(a, hash: "h2", applied: true)
            #expect(b.files[a] == EditorBuffer(base: "h2", readOnly: false) && b.banner == nil)
        case .overwrite:
            #expect(effect == .overwrite(path: a, diskHash: "h2"))
            b.saved(a, hash: "h4")
            #expect(b.files[a] == EditorBuffer(base: "h4", readOnly: false) && b.banner == nil)
        case .keep:
            #expect(effect == nil)
            #expect(b.banner == nil && b.files[a]?.dirty == true && b.files[a]?.base == "h1")
        }
    }
}

@Test func keptEditsAreAskedAboutAgainWhenTheDiskChangesAgainOrASaveFindsIt() {
    var b = opened(dirty: true)
    _ = b.diskChanged(a, hash: "h2")
    _ = b.choose(.keep, a)
    // the same change reported again (a rescan) stays quiet
    #expect(b.diskChanged(a, hash: "h2") == nil && b.banner == nil)
    #expect(b.diskChanged(a, hash: "h3") == nil && b.banner == .changed(path: a))
    _ = b.choose(.keep, a)
    b.conflict(a, diskHash: "h3")
    #expect(b.banner == .changed(path: a), "a save that wrote nothing says why")
    #expect(b.choose(.overwrite, a) == .overwrite(path: a, diskHash: "h3"))
}

@Test func aChoiceWithoutABannerDoesNothing() {
    var clean = opened()
    var dirty = opened(dirty: true)
    for choice in BannerChoice.allCases {
        #expect(clean.choose(choice, a) == nil)
        #expect(dirty.choose(choice, a) == nil, "the disk did not change")
        #expect(dirty.choose(choice, "/w/not-open.swift") == nil)
    }
}

@Test func anEditUndoneUnderAChangedDiskReloads() {
    var b = opened(dirty: true)
    _ = b.diskChanged(a, hash: "h2")
    #expect(b.setDirty(a, false) == .reload(path: a, force: false))
    #expect(b.setDirty(a, false) == nil, "said once")
    var plain = opened(dirty: true)
    #expect(plain.setDirty(a, false) == nil)
}

@Test func aDeletedFileKeepsItsBufferAndComesBack() {
    var b = opened(dirty: true)
    #expect(b.diskChanged(a, hash: nil) == .deleted(path: a))
    #expect(b.banner == .deleted(path: a, dirty: true) && b.unsaved == [a])
    #expect(b.diskChanged(a, hash: nil) == nil, "said once")
    #expect(b.choose(.overwrite, a) == nil, "nothing brings a deleted file back")
    // written again by a worker: other bytes under the edit
    #expect(b.diskChanged(a, hash: "h2") == nil && b.banner == .changed(path: a))

    // deleted, then there again with the bytes the edit started from (a checkout and back): the page is told, to
    // unlock the file, keeps the edit, and that is no change of the disk
    var back = opened(dirty: true)
    _ = back.diskChanged(a, hash: nil)
    #expect(back.diskChanged(a, hash: "h1") == .reload(path: a, force: false))
    back.reloaded(a, hash: "h1", applied: false)
    #expect(back.banner == nil && back.files[a]?.dirty == true && back.files[a]?.disk == .same)

    var clean = opened()
    #expect(clean.diskChanged(a, hash: nil) == .deleted(path: a))
    #expect(clean.banner == .deleted(path: a, dirty: false))
    #expect(clean.diskChanged(a, hash: "h1") == .reload(path: a, force: false), "the same bytes again: the page unlocks through a reload")
    #expect(clean.banner == nil)
}

// MARK: - A file renamed or trashed from the tree (G4 I9)

@Test func aRenamedFileKeepsItsBufferUnderTheNewPath() {
    var b = opened(dirty: true)
    b.open("/w/b.swift", hash: "hb", readOnly: true)
    b.open(a, hash: "h1", readOnly: true)
    let moved = b.renamed(from: a, to: "/w/z.swift")
    #expect(moved.map(\.from) == [a] && moved.map(\.to) == ["/w/z.swift"])
    #expect(b.tabs == ["/w/z.swift", "/w/b.swift"] && b.shown == "/w/z.swift")
    #expect(b.files[a] == nil)
    #expect(b.files["/w/z.swift"]?.dirty == true && b.files["/w/z.swift"]?.readOnly == false && b.files["/w/z.swift"]?.base == "h1")
    #expect(b.unsaved == ["/w/z.swift"])
    // a file that is not open moves nothing
    #expect(b.renamed(from: "/w/not-open.swift", to: "/w/other.swift").isEmpty)
}

@Test func aRenamedFolderMovesEveryBufferUnderItAndNoOther() {
    var b = EditorBuffers()
    for path in ["/w/src/a.swift", "/w/src/deep/b.swift", "/w/src2/c.swift", "/w/srcfile"] { b.open(path, hash: "h", readOnly: true) }
    let moved = b.renamed(from: "/w/src", to: "/w/lib")
    #expect(moved.map(\.to) == ["/w/lib/a.swift", "/w/lib/deep/b.swift"])
    #expect(b.tabs == ["/w/lib/a.swift", "/w/lib/deep/b.swift", "/w/src2/c.swift", "/w/srcfile"])
    #expect(b.shown == "/w/srcfile")
}

@Test func theOpenFilesUnderATrashedPathAreFoundAndMarkedDeleted() {
    var b = EditorBuffers()
    for path in ["/w/src/a.swift", "/w/src/deep/b.swift", "/w/src2/c.swift"] { b.open(path, hash: "h", readOnly: true) }
    #expect(b.open(under: "/w/src") == ["/w/src/a.swift", "/w/src/deep/b.swift"])
    #expect(b.open(under: "/w/src/a.swift") == ["/w/src/a.swift"])
    #expect(b.open(under: "/w/sr").isEmpty)
    b.open("/w/src/a.swift", hash: "h", readOnly: true)
    #expect(b.diskChanged("/w/src/a.swift", hash: nil) == .deleted(path: "/w/src/a.swift"))
    #expect(b.banner == .deleted(path: "/w/src/a.swift", dirty: false))
    // the watch reports the same deletion a moment later: said once
    #expect(b.diskChanged("/w/src/a.swift", hash: nil) == nil)
}
