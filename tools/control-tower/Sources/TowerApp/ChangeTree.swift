import TowerCore

// The "변경" area's file tree, built from a diff section already collected. No view code.

enum FileChange: Equatable {
    case lines(added: Int, removed: Int)
    case binary
    case untracked
}

struct ChangeTreeNode: Equatable {
    enum Kind: Equatable {
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
func changeTree(_ section: DiffSection) -> [ChangeTreeNode] {
    let leaves = section.files.map { f in
        Leaf(path: f.path, change: f.binary ? .binary : .lines(added: f.added, removed: f.removed))
    } + section.untracked.map { Leaf(path: $0, change: .untracked) }
    return build(leaves.map { (rest: $0.path.split(separator: "/").map(String.init), leaf: $0) }, under: "")
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
