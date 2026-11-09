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

private struct ScaledFont: ViewModifier {
    @Environment(\.boardFontScale) private var scale
    let style: NSFont.TextStyle
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: NSFont.preferredFont(forTextStyle: style).pointSize * scale, weight: weight, design: design))
    }
}

extension View {
    /// A system text style's size times the board's font scale. SF Symbols in the view follow it.
    func scaledFont(_ style: NSFont.TextStyle, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(style: style, weight: weight, design: design))
    }
}
