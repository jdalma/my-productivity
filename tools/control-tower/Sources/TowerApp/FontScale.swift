import AppKit
import SwiftUI

/// The board window's text scale, 0.8 to 2.0 in 0.1 steps. Kept in tenths so repeated steps never drift.
struct FontScale: Equatable {
    static let standard = FontScale(tenths: 10)
    static let storageKey = "boardFontScale"
    private static let bounds = 8...20

    private let tenths: Int

    private init(tenths: Int) {
        self.tenths = min(max(tenths, Self.bounds.lowerBound), Self.bounds.upperBound)
    }

    /// A stored value outside 0.8...2.0 (or not a number) restores the standard size.
    init(stored: Double) {
        guard stored.isFinite, (0.8...2.0).contains(stored) else {
            self = .standard
            return
        }
        // 1.1 * 10 is 11.000000000000002 and 0.7 * 10 is 6.999999999999999: absorb the error, then truncate.
        self.init(tenths: Int((stored * 10 + 1e-9).rounded(.down)))
    }

    var value: Double { Double(tenths) / 10 }
    func bigger() -> FontScale { FontScale(tenths: tenths + 1) }
    func smaller() -> FontScale { FontScale(tenths: tenths - 1) }
}

extension EnvironmentValues {
    @Entry var boardFontScale = 1.0
}

/// The measures of a document's text (T205, brief E and F), in one place: the user may tune them after seeing them.
enum DocumentType {
    /// A line's height over the font's size, for the body and for a heading.
    static let bodyLineHeight = 1.5
    static let headingLineHeight = 1.3
    /// A heading's size over the body's, by level; a deeper heading is the body's size.
    static let headingSizes: [Int: Double] = [1: 1.875, 2: 1.5, 3: 1.25]
    /// The room between a document's blocks, which is also below a heading, and the room above a heading.
    static let blockSpacing: CGFloat = 8
    static let headingSpaceAbove: CGFloat = 24

    static func headingSize(_ level: Int) -> Double { headingSizes[level] ?? 1 }

    /// What `lineSpacing` adds to a line of the system font at `size` for the line to be `height` times the size.
    static func lineGap(size: Double, height: Double) -> CGFloat {
        max(0, size * height - NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: size)))
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.boardFontScale) private var scale
    let style: NSFont.TextStyle
    var factor = 1.0
    let weight: Font.Weight
    var design: Font.Design = .default
    var lineHeight: Double?

    func body(content: Content) -> some View {
        let size = NSFont.preferredFont(forTextStyle: style).pointSize * factor * scale
        let font = content.font(.system(size: size, weight: weight, design: design))
        if let lineHeight { font.lineSpacing(DocumentType.lineGap(size: size, height: lineHeight)) } else { font }
    }
}

extension View {
    /// A system text style's size times the board's font scale. SF Symbols in the view follow it.
    func scaledFont(_ style: NSFont.TextStyle, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(style: style, weight: weight, design: design))
    }

    /// A document's running text: the body's size and `DocumentType.bodyLineHeight`.
    func documentText() -> some View {
        modifier(ScaledFont(style: .body, weight: .regular, lineHeight: DocumentType.bodyLineHeight))
    }

    /// A document's heading: a multiple of the body's size, so it follows the system's body size as `scaledFont` does.
    func documentHeading(_ level: Int, weight: Font.Weight) -> some View {
        modifier(ScaledFont(style: .body, factor: DocumentType.headingSize(level), weight: weight, lineHeight: DocumentType.headingLineHeight))
    }
}
