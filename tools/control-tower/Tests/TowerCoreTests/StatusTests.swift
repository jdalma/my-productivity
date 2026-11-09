import Foundation
import Testing
@testable import TowerCore

@Test func deriveMyTurnTruthTable() {
    #expect(deriveMyTurn(status: .wait) == true)
    #expect(deriveMyTurn(status: .wait, spool: 0) == true)
    #expect(deriveMyTurn(status: .wait, spool: 2) == false)
    #expect(deriveMyTurn(status: .busy, spool: 0) == false)
    #expect(deriveMyTurn(status: .unknown, spool: 0) == false)
    #expect(deriveMyTurn(status: .busy, spool: 3, permissionPrompt: true) == true)
    #expect(deriveMyTurn(status: .unknown, permissionPrompt: true) == true)
}

@Test func deriveMyTurnEveryCombination() {
    for status in [Status.busy, .wait, .unknown] {
        for spool in [0, 1] {
            for prompt in [false, true] {
                #expect(deriveMyTurn(status: status, spool: spool, permissionPrompt: prompt)
                    == ((status == .wait && spool == 0) || prompt))
            }
        }
    }
}

let questionScreen = """
⏺ Bash(rm -rf build)

 Bash command
   rm -rf build
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for rm commands
   3. No, and tell Claude what to do differently
"""

let footerScreen = """
 Edit file src/app.js
 ❯ 1. Yes
   2. No

 Esc to cancel
"""

let trustScreen = """
 Do you trust the files in this folder?
 /tmp/example
 ❯ 1. Yes, proceed
   2. No, exit
"""

@Test func permissionPromptInDetectsToolAndTrustModals() {
    #expect(permissionPromptIn(questionScreen))
    #expect(permissionPromptIn(footerScreen))
    #expect(permissionPromptIn(trustScreen))
    #expect(!permissionPromptIn("❯ \n  ? for shortcuts"))
    #expect(!permissionPromptIn("Do you want to proceed? I asked earlier."))
    #expect(!permissionPromptIn(""))
    #expect(!permissionPromptIn(nil))
}

func session(handle: String = "pid:1", status: Status = .busy, myTurn: Bool = false, permissionPrompt: Bool = false) -> Session {
    Session(handle: handle, agent: .claude, pid: 1, cwd: "", startedAt: nil, status: status, myTurn: myTurn, since: nil,
            permissionPrompt: permissionPrompt, title: "", tmux: nil, transcript: nil, lastUser: "", lastAssistant: "",
            termProgram: nil)
}

@Test func applyPermissionPromptForcesWaitAndMyTurnOnlyWhenAModalIsUp() {
    let s = session()
    var want = s
    want.status = .wait
    want.myTurn = true
    want.permissionPrompt = true
    #expect(applyPermissionPrompt(s, captured: questionScreen) == want)
    #expect(applyPermissionPrompt(s, captured: "❯ ") == s)
    #expect(applyPermissionPrompt(session(permissionPrompt: true), captured: "") == s)
}

private func json(_ text: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
}

@Test func extractTextHandlesClaudeAndCodexShapes() {
    #expect(extractText(json(#"{"type":"user","message":{"content":"hi"}}"#), agent: .claude) == Message(role: .user, text: "hi"))
    #expect(extractText(json(#"{"type":"assistant","message":{"content":[{"type":"text","text":"a"},{"type":"tool_use"},{"type":"text","text":"b"}]}}"#), agent: .claude)
        == Message(role: .assistant, text: "a\nb"))
    #expect(extractText(json(#"{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}"#), agent: .claude) == nil)
    #expect(extractText(json(#"{"type":"user","isMeta":true,"message":{"content":"x"}}"#), agent: .claude) == nil)
    #expect(extractText(json(#"{"type":"assistant","isSidechain":true,"message":{"content":"x"}}"#), agent: .claude) == nil)
    #expect(extractText(json(#"{"type":"user","message":{"content":"<system-reminder>x"}}"#), agent: .claude) == nil)
    #expect(extractText(json(#"{"type":"summary"}"#), agent: .claude) == nil)

    func codex(_ role: String, _ type: String, _ text: String) -> [String: Any] {
        ["type": "response_item", "payload": ["type": "message", "role": role, "content": [["type": type, "text": text]]]]
    }
    #expect(extractText(codex("user", "input_text", "go"), agent: .codex) == Message(role: .user, text: "go"))
    #expect(extractText(codex("assistant", "output_text", "done"), agent: .codex) == Message(role: .assistant, text: "done"))
    #expect(extractText(codex("user", "input_text", "# AGENTS.md instructions"), agent: .codex) == nil)
    #expect(extractText(codex("user", "input_text", "<environment_context>"), agent: .codex) == nil)
    #expect(extractText(codex("developer", "input_text", "sys"), agent: .codex) == nil)
    #expect(extractText(json(#"{"type":"event_msg","payload":{"type":"agent_message","message":"x"}}"#), agent: .codex) == nil)
}

@Test func lastMessagesReadsTheClaudeFixture() {
    #expect(lastMessages(fixtures.appending(path: "transcripts/claude-basic.jsonl").path, agent: .claude)
        == LastMessages(lastUser: "Please add a health check endpoint.", lastAssistant: "Added GET /health returning 200."))
}

@Test func lastMessagesReadsTheCodexFixture() {
    #expect(lastMessages(fixtures.appending(path: "transcripts/codex-basic.jsonl").path, agent: .codex)
        == LastMessages(lastUser: "Rename the config loader.", lastAssistant: "Renamed loadConfig to readConfig."))
}

@Test func lastMessagesReturnsEmptyStringsForMissingOrNilPaths() {
    #expect(lastMessages(nil, agent: .claude) == LastMessages())
    #expect(lastMessages(fixtures.appending(path: "transcripts/nope.jsonl").path, agent: .claude) == LastMessages())
}

@Test func lastMessagesReadsOnlyThe200KBTailAndTruncatesTo300Chars() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "ct-status-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func rec(_ type: String, _ text: String) -> String {
        #"{"type":"\#(type)","isSidechain":false,"message":{"role":"\#(type)","content":[{"type":"text","text":"\#(text)"}]}}"#
    }
    // old records that would win if the reader looked past the tail window
    let head = [rec("user", "OLD user"), rec("assistant", "OLD assistant")]
    let filler = (0..<3000).map { #"{"type":"progress","i":\#($0),"pad":"\#(String(repeating: "x", count: 100))"}"# }
    let lines = head + filler + [rec("user", String(repeating: "y", count: 1000))] + filler.prefix(10)
    let path = dir.appending(path: "big.jsonl").path
    try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)

    let got = lastMessages(path, agent: .claude)
    #expect(got.lastUser.utf16.count == 300)
    #expect(got.lastUser.hasSuffix("…"))
    #expect(got.lastAssistant == "") // only beyond the 200KB window
}

@Test func clipNeverSplitsASurrogatePair() {
    let text = String(repeating: "a", count: 298) + "😀" + "tail"
    let got = clip(text)
    #expect(got == String(repeating: "a", count: 298) + "…")
}

@Test func trustPromptTextQuotedInScrollbackIsNotAPrompt() {
    let quoted = ([
        "⏺ Write(test/status.test.js)",
        "  42 const TRUST_SCREEN = [",
        "  43   ' Do you trust the files in this folder?',",
        "  45   ' ❯ 1. Yes, proceed',",
    ] + (0..<20).map { "  line \($0)" } + ["❯ ", "  ? for shortcuts"]).joined(separator: "\n")
    #expect(!permissionPromptIn(quoted))
}
