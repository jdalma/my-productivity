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

@Test func aRefusedSaveSaysWhyInWords() {
    #expect(saveRefusalText("readOnly") == "잠겨 있음 (잠금 해제 뒤 저장)")
    #expect(saveRefusalText("missing") == "디스크에 파일이 없음")
    #expect(saveRefusalText(EditorRefusal.notOpen.rawValue) == "열린 파일이 아님")
    #expect(saveRefusalText("something new") == "something new")
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

// MARK: - The tree's file menu (G4 I9)

@Test func aNewFileGoesInTheLinesFolderOrTheWorktreeRoot() {
    let folder = TreeLine(ChangeTreeNode(name: "src", path: "app/src", kind: .directory([])), part: nil)
    let file = TreeLine(ChangeTreeNode(name: "a.swift", path: "app/src/a.swift", kind: .file(.unchanged)), part: nil)
    let top = TreeLine(ChangeTreeNode(name: "README.md", path: "README.md", kind: .file(.unchanged)), part: nil)
    #expect(newPath("x.swift", from: folder, toplevel: "/repo", root: "/repo/app") == "/repo/app/src/x.swift")
    #expect(newPath("x.swift", from: file, toplevel: "/repo", root: "/repo/app") == "/repo/app/src/x.swift", "beside the file")
    #expect(newPath("x.swift", from: top, toplevel: "/repo", root: "/repo") == "/repo/x.swift")
    #expect(newPath("a/b/x.swift", from: nil, toplevel: "/repo", root: "/repo/app") == "/repo/app/a/b/x.swift", "no line: the worktree")
}

@Test func everyRefusalOfAFileOperationHasItsWords() {
    let all: [FileOpRefusal] = [.locked, .missing, .outside, .exists, .badName, .notAbsolute]
    #expect(Set(all.map(fileOpRefusalText)).count == all.count)
    #expect(fileOpRefusalText(.locked) == "파일 작업이 잠겨 있음")
}

/// The task board window's area reads only: no file operation runs from it.
@MainActor @Test func theReadOnlyWindowsAreaRunsNoFileOperation() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "ct-ide-readonly-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let state = IdeState(lockable: false)
    state.show(root: dir)
    await state.session?.toggleFileOps()
    await state.fileOp(.newFile(dir + "/x.txt"))
    #expect(!FileManager.default.fileExists(atPath: dir + "/x.txt"))
}
