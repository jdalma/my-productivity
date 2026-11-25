import Foundation
import Testing
@testable import TowerCore

// What a task board link shows read-only (G4 I12, D#17): a file at a commit, a file on disk, at a line.

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
    // outside every root: whatever the page sends back is refused
    let files = EditorFiles(roots: [])
    #expect(await files.handle(.writeFile(path: doc, text: "x", baseHash: sha256(Data("two\n".utf8)))) == .refused(.outside))
}

// MARK: - G4 I12: the line a link names, and whether the file moved since the review

@Test func aLinkOpensTheFileAtItsLine() throws {
    let (dir, first) = try repo()
    #expect(commitOpen(dir: dir, rev: first, path: "src/a.swift", line: 1)
            == .openFile(path: dir + "/src/a.swift", text: "one\n", hash: sha256(Data("one\n".utf8)), line: 1, readOnly: true))
    #expect(readOnlyOpen(dir + "/src/a.swift", line: 1)
            == .openFile(path: dir + "/src/a.swift", text: "two\n", hash: sha256(Data("two\n".utf8)), line: 1, readOnly: true))
}

@Test func aFileChangedSinceTheReviewedCommitIsToldApart() throws {
    let (dir, first) = try repo()  // src/a.swift edited in the work tree after `first`
    #expect(fileChanged(dir: dir, since: first, path: "src/a.swift") == true)
    try git(dir, "checkout", "-q", "--", "src/a.swift")
    #expect(fileChanged(dir: dir, since: first, path: "src/a.swift") == false)
    #expect(fileChanged(dir: dir, since: "0000000", path: "src/a.swift") == nil)
}

@Test func markersEncodeForThePage() throws {
    let m = EditorCommand.setMarkers(path: "/w/a", markers: [EditorMarker(line: 3, severity: .warning, message: "R1 S1 x")])
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as! [String: Any]
    #expect(json["kind"] as? String == "setMarkers" && json["path"] as? String == "/w/a")
    #expect((json["markers"] as? [[String: Any]])?.first?["severity"] as? String == "warning")
}
