import AppKit
import Observation
import TowerCore

/// The one collection loop. Menu bar and board window read the same `board`.
@MainActor @Observable
final class Tower {
    private(set) var board: Board?
    /// Why the board has no teams, when my-team failed. A GUI app's stderr is invisible.
    private(set) var myTeamError: String?
    /// Past sessions, newest first. Its own loop: the first scan takes 2-3 s and must not delay the board.
    private(set) var history: [HistorySession] = []
    /// A row the dropdown asked the board to select; the board takes it, open already or opening now.
    var boardSelectRequest: RowID?
    /// Launch or reopen asked for the board window; the menu bar label opens it and clears this.
    var boardOpenRequested = false
    @ObservationIgnored private var notifier: Notifier?

    init() {
        notifier = Notifier { [weak self] in self?.focus($0) }
        // Lives as long as the app.
        Task {
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        Task {
            while true {
                guard let board else {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                history = await Task.detached { await collectHistory(board: board) }.value
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func refresh() async {
        // collect blocks for about a second; keep it off the main actor.
        let snap = await Task.detached { await collectSnapshot() }.value
        let next = snap.board
        myTeamError = snap.myTeamError
        for s in newlyMyTurn(prev: board, next: next) {
            notifier?.post(s, title: displayTitle(s, in: next))
        }
        board = next
    }

    var myTurn: Int { board.map(myTurnCount) ?? 0 }

    /// Moves focus to `handle`. Failures surface as an alert; the app never crashes on them.
    func focus(_ handle: String) {
        guard let board else { return }
        Task {
            do {
                let clients = await Task.detached { listClients() }.value
                let plan = planFocus(handle: handle, board: board, clients: clients)
                guard plan.kind != .none else { throw FocusError.unreachable(handle) }
                // ponytail: only Ghostty is narrowed to a tab; other terminals and the detached path raise the app as before.
                guard plan.commands.last == ["open", "-a", "Ghostty"],
                      let s = sessions(board).first(where: { $0.handle == handle }) else {
                    return try await FocusRunner.run(plan.commands)
                }
                try await FocusRunner.run(plan.commands.dropLast())
                let title = s.transcript.flatMap { t in history.first { $0.transcriptPath == t }?.title }
                let tmuxSession = plan.kind == .attached ? s.tmux?.session : nil
                // Denied Automation, an old Ghostty or no single match: skip the tab and just raise the app.
                if let id = await Task.detached(operation: { listGhosttyTerminals() }).value
                    .flatMap({ pickTerminal($0, tmuxSession: tmuxSession, title: title, cwd: s.cwd) }) {
                    try? await FocusRunner.run([ghosttyFocusArgv(id)])
                }
                try await FocusRunner.run([["open", "-a", "Ghostty"]])
            } catch {
                showAlert("세션으로 이동하지 못함", error)
            }
        }
    }

    /// Double click on a history row: focus the running session that reads it, else resume it in a new Ghostty window.
    func open(_ h: HistorySession) {
        if let s = sessions(board ?? Board(at: "", teams: [], loose: [])).first(where: { $0.transcript == h.transcriptPath }) {
            focus(s.handle)
            return
        }
        var ended = h
        ended.live = false
        Task {
            do {
                guard let argv = planResume(ended) else { throw FocusError.noWorkspace(h.workspace) }
                try await FocusRunner.run([argv])
            } catch {
                showAlert("세션을 resume하지 못함", error)
            }
        }
    }

    /// Opens a terminal where Claude writes a new team's config in `~/teams` with the user and starts it.
    func newTeam() {
        run("새 팀 터미널을 열지 못함", [planTerminal(in: teamsDir, commandLine: shellCommandLine([resumeBins[.claude] ?? "claude", newTeamPrompt]))])
    }

    /// Opens a terminal that starts one run of a stopped team again, each claude worker resuming its last session.
    func resumeTeam(_ teamRun: TeamRun) {
        let runs = teamRuns(history)
        let sessions = history.filter { runs[$0.transcriptPath] == teamRun }
        guard let base = teamBase(teamRun.team),
              let data = try? JSONSerialization.data(withJSONObject: resumeConfig(base, run: sessions),
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return showAlert("팀을 이어서 띄우지 못함", TeamLaunchError.noConfig(teamRun.team)) }
        let command = resumeTeamCommand(team: teamRun.team, config: String(decoding: data, as: UTF8.self),
                                        path: "\(teamsDir)/\(teamRun.team).resume.json", myTeam: myTeamBin, tmux: towerTmuxBin)
        run("팀을 이어서 띄우지 못함", [planTerminal(in: teamsDir, commandLine: shellCommandLine(command))])
    }

    private func run(_ failure: String, _ argvs: [[String]]) {
        Task {
            do { try await FocusRunner.run(argvs) } catch { showAlert(failure, error) }
        }
    }

    private func showAlert(_ title: String, _ error: any Error) {
        NSApp.activate()
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

enum FocusError: LocalizedError {
    case unreachable(String)
    case noWorkspace(String)
    var errorDescription: String? {
        switch self {
        case .unreachable(let h): "\(h)이(가) 보드에 없거나 앞으로 가져올 터미널이 없습니다."
        case .noWorkspace(let w): "resume할 수 없음: 세션의 워크스페이스가 없습니다(\(w))."
        }
    }
}

/// `team / worker` for a team worker, the card name otherwise.
func displayTitle(_ s: Session, in board: Board) -> String {
    for t in board.teams {
        if let w = t.workers.first(where: { $0.handle == s.handle }) { return "\(t.name) / \(w.cardName)" }
    }
    return s.cardName
}

func sessions(_ b: Board) -> [Session] {
    b.teams.flatMap { $0.workers.map(\.session) } + b.loose
}

extension Session {
    /// A list id unique across teams and loose. A handle alone repeats when two processes
    /// claim one pane; a pid alone repeats as 0 for workers with no recognized process.
    var rowID: String { "\(handle)#\(pid)" }
}
