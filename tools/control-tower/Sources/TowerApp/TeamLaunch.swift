import Foundation
import TowerCore

// Starting a my-team team from the board, in a new Ghostty window: a new team that Claude writes with the user,
// or a stopped one (after a reboot, say) with each worker back in its last session.
// The board itself writes no file: the terminal it opens does, in front of the user.

let teamsDir = homeDirectory() + "/teams"

/// The config that starts one run of a team again: its workers as that run had them, each with what `base` (the
/// team's config) gives it, else its agent and folder; each claude worker resuming its last ended session with
/// `--resume <id>`, which my-team uses for that one launch and keeps out of the team's manifest. Codex workers start
/// afresh: my-team passes launch args to codex as options, and its resume is a subcommand. A worker whose folder is
/// gone (`folderIsGone`) is left out, and named in `gone`.
func resumeConfig(_ base: [String: Any], run: [HistorySession]) -> ResumeConfig {
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
    let all = configured + added
    var config = base
    config["workers"] = all.filter { !folderIsGone($0["cwd"]) }.map { worker in
        guard worker["agent_type"] as? String == "claude", let name = worker["name"] as? String,
              let last = newest[name], !last.live, last.agent == .claude else { return worker }
        var args = worker["launch_args"] as? [String] ?? []
        if let i = args.firstIndex(of: "--resume") { args.removeSubrange(i...min(i + 1, args.count - 1)) }
        var w = worker
        w["launch_args"] = args + ["--resume", last.id]
        return w
    }
    let gone = all.filter { folderIsGone($0["cwd"]) }
        .map { GoneWorker(name: $0["name"] as? String ?? "", cwd: $0["cwd"] as? String ?? "") }
    return ResumeConfig(config: config, gone: gone, roles: all.contains { $0["role"] is String })
}

/// A worker the resume left out: its folder is gone.
struct GoneWorker: Equatable {
    let name: String
    let cwd: String
}

/// The config a resume writes, and the workers it left out.
struct ResumeConfig {
    var config: [String: Any]
    var gone: [GoneWorker] = []
    /// A worker of the run, left out or not, declares a role: my-team then needs an orchestrator among the rest.
    var roles = false

    var workers: [[String: Any]] { config["workers"] as? [[String: Any]] ?? [] }

    /// What the user is told before the resume starts (T229, R15): nil when no worker was left out. `stops` when
    /// my-team start would refuse what is left: no worker (parser.js `workers must be a non-empty array`), or a
    /// role team whose every orchestrator was left out (parser.js `no 'orchestrator'`; without it the team would come
    /// up as peers when only the orchestrator declared a role); neither names the folder.
    func problem(team: String) -> (stops: Bool, failure: Failure)? {
        guard !gone.isEmpty else { return nil }
        let list = gone.map { "\($0.name) (\($0.cwd))" }.joined(separator: ", ")
        let isOrchestrator = { (w: [String: Any]) in w["role"] as? String == "orchestrator" }
        if workers.isEmpty {
            return (true, Failure(title: "“\(team)” 팀을 이어서 띄우지 못함",
                                  reason: "모든 워커의 작업 폴더가 없습니다: \(list)"))
        }
        if roles && !workers.contains(where: isOrchestrator) {
            return (true, Failure(title: "“\(team)” 팀을 이어서 띄우지 못함",
                                  reason: "orchestrator의 작업 폴더가 없어 역할 팀을 띄울 수 없습니다. 작업 폴더가 없는 워커: \(list)"))
        }
        return (false, Failure(title: "“\(team)” 팀을 워커 \(gone.count)개 없이 띄움",
                               reason: "작업 폴더가 없어 뺀 워커: \(list)"))
    }
}

/// A worker folder my-team would accept the form of (absolute, `~` or `~/…`, `~` being `$HOME` as in my-team's
/// config/parser.js) but that is no longer a directory: a removed worktree. my-team start refuses a config naming
/// one, so the resume leaves that worker out. Any other cwd is kept for my-team to judge and report.
func folderIsGone(_ cwd: Any?, home: String = homeDirectory()) -> Bool {
    guard let cwd = cwd as? String, cwd == "~" || cwd.hasPrefix("~/") || cwd.hasPrefix("/") else { return false }
    let path = cwd == "~" ? home : cwd.hasPrefix("~/") ? home + cwd.dropFirst() : cwd
    var isDir: ObjCBool = false
    return !(FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue)
}

/// The config in `dir` that names `team`: the one 팀 실행 lists for it (`teamConfigs`), so 팀 실행 and the resume of
/// a stopped team start from the same file (T208). The `.resume.json` the board wrote last time is never the base:
/// it carries old session ids.
func teamConfigPath(named team: String, in dir: String) -> String? {
    teamConfigs(in: dir).configs.first { $0.team == team }?.path
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
              stateBase: String = stateRootBase()) -> [String: Any]? {
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
    /// The config's workers: what `start --continue` starts. A team with a run in the history shows what its
    /// resume starts instead (`launchWorkerCounts`).
    let workers: Int
    let modified: Date
    /// The other files in `~/teams` that name the team; the newest, `path`, is the one started (T209 R3 S1).
    var others: [String] = []

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

/// The team configs right in `dir`, one a team: the newest file that names it (`teamConfigPath` reads the same),
/// with the others named. The board's `.resume.json` and any file with `.bak` in its name are left out; any other
/// `.json` file that is not a team config is listed in `unreadable` with its reason.
func teamConfigs(in dir: String) -> TeamConfigList {
    let fm = FileManager.default
    var found: [String: [TeamConfig]] = [:]
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
        found[team, default: []].append(TeamConfig(team: team, path: path, workers: workers.count, modified: modified(path)))
    }
    let configs = found.values.map { files -> TeamConfig in
        // newest first; on the same time, the first by name
        let sorted = files.enumerated().sorted { a, b in
            a.element.modified != b.element.modified ? a.element.modified > b.element.modified : a.offset < b.offset
        }.map(\.element)
        var newest = sorted[0]
        newest.others = sorted.dropFirst().map(\.file).sorted()
        return newest
    }
    return TeamConfigList(configs: configs.sorted { $0.team < $1.team }, unreadable: unreadable)
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

/// The 팀 종료 flow: a team is shut down only after the user pressed 팀 종료 in the dialog `ask` opened for it, and
/// once at a time. The dialog closing (`close`, which SwiftUI may do before or after a button's action) is apart from
/// 취소 (`cancel`), so a dialog closed another way does not come back and 팀 종료 still finds its team.
struct TeamShutdowns {
    /// The team whose confirmation dialog is open.
    private(set) var asking: String?
    /// The team the last dialog asked about, until 취소, 팀 종료 or the next dialog.
    private var asked: String?
    /// Teams being shut down: from the confirmation until the board no longer sees them run, or the command failed.
    private(set) var running: Set<String> = []

    /// false while `team` is being shut down already.
    mutating func ask(_ team: String) -> Bool {
        guard !running.contains(team) else { return false }
        asking = team
        asked = team
        return true
    }

    mutating func close() { asking = nil }

    mutating func cancel() {
        asking = nil
        asked = nil
    }

    /// Whether `team`'s dialog was the last one opened and not cancelled; it is now being shut down.
    mutating func confirm(_ team: String) -> Bool {
        guard asked == team else { return false }
        asking = nil
        asked = nil
        running.insert(team)
        return true
    }

    mutating func failed(_ team: String) { running.remove(team) }

    mutating func settle(running live: Set<String>) { running.formIntersection(live) }
}

/// How long `my-team shutdown` may take before the board gives up on it and the team can be shut down again.
let shutdownTimeout: TimeInterval = 30

/// The 팀 종료 dialog's message (T206 §1): what ends at once and what stays.
func shutdownMessage(workers: Int) -> String {
    "워커 \(workers)개와 tmux 세션이 바로 끝나고, 응답 중인 워커는 중간에 멈춥니다. "
        + "작업판·메일·manifest는 남아 있어, ‘팀 실행’으로 다시 띄우면 워커마다 마지막 대화를 이어갑니다."
}

/// A team's newest run in the history: the run its newest session belongs to, and when that session last changed.
struct TeamLastRun: Equatable {
    var run: TeamRun
    var updatedAt: String
}

/// Each team's newest run, by team name, from the sessions `teamRuns` gives a run.
func lastRuns(_ history: [HistorySession]) -> [String: TeamLastRun] {
    let byPath = Dictionary(history.map { ($0.transcriptPath, $0) }, uniquingKeysWith: { a, _ in a })
    var last: [String: TeamLastRun] = [:]
    for (path, run) in teamRuns(history) {
        guard let h = byPath[path] else { continue }
        if let seen = last[run.team], (parseISO(seen.updatedAt) ?? 0) >= (parseISO(h.updatedAt) ?? 0) { continue }
        last[run.team] = TeamLastRun(run: run, updatedAt: h.updatedAt)
    }
    return last
}

/// 팀 실행's order: the team run last first, then the teams with no run in the history by name.
func launchOrder(_ configs: [TeamConfig], last: [String: TeamLastRun]) -> [TeamConfig] {
    configs.sorted { a, b in
        switch (last[a.team].flatMap { parseISO($0.updatedAt) }, last[b.team].flatMap { parseISO($0.updatedAt) }) {
        case let (x?, y?) where x != y: x > y
        case (_?, nil): true
        case (nil, _?): false
        default: a.team < b.team
        }
    }
}

/// How 팀 실행 starts a team: a stopped run in the history comes back with each worker resuming its last
/// conversation (`Tower.resumeTeam`); a team with none starts from its config with `--continue`.
enum TeamLaunchPlan: Equatable {
    case resume(TeamRun)
    case start
}

func launchPlan(_ config: TeamConfig, last: [String: TeamLastRun]) -> TeamLaunchPlan {
    last[config.team].map { .resume($0.run) } ?? .start
}

/// When a team last ran, as 팀 실행 shows it (T209): `오늘 14:30`, `어제 09:05`, `11-17 22:40` this year, else
/// `2025-12-03`; 24-hour, on the user's calendar and time zone.
func lastRunTime(_ iso: String, now: Date, calendar: Calendar = .current) -> String? {
    guard let ms = parseISO(iso) else { return nil }
    let date = Date(timeIntervalSince1970: ms / 1000)
    func format(_ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
    if calendar.isDate(date, inSameDayAs: now) { return "오늘 " + format("HH:mm") }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
        return "어제 " + format("HH:mm")
    }
    if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return format("MM-dd HH:mm") }
    return format("yyyy-MM-dd")
}

/// A 팀 실행 menu line's second line: when the team last ran, or that it runs or is being started, then its size.
func launchItemSubtitle(workers: Int, last: TeamLastRun?, running: Bool, launching: Bool, now: Date) -> String {
    let when = running ? "실행 중" : launching ? "띄우는 중" : last.flatMap { lastRunTime($0.updatedAt, now: now) } ?? "기록 없음"
    return "\(when) · 워커 \(workers)"
}

/// The sessions of one run in the history.
func runSessions(_ run: TeamRun, in history: [HistorySession]) -> [HistorySession] {
    let runs = teamRuns(history)
    return history.filter { runs[$0.transcriptPath] == run }
}

/// The config the resume of `run` starts (`Tower.resumeTeam` writes it): the team's base with each worker of the run.
func resumeConfig(for run: TeamRun, history: [HistorySession], teams: String = teamsDir,
                  stateBase: String = stateRootBase()) -> ResumeConfig? {
    teamBase(run.team, teams: teams, stateBase: stateBase).map { resumeConfig($0, run: runSessions(run, in: history)) }
}

/// The worker count each 팀 실행 line shows: what picking it starts (T208 R5 S1). A team with a run in the history
/// resumes that run's workers; one without starts its config's.
func launchWorkerCounts(_ configs: [TeamConfig], history: [HistorySession], teams: String = teamsDir,
                        stateBase: String = stateRootBase()) -> [String: Int] {
    let last = lastRuns(history)
    return Dictionary(uniqueKeysWithValues: configs.map { c in
        let resumed = last[c.team].flatMap { resumeConfig(for: $0.run, history: history, teams: teams, stateBase: stateBase) }
        return (c.team, resumed?.workers.count ?? c.workers)
    })
}

/// A 팀 실행 menu line's tooltip: its file, when it last ran, and what picking it does; the team's other files.
func launchItemTooltip(_ config: TeamConfig, last: TeamLastRun?, running: Bool, home: String, now: Date) -> String {
    var lines = [abbreviate(config.path, home: home)]
    if running {
        lines.append("이 팀은 지금 실행 중입니다")
    } else if let last {
        lines += ["마지막 실행 " + relativeTime(last.updatedAt, now: now), "실행: 작업판을 이어 가고, 워커마다 마지막 대화를 resume합니다"]
    } else {
        lines.append("실행: 작업판을 이어 가고, 워커는 새 대화로 시작합니다")
    }
    if !config.others.isEmpty {
        lines.append("같은 팀 config: \(config.others.joined(separator: ", ")) (가장 최근 수정 파일로 띄움)")
    }
    return lines.joined(separator: "\n")
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
