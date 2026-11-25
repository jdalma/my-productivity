import Foundation
import Testing
@testable import TowerCore

// The editor page's bridge (G4 I4, plan §1.4): what the page may ask, what Swift answers and tells it. The page is
// outside the trust boundary: every path it sends is judged again here.

private func tempTree() -> String {
    let dir = FileManager.default.temporaryDirectory.appending(path: "ct-bridge-\(UUID().uuidString)").path
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return realPath(dir)!
}

private func put(_ text: String, _ path: String) { try! Data(text.utf8).write(to: URL(fileURLWithPath: path)) }
private func text(_ path: String) -> String { try! String(contentsOfFile: path, encoding: .utf8) }

private func request(_ json: String) throws -> EditorRequest { try JSONDecoder().decode(EditorRequest.self, from: Data(json.utf8)) }
private func json(_ value: some Encodable) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
}

/// Opens `path` the way the page does, and returns the hash it read.
private func read(_ files: EditorFiles, _ path: String) async -> String? {
    if case .file(_, let hash) = await files.handle(.readFile(path: path)) { hash } else { nil }
}

// MARK: - Messages

@Test func thePagesMessagesDecode() throws {
    #expect(try request(#"{"kind":"readFile","path":"/w/a.swift"}"#) == .readFile(path: "/w/a.swift"))
    #expect(try request(#"{"kind":"writeFile","path":"/w/a.swift","text":"x","baseHash":"ab"}"#)
            == .writeFile(path: "/w/a.swift", text: "x", baseHash: "ab"))
    #expect(try request(#"{"kind":"dirtyChanged","path":"/w/a.swift","dirty":true}"#) == .dirtyChanged(path: "/w/a.swift", dirty: true))
    #expect(try request(#"{"kind":"cursor","path":"/w/a.swift","line":3,"col":7}"#) == .cursor(path: "/w/a.swift", line: 3, col: 7))
    #expect(try request(#"{"kind":"ready"}"#) == .ready)
    #expect(try request(#"{"kind":"log","message":"worker failed"}"#) == .log(message: "worker failed"))
    #expect(throws: DecodingError.self) { try request(#"{"kind":"runCommand","cmd":"rm"}"#) }
    #expect(throws: DecodingError.self) { try request(#"{"kind":"writeFile","path":"/w/a.swift"}"#) }
}

@Test func swiftsAnswersEncode() throws {
    #expect(NSDictionary(dictionary: try json(EditorReply.file(text: "a", hash: "h"))) == ["result": "ok", "text": "a", "hash": "h"])
    #expect(NSDictionary(dictionary: try json(EditorReply.written(hash: "h"))) == ["result": "ok", "hash": "h"])
    #expect(NSDictionary(dictionary: try json(EditorReply.conflict(diskHash: "d"))) == ["result": "conflict", "diskHash": "d"])
    #expect(NSDictionary(dictionary: try json(EditorReply.refused(.outside))) == ["result": "refused", "reason": "outside"])
    #expect(NSDictionary(dictionary: try json(EditorReply.ok)) == ["result": "ok"])
}

@Test func swiftsCommandsEncode() throws {
    #expect(NSDictionary(dictionary: try json(EditorCommand.openFile(path: "/w/a", text: "t", hash: "h", line: 4, readOnly: true)))
            == ["kind": "openFile", "path": "/w/a", "text": "t", "hash": "h", "line": 4, "readOnly": true])
    #expect(NSDictionary(dictionary: try json(EditorCommand.openFile(path: "/w/a", text: "t", hash: "h", line: nil, readOnly: false)))
            == ["kind": "openFile", "path": "/w/a", "text": "t", "hash": "h", "readOnly": false])
    #expect(NSDictionary(dictionary: try json(EditorCommand.fileChangedOnDisk(path: "/w/a", text: "n", hash: "h2")))
            == ["kind": "fileChangedOnDisk", "path": "/w/a", "text": "n", "hash": "h2"])
    #expect(NSDictionary(dictionary: try json(EditorCommand.fileDeleted(path: "/w/a"))) == ["kind": "fileDeleted", "path": "/w/a"])
    #expect(NSDictionary(dictionary: try json(EditorCommand.setTheme(dark: true))) == ["kind": "setTheme", "dark": true])
    #expect(NSDictionary(dictionary: try json(EditorCommand.setFontSize(14.3))) == ["kind": "setFontSize", "size": 14.3])
    #expect(NSDictionary(dictionary: try json(EditorCommand.setReadOnly(path: "/w/a", readOnly: false)))
            == ["kind": "setReadOnly", "path": "/w/a", "readOnly": false])
    #expect(NSDictionary(dictionary: try json(EditorCommand.save)) == ["kind": "save"])
}

// MARK: - Reads and writes the page asks for

@Test func aReadOutsideTheRootsIsRefused() async {
    let root = tempTree(), outside = tempTree()
    put("secret", outside + "/s.txt")
    try! FileManager.default.createSymbolicLink(atPath: root + "/link.txt", withDestinationPath: outside + "/s.txt")
    let files = EditorFiles(roots: [root])
    #expect(await files.handle(.readFile(path: outside + "/s.txt")) == .refused(.outside))
    #expect(await files.handle(.readFile(path: root + "/../" + outside.split(separator: "/").last! + "/s.txt")) == .refused(.outside))
    #expect(await files.handle(.readFile(path: root + "/link.txt")) == .refused(.outside))  // a link leading out
    #expect(await files.handle(.readFile(path: "s.txt")) == .refused(.notAbsolute))
    #expect(await files.handle(.readFile(path: root + "/none.txt")) == .refused(.missing))
}

@Test func aReadInsideGivesTheTextAndItsHash() async {
    let root = tempTree()
    put("let a = 1\n", root + "/a.swift")
    let files = EditorFiles(roots: [root])
    guard case .file(let t, let hash) = await files.handle(.readFile(path: root + "/a.swift")) else { Issue.record("no file"); return }
    #expect(t == "let a = 1\n")
    #expect(hash.count == 64)
    try! Data([0x61, 0x00]).write(to: URL(fileURLWithPath: root + "/b.bin"))
    #expect(await files.handle(.readFile(path: root + "/b.bin")) == .refused(.binary))
}

@Test func aWriteOutsideTheRootsIsRefusedAndTheFileKept() async {
    let root = tempTree(), outside = tempTree()
    put("secret", outside + "/s.txt")
    let files = EditorFiles(roots: [root])
    #expect(await files.handle(.writeFile(path: outside + "/s.txt", text: "x", baseHash: "")) == .refused(.outside))
    #expect(text(outside + "/s.txt") == "secret")
}

@Test func aFileIsReadOnlyUntilSwiftUnlocksIt() async {
    let root = tempTree()
    put("one\n", root + "/a.txt")
    let files = EditorFiles(roots: [root])
    // never read by this editor: the page cannot write a file it was not given
    #expect(await files.handle(.writeFile(path: root + "/a.txt", text: "two\n", baseHash: "")) == .refused(.notOpen))
    let hash = await read(files, root + "/a.txt")!
    #expect(await files.handle(.writeFile(path: root + "/a.txt", text: "two\n", baseHash: hash)) == .refused(.readOnly))
    #expect(text(root + "/a.txt") == "one\n")
    #expect(await files.setReadOnly(root + "/a.txt", false) == .setReadOnly(path: root + "/a.txt", readOnly: false))
    guard case .written(let after) = await files.handle(.writeFile(path: root + "/a.txt", text: "two\n", baseHash: hash)) else {
        Issue.record("not written"); return
    }
    #expect(text(root + "/a.txt") == "two\n")
    #expect(after != hash)
    _ = await files.setReadOnly(root + "/a.txt", true)
    #expect(await files.handle(.writeFile(path: root + "/a.txt", text: "three\n", baseHash: after)) == .refused(.readOnly))
}

@Test func aWriteFromAnOldReadIsAConflict() async {
    let root = tempTree()
    put("one\n", root + "/a.txt")
    let files = EditorFiles(roots: [root])
    let hash = await read(files, root + "/a.txt")!
    _ = await files.setReadOnly(root + "/a.txt", false)
    put("worker\n", root + "/a.txt")  // a worker's edit after the read
    guard case .conflict = await files.handle(.writeFile(path: root + "/a.txt", text: "mine\n", baseHash: hash)) else {
        Issue.record("not a conflict"); return
    }
    #expect(text(root + "/a.txt") == "worker\n")
}

@Test func swiftOpensAFileReadOnlyByDefault() async {
    let root = tempTree(), outside = tempTree()
    put("x\n", root + "/a.txt")
    put("x\n", outside + "/b.txt")
    let files = EditorFiles(roots: [root])
    guard case .openFile(let path, let t, _, let line, let readOnly) = await files.open(root + "/a.txt", line: 2) else {
        Issue.record("not opened"); return
    }
    #expect((path, t, line, readOnly) == (root + "/a.txt", "x\n", 2, true))  // D#5 b
    #expect(await files.open(outside + "/b.txt", line: nil) == nil)
}

/// R15 L1: a hard link inside a root to a file outside it passes the real-path check (a hard link has no target to
/// follow). The save still cannot write through it: the atomic write puts a new file at the link's name, and the
/// file outside keeps its bytes.
@Test func aSaveThroughAHardLinkLeavesTheFileOutsideAsItWas() async throws {
    let root = tempTree(), outside = tempTree()
    put("secret\n", outside + "/s.txt")
    try FileManager.default.linkItem(atPath: outside + "/s.txt", toPath: root + "/hard.txt")
    let files = EditorFiles(roots: [root])
    let hash = await read(files, root + "/hard.txt")!
    _ = await files.setReadOnly(root + "/hard.txt", false)
    guard case .written = await files.handle(.writeFile(path: root + "/hard.txt", text: "edited\n", baseHash: hash)) else {
        Issue.record("not written"); return
    }
    #expect(text(outside + "/s.txt") == "secret\n")
    #expect(text(root + "/hard.txt") == "edited\n")
    let links = try FileManager.default.attributesOfItem(atPath: outside + "/s.txt")[.referenceCount] as? Int
    #expect(links == 1)
}

// MARK: - The page's files (ctedit://app/<path>)

@Test func thePageServesOnlyFilesInsideItsFolder() throws {
    let page = tempTree(), outside = tempTree()
    try FileManager.default.createDirectory(atPath: page + "/assets", withIntermediateDirectories: true)
    put("<html>", page + "/index.html")
    put("x", page + "/assets/a.js")
    put("secret", outside + "/s.txt")
    try FileManager.default.createSymbolicLink(atPath: page + "/assets/out.txt", withDestinationPath: outside + "/s.txt")
    #expect(editorPageFile(folder: page, urlPath: "") == page + "/index.html")
    #expect(editorPageFile(folder: page, urlPath: "/") == page + "/index.html")
    #expect(editorPageFile(folder: page, urlPath: "/assets/a.js") == page + "/assets/a.js")
    #expect(editorPageFile(folder: page, urlPath: "/../" + outside.split(separator: "/").last! + "/s.txt") == nil)
    #expect(editorPageFile(folder: page, urlPath: "/assets/out.txt") == nil)
    #expect(editorPageFile(folder: page, urlPath: "/assets") == nil)  // a folder
    #expect(editorPageFile(folder: page, urlPath: "/none.js") == nil)
    #expect(editorContentType("wasm") == "application/wasm")
    #expect(editorContentType("js") == "text/javascript")
    #expect(editorContentType("bin") == "application/octet-stream")
}

// MARK: - The disk under an open file (FileWatch → page)

@Test func aWatchBatchTellsThePageOnlyOfTheFilesItHasOpen() async {
    let root = tempTree()
    put("a", root + "/open.swift")
    put("b", root + "/other.swift")
    put("c", root + "/gone.swift")
    let files = EditorFiles(roots: [root])
    _ = await read(files, root + "/open.swift")
    _ = await read(files, root + "/gone.swift")
    put("a2", root + "/open.swift")
    try? FileManager.default.removeItem(atPath: root + "/gone.swift")

    let commands = await files.diskChanged(FileWatchBatch(changed: ["open.swift", "other.swift"], deleted: ["gone.swift"]), root: root)
    #expect(commands == [.fileDeleted(path: root + "/gone.swift"),
                         .fileChangedOnDisk(path: root + "/open.swift", text: "a2", hash: sha256(Data("a2".utf8)))])
}

@Test func aRescanLooksAgainAtEveryOpenFile() async {
    let root = tempTree()
    put("a", root + "/a.swift")
    put("b", root + "/b.swift")
    let files = EditorFiles(roots: [root])
    _ = await read(files, root + "/a.swift")
    _ = await read(files, root + "/b.swift")
    put("b2", root + "/b.swift")
    try? FileManager.default.removeItem(atPath: root + "/a.swift")

    let commands = await files.diskChanged(FileWatchBatch(rescan: true), root: root)
    #expect(commands == [.fileDeleted(path: root + "/a.swift"),
                         .fileChangedOnDisk(path: root + "/b.swift", text: "b2", hash: sha256(Data("b2".utf8)))])
}

// MARK: - Buffers (G4 I7)

@Test func theBannersCommandsEncode() throws {
    #expect(NSDictionary(dictionary: try json(EditorCommand.reloadFile(path: "/w/a", text: "n", hash: "h2")))
            == ["kind": "reloadFile", "path": "/w/a", "text": "n", "hash": "h2"])
    #expect(NSDictionary(dictionary: try json(EditorCommand.overwrite(path: "/w/a", diskHash: "h2")))
            == ["kind": "overwrite", "path": "/w/a", "diskHash": "h2"])
    #expect(NSDictionary(dictionary: try json(EditorCommand.getText(path: "/w/a"))) == ["kind": "getText", "path": "/w/a"])
}

@Test func anOpenFileIsReadAgainFromTheDiskForAReload() async {
    let dir = tempTree()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let a = dir + "/a.txt"
    put("one\n", a)
    let files = EditorFiles(roots: [dir])
    #expect(await files.reload(a) == nil, "not a file this editor read")
    let first = await read(files, a)
    put("two\n", a)
    guard case .reloadFile(a, "two\n", let hash)? = await files.reload(a) else { return #expect(Bool(false), "no reload") }
    #expect(hash != first)
    #expect(await files.changed(a) == .fileChangedOnDisk(path: a, text: "two\n", hash: hash))
    try? FileManager.default.removeItem(atPath: a)
    #expect(await files.reload(a) == nil)
    #expect(await files.changed(a) == .fileDeleted(path: a))
}

/// The banner's 덮어쓰기 as the page does it: a save whose base is the disk hash the banner was for. It writes over
/// those bytes, and over no others.
@Test func anOverwriteWritesOverTheBytesTheBannerWasForAndNoOthers() async {
    let dir = tempTree()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let a = dir + "/a.txt"
    put("base\n", a)
    let files = EditorFiles(roots: [dir])
    let base = await read(files, a)!
    _ = await files.setReadOnly(a, false)
    // a worker writes; the user's save from the old read is a conflict that names the disk's bytes
    put("worker\n", a)
    guard case .conflict(let disk) = await files.handle(.writeFile(path: a, text: "mine\n", baseHash: base)) else { return #expect(Bool(false), "no conflict") }
    #expect(text(a) == "worker\n")
    // the worker writes once more before the user picks 덮어쓰기: still nothing written
    put("worker again\n", a)
    guard case .conflict = await files.handle(.writeFile(path: a, text: "mine\n", baseHash: disk)) else { return #expect(Bool(false), "written over newer bytes") }
    #expect(text(a) == "worker again\n")
    put("worker\n", a)
    guard case .written = await files.handle(.writeFile(path: a, text: "mine\n", baseHash: disk)) else { return #expect(Bool(false), "not written") }
    #expect(text(a) == "mine\n")
}

@Test func aBufferIsComparedWithTheDiskWithoutWritingAnything() throws {
    let dir = tempTree()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let a = dir + "/a.txt"
    put("one\ntwo\nthree\n", a)
    let d = try #require(bufferDiff(path: a, text: "one\nTWO\nthree\nfour\n"))
    #expect(d.path == "a.txt" && d.added == 2 && d.removed == 1)
    #expect(d.lines.filter { $0.kind == .removed }.map(\.text) == ["two"])
    #expect(d.lines.filter { $0.kind == .added }.map(\.text) == ["TWO", "four"])
    #expect(text(a) == "one\ntwo\nthree\n")
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["a.txt"])
    // the same text: no lines
    #expect(try #require(bufferDiff(path: a, text: "one\ntwo\nthree\n")).lines.isEmpty)
}

/// W3 (T35): a write the editor saved is the app's own, not a worker's.
@Test func theEditorTellsItsOwnSavesFromOtherWrites() async {
    let root = tempTree()
    put("one\n", root + "/a.txt")
    put("x\n", root + "/b.txt")
    let files = EditorFiles(roots: [root])
    let hash = await read(files, root + "/a.txt")!
    _ = await files.setReadOnly(root + "/a.txt", false)
    _ = await files.handle(.writeFile(path: root + "/a.txt", text: "two\n", baseHash: hash))
    put("y\n", root + "/b.txt")  // a worker's write
    #expect(await files.ownWrites([root + "/a.txt", root + "/b.txt"]) == [root + "/a.txt"])
}
