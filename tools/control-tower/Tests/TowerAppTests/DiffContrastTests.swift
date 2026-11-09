import AppKit
import SwiftUI
import Testing
@testable import TowerCore
@testable import TowerApp

private typealias RGBA = (r: Double, g: Double, b: Double, a: Double)

private func resolve(_ c: Color, _ name: NSAppearance.Name) -> RGBA {
    var o: RGBA = (0, 0, 0, 0)
    NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
        let s = NSColor(c).usingColorSpace(.sRGB)!
        o = (s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent)
    }
    return o
}

private func over(_ f: RGBA, _ b: RGBA) -> RGBA {
    (f.r * f.a + b.r * (1 - f.a), f.g * f.a + b.g * (1 - f.a), f.b * f.a + b.b * (1 - f.a), 1)
}

private func contrast(_ x: RGBA, _ y: RGBA) -> Double {
    func lum(_ c: RGBA) -> Double {
        func l(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * l(c.r) + 0.7152 * l(c.g) + 0.0722 * l(c.b)
    }
    let a = lum(x), b = lum(y)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

private let kinds: [SyntaxKind] = [.keyword, .entity, .constant, .string, .variable, .comment, .entityTag, .heading, .list]

/// Every text color of a file card against the backgrounds it is drawn on, composited as the view
/// layers them: line and number cells on the canvas, word backgrounds on the line.
@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func everyDiffTextReadsAtFourPointFive(_ name: NSAppearance.Name) {
    func c(_ color: Color) -> RGBA { resolve(color, name) }
    let canvas = c(DiffColors.canvas)
    let addLine = over(c(DiffColors.addedLine), canvas), delLine = over(c(DiffColors.removedLine), canvas)
    let addWord = over(c(DiffColors.addedWord), addLine), delWord = over(c(DiffColors.removedWord), delLine)
    let text = c(DiffColors.text), muted = c(DiffColors.mutedText)
    for bg in [canvas, addLine, delLine, addWord, delWord] { #expect(contrast(text, bg) >= 4.5) }
    #expect(contrast(muted, canvas) >= 4.5)  // context line numbers
    #expect(contrast(text, over(c(DiffColors.addedNumber), canvas)) >= 4.5)
    #expect(contrast(text, over(c(DiffColors.removedNumber), canvas)) >= 4.5)
    #expect(contrast(muted, over(c(DiffColors.hunkLine), canvas)) >= 4.5)
    let header = c(DiffColors.header)
    for fg in [muted, text, c(DiffColors.addedCount), c(DiffColors.removedCount)] { #expect(contrast(fg, header) >= 4.5) }
    for k in kinds {
        for bg in [canvas, addLine, delLine] { #expect(contrast(c(DiffColors.syntax(k)), bg) >= 4.5, "\(k) \(name.rawValue)") }
        for bg in [addWord, delWord] { #expect(contrast(c(DiffColors.syntax(k, onWord: true)), bg) >= 4.5, "\(k) on word \(name.rawValue)") }
        // a kind falls back to the body color on a word only when its own color misses there
        let own = c(DiffColors.syntax(k)), onWord = c(DiffColors.syntax(k, onWord: true))
        let ownReads = contrast(own, addWord) >= 4.5 && contrast(own, delWord) >= 4.5
        #expect((onWord == own) == ownReads || own == text, "\(k) \(name.rawValue)")
    }
}

/// The detail pane sets `.foregroundStyle(text, mutedText)`, so its `.primary`/`.secondary` draw in
/// GitHub's colors. Rendered, not assumed; compared with the same colors drawn through the same renderer.
@MainActor @Test(arguments: [ColorScheme.light, .dark])
func detailHierarchyDrawsInGitHubColors(_ scheme: ColorScheme) throws {
    func pixel(_ view: some View) throws -> [Int] {
        let r = ImageRenderer(content: view.frame(width: 4, height: 4).environment(\.colorScheme, scheme))
        r.scale = 1
        let image = try #require(r.nsImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let c = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: 2, y: 2))
        return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
    }
    func hierarchy(_ style: HierarchicalShapeStyle) -> some View {
        Rectangle().fill(style).foregroundStyle(DiffColors.text, DiffColors.mutedText)
    }
    #expect(try pixel(hierarchy(.primary)) == pixel(Rectangle().fill(DiffColors.text)))
    #expect(try pixel(hierarchy(.secondary)) == pixel(Rectangle().fill(DiffColors.mutedText)))
    #expect(try pixel(hierarchy(.secondary)) != pixel(Rectangle().fill(.secondary)))
}

/// What else the detail pane draws on the canvas: links and the team pill.
@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func detailExtrasReadOnTheCanvas(_ name: NSAppearance.Name) {
    let canvas = resolve(DiffColors.canvas, name)
    var link: RGBA = (0, 0, 0, 0)
    NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
        let s = NSColor.linkColor.usingColorSpace(.sRGB)!
        link = (s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent)
    }
    #expect(contrast(over(link, canvas), canvas) >= 4.5)
    let pill = over(resolve(DiffColors.header, name), canvas)
    #expect(contrast(resolve(DiffColors.text, name), pill) >= 4.5)
    for count in [DiffColors.addedCount, DiffColors.removedCount] { #expect(contrast(resolve(count, name), canvas) >= 4.5) }
    #expect(contrast(resolve(DiffColors.mutedText, name), canvas) >= 4.5)
}
