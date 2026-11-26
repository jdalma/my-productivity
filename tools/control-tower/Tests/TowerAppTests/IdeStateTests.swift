import Foundation
import Testing
import TowerCore
import TowerTestSupport
@testable import TowerApp

// The board's IDE area marks the files a worker wrote lately (G4 I14 W3, T35): not the app's own saves.
// A task board link in the board window's editor (G4 I12, D#17): opened read-only at its line once the window shows
// the worker's worktree, never unlocked, with the task's open findings marked.

private func folder() throws -> String {
    let url = FileManager.default.temporaryDirectory.appending(path: "ide-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // /var is a link to /private/var: the editor names files by their real path
    return String(cString: realpath(url.path, nil))
}

/// A stand-in for the built editor page: the page never says ready, so commands wait, as they do while Monaco loads.
private func page() throws -> URL {
    let dir = try folder()
    try "<html></html>".write(toFile: dir + "/index.html", atomically: true, encoding: .utf8)
    return URL(fileURLWithPath: dir)
}

/// The tests that wait on work off the main actor run in `withGCDWorkersFree` (T48): a test that blocks every GCD
/// worker (FocusRunnerTests, CommandTests) would hold that work for its 20 s.
@MainActor
private func until(_ done: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !done(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
}

/// W3: a file written in the worktree by something other than the app is marked as the worker's.
@MainActor @Test func aFileWrittenFromOutsideIsMarkedAsTheWorkers() async throws {
    try await withGCDWorkersFree {
        let work = try folder()
        try "x\n".write(toFile: work + "/a.swift", atomically: true, encoding: .utf8)
        let state = IdeState(page: try page())
        state.show(root: work)
        state.worker = "analyst"
        try await Task.sleep(for: .milliseconds(300))  // the watch starts
        try "y\n".write(toFile: work + "/a.swift", atomically: true, encoding: .utf8)
        try await until { state.session?.writes.last[work + "/a.swift"] != nil }
        #expect(state.session?.writtenWarning(work + "/a.swift")?.hasPrefix("analyst가 ") == true)
        state.areaGone()
    }
}

/// R36 L1: the app's own save of an unlocked file is not marked; a worker's write of another file in the same batch
/// window is.
@MainActor @Test func theAppsOwnSaveIsNotMarkedAsTheWorkers() async throws {
    try await withGCDWorkersFree {
        let work = try folder()
        try "x\n".write(toFile: work + "/mine.swift", atomically: true, encoding: .utf8)
        try "x\n".write(toFile: work + "/theirs.swift", atomically: true, encoding: .utf8)
        let state = IdeState(page: try page())
        state.show(root: work)
        let files = try #require(state.editor?.files)
        guard case .file(_, let hash) = await files.handle(.readFile(path: work + "/mine.swift")) else { Issue.record("no read"); return }
        _ = await files.setReadOnly(work + "/mine.swift", false)
        // The setup's writes above are not the app's, and on a loaded machine their events can come after the watch has
        // started (T45: the cause of the R40a failure, which slept 300 ms for them). Events come in order: once a file
        // written now is seen, theirs have come too. The save must then add nothing for mine.swift.
        try "s\n".write(toFile: work + "/sentinel.txt", atomically: true, encoding: .utf8)
        try await until { state.session?.writes.last[work + "/sentinel.txt"] != nil }
        let before = state.session?.writes.last[work + "/mine.swift"]
        let saved = Date()
        guard case .written = await files.handle(.writeFile(path: work + "/mine.swift", text: "saved\n", baseHash: hash)) else {
            Issue.record("not saved"); return
        }
        // a worker's write after the save: once it is seen, so is the save's event
        try "y\n".write(toFile: work + "/theirs.swift", atomically: true, encoding: .utf8)
        try await until { (state.session?.writes.last[work + "/theirs.swift"]).map { $0 >= saved } == true }
        #expect(state.session?.writes.last[work + "/mine.swift"] == before)
        state.areaGone()
    }
}

/// The last markers the page was sent for `path`.
@MainActor private func marked(_ state: IdeState, _ path: String) -> [EditorMarker]? {
    state.editor?.waiting.reversed().lazy.compactMap { c -> [EditorMarker]? in
        if case .setMarkers(path, let m) = c { m } else { nil }
    }.first
}

@MainActor @Test func aLinkWaitsForTheWorkersWorktreeThenOpensReadOnlyAtItsLineWithItsMarkers() async throws {
    try await withGCDWorkersFree {
        let state = IdeState(page: try page())
        let other = try folder(), work = try folder(), file = work + "/area.swift"
        try "a\nb\nc\n".write(toFile: file, atomically: true, encoding: .utf8)
        state.show(root: other)  // the board window shows another worker

        let finding = FindingPlace(id: "R1 M1", severity: "must", summary: "`area.swift:2` rounds", repo: work)
        await state.take(IdeOpenRequest(root: work, target: .file(path: file, line: 2), findings: [finding]))
        #expect(state.shown == nil && state.session?.root == other)  // not in another worktree's editor

        state.show(root: work)  // the board selects the worker's row
        try await until { marked(state, file) != nil }
        #expect(state.shown == file && state.readOnly)
        #expect(state.editor?.waiting.contains(.showFile(path: file, text: "a\nb\nc\n", line: 2)) == true)
        #expect(marked(state, file) == [EditorMarker(line: 2, severity: .error, message: "R1 M1 `area.swift:2` rounds")])

        // never unlocked: it is no buffer of the editor's
        await state.session?.toggleLock()
        #expect(state.readOnly)
    }
}

@MainActor @Test func aLinkOfTheWorktreeShownOpensAtOnceAndACommitsFileIsReadFromGit() async throws {
    let state = IdeState(page: try page())
    let work = try folder()
    state.show(root: work)
    try "x\n".write(toFile: work + "/a.md", atomically: true, encoding: .utf8)
    await state.take(IdeOpenRequest(root: work, target: .file(path: work + "/a.md", line: 1), findings: []))
    #expect(state.shown == work + "/a.md")

    // a commit that is not there: nothing shown in its place
    await state.take(IdeOpenRequest(root: work, target: .commit(repo: work, commit: "abc1234", path: "a.md", line: 1), findings: []))
    #expect(state.status == "열 수 없음")
}

/// R34a L3: a link's file is a document of its own in the page, not the buffer of the same path. What the buffer
/// goes through (unlocked before, the disk changing it, its lock sent again) never reaches what the link shows.
@MainActor @Test func aLinkToAnUnlockedBuffersFileIsADocumentOfItsOwn() async throws {
    let state = IdeState(page: try page())
    let work = try folder(), file = work + "/a.swift"
    try "a\nb\n".write(toFile: file, atomically: true, encoding: .utf8)
    state.show(root: work)
    await state.session?.open(file)
    await state.session?.toggleLock()
    #expect(!state.readOnly)

    await state.take(IdeOpenRequest(root: work, target: .file(path: file, line: 2), findings: []))
    let sent = state.editor?.waiting ?? []
    // shown as its own document; the buffer's file is not opened again over it
    #expect(sent.last(where: { if case .showFile = $0 { true } else { false } }) == .showFile(path: file, text: "a\nb\n", line: 2))
    #expect(sent.filter { if case .openFile(file, _, _, _, _) = $0 { true } else { false } }.count == 1)
    #expect(state.readOnly && state.shown == file)

    // a link's document is no buffer: the lock does nothing to it
    await state.session?.toggleLock()
    #expect(state.readOnly)
}

/// T39: ⌘P and ⌘⇧F open the search panel of the worktree the area shows; a result opens its file read-only (D#5 b)
/// at its line. A file picked by name closes the panel; text results stay for the next hit.
@MainActor @Test func aSearchResultOpensItsFileReadOnlyAtItsLine() async throws {
    let state = IdeState(page: try page())
    let work = try folder(), file = work + "/src/a.swift"
    try FileManager.default.createDirectory(atPath: work + "/src", withIntermediateDirectories: true)
    try "a\nb\n".write(toFile: file, atomically: true, encoding: .utf8)
    state.search(.files)
    #expect(state.searching == nil)  // no worktree shown: nowhere to search

    state.show(root: work)
    state.search(.text)
    #expect(state.searching == .text)
    await state.openFound("src/a.swift", line: 2)
    #expect(state.shown == file && state.readOnly)
    #expect(state.editor?.waiting.contains { if case .openFile(file, _, _, 2, true) = $0 { true } else { false } } == true)
    #expect(state.searching == .text)

    state.search(.files)
    await state.openFound("src/a.swift", line: nil)
    #expect(state.searching == nil)

    // the editor's ⌘P and ⌘⇧F, which the page sends on instead of keeping them
    state.editor?.onSearch?(.text)
    #expect(state.searching == .text)
    state.areaGone()
    state.search(.files)
    #expect(state.searching == .text)  // the area left the window: no panel to open
}
