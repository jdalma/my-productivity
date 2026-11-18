import Foundation

private let tailBytes = 200 * 1024
private let maxChars = 300

/// Idle with an empty spool, or a modal waiting on the user.
public func deriveMyTurn(status: Status, spool: Int = 0, permissionPrompt: Bool = false) -> Bool {
    (status == .wait && spool == 0) || permissionPrompt
}

/// The last 14 non-empty, trimmed lines: what is on screen, not what scrolled past.
private func screenTail(_ captured: String, stripCR: Bool) -> [String] {
    // split on scalars: as a Character, "\r\n" is one grapheme and matches neither "\n" nor "\r"
    let lines = captured.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line in String(String.UnicodeScalarView(stripCR ? line.filter { $0 != "\r" } : Array(line))).trimmed }
        .filter { !$0.isEmpty }
    return Array(lines.suffix(14))
}

/// Copy of `paneHasPermissionPrompt` in tools/my-team/src/lib/tmux-session.js, which stays Node.
func paneHasPermissionPrompt(_ captured: String) -> Bool {
    let tail = screenTail(captured, stripCR: true)
    let hasNumberedYes = tail.contains { $0.contains(#/^[❯>]?\s*1\.\s*Yes\b/#.ignoresCase()) }
    let hasNumberedNo = tail.contains { $0.contains(#/^\s*\d+\.\s*No\b/#.ignoresCase()) }
    guard hasNumberedYes && hasNumberedNo else { return false }
    let hasQuestion = tail.contains { $0.contains(#/Do you want to .+\?/#.ignoresCase()) }
    let hasFooter = tail.contains { $0.contains(#/Esc to cancel/#.ignoresCase()) }
    return hasQuestion || hasFooter
}

/// Claude Code's trust-folder dialog (startup, before any tool modal). The menu
/// item must start its own line, so a transcript that merely quotes the dialog
/// text in scrollback is not a prompt.
private func hasTrustPrompt(_ captured: String) -> Bool {
    let tail = screenTail(captured, stripCR: false)
    return tail.contains { $0.contains(#/^Do you trust the (files in this folder|contents of this directory)\?/#.ignoresCase()) }
        && tail.contains { $0.contains(#/^[❯>]?\s*1\.\s*Yes,\s*(proceed|continue)/#.ignoresCase()) }
}

public func permissionPromptIn(_ captured: String?) -> Bool {
    guard let captured, !captured.isEmpty else { return false }
    return paneHasPermissionPrompt(captured) || hasTrustPrompt(captured)
}

func applyPermissionPrompt(_ session: Session, captured: String) -> Session {
    var s = session
    s.permissionPrompt = permissionPromptIn(captured)
    if s.permissionPrompt {
        s.status = .wait
        s.myTurn = true
    }
    return s
}

struct Message: Equatable {
    enum Role: String { case user, assistant }
    var role: Role
    var text: String
}

private func joinText(_ blocks: Any?, types: Set<String>) -> String {
    if let s = blocks as? String { return s }
    guard let list = blocks as? [Any] else { return "" }
    return list.compactMap { b -> String? in
        guard let b = b as? [String: Any], let type = b["type"] as? String, types.contains(type) else { return nil }
        return b["text"] as? String
    }.joined(separator: "\n")
}

/// JSON `true`, not merely truthy: NSNumber(1) also casts to Bool.
private func isTrue(_ v: Any?) -> Bool {
    guard let n = v as? NSNumber else { return false }
    return CFGetTypeID(n) == CFBooleanGetTypeID() && n.boolValue
}

/// One transcript record → role and text, or nil when it carries no user-visible
/// text (tool calls/results, meta, sidechain, injected `<…>` blocks).
func extractText(_ record: [String: Any], agent: AgentKind) -> Message? {
    let roleName: String?
    let text: String
    switch agent {
    case .codex:
        guard record["type"] as? String == "response_item", let p = record["payload"] as? [String: Any],
              p["type"] as? String == "message" else { return nil }
        roleName = p["role"] as? String
        text = joinText(p["content"], types: ["input_text", "output_text", "text"]).trimmed
        if text.hasPrefix("# AGENTS.md") { return nil }
    case .claude:
        guard let type = record["type"] as? String, type == "user" || type == "assistant" else { return nil }
        if isTrue(record["isMeta"]) || isTrue(record["isSidechain"]) { return nil }
        roleName = type
        text = joinText((record["message"] as? [String: Any])?["content"], types: ["text"]).trimmed
    }
    guard let role = roleName.flatMap(Message.Role.init(rawValue:)), !text.isEmpty, !text.hasPrefix("<") else { return nil }
    return Message(role: role, text: text)
}

/// At most 300 UTF-16 units including the ellipsis; never splits a surrogate pair.
func clip(_ text: String) -> String {
    let units = Array(text.utf16)
    if units.count <= maxChars { return text }
    let cut = UTF16.isLeadSurrogate(units[maxChars - 2]) ? maxChars - 2 : maxChars - 1
    return String(decoding: units[..<cut], as: UTF16.self) + "…"
}

struct LastMessages: Equatable {
    var lastUser = ""
    var lastAssistant = ""
}

/// Lines of the last 200 KB, the first one dropped when it was cut.
private func tailLines(_ path: String) -> [Data]? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    guard let size = try? fh.seekToEnd() else { return nil }
    let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
    guard (try? fh.seek(toOffset: start)) != nil, let data = try? fh.readToEnd() ?? Data() else { return nil }
    var lines = data.split(separator: 10, omittingEmptySubsequences: false)
    if start > 0 { lines.removeFirst() }
    return lines.map { Data($0) }
}

func lastMessages(_ transcriptPath: String?, agent: AgentKind) -> LastMessages {
    var out = LastMessages()
    guard let transcriptPath, let lines = tailLines(transcriptPath) else { return out }
    for line in lines.reversed() where out.lastUser.isEmpty || out.lastAssistant.isEmpty {
        guard !line.isEmpty,
              let record = try? JSONSerialization.jsonObject(with: line, options: .fragmentsAllowed) as? [String: Any],
              let msg = extractText(record, agent: agent) else { continue }
        switch msg.role {
        case .user where out.lastUser.isEmpty: out.lastUser = clip(msg.text)
        case .assistant where out.lastAssistant.isEmpty: out.lastAssistant = clip(msg.text)
        default: break
        }
    }
    return out
}
