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
