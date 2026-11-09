import Foundation

// Read-only tmux access. Nothing here may select, send keys to, or kill anything.

let paneFormat = [
    "#{session_name}", "#{window_id}", "#{pane_id}", "#{pane_pid}", "#{pane_dead}",
    "#{@worker_name}", "#{pane_title}", "#{pane_current_path}",
].joined(separator: "\t")

let clientFormat = "#{client_session}\t#{client_pid}\t#{client_tty}"

struct Pane: Decodable, Hashable {
    var session: String
    var window: String
    var pane: String
    var pid: Int
    var dead: Bool
    var workerName: String?
    var title: String
    var cwd: String
}

/// An attached tmux client; a session with one is focused in place instead of opening a new window.
public struct TmuxClient: Codable, Hashable, Sendable {
    public var session: String
    public var pid: Int
    public var tty: String

    public init(session: String, pid: Int, tty: String) {
        self.session = session
        self.pid = pid
        self.tty = tty
    }
}

private func fields(_ text: String) -> [[String]] {
    text.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
}

func parsePanes(_ text: String) -> [Pane] {
    fields(text).map { f in
        let at = { (i: Int) in i < f.count ? f[i] : "" }
        return Pane(
            session: at(0), window: at(1), pane: at(2), pid: Int(at(3)) ?? 0, dead: at(4) == "1",
            workerName: at(5).nonEmpty,
            // title is the only free-text field; rejoin in case it contains a tab
            title: f.count > 7 ? f[6..<(f.count - 1)].joined(separator: "\t") : "",
            cwd: f.last ?? ""
        )
    }
}

func parseClients(_ text: String) -> [TmuxClient] {
    fields(text).map { f in
        TmuxClient(session: f[0], pid: f.count > 1 ? Int(f[1]) ?? 0 : 0, tty: f.count > 2 ? f[2] : "")
    }
}

/// '' when there is no tmux binary, no server, or the command fails.
private func tmux(_ args: [String]) -> String {
    guard let r = try? runCommand(["tmux"] + args, timeout: 2), r.status == 0 else { return "" }
    return r.stdout
}

func listPanes() -> [Pane] {
    parsePanes(tmux(["list-panes", "-a", "-F", paneFormat]))
}

public func listClients() -> [TmuxClient] {
    parseClients(tmux(["list-clients", "-F", clientFormat]))
}

func capturePane(_ pane: String, lines: Int = 40) -> String {
    tmux(["capture-pane", "-p", "-S", "-\(lines)", "-t", pane])
}
