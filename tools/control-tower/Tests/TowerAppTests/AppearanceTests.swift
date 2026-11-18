import AppKit
import SwiftUI
import Testing
@testable import TowerApp

@Test func storedChoiceMapsToAnAppearance() {
    #expect(AppearanceChoice(stored: "system").appearanceName == nil)
    #expect(AppearanceChoice(stored: "light").appearanceName == .aqua)
    #expect(AppearanceChoice(stored: "dark").appearanceName == .darkAqua)
    #expect(AppearanceChoice(stored: "sepia") == .system)
    #expect(AppearanceChoice.allCases.map(\.label) == ["시스템", "라이트", "다크"])
}

/// The tag color resolves against the appearance it is drawn in (which NSApp.appearance sets),
/// not the system setting.
@Test func tagTextLightensOnlyWhenDrawnDark() {
    func resolved(_ name: NSAppearance.Name) -> (text: NSColor, base: NSColor) {
        var c = (text: NSColor.clear, base: NSColor.clear)
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            c = (NSColor(LineKind.team.textColor).usingColorSpace(.sRGB)!, NSColor(LineKind.team.color).usingColorSpace(.sRGB)!)
        }
        return c
    }
    let light = resolved(.aqua), dark = resolved(.darkAqua)
    #expect(light.text == light.base)
    #expect(dark.text != dark.base)
    // toward white: every channel up (HSB brightness is already 1 for #58a6ff, so it cannot show this)
    #expect(dark.text.redComponent > dark.base.redComponent && dark.text.greenComponent > dark.base.greenComponent)
}

/// T41, T41a: my-team in Primer's accent blue, claude in terracotta, each with its own light and dark value.
@Test func teamAndClaudeTagsTakeTheirChosenColors() {
    func hex(_ c: Color, _ name: NSAppearance.Name) -> String {
        var out = ""
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let s = NSColor(c).usingColorSpace(.sRGB)!
            out = String(format: "%02x%02x%02x", Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()),
                         Int((s.blueComponent * 255).rounded()))
        }
        return out
    }
    #expect([hex(LineKind.team.color, .aqua), hex(LineKind.team.color, .darkAqua)] == ["0550ae", "58a6ff"])
    #expect([hex(LineKind.agent(.claude).color, .aqua), hex(LineKind.agent(.claude).color, .darkAqua)] == ["8f3a1c", "e8906f"])
    #expect(hex(LineKind.agent(.claude).textColor, .aqua) == "8f3a1c")
    // T43: Primer's display teal, light scale-7 and dark scale-8, for 4.5:1 where the tags sit
    #expect([hex(LineKind.agent(.codex).color, .aqua), hex(LineKind.agent(.codex).color, .darkAqua)] == ["0d5b63", "24d6c4"])
}
