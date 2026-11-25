import AppKit
import os
import TowerCore

// The language servers the editors use (G4 I11): one process per LanguageServerKey on stdio, its output framed by
// LSPFrameReader and handed over in the order it was written. Which keys run is LanguageServerPool's.

@MainActor final class LanguageServerHost {
    static let shared = LanguageServerHost()
    private static let log = Logger(subsystem: "local.control-tower", category: "lsp")

    private final class Server {
        let process: Process
        let input: FileHandle
        var reader = LSPFrameReader()
        let onMessage: (String) -> Void
        let onExit: () -> Void

        init(process: Process, input: FileHandle, onMessage: @escaping (String) -> Void, onExit: @escaping () -> Void) {
            self.process = process
            self.input = input
            self.onMessage = onMessage
            self.onExit = onExit
        }
    }

    private var pool = LanguageServerPool()
    private var servers: [LanguageServerKey: Server] = [:]
    private var quit: NSObjectProtocol?

    init() {
        // the app quitting stops every server; a server also ends by itself when its stdin closes with the app
        quit = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
    }

    func isRunning(_ key: LanguageServerKey) -> Bool { servers[key] != nil }

    /// Starts the server of `key` in its root unless it runs. Its messages go to `onMessage` in the order it wrote them;
    /// `onExit` runs if it ends by itself. nil when it runs; the reason it could not start otherwise.
    func start(_ key: LanguageServerKey, executable: String, arguments: [String],
               onMessage: @escaping (String) -> Void, onExit: @escaping () -> Void) -> String? {
        guard pool.want(key) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: key.root)
        process.environment = languageServerEnvironment()
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            // the main queue keeps the reads in order; a Task per read might not
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data, from: key) } }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(key) } }
        }
        do {
            try process.run()
        } catch {
            pool.exited(key)
            return error.localizedDescription
        }
        servers[key] = Server(process: process, input: stdin.fileHandleForWriting, onMessage: onMessage, onExit: onExit)
        Self.log.info("language server \(key.server, privacy: .public) started in \(key.root, privacy: .public)")
        return nil
    }

    /// Writes one message to the server of `key`; false when it does not run.
    func send(_ key: LanguageServerKey, _ message: String) -> Bool {
        guard let server = servers[key] else { return false }
        Self.log.debug("to \(key.server, privacy: .public): \(Self.summary(message), privacy: .public)")
        do {
            try server.input.write(contentsOf: LSPFrameReader.frame(Data(message.utf8)))
            return true
        } catch {
            return false
        }
    }

    /// An editor closed: its servers stop.
    func release(editor: Int) { pool.release(editor: editor).forEach(stop) }

    func stopAll() { pool.stopAll().forEach(stop) }

    private func stop(_ key: LanguageServerKey) {
        // taken out first: its end is then not reported as a server ending by itself
        guard let server = servers.removeValue(forKey: key) else { return }
        try? server.input.close()
        server.process.terminate()
    }

    private func received(_ data: Data, from key: LanguageServerKey) {
        guard let server = servers[key] else { return }
        do {
            for body in try server.reader.push(data) {
                let message = String(decoding: body, as: UTF8.self)
                Self.log.debug("from \(key.server, privacy: .public): \(Self.summary(message), privacy: .public)")
                server.onMessage(message)
            }
        } catch {
            Self.log.error("language server \(key.server, privacy: .public) wrote no LSP: \(String(describing: error), privacy: .public)")
            stop(key)
            pool.exited(key)
            server.onExit()
        }
    }

    /// A message's method and id, for the debug log (`log stream --level debug --predicate 'category == "lsp"'`).
    private static func summary(_ message: String) -> String {
        guard let m = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any] else { return "not JSON" }
        let id = m["id"].map { " #\($0)" } ?? ""
        return (m["method"] as? String ?? (m["error"] != nil ? "error" : "result")) + id
    }

    private func ended(_ key: LanguageServerKey) {
        guard let server = servers.removeValue(forKey: key) else { return }
        pool.exited(key)
        Self.log.error("language server \(key.server, privacy: .public) ended (status \(server.process.terminationStatus))")
        server.onExit()
    }
}
