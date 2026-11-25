import Foundation
import Testing
@testable import TowerApp
@testable import TowerCore

// The board's editor and its language servers (G4 I11 with I5, plan K12: a root no longer shown has no server):
// another worktree, the window closing and the page's process ending each stop the editor's servers. `cat` stands in
// for a server; the page folder is empty (no page loads), which the servers do not need.

@MainActor private func folders() throws -> (page: String, a: String, b: String) {
    let base = FileManager.default.temporaryDirectory.appending(path: "ct-ide-lsp-\(UUID().uuidString)").path
    for dir in ["page", "a", "b"] { try FileManager.default.createDirectory(atPath: base + "/" + dir, withIntermediateDirectories: true) }
    return (base + "/page", base + "/a", base + "/b")
}

@MainActor private func runServer(_ host: LanguageServerHost, for editor: EditorController, root: String) -> LanguageServerKey {
    let key = LanguageServerKey(editor: editor.editorID, server: "echo", root: root)
    _ = host.start(key, executable: "/bin/cat", arguments: [], onMessage: { _ in }, onExit: {})
    return key
}

@MainActor @Test func anotherWorktreeStopsTheOldEditorsServers() throws {
    let f = try folders()
    let host = LanguageServerHost()
    let state = IdeState { root in EditorController(roots: [root], page: URL(fileURLWithPath: f.page), servers: host) }
    defer { host.stopAll() }

    state.show(root: f.a)
    let first = try #require(state.editor)
    let old = runServer(host, for: first, root: f.a)
    #expect(host.isRunning(old))

    state.show(root: f.a)
    #expect(state.editor === first, "the same root keeps its editor")
    #expect(host.isRunning(old))

    state.show(root: f.b)
    #expect(state.editor !== first)
    #expect(!host.isRunning(old), "the old worktree's server stops")
}

@MainActor @Test func closingTheWindowStopsItsEditorsServers() throws {
    let f = try folders()
    let host = LanguageServerHost()
    let state = IdeState { root in EditorController(roots: [root], page: URL(fileURLWithPath: f.page), servers: host) }
    defer { host.stopAll() }

    state.show(root: f.a)
    let key = runServer(host, for: try #require(state.editor), root: f.a)
    state.close()
    #expect(!host.isRunning(key))
    #expect(state.editor == nil)

    state.show(root: f.a)
    #expect(state.editor != nil, "opened again, the window gets a new editor")
}

@MainActor @Test func thePagesProcessEndingStopsTheEditorsServers() throws {
    let f = try folders()
    let host = LanguageServerHost()
    let editor = EditorController(roots: [f.a], page: URL(fileURLWithPath: f.page), servers: host)
    defer { host.stopAll() }
    let key = runServer(host, for: editor, root: f.a)
    editor.webViewWebContentProcessDidTerminate(editor.web)
    #expect(!host.isRunning(key), "the new page starts its servers again when it opens a file")
}

/// T41: an editor kept for its edits that are not saved (IdeParking) runs no server while no window shows it; the page
/// hears its clients closed (lspClosed). Shown again, the same servers start again and the page connects anew.
@MainActor @Test func aParkedEditorsServersStopAndStartAgainWhenItIsShown() async throws {
    let f = try folders()
    let host = LanguageServerHost()
    let state = IdeState { root in EditorController(roots: [root], page: URL(fileURLWithPath: f.page), servers: host) }
    defer { host.stopAll() }
    try "x\n".write(toFile: f.a + "/a.swift", atomically: true, encoding: .utf8)

    state.show(root: f.a)
    let editor = try #require(state.editor)
    let key = runServer(host, for: editor, root: f.a)
    // an edit not saved: the editor waits in IdeParking when another worktree shows (files go by their real path)
    let file = try #require(realPath(f.a + "/a.swift"))
    await state.session?.open(file)
    editor.onDirty?(file, true)
    #expect(state.buffers.unsaved == [file])

    state.show(root: f.b)
    #expect(!host.isRunning(key), "a parked editor's server stops")
    try await until { editor.waiting.contains(.lspClosed(channel: key.channel)) }

    state.show(root: f.a)
    #expect(state.editor === editor, "the waiting editor, edits and all")
    #expect(host.isRunning(key), "its server runs again")
    try await until { editor.waiting.contains(.reconnectLanguageServers) }
}

@MainActor private func until(_ done: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !done(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(done())
}

/// R40 M1: a server started again under the key of one just stopped (parked, then shown at once) is not taken for
/// the old one: the old process's end and output do not touch it, and the app does not stop.
@MainActor @Test func aServerStartedAgainAtOnceOutlivesTheEndOfTheOldOne() async throws {
    let f = try folders()
    let host = LanguageServerHost()
    defer { host.stopAll() }
    let key = LanguageServerKey(editor: 4101, server: "echo", root: f.a)
    var exits = 0
    _ = host.start(key, executable: "/bin/cat", arguments: [], onMessage: { _ in }, onExit: { exits += 1 })
    try await Task.sleep(for: .milliseconds(200))
    #expect(host.suspend(editor: 4101) == [key])
    host.resume(editor: 4101)  // before the old process's end is reported
    try await Task.sleep(for: .seconds(1))
    #expect(host.isRunning(key), "the new server still runs")
    #expect(exits == 0, "a stop is no end by itself")
    #expect(host.send(key, #"{"jsonrpc":"2.0","method":"x"}"#))
}
