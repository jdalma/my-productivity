import AppKit
import SwiftUI
import Testing
import TowerCore
@testable import TowerApp

// T172 (R26 L1): `↓ n개 더` on the panel as drawn, not only its rule. The rule's own tests are in TaskBoardViewTests.

private func doingBoard() throws -> TaskBoardStatus {
    let tasks = (1...4).map {
        #"{"id":"T\#($0)","parent_id":null,"title":"t","ticket_path":"/tmp/example/t.md","state":"doing","assignee":"dev","reviewer":"rv","priority":100,"constraints":"none"}"#
    }.joined(separator: ",")
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return try d.decode(TaskBoardStatus.self, from: Data(#"{"tasks":[\#(tasks)],"workers":[],"open_findings":[],"recent":[],"announcements":[]}"#.utf8))
}

/// The task board's list with 진행 중 at `height`, a line picked or none, in a window never shown.
@MainActor private final class Shown {
    let window: NSWindow
    init(height: Double?, selected: String?) throws {
        let prefs = height.map { TaskPanelPrefs().setting(height: $0, for: .doing) } ?? TaskPanelPrefs()
        let list = TaskPanelList(team: "example", status: try doingBoard(), query: "", now: Date(), selected: selected, pick: { _ in },
                                 prefs: .constant(prefs), doneOpen: .constant(false), pastOpen: .constant(false),
                                 headTarget: .constant(nil), arrange: { _, _ in }, todoTotals: [:], workerRow: { _ in nil },
                                 select: { _ in }, columnRoom: .constant(1))
        window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 600, height: 900), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: list.frame(width: 600, height: 900))
    }

    func close() { window.contentView = nil }

    /// Whether `↓ n개 더` is drawn: ink in the band's strip, right under the panel's scroll. With no count the strip is
    /// the box's plain background.
    func bandShown() throws -> Bool {
        let v = window.contentView!
        let scroll = try #require(innerScrolls().first)
        let r = scroll.convert(scroll.bounds, to: v)
        let band = moreBelowBand(scale: 1)
        let strip = CGRect(x: r.minX, y: v.isFlipped ? r.maxY : r.minY - band, width: r.width, height: band)
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        let k = CGFloat(rep.pixelsWide) / v.bounds.width
        let top = v.isFlipped ? strip.minY : v.bounds.height - strip.maxY
        var lo: CGFloat = 1, hi: CGFloat = 0
        for y in Int((top + 2) * k)..<Int((top + band - 2) * k) {
            for x in stride(from: Int(strip.minX * k), to: Int(strip.maxX * k), by: 1) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let l = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                lo = min(lo, l); hi = max(hi, l)
            }
        }
        return hi - lo > 0.15
    }

    /// The scroll views inside the list's own, smallest first: a sized panel's lines.
    func innerScrolls() -> [NSScrollView] {
        func all(_ v: NSView) -> [NSScrollView] { ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap(all) }
        return all(window.contentView!).sorted { $0.frame.height < $1.frame.height }
    }

    /// Lays out and lets the measures (onGeometryChange, the scroll probe's async report) land.
    func settle() async throws {
        for _ in 0..<10 {
            window.contentView!.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
    }
}

/// 6fdd656 (T168): a line is whole when its words show, its pick's padding (4 pt under it) aside. Here the panel is 2 pt
/// short of the last line's padding: every word shows and nothing is below. Measured with the padding, the last line
/// was counted as cut.
@MainActor @Test func aLineWhoseWordsShowIsNotCountedForItsPickPadding() async throws {
    let band = moreBelowBand(scale: 1)
    let measure = try Shown(height: 400, selected: nil)
    try await measure.settle()
    let lines = try #require(measure.innerScrolls().first?.documentView?.frame.height)
    measure.close()
    // under the lines: the stack's own 6 pt, then the last line's 4 pt of pick padding, then its words' bottom
    let words = lines - 6 - 4
    let whole = try Shown(height: words + 2 + band, selected: nil)
    try await whole.settle()
    #expect(try !whole.bandShown(), "the last line's words all show, \(lines) pt of lines")
    whole.close()
    let cut = try Shown(height: words - 2 + band, selected: nil)
    try await cut.settle()
    #expect(try cut.bandShown(), "2 pt of the last line's words cut")
    cut.close()
}

/// 07d4eab (T168, R22 L1): the band has a strip of its own under the lines, so the lines scroll in the panel's height
/// less the band. Picking the last line of a short panel scrolls it whole into that part, and nothing is below. With
/// the band over the lines, the scroll put the line under it and `↓ 1개 더` stayed.
@MainActor @Test func pickingTheLastLineOfAShortPanelLeavesNothingBelow() async throws {
    let band = moreBelowBand(scale: 1)
    let none = try Shown(height: 60, selected: nil)
    try await none.settle()
    #expect(try none.bandShown(), "60 pt, at the top: lines below")
    none.close()
    let last = try Shown(height: 60, selected: "T4")
    try await last.settle()
    #expect(try #require(last.innerScrolls().first).frame.height == 60 - band)
    #expect(try !last.bandShown(), "the last line picked: whole, nothing below")
    last.close()
}
