import Foundation

// A task's code in the task board window (G4 I6, plan K5): the tree and the read-only editor beside the detail.

/// Where the task board reads a task's code.
public enum TaskCodeSource: Hashable, Sendable {
    /// The assignee's worktree as it is now.
    case worktree(String)
    /// A landing's commit in its repo; `base`, the start of the task's changes.
    case commit(repo: String, base: String?, commit: String)
}

/// The assignee's worktree while the task is unfinished and its worker runs (D#6 a); otherwise the task's last landing
/// with a commit, at that commit: a worker's worktree serves its next tasks, so a finished task's files are read from
/// git (plan §2 공통 사실). Its changes start at the task's base, else the landing's. nil with neither: a document
/// task, a task not yet worked. `landings` are the task's own, in time order.
public func taskCodeSource(state: String, workerCwd: String?, taskBase: String?, landings: [TaskBoardLanding]) -> TaskCodeSource? {
    if !["done", "cancelled"].contains(state), let workerCwd { return .worktree(workerCwd) }
    guard let l = landings.last(where: { $0.repo != nil && !$0.commit.isEmpty }), let repo = l.repo else { return nil }
    return .commit(repo: repo, base: taskBase ?? l.baseCommit, commit: l.commit)
}

/// The files `rev` holds in `dir`, paths from the repository's top; nil when it is no revision there. `rev` comes
/// after `--end-of-options`: a landing's commit is another worker's input.
public func filesAt(dir: String, rev: String) -> [String]? {
    guard let z = out(.lsTree, ["-r", "--name-only", "-z", "--end-of-options", rev], in: dir) else { return nil }
    return z.split(separator: "\0").map(String.init)
}

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
