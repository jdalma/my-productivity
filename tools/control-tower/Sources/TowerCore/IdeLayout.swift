import Foundation

/// The board's IDE area (G4 I5): the folder tree right of the editor. The tree's width and whether it shows are
/// kept for every worktree.
public struct IdeLayout: Codable, Equatable, Sendable {
    public static let storageKey = "ideLayout"
    /// The line between the editor and the tree.
    public static let line = 1.0
    public static let standardTreeWidth = 240.0
    public static let minTreeWidth = 160.0
    public static let maxTreeWidth = 480.0
    public static let minEditorWidth = 200.0

    public var treeWidth = standardTreeWidth
    public var treeShown = true

    public init() {}

    /// The stored text; the standard layout when it is empty or unreadable.
    public init(stored: String) {
        self = (try? JSONDecoder().decode(IdeLayout.self, from: Data(stored.utf8))) ?? IdeLayout()
    }

    public var stored: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }

    /// The tree's width in an area `total` wide: within its bounds, and giving way to the editor's least width.
    public static func treeWidth(_ width: Double, total: Double) -> Double {
        max(0, min(min(max(width, minTreeWidth), maxTreeWidth), total - minEditorWidth))
    }
}
