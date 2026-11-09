# control-tower

One view of every my-team worker and every Claude Code / Codex session on this Mac: who is waiting for you, for how long, and a click to jump to that tmux pane.

Read-only except for two things the user asks for: moving focus, and resuming an ended session they double-click (a new Ghostty window runs `claude --resume <id>` or `codex resume <id>` in that session's directory). It never types into a pane, never closes a session, and never reads a my-team mailbox in a way that consumes it.

A Swift package for macOS 14+. `TowerCore` collects and judges, `TowerApp` is the menu bar app, and `tower-cli` prints the same data for scripts.

## Menu bar app

```bash
cd tools/control-tower
scripts/bundle-app.sh          # swift build -c release, ad-hoc sign, install to ~/Applications/ControlTower.app
```

Then open **Control Tower** from Spotlight, Launchpad or Finder. Rerun the script to update; it replaces the installed bundle.

- Opening the app opens the board window. Opening it again while it runs brings the board forward; there is still one menu bar icon.
- Started by Open at Login, it stays in the menu bar and does not open the board.
  It tells the two apart by the launch event's `keyAELaunchedAsLogInItem` flag. Each launch writes one line with the raw event
  to `~/Library/Logs/ControlTower/launch.log` (last 20 lines), so a login launch that opens the board shows why there.
- Open at Login registered from the old `.build/ControlTower.app` path: turn it off and on again in Settings from the installed app.
  Check what is registered with `sfltool dumpbtm | grep -B2 -A10 local.control-tower`.

- Menu bar: an icon, plus N while N sessions are waiting for you. Collects every 5 s.
- Dropdown: the waiting sessions; click one to jump to it. Open Board (⌘B), Settings (⌘,), Quit (⌘Q).
- Board window: one column per live my-team team, then Claude Code and Codex sessions outside any team.
- Notification when a session turns into your turn (not for the first snapshot after launch). Click it to jump.
- Settings → Open at Login (off by default).

Notifications and Open at Login need the `.app` bundle; `swift run TowerApp` works without them.
The bundle is ad-hoc signed, not notarized: a personal tool built on this Mac.

A card is **your turn** when the agent finished its turn and has no unread peer mail, or a permission prompt is on screen. A worker my-team reports dead is never your turn.

Clicking a card:

- tmux session with an attached client: select the window and pane, then bring Ghostty forward.
- tmux session nobody is attached to: select the pane, then open a new Ghostty window running `tmux attach`.
- session outside tmux: bring its terminal app forward.

## tower-cli

```bash
swift build -c release --product tower-cli
.build/release/tower-cli --once | jq .   # one snapshot as JSON
.build/release/tower-cli --count         # number of sessions waiting for you; prints nothing at 0
.build/release/tower-cli --history --limit 20   # past interactive Claude Code / Codex sessions, newest first
.build/release/tower-cli --diff <dir>    # a git workspace vs its base branch: base, merge-base, committed/uncommitted file counts, untracked paths
```

## tmux status-right badge (optional)

Build `tower-cli` in release mode first (above), then:

```tmux
set -g status-right '#(~/IdeaProjects/my-claude-plugin/tools/control-tower/scripts/tmux-badge.sh) %H:%M'
```

Prints `my turn N` while N > 0. Prints nothing and exits 0 when N is 0 or `.build/release/tower-cli` is missing or fails.

## Where the data comes from

| Source | Used for |
|---|---|
| `~/.my-team/sessions/<team>/manifest.json`, then under its `state_root`: `workers/<w>/status.json`, `mailbox/<w>.json`, `incoming-spool/<w>/` | live teams, workers, mail counts, self-reported state (read the way `my-team status --all --json` does) |
| `~/.claude/sessions/<pid>.json` | Claude pid, tmux pane, busy/idle, transcript |
| `sysctl` / libproc | processes, Codex processes and their open rollout files |
| `tmux list-panes` / `list-clients` / `capture-pane` | worker liveness, pane titles, attached sessions, permission prompts |
| transcript tails (last 200 KB) | last user / assistant message |
| `~/.claude/projects/*/<id>.jsonl` (`CLAUDE_CONFIG_DIR`), `~/.codex/sessions/**/rollout-*.jsonl` and `session_index.jsonl` (`CODEX_HOME`), first and last 256 KB each | session history: title, workspace, branch, last prompt; only `entrypoint: cli` Claude sessions and Codex TUI / CLI / Desktop sessions |

`MY_TEAM_STATE_ROOT_BASE` overrides `~/.my-team/sessions`, as it does for my-team. The my-team CLI itself is never run, so neither it nor `node` needs to be installed. Requires `tmux`.

## Test

```bash
swift test
```
