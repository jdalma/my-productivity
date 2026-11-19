import Foundation
import TowerCore

// Starting a my-team team from the board, in a new Ghostty window: a new team that Claude writes with the user,
// or a stopped one (after a reboot, say) with each worker back in its last session.
// The board itself writes no file: the terminal it opens does, in front of the user.

let teamsDir = homeDirectory() + "/teams"

/// The config that starts one run of a team again: its workers as that run had them, each with what `base` (the
/// team's config) gives it, else its agent and folder; each claude worker resuming its last ended session with
/// `--resume <id>`, which my-team uses for that one launch and keeps out of the team's manifest. Codex workers start
/// afresh: my-team passes launch args to codex as options, and its resume is a subcommand.
func resumeConfig(_ base: [String: Any], run: [HistorySession]) -> [String: Any] {
    var newest: [String: HistorySession] = [:]
    for h in run {
        guard let name = h.member?.worker else { continue }
        if let seen = newest[name], (parseISO(seen.updatedAt) ?? 0) >= (parseISO(h.updatedAt) ?? 0) { continue }
        newest[name] = h
    }
    let configured = (base["workers"] as? [[String: Any]] ?? []).filter { ($0["name"] as? String).map { newest[$0] != nil } ?? false }
    let named = Set(configured.compactMap { $0["name"] as? String })
    let added = newest.keys.filter { !named.contains($0) }.sorted().map { name -> [String: Any] in
        ["name": name, "agent_type": newest[name]!.agent.rawValue, "cwd": newest[name]!.workspace]
    }
    var config = base
    config["workers"] = (configured + added).map { worker in
        guard worker["agent_type"] as? String == "claude", let name = worker["name"] as? String,
              let last = newest[name], !last.live, last.agent == .claude else { return worker }
        var args = worker["launch_args"] as? [String] ?? []
        if let i = args.firstIndex(of: "--resume") { args.removeSubrange(i...min(i + 1, args.count - 1)) }
        var w = worker
        w["launch_args"] = args + ["--resume", last.id]
        return w
    }
    return config
}

/// The config in `dir` that names `team`, the newest if several do. The `.resume.json` the board wrote last time
/// is never the base: it carries old session ids.
func teamConfigPath(named team: String, in dir: String) -> String? {
    let fm = FileManager.default
    let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
    return files
        .filter { $0.hasSuffix(".json") && !$0.hasSuffix(".resume.json") }
        .map { "\(dir)/\($0)" }
        .filter { path in
            let json = fm.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            return json?["team_name"] as? String == team
        }
        .max { modified($0) < modified($1) }
}

private func modified(_ path: String) -> Date {
    (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
}

/// Writes the config, starts the team with `--continue` (its mail, work files and events as the last run left
/// them), and attaches this terminal to the team's tmux session. A team that already
/// runs (a second click, or one from before the board restarted) is only attached: two `my-team start` of one team
/// race and leave a tmux session no manifest names. A session name that cannot be read stops it: `attach -t ""`
/// would attach to the most recent session, another team's (R48). On a failure the window stays open until Enter.
func resumeTeamCommand(team: String, config: String, path: String, myTeam: String, tmux: String) -> [String] {
    let script = """
        alive=$("$3" status --team "$5" --json 2>/dev/null | plutil -extract team_alive raw -o - - 2>/dev/null)
        if [ "$alive" = true ]; then echo '이미 실행 중인 팀입니다. 그 세션에 붙습니다.'
        else mkdir -p "$(dirname "$2")" && printf '%s\\n' "$1" > "$2" && "$3" start --continue --config "$2" \
            || { echo; echo '팀을 띄우지 못했습니다. Enter로 닫기'; read -r _; exit 1; }
        fi
        s=$("$3" status --team "$5" --json 2>/dev/null | plutil -extract session raw -o - - 2>/dev/null)
        [ -n "$s" ] || { echo; echo '팀의 tmux 세션을 찾지 못해 붙지 않습니다. Enter로 닫기'; read -r _; exit 1; }
        exec "$4" attach -t "$s"
        """
    return ["/bin/sh", "-c", script, "sh", config, path, myTeam, tmux, team]
}

/// The teams the board has asked to start and not yet seen running. One click starts a team; another click on it
/// does nothing until the board sees it run, or `wait` passes (my-team waits up to 30 s for its panes).
struct TeamLaunches {
    static let wait: TimeInterval = 120
    private var started: [String: Date] = [:]

    func pending(_ team: String) -> Bool { started[team] != nil }

    /// false while `team` is already being started.
    mutating func begin(_ team: String, at now: Date) -> Bool {
        guard started[team] == nil else { return false }
        started[team] = now
        return true
    }

    mutating func cancel(_ team: String) { started[team] = nil }

    /// The teams being started, by name.
    var teams: [String] { started.keys.sorted() }

    /// Drops the teams that run now and the ones that never came up in time.
    mutating func settle(running: Set<String>, now: Date) {
        started = started.filter { team, at in !running.contains(team) && now.timeIntervalSince(at) < Self.wait }
    }
}

/// The new-team terminal's command: makes `teams` when the machine has none yet, and starts Claude in it.
func newTeamCommand(teams: String, claude: String) -> [String] {
    ["/bin/sh", "-c", #"mkdir -p "$1" && cd "$1" && exec "$2" "$3""#, "sh", teams, claude, newTeamPrompt]
}

/// What Claude is asked first in a new-team terminal.
let newTeamPrompt = """
    ~/teams 에 my-team 팀을 새로 만들고 띄운다. 먼저 나에게 팀의 목적, 필요한 워커(이름·역할·작업 폴더·할 일)를 묻는다. \
    답을 들으면 my-team 스킬의 config 형식으로 ~/teams/<team_name>.json 을 쓴다. 기존 ~/teams/*.json 을 참고하되 \
    보드가 이어 띄우기용으로 쓴 *.resume.json 은 옛 세션 id가 들어 있으니 참고하지 않고, \
    같은 git 저장소를 고치는 워커가 둘 이상이면 워커마다 `git worktree add <저장소>/.worktrees/<워커> -b <team>/<워커>` 로 \
    worktree를 만들어 그 폴더를 cwd로 쓴다(읽기만 하는 워커는 원래 폴더를 써도 된다). \
    같은 이름의 파일이 있으면 덮어쓰기 전에 묻는다. 내가 확인하면 `my-team start --config <그 파일>` 로 띄운다. \
    띄운 뒤에는 Control Tower 보드에서 그 팀이 보이고, 워커를 더블 클릭하면 터미널로 간다고 알려 준다.
    """

/// The config a stopped team starts from. Its workers are the ones its last run had (the manifest keeps workers
/// added or removed mid-run), each with the brief and settings its `~/teams` config gives it; with no manifest,
/// the config alone. The manifest lacks the briefs, but a resumed worker has its own in its conversation.
func teamBase(_ team: String, teams: String = teamsDir,
              stateBase: String = homeDirectory() + "/.my-team/sessions") -> [String: Any]? {
    func read(_ path: String) -> [String: Any]? {
        FileManager.default.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    }
    let config = teamConfigPath(named: team, in: teams).flatMap(read)
    guard let manifest = read("\(stateBase)/\(team)/manifest.json") else { return config }
    let configured = Dictionary((config?["workers"] as? [[String: Any]] ?? []).compactMap { w in
        (w["name"] as? String).map { ($0, w) }
    }, uniquingKeysWith: { a, _ in a })
    let keys: Set = ["name", "role", "agent_type", "cwd", "description", "launch_args"]
    var base = config ?? [:]
    base["team_name"] = team
    base["workers"] = (manifest["workers"] as? [[String: Any]] ?? []).map { ran in
        let name = ran["name"] as? String ?? ""
        return (configured[name] ?? [:]).merging(ran.filter { keys.contains($0.key) }) { _, last in last }
    }
    return base
}

enum TeamLaunchError: LocalizedError {
    case noConfig(String)

    var errorDescription: String? {
        switch self {
        case .noConfig(let team): "~/teams 에 team_name이 \(team)인 config가 없고, my-team 기록(manifest)도 없습니다."
        }
    }
}

/// A team config in `~/teams` the 팀 실행 menu offers.
struct TeamConfig: Equatable {
    let team: String
    let path: String
    let workers: Int
    let modified: Date

    var file: String { (path as NSString).lastPathComponent }
}

/// A `.json` file in `~/teams` that is not offered, and why (T206 §2).
struct UnreadableConfig: Equatable {
    enum Reason: String { case notJSON = "JSON 아님", noTeamName = "team_name 없음", noWorkers = "workers 없음", denied = "읽기 권한 없음" }
    let file: String
    let reason: Reason
}

struct TeamConfigList: Equatable {
    var configs: [TeamConfig] = []
    var unreadable: [UnreadableConfig] = []
}

/// The team configs right in `dir`, one a team: the newest file that names it, as `teamConfigPath` picks. The
/// board's `.resume.json` and `.bak` copies are left out; any other `.json` file that is not a team config is listed
/// in `unreadable` with its reason.
func teamConfigs(in dir: String) -> TeamConfigList {
    let fm = FileManager.default
    var newest: [String: TeamConfig] = [:]
    var unreadable: [UnreadableConfig] = []
    for name in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted()
    where name.hasSuffix(".json") && !name.hasSuffix(".resume.json") && !name.contains(".bak") {
        let path = "\(dir)/\(name)"
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
        guard let data = fm.contents(atPath: path) else {
            unreadable.append(UnreadableConfig(file: name, reason: .denied)); continue
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            unreadable.append(UnreadableConfig(file: name, reason: .notJSON)); continue
        }
        guard let team = json["team_name"] as? String, !team.isEmpty else {
            unreadable.append(UnreadableConfig(file: name, reason: .noTeamName)); continue
        }
        guard let workers = json["workers"] as? [Any], !workers.isEmpty else {
            unreadable.append(UnreadableConfig(file: name, reason: .noWorkers)); continue
        }
        let config = TeamConfig(team: team, path: path, workers: workers.count, modified: modified(path))
        if let seen = newest[team], seen.modified >= config.modified { continue }
        newest[team] = config
    }
    return TeamConfigList(configs: newest.values.sorted { $0.team < $1.team }, unreadable: unreadable)
}

/// Starts the team in `path` with `--continue` (a team with no previous state starts new; one with state keeps its
/// mail and work files) and attaches this terminal to its tmux session, as `resumeTeamCommand` does, without
/// writing any file. A team that already runs is only attached.
func launchTeamCommand(team: String, path: String, myTeam: String, tmux: String) -> [String] {
    let script = """
        alive=$("$2" status --team "$4" --json 2>/dev/null | plutil -extract team_alive raw -o - - 2>/dev/null)
        if [ "$alive" = true ]; then echo '이미 실행 중인 팀입니다. 그 세션에 붙습니다.'
        else "$2" start --continue --config "$1" || { echo; echo '팀을 띄우지 못했습니다. Enter로 닫기'; read -r _; exit 1; }
        fi
        s=$("$2" status --team "$4" --json 2>/dev/null | plutil -extract session raw -o - - 2>/dev/null)
        [ -n "$s" ] || { echo; echo '팀의 tmux 세션을 찾지 못해 붙지 않습니다. Enter로 닫기'; read -r _; exit 1; }
        exec "$3" attach -t "$s"
        """
    return ["/bin/sh", "-c", script, "sh", path, myTeam, tmux, team]
}

/// `my-team shutdown` of one team, run without a shell.
func shutdownTeamArgv(team: String, myTeam: String) -> [String] { [myTeam, "shutdown", "--team", team] }

/// The 팀 종료 flow: a team is shut down only after the user confirmed the dialog `ask` opened, and once at a time.
struct TeamShutdowns {
    /// The team whose confirmation dialog is open.
    private(set) var asking: String?
    /// Teams being shut down: from the confirmation until the board no longer sees them run, or the command failed.
    private(set) var running: Set<String> = []

    /// false while `team` is being shut down already.
    mutating func ask(_ team: String) -> Bool {
        guard !running.contains(team) else { return false }
        asking = team
        return true
    }

    mutating func dismiss() { asking = nil }

    /// Whether `team`'s dialog was open and it is now being shut down.
    mutating func confirm(_ team: String) -> Bool {
        guard asking == team else { return false }
        asking = nil
        running.insert(team)
        return true
    }

    mutating func failed(_ team: String) { running.remove(team) }

    mutating func settle(running live: Set<String>) { running.formIntersection(live) }
}

/// A 팀 실행 menu line's second line: how big the team is, and its file, or why it cannot be picked now.
func launchItemSubtitle(_ config: TeamConfig, running: Bool, launching: Bool) -> String {
    "워커 \(config.workers) · " + (running ? "실행 중" : launching ? "띄우는 중" : config.file)
}

/// The 팀 종료 failure alert: my-team's last stderr line, or its exit code, then the command to try by hand.
func shutdownFailure(team: String, _ error: any Error) -> Failure {
    let said: String
    if let e = error as? CommandError {
        said = e.output.split(separator: "\n").last.map(String.init) ?? "my-team이 \(e.status)로 끝났습니다."
    } else {
        said = error.localizedDescription
    }
    return Failure(title: "“\(team)” 팀을 종료하지 못함",
                   reason: "\(said)\n터미널에서 my-team shutdown --team \(team) 을 직접 실행해 보세요.")
}

/// The 팀 종료 dialog's message (T206 §1): what ends at once and what stays.
func shutdownMessage(workers: Int) -> String {
    "워커 \(workers)개와 tmux 세션이 바로 끝나고, 응답 중인 워커는 중간에 멈춥니다. "
        + "작업판·메일·manifest는 남아 있어, 기록의 ‘이어서 실행’으로 다시 띄울 수 있습니다."
}
