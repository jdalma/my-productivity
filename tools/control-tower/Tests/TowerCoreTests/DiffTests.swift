import Foundation
import Testing
@testable import TowerCore

// MARK: - Fixture repos

private let isolation = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]

@discardableResult
private func sh(_ dir: String, _ args: [String]) throws -> String {
    let r = try runCommand(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-C", dir] + args, timeout: 30, env: isolation)
    #expect(r.status == 0, "git \(args) failed: \(r.stderr)")
    return r.stdout.trimmed
}

private func write(_ dir: String, _ file: String, _ content: String) throws {
    try content.write(toFile: "\(dir)/\(file)", atomically: true, encoding: .utf8)
}

private func commit(_ dir: String, _ file: String, _ content: String, _ msg: String = "c") throws {
    try write(dir, file, content)
    try sh(dir, ["add", "-A"])
    try sh(dir, ["commit", "-q", "-m", msg])
}

/// A temp directory; a repo on `main` with one commit when `repo`.
private func fixture(repo: Bool = true) throws -> String {
    let url = FileManager.default.temporaryDirectory.appending(path: "diff-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // /var/folders is a symlink to /private/var and git reports the real path
    let dir = String(cString: realpath(url.path, nil))
    if repo {
        try sh(dir, ["init", "-q", "-b", "main"])
        try commit(dir, "a.txt", "1\n2\n3\n4\n5\n", "base")
        try write(dir, "b.txt", "x\ny\n")
        try sh(dir, ["add", "-A"])
        try sh(dir, ["commit", "-q", "-m", "b"])
    }
    return dir
}

private func result(_ dir: String, pinned: String? = nil, limit: Int = 2000) throws -> WorkspaceDiff {
    guard case .diff(let d) = workspaceDiff(at: dir, pinnedBase: pinned, lineLimit: limit) else {
        Issue.record("expected a repo at \(dir)")
        throw CommandError(description: "not a repo")
    }
    return d
}

private func baseRef(_ d: WorkspaceDiff) -> String? {
    if case .resolved(let ref, _) = d.base { ref } else { nil }
}

// MARK: - Acceptance 2

@Test func committedUncommittedAndUntrackedAreSeparated() throws {
    let dir = try fixture()
    let fork = try sh(dir, ["rev-parse", "HEAD"])
    try sh(dir, ["switch", "-q", "-c", "feature"])
    try commit(dir, "a.txt", "1\n2\nTHREE\n4\n5\n")
    try commit(dir, "c.txt", "new\n")
    try write(dir, "b.txt", "x\ny\nz\n")
    try write(dir, "n.txt", "untracked\n")

    let d = try result(dir)
    #expect(d.toplevel == dir)
    #expect(d.base == .resolved(ref: "main", mergeBase: fork))
    let committed = try #require(d.committed)
    #expect(committed.files.map(\.path) == ["a.txt", "c.txt"])
    #expect(committed.added == 2 && committed.removed == 1)
    #expect(d.uncommitted.files.map(\.path) == ["b.txt"])
    #expect(d.uncommitted.added == 2 && d.uncommitted.removed == 0)  // b.txt's line and untracked n.txt's
    #expect(d.uncommitted.untracked == ["n.txt"])
    #expect(((d.committed?.files ?? []) + d.uncommitted.files).allSatisfy { $0.hiddenLines == 0 })
}

@Test func originHeadNamesTheBase() throws {
    let dir = try fixture()
    try sh(dir, ["branch", "develop"])
    try sh(dir, ["update-ref", "refs/remotes/origin/develop", "develop"])
    try sh(dir, ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop"])
    #expect(baseRef(try result(dir)) == "develop")
}

@Test func mainWithoutOriginHeadIsTheBaseAndMasterIsTheFallback() throws {
    let dir = try fixture()
    #expect(baseRef(try result(dir)) == "main")
    try sh(dir, ["branch", "-m", "main", "master"])
    #expect(baseRef(try result(dir)) == "master")
}

@Test func theNewerMergeBaseWinsBetweenLocalAndOrigin() throws {
    let behind = try fixture()
    try sh(behind, ["switch", "-q", "-c", "feature"])
    try commit(behind, "a.txt", "changed\n")
    try sh(behind, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    try sh(behind, ["switch", "-q", "-c", "work"])
    try commit(behind, "w.txt", "w\n")
    #expect(baseRef(try result(behind)) == "origin/main")

    let ahead = try fixture()
    try sh(ahead, ["branch", "old"])
    try sh(ahead, ["update-ref", "refs/remotes/origin/main", "old"])
    try sh(ahead, ["switch", "-q", "-c", "work"])
    try commit(ahead, "w.txt", "w\n")
    #expect(baseRef(try result(ahead)) == "main")
}

@Test func aPinnedBaseThatIsGoneIsReportedNotReplaced() throws {
    let dir = try fixture()
    try sh(dir, ["branch", "gone"])
    #expect(baseRef(try result(dir, pinned: "gone")) == "gone")
    try sh(dir, ["branch", "-D", "gone"])
    let d = try result(dir, pinned: "gone")
    #expect(d.base == .pinnedMissing("gone"))
    #expect(d.committed == nil)
}

@Test func aPinnedRemoteTrackingBaseIsUsedAsIs() throws {
    let dir = try fixture()
    try sh(dir, ["update-ref", "refs/remotes/origin/develop", "main"])
    #expect(baseRef(try result(dir, pinned: "origin/develop")) == "origin/develop")
}

@Test func noBaseLeavesCommittedOutAndUncommittedIntact() throws {
    let dir = try fixture()
    try sh(dir, ["branch", "-m", "main", "trunk"])
    try write(dir, "b.txt", "changed\n")
    let d = try result(dir)
    #expect(d.base == .none)
    #expect(d.committed == nil)
    #expect(d.uncommitted.files.map(\.path) == ["b.txt"])
}

@Test func onTheBaseBranchCommittedIsEmpty() throws {
    let dir = try fixture()
    try write(dir, "b.txt", "changed\n")
    let d = try result(dir)
    #expect(d.committed == DiffSection(files: [], untracked: []))
    #expect(d.uncommitted.files.map(\.path) == ["b.txt"])
}

@Test func notARepo() throws {
    let plain = try fixture(repo: false)
    #expect(workspaceDiff(at: plain, pinnedBase: nil) == .notARepo)
    #expect(workspaceDiff(at: plain + "/missing", pinnedBase: nil) == .notARepo)
}

@Test func linesBeyondTheLimitAreCutAndCounted() throws {
    let dir = try fixture()
    try sh(dir, ["switch", "-q", "-c", "feature"])
    try commit(dir, "big.txt", (1...3000).map { "line \($0)\n" }.joined())
    try write(dir, "a.txt", "1\n2\nTHREE\n4\n5\n")

    let full = try result(dir, limit: 100_000)
    let bigLines = full.committed?.files.first?.lines.count ?? 0
    #expect(bigLines > 3000 && full.committed?.files.first?.hiddenLines == 0)

    let d = try result(dir)
    let big = d.committed?.files.first
    #expect(big?.lines.count == 2000)
    #expect(big?.hiddenLines == bigLines - 2000)
    #expect(big?.added == 3000)
    #expect(d.uncommitted.files.map(\.path) == ["a.txt"])
    #expect(d.uncommitted.files.first?.hiddenLines == 0)
}

@Test func binaryFilesHaveNoLines() throws {
    let dir = try fixture()
    try sh(dir, ["switch", "-q", "-c", "feature"])
    try Data([0, 1, 2, 0xff, 0]).write(to: URL(fileURLWithPath: "\(dir)/img.bin"))
    try sh(dir, ["add", "-A"])
    try sh(dir, ["commit", "-q", "-m", "bin"])
    let f = try #require(try result(dir).committed?.files.first)
    #expect(f.path == "img.bin" && f.binary && f.lines.isEmpty && f.added == 0)
}

@Test func candidatesAreHeadsAndRemoteTrackingWithoutOriginHead() throws {
    let dir = try fixture()
    try sh(dir, ["branch", "feature/x"])
    try sh(dir, ["update-ref", "refs/remotes/origin/develop", "main"])
    try sh(dir, ["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/develop"])
    #expect(baseCandidates(toplevel: dir) == ["feature/x", "main", "origin/develop"])
}

// MARK: - Parser and safety

@Test func parserNumbersLinesFromHunkHeadersAndReadsRenamesAndBinaries() {
    let text = """
    diff --git a/src/a b.txt b/src/a b.txt
    index 111..222 100644
    --- a/src/a b.txt
    +++ b/src/a b.txt
    @@ -3,3 +3,4 @@ func f()
     keep
    -gone
    +new1
    +new2
     tail
    @@ -20 +21 @@
    -x
    +y
    \\ No newline at end of file
    diff --git a/old.txt b/new.txt
    similarity index 100%
    rename from old.txt
    rename to new.txt
    diff --git a/img.png b/img.png
    index 111..222 100644
    Binary files a/img.png and b/img.png differ

    """
    let files = parseUnifiedDiff(text)
    #expect(files.map(\.path) == ["src/a b.txt", "new.txt", "img.png"])
    #expect(files[0].added == 3 && files[0].removed == 2)
    #expect(files[0].lines.map(\.kind) == [.hunk, .context, .removed, .added, .added, .context, .hunk, .removed, .added])
    #expect(files[0].lines[1...5].map { [$0.old, $0.new] } == [[3, 3], [4, nil], [nil, 4], [nil, 5], [5, 6]])
    #expect(files[0].lines[7].old == 20 && files[0].lines[8].new == 21)
    #expect(files[0].lines[2].text == "gone")
    #expect(files[1].lines.isEmpty && !files[1].binary)
    #expect(files[2].binary && files[2].lines.isEmpty)
}

@Test func gitRunsOnlyReadOnlySubcommands() {
    #expect(Set(GitRead.allCases.map(\.rawValue)) == ["diff", "diff-index", "ls-files", "merge-base", "rev-parse", "symbolic-ref", "for-each-ref"])
}

// MARK: - T9a regressions

private func mtime(_ path: String) throws -> Date {
    try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as! Date
}

@Test func collectingNeverRewritesTheIndex() throws {
    let dir = try fixture()
    Thread.sleep(forTimeInterval: 1.1)
    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: "\(dir)/a.txt")
    let index = "\(dir)/.git/index"
    let (before, bytes) = (try mtime(index), try Data(contentsOf: URL(fileURLWithPath: index)))
    let d = try result(dir)
    #expect(try mtime(index) == before)
    #expect(try Data(contentsOf: URL(fileURLWithPath: index)) == bytes)
    #expect(d.uncommitted.files.isEmpty)
}

@Test func quotedPathsAreFilesOfTheirOwn() throws {
    let dir = try fixture()
    try sh(dir, ["switch", "-q", "-c", "work"])
    for f in ["q\"uote.txt", "back\\slash.txt", "한글.txt"] { try write(dir, f, "one\n") }
    try sh(dir, ["add", "-A"])
    try sh(dir, ["commit", "-q", "-m", "three"])
    let numstat = try sh(dir, ["diff", "--numstat", "main...HEAD"]).split(separator: "\n")
    let added = numstat.reduce(0) { $0 + (Int($1.split(separator: "\t")[0]) ?? 0) }
    let removed = numstat.reduce(0) { $0 + (Int($1.split(separator: "\t")[1]) ?? 0) }
    let c = try #require(try result(dir).committed)
    #expect(c.files.count == numstat.count)
    #expect(c.added == added)
    #expect(c.removed == removed)
    #expect(Set(c.files.map(\.path)) == ["q\"uote.txt", "back\\slash.txt", "한글.txt"])
}

@Test func aPinnedBaseIsTheRefThatWasPicked() throws {
    let gone = try fixture()
    try sh(gone, ["branch", "dev"])
    try sh(gone, ["update-ref", "refs/remotes/origin/dev", "dev"])
    try sh(gone, ["branch", "-D", "dev"])
    #expect(try result(gone, pinned: "dev").base == .pinnedMissing("dev"))

    let newer = try fixture()
    try sh(newer, ["switch", "-q", "-c", "feature"])
    try commit(newer, "a.txt", "changed\n")
    try sh(newer, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    try sh(newer, ["switch", "-q", "-c", "work"])
    try commit(newer, "w.txt", "w\n")
    #expect(baseRef(try result(newer)) == "origin/main")
    #expect(baseRef(try result(newer, pinned: "main")) == "main")
}

@Test func quotedPathsUnescapeCEscapesAndOctalBytes() {
    #expect(unquotePath(#""b/q\"uote.txt""#) == "b/q\"uote.txt")
    #expect(unquotePath(#""b/back\\slash\ttab""#) == "b/back\\slash\ttab")
    #expect(unquotePath(#""b/\355\225\234.txt""#) == "b/한.txt")
    #expect(unquotePath("b/plain.txt") == "b/plain.txt")
}

@Test func aFileAfterALargeOneStillHasItsLines() throws {
    let dir = try fixture()
    try sh(dir, ["switch", "-q", "-c", "feature"])
    try commit(dir, "big.txt", (1...3000).map { "line \($0)\n" }.joined())
    try commit(dir, "small.txt", "s\n")
    try write(dir, "a.txt", "1\n2\nTHREE\n4\n5\n")

    let d = try result(dir)
    let committed = Dictionary(uniqueKeysWithValues: (d.committed?.files ?? []).map { ($0.path, $0) })
    #expect(committed["small.txt"]?.lines.map(\.text) == ["@@ -0,0 +1 @@", "s"])
    #expect(d.uncommitted.files.first?.lines.contains { $0.kind == .added && $0.text == "THREE" } == true)
}

// MARK: - Untracked files (T37)

@Test func untrackedFilesAreReadAsAllAddedDiffs() throws {
    let dir = try fixture()
    try FileManager.default.createDirectory(atPath: "\(dir)/src/com/example", withIntermediateDirectories: true)
    try write(dir, "src/com/example/A.kt", "package com.example\n\nclass A\n")
    try write(dir, "tail.txt", "x\ny")
    try write(dir, "empty.txt", "")
    try write(dir, "long.txt", "1\n2\n3\n4\n5\n")
    try Data([0x50, 0x4e, 0x47, 0x00, 0x01]).write(to: URL(fileURLWithPath: "\(dir)/img.bin"))
    try FileManager.default.createSymbolicLink(atPath: "\(dir)/link.txt", withDestinationPath: "tail.txt")
    let status = try sh(dir, ["status", "--porcelain"])  // porcelain status may refresh the index, so first
    let index = "\(dir)/.git/index"
    let stamp = try FileManager.default.attributesOfItem(atPath: index)[.modificationDate] as? Date

    let d = try result(dir, limit: 4)
    let byPath = Dictionary(uniqueKeysWithValues: d.uncommitted.newFiles.map { ($0.path, $0) })
    #expect(d.uncommitted.untracked.sorted() == ["empty.txt", "img.bin", "link.txt", "long.txt", "src/com/example/A.kt", "tail.txt"])
    #expect(byPath["link.txt"] == nil)  // a symlink stays a path
    let a = try #require(byPath["src/com/example/A.kt"])
    #expect(a.lines.map(\.kind) == [.hunk, .added, .added, .added])
    #expect(a.lines.first?.text == "@@ -0,0 +1,3 @@")
    #expect(a.lines.dropFirst().map(\.new) == [1, 2, 3])
    #expect(a.lines.dropFirst().map(\.text) == ["package com.example", "", "class A"])
    #expect(a.added == 3 && a.removed == 0 && !a.binary && a.hiddenLines == 0)
    #expect(a.split.count == 4)
    #expect(byPath["tail.txt"]?.lines.dropFirst().map(\.text) == ["x", "y"])
    #expect(byPath["empty.txt"] == FileDiff(path: "empty.txt", added: 0, removed: 0, binary: false, lines: []))
    #expect(byPath["img.bin"]?.binary == true && byPath["img.bin"]?.lines == [])
    let long = try #require(byPath["long.txt"])
    #expect(long.added == 5 && long.lines.count == 4 && long.hiddenLines == 2)
    #expect(d.uncommitted.added == 3 + 2 + 5)
    #expect(d.uncommitted.files.isEmpty)  // tower-cli's uncommitted_files stays tracked files only

    #expect(try FileManager.default.attributesOfItem(atPath: index)[.modificationDate] as? Date == stamp)
    #expect(try sh(dir, ["status", "--porcelain"]) == status)
}

@Test func onlyTheFirstUntrackedFilesAreRead() throws {
    let dir = try fixture()
    for i in 0..<(newFileLimit + 5) { try write(dir, String(format: "n%04d.txt", i), "\(i)\n") }
    try write(dir, "big.txt", String(repeating: "a", count: newFileByteLimit + 1))
    let d = try result(dir)
    #expect(d.uncommitted.untracked.count == newFileLimit + 6)
    // only the first paths are looked at: the oversized one takes a slot and stays a path
    #expect(d.uncommitted.newFiles.map(\.path) == d.uncommitted.untracked.prefix(newFileLimit).filter { $0 != "big.txt" })
}

@Test func crlfUntrackedFilesSplitLikeTrackedOnes() throws {
    let dir = try fixture()
    try write(dir, "crlf.txt", "a\r\nb\r\nc\r\n")
    try write(dir, "tail.txt", "a\r\nb")
    let d = try result(dir)
    let byPath = Dictionary(uniqueKeysWithValues: d.uncommitted.newFiles.map { ($0.path, $0) })
    #expect(byPath["crlf.txt"]?.added == 3)
    #expect(byPath["crlf.txt"]?.lines.dropFirst().map(\.text) == ["a\r", "b\r", "c\r"])  // as the tracked parser keeps them
    #expect(byPath["tail.txt"]?.lines.dropFirst().map(\.text) == ["a\r", "b"])
}

@Test func aRewrittenUntrackedFileIsReadAgain() throws {
    let dir = try fixture()
    try write(dir, "n.txt", "one\n")
    #expect(try result(dir).uncommitted.newFiles.first?.lines.last?.text == "one")
    try write(dir, "n.txt", "one\ntwo\n")
    #expect(try result(dir).uncommitted.newFiles.first?.lines.last?.text == "two")
}
