import AppKit
import SwiftUI
import Testing
@testable import TowerCore
@testable import TowerApp

@MainActor @Observable private final class Rows { var ratio = 0.5; var shown = true }

private struct RowsView: View {
    @Bindable var rows: Rows
    static let lines = [DiffLine(kind: .removed, old: 1, new: nil, text: "a"), DiffLine(kind: .added, old: nil, new: 1, text: "b")]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if rows.shown { SplitRowView(row: .pair(old: 0, new: 1), lines: Self.lines, ratio: $rows.ratio) }
            }
        }
        .frame(width: 600, height: 100)
    }
}

@MainActor private final class Hovered {
    let rows = Rows()
    let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 600, height: 100), styleMask: .borderless,
                          backing: .buffered, defer: false)
    private let host: NSHostingView<RowsView>
    private var events = 0
    static let handle = CGPoint(x: 300.5, y: 92)
    static let away = CGPoint(x: 100, y: 40)
    private static let marker = NSCursor.crosshair

    /// What is on top of the cursor stack: `marker` while the handle's takes and returns are in step.
    enum Top { case marker, resize, other }

    init() {
        host = NSHostingView(rootView: RowsView(rows: rows))
        window.contentView = host
        window.orderBack(nil)  // a drag reaches the row only in a window that is ordered in
        settle()
        Self.marker.push()
    }

    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

    var cursor: Top {
        switch NSCursor.current {
        case Self.marker: .marker
        case .resizeLeftRight: .resize
        default: .other
        }
    }

    func mouse(_ type: NSEvent.EventType, _ p: CGPoint) {
        events += 1
        let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: events, clickCount: 1,
                                   pressure: type == .leftMouseUp ? 0 : 1)!
        if type == .mouseMoved { host.mouseMoved(with: e) } else { window.sendEvent(e) }
        settle()
    }

    func enter(_ p: CGPoint) {
        // SwiftUI takes a pointer as inside only after an enter event that names the hosting view's own tracking area
        guard let area = host.trackingAreas.first else {
            Issue.record("the hosting view has no tracking area")
            return
        }
        let e = NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                       trackingNumber: unsafeBitCast(area, to: Int.self), userData: nil)!
        host.mouseEntered(with: e)
        mouse(.mouseMoved, p)
    }

    /// AppKit posts the occlusion change only for a window on a screen.
    func hide() {
        window.orderOut(nil)
        deselect()
    }

    /// As a tab that is no longer the selected one: still ordered in, no longer on screen.
    func deselect() {
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        settle()
    }

    func close() {
        window.contentView = nil
        settle()
        for _ in 0..<4 where NSCursor.current != Self.marker { NSCursor.pop() }
        NSCursor.pop()
    }
}

@Test func aHandleWithNoCursorGivesNothingBack() {
    var c = HeldCursor()
    #expect(c.hover(false) == nil && c.drag(false) == nil && c.gone() == nil)
}

@Test func aHandleTakesItsCursorOnceWhileHoveredOrDragged() {
    var c = HeldCursor()
    #expect(c.hover(true) == .take)
    #expect(c.hover(true) == nil && c.drag(true) == nil && c.drag(true) == nil)
    var dragged = HeldCursor()
    #expect(dragged.drag(true) == .take)
    #expect(dragged.hover(true) == nil)
}

@Test func aDragOffTheHandleKeepsTheCursorUntilItEnds() {
    var c = HeldCursor()
    _ = c.hover(true)
    _ = c.drag(true)
    #expect(c.hover(false) == nil)
    #expect(c.drag(false) == .giveBack)
}

@Test func aDragReleasedOnTheHandleKeepsTheCursor() {
    var c = HeldCursor()
    _ = c.hover(true)
    _ = c.drag(true)
    #expect(c.drag(false) == nil)
    #expect(c.hover(false) == .giveBack)
}

@Test func aHandleGoneGivesItsCursorBackOnce() {
    var c = HeldCursor()
    _ = c.hover(true)
    _ = c.drag(true)
    #expect(c.gone() == .giveBack)
    #expect(c.gone() == nil && c.hover(false) == nil && c.drag(false) == nil)
    #expect(c.hover(true) == .take)
}

/// The cursor stack is one per process.
@MainActor @Suite(.serialized) struct SplitHandleCursorTests {
    @Test func theResizeCursorIsOnTheHandleOnly() {
        let w = Hovered()
        defer { w.close() }
        #expect(w.cursor == .marker)
        w.enter(Hovered.handle)
        #expect(w.cursor == .resize)
        w.mouse(.mouseMoved, Hovered.away)
        #expect(w.cursor == .marker)
    }

    @Test func aRowGoneUnderThePointerTakesItsCursorWithIt() {
        let w = Hovered()
        defer { w.close() }
        w.enter(Hovered.handle)
        w.rows.shown = false
        w.settle()
        #expect(w.cursor == .marker)
        w.rows.shown = true
        w.settle()
        w.mouse(.mouseMoved, Hovered.handle)
        #expect(w.cursor == .resize)
        w.mouse(.mouseMoved, Hovered.away)
        #expect(w.cursor == .marker)
    }

    @Test func aDragKeepsTheCursorOffTheHandleAndGivesItBackAfter() {
        let w = Hovered()
        defer { w.close() }
        w.enter(Hovered.handle)
        w.mouse(.leftMouseDown, Hovered.handle)
        w.mouse(.leftMouseDragged, CGPoint(x: 200, y: 92))
        #expect(abs(w.rows.ratio - 0.333) < 0.01)
        w.mouse(.leftMouseDragged, CGPoint(x: 20, y: 40))
        #expect(w.rows.ratio == SplitRatio.bounds.lowerBound)
        #expect(w.cursor == .resize)
        w.mouse(.leftMouseUp, CGPoint(x: 20, y: 40))
        w.mouse(.mouseMoved, Hovered.away)
        #expect(w.cursor == .marker)
    }

    @Test func aWindowHiddenUnderThePointerLeavesNoCursorForTheNextWindow() {
        let hidden = Hovered(), next = Hovered()
        defer { next.close(); hidden.close() }
        hidden.enter(Hovered.handle)
        hidden.hide()
        #expect(hidden.cursor == .marker)
        next.enter(Hovered.handle)
        #expect(next.cursor == .resize)
        next.mouse(.mouseMoved, Hovered.away)
        #expect(next.cursor == .marker)
        hidden.window.orderBack(nil)
        hidden.mouse(.mouseMoved, Hovered.away)
        #expect(hidden.cursor == .marker)
    }

    @Test func aTabNoLongerSelectedLeavesNoCursor() {
        let w = Hovered()
        defer { w.close() }
        w.enter(Hovered.handle)
        w.deselect()
        #expect(w.window.isVisible)
        #expect(w.cursor == .marker)
    }

    @Test func anotherWindowHiddenLeavesAHoveredHandleItsCursor() {
        let w = Hovered(), other = Hovered()
        defer { other.close(); w.close() }
        w.enter(Hovered.handle)
        other.hide()
        #expect(w.cursor == .resize)
        w.mouse(.mouseMoved, Hovered.away)
        #expect(w.cursor == .marker)
    }

    @Test func anotherWindowHiddenLeavesADraggedHandleItsCursor() {
        let w = Hovered(), other = Hovered()
        defer { other.close(); w.close() }
        w.enter(Hovered.handle)
        w.mouse(.leftMouseDown, Hovered.handle)
        w.mouse(.leftMouseDragged, CGPoint(x: 200, y: 92))
        other.hide()
        #expect(w.cursor == .resize)
        w.mouse(.leftMouseUp, CGPoint(x: 200, y: 92))
        w.mouse(.mouseMoved, Hovered.away)
        #expect(w.cursor == .marker)
    }

    @Test func aDragThePointerNeverHoveredForTakesTheCursorUntilItEnds() {
        let w = Hovered()
        defer { w.close() }
        w.mouse(.leftMouseDown, Hovered.handle)
        w.mouse(.leftMouseDragged, CGPoint(x: 200, y: 92))
        #expect(w.cursor == .resize)
        w.mouse(.leftMouseUp, CGPoint(x: 200, y: 40))
        #expect(w.cursor == .marker)
    }

    @Test func aRowGoneInADragTakesItsCursorWithIt() {
        let w = Hovered()
        defer { w.close() }
        w.mouse(.leftMouseDown, Hovered.handle)
        w.mouse(.leftMouseDragged, CGPoint(x: 200, y: 92))
        w.rows.shown = false
        w.settle()
        #expect(w.cursor == .marker)
    }
}
