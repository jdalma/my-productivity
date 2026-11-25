import AppKit
import SwiftUI
import Testing
@testable import TowerApp

// The board's editor slot (T33): a new EditorController (another worktree) must put its own page in the window. A
// representable keeps the view it made first unless its identity changes; the new page then never joins the window,
// has no size, and Monaco fails to start ("Unable to figure out browser width and height").

@MainActor private func editor() throws -> EditorController {
    let page = FileManager.default.temporaryDirectory.appending(path: "ct-slot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: page, withIntermediateDirectories: true)
    return EditorController(roots: [page.path], page: page)
}

@MainActor @Test func anotherEditorPutsItsOwnPageInTheWindow() throws {
    let first = try editor(), second = try editor()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: EditorSlot(editor: first))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    #expect(first.web.window === window)
    #expect(first.web.frame.width > 0 && first.web.frame.height > 0)

    host.rootView = EditorSlot(editor: second)
    host.layoutSubtreeIfNeeded()
    #expect(second.web.window === window, "the new editor's page is in the window")
    #expect(second.web.frame.width > 0 && second.web.frame.height > 0, "with a size, so Monaco can start")
    #expect(first.web.window == nil, "the old page left it")
}

@MainActor @Test func aPageLoadsOnlyOnceItIsInAWindowWithASize() throws {
    // made while not shown (a narrow window, a hidden tab), a page that loaded at size zero stays blank (T31)
    let detached = try editor()
    #expect(detached.web.url == nil, "not loaded while it is in no window")

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: EditorSlot(editor: detached))
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    #expect(detached.web.url?.absoluteString == "ctedit://app/index.html", "loaded once it has a size")
}
