import Foundation
import Testing
@testable import TowerCore

// The task board's code (G4 I6): where a task's code is read, the files of a commit, and what the page gets to show
// a file read-only.

private func landings(_ json: String) throws -> [TaskBoardLanding] {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return try d.decode([TaskBoardLanding].self, from: Data(json.utf8))
}

private let two = """
[{"id":"T5#1","task_id":"T5","repo":"/w/dev","commit":"1111111","base_commit":"0000000","commits":["1111111"]},
 {"id":"T5#2","task_id":"T5","repo":"/w/dev","commit":"2222222","base_commit":"1111111","commits":["2222222"]}]
"""

@Test func anUnfinishedTaskWithARunningWorkerIsReadInItsWorktree() throws {
    #expect(taskCodeSource(state: "doing", workerCwd: "/w/dev", taskBase: "0000000", landings: try landings(two)) == .worktree("/w/dev"))
    #expect(taskCodeSource(state: "changes", workerCwd: "/w/dev", taskBase: nil, landings: []) == .worktree("/w/dev"))
}

@Test func aDoneTaskIsReadAtItsLastLandingFromTheTasksBase() throws {
    // the worktree serves the worker's next task now: the landing's commit, its changes from the task's base
    #expect(taskCodeSource(state: "done", workerCwd: "/w/dev", taskBase: "0000000", landings: try landings(two))
            == .commit(repo: "/w/dev", base: "0000000", commit: "2222222"))
    // no task base: the landing's own
    #expect(taskCodeSource(state: "review", workerCwd: nil, taskBase: nil, landings: try landings(two))
            == .commit(repo: "/w/dev", base: "1111111", commit: "2222222"))
}

@Test func aTaskWithNeitherHasNoCode() throws {
    let document = try landings(#"[{"id":"T9#1","task_id":"T9","repo":"","commit":"","base_commit":"","commits":[]}]"#)
    #expect(taskCodeSource(state: "done", workerCwd: "/w/dev", taskBase: nil, landings: document) == nil)
    #expect(taskCodeSource(state: "ready", workerCwd: nil, taskBase: nil, landings: []) == nil)
}

private func git(_ dir: String, _ args: String...) throws {
    let r = try runCommand(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-C", dir] + args, timeout: 30,
                           env: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    #expect(r.status == 0, "git \(args): \(r.stderr)")
}

private func repo() throws -> (dir: String, first: String) {
    let path = FileManager.default.temporaryDirectory.appending(path: "taskcode-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: path + "/src", withIntermediateDirectories: true)
    let top = realPath(path)!
    try git(top, "init", "-q", "-b", "main")
    try "one\n".write(toFile: top + "/src/a.swift", atomically: true, encoding: .utf8)
    try "doc\n".write(toFile: top + "/README.md", atomically: true, encoding: .utf8)
    try git(top, "add", "-A")
    try git(top, "commit", "-q", "-m", "first")
    let first = try runCommand(["git", "-C", top, "rev-parse", "HEAD"], timeout: 10).stdout.trimmed
    try "two\n".write(toFile: top + "/src/a.swift", atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(atPath: top + "/README.md")
    return (top, first)
}

@Test func aCommitsFilesAreItsTreeNotTheWorkTree() throws {
    let (dir, first) = try repo()
    try "new\n".write(toFile: dir + "/untracked.txt", atomically: true, encoding: .utf8)
    #expect(filesAt(dir: dir, rev: first) == ["README.md", "src/a.swift"])
    #expect(filesAt(dir: dir, rev: "no-such-rev") == nil)
    #expect(filesAt(dir: dir, rev: "--output=/tmp/x") == nil)  // a revision is never an option
}

@Test func aFileAtACommitOpensReadOnlyWithItsTextThen() throws {
    let (dir, first) = try repo()
    #expect(commitOpen(dir: dir, rev: first, path: "src/a.swift")
            == .openFile(path: dir + "/src/a.swift", text: "one\n", hash: sha256(Data("one\n".utf8)), line: nil, readOnly: true))
    #expect(commitOpen(dir: dir, rev: first, path: "src") == nil)  // a folder
    #expect(commitOpen(dir: dir, rev: first, path: "gone.txt") == nil)
}

@Test func aDocumentOpensReadOnlyAndNoSaveOfItIsTaken() async throws {
    let (dir, _) = try repo()
    let doc = dir + "/src/a.swift"
    #expect(readOnlyOpen(doc) == .openFile(path: doc, text: "two\n", hash: sha256(Data("two\n".utf8)), line: nil, readOnly: true))
    #expect(readOnlyOpen("src/a.swift") == nil)  // not absolute
    #expect(readOnlyOpen(dir + "/nothing.md") == nil)
    let binary = dir + "/b.bin"
    try Data([0, 1, 2]).write(to: URL(fileURLWithPath: binary))
    #expect(readOnlyOpen(binary) == nil)
    // the task board's editor has no root: whatever the page sends back is refused
    let files = EditorFiles(roots: [])
    #expect(await files.handle(.writeFile(path: doc, text: "x", baseHash: sha256(Data("two\n".utf8)))) == .refused(.outside))
}
