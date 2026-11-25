import Foundation
import Testing
@testable import TowerApp
@testable import TowerCore

// The language server processes (G4 I11): started per key, their stdout framed and handed over in order, stopped with
// their editor or the app, and reported when they end by themselves. `cat` stands in for a server: it echoes the
// framed messages it is sent.

@MainActor private func until(_ seconds: Double = 10, _ done: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !done() {
        if Date() > end { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

private func key(_ editor: Int = 1, _ server: String = "echo") -> LanguageServerKey {
    LanguageServerKey(editor: editor, server: server, root: FileManager.default.temporaryDirectory.path)
}

/// The processes whose command line has `marker` (tests run in parallel: each counts only its own).
private func pids(marked marker: String) -> Set<String> {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", marker]
    let out = Pipe()
    p.standardOutput = out
    try? p.run()
    p.waitUntilExit()
    return Set(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init))
}

@MainActor @Test func messagesGoToTheServerAndItsAnswersComeBackInOrder() async {
    let host = LanguageServerHost()
    var got: [String] = []
    var ended = false
    let k = key()
    #expect(host.start(k, executable: "/bin/cat", arguments: [], onMessage: { got.append($0) }, onExit: { ended = true }) == nil)
    #expect(host.isRunning(k))
    let sent = (1...50).map { #"{"jsonrpc":"2.0","id":\#($0),"method":"x","params":{"text":"한글 \#(String(repeating: "a", count: $0 * 97))"}}"# }
    for m in sent { #expect(host.send(k, m)) }
    #expect(await until { got.count == sent.count })
    #expect(got == sent)
    host.release(editor: 1)
    #expect(!host.isRunning(k))
    #expect(!host.send(k, "{}"), "a stopped server takes nothing")
    try? await Task.sleep(for: .milliseconds(300))
    #expect(!ended, "stopping it is not its own end")
}

@MainActor @Test func aSecondStartOfTheSameKeyStartsNothing() async {
    let host = LanguageServerHost()
    let k = key()
    let marker = "ct-lsp-test-\(UUID().uuidString)"
    // the shell stays (it runs cat, then the marker's no-op), so its command line keeps the marker
    let args = ["-c", "cat; : \(marker)"]
    #expect(host.start(k, executable: "/bin/sh", arguments: args, onMessage: { _ in }, onExit: {}) == nil)
    #expect(host.start(k, executable: "/bin/sh", arguments: args, onMessage: { _ in }, onExit: {}) == nil)
    #expect(await until { pids(marked: marker).count == 1 })
    try? await Task.sleep(for: .milliseconds(200))
    #expect(pids(marked: marker).count == 1)
    host.stopAll()
    #expect(await until { pids(marked: marker).isEmpty }, "quitting leaves no server behind")
}

@MainActor @Test func closingOneEditorStopsOnlyItsServers() async {
    let host = LanguageServerHost()
    let mine = key(1), theirs = key(2)
    for k in [mine, theirs] { _ = host.start(k, executable: "/bin/cat", arguments: [], onMessage: { _ in }, onExit: {}) }
    host.release(editor: 1)
    #expect(!host.isRunning(mine))
    #expect(host.isRunning(theirs))
    host.stopAll()
    #expect(!host.isRunning(theirs))
}

@MainActor @Test func aServerThatEndsByItselfIsReportedAndCanStartAgain() async {
    let host = LanguageServerHost()
    var ended = 0
    let k = key()
    _ = host.start(k, executable: "/bin/sh", arguments: ["-c", "exit 3"], onMessage: { _ in }, onExit: { ended += 1 })
    #expect(await until { ended == 1 })
    #expect(!host.isRunning(k))
    #expect(host.start(k, executable: "/bin/cat", arguments: [], onMessage: { _ in }, onExit: {}) == nil)
    #expect(host.isRunning(k))
    host.stopAll()
}

@MainActor @Test func aProgramThatDoesNotSpeakLSPIsStoppedAndReported() async {
    let host = LanguageServerHost()
    var ended = 0
    var got: [String] = []
    let k = key()
    // plain text and no header end: refused once it is clearly not a header (LSPFrameReader.headerLimit). `exec`: the
    // stop ends the sleep itself; an orphaned sleep would hold pipes other tests' children inherit, for 30 s
    _ = host.start(k, executable: "/bin/sh", arguments: ["-c", "head -c 6000 /dev/zero | tr '\\\\0' x; exec sleep 30"],
                   onMessage: { got.append($0) }, onExit: { ended += 1 })
    #expect(await until { ended == 1 })
    #expect(!host.isRunning(k))
    #expect(got.isEmpty)
}

@MainActor @Test func aProgramThatCannotStartSaysWhy() {
    let host = LanguageServerHost()
    let k = key()
    #expect(host.start(k, executable: "/nonexistent/server", arguments: [], onMessage: { _ in }, onExit: {}) != nil)
    #expect(!host.isRunning(k))
}

// MARK: - sourcekit-lsp, end to end (CT_LSP_E2E=1; it builds a package index, so it is not part of every run)

/// One request or notification as the page's language client would send it.
private func rpc(_ id: Int?, _ method: String, _ params: [String: Any]) -> String {
    var m: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
    if let id { m["id"] = id }
    return String(decoding: try! JSONSerialization.data(withJSONObject: m), as: UTF8.self)
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["CT_LSP_E2E"] == "1"))
func sourceKitLSPAnswersCompletionDefinitionAndDiagnosticsThroughTheHost() async throws {
    let spec = try #require(languageServer(for: "swift"))
    guard case .run(let executable, let arguments) = launch(spec) else { Issue.record("sourcekit-lsp not found"); return }
    let root = FileManager.default.temporaryDirectory.appending(path: "ct-lsp-e2e-\(UUID().uuidString)").path
    let sources = root + "/Sources/Sample"
    try FileManager.default.createDirectory(atPath: sources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    try #"// swift-tools-version: 6.0\#nimport PackageDescription\#nlet package = Package(name: "Sample", targets: [.executableTarget(name: "Sample")])\#n"#
        .write(toFile: root + "/Package.swift", atomically: true, encoding: .utf8)
    try "struct Greeter {\n    let name: String\n    func greet() -> String { \"Hello, \\(name)\" }\n}\n"
        .write(toFile: sources + "/Greeter.swift", atomically: true, encoding: .utf8)
    let main = "let greeter = Greeter(name: \"tower\")\nprint(greeter.greet())\nlet count: Int = \"not a number\"\n"
    try main.write(toFile: sources + "/main.swift", atomically: true, encoding: .utf8)
    let real = try #require(realPath(root))
    let mainURI = URL(fileURLWithPath: real + "/Sources/Sample/main.swift").absoluteString

    let host = LanguageServerHost()
    var answers: [Int: Any] = [:]
    var diagnostics: [[String: Any]] = []
    let k = LanguageServerKey(editor: 1, server: spec.id, root: real)
    #expect(host.start(k, executable: executable, arguments: arguments, onMessage: { text in
        guard let m = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if let id = m["id"] as? Int, m["method"] == nil { answers[id] = m["result"] ?? NSNull() }
        if m["method"] as? String == "textDocument/publishDiagnostics", let p = m["params"] as? [String: Any],
           p["uri"] as? String == mainURI, let d = p["diagnostics"] as? [[String: Any]], !d.isEmpty { diagnostics = d }
    }, onExit: {}) == nil)
    defer { host.stopAll() }

    _ = host.send(k, rpc(1, "initialize", ["processId": NSNull(), "rootUri": URL(fileURLWithPath: real).absoluteString, "capabilities": [:]]))
    #expect(await until(60) { answers[1] != nil })
    _ = host.send(k, rpc(nil, "initialized", [:]))
    _ = host.send(k, rpc(nil, "textDocument/didOpen", ["textDocument": ["uri": mainURI, "languageId": "swift", "version": 1, "text": main]]))
    #expect(await until(90) { !diagnostics.isEmpty }, "a diagnostic for line 3")
    #expect(diagnostics.contains { (($0["range"] as? [String: Any])?["start"] as? [String: Any])?["line"] as? Int == 2 })

    // after "greeter." on line 2 (0-based line 1, character 14)
    _ = host.send(k, rpc(2, "textDocument/completion", ["textDocument": ["uri": mainURI], "position": ["line": 1, "character": 14]]))
    #expect(await until(60) { answers[2] != nil })
    let items = ((answers[2] as? [String: Any])?["items"] as? [[String: Any]]) ?? (answers[2] as? [[String: Any]]) ?? []
    #expect(items.contains { ($0["label"] as? String)?.hasPrefix("greet") == true })

    // Greeter on line 1 → Greeter.swift
    _ = host.send(k, rpc(3, "textDocument/definition", ["textDocument": ["uri": mainURI], "position": ["line": 0, "character": 16]]))
    #expect(await until(60) { answers[3] != nil })
    let target = (answers[3] as? [[String: Any]])?.first ?? (answers[3] as? [String: Any]) ?? [:]
    #expect(((target["uri"] ?? target["targetUri"]) as? String)?.hasSuffix("/Greeter.swift") == true)
}
