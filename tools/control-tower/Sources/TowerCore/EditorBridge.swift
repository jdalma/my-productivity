import Foundation

// The editor page's bridge (G4 I4, plan §1.4). The page (Monaco in a WKWebView) is outside the trust boundary: a path
// it sends is judged again here every time, and it writes only a file Swift gave it and unlocked (D#5 b).
// Later tickets add their messages here: lsp.send/receive (K12), openDiff and setMarkers (W2, W5).

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

    private enum Key: String, CodingKey { case kind, path, text, baseHash, dirty, line, col, message }

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

    private enum Key: String, CodingKey { case result, text, hash, diskHash, reason, message }

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
        }
    }
}

/// What Swift tells the page: the argument `m` of `window.ctBridge.receive(m)` through callAsyncJavaScript, never
/// JavaScript assembled from strings.
public enum EditorCommand: Equatable, Sendable, Encodable {
    case openFile(path: String, text: String, hash: String, line: Int?, readOnly: Bool)
    case fileChangedOnDisk(path: String, text: String?, hash: String?)
    case fileDeleted(path: String)
    case setTheme(dark: Bool)
    case setFontSize(Double)
    case setReadOnly(path: String, readOnly: Bool)
    /// Save the shown file, as ⌘S in the editor does.
    case save
    /// The open findings beside their lines in `path` (G4 W5); an empty list clears them.
    case setMarkers(path: String, markers: [EditorMarker])

    private enum Key: String, CodingKey { case kind, path, text, hash, line, readOnly, dark, size, markers }

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
        case .setMarkers(let path, let markers):
            try c.encode("setMarkers", forKey: .kind)
            try c.encode(path, forKey: .path)
            try c.encode(markers, forKey: .markers)
        }
    }
}

/// One editor's files: the folders it may read and save in, the files it has read (with the encoding a save keeps),
/// and the ones Swift unlocked. Paths are the real ones, links followed, as the page got them.
public actor EditorFiles {
    public let roots: [String]
    private var opened: [String: TextEncoding] = [:]
    private var unlocked: Set<String> = []
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
        return paths.sorted().map { path in
            if case .file(let text, let hash) = read(path) { .fileChangedOnDisk(path: path, text: text, hash: hash) } else { .fileDeleted(path: path) }
        }
    }

    public func handle(_ request: EditorRequest) async -> EditorReply {
        switch request {
        case .readFile(let path): return read(path)
        case .writeFile(let path, let text, let baseHash): return await write(path, text, baseHash)
        case .dirtyChanged, .cursor, .ready, .log: return .ok
        }
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
        case .written(let hash), .unchanged(let hash): return .written(hash: hash)
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

/// A finding's place in the editor (G4 W5): its line, how loud, what the hover says.
public struct EditorMarker: Hashable, Sendable, Encodable {
    public enum Severity: String, Sendable, Encodable { case error, warning, info, hint }
    public var line: Int
    public var severity: Severity
    public var message: String

    public init(line: Int, severity: Severity, message: String) {
        self.line = line
        self.severity = severity
        self.message = message
    }
}
