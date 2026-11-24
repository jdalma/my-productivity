import Observation
import TowerCore

// The "변경" area's file tree, built from a diff section already collected. No view code.

enum FileChange: Equatable, Sendable {
    case lines(added: Int, removed: Int)
    case binary
    case untracked
    /// A file of the full folder tree the diff does not touch.
    case unchanged
}

struct ChangeTreeNode: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case directory([ChangeTreeNode])
        case file(FileChange)
    }

    /// One path component, or several joined by `/` for a chain of single-child directories.
    var name: String
    /// From the repo root: the file's diff path, or the directory's.
    var path: String
    var kind: Kind
}

/// Directories first, then files, each by name. A directory whose only child is a directory shares its line.
func changeTree(_ section: DiffSection) -> [ChangeTreeNode] { tree(leaves(section)) }

/// A full folder tree: every file `files` lists, a changed one with its change. A file changed in
/// both sections shows its uncommitted change, as the file view shows the work tree; a changed file the list lacks
/// (deleted and staged) is added. Without a diff every file is `.unchanged`.
func folderTree(files: [String], diff: WorkspaceDiff? = nil) -> [ChangeTreeNode] {
    var change: [String: FileChange] = [:]
    for section in [diff?.committed, diff?.uncommitted].compactMap({ $0 }) {
        for leaf in leaves(section) { change[leaf.path] = leaf.change }
    }
    return tree(Set(files).union(change.keys).map { Leaf(path: $0, change: change[$0] ?? .unchanged) })
}

/// A landing's changed files (G4 I6): an added one marked new, the others plain; git gives no line counts here.
func changedTree(_ files: [ChangedFile]) -> [ChangeTreeNode] {
    tree(files.map { Leaf(path: $0.path, change: $0.status == .added ? .untracked : .lines(added: 0, removed: 0)) })
}

/// The folders, by path, that hold a changed file somewhere below them: the full tree opens these by default.
func changedFolders(_ diff: WorkspaceDiff) -> Set<String> {
    var folders = Set<String>()
    for section in [diff.committed, diff.uncommitted].compactMap({ $0 }) {
        for leaf in leaves(section) {
            var dir = Substring(leaf.path)
            while let slash = dir.lastIndex(of: "/") {
                dir = dir[..<slash]
                guard folders.insert(String(dir)).inserted else { break }
            }
        }
    }
    return folders
}

private func leaves(_ section: DiffSection) -> [Leaf] {
    section.files.map { f in
        Leaf(path: f.path, change: f.binary ? .binary : .lines(added: f.added, removed: f.removed))
    } + section.untracked.map { Leaf(path: $0, change: .untracked) }
}

private func tree(_ leaves: [Leaf]) -> [ChangeTreeNode] {
    build(leaves.map { (rest: $0.path.split(separator: "/").map(String.init), leaf: $0) }, under: "")
}

/// What the diff window's tree lists: the changed files of each section, or every file of the workspace.
enum TreeMode: Hashable {
    case changed, all
}

extension ChangeTreeNode {
    /// A directory's lines, nil for a file: what the tree's disclosure opens.
    var children: [ChangeTreeNode]? {
        if case .directory(let c) = kind { c } else { nil }
    }
}

/// A line of the diff window's tree as its list selects it, unique across the sections and the two modes.
struct TreeLine: Hashable {
    /// The section a changed view's line is in; nil in the full view.
    var part: DiffPart?
    var path: String
    var isFolder: Bool

    init(_ node: ChangeTreeNode, part: DiffPart?) {
        self.part = part
        path = node.path
        isFolder = node.children != nil
    }

    /// What `FolderTreeState.flippedFolders` holds for a folder.
    var id: String {
        switch part {
        case .committed: "c:" + path
        case .uncommitted: "u:" + path
        case nil: "a:" + path
        }
    }
}

/// What a folder tree keeps while it is shown, whoever shows it: the folders opened or closed, the line picked.
@MainActor @Observable
final class FolderTreeState {
    /// Folder line ids (`TreeLine.id`) the user opened or closed against their default, both modes.
    private(set) var flippedFolders: Set<String> = []
    /// The line the list selects.
    var picked: TreeLine?

    /// A folder is open by `byDefault`, unless the user opened or closed it against that.
    func isOpen(_ folder: TreeLine, byDefault: Bool) -> Bool { byDefault != flippedFolders.contains(folder.id) }

    func setOpen(_ folder: TreeLine, _ open: Bool, byDefault: Bool) {
        if open == byDefault { flippedFolders.remove(folder.id) } else { flippedFolders.insert(folder.id) }
    }

    /// Another root is another tree: its folders start at their defaults, nothing picked.
    func reset() {
        flippedFolders = []
        picked = nil
    }
}

private struct Leaf {
    var path: String
    var change: FileChange
}

private func build(_ items: [(rest: [String], leaf: Leaf)], under prefix: String) -> [ChangeTreeNode] {
    let files = items.filter { $0.rest.count == 1 }
        .map { ChangeTreeNode(name: $0.rest[0], path: $0.leaf.path, kind: .file($0.leaf.change)) }
        .sorted { $0.name < $1.name }
    let byDir = Dictionary(grouping: items.filter { $0.rest.count > 1 }, by: { $0.rest[0] })
    let dirs = byDir.keys.sorted().map { name -> ChangeTreeNode in
        let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
        let children = build(byDir[name]!.map { (Array($0.rest.dropFirst()), $0.leaf) }, under: path)
        if children.count == 1, case .directory = children[0].kind {
            return ChangeTreeNode(name: "\(name)/\(children[0].name)", path: children[0].path, kind: children[0].kind)
        }
        return ChangeTreeNode(name: name, path: path, kind: .directory(children))
    }
    return dirs + files
}

enum DiffPart: Hashable {
    case committed, uncommitted
}

/// A file's place in the "변경" area: the key folding state and tree clicks use, stable across refreshes.
struct DiffFileKey: Hashable {
    var part: DiffPart
    var path: String
}

/// A file header's directory (with its trailing `/`, '' at the root) and file name, the tree's leaf name.
func splitPath(_ path: String) -> (dir: String, name: String) {
    guard let slash = path.lastIndex(of: "/") else { return ("", path) }
    return (String(path[...slash]), String(path[path.index(after: slash)...]))
}

/// `+N` and `−N`, each left out at 0.
func changeCounts(added: Int, removed: Int) -> [String] {
    (added > 0 ? ["+\(added)"] : []) + (removed > 0 ? ["−\(removed)"] : [])
}

/// A diff line as shown: tabs as four spaces. The collected text keeps its tabs.
func displayLine(_ text: String) -> String {
    text.replacingOccurrences(of: "\t", with: "    ")
}
