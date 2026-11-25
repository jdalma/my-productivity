import Foundation
import Testing
@testable import TowerCore

// The LSP relay (G4 I11, plan K12): framing of the server's stdout, the fixed table of servers (D#9 a), which servers
// run (D#14 a), and the bridge messages the page and the app exchange for it.

private func frame(_ json: String) -> Data { LSPFrameReader.frame(Data(json.utf8)) }
private func strings(_ bodies: [Data]) -> [String] { bodies.map { String(decoding: $0, as: UTF8.self) } }

// MARK: - Framing

@Test func aWholeMessageInOneReadComesOutWhole() throws {
    var reader = LSPFrameReader()
    let out = try reader.push(frame(#"{"id":1}"#))
    #expect(strings(out) == [#"{"id":1}"#])
}

@Test func aMessageSplitAnywhereComesOutOnceItIsComplete() throws {
    let bytes = frame(#"{"jsonrpc":"2.0","id":7,"result":null}"#)
    for cut in 1..<bytes.count {
        var reader = LSPFrameReader()
        let first = try reader.push(bytes.prefix(cut))
        let second = try reader.push(bytes.dropFirst(cut))
        #expect(first.isEmpty, "cut at \(cut)")
        #expect(strings(second) == [#"{"jsonrpc":"2.0","id":7,"result":null}"#], "cut at \(cut)")
    }
}

@Test func severalMessagesInOneReadComeOutInOrderAndAPartialOneWaits() throws {
    var reader = LSPFrameReader()
    let third = frame(#"{"id":3}"#)
    let out = try reader.push(frame(#"{"id":1}"#) + frame(#"{"id":2}"#) + third.prefix(10))
    #expect(strings(out) == [#"{"id":1}"#, #"{"id":2}"#])
    let rest = try reader.push(third.dropFirst(10))
    #expect(strings(rest) == [#"{"id":3}"#])
}

@Test func theLengthCountsBytesNotCharacters() throws {
    var reader = LSPFrameReader()
    let body = #"{"message":"타입이 맞지 않습니다 ✓"}"#
    let out = try reader.push(frame(body) + frame("{}"))
    #expect(strings(out) == [body, "{}"])
}

@Test func otherHeadersAndAnyCaseOfContentLengthAreRead() throws {
    var reader = LSPFrameReader()
    let raw = Data("content-length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n{}".utf8)
    let out = try reader.push(raw)
    #expect(strings(out) == ["{}"])
}

@Test func outputThatIsNotLSPIsRefused() throws {
    var noLength = LSPFrameReader()
    #expect(throws: LSPFrameReader.Failure.self) { _ = try noLength.push(Data("Hello: 1\r\n\r\n{}".utf8)) }
    // a program that writes plain text never ends a header: refused once that is clearly not one
    var chatter = LSPFrameReader()
    let early = try chatter.push(Data(repeating: UInt8(ascii: "x"), count: 100))
    #expect(early.isEmpty)
    #expect(throws: LSPFrameReader.Failure.self) { _ = try chatter.push(Data(repeating: UInt8(ascii: "x"), count: 5000)) }
}

@Test func aLargeBodyIsNotMistakenForAnOverlongHeader() throws {
    var reader = LSPFrameReader()
    let body = "{\"text\":\"" + String(repeating: "a", count: 10000) + "\"}"
    let bytes = frame(body)
    let first = try reader.push(bytes.prefix(6000))
    let second = try reader.push(bytes.dropFirst(6000))
    #expect(first.isEmpty)
    #expect(strings(second) == [body])
}

// MARK: - The table

@Test func eachLanguageHasAtMostOneServerAndKotlinPlainTextHaveNone() {
    #expect(languageServer(for: "swift")?.id == "sourcekit-lsp")
    #expect(languageServer(for: "typescript")?.id == "typescript-language-server")
    #expect(languageServer(for: "javascriptreact")?.id == "typescript-language-server")
    #expect(languageServer(for: "python")?.id == "pyright")
    #expect(languageServer(for: "java")?.id == "jdtls")
    #expect(languageServer(for: "kotlin") == nil)
    #expect(languageServer(for: "plaintext") == nil)
    let all = languageServers.flatMap(\.languages)
    #expect(Set(all).count == all.count, "a language in two entries")
}

@Test func aServerRunsFromWhereItIsFoundAndOtherwiseTheNoticeSaysHowToGetIt() throws {
    let swift = try #require(languageServer(for: "swift"))
    let ts = try #require(languageServer(for: "typescript"))
    let found: (String) -> String? = { ["xcrun": "/usr/bin/xcrun", "typescript-language-server": "/opt/homebrew/bin/typescript-language-server"][$0] }
    #expect(launch(swift, find: found, xcrunHas: { $0 == "sourcekit-lsp" }) == .run(executable: "/usr/bin/xcrun", arguments: ["sourcekit-lsp"]))
    #expect(launch(ts, find: found, xcrunHas: { _ in false })
            == .run(executable: "/opt/homebrew/bin/typescript-language-server", arguments: ["--stdio"]))

    guard case .notInstalled(let noSwift) = launch(swift, find: found, xcrunHas: { _ in false }) else { Issue.record("no notice"); return }
    #expect(noSwift.contains("sourcekit-lsp") && noSwift.contains("xcode-select --install"))
    guard case .notInstalled(let noTS) = launch(ts, find: { _ in nil }, xcrunHas: { _ in true }) else { Issue.record("no notice"); return }
    #expect(noTS.contains("typescript-language-server") && noTS.contains("npm install -g typescript-language-server typescript"))
}

// MARK: - Which servers run

@Test func aServerStartsOncePerEditorAndRootAndStopsWithItsEditor() {
    var pool = LanguageServerPool()
    let a = LanguageServerKey(editor: 1, server: "sourcekit-lsp", root: "/w/shop")
    let b = LanguageServerKey(editor: 1, server: "pyright", root: "/w/shop")
    let other = LanguageServerKey(editor: 2, server: "sourcekit-lsp", root: "/w/shop")
    let started = [pool.want(a), pool.want(a), pool.want(b), pool.want(other)]
    // the second want of a: already runs. another editor gets its own (D#14 a)
    #expect(started == [true, false, true, true])
    let stopped = pool.release(editor: 1)
    #expect(Set(stopped) == [a, b])
    #expect(pool.running == [other])
    let again = pool.release(editor: 1)
    #expect(again.isEmpty)
}

@Test func aServerThatEndedStartsAgainAndQuittingStopsEveryOne() {
    var pool = LanguageServerPool()
    let a = LanguageServerKey(editor: 1, server: "sourcekit-lsp", root: "/w/shop")
    let b = LanguageServerKey(editor: 3, server: "jdtls", root: "/w/api")
    _ = pool.want(a)
    _ = pool.want(b)
    pool.exited(a)
    let restarted = pool.want(a)
    #expect(restarted)
    let all = pool.stopAll()
    #expect(Set(all) == [a, b])
    #expect(pool.running.isEmpty)
}

@Test func theChannelNamesServerAndRoot() {
    #expect(LanguageServerKey(editor: 4, server: "sourcekit-lsp", root: "/w/shop").channel == "sourcekit-lsp:/w/shop")
}

// MARK: - Bridge messages

private func json(_ value: some Encodable) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
}

@Test func thePagesLSPMessagesDecode() throws {
    let start = try JSONDecoder().decode(EditorRequest.self, from: Data(#"{"kind":"lspStart","languageId":"swift","path":"/w/a.swift"}"#.utf8))
    #expect(start == .lspStart(languageId: "swift", path: "/w/a.swift"))
    let send = try JSONDecoder().decode(EditorRequest.self, from: Data(#"{"kind":"lspSend","channel":"c","message":"{}"}"#.utf8))
    #expect(send == .lspSend(channel: "c", message: "{}"))
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(EditorRequest.self, from: Data(#"{"kind":"lspStart","languageId":"swift"}"#.utf8))
    }
}

@Test func theAppsLSPAnswersAndCommandsEncode() throws {
    let started = try json(EditorReply.lspStarted(channel: "sourcekit-lsp:/w", root: "/w", languages: ["swift"]))
    #expect(started["result"] as? String == "ok")
    #expect(started["channel"] as? String == "sourcekit-lsp:/w")
    #expect(started["root"] as? String == "/w")
    #expect(started["languages"] as? [String] == ["swift"])
    #expect(try json(EditorReply.refused(.languageServerMissing))["reason"] as? String == "languageServerMissing")
    #expect(try json(EditorReply.refused(.noChannel))["reason"] as? String == "noChannel")
    let receive = try json(EditorCommand.lspReceive(channel: "c", message: #"{"id":1}"#))
    #expect(receive["kind"] as? String == "lspReceive" && receive["channel"] as? String == "c" && receive["message"] as? String == #"{"id":1}"#)
    #expect(try json(EditorCommand.lspClosed(channel: "c")) as NSDictionary == ["kind": "lspClosed", "channel": "c"])
}

@Test func aServersRootIsTheEditorRootTheFileIsIn() async throws {
    // the temporary folder is reached through a link (/var -> /private/var): roots come back as real paths
    let base = FileManager.default.temporaryDirectory.appending(path: "ct-lsp-\(UUID().uuidString)").path
    let shop = base + "/shop", api = base + "/api", outside = base + "/other"
    for dir in [shop + "/Sources", api, outside] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(atPath: base) }
    for f in [shop + "/Sources/a.swift", api + "/b.py", outside + "/c.swift"] { FileManager.default.createFile(atPath: f, contents: Data()) }
    let real = try #require(realPath(base))
    let files = EditorFiles(roots: [shop, api])
    #expect(await files.root(of: shop + "/Sources/a.swift") == real + "/shop")
    #expect(await files.root(of: api + "/b.py") == real + "/api")
    #expect(await files.root(of: outside + "/c.swift") == nil)
    #expect(await files.root(of: "Sources/a.swift") == nil)
}
