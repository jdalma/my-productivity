import Foundation

/// The board's IDE area (G4 I5): the editor over the terminal, the folder tree right of the editor. The editor's
/// share of the height is kept per worktree, the tree's width and whether it shows for every worktree.
public struct IdeLayout: Codable, Equatable, Sendable {
    public static let storageKey = "ideLayout"
    public static let standardRatio = 0.5
    /// The editor's and the terminal's least height: a few lines each at the standard font size.
    public static let minHeight = 120.0
    /// The line between the editor and the terminal.
    public static let line = 1.0
    public static let standardTreeWidth = 240.0
    public static let minTreeWidth = 160.0
    public static let maxTreeWidth = 480.0
    public static let minEditorWidth = 200.0

    /// The editor's share of the height, by worktree root.
    // ponytail: one entry per worktree ever shown, never pruned; prune by age if the list ever matters
    private var ratios: [String: Double] = [:]
    public var treeWidth = standardTreeWidth
    public var treeShown = true

    public init() {}

    /// The stored text; the standard layout when it is empty or unreadable.
    public init(stored: String) {
        self = (try? JSONDecoder().decode(IdeLayout.self, from: Data(stored.utf8))) ?? IdeLayout()
    }

    public var stored: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }

    public func ratio(for worktree: String) -> Double { ratios[worktree] ?? Self.standardRatio }

    public mutating func setRatio(_ ratio: Double, for worktree: String) { ratios[worktree] = ratio }

    /// The editor's and the terminal's heights in an area `total` tall. A ratio outside 0...1 is the standard one;
    /// an area too short for two least heights shares by the ratio alone.
    public static func heights(total: Double, ratio: Double) -> (editor: Double, terminal: Double) {
        let room = max(0, total - line)
        let share = ratio.isFinite && (0...1).contains(ratio) ? ratio : standardRatio
        var editor = (room * share).rounded()
        if room >= 2 * minHeight { editor = min(max(editor, minHeight), room - minHeight) }
        return (editor, room - editor)
    }

    /// The ratio that gives the editor `editor` points, for a drag measured from where the line was.
    public static func ratio(editor: Double, total: Double) -> Double {
        let room = total - line
        return room > 0 ? min(max(editor, 0), room) / room : standardRatio
    }

    /// The tree's width in an area `total` wide: within its bounds, and giving way to the editor's least width.
    public static func treeWidth(_ width: Double, total: Double) -> Double {
        max(0, min(min(max(width, minTreeWidth), maxTreeWidth), total - minEditorWidth))
    }
}
