import AppKit

/// The board's 보기 › 화면 choice. Applied to `NSApp.appearance`, so the board, the menu bar dropdown
/// and Settings all follow it; `system` clears the override.
enum AppearanceChoice: String, CaseIterable {
    case system, light, dark

    static let storageKey = "appearance"

    /// An unknown stored value follows the system.
    init(stored: String) { self = AppearanceChoice(rawValue: stored) ?? .system }

    var label: String {
        switch self {
        case .system: "시스템"
        case .light: "라이트"
        case .dark: "다크"
        }
    }

    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    @MainActor func apply() { NSApp.appearance = appearanceName.flatMap(NSAppearance.init(named:)) }
}
