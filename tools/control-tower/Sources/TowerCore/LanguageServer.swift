import Foundation

// The LSP relay (G4 I11, plan K12): the app runs a language server on stdio and passes its JSON-RPC messages to the
// editor page over the bridge, where MonacoLanguageClient speaks LSP (editor-web/src/lsp-transport.ts).
// What runs is a fixed table (D#9 a): the page names a language, never a program, and nothing is installed by the app.

// MARK: - Framing

/// LSP's base protocol: `Content-Length: <n>\r\n` (other headers allowed), a blank line, then n bytes of JSON.
/// The server's stdout arrives in pieces of any size: one message split over reads, several in one read.
public struct LSPFrameReader: Sendable {
    public enum Failure: Error, Equatable {
        /// A header block without a usable Content-Length, or one too long to be a header: the stream is not LSP.
        case badHeader(String)
    }

    /// A header block longer than this is not a header (LSP's has one or two short lines).
    static let headerLimit = 4096
    private var buffer = Data()

    public init() {}

    /// The bodies complete after `chunk`, in order; a partial message stays for the next call.
    public mutating func push(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var bodies: [Data] = []
        let separator = Data("\r\n\r\n".utf8)
        while let end = buffer.range(of: separator) {
            let header = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            guard let length = Self.contentLength(header) else { throw Failure.badHeader(header) }
            let start = end.upperBound
            guard buffer.endIndex - start >= length else { break }
            bodies.append(Data(buffer[start..<(start + length)]))
            buffer = Data(buffer[(start + length)...])
        }
        // what is left is a header still arriving, or a body waiting for its last bytes (its separator is there)
        if buffer.range(of: separator) == nil, buffer.count > Self.headerLimit {
            throw Failure.badHeader(String(decoding: buffer.prefix(80), as: UTF8.self))
        }
        return bodies
    }

    /// `body` framed for the server's stdin.
    public static func frame(_ body: Data) -> Data {
        Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }

    private static func contentLength(_ header: String) -> Int? {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 ? $0 : nil }
            }
        }
        return nil
    }
}

// MARK: - The servers

/// A language server the app may run (D#9 a: the user installs it, the app only finds it).
public struct LanguageServerSpec: Equatable, Sendable {
    /// Stable id, also the channel's prefix: "sourcekit-lsp".
    public let id: String
    /// The page's (Monaco's) language ids it serves.
    public let languages: [String]
    /// For the "not found" notice: "Swift".
    public let label: String
    /// The program: found on the search path, or through `xcrun --find` when `viaXcrun`.
    public let executable: String
    public let arguments: [String]
    public let viaXcrun: Bool
    /// How the user gets it, for the "not found" notice.
    public let install: String
}

/// The fixed table. Kotlin has no grammar in the page (no VS Code built-in), so no Kotlin file reaches a server.
public let languageServers: [LanguageServerSpec] = [
    LanguageServerSpec(id: "sourcekit-lsp", languages: ["swift"], label: "Swift", executable: "sourcekit-lsp",
                       arguments: [], viaXcrun: true, install: "Xcode 또는 Command Line Tools(xcode-select --install)에 들어 있습니다."),
    LanguageServerSpec(id: "typescript-language-server", languages: ["typescript", "javascript", "typescriptreact", "javascriptreact"],
                       label: "TypeScript·JavaScript", executable: "typescript-language-server", arguments: ["--stdio"], viaXcrun: false,
                       install: "npm install -g typescript-language-server typescript"),
    LanguageServerSpec(id: "pyright", languages: ["python"], label: "Python", executable: "pyright-langserver",
                       arguments: ["--stdio"], viaXcrun: false, install: "npm install -g pyright"),
    LanguageServerSpec(id: "jdtls", languages: ["java"], label: "Java", executable: "jdtls", arguments: [], viaXcrun: false,
                       install: "brew install jdtls (JDK가 필요합니다)"),
]

public func languageServer(for languageId: String) -> LanguageServerSpec? {
    languageServers.first { $0.languages.contains(languageId) }
}

/// What starting `spec` comes to on this Mac.
public enum LanguageServerLaunch: Equatable, Sendable {
    case run(executable: String, arguments: [String])
    /// The notice to show: what is missing and how to get it.
    case notInstalled(String)
}

/// `find` resolves a program name on the search path; `xcrunHas` asks `xcrun --find` for a developer tool.
public func launch(_ spec: LanguageServerSpec, find: (String) -> String?, xcrunHas: (String) -> Bool) -> LanguageServerLaunch {
    if spec.viaXcrun {
        if let xcrun = find("xcrun"), xcrunHas(spec.executable) { return .run(executable: xcrun, arguments: [spec.executable] + spec.arguments) }
    } else if let path = find(spec.executable) {
        return .run(executable: path, arguments: spec.arguments)
    }
    return .notInstalled(notInstalledNotice(spec))
}

/// The real `launch`: the app's search path (Homebrew included) and `xcrun --find`.
public func launch(_ spec: LanguageServerSpec) -> LanguageServerLaunch {
    launch(spec, find: { resolveExecutable($0) }, xcrunHas: { tool in
        (try? runCommand(["xcrun", "--find", tool], timeout: 10))?.status == 0
    })
}

public func notInstalledNotice(_ spec: LanguageServerSpec) -> String {
    "\(spec.label) 언어 서버(\(spec.executable))를 찾지 못해 자동 완성·정의 이동·진단 없이 엽니다. \(spec.install)"
}

/// The environment a server runs with: the app's, with the search path the app uses (a GUI app lacks Homebrew's).
public func languageServerEnvironment() -> [String: String] {
    childEnvironment(base: ProcessInfo.processInfo.environment, extra: [:])
}

// MARK: - Which servers run

/// One server: for one editor (D#14 a, LSP being one client per server), one table entry, one workspace root.
public struct LanguageServerKey: Hashable, Sendable {
    public let editor: Int
    public let server: String
    public let root: String

    public init(editor: Int, server: String, root: String) {
        self.editor = editor
        self.server = server
        self.root = root
    }

    /// The name the page and the app use for this server's messages.
    public var channel: String { "\(server):\(root)" }
}

/// Which servers should run: started once per key, stopped when their editor closes, all stopped when the app quits.
public struct LanguageServerPool: Sendable {
    public private(set) var running: Set<LanguageServerKey> = []

    public init() {}

    /// true when `key` must be started now; false when it already runs.
    public mutating func want(_ key: LanguageServerKey) -> Bool { running.insert(key).inserted }

    /// An editor closed (it sees no root any more): the servers to stop.
    public mutating func release(editor: Int) -> [LanguageServerKey] {
        let gone = running.filter { $0.editor == editor }
        running.subtract(gone)
        return gone.sorted { $0.channel < $1.channel }
    }

    /// The server ended by itself: the next file of its language starts it again.
    public mutating func exited(_ key: LanguageServerKey) { running.remove(key) }

    /// The app quits: every server.
    public mutating func stopAll() -> [LanguageServerKey] {
        defer { running = [] }
        return running.sorted { ($0.editor, $0.channel) < ($1.editor, $1.channel) }
    }
}
