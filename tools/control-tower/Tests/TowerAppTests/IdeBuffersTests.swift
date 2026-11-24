import Foundation
import Testing
import TowerCore
@testable import TowerApp

@MainActor @Test func aTabSaysWhatItsFileHolds() {
    var b = EditorBuffers()
    b.open("/w/src/a.swift", hash: "h1", readOnly: true)
    #expect(IdeTabs.label("/w/src/a.swift", b.files["/w/src/a.swift"]) == "a.swift")
    _ = b.setDirty("/w/src/a.swift", true)
    #expect(IdeTabs.label("/w/src/a.swift", b.files["/w/src/a.swift"]) == "a.swift •")
    _ = b.diskChanged("/w/src/a.swift", hash: "h2")
    #expect(IdeTabs.label("/w/src/a.swift", b.files["/w/src/a.swift"]) == "a.swift • !")
    #expect(IdeTabs.label("/w/gone.swift", nil) == "gone.swift")
}

@MainActor @Test func theBannerOffersTheFourChoicesOnlyForAChangedFile() {
    #expect(BannerChoice.allCases.map(IdeBanner.title) == ["비교", "디스크로 다시 읽기", "덮어쓰기", "내 편집 유지"])
    #expect(Set(BannerChoice.allCases.map(IdeBanner.help)).count == 4)
    #expect(IdeBanner.text(.changed(path: "/w/a")).contains("바뀌었습니다"))
    #expect(!IdeBanner.text(.deleted(path: "/w/a", dirty: false)).contains("저장하지 않은 편집"))
    #expect(IdeBanner.text(.deleted(path: "/w/a", dirty: true)).contains("저장하지 않은 편집"))
}

@Test func quittingAsksOnlyWithEditsThatAreNotSaved() {
    #expect(unsavedQuitMessage([], home: "/Users/example") == nil)
    let one = unsavedQuitMessage(["/Users/example/w/a.swift"], home: "/Users/example")
    #expect(one?.contains("~/w/a.swift") == true)
    let many = unsavedQuitMessage((1...11).map { "/w/f\($0).swift" }, home: "/Users/example")
    #expect(many?.contains("/w/f8.swift") == true && many?.contains("/w/f9.swift") == false && many?.contains("외 3개") == true)
}

/// R24 S1: an editor with edits that are not saved waits for the next area of its worktree; one without is not kept.
@MainActor @Test func anEditorWithUnsavedEditsWaitsForItsWorktreeAndOneWithoutDoesNot() {
    let root = "/no/such/worktree-\(UUID().uuidString)"
    let clean = IdeParking.session(for: root)
    #expect(!IdeParking.park(clean))
    #expect(IdeParking.session(for: root) !== clean, "a new editor")

    let state = IdeState()
    state.show(root: root)
    let first = state.session
    #expect(first != nil && first?.root == root)
    state.areaGone()
    #expect(state.session === first, "nothing to lose: the area keeps its editor")
    state.show(root: root + "-other")
    #expect(state.session !== first && state.session?.root == root + "-other")
}
