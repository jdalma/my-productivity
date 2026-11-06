import Foundation

/// The argv lists that move focus to a session, run in order by the caller.
/// TowerCore only plans; it never executes these (nor planResume's).
public struct FocusPlan: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// tmux session with an attached client: select the pane, raise Ghostty.
        case attached
        /// tmux session nobody is attached to: select the pane, open a Ghostty window running `tmux attach`.
        case detached
        /// outside tmux: raise its terminal app.
        case outside
        case none
    }

    public var kind: Kind
    public var commands: [[String]]

    public init(kind: Kind, commands: [[String]]) {
        self.kind = kind
        self.commands = commands
    }

    public static let none = FocusPlan(kind: .none, commands: [])
}

/// A Ghostty window opened via `open` gets launchd's PATH (no /opt/homebrew/bin),
/// so the attach command needs tmux's absolute path.
public let towerTmuxBin = resolveExecutable("tmux") ?? "tmux"
/// Same for `my-team`, run in a terminal the board opens to start a team.
public let myTeamBin = resolveExecutable("my-team") ?? "my-team"

private let terminalApps = [
    "ghostty": "Ghostty",
    "iTerm.app": "iTerm",
    "Apple_Terminal": "Terminal",
    "WezTerm": "WezTerm",
    "vscode": "Visual Studio Code",
    "WarpTerminal": "Warp",
]

public func planFocus(handle: String, board: Board, clients: [TmuxClient],
                      ghosttyApp: String = "Ghostty", tmuxBin: String = towerTmuxBin) -> FocusPlan {
    let all = board.teams.flatMap { $0.workers.map(\.session) } + board.loose
    guard let s = all.first(where: { $0.handle == handle }) else { return .none }

    if handle.hasPrefix("pid:") {
        guard let app = s.termProgram.flatMap({ terminalApps[$0] }) else { return .none }
        return FocusPlan(kind: .outside, commands: [["open", "-a", app]])
    }

    guard let t = s.tmux, !t.window.isEmpty else { return .none }
    let tmux = [
        ["tmux", "select-window", "-t", "\(t.session):\(t.window)"],
        ["tmux", "select-pane", "-t", t.pane],
    ]
    if clients.contains(where: { $0.session == t.session }) {
        return FocusPlan(kind: .attached, commands: tmux + [["open", "-a", ghosttyApp]])
    }
    // `direct:` splits on spaces; a session name with one is only raised, not attached
    guard !(tmuxBin + t.session).contains(where: \.isWhitespace) else {
        return FocusPlan(kind: .detached, commands: tmux + [["open", "-a", ghosttyApp]])
    }
    return FocusPlan(kind: .detached, commands: tmux + [
        planTerminal(in: homeDir, commandLine: "direct:\(tmuxBin) attach -t \(t.session)", ghosttyApp: ghosttyApp,
                     keepOpen: false),
    ])
}

/// `claude` usually lives in `~/.local/bin`, which a GUI app's PATH lacks.
public let resumeBins: [AgentKind: String] = [
    .claude: resolveExecutable("claude", in: searchPath + ["\(homeDir)/.local/bin"]) ?? "claude",
    .codex: resolveExecutable("codex") ?? "codex",
]

/// Our child PATH. A Ghostty window opened via `open` gets launchd's, which lacks the `node` that
/// `codex` (`#!/usr/bin/env node`) and Claude's MCP servers need.
public let resumePath = childEnvironment(base: ProcessInfo.processInfo.environment, extra: [:])["PATH"] ?? ""

/// The argv that opens a new Ghostty window in the session's workspace and resumes it there,
/// through `/usr/bin/env PATH=…` so no shell is involved.
/// nil for a live session (resuming would start a second process on it) or one without a workspace.
public func planResume(_ s: HistorySession, ghosttyApp: String = "Ghostty",
                       bins: [AgentKind: String] = resumeBins, path: String = resumePath) -> [String]? {
    guard !s.live, !s.workspace.isEmpty, let program = s.resumeCommand.first else { return nil }
    let argv = [bins[s.agent] ?? program] + s.resumeCommand.dropFirst()
    // `direct:` runs the argv without a shell, split on spaces, so an argument may not hold one
    guard !argv.contains(where: { $0.contains(where: \.isWhitespace) }) else { return nil }
    return planTerminal(in: s.workspace, commandLine: "direct:" + argv.joined(separator: " "),
                        ghosttyApp: ghosttyApp, path: path)
}

/// The argv that opens a new Ghostty window in `cwd` running `commandLine` (Ghostty's `command` syntax) with our
/// PATH; with `keepOpen` the window stays when the command ends, so a failure stays readable. Through Ghostty's AppleScript:
/// Ghostty 1.3 takes `open --args -e <argv>` as files to open, one window each. The values reach the script as
/// `argv`, never as script text.
public func planTerminal(in cwd: String, commandLine: String, ghosttyApp: String = "Ghostty",
                         path: String = resumePath, keepOpen: Bool = true) -> [String] {
    ["osascript", "-e", "on run argv", "-e", "tell application \"\(ghosttyApp)\"",
     "-e", "new window with configuration {initial working directory:(item 1 of argv), command:(item 2 of argv), "
         + "environment variables:{item 3 of argv}, wait after command:\(keepOpen)}",
     "-e", "activate", "-e", "end tell", "-e", "end run",
     cwd, commandLine, "PATH=\(path)"]
}

/// One Ghostty terminal (a tab or a split) as its AppleScript dictionary reports it.
public struct GhosttyTerminal: Equatable, Sendable {
    public var id: String
    public var name: String
    public var cwd: String

    public init(id: String, name: String, cwd: String) {
        self.id = id
        self.name = name
        self.cwd = cwd
    }
}

/// Reads every terminal's id, name and working directory, one tab-separated line each.
/// Only reads properties; the one thing sent to a terminal is planFocus's `focus`.
private let listTerminalsScript = """
tell application "Ghostty" to set {ids, names, dirs} to {id, name, working directory} of every terminal
set out to {}
repeat with i from 1 to count of ids
    set end of out to (item i of ids as text) & tab & (item i of names as text) & tab & (item i of dirs as text)
end repeat
set AppleScript's text item delimiters to linefeed
out as text
"""

public func parseGhosttyTerminals(_ text: String) -> [GhosttyTerminal] {
    text.split(whereSeparator: \.isNewline).compactMap { line in
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        return f.count == 3 ? GhosttyTerminal(id: f[0], name: f[1], cwd: f[2]) : nil
    }
}

/// nil when Ghostty is not scriptable or Automation was denied; the caller then only raises the app.
/// The 30 s timeout covers the first-run Automation prompt.
public func listGhosttyTerminals() -> [GhosttyTerminal]? {
    guard let r = try? runCommand(["osascript", "-e", listTerminalsScript], timeout: 30), r.status == 0 else { return nil }
    return parseGhosttyTerminals(r.stdout)
}

/// The terminal a focus should land on, or nil when none or several match (raising the app beats a wrong tab).
/// A tmux client's tab is named after its command, `tmux attach -t <session>`, so match a tab naming tmux and the session as whole words.
/// Claude Code titles its tab `<status glyph> <session title>`; a tab in another known directory never matches,
/// and several such tabs narrow by working directory.
public func pickTerminal(_ terminals: [GhosttyTerminal], tmuxSession: String?, title: String?, cwd: String) -> String? {
    func only(_ ts: [GhosttyTerminal]) -> String? { ts.count == 1 ? ts[0].id : nil }
    if let tmuxSession {
        return only(terminals.filter {
            let words = $0.name.split(whereSeparator: \.isWhitespace)
            return words.contains("tmux") && words.contains { $0 == tmuxSession }
        })
    }
    guard let title, !title.isEmpty else { return nil }
    // A tab whose known directory differs is another session with the same title, even when it is the only one.
    let titled = terminals.filter { tabTitle($0.name) == title && ($0.cwd == cwd || $0.cwd.isEmpty || $0.cwd == "missing value") }
    return titled.count > 1 ? only(titled.filter { $0.cwd == cwd }) : only(titled)
}

/// Drops a leading one-character status glyph (`✳`, a braille spinner) that is not a letter or digit.
private func tabTitle(_ name: String) -> String {
    let parts = name.split(separator: " ", maxSplits: 1)
    guard parts.count == 2, parts[0].count == 1, let c = parts[0].first, !c.isLetter, !c.isNumber else { return name }
    return String(parts[1])
}

/// Selects the terminal's tab and brings its window to the front. The id travels as an argument, never as script text.
public func ghosttyFocusArgv(_ id: String) -> [String] {
    ["osascript", "-e", "on run argv", "-e", "tell application \"Ghostty\" to focus terminal id (item 1 of argv)", "-e", "end run", id]
}
