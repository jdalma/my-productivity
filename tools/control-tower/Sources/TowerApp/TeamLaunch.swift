import Foundation
import TowerCore

// Starting a my-team team from the board, in a new Ghostty window: a new team that Claude writes with the user,
// or a stopped one (after a reboot, say) with each worker back in its last session.
// The board itself writes no file: the terminal it opens does, in front of the user.

let teamsDir = NSHomeDirectory() + "/teams"

/// Each claude worker's last ended session in `team`, by worker name. Codex workers start afresh: my-team passes
/// launch args to codex as options, and its resume is a subcommand.
func lastSessions(of team: String, in history: [HistorySession]) -> [String: String] {
    var newest: [String: HistorySession] = [:]
    for h in history where h.member?.team == team && h.agent == .claude && !h.live {
        guard let worker = h.member?.worker else { continue }
        if let seen = newest[worker], (parseISO(seen.updatedAt) ?? 0) >= (parseISO(h.updatedAt) ?? 0) { continue }
        newest[worker] = h
    }
    return newest.mapValues(\.id)
}

/// `base` with `--resume <id>` in the launch args of each worker that has a session; anything else in the config
/// stays as it was. my-team uses a `--resume` for that one launch and keeps it out of the team's manifest.
func resumeConfig(_ base: [String: Any], sessions: [String: String]) -> [String: Any] {
    var config = base
    config["workers"] = (base["workers"] as? [[String: Any]] ?? []).map { worker in
        guard worker["agent_type"] as? String == "claude", let name = worker["name"] as? String, let id = sessions[name]
        else { return worker }
        var args = worker["launch_args"] as? [String] ?? []
        if let i = args.firstIndex(of: "--resume") { args.removeSubrange(i...min(i + 1, args.count - 1)) }
        var w = worker
        w["launch_args"] = args + ["--resume", id]
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

/// Writes the config, starts the team, and attaches this terminal to the team's tmux session. On a failure the
/// window stays open on the error until Enter.
func resumeTeamCommand(team: String, config: String, path: String, myTeam: String, tmux: String) -> [String] {
    let script = """
        printf '%s\\n' "$1" > "$2" && "$3" start --config "$2" \
        && exec "$4" attach -t "$("$3" status --team "$5" --json | plutil -extract session raw -o - -)"
        echo; echo '팀을 띄우지 못했습니다. Enter로 닫기'; read -r _
        """
    return ["/bin/sh", "-c", script, "sh", config, path, myTeam, tmux, team]
}

/// What Claude is asked first in a new-team terminal.
let newTeamPrompt = """
    ~/teams 에 my-team 팀을 새로 만들고 띄운다. 먼저 나에게 팀의 목적, 필요한 워커(이름·역할·작업 폴더·할 일)를 묻는다. \
    답을 들으면 my-team 스킬의 config 형식으로 ~/teams/<team_name>.json 을 쓴다. 기존 ~/teams/*.json 을 참고하고, \
    같은 이름의 파일이 있으면 덮어쓰기 전에 묻는다. 내가 확인하면 `my-team start --config <그 파일>` 로 띄운다. \
    띄운 뒤에는 Control Tower 보드에서 그 팀이 보이고, 워커를 더블 클릭하면 터미널로 간다고 알려 준다.
    """

/// The config a stopped team starts from. Its workers are the ones its last run had (the manifest keeps workers
/// added or removed mid-run), each with the brief and settings its `~/teams` config gives it; with no manifest,
/// the config alone. The manifest lacks the briefs, but a resumed worker has its own in its conversation.
func teamBase(_ team: String, teams: String = teamsDir,
              stateBase: String = NSHomeDirectory() + "/.my-team/sessions") -> [String: Any]? {
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
