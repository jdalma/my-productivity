import AppKit
import Foundation
import Testing
import TowerCore
@testable import TowerApp

// The board's IDE area marks the files a worker wrote lately (G4 I14 W3, T35): not the app's own saves.

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

/// W3: a file written in the worktree by something other than the app is marked as the worker's.
@MainActor @Test func aFileWrittenFromOutsideIsMarkedAsTheWorkers() async throws {
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

/// R36 L1: the app's own save of an unlocked file is not marked; a worker's write of another file in the same batch
/// window is.
@MainActor @Test func theAppsOwnSaveIsNotMarkedAsTheWorkers() async throws {
    let work = try folder()
    try "x\n".write(toFile: work + "/mine.swift", atomically: true, encoding: .utf8)
    try "x\n".write(toFile: work + "/theirs.swift", atomically: true, encoding: .utf8)
    let state = IdeState(page: try page())
    state.show(root: work)
    let files = try #require(state.editor?.files)
    guard case .file(_, let hash) = await files.handle(.readFile(path: work + "/mine.swift")) else { Issue.record("no read"); return }
    _ = await files.setReadOnly(work + "/mine.swift", false)
    try await Task.sleep(for: .milliseconds(300))  // the watch starts
    guard case .written = await files.handle(.writeFile(path: work + "/mine.swift", text: "saved\n", baseHash: hash)) else {
        Issue.record("not saved"); return
    }
    try "y\n".write(toFile: work + "/theirs.swift", atomically: true, encoding: .utf8)
    try await until { state.session?.writes.last[work + "/theirs.swift"] != nil }
    #expect(state.session?.writes.last[work + "/mine.swift"] == nil)
    state.areaGone()
}
