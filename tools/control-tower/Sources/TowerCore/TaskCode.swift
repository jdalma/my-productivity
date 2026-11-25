import Foundation

// What the board window's editor shows read-only for a task board link (G4 I12, D#17): a file as a commit holds it,
// or as it is on disk, never through `EditorFiles`, so no save of it is ever taken.

/// `path` as `rev` holds it, for the page to show read-only; nil for a folder, a binary file or no such file. Not
/// read through `EditorFiles`, so no save of it is ever taken.
public func commitOpen(dir: String, rev: String, path: String, line: Int? = nil) -> EditorCommand? {
    guard case .text(let text) = fileAt(dir: dir, rev: rev, path: path) else { return nil }
    return .openFile(path: dir + "/" + path, text: text, hash: sha256(Data(text.utf8)), line: line, readOnly: true)
}

/// A document the board names (a ticket, a report), for the page to show read-only (D#7 b); nil unless `path` is
/// absolute and a text file. Outside every `EditorFiles` root, so no save of it is taken.
public func readOnlyOpen(_ path: String, line: Int? = nil) -> EditorCommand? {
    guard path.hasPrefix("/"), let real = realPath(path),
          case .text(let f) = readFullFile(toplevel: "/", path: String(real.dropFirst())) else { return nil }
    return .openFile(path: real, text: f.text, hash: f.hash, line: line, readOnly: true)
}

/// What the page gets for a link's target (G4 I12): the file at its line, read-only.
public func targetOpen(_ target: FileTarget) -> EditorCommand? {
    switch target {
    case .file(let path, let line): readOnlyOpen(path, line: line)
    case .commit(let repo, let commit, let path, let line): commitOpen(dir: repo, rev: commit, path: path, line: line)
    }
}
