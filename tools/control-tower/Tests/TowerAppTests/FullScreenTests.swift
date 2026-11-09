import AppKit
import Testing
@testable import TowerApp

/// Windows here are never shown: only their collection behavior is read.
@MainActor private func window(_ behavior: NSWindow.CollectionBehavior = []) -> NSWindow {
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
    w.collectionBehavior = behavior
    return w
}

private let fullScreenBits: NSWindow.CollectionBehavior = [.fullScreenPrimary, .fullScreenAuxiliary, .fullScreenNone]

@MainActor @Test func theBoardWindowCanTakeItsOwnFullScreenSpace() {
    let w = window()
    #expect(!w.collectionBehavior.contains(.fullScreenPrimary))
    w.contentView = FullScreenCapable().makeProbe()
    #expect(w.collectionBehavior.contains(.fullScreenPrimary))
    #expect(FullScreenCapable.board === w)  // ⌃⌘F turns this window, whichever window is key
    #expect(!w.isVisible)
}

@MainActor @Test func anOpposingFullScreenBitGivesWayToPrimary() {
    for start: NSWindow.CollectionBehavior in [.fullScreenNone, .fullScreenAuxiliary] {
        let w = window([start, .managed])
        w.contentView = FullScreenCapable().makeProbe()
        #expect(w.collectionBehavior.intersection(fullScreenBits) == .fullScreenPrimary)
        #expect(w.collectionBehavior.contains(.managed))  // other bits stay
    }
}

/// T38b log: SwiftUI writes 131584 back when the board becomes key, after the probe moved in.
@MainActor @Test func aLaterRewriteOfTheBehaviorIsUndone() {
    let w = window()
    w.contentView = FullScreenCapable().makeProbe()
    w.collectionBehavior = [.auxiliary, .fullScreenNone]
    #expect(w.collectionBehavior == [.primary, .fullScreenPrimary])
    w.contentView = NSView()  // once the probe leaves, the window is left alone
    w.collectionBehavior = [.fullScreenNone]
    #expect(w.collectionBehavior == [.fullScreenNone])
}

/// What SwiftUI gives the board in the accessory app (T38b log: 131584 = .auxiliary + .fullScreenNone).
@MainActor @Test func theAuxiliaryMarkSwiftUIGivesTheBoardBecomesPrimary() {
    let roles: NSWindow.CollectionBehavior = [.primary, .auxiliary, .canJoinAllApplications]
    let w = window([.auxiliary, .fullScreenNone])
    w.contentView = FullScreenCapable().makeProbe()
    #expect(w.collectionBehavior.intersection(roles) == .primary)
    #expect(w.collectionBehavior.intersection(fullScreenBits) == .fullScreenPrimary)
}

/// The divider's cursor area sits under the drag strip: clicks must reach SwiftUI's gesture.
@MainActor @Test func theResizeCursorAreaLetsClicksThrough() {
    let area = ResizeUpDownCursor.Area(frame: .init(x: 0, y: 0, width: 100, height: 7))
    #expect(area.hitTest(NSPoint(x: 50, y: 3)) == nil)
}

/// A window that is never shown but says whether it is, and counts the full screen toggles asked of it.
@MainActor private final class FakeBoardWindow: NSWindow {
    var shown = false
    var toggles = 0
    override var isVisible: Bool { shown }
    override func toggleFullScreen(_ sender: Any?) { toggles += 1 }
}

@MainActor private func fakeBoard() -> FakeBoardWindow {
    FakeBoardWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .resizable],
                    backing: .buffered, defer: true)
}

/// Closing the board ends its full screen space, and a reopened window lands on the space in view, over a full
/// screen Ghostty (user report, 2026-11-08). The board goes back to full screen when it was closed in it.
@MainActor @Test func aBoardClosedInFullScreenReopensInFullScreen() async throws {
    let suite = "ct-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    FullScreenCapable.defaults = defaults
    FullScreenCapable.settle = .milliseconds(50)
    let post = { (name: Notification.Name, w: NSWindow) in NotificationCenter.default.post(name: name, object: w) }

    let first = fakeBoard()
    first.contentView = FullScreenCapable().makeProbe()
    post(NSWindow.willEnterFullScreenNotification, first)
    // closing leaves full screen with the window already gone: the wish stays
    post(NSWindow.didExitFullScreenNotification, first)
    try await Task.sleep(for: .milliseconds(150))
    first.contentView = NSView()

    let reopened = fakeBoard()
    reopened.contentView = FullScreenCapable().makeProbe()
    post(NSWindow.didBecomeMainNotification, reopened)
    post(NSWindow.didBecomeMainNotification, reopened)
    #expect(reopened.toggles == 1)  // once, when it first comes forward

    // the user leaves full screen and keeps the window: next time it opens as a window
    reopened.shown = true
    post(NSWindow.didExitFullScreenNotification, reopened)
    let deadline = Date().addingTimeInterval(2)  // the check runs `settle` later, later still under a loaded run
    while defaults.bool(forKey: FullScreenCapable.fullScreenKey), Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    reopened.contentView = NSView()
    let windowed = fakeBoard()
    windowed.contentView = FullScreenCapable().makeProbe()
    post(NSWindow.didBecomeMainNotification, windowed)
    #expect(windowed.toggles == 0)
}
