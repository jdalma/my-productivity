import Foundation
import Testing
import TowerCore
@testable import TowerApp

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

@MainActor
private func until(_ done: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !done(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
}

/// The last markers the page was sent for `path`.
@MainActor private func marked(_ state: IdeState, _ path: String) -> [EditorMarker]? {
    state.editor?.waiting.reversed().lazy.compactMap { c -> [EditorMarker]? in
        if case .setMarkers(path, let m) = c { m } else { nil }
    }.first
}

@MainActor @Test func aLinkWaitsForTheWorkersWorktreeThenOpensReadOnlyAtItsLineWithItsMarkers() async throws {
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
    #expect(state.editor?.waiting.contains { if case .openFile(file, _, _, 2, true) = $0 { true } else { false } } == true)
    #expect(marked(state, file) == [EditorMarker(line: 2, severity: .error, message: "R1 M1 `area.swift:2` rounds")])

    // never unlocked: it is no buffer of the editor's
    await state.session?.toggleLock()
    #expect(state.readOnly)
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
