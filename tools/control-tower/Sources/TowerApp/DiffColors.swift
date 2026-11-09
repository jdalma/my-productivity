import AppKit
import SwiftUI
import TowerCore

/// GitHub's diff colors, light and dark, from @primer/primitives 11.10.0
/// (dist/css/functional/themes/light.css and dark.css). The file cards are painted on GitHub's own
/// canvas, so the translucent dark `--diffBlob-*` values blend as they do on github.com.
enum DiffColors {
    /// `--bgColor-default`, `--bgColor-muted`, `--borderColor-default`.
    static let canvas = pair(0xffffffff, 0x0d1117ff)
    static let header = pair(0xf6f8faff, 0x151b23ff)
    static let border = pair(0xd1d9e0ff, 0x3d444dff)
    /// `--fgColor-default`, `--fgColor-muted`, `--fgColor-success`, `--fgColor-danger`.
    static let text = pair(0x1f2328ff, 0xf0f6fcff)
    static let mutedText = pair(0x59636eff, 0x9198a1ff)
    static let addedCount = pair(0x1a7f37ff, 0x3fb950ff)
    static let removedCount = pair(0xd1242fff, 0xf85149ff)

    static let addedLine = pair(0xdafbe1ff, 0x2ea04326)
    static let addedNumber = pair(0xaceebbff, 0x3fb9504d)
    static let addedWord = pair(0xaceebbff, 0x2ea04366)
    static let removedLine = pair(0xffebe9ff, 0xf851491a)
    static let removedNumber = pair(0xffcecbff, 0xf851494d)
    static let removedWord = pair(0xffcecbff, 0xf8514966)
    static let hunkLine = pair(0xddf4ffff, 0x388bfd1a)
    static let hunkNumber = pair(0xb6e3ffff, 0x0c2d6bff)
    /// `--bgColor-attention-muted`, GitHub's highlighted line in a file view.
    static let targetLine = pair(0xfff8c5ff, 0xbb800926)
    /// `--diffBlob-emptyLine-bgColor` and `-emptyNum-bgColor` (both `--bgColor-muted`): the missing side of a split row.
    static let emptyCell = pair(0xf6f8faff, 0x151b23ff)

    /// The tree beside the diff keeps the macOS background, where the plain success/danger read under
    /// 4.5:1: `--fgColor-success`/`-danger` of light-high-contrast.css and dark-high-contrast.css.
    static let treeAddedCount = pair(0x04591fff, 0x2bd853ff)
    static let treeRemovedCount = pair(0x960d1eff, 0xff9492ff)

    /// `--prettylights-syntax-*`. Heading takes the constant color, as highlight.js's github.css does;
    /// the dark heading value reads 3.4:1 on an added line.
    /// On a changed word a color stays only where it reaches 4.5:1 on both word backgrounds of that
    /// appearance; elsewhere the word shows in the body color.
    static func syntax(_ kind: SyntaxKind, onWord: Bool = false) -> Color {
        let (light, dark): (UInt32, UInt32) = switch kind {
        case .keyword: (0xcf222eff, 0xff7b72ff)
        case .entity: (0x6639baff, 0xd2a8ffff)
        case .constant, .heading: (0x0550aeff, 0x79c0ffff)
        case .string: (0x0a3069ff, 0xa5d6ffff)
        case .variable: (0x953800ff, 0xffa657ff)
        case .comment: (0x59636eff, 0x9198a1ff)
        case .entityTag: (0x0550aeff, 0x7ee787ff)
        case .list: (0x3b2300ff, 0xf2cc60ff)
        }
        guard onWord else { return pair(light, dark) }
        return pair(wordSafe.light.contains(kind) ? light : 0x1f2328ff, wordSafe.dark.contains(kind) ? dark : 0xf0f6fcff)
    }

    /// Kinds at 4.5:1 or more on the added and removed word backgrounds (T29 report table).
    private static let wordSafe: (light: Set<SyntaxKind>, dark: Set<SyntaxKind>) = (
        [.entity, .constant, .heading, .string, .variable, .entityTag, .list],
        [.string, .entityTag, .list]
    )

    /// Resolved against the appearance the view is drawn in, which T26's choice sets.
    private static func pair(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            rgba(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }

    static func rgba(_ v: UInt32) -> NSColor {
        func c(_ shift: UInt32) -> CGFloat { CGFloat((v >> shift) & 0xff) / 255 }
        return NSColor(srgbRed: c(24), green: c(16), blue: c(8), alpha: c(0))
    }
}
