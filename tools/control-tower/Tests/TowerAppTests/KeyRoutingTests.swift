import AppKit
import Testing
import WebKit
@testable import TowerApp

// Who takes a shortcut both the app and the editor (or a pane terminal) know (G4 I8, T14 §5): the app's menu acts
// only when the key is the app's for the focus it comes from.

@Test func theEditorKeepsItsOwnKeysAndLeavesTheWindowsToTheApp() {
    for key in [SharedKey.find, .searchK, .escape, .back, .forward, .openDiff, .undo, .quickOpen, .commandPalette] {
        #expect(keyConsumer(key, focus: .editor) == .editor, "\(key)")
    }
    for key in [SharedKey.close, .fontBigger, .fontSmaller, .fontReset] {
        #expect(keyConsumer(key, focus: .editor) == .app, "\(key)")
    }
}

@Test func aPaneTerminalKeepsFindAndLeavesItWithK() {
    #expect(keyConsumer(.find, focus: .terminal) == .terminal)
    #expect(keyConsumer(.searchK, focus: .terminal) == .app)  // ⌘K is the way out of a pane terminal
    for key in [SharedKey.escape, .back, .forward, .openDiff, .close, .fontBigger] {
        #expect(keyConsumer(key, focus: .terminal) == .app, "\(key)")
    }
}

@Test func elsewhereEveryKeyIsTheApps() {
    for key in SharedKey.allCases { #expect(keyConsumer(key, focus: .other) == .app, "\(key)") }
}

@MainActor @Test func theFocusIsTheEditorForTheWebViewAndAnythingInsideIt() {
    let web = EditorPageView(frame: .zero, configuration: WKWebViewConfiguration())
    let inside = NSView()
    web.addSubview(inside)
    #expect(KeyFocus(responder: web) == .editor)
    #expect(KeyFocus(responder: inside) == .editor)
    #expect(KeyFocus(responder: NSView()) == .other)
    #expect(KeyFocus(responder: nil) == .other)
    #expect(KeyFocus(responder: NSWindow()) == .other)
}
