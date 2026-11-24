import CryptoKit
import Foundation

// A working-tree file whole, for the editor (G4 K1), and the app's only write into a working tree (K7): a save goes
// through only to an existing file inside the allowed folders, and only while the disk still holds what was read.

/// How a text file's bytes are kept, so a save writes them back the same way.
public enum TextEncoding: Hashable, Sendable {
    case utf8, utf8BOM, utf16LE, utf16BE
}

public struct FullFile: Hashable, Sendable {
    public var text: String
    public var encoding: TextEncoding
    /// SHA-256 of the bytes on disk, lowercase hex: what a save compares the disk against.
    public var hash: String
}

public enum FullRead: Hashable, Sendable {
    /// Gone from the working tree, or not a regular readable file.
    case missing
    /// A NUL in the first 8000 bytes, or text in none of `TextEncoding`.
    case binary
    case tooLarge(size: Int)
    case text(FullFile)
}

/// The largest file read whole.
// ponytail: one fixed cap; the editor shows tooLarge past it. Raise or make it a setting if real files hit it.
public let fullFileLimit = 10 * 1024 * 1024

/// Reads `path` under `toplevel` whole, line endings as written. Unlike `readWorkingFile` there is no line window.
public func readFullFile(toplevel: String, path: String, sizeLimit: Int = fullFileLimit) -> FullRead {
    let url = URL(fileURLWithPath: toplevel).appending(path: path)
    guard let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true else { return .missing }
    if let size = v.fileSize, size > sizeLimit { return .tooLarge(size: size) }
    guard let data = try? Data(contentsOf: url) else { return .missing }
    guard let (text, encoding) = decode(data) else { return .binary }
    return .text(FullFile(text: text, encoding: encoding, hash: sha256(data)))
}

/// A BOM first: UTF-16 holds NULs, so it is told by its BOM before the NUL check marks it binary.
private func decode(_ data: Data) -> (String, TextEncoding)? {
    let b = [UInt8](data.prefix(3))
    if b.starts(with: [0xff, 0xfe]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian).map { ($0, .utf16LE) } }
    if b.starts(with: [0xfe, 0xff]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian).map { ($0, .utf16BE) } }
    guard !data.prefix(8000).contains(0) else { return nil }
    if b == [0xef, 0xbb, 0xbf] { return String(data: data.dropFirst(3), encoding: .utf8).map { ($0, .utf8BOM) } }
    return String(data: data, encoding: .utf8).map { ($0, .utf8) }
}

private func encode(_ text: String, _ encoding: TextEncoding) -> Data {
    switch encoding {
    case .utf8: Data(text.utf8)
    case .utf8BOM: Data([0xef, 0xbb, 0xbf] + Array(text.utf8))
    case .utf16LE: Data([0xff, 0xfe]) + text.data(using: .utf16LittleEndian)!
    case .utf16BE: Data([0xfe, 0xff]) + text.data(using: .utf16BigEndian)!
    }
}

func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

// MARK: - Where a save may go

public enum WriteRefusal: Hashable, Sendable {
    case notAbsolute
    /// No file there: a save never creates one, nor brings back a file deleted after it was read.
    case missing
    case notRegularFile
    /// Its real path, links followed, is in none of the roots.
    case outside
}

public enum WriteTarget: Hashable, Sendable {
    /// The real path the bytes go to.
    case file(String)
    case refused(WriteRefusal)
}

/// Where a save of `path` goes: its real path, while that is an existing regular file inside one of `roots` (a
/// worktree, or another allowed folder) judged by the roots' real paths too. A link that leads out of every root, by
/// `..` or a linked folder on the way, is refused, as `documentTarget` does for the documents folder.
public func writeTarget(_ path: String, roots: [String]) -> WriteTarget {
    guard path.hasPrefix("/") else { return .refused(.notAbsolute) }
    guard let real = realPath(path) else { return .refused(.missing) }
    guard roots.compactMap(realPath).contains(where: { isInside(real, $0) }) else { return .refused(.outside) }
    guard (try? FileManager.default.attributesOfItem(atPath: real)[.type]) as? FileAttributeType == .typeRegular else {
        return .refused(.notRegularFile)
    }
    return .file(real)
}

// MARK: - Compare-and-write

public enum WriteResult: Hashable, Sendable {
    case written(hash: String)
    /// The disk already holds these bytes: nothing written.
    case unchanged(hash: String)
    /// The disk changed since the read (`current`: its hash now); nothing written.
    case conflict(current: String)
    case refused(WriteRefusal)
    /// The write itself failed (disk full, permission): the file may still hold its old bytes, the edit is not saved.
    case failed(String)
}

/// The paths this app just wrote, so the file watcher can pass over the event of its own save (G4 §3 design 8).
public struct SelfWriteRegistry: Sendable {
    public static let ttl: TimeInterval = 0.75
    private(set) var paths: [String: Date] = [:]

    public init() {}

    public mutating func record(_ path: String, at now: Date) {
        paths = paths.filter { now.timeIntervalSince($0.value) < Self.ttl }
        paths[path] = now
    }

    public func contains(_ path: String, at now: Date) -> Bool {
        paths[path].map { now.timeIntervalSince($0) < Self.ttl } ?? false
    }
}

/// Saves of working-tree files, one at a time: the hash check and the write of a save never interleave with another's.
// ponytail: one actor serializes every save, of any file. Per-file queues if saving many files at once ever waits.
public actor WorkingFileWriter {
    private var selfWrites = SelfWriteRegistry()
    private let now: @Sendable () -> Date
    /// What `trash` does with a file: the user's trash, or a test's stand-in for it.
    let toTrash: @Sendable (URL) throws -> Void

    public init(now: @escaping @Sendable () -> Date = Date.init,
                toTrash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.now = now
        self.toTrash = toTrash
    }

    /// Notes a path this writer just wrote, made, moved or trashed (`isSelfWrite`).
    func wrote(_ realPath: String) { selfWrites.record(realPath, at: now()) }

    /// Writes `text` to `path` when its bytes on disk still hash to `expected`, the hash of the read the edit started
    /// from. The bytes go to the real path (a link inside the roots stays a link) atomically, and the file keeps its
    /// permissions.
    public func write(_ text: String, encoding: TextEncoding, to path: String, roots: [String], expected: String) -> WriteResult {
        let real: String
        switch writeTarget(path, roots: roots) {
        case .file(let r): real = r
        case .refused(let why): return .refused(why)
        }
        let url = URL(fileURLWithPath: real)
        guard let disk = try? Data(contentsOf: url) else { return .refused(.missing) }
        let bytes = encode(text, encoding)
        let wanted = sha256(bytes), current = sha256(disk)
        if current == wanted { return .unchanged(hash: wanted) }
        guard current == expected else { return .conflict(current: current) }
        let mode = (try? FileManager.default.attributesOfItem(atPath: real))?[.posixPermissions]
        do {
            // `.atomic` (a new file renamed over the name) is what keeps a hard link inside the roots from writing
            // through to a file outside them, which `writeTarget` cannot see: never write in place here (R15 L1,
            // EditorBridgeTests aSaveThroughAHardLink…). The link is broken instead; the outside file keeps its bytes.
            try bytes.write(to: url, options: .atomic)
            if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: real) }
        } catch {
            return .failed(error.localizedDescription)
        }
        wrote(real)
        return .written(hash: wanted)
    }

    /// Whether `realPath` was written by this writer within the last 750 ms.
    public func isSelfWrite(_ realPath: String) -> Bool { selfWrites.contains(realPath, at: now()) }
}

// MARK: - Creating, renaming and trashing (G4 I9)

public enum FileOpRefusal: String, Hashable, Sendable, Error {
    case notAbsolute
    /// Nothing at the path to rename or trash, or no folder to make the new thing in.
    case missing
    /// The folder it is in, links followed, is in none of the roots.
    case outside
    /// Something is already at the new path: nothing is ever written over.
    case exists
    /// Not one path component: empty, `.`, `..`, or with a `/`.
    case badName
    /// File operations are locked until the user unlocks them (D#5 b).
    case locked
}

public enum FileOpResult: Hashable, Sendable {
    /// The real path of what was made, of the new name, or of what went to the trash.
    case done(path: String)
    case refused(FileOpRefusal)
    case failed(String)
}

/// One path component a file or folder may be named.
func isFileName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
}

/// `path` as the real path of its folder plus its last component, while that folder is inside one of `roots`: a
/// folder reached through a link that leads out of every root, or by `..`, is refused. The last component is not
/// followed: a link is renamed or trashed itself, and a new name is never looked through.
private func placed(_ path: String, roots: [String]) -> Result<String, FileOpRefusal> {
    guard path.hasPrefix("/"), let slash = path.lastIndex(of: "/") else { return .failure(.notAbsolute) }
    let name = String(path[path.index(after: slash)...])
    guard isFileName(name) else { return .failure(.badName) }
    guard let folder = realPath(slash == path.startIndex ? "/" : String(path[..<slash])) else { return .failure(.missing) }
    guard roots.compactMap(realPath).contains(where: { isInside(folder, $0) }) else { return .failure(.outside) }
    return .success(folder + "/" + name)
}

/// Whether anything is at `path`, a link that leads nowhere included.
private func somethingAt(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}

extension WorkingFileWriter {
    /// Makes an empty file at `path`: its folder there already and inside the roots, nothing at the path.
    public func createFile(_ path: String, roots: [String]) -> FileOpResult {
        make(path, roots: roots) { try Data().write(to: URL(fileURLWithPath: $0), options: .withoutOverwriting) }
    }

    /// Makes a folder at `path`, under the same rules.
    public func createFolder(_ path: String, roots: [String]) -> FileOpResult {
        make(path, roots: roots) { try FileManager.default.createDirectory(atPath: $0, withIntermediateDirectories: false) }
    }

    private func make(_ path: String, roots: [String], _ create: (String) throws -> Void) -> FileOpResult {
        let target: String
        switch placed(path, roots: roots) {
        case .success(let t): target = t
        case .failure(let why): return .refused(why)
        }
        guard !somethingAt(target) else { return .refused(.exists) }
        do { try create(target) } catch { return somethingAt(target) ? .refused(.exists) : .failed(error.localizedDescription) }
        wrote(target)
        return .done(path: target)
    }

    /// Gives the file or folder at `path` the name `name`, in the folder it is in. Nothing is written over: with
    /// something at the new name already, even made in this instant, nothing moves (`RENAME_EXCL`).
    // ponytail: a change of letter case only is refused as `exists` where the file system ignores case (the name is taken, by the file itself)
    public func rename(_ path: String, to name: String, roots: [String]) -> FileOpResult {
        let source: String
        switch placed(path, roots: roots) {
        case .success(let s): source = s
        case .failure(let why): return .refused(why)
        }
        guard somethingAt(source) else { return .refused(.missing) }
        guard isFileName(name) else { return .refused(.badName) }
        let target = String(source[...source.lastIndex(of: "/")!]) + name
        guard renamex_np(source, target, UInt32(RENAME_EXCL)) == 0 else {
            return errno == EEXIST ? .refused(.exists) : .failed(String(cString: strerror(errno)))
        }
        wrote(source)
        wrote(target)
        return .done(path: target)
    }

    /// Moves the file or folder at `path` to the trash, where the user can take it back.
    public func trash(_ path: String, roots: [String]) -> FileOpResult {
        let source: String
        switch placed(path, roots: roots) {
        case .success(let s): source = s
        case .failure(let why): return .refused(why)
        }
        guard somethingAt(source) else { return .refused(.missing) }
        do { try toTrash(URL(fileURLWithPath: source)) } catch { return .failed(error.localizedDescription) }
        wrote(source)
        return .done(path: source)
    }
}
