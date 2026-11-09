import AppKit
import SwiftUI
import Testing
@testable import TowerCore
@testable import TowerApp

/// A split row takes the taller side's height (a wrapped long line), never an unbounded one.
@MainActor @Test func aSplitRowFitsItsTallerSide() throws {
    let short = DiffLine(kind: .removed, old: 1, new: nil, text: "a(1)")
    let long = DiffLine(kind: .added, old: nil, new: 1, text: String(repeating: "word ", count: 80))
    func height(_ row: SplitRow, _ lines: [DiffLine]) throws -> CGFloat {
        let r = ImageRenderer(content: SplitRowView(row: row, lines: lines, ratio: .constant(0.5)).frame(width: 600))
        return try #require(r.nsImage).size.height
    }
    let one = try height(.pair(old: 0, new: 1), [short, short])
    let tall = try height(.pair(old: 0, new: 1), [short, long])
    let empty = try height(.pair(old: 0, new: nil), [short])
    #expect(one > 5 && one < 40)
    #expect(tall > one * 3 && tall < 1000)
    #expect(abs(empty - one) < 1)
}

@Test func theSplitRatioStaysInItsBoundsAndResetsToTheMiddle() {
    #expect(SplitRatio.clamp(0.35) == 0.35)
    #expect(SplitRatio.clamp(0.05) == 0.2)
    #expect(SplitRatio.clamp(0.95) == 0.8)
    #expect(SplitRatio.clamp(.nan) == 0.5)
    #expect(SplitRatio.clamp(.infinity) == 0.5)
    #expect(SplitRatio.standard == 0.5)
    let w = SplitRatio.widths(total: 601, ratio: 0.5)
    #expect(w.old == 300 && w.new == 300)  // the 1 pt line takes the rest
    #expect(SplitRatio.widths(total: 601, ratio: 0.99).old == 480)
    // a drag puts the line under the pointer
    for r in [0.2, 0.3, 0.5, 0.75] {
        let x = SplitRatio.widths(total: 801, ratio: r).old + 0.5
        #expect(abs(SplitRatio.ratio(atX: x, total: 801) - r) < 0.002)
    }
    #expect(SplitRatio.ratio(atX: -50, total: 801) == 0.2)
    #expect(SplitRatio.ratio(atX: 5000, total: 801) == 0.8)
}

/// Rendered: the center line sits where the ratio puts it, and the row keeps its height.
@MainActor @Test func theCenterLineDrawsAtTheRatio() throws {
    let line = DiffLine(kind: .context, old: 1, new: 1, text: "x")
    func lineX(_ ratio: Double) throws -> (x: [Int], height: CGFloat) {
        let r = ImageRenderer(content: SplitRowView(row: .pair(old: nil, new: nil), lines: [line], ratio: .constant(ratio))
            .frame(width: 601).environment(\.colorScheme, .dark))
        r.scale = 1
        let image = try #require(r.nsImage)
        let rep = NSBitmapImageRep(cgImage: try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        let y = rep.pixelsHigh / 2
        let empty = rep.colorAt(x: 5, y: y)
        let xs = (0..<rep.pixelsWide).filter { rep.colorAt(x: $0, y: y) != empty }
        return (xs, image.size.height)
    }
    let mid = try lineX(0.5), left = try lineX(0.3)
    #expect(mid.x == [300])
    #expect(left.x == [180])
    #expect(mid.height == left.height)
}
