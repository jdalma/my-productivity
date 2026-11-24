import AppKit
import Foundation
import SwiftUI
import Testing
import TowerCore
@testable import TowerApp

// The task board window's code beside a task (G4 I6, T31): a document link is never dropped for want of an editor,
// and a commit's tree, which cannot change, is read once per mode.

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

/// git's stdout, trimmed; the test fails on a non-zero exit.
@discardableResult
private func git(_ dir: String, _ args: String...) throws -> String {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-c", "user.name=t", "-c", "user.email=t@t", "-C", dir] + args
    p.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
    p.standardOutput = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0, "git \(args)")
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

@MainActor
private func until(_ done: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !done(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
}

/// Shows `split` in a window off screen, `width` wide; the caller keeps the window.
@MainActor
private func host(_ view: some View, width: CGFloat) -> NSWindow {
    let w = NSWindow(contentRect: .init(x: -20000, y: -20000, width: width, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    w.contentView = NSHostingView(rootView: view)
    return w
}

/// R27 S1 (1): narrow, the code tab never shown, a document link still opens: it waits for the editor the code
/// tab makes as it comes forward. No editor is made while the code is hidden: a web view loaded out of a window stays
/// blank when it is shown.
@MainActor @Test func aDocumentOpensFromTheDetailTabBeforeTheCodeWasEverShown() async throws {
    let state = IdeState(lockable: false, page: try page())
    let work = try folder(), doc = try folder() + "/T1-report.md"
    try "# report\n".write(toFile: doc, atomically: true, encoding: .utf8)
    let w = host(TaskCodeSplit(state: state, source: .worktree(work), at: "0") { Text("detail") }, width: 600)
    defer { w.contentView = nil }
    try await Task.sleep(for: .milliseconds(300))
    #expect(state.editor == nil && !state.codeShown)

    await state.openDocument(doc, in: .worktree(work))
    try await until { state.shown == doc }
    #expect(state.shown == doc && state.source == .worktree(work))
    #expect(state.codeShown)  // the code tab came forward with it
}

/// R27 S1 (2): in the detail tab, moved to a task of another source, a document link opens in that task's editor,
/// not in the last task's, which the code tab would throw away as it shows.
@MainActor @Test func aDocumentOpensInTheEditorOfTheTaskNowShown() async throws {
    let state = IdeState(lockable: false, page: try page())
    let first = try folder(), second = try folder(), doc = try folder() + "/T2-report.md"
    try "# report\n".write(toFile: doc, atomically: true, encoding: .utf8)
    state.show(.worktree(first))  // the code of the first task was shown before
    let firstEditor = state.editor
    let w = host(TaskCodeSplit(state: state, source: .worktree(second), at: "0") { Text("detail") }, width: 600)
    defer { w.contentView = nil }
    try await Task.sleep(for: .milliseconds(300))
    #expect(state.source == .worktree(first))  // the code tab is hidden: nothing made for the second yet

    await state.openDocument(doc, in: .worktree(second))
    try await until { state.shown == doc }
    #expect(state.shown == doc && state.source == .worktree(second) && state.editor !== firstEditor)
}

/// R27 L1: a commit cannot change, so the 15 s refresh does not read its tree again; another mode is read.
@MainActor @Test func aCommitsTreeIsReadOncePerMode() async throws {
    let repo = try folder()
    try git(repo, "init", "-q", "-b", "main")
    try "a\n".write(toFile: repo + "/a.swift", atomically: true, encoding: .utf8)
    try git(repo, "add", "-A")
    try git(repo, "commit", "-q", "-m", "base")
    let base = try git(repo, "rev-parse", "HEAD")
    try "b\n".write(toFile: repo + "/b.swift", atomically: true, encoding: .utf8)
    try git(repo, "add", "-A")
    try git(repo, "commit", "-q", "-m", "work")
    let head = try git(repo, "rev-parse", "HEAD")

    let state = IdeState(lockable: false, page: nil)
    state.show(.commit(repo: repo, base: base, commit: head))
    await state.loadCommitTree()
    #expect(state.commitTree?.nodes?.map(\.path) == ["b.swift"])

    // a read now would fail: the tree shown is the one read before
    try FileManager.default.removeItem(atPath: repo + "/.git")
    await state.loadCommitTree()
    #expect(state.commitTree?.nodes?.map(\.path) == ["b.swift"])
    state.commitMode = .all
    await state.loadCommitTree()
    #expect(state.commitTree?.mode == .all && state.commitTree?.nodes == nil)  // a new mode is read, and fails
}
