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
    // the file card's counts and links on the canvas itself (T75 kept these from the detail's old canvas test)
    for count in [DiffColors.addedCount, DiffColors.removedCount] { #expect(contrast(c(count), canvas) >= 4.5) }
    #expect(contrast(over(c(Color(nsColor: .linkColor)), canvas), canvas) >= 4.5)
    for k in kinds {
        for bg in [canvas, addLine, delLine] { #expect(contrast(c(DiffColors.syntax(k)), bg) >= 4.5, "\(k) \(name.rawValue)") }
        for bg in [addWord, delWord] { #expect(contrast(c(DiffColors.syntax(k, onWord: true)), bg) >= 4.5, "\(k) on word \(name.rawValue)") }
        // a kind falls back to the body color on a word only when its own color misses there
        let own = c(DiffColors.syntax(k)), onWord = c(DiffColors.syntax(k, onWord: true))
        let ownReads = contrast(own, addWord) >= 4.5 && contrast(own, delWord) >= 4.5
        #expect((onWord == own) == ownReads || own == text, "\(k) \(name.rawValue)")
    }
}

/// The worker detail on the window's own background (T75): its text, links and the team pill's text read 4.5:1.
/// `.secondary` text is left out: macOS's secondaryLabelColor reads 3.95:1 in light (T75 report).
@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func detailTextReadsOnTheWindowBackground(_ name: NSAppearance.Name) {
    func ns(_ c: NSColor) -> RGBA { resolve(Color(nsColor: c), name) }
    let window = ns(.windowBackgroundColor)
    #expect(contrast(over(ns(.labelColor), window), window) >= 4.5)
    #expect(contrast(over(ns(.linkColor), window), window) >= 4.5)
    let pill = over(ns(.quaternaryLabelColor), window)
    #expect(contrast(over(ns(.labelColor), pill), pill) >= 4.5)
}

/// T124, T132: the sidebar's team head without its band. Its name (`.primary`) and its icon and counts
/// (`TaskColor.sidebarGray`) read 4.5:1 on the window's background and on the sidebar's material, which a test cannot
/// resolve: in light a gray darker than it is drawn (#e0e0e0), in dark its color in a capture (#37393a, T124 report).
/// `.secondary` would read about 4:1 in light (T75 report), so the counts do not use it.
@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func theTeamHeadReadsOnTheSidebar(_ name: NSAppearance.Name) {
    func ns(_ c: NSColor) -> RGBA { resolve(Color(nsColor: c), name) }
    let dark: RGBA = (55 / 255.0, 57 / 255.0, 58 / 255.0, 1)
    let light: RGBA = (224 / 255.0, 224 / 255.0, 224 / 255.0, 1)
    let sidebar = name == .darkAqua ? dark : light
    for bg in [ns(.windowBackgroundColor), sidebar] {
        #expect(contrast(over(ns(.labelColor), bg), bg) >= 4.5, "name \(name.rawValue)")
        let counts = contrast(over(resolve(TaskColor.sidebarGray, name), bg), bg)
        #expect(counts >= 4.5, "icon and counts \(name.rawValue): \(counts)")
    }
}

/// The task detail's colored words (T92, H7): verdicts, finding states, "설치됨", the left-out commits, and each
/// state's word in the summary, on the window and on a text background.
@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func taskDetailWordsReadAtFourPointFive(_ name: NSAppearance.Name) {
    let verdicts = ["approve", "changes", "hold"].map { VerdictStyle.of($0).color }
    let findings = [FindingStatus.open, .fixedPending("T1#1"), .fixedApproved("T1#2")].map { FindingStyle.of($0).color }
    let states = TaskStateStyle.all.map { TaskStateStyle.of($0).color }
    let todo = [TodoStatus.done, .doing, .notYet].map { TodoStyle.of($0).color }  // T128: the to-do marks
    for bg in [NSColor.windowBackgroundColor, .textBackgroundColor].map({ resolve(Color(nsColor: $0), name) }) {
        for c in verdicts + findings + states + todo + [TaskColor.green, TaskColor.orange] {
            #expect(contrast(resolve(c, name), bg) >= 4.5, "\(c) \(name.rawValue)")
        }
    }
}

/// The task board's tags and bands (T70b, v2 §A.3): each state's word on its own tint, each group's count, the
/// group name and whose move on the band, all over the canvas.
@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func taskBoardTagsAndBandsReadAtFourPointFive(_ name: NSAppearance.Name) {
    let canvas = resolve(DiffColors.canvas, name)
    func tinted(_ c: Color, _ opacity: Double) -> RGBA { over(resolve(c.opacity(opacity), name), canvas) }
    for state in TaskStateStyle.all {
        let c = TaskStateStyle.of(state).color
        #expect(contrast(resolve(c, name), tinted(c, TaskPanelStyle.tagOpacity)) >= 4.5, "\(state) tag \(name.rawValue)")
        #expect(contrast(resolve(c, name), canvas) >= 4.5, "\(state) untinted on a finished line \(name.rawValue)")
    }
    for g in TaskPanel.allCases {
        let band = tinted(TaskPanelStyle.of(g).color, TaskPanelStyle.bandOpacity)
        for fg in [TaskPanelStyle.of(g).color, DiffColors.text, DiffColors.mutedText] {
            #expect(contrast(resolve(fg, name), band) >= 4.5, "\(g) band \(name.rawValue)")
        }
    }
}

/// T116: the sidebar's 결정 대기 count, its word on the filled pink.
@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func theUsersDecisionCountReadsAtFourPointFive(_ name: NSAppearance.Name) {
    #expect(contrast(resolve(TaskColor.onRed, name), resolve(TaskColor.pink, name)) >= 4.5, "\(name.rawValue)")
}

/// The severity tags (T91, H7): 필수's word on its filled red, 권장's and 낮음's words over the canvas, and the
/// finished line's title, now primary, over the canvas.
@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func severityTagsAndFinishedTitlesReadAtFourPointFive(_ name: NSAppearance.Name) {
    let canvas = resolve(DiffColors.canvas, name)
    let red = over(resolve(TaskColor.red, name), canvas)
    #expect(contrast(resolve(TaskColor.onRed, name), red) >= 4.5, "필수 \(name.rawValue)")
    for c in [TaskColor.orange, TaskColor.gray] {
        #expect(contrast(resolve(c, name), canvas) >= 4.5, "권장/낮음 \(name.rawValue)")
    }
    #expect(contrast(resolve(DiffColors.text, name), canvas) >= 4.5, "finished title \(name.rawValue)")
}

/// T155: a worker's initial on its color. T205: a callout's name and its text on its gray over the callout's ground,
/// which keeps a decision brief's pink from mixing in (R12 L5).
@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func personTagsAndCalloutsReadAtFourPointFive(_ name: NSAppearance.Name) {
    for c in personColors { #expect(contrast(resolve(personInk, name), resolve(c, name)) >= 4.5, "\(c) \(name.rawValue)") }
    let callout = over(resolve(CalloutStyle.fill, name), resolve(CalloutStyle.ground, name))
    for kind in CalloutKind.allCases {
        let c = contrast(resolve(CalloutStyle.of(kind).color, name), callout)
        #expect(c >= 4.5, "\(kind) \(name.rawValue): \(c)")
    }
    let text = contrast(over(resolve(Color(nsColor: .labelColor), name), callout), callout)
    #expect(text >= 4.5, "text \(name.rawValue): \(text)")
}
