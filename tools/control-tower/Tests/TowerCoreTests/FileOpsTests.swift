import Foundation
import Testing
@testable import TowerCore

// Creating, renaming and trashing from the tree (G4 I9): only inside the worktree, links followed, never over
// something that is there. The trash here is a folder of the test's: nothing goes to the user's trash.

private struct Tree {
    let root: String
    let outside: String
    let trashed: String

    init() {
        let base = FileManager.default.temporaryDirectory.appending(path: "ct-fileops-\(UUID().uuidString)").path
        for d in ["root/src", "outside", "trashed"] { try! FileManager.default.createDirectory(atPath: base + "/" + d, withIntermediateDirectories: true) }
        let real = realPath(base)!
        (root, outside, trashed) = (real + "/root", real + "/outside", real + "/trashed")
    }

    func writer() -> WorkingFileWriter {
        let to = trashed
        return WorkingFileWriter(toTrash: { try FileManager.default.moveItem(atPath: $0.path, toPath: to + "/" + $0.lastPathComponent) })
    }

    func put(_ text: String, _ path: String) { try! Data(text.utf8).write(to: URL(fileURLWithPath: path)) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func remove() { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: root).deletingLastPathComponent().path) }
}

@Test func aFileAndAFolderAreMadeInsideTheWorktree() async {
    let t = Tree(); defer { t.remove() }
    let w = t.writer()
    #expect(await w.createFile(t.root + "/src/new.swift", roots: [t.root]) == .done(path: t.root + "/src/new.swift"))
    #expect((try? Data(contentsOf: URL(fileURLWithPath: t.root + "/src/new.swift"))) == Data())
    #expect(await w.createFolder(t.root + "/docs", roots: [t.root]) == .done(path: t.root + "/docs"))
    var isFolder: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: t.root + "/docs", isDirectory: &isFolder) && isFolder.boolValue)
    #expect(await w.isSelfWrite(t.root + "/src/new.swift"))
    // its folder must be there: the writer makes one thing at a time
    #expect(await w.createFile(t.root + "/no/such/x.swift", roots: [t.root]) == .refused(.missing))
}

@Test func nothingIsMadeOverSomethingThatIsThere() async {
    let t = Tree(); defer { t.remove() }
    let w = t.writer()
    t.put("keep\n", t.root + "/src/a.swift")
    #expect(await w.createFile(t.root + "/src/a.swift", roots: [t.root]) == .refused(.exists))
    #expect(await w.createFolder(t.root + "/src/a.swift", roots: [t.root]) == .refused(.exists))
    #expect(await w.createFile(t.root + "/src", roots: [t.root]) == .refused(.exists))
    #expect((try? String(contentsOfFile: t.root + "/src/a.swift", encoding: .utf8)) == "keep\n")
    // a link that leads nowhere is something too: a new file there would be written through it
    try! FileManager.default.createSymbolicLink(atPath: t.root + "/src/dangling", withDestinationPath: t.outside + "/made-through-link")
    #expect(await w.createFile(t.root + "/src/dangling", roots: [t.root]) == .refused(.exists))
    #expect(!t.exists(t.outside + "/made-through-link"))
}

@Test func aPathOutsideTheWorktreeIsRefusedForEveryOperation() async {
    let t = Tree(); defer { t.remove() }
    let w = t.writer()
    t.put("theirs\n", t.outside + "/secret.txt")
    try! FileManager.default.createSymbolicLink(atPath: t.root + "/src/out", withDestinationPath: t.outside)
    // outright, by `..`, and through a linked folder
    for path in [t.outside + "/x.txt", t.root + "/../outside/x.txt", t.root + "/src/out/x.txt"] {
        #expect(await w.createFile(path, roots: [t.root]) == .refused(.outside), "\(path)")
        #expect(await w.createFolder(path, roots: [t.root]) == .refused(.outside), "\(path)")
    }
    for path in [t.outside + "/secret.txt", t.root + "/../outside/secret.txt", t.root + "/src/out/secret.txt"] {
        #expect(await w.rename(path, to: "mine.txt", roots: [t.root]) == .refused(.outside), "\(path)")
        #expect(await w.trash(path, roots: [t.root]) == .refused(.outside), "\(path)")
    }
    // the worktree itself is not inside itself
    #expect(await w.trash(t.root, roots: [t.root]) == .refused(.outside))
    #expect(await w.rename(t.root, to: "gone", roots: [t.root]) == .refused(.outside))
    #expect((try? FileManager.default.contentsOfDirectory(atPath: t.outside)) == ["secret.txt"])
    #expect(try! FileManager.default.contentsOfDirectory(atPath: t.trashed).isEmpty)
    #expect(await w.createFile("src/x.txt", roots: [t.root]) == .refused(.notAbsolute))
}

@Test func aNameIsOneComponent() async {
    let t = Tree(); defer { t.remove() }
    let w = t.writer()
    t.put("a\n", t.root + "/src/a.swift")
    for name in ["", ".", "..", "sub/b.swift", "../../outside/b.swift"] {
        #expect(await w.rename(t.root + "/src/a.swift", to: name, roots: [t.root]) == .refused(.badName), "\(name)")
    }
    #expect(await w.createFile(t.root + "/src/", roots: [t.root]) == .refused(.badName))
    #expect(await w.createFile(t.root + "/src/..", roots: [t.root]) == .refused(.badName))
    #expect(t.exists(t.root + "/src/a.swift"))
}

@Test func aRenameMovesTheFileAndNeverOverAnother() async {
    let t = Tree(); defer { t.remove() }
    let w = t.writer()
    t.put("a\n", t.root + "/src/a.swift")
    t.put("b\n", t.root + "/src/b.swift")
    #expect(await w.rename(t.root + "/src/a.swift", to: "b.swift", roots: [t.root]) == .refused(.exists))
    #expect((try? String(contentsOfFile: t.root + "/src/b.swift", encoding: .utf8)) == "b\n")
    #expect(await w.rename(t.root + "/src/a.swift", to: "c.swift", roots: [t.root]) == .done(path: t.root + "/src/c.swift"))
    #expect(!t.exists(t.root + "/src/a.swift") && (try? String(contentsOfFile: t.root + "/src/c.swift", encoding: .utf8)) == "a\n")
    #expect(await w.isSelfWrite(t.root + "/src/a.swift"))
    #expect(await w.isSelfWrite(t.root + "/src/c.swift"))
    #expect(await w.rename(t.root + "/src/a.swift", to: "d.swift", roots: [t.root]) == .refused(.missing))
    // a folder, with what is in it
    #expect(await w.rename(t.root + "/src", to: "lib", roots: [t.root]) == .done(path: t.root + "/lib"))
    #expect(t.exists(t.root + "/lib/c.swift"))
}

/// A link inside the worktree is renamed and trashed itself; what it points at outside stays as it was.
@Test func aLinkIsRenamedAndTrashedItself() async {
    let t = Tree(); defer { t.remove() }
    let w = t.writer()
    t.put("theirs\n", t.outside + "/secret.txt")
    try! FileManager.default.createSymbolicLink(atPath: t.root + "/src/link.txt", withDestinationPath: t.outside + "/secret.txt")
    #expect(await w.rename(t.root + "/src/link.txt", to: "link2.txt", roots: [t.root]) == .done(path: t.root + "/src/link2.txt"))
    #expect(await w.trash(t.root + "/src/link2.txt", roots: [t.root]) == .done(path: t.root + "/src/link2.txt"))
    #expect((try? String(contentsOfFile: t.outside + "/secret.txt", encoding: .utf8)) == "theirs\n")
    #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: t.trashed + "/link2.txt")) == t.outside + "/secret.txt")
}

@Test func aTrashedFileGoesToTheTrashAndNothingElseDoes() async {
    let t = Tree(); defer { t.remove() }
    let w = t.writer()
    t.put("a\n", t.root + "/src/a.swift")
    t.put("b\n", t.root + "/src/b.swift")
    #expect(await w.trash(t.root + "/src/a.swift", roots: [t.root]) == .done(path: t.root + "/src/a.swift"))
    #expect(!t.exists(t.root + "/src/a.swift") && t.exists(t.root + "/src/b.swift"))
    #expect((try? String(contentsOfFile: t.trashed + "/a.swift", encoding: .utf8)) == "a\n", "moved, not deleted")
    #expect(await w.trash(t.root + "/src/a.swift", roots: [t.root]) == .refused(.missing))
}

// MARK: - Through the editor's files: locked until the user unlocks, and open files follow a rename

@Test func fileOperationsAreRefusedUntilTheyAreUnlocked() async {
    let t = Tree(); defer { t.remove() }
    let files = EditorFiles(roots: [t.root], writer: t.writer())
    t.put("a\n", t.root + "/src/a.swift")
    #expect(await files.createFile(t.root + "/src/x.swift") == .refused(.locked))
    #expect(await files.createFolder(t.root + "/docs") == .refused(.locked))
    #expect(await files.rename(t.root + "/src/a.swift", to: "b.swift") == .refused(.locked))
    #expect(await files.trash(t.root + "/src/a.swift") == .refused(.locked))
    #expect(try! FileManager.default.contentsOfDirectory(atPath: t.root + "/src") == ["a.swift"])
    await files.setFileOpsLocked(false)
    #expect(await files.createFile(t.root + "/src/x.swift") == .done(path: t.root + "/src/x.swift"))
    await files.setFileOpsLocked(true)
    #expect(await files.trash(t.root + "/src/x.swift") == .refused(.locked))
}

@Test func aNewFileMakesTheFoldersOnItsWayInsideTheWorktreeOnly() async {
    let t = Tree(); defer { t.remove() }
    let files = EditorFiles(roots: [t.root], writer: t.writer())
    await files.setFileOpsLocked(false)
    #expect(await files.createFile(t.root + "/a/b/c.swift") == .done(path: t.root + "/a/b/c.swift"))
    #expect(await files.createFolder(t.root + "/a/x/y") == .done(path: t.root + "/a/x/y"))
    #expect(await files.createFile(t.root + "/a/../../outside/c.swift") == .refused(.outside))
    #expect(await files.createFile(t.root + "/new/../../outside/c.swift") == .refused(.badName), "`..` under a folder that is not there yet")
    #expect(!t.exists(t.root + "/new") && (try? FileManager.default.contentsOfDirectory(atPath: t.outside)) == [])
}

@Test func anOpenFileIsSavedUnderItsNewNameAfterARename() async {
    let t = Tree(); defer { t.remove() }
    let files = EditorFiles(roots: [t.root], writer: t.writer())
    await files.setFileOpsLocked(false)
    let a = t.root + "/src/a.swift", b = t.root + "/src/b.swift"
    t.put("one\n", a)
    guard case .file(_, let hash) = await files.handle(.readFile(path: a)) else { return #expect(Bool(false), "not read") }
    _ = await files.setReadOnly(a, false)
    #expect(await files.rename(a, to: "b.swift") == .done(path: b))
    // the page's buffer, told its new path, saves there: still open, still unlocked
    guard case .written = await files.handle(.writeFile(path: b, text: "two\n", baseHash: hash)) else { return #expect(Bool(false), "not written") }
    #expect((try? String(contentsOfFile: b, encoding: .utf8)) == "two\n")
    // the old path is no file of this editor any more
    #expect(await files.handle(.writeFile(path: a, text: "x\n", baseHash: hash)) == .refused(.missing))
    #expect(!t.exists(a))
    // a renamed folder takes its open files along
    #expect(await files.rename(t.root + "/src", to: "lib") == .done(path: t.root + "/lib"))
    guard case .written = await files.handle(.writeFile(path: t.root + "/lib/b.swift", text: "three\n", baseHash: sha256(Data("two\n".utf8)))) else {
        return #expect(Bool(false), "not written after the folder moved")
    }
}
