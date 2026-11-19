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
    /// Teams the board asked to start and has not seen running yet: their resume button waits.
    private(set) var launches = TeamLaunches()
    /// The 팀 종료 dialog and the teams being shut down.
    private(set) var shutdowns = TeamShutdowns()
    /// The team configs in `~/teams` the 팀 실행 menu offers, read with each collection.
    private(set) var teamConfigList = TeamConfigList()
    /// Task boards of the running teams that keep one (T70), read only while the board or a task board window is open.
    private(set) var taskBoards: [String: TaskBoardState] = [:]
    /// A failure the board window shows attached to itself, until it is dismissed.
    var failure: Failure?
    /// The task picked in each team's task board window (T70a, T86); their families are read with the boards.
    var taskPicks = TaskBoardPicks() {
        didSet { if taskPicks != oldValue { reloadTaskBoards() } }
    }
    /// The picked tasks' families, last read; one stays while a read of it fails.
    private(set) var taskFamilies: [TaskRef: TaskFamilyState] = [:]
    /// The windows on screen; BoardView, DiffWindow and TaskBoardWindow set it.
    var windows = OpenWindows() {
        didSet {
            if windows.board && !oldValue.board || !windows.taskBoards.isSubset(of: oldValue.taskBoards) { reloadTaskBoards() }
            OpenWindows.apply(windows.policy)
        }
    }
    @ObservationIgnored private var notifier: Notifier?
    @ObservationIgnored private var taskBoardReading = false
    /// When the boards were last read, for the slower reads while no window is open.
    @ObservationIgnored private var lastTaskBoardRead: Date?
    /// Every decision read since launch; a notification goes out for an open one not seen before (T147, T148).
    @ObservationIgnored private var seenDecisions = SeenDecisions()
    /// The usage dashboard's report, period and scroll position, kept while the board shows other screens.
    let usage = UsageDashboard()
    let diffTotals = WorkerDiffTotals()
    /// The dashboard's analysis and advice. The test instance never starts `claude`.
    let advisor = UsageAdvisor(defaults: .standard, store: UsageAdviceStore(), run: towerDryRun.map(dryAdviceRun) ?? claudeAdviceRun)

    init() {
        notifier = Notifier(onClick: { [weak self] in self?.focus($0) },
                            onDecision: { [weak self] team, id in self?.openDecision(team: team, id: id) })
        // Lives as long as the app.
        Task {
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        // 5 s: the open board within 10 s of the truth, every team's counts within 15 s (design §6 U1, U2)
        Task {
            while true {
                try? await Task.sleep(for: .seconds(5))
                reloadTaskBoards()
            }
        }
        Task {
            while true {
                await diffTotals.refresh()
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
        launches.settle(running: runningTeams(next), now: Date())
        shutdowns.settle(running: runningTeams(next))
        teamConfigList = await Task.detached { teamConfigs(in: teamsDir) }.value
    }

    var myTurn: Int { board.map { myTurnShown($0, taskBoards: taskBoardStatuses) } ?? 0 }

    /// Each team's last good board read.
    var taskBoardStatuses: [String: TaskBoardStatus] { taskBoards.compactMapValues(\.status) }

    /// A task board window asked for from outside a view (a notification click); the menu bar label opens it (T147).
    var taskBoardOpenRequest: TaskBoardTarget?

    /// Opens the team's task board window with the decision picked.
    func openDecision(team: String, id: String) {
        taskBoardOpenRequest = taskPicks.open(team, task: id)
    }

    /// Reads every task board now (⌘R, the timer, a window opening). With every window closed, at most every 15 s:
    /// a decision waiting for the user is in the menu bar and the notifications anyway (T147, D#1; was U3). Nothing
    /// when no running team keeps a task board: then my-team is never run.
    func reloadTaskBoards() {
        let now = Date()
        guard !taskBoardReading, let board,
              taskBoardReadDue(windowsOpen: windows.readsTaskBoards, last: lastTaskBoardRead, now: now) else { return }
        lastTaskBoardRead = now
        taskBoardReading = true
        let picked = taskPicks.reads(open: windows.taskBoards)
        Task {
            // the picked tasks first: a detail fills right after the click (U6), the lists follow
            var families: [TaskRef: TaskFamilyState] = [:]
            for ref in picked {
                let read = await Task.detached { readTaskFamily(team: ref.team, task: ref.task) }.value
                families[ref] = taskFamilies[ref].applying(read, to: ref)
            }
            taskFamilies = families
            let reads = await Task.detached { readTaskBoards(board) }.value
            let now = Date()
            var next = taskBoards.filter { reads[$0.key] != nil }
            for (team, read) in reads { next[team, default: TaskBoardState()].apply(read, at: now) }
            for w in decisionsToNotify(seen: &seenDecisions, next: next.compactMapValues(\.status)) { notifier?.post(w) }
            taskBoards = next
            forgetLeftPins(next.compactMapValues(\.status))
            taskBoardReading = false
            // picked or opened while this read ran: read those families now
            if taskPicks.reads(open: windows.taskBoards) != picked { reloadTaskBoards() }
        }
    }

    /// A task put on top of a panel is no longer on top once it has left that panel, whether or not its window is
    /// open at the time (v4 §7.9.3), so a task back later is not on top again.
    private func forgetLeftPins(_ statuses: [String: TaskBoardStatus]) {
        let stored = UserDefaults.standard.string(forKey: taskPanelPrefsKey) ?? ""
        var all = readPanelPrefs(stored)
        for (team, s) in statuses { all[team] = all[team]?.cleaned(taskPanels(s)) }
        let next = storedPanelPrefs(all)
        if !all.isEmpty, next != stored { UserDefaults.standard.set(next, forKey: taskPanelPrefsKey) }
    }

    /// Moves focus to `handle`. Failures surface as an alert or a notification; the app never crashes on them.
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
        let command = newTeamCommand(teams: teamsDir, claude: resumeBins[.claude] ?? "claude")
        // the window opens in the home folder; the command makes ~/teams and moves there
        run("새 팀 터미널을 열지 못함", [planTerminal(in: homeDirectory(), commandLine: shellCommandLine(command))])
    }

    /// Opens a terminal that starts one run of a stopped team again, each claude worker resuming its last session.
    func resumeTeam(_ teamRun: TeamRun) {
        guard launches.begin(teamRun.team, at: Date()) else { return }
        let runs = teamRuns(history)
        let sessions = history.filter { runs[$0.transcriptPath] == teamRun }
        guard let base = teamBase(teamRun.team),
              let data = try? JSONSerialization.data(withJSONObject: resumeConfig(base, run: sessions),
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else {
            launches.cancel(teamRun.team)
            return showAlert("팀을 이어서 띄우지 못함", TeamLaunchError.noConfig(teamRun.team))
        }
        let command = resumeTeamCommand(team: teamRun.team, config: String(decoding: data, as: UTF8.self),
                                        path: "\(teamsDir)/\(teamRun.team).resume.json", myTeam: myTeamBin, tmux: towerTmuxBin)
        run("팀을 이어서 띄우지 못함", [planTerminal(in: teamsDir, commandLine: shellCommandLine(command))]) { [weak self] in
            self?.launches.cancel(teamRun.team)
        }
    }

    /// 팀 실행: a team with a stopped run in the history comes back as that run, each worker resuming its last
    /// conversation; one with none starts from `config` with `--continue` (T208). Either way a terminal attaches to it.
    func launchTeam(_ config: TeamConfig) {
        if case .resume(let run) = launchPlan(config, last: lastRuns(history)) { return resumeTeam(run) }
        guard launches.begin(config.team, at: Date()) else { return }
        let command = launchTeamCommand(team: config.team, path: config.path, myTeam: myTeamBin, tmux: towerTmuxBin)
        run("“\(config.team)” 팀을 띄우지 못함", [planTerminal(in: teamsDir, commandLine: shellCommandLine(command))]) { [weak self] in
            self?.launches.cancel(config.team)
        }
    }

    /// Opens the 팀 종료 confirmation for `team`; nothing is shut down until it is confirmed.
    func askShutdown(_ team: String) { _ = shutdowns.ask(team) }

    /// The dialog closed, by a button or another way.
    func closeShutdown() { shutdowns.close() }

    func cancelShutdown() { shutdowns.cancel() }

    /// The confirmed team's `my-team shutdown`, in the background with no terminal; stderr shows on failure.
    func confirmShutdown(_ team: String) {
        guard shutdowns.confirm(team) else { return }
        Task {
            do { try await FocusRunner.run([shutdownTeamArgv(team: team, myTeam: myTeamBin)], env: myTeamEnvironment(),
                                           timeout: shutdownTimeout) } catch {
                shutdowns.failed(team)
                show(shutdownFailure(team: team, error))
            }
        }
    }

    /// Opens `~/teams` in Finder.
    func openTeamsFolder() { run("~/teams 폴더를 열지 못함", [["open", teamsDir]]) }

    private func run(_ failure: String, _ argvs: [[String]], onFailure: @escaping () -> Void = {}) {
        Task {
            do { try await FocusRunner.run(argvs) } catch {
                onFailure()
                showAlert(failure, error)
            }
        }
    }

    /// Never brings the app forward: a failed move to a terminal leaves the keyboard where the user is (T75).
    private func showAlert(_ title: String, _ error: any Error) {
        show(Failure(title: title, reason: error.localizedDescription))
    }

    private func show(_ failure: Failure) {
        switch failureRoute(windows) {
        case .sheet: self.failure = failure
        case .notification: notifier?.post(failure)
        }
    }
}

/// The board, diff and task board windows on screen (T73, T86). While any is open the app is a regular one, in the
/// Dock and ⌘Tab with a main menu; with none it is the menu bar icon alone, as Info.plist's LSUIElement starts it.
struct OpenWindows: Equatable {
    var board = false
    var diffs: Set<DiffTarget> = []
    /// Teams whose task board window is open.
    var taskBoards: Set<String> = []
    /// The board window has the keyboard: the user is looking at it.
    var boardKey = false

    var policy: NSApplication.ActivationPolicy { board || !diffs.isEmpty || !taskBoards.isEmpty ? .regular : .accessory }

    /// The sidebar's 작업판 counts and the task board windows need the boards read; nothing else does.
    var readsTaskBoards: Bool { board || !taskBoards.isEmpty }

    /// A test instance stays an accessory. Measured (T103): with `.canJoinAllSpaces` and `.fullScreenAuxiliary` its
    /// windows stayed off another app's full screen Space while the app was regular, and showed as an accessory.
    static func applied(_ policy: NSApplication.ActivationPolicy, test: Bool = testInstanceWindows != nil) -> NSApplication.ActivationPolicy {
        test ? .accessory : policy
    }

    @MainActor static func apply(_ policy: NSApplication.ActivationPolicy) {
        let policy = applied(policy)
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// Opens a window from the menu bar: regular first, then activated, so the menu bar shows the app's menus
    /// at once; the window's appearing alone would switch only after it is up.
    @MainActor static func show(activates: Bool = testInstanceWindows == nil, _ open: () -> Void) {
        apply(.regular)
        open()
        if activates { NSApp.activate() }
    }
}

/// What did not work, and why.
struct Failure: Equatable {
    var title: String
    var reason: String
}

/// How often the task boards are read while no board or task board window is open (T147, D#1).
let closedTaskBoardInterval: TimeInterval = 15

/// Whether to read the task boards now: whenever a window that shows them is open (every 5 s, and at once on ⌘R or
/// a pick); with none open, once `closedTaskBoardInterval` has passed since the last read.
func taskBoardReadDue(windowsOpen: Bool, last: Date?, now: Date) -> Bool {
    windowsOpen || last.map { now.timeIntervalSince($0) >= closedTaskBoardInterval } ?? true
}

enum FailureRoute { case sheet, notification }

/// On the board window while it is the key window, where the user is looking; in Notification Center otherwise,
/// the board behind another app or closed (T75 R4 L1).
func failureRoute(_ windows: OpenWindows) -> FailureRoute { windows.board && windows.boardKey ? .sheet : .notification }

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

/// A task on one team's board.
struct TaskRef: Hashable {
    var team: String
    var task: String
}

/// The picked task's family over reads: the last answer stays when a read fails.
struct TaskFamilyState: Equatable {
    var ref: TaskRef
    var family: TaskFamily?
    var failure: TaskBoardFailure?
}

extension Optional where Wrapped == TaskFamilyState {
    func applying(_ read: Result<TaskFamily, TaskBoardFailure>, to ref: TaskRef) -> TaskFamilyState {
        var s = self ?? TaskFamilyState(ref: ref)
        switch read {
        case .success(let f): s.family = f; s.failure = nil
        case .failure(let e): s.failure = e
        }
        return s
    }
}
