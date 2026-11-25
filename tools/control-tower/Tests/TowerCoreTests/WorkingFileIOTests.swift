import CryptoKit
import Foundation
import Testing
@testable import TowerCore

private func tempTree() -> String {
    let dir = FileManager.default.temporaryDirectory.appending(path: "ct-fileio-\(UUID().uuidString)").path
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return realPath(dir)!
}

private func put(_ bytes: [UInt8], _ path: String) { try! Data(bytes).write(to: URL(fileURLWithPath: path)) }
private func put(_ text: String, _ path: String) { put(Array(text.utf8), path) }
private func bytes(_ path: String) -> [UInt8] { Array(try! Data(contentsOf: URL(fileURLWithPath: path))) }
private func sha(_ b: [UInt8]) -> String { SHA256.hash(data: Data(b)).map { String(format: "%02x", $0) }.joined() }

// MARK: - Full read

@Test func aFullReadKeepsEveryLineAndHashesTheBytesOnDisk() throws {
    let root = tempTree()
    let text = (1...5000).map { "line \($0)" }.joined(separator: "\r\n") + "\n"
    put(text, root + "/big.txt")
    guard case .text(let f) = readFullFile(toplevel: root, path: "big.txt") else { Issue.record("not text"); return }
    #expect(f.text == text)  // past readWorkingFile's 2000-line window, CRLF kept as written
    #expect(f.encoding == .utf8)
    #expect(f.hash == sha(Array(text.utf8)))
}

@Test func aFullReadTellsMissingBinaryAndTooLarge() {
    let root = tempTree()
    #expect(readFullFile(toplevel: root, path: "none.txt") == .missing)
    try! FileManager.default.createDirectory(atPath: root + "/dir", withIntermediateDirectories: true)
    #expect(readFullFile(toplevel: root, path: "dir") == .missing)
    put([0x61, 0x00, 0x62], root + "/nul.bin")
    #expect(readFullFile(toplevel: root, path: "nul.bin") == .binary)
    put([0x61, 0xff, 0xfe, 0x62], root + "/latin.txt")  // not UTF-8, no BOM
    #expect(readFullFile(toplevel: root, path: "latin.txt") == .binary)
    put("0123456789", root + "/ten.txt")
    #expect(readFullFile(toplevel: root, path: "ten.txt", sizeLimit: 9) == .tooLarge(size: 10))
    if case .text = readFullFile(toplevel: root, path: "ten.txt", sizeLimit: 10) {} else { Issue.record("10 bytes fit a limit of 10") }
}

@Test func aFullReadKnowsTheEncodingByItsBOM() {
    let root = tempTree()
    put([0xef, 0xbb, 0xbf] + Array("é".utf8), root + "/bom8.txt")
    put([0xff, 0xfe, 0x41, 0x00, 0xe9, 0x00], root + "/le.txt")  // "Aé", NULs a UTF-16 file always has
    put([0xfe, 0xff, 0x00, 0x41, 0x00, 0xe9], root + "/be.txt")
    #expect(readFullFile(toplevel: root, path: "bom8.txt") == .text(FullFile(text: "é", encoding: .utf8BOM, hash: sha(bytes(root + "/bom8.txt")))))
    #expect(readFullFile(toplevel: root, path: "le.txt") == .text(FullFile(text: "Aé", encoding: .utf16LE, hash: sha(bytes(root + "/le.txt")))))
    #expect(readFullFile(toplevel: root, path: "be.txt") == .text(FullFile(text: "Aé", encoding: .utf16BE, hash: sha(bytes(root + "/be.txt")))))
}

// MARK: - Write path check

@Test func aWriteTargetIsAnExistingRegularFileWhoseRealPathIsInARoot() throws {
    let root = tempTree(), other = tempTree()
    let fm = FileManager.default
    try fm.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
    put("a", root + "/src/a.swift")
    put("secret", other + "/secret.txt")
    try fm.createSymbolicLink(atPath: root + "/src/escape.txt", withDestinationPath: other + "/secret.txt")
    try fm.createSymbolicLink(atPath: root + "/src/alias.swift", withDestinationPath: root + "/src/a.swift")
    try fm.createSymbolicLink(atPath: root + "/linkdir", withDestinationPath: other)

    #expect(writeTarget(root + "/src/a.swift", roots: [root]) == .file(root + "/src/a.swift"))
    #expect(writeTarget(root + "/src/../src/a.swift", roots: [root]) == .file(root + "/src/a.swift"))
    // a link inside the root that stays inside is written at its target
    #expect(writeTarget(root + "/src/alias.swift", roots: [root]) == .file(root + "/src/a.swift"))
    #expect(writeTarget(root + "/src/escape.txt", roots: [root]) == .refused(.outside))
    #expect(writeTarget(root + "/linkdir/secret.txt", roots: [root]) == .refused(.outside))
    #expect(writeTarget(root + "/../" + URL(fileURLWithPath: other).lastPathComponent + "/secret.txt", roots: [root]) == .refused(.outside))
    #expect(writeTarget(other + "/secret.txt", roots: [root, other]) == .file(other + "/secret.txt"))  // an allowed folder
    #expect(writeTarget(root + "/src/new.swift", roots: [root]) == .refused(.missing))
    #expect(writeTarget(root + "/src", roots: [root]) == .refused(.notRegularFile))
    #expect(writeTarget("src/a.swift", roots: [root]) == .refused(.notAbsolute))
    // a root that is itself a link: judged by its real path, so the same file passes
    try fm.createSymbolicLink(atPath: other + "/rootlink", withDestinationPath: root)
    #expect(writeTarget(root + "/src/a.swift", roots: [other + "/rootlink"]) == .file(root + "/src/a.swift"))
    // a sibling whose name starts with the root's is not inside it
    try fm.createDirectory(atPath: root + "-x", withIntermediateDirectories: true)
    put("x", root + "-x/f.txt")
    #expect(writeTarget(root + "-x/f.txt", roots: [root]) == .refused(.outside))
}

// MARK: - Compare-and-write

@Test func aWriteGoesThroughOnlyWhenTheDiskStillHoldsWhatWasRead() async throws {
    let root = tempTree()
    let path = root + "/f.txt"
    put("one\n", path)
    guard case .text(let read) = readFullFile(toplevel: root, path: "f.txt") else { Issue.record("not text"); return }
    let w = WorkingFileWriter()

    let saved = await w.write("two\n", encoding: .utf8, to: path, roots: [root], expected: read.hash)
    #expect(saved == .written(hash: sha(Array("two\n".utf8))))
    #expect(bytes(path) == Array("two\n".utf8))

    // the agent changes the file after the editor's read: the stale hash conflicts and nothing is written
    put("agent\n", path)
    let stale = await w.write("mine\n", encoding: .utf8, to: path, roots: [root], expected: read.hash)
    #expect(stale == .conflict(current: sha(Array("agent\n".utf8))))
    #expect(bytes(path) == Array("agent\n".utf8))
}

@Test func theSameContentIsNotWrittenAgain() async throws {
    let root = tempTree()
    let path = root + "/f.txt"
    put("same\n", path)
    let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as! Date
    let h = sha(Array("same\n".utf8))
    let w = WorkingFileWriter()
    #expect(await w.write("same\n", encoding: .utf8, to: path, roots: [root], expected: h) == .unchanged(hash: h))
    // the disk already holds what would be written: no conflict even from a stale read, and no write
    #expect(await w.write("same\n", encoding: .utf8, to: path, roots: [root], expected: "stale") == .unchanged(hash: h))
    #expect(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as! Date == before)
    #expect(await w.isSelfWrite(path) == false)
}

@Test func aWriteKeepsTheEncodingThePermissionsAndALinkInsideTheRoot() async throws {
    let root = tempTree()
    let fm = FileManager.default
    let path = root + "/run.sh"
    put([0xff, 0xfe, 0x41, 0x00], path)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    try fm.createSymbolicLink(atPath: root + "/alias.sh", withDestinationPath: path)
    let w = WorkingFileWriter()
    let r = await w.write("AB", encoding: .utf16LE, to: root + "/alias.sh", roots: [root], expected: sha([0xff, 0xfe, 0x41, 0x00]))
    #expect(r == .written(hash: sha([0xff, 0xfe, 0x41, 0x00, 0x42, 0x00])))
    #expect(bytes(path) == [0xff, 0xfe, 0x41, 0x00, 0x42, 0x00])
    #expect(try fm.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o755)
    #expect(try fm.destinationOfSymbolicLink(atPath: root + "/alias.sh") == path)  // still a link
    #expect(await w.write("x", encoding: .utf8BOM, to: path, roots: [root], expected: sha(bytes(path))) == .written(hash: sha([0xef, 0xbb, 0xbf, 0x78])))
}

@Test func aWriteIsRefusedOutsideTheRootsAndForAFileThatIsGone() async throws {
    let root = tempTree(), other = tempTree()
    put("secret", other + "/s.txt")
    try FileManager.default.createSymbolicLink(atPath: root + "/s.txt", withDestinationPath: other + "/s.txt")
    let w = WorkingFileWriter()
    #expect(await w.write("x", encoding: .utf8, to: root + "/s.txt", roots: [root], expected: sha(Array("secret".utf8))) == .refused(.outside))
    #expect(bytes(other + "/s.txt") == Array("secret".utf8))
    // deleted after the read: a save does not bring it back
    #expect(await w.write("x", encoding: .utf8, to: root + "/gone.txt", roots: [root], expected: "h") == .refused(.missing))
    #expect(!FileManager.default.fileExists(atPath: root + "/gone.txt"))
}

@Test func concurrentSavesOfOneFileFromOneReadLetOnlyOneThrough() async throws {
    let root = tempTree()
    let path = root + "/f.txt"
    put("base\n", path)
    let h = sha(Array("base\n".utf8))
    let w = WorkingFileWriter()
    let results = await withTaskGroup(of: WriteResult.self) { group in
        for i in 0..<8 { group.addTask { await w.write("edit \(i)\n", encoding: .utf8, to: path, roots: [root], expected: h) } }
        return await group.reduce(into: []) { $0.append($1) }
    }
    #expect(results.filter { if case .written = $0 { true } else { false } }.count == 1)
    #expect(results.filter { if case .conflict = $0 { true } else { false } }.count == 7)
}

// MARK: - Self-write registry

@Test func aSelfWriteIsKnownFor750Milliseconds() {
    var r = SelfWriteRegistry()
    let t = Date(timeIntervalSinceReferenceDate: 1000)
    r.record("/w/a.txt", at: t)
    #expect(r.contains("/w/a.txt", at: t))
    #expect(r.contains("/w/a.txt", at: t.addingTimeInterval(0.749)))
    #expect(!r.contains("/w/a.txt", at: t.addingTimeInterval(0.75)))
    #expect(!r.contains("/w/b.txt", at: t))
    r.record("/w/b.txt", at: t.addingTimeInterval(1))
    #expect(r.paths.count == 1)  // an expired entry goes at the next record
}

@Test func aWriteIsRecordedAsTheWritersOwnByItsRealPath() async throws {
    let root = tempTree()
    let path = root + "/f.txt"
    put("a", path)
    try FileManager.default.createSymbolicLink(atPath: root + "/link.txt", withDestinationPath: path)
    let now = Date(timeIntervalSinceReferenceDate: 50)
    let clock = Clock(now)
    let w = WorkingFileWriter(now: { clock.now })
    _ = await w.write("b", encoding: .utf8, to: root + "/link.txt", roots: [root], expected: sha(Array("a".utf8)))
    #expect(await w.isSelfWrite(path))
    #expect(await !w.isSelfWrite(root + "/link.txt"))  // the watcher reports the real path
    clock.now = now.addingTimeInterval(0.8)
    #expect(await !w.isSelfWrite(path))
}

private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}
