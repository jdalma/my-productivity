import AppKit
import SwiftUI
import Testing
import TowerCore
@testable import TowerApp

/// T184: a click on the team line's task board button opens the board and leaves the fold alone; a click anywhere
/// else on the line folds or unfolds and opens nothing. The clicks are made here and handed to a window far off
/// every screen: nothing global.
@MainActor @Test func aClickOnTheTeamLineEitherOpensTheBoardOrFoldsNeverBoth() throws {
    final class Seen { var opened = 0, toggled = 0 }
    let seen = Seen()
    let team = TeamGroup(name: "example-team", myTurn: 0, rows: [], hasTaskBoard: true, taskCounts: nil)
    let width: CGFloat = 500, height: CGFloat = 30
    let header = TeamHeader(team: team, expanded: false, board: TaskBoardButtonState(counts: nil, problem: nil),
                            openBoard: { seen.opened += 1 }, toggle: { seen.toggled += 1 })
        .frame(width: width, height: height)
    let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: width, height: height), styleMask: .borderless,
                          backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: header)
    window.orderBack(nil)  // a click reaches the line only in a window that is ordered in
    defer { window.contentView = nil; window.orderOut(nil) }
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    settle()

    var events = 0
    func click(x: CGFloat) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            events += 1
            window.sendEvent(try! #require(NSEvent.mouseEvent(
                with: type, location: CGPoint(x: x, y: height / 2), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: events, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
        settle()
    }

    var opens = 0, folds = 0
    for x in stride(from: CGFloat(4), to: width, by: 8) {
        let before = (seen.opened, seen.toggled)
        click(x: x)
        let opened = seen.opened - before.0, toggled = seen.toggled - before.1
        #expect(opened + toggled == 1, "a click at x \(x) opened \(opened) and folded \(toggled)")
        opens += opened
        folds += toggled
    }
    #expect(opens > 0, "no click reached the task board button")
    #expect(folds > opens, "the line outside the button folds")
}

/// R11 L1: VoiceOver's `작업판 열기` opens the board and leaves the fold, `펴기` unfolds and opens nothing, and the line
/// has no button for a press on the header to take along with the fold (2e43dd1).
@MainActor @Test func voiceOversTaskBoardActionOpensTheBoardAndLeavesTheFold() throws {
    final class Seen { var opened = 0, toggled = 0 }
    let seen = Seen()
    let team = TeamGroup(name: "example-team", myTurn: 0, rows: [], hasTaskBoard: true, taskCounts: nil)
    let header = TeamHeader(team: team, expanded: false, board: TaskBoardButtonState(counts: nil, problem: nil),
                            openBoard: { seen.opened += 1 }, toggle: { seen.toggled += 1 })
        .frame(width: 500, height: 30)
    let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 500, height: 30), styleMask: .borderless,
                          backing: .buffered, defer: false)
    let host = NSHostingView(rootView: header)
    window.contentView = host
    window.orderBack(nil)
    // SwiftUI builds its accessibility tree only after an assistive app has asked the app for it, and a test
    // process has none: without this attribute, which VoiceOver sets on an app, the tree is the hosting view alone
    let assistive = NSSelectorFromString("accessibilitySetValue:forAttribute:")
    func assist(_ on: Bool) { _ = NSApplication.shared.perform(assistive, with: on, with: "AXEnhancedUserInterface") }
    assist(true)
    defer { assist(false); window.contentView = nil; window.orderOut(nil) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    func get(_ o: NSObject, _ name: String) -> Any? {
        let s = NSSelectorFromString(name)
        return o.responds(to: s) ? o.perform(s)?.takeUnretainedValue() : nil
    }
    func nodes(_ o: NSObject) -> [NSObject] {
        [o] + ((get(o, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(nodes)
    }
    let all = nodes(host)
    let actions = all.flatMap { (get($0, "accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? [] }
    #expect(actions.map(\.name).sorted() == ["작업판 열기", "펴기"])
    #expect(!all.contains { get($0, "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue })

    _ = actions.first { $0.name == "작업판 열기" }?.handler?()
    #expect(seen.opened == 1 && seen.toggled == 0)
    _ = actions.first { $0.name == "펴기" }?.handler?()
    #expect(seen.opened == 1 && seen.toggled == 1)
}

@MainActor @Test func aWorkerRowDrawsItsLineCountsOnlyWithRoomAndAlwaysReadsThem() throws {
    let session = Session(handle: "pane:t:%1", agent: .claude, pid: 1, cwd: "/w", startedAt: nil, status: .wait, myTurn: false, since: nil,
                          permissionPrompt: false, title: "", tmux: nil, transcript: nil, lastUser: "", lastAssistant: "", termProgram: nil)
    let row = LiveRow(id: .live("w"), session: session, worker: nil, teamName: "t", title: "core", folder: "core", path: "~/w",
                      badge: .idle(minutes: 12), matched: nil)
    let assistive = NSSelectorFromString("accessibilitySetValue:forAttribute:")
    func assist(_ on: Bool) { _ = NSApplication.shared.perform(assistive, with: on, with: "AXEnhancedUserInterface") }
    assist(true)
    defer { assist(false) }

    func shown(_ change: RowChange?, width: CGFloat) throws -> (pixels: Data, names: [String]) {
        let host = NSHostingView(rootView: LiveRowView(row: row, change: change).frame(width: width, height: 24))
        let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: width, height: 24), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.contentView = nil; window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func get(_ o: NSObject, _ name: String) -> Any? {
            let s = NSSelectorFromString(name)
            return o.responds(to: s) ? o.perform(s)?.takeUnretainedValue() : nil
        }
        func nodes(_ o: NSObject) -> [NSObject] { [o] + ((get(o, "accessibilityChildren") as? [NSObject]) ?? []).flatMap(nodes) }
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return (try #require(rep.tiffRepresentation), nodes(host).compactMap { get($0, "accessibilityLabel") as? String })
    }

    let change = RowChange(total: DiffTotal(added: 340, removed: 85))
    for (width, drawn) in [(CGFloat(300), true), (90, false)] {
        let with = try shown(change, width: width), without = try shown(nil, width: width)
        #expect((with.pixels != without.pixels) == drawn, "at \(width)pt")
        #expect(with.names.contains("더한 줄 340, 뺀 줄 85"), "at \(width)pt")
        #expect(!without.names.contains { $0.contains("더한 줄") })
    }
}
