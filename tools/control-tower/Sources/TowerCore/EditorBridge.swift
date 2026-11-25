import Foundation

// The editor page's bridge (G4 I4, plan §1.4). The page (Monaco in a WKWebView) is outside the trust boundary: a path
// it sends is judged again here every time, and it writes only a file Swift gave it and unlocked (D#5 b).
// Later tickets add their messages here: openDiff and setMarkers (W2, W5). The LSP relay's are lspStart, lspSend
// (page to Swift) and lspReceive, lspClosed (Swift to page), LanguageServer.swift.

/// What the page sends: `window.webkit.messageHandlers.ct.postMessage({kind, …})`.
public enum EditorRequest: Equatable, Sendable, Decodable {
    case readFile(path: String)
    /// `baseHash`: the hash of the read the edit started from.
    case writeFile(path: String, text: String, baseHash: String)
    case dirtyChanged(path: String, dirty: Bool)
    case cursor(path: String, line: Int, col: Int)
    /// The editor has started; commands sent before it wait for this.
    case ready
    /// An error in the page or one of its workers, for the app's log.
    case log(message: String)
    /// The page opened a file of `languageId` at `path`: start its language server, if the table has one.
    case lspStart(languageId: String, path: String)
    /// One JSON-RPC message from the page's language client to the server of `channel`.
    case lspSend(channel: String, message: String)

    private enum Key: String, CodingKey { case kind, path, text, baseHash, dirty, line, col, message, languageId, channel }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "readFile": self = .readFile(path: try c.decode(String.self, forKey: .path))
        case "writeFile":
            self = .writeFile(path: try c.decode(String.self, forKey: .path), text: try c.decode(String.self, forKey: .text),
                              baseHash: try c.decode(String.self, forKey: .baseHash))
        case "dirtyChanged": self = .dirtyChanged(path: try c.decode(String.self, forKey: .path), dirty: try c.decode(Bool.self, forKey: .dirty))
        case "cursor":
            self = .cursor(path: try c.decode(String.self, forKey: .path), line: try c.decode(Int.self, forKey: .line),
                           col: try c.decode(Int.self, forKey: .col))
        case "ready": self = .ready
        case "log": self = .log(message: try c.decode(String.self, forKey: .message))
        case "lspStart":
            self = .lspStart(languageId: try c.decode(String.self, forKey: .languageId), path: try c.decode(String.self, forKey: .path))
        case "lspSend":
            self = .lspSend(channel: try c.decode(String.self, forKey: .channel), message: try c.decode(String.self, forKey: .message))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown kind \(kind)")
        }
    }
}

/// Why a read or a save the page asked for did not happen.
public enum EditorRefusal: String, Equatable, Sendable, Encodable {
    case notAbsolute, missing, notRegularFile, outside, binary, tooLarge
    /// A save of a file this editor never read.
    case notOpen
    /// A save of a file Swift has not unlocked.
    case readOnly
    /// No language server for this language in the table (LanguageServer.swift).
    case noLanguageServer
    /// The table has one, but it is not installed: the app shows the notice.
    case languageServerMissing
    /// A message for a server this editor did not start, or one that has ended.
    case noChannel
}

/// The answer to a request: `{result: "ok" | "conflict" | "refused" | "failed", …}`.
public enum EditorReply: Equatable, Sendable, Encodable {
    case file(text: String, hash: String)
    case written(hash: String)
    /// The disk changed since the read: nothing written.
    case conflict(diskHash: String)
    case refused(EditorRefusal)
    case failed(message: String)
    case ok
    /// The server of `channel` runs (or already ran) for the workspace `root`; its client serves `languages`.
    case lspStarted(channel: String, root: String, languages: [String])

    private enum Key: String, CodingKey { case result, text, hash, diskHash, reason, message, channel, root, languages }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .file(let text, let hash):
            try c.encode("ok", forKey: .result)
            try c.encode(text, forKey: .text)
            try c.encode(hash, forKey: .hash)
        case .written(let hash):
            try c.encode("ok", forKey: .result)
            try c.encode(hash, forKey: .hash)
        case .conflict(let disk):
            try c.encode("conflict", forKey: .result)
            try c.encode(disk, forKey: .diskHash)
        case .refused(let why):
            try c.encode("refused", forKey: .result)
            try c.encode(why, forKey: .reason)
        case .failed(let message):
            try c.encode("failed", forKey: .result)
            try c.encode(message, forKey: .message)
        case .ok: try c.encode("ok", forKey: .result)
        case .lspStarted(let channel, let root, let languages):
            try c.encode("ok", forKey: .result)
            try c.encode(channel, forKey: .channel)
            try c.encode(root, forKey: .root)
            try c.encode(languages, forKey: .languages)
        }
    }
}

/// What Swift tells the page: the argument `m` of `window.ctBridge.receive(m)` through callAsyncJavaScript, never
/// JavaScript assembled from strings.
public enum EditorCommand: Equatable, Sendable, Encodable {
    case openFile(path: String, text: String, hash: String, line: Int?, readOnly: Bool)
    /// The disk's text for a buffer held clean: the page takes it unless the buffer was edited meanwhile, and says
    /// which (`applied`).
    case fileChangedOnDisk(path: String, text: String?, hash: String?)
    /// The disk's text over the buffer whatever it holds (the banner's 디스크로 다시 읽기), as one edit the editor's
    /// undo takes back.
    case reloadFile(path: String, text: String, hash: String)
    /// Save the buffer over the disk bytes that hash to `diskHash` (the banner's 덮어쓰기): the page's save, from
    /// that base, so bytes that changed once more are not written over.
    case overwrite(path: String, diskHash: String)
    /// The buffer's text, for the banner's 비교.
    case getText(path: String)
    /// An open file has a new path (the tree's 이름 변경): the page keeps its buffer, under that path from now on.
    case renameFile(from: String, to: String)
    case fileDeleted(path: String)
    case setTheme(dark: Bool)
    case setFontSize(Double)
    case setReadOnly(path: String, readOnly: Bool)
    /// Save the shown file, as ⌘S in the editor does.
    case save
    /// One JSON-RPC message from the server of `channel`, in the order the server wrote them.
    case lspReceive(channel: String, message: String)
    /// The server of `channel` ended: its client stops; the next file of its language starts it again.
    case lspClosed(channel: String)

    private enum Key: String, CodingKey { case kind, path, text, hash, diskHash, line, readOnly, dark, size, from, to, channel, message }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .openFile(let path, let text, let hash, let line, let readOnly):
            try c.encode("openFile", forKey: .kind)
            try c.encode(path, forKey: .path)
            try c.encode(text, forKey: .text)
            try c.encode(hash, forKey: .hash)
            try c.encodeIfPresent(line, forKey: .line)
            try c.encode(readOnly, forKey: .readOnly)
        case .fileChangedOnDisk(let path, let text, let hash):
            try c.encode("fileChangedOnDisk", forKey: .kind)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(text, forKey: .text)
            try c.encodeIfPresent(hash, forKey: .hash)
        case .reloadFile(let path, let text, let hash):
            try c.encode("reloadFile", forKey: .kind)
            try c.encode(path, forKey: .path)
            try c.encode(text, forKey: .text)
            try c.encode(hash, forKey: .hash)
        case .overwrite(let path, let diskHash):
            try c.encode("overwrite", forKey: .kind)
            try c.encode(path, forKey: .path)
            try c.encode(diskHash, forKey: .diskHash)
        case .getText(let path):
            try c.encode("getText", forKey: .kind)
            try c.encode(path, forKey: .path)
        case .renameFile(let from, let to):
            try c.encode("renameFile", forKey: .kind)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
        case .fileDeleted(let path):
            try c.encode("fileDeleted", forKey: .kind)
            try c.encode(path, forKey: .path)
        case .setTheme(let dark):
            try c.encode("setTheme", forKey: .kind)
            try c.encode(dark, forKey: .dark)
        case .setFontSize(let size):
            try c.encode("setFontSize", forKey: .kind)
            try c.encode(size, forKey: .size)
        case .setReadOnly(let path, let readOnly):
            try c.encode("setReadOnly", forKey: .kind)
            try c.encode(path, forKey: .path)
            try c.encode(readOnly, forKey: .readOnly)
        case .save: try c.encode("save", forKey: .kind)
        case .lspReceive(let channel, let message):
            try c.encode("lspReceive", forKey: .kind)
            try c.encode(channel, forKey: .channel)
            try c.encode(message, forKey: .message)
        case .lspClosed(let channel):
            try c.encode("lspClosed", forKey: .kind)
            try c.encode(channel, forKey: .channel)
        }
    }
}

/// One editor's files: the folders it may read and save in, the files it has read (with the encoding a save keeps),
/// and the ones Swift unlocked. Paths are the real ones, links followed, as the page got them.
public actor EditorFiles {
    public let roots: [String]
    private var opened: [String: TextEncoding] = [:]
    private var unlocked: Set<String> = []
    /// The hash of each file's last save by this editor: the disk still holding it is the app's own write (W3).
    private var saved: [String: String] = [:]
    /// Making, renaming and trashing files is refused until the user unlocks it (D#5 b), as editing a file is.
    private var fileOpsLocked = true
    private let writer: WorkingFileWriter

    public init(roots: [String], writer: WorkingFileWriter = WorkingFileWriter()) {
        self.roots = roots
        self.writer = writer
    }

    /// Swift opening a file in the editor (a tree click, a finding's link): read-only until unlocked (D#5 b). nil for a
    /// file that cannot be shown; the caller says why from `handle(.readFile)` if it needs to.
    public func open(_ path: String, line: Int?) -> EditorCommand? {
        guard case .file(let text, let hash) = read(path), let real = realPath(path) else { return nil }
        return .openFile(path: real, text: text, hash: hash, line: line, readOnly: !unlocked.contains(real))
    }

    /// Locks or unlocks a file the editor read; the command tells the page.
    public func setReadOnly(_ path: String, _ readOnly: Bool) -> EditorCommand? {
        guard let real = realPath(path), opened[real] != nil else { return nil }
        if readOnly { unlocked.remove(real) } else { unlocked.insert(real) }
        return .setReadOnly(path: real, readOnly: readOnly)
    }

    /// What the page must hear of a watch batch under `root` (the folder the watch was given): each file it has open
    /// that changed on disk, with its text now, or that cannot be read any more. A rescan looks at every open file. By path.
    public func diskChanged(_ batch: FileWatchBatch, root: String) -> [EditorCommand] {
        let base = realPath(root) ?? root
        let paths = batch.rescan ? Set(opened.keys) : Set(batch.changed.union(batch.deleted).map { base + "/" + $0 }).filter { opened[$0] != nil }
        return paths.sorted().map(changed)
    }

    /// An open file as the disk holds it now: its text, or that it cannot be read any more.
    public func changed(_ path: String) -> EditorCommand {
        if case .file(let text, let hash) = read(path) { .fileChangedOnDisk(path: path, text: text, hash: hash) } else { .fileDeleted(path: path) }
    }

    /// The disk's text to put over an open file's buffer; nil when it cannot be read any more.
    public func reload(_ path: String) -> EditorCommand? {
        guard opened[path] != nil, case .file(let text, let hash) = read(path) else { return nil }
        return .reloadFile(path: path, text: text, hash: hash)
    }

    // MARK: The tree's file operations (G4 I9): Swift's own, never the page's

    public func setFileOpsLocked(_ locked: Bool) { fileOpsLocked = locked }

    /// Makes an empty file at `path`, and the folders missing on the way to it.
    public func createFile(_ path: String) async -> FileOpResult {
        guard !fileOpsLocked else { return .refused(.locked) }
        if let stopped = await makeFolders(above: path) { return stopped }
        return await writer.createFile(path, roots: roots)
    }

    /// Makes a folder at `path`, and the folders missing on the way to it.
    public func createFolder(_ path: String) async -> FileOpResult {
        guard !fileOpsLocked else { return .refused(.locked) }
        if let stopped = await makeFolders(above: path) { return stopped }
        return await writer.createFolder(path, roots: roots)
    }

    /// The folders of `path` that are not there yet, made nearest the root first; what stopped it, or nil. Each is
    /// judged as any new folder is: inside the roots, and no `..` in a name.
    private func makeFolders(above path: String) async -> FileOpResult? {
        var missing: [String] = []
        var folder = (path as NSString).deletingLastPathComponent
        // NSString resolves no `..`: a component is taken off as written, and `placed` refuses `..` as a name
        while folder.count > 1, realPath(folder) == nil {
            missing.append(folder)
            folder = String(folder[..<(folder.lastIndex(of: "/") ?? folder.startIndex)])
        }
        // every name first: a `..` further down must not leave the folders before it made
        guard missing.allSatisfy({ isFileName(($0 as NSString).lastPathComponent) }) else { return .refused(.badName) }
        for folder in missing.reversed() {
            let made = await writer.createFolder(folder, roots: roots)
            guard case .done = made else { return made }
        }
        return nil
    }

    /// Renames the file or folder at `path` in its folder. The files this editor read at or under it stay open, and
    /// unlocked, under their new paths.
    public func rename(_ path: String, to name: String) async -> FileOpResult {
        guard !fileOpsLocked else { return .refused(.locked) }
        let result = await writer.rename(path, to: name, roots: roots)
        guard case .done(let new) = result, let slash = new.lastIndex(of: "/") else { return result }
        let old = String(new[...slash]) + (path as NSString).lastPathComponent
        func moved(_ p: String) -> String? { p == old || p.hasPrefix(old + "/") ? new + p.dropFirst(old.count) : nil }
        opened = Dictionary(uniqueKeysWithValues: opened.map { (moved($0.key) ?? $0.key, $0.value) })
        unlocked = Set(unlocked.map { moved($0) ?? $0 })
        return result
    }

    /// Moves the file or folder at `path` to the trash.
    public func trash(_ path: String) async -> FileOpResult {
        guard !fileOpsLocked else { return .refused(.locked) }
        return await writer.trash(path, roots: roots)
    }

    /// Which of `paths` (real paths) are this editor's own writes: a file operation within the last moment
    /// (`SelfWriteRegistry.ttl`), or a save whose bytes the disk still holds. A watch event of one of them is the
    /// app's, not a worker's write (W3).
    public func ownWrites(_ paths: [String]) async -> Set<String> {
        var own: Set<String> = []
        for p in paths {
            // the window covers file operations; a save is the app's while the disk still holds its bytes, however
            // late the watch reports it (a loaded machine runs past 750 ms)
            if await writer.isSelfWrite(p) { own.insert(p) } else if let h = saved[p], let data = FileManager.default.contents(atPath: p),
                                                                     sha256(data) == h { own.insert(p) }
        }
        return own
    }

    public func handle(_ request: EditorRequest) async -> EditorReply {
        switch request {
        case .readFile(let path): return read(path)
        case .writeFile(let path, let text, let baseHash): return await write(path, text, baseHash)
        case .dirtyChanged, .cursor, .ready, .log, .lspStart, .lspSend: return .ok
        }
    }

    /// The root `path` is in (its real path), for a language server's workspace: nil outside every root.
    public func root(of path: String) -> String? {
        guard path.hasPrefix("/"), let real = realPath(path) else { return nil }
        return roots.compactMap(realPath).first { isInside(real, $0) }
    }

    private func read(_ path: String) -> EditorReply {
        guard path.hasPrefix("/") else { return .refused(.notAbsolute) }
        guard let real = realPath(path) else { return .refused(.missing) }
        guard roots.compactMap(realPath).contains(where: { isInside(real, $0) }) else { return .refused(.outside) }
        switch readFullFile(toplevel: "/", path: String(real.dropFirst())) {
        case .missing: return .refused(.notRegularFile)
        case .binary: return .refused(.binary)
        case .tooLarge: return .refused(.tooLarge)
        case .text(let f):
            opened[real] = f.encoding
            return .file(text: f.text, hash: f.hash)
        }
    }

    private func write(_ path: String, _ text: String, _ baseHash: String) async -> EditorReply {
        let real: String
        switch writeTarget(path, roots: roots) {
        case .file(let r): real = r
        case .refused(let why): return .refused(EditorRefusal(why))
        }
        guard let encoding = opened[real] else { return .refused(.notOpen) }
        guard unlocked.contains(real) else { return .refused(.readOnly) }
        switch await writer.write(text, encoding: encoding, to: real, roots: roots, expected: baseHash) {
        case .written(let hash), .unchanged(let hash):
            saved[real] = hash
            return .written(hash: hash)
        case .conflict(let current): return .conflict(diskHash: current)
        case .refused(let why): return .refused(EditorRefusal(why))
        case .failed(let message): return .failed(message: message)
        }
    }
}

private extension EditorRefusal {
    init(_ why: WriteRefusal) {
        switch why {
        case .notAbsolute: self = .notAbsolute
        case .missing: self = .missing
        case .notRegularFile: self = .notRegularFile
        case .outside: self = .outside
        }
    }
}

// MARK: - The page's files

/// The file a `ctedit://app/<urlPath>` request names in the built page `folder`: a regular file whose real path is
/// inside the folder, or nil (a `..` or a link leading out, a folder, nothing there).
public func editorPageFile(folder: String, urlPath: String) -> String? {
    let relative = urlPath.drop { $0 == "/" }
    guard let base = realPath(folder), let real = realPath(base + "/" + (relative.isEmpty ? "index.html" : relative)),
          isInside(real, base),
          (try? FileManager.default.attributesOfItem(atPath: real)[.type]) as? FileAttributeType == .typeRegular else { return nil }
    return real
}

/// The Content-Type of a page file by its extension (the page loads wasm and module workers, which need theirs).
public func editorContentType(_ pathExtension: String) -> String {
    switch pathExtension {
    case "html": "text/html"
    case "js", "mjs": "text/javascript"
    case "css": "text/css"
    case "json", "code-snippets": "application/json"
    case "wasm": "application/wasm"
    case "svg": "image/svg+xml"
    case "png": "image/png"
    case "ttf": "font/ttf"
    default: "application/octet-stream"
    }
}
