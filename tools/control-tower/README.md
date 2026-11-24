# control-tower

One view of every my-team worker and every Claude Code / Codex session on this Mac: who is waiting for you, for how long, and a click to jump to that tmux pane.

Read-only except for what the user asks for: moving focus; resuming an ended session they double-click (a new Ghostty window runs `claude --resume <id>` or `codex resume <id>` in that session's directory); starting a team in a new Ghostty window (팀 실행, 새 팀 만들기…); shutting down a running my-team team (팀 종료…), only after the user confirms the dialog; and saving a worktree file in the board's editor, only a file the user unlocked there (잠금 해제) and only when they save it. It never types into a pane, never closes a single session, and never reads a my-team mailbox in a way that consumes it.

A Swift package for macOS 14+. `TowerCore` collects and judges, `TowerApp` is the menu bar app, and `tower-cli` prints the same data for scripts.

## Menu bar app

```bash
cd tools/control-tower
scripts/bundle-app.sh          # build the editor page, swift build -c release, ad-hoc sign, install to ~/Applications/ControlTower.app
```

Then open **Control Tower** from Spotlight, Launchpad or Finder. Rerun the script to update; it replaces the installed bundle.

The script needs Node.js 22.12 or later and npm: it first builds the editor page (`editor-web/`, Monaco) with
`npm ci && npm run build` into `Sources/TowerCore/Resources/editor/`, which is built, never committed. Without node it
stops and says so. `swift build` and `swift test` do not need the editor page and run the same without
`Resources/editor/`. To build only the page: `(cd editor-web && npm ci && npm run build)`.

- Opening the app opens the board window. Opening it again while it runs brings the board forward; there is still one menu bar icon.
- Started by Open at Login, it stays in the menu bar and does not open the board.
  It tells the two apart by the launch event's `keyAELaunchedAsLogInItem` flag. Each launch writes one line with the raw event
  to `~/Library/Logs/ControlTower/launch.log` (last 20 lines), so a login launch that opens the board shows why there.
- Open at Login registered from the old `.build/ControlTower.app` path: turn it off and on again in Settings from the installed app.
  Check what is registered with `sfltool dumpbtm | grep -B2 -A10 local.control-tower`.

- Menu bar: an icon, plus N while N sessions are waiting for you. Collects every 5 s.
- Dropdown: the waiting sessions; click one to jump to it. Open Board (⌘B), Settings (⌘,), Quit (⌘Q).
- Board window: one column per live my-team team, then Claude Code and Codex sessions outside any team.
  Diff windows, one per folder, open as tabs of one window of their own, titled by team and the workers in the
  folder (`shop · pm, core`), or by the folder's name for a session outside a team. Opening a folder already there
  selects its tab; the tab bar's + opens nothing. Neither the board window nor a task board joins them.
- Dashboard: the board opens on it, and the sidebar's first line (대시보드) goes back to it. It looks back at your
  Claude Code usage over today, the last 7 days or the last 30 days (the picker at the top right; the choice is
  kept). Reading order: up to three sentences about what stands out, then 사용량 (output tokens against the usual
  level, a bar per day or hour, the other token kinds as numbers), 어디에 (projects or models, the top five and the
  rest) and 새는 곳 (cache written again after a pause longer than the cache was kept, 5 minutes or an hour, and
  sessions compacted 3 times or more). A sentence is only shown when its sample is large enough, and names what it
  compares with. Click a sentence to scroll to its group; double-click a project to search the sidebar for it, a
  session to open it (⌘[ comes back). Last, 실행 중인 워커: each live my-team worker's prompt cache hit rate,
  cache read ÷ (input + cache creation + cache read), over its whole current session whatever the period, with
  its subagents' apart; 낮음 marks a rate under 90% after 20 responses. Click a worker to open its row.
  It reads the transcripts when it is shown, on ⌘R, when the period changes, and every minute (today) or five
  minutes while it stays on screen: never while another screen is shown. The same numbers: `tower-cli --usage`.
- Analysis and advice (the 분석과 조언 button beside 새는 곳): Claude writes where the tokens leak and what to change.
  This is the one command the app starts on its own: `claude -p --model sonnet --tools "" --safe-mode
  --strict-mcp-config --disable-slash-commands --no-session-persistence --output-format json --system-prompt <a
  fixed sentence>`, from `~/.local/bin`, `/opt/homebrew/bin` or `/usr/local/bin` (not the PATH), never through a
  shell, in an empty temporary folder, stopped after 120 seconds. The arguments are the same on every run; the
  request goes to its standard input. It holds what the dashboard shows for the period on screen and nothing else:
  the sums, the comparison with the usual level, output per day or hour, the sums per project (the folder's own
  name, never its path), per model and per kind, cache written again after pauses, how often sessions were
  compacted, and the eight sessions that leak most by their project's name and numbers. No prompt, no response, no
  session title, no path and no account detail goes out. Claude gets no tool, and none of your CLAUDE.md, hooks,
  plugins, skills or MCP servers is loaded (policy an administrator manages still applies, with the
  hooks it sets: `--safe-mode` leaves that on); the run writes no transcript, so it is not in the dashboard's own sums, but it does use
  your Claude account (about 2K tokens in, 1K out).
  It runs by itself once a day, the first time the dashboard is on screen with a finished reading, whether that run
  works or not. The board opens on the dashboard, so starting the app with its window is enough for the day's run;
  a run is never started while another screen is shown. 다시 분석 in the sheet runs it again. Settings (⌘,) → 대시보드 → 하루 한 번 사용량 분석 turns the
  daily run off; the button still works. The last analysis, when and from which period it was written, and a failed
  try's reason are kept in `~/Library/Application Support/ControlTower/advice/v1.json`.
- Team line: one line per team in the sidebar, never two: a chevron (the fold), the team's name, a `작업판` button
  when the team keeps a task board, `워커 N`, the decisions waiting for the user in a pink `결정 대기 N` tag (not at 0),
  then an icon and a number for each of 권한 요청, 답 기다림, 완료 and 작업 중 (not at 0). The line never wraps. When
  the name whole does not fit, it gives way in this order: `작업판` and `워커` become icons, then `결정 대기` too, then
  the worker count goes, then 작업 중 goes. What is your turn stays longest (the button, the decisions, 권한 요청, 답
  기다림, 완료): the name is cut to its first four characters first, then those three counts are added into one
  `내 차례` number (a tray icon) beside the decisions, and the name is cut further before any count is.
  The tooltip and VoiceOver read the same words whatever is drawn: `워커 N`, `내 차례 N`, `결정 대기 N`, each state's
  count and `멈춤 N 숨김`, all of the workers the line lists by the state each shows. VoiceOver adds the task
  board's panel counts or why its read failed.
  Teams start folded: a click on the line opens its workers and is kept; a search opens every team; a worker picked
  from elsewhere opens its team. With the list focused, ← folds the selected worker's team and → unfolds it; with
  no folded team under the selection, → unfolds the first folded team down the list.
  The button opens the team's task board window and does not fold the team; its tooltip is the decisions waiting
  for the user (not at 0), then 시작 전, 진행 중, 리뷰 중 and 보류 (when it has one), or why the read failed (the
  icon is a triangle then).
  The line's context menu has 작업판 열기 (with a task board) and 팀 종료…, also a VoiceOver action. A dialog asks
  first (취소 is the default button: Return and Esc do not shut down); 팀 종료 runs `my-team shutdown --team <name>`
  without a shell or a terminal. The line then shows a spinner in place of its counts until the team leaves the
  running list (팀 실행 then lists it with its last run); on a failure, or when my-team has not ended within 30
  seconds (it is then stopped), it comes back at once and an alert shows my-team's last stderr line.
- 팀 실행 (the running list's head) is a menu: the team configs in `~/teams/*.json`, one per `team_name` (the newest
  file; the resume of a stopped run reads the same one), leaving out the board's `*.resume.json` and any file with
  `.bak` in its name; the team's other files are named in the tooltip. Each line's second line reads
  `<when> · 워커 N`: when the team's newest session in the history last changed (`오늘 14:30`, `어제 09:05`,
  `11-17 22:40` this year, else `2025-12-03`), or `기록 없음`; N is the workers picking it starts: the workers of its
  last run that the resume brings back, else the config's. The team run last is first, the teams never run follow by name. A team that runs or is being
  started is dimmed (`실행 중 · 워커 N`, `띄우는 중 · 워커 N`), and every team is (`기록 읽는 중`) until the history
  has been read once after launch, so a stopped team is never started without its conversations. The tooltip has the file, the time relative to now
  and what picking it does. Other `.json` files
  are listed disabled under 읽지 못한 파일 with the reason (JSON 아님, team_name 없음, workers 없음, 읽기 권한 없음).
  Then 새 팀 만들기… and ~/teams 폴더 열기. Picking a team opens a new Ghostty window and attaches to the team's tmux
  session; a team that already runs is only attached. A team with a stopped run in the history comes back as that
  run, each claude worker resuming its last conversation (`--resume <id>` in a `~/teams/<team>.resume.json` the
  board writes, then `my-team start --continue`); a team with none runs `my-team start --continue --config <file>`
  (no previous state: a new team). The config in `~/teams` is never written. Until
  the board sees the team run, a `띄우는 중` line holds its place at the top of the running teams.
- 기록 (history): the ended Claude Code or Codex sessions outside any team, newest first, Claude or Codex picked
  above the list. A team's workers are not listed there: 팀 실행 starts a stopped team again.
- Worker line: under an unfolded team, each worker's state icon, name, folder (when it is not the name) and time in
  the state. A worker whose folder is a git work tree with changes has `+N −M` before the time: the lines added and
  removed against the base the diff window uses (a base picked there too), its 커밋된 변경 and 미커밋 변경 counts
  added up, so a line committed and then changed again counts twice. Untracked files count as added lines by the
  diff window's rules (the first 200, up to 1 MB each); a binary file counts no lines. No changes, or a folder
  outside git: nothing. Workers in one folder (no worktree each) all show that folder's counts with a folder icon,
  and the tooltip names who shares it. On a narrow line the counts go first and whole, before the folder or the
  name is cut; the tooltip and VoiceOver still read `더한 줄 N, 뺀 줄 M`. They are counted every 5 s for
  the workers of the unfolded teams while the board window is open (a row scrolled away or a minimized window
  included): git is not run for a folded team or with the board window closed.
  `tower-cli --diff <folder>` prints the same two numbers as `added` and `removed` (with the automatic base).
- Task board: the window's subtitle has the same counts as that tooltip. Read only; ⌘R reads it again.
  The list is one column of panels by state, in this order: 시작 전, 사용자 결정, 진행 중, 리뷰 중, 보류, 끝남.
  A waiting task stays in the panel it goes back to, with a pink `결정` tag. A panel with nothing keeps its head.
  A line shows the task's state icon, id, title, step (등록 → 배정 → 작업 → 리뷰 → 끝), to-do bar (`4/6` from the ticket),
  assignee → reviewer, tags (결정, findings, `pm 차례 · …`, 수정 요청, 취소됨, 제출 직전) and how long it has stood.
  The last progress record is under it. A narrow list puts the step, to-do, people and tags on the second line.
  Click a panel's head to fold or unfold it, or Option-click to fold or unfold every panel. A folded head keeps its
  counts and gathers its lines' warnings. Folds are kept per team across launches. A search shows what it finds in
  folded panels. Picking a task from elsewhere opens its panel. A new decision opens a folded 사용자 결정 once.
  The toolbar's pink `결정 N` goes to the decisions. 끝남 shows its last 5 until 모두 보기. 지난 결정 opens under the
  waiting ones. ↑ and ↓ move through the lines across panels, passing a folded panel's.
  The layout is yours, kept per team with the folds: drag a panel by its head to move it (a line shows where it
  goes), or use View › 묶음 (⌥⌘↑ / ⌥⌘↓ move the panel whose head you last clicked, else the picked task) or the
  head's right-click menu. Panels also stand side by side in columns, as many as the list has room for (a column
  is at least 520 pt wide at the standard text size; a 1440 pt window without the detail has room for two). The app
  makes no column by itself: drag a panel onto another column, or onto the `여기에 놓으면 새 단` strip that shows at
  the list's right edge while you drag, or use 왼쪽 단으로 / 오른쪽 단으로 (⌥⌘← / ⌥⌘→, View › 묶음, the head's
  menu, VoiceOver's actions). A column left empty is gone. When the list is too narrow for the columns kept (a
  smaller window, or the detail open beside it) it shows them as one, the first column's panels then the next's,
  and what is kept does not change: widen the list and the columns are back. A panel moved while they show as one
  goes to the column of the panel it is put before. ↑ and ↓ follow the same reading order. Within 시작 전, 진행 중, 리뷰 중 and 보류, drag a task's line, or use its right-click menu
  (위로, 아래로, 맨 위로, 원래 자리로), to put it on top: the tasks you put on top come first with a pin, then the rest in
  the board's order under `↑ 직접 올린 작업 n`. A task that moves to another panel leaves the top for good. Lines of
  끝남 and the decisions, and lines while a search runs, do not move. Drag a panel's bottom edge to set its height;
  its lines then scroll inside it with `↓ n개 더` at the bottom, and its head says 높이 고정. Double-click the edge or
  the tag to fit the lines again. ⌘Z takes back each move; 기본 배치로 되돌리기 (View › 묶음, the head's menu, or
  ↺ 배치 되돌리기 at the top) resets order, tops and heights but keeps the folds.
  The toolbar's first control switches the list between 상태별 (the panels) and 순서 (View › 상태별로 보기 ⌘1,
  순서로 보기 ⌘2; kept per team). 순서 shows each goal of the team (`my-team api goal-order`: the `## 순서` of its
  goal files) as a section, the goals with a task to start first and the ones all done last and folded. A goal's
  waves stand side by side, a column each (at least 200 pt × the text scale), or, when they do not all fit, all
  stacked; never some of each. A card has the task's state icon and id (and its items for a range node, `할 일 4–7`),
  its title on two lines at most and one status line: `지금 시작 가능` (its predecessors are done and it has not
  started; accent border), the task's state when it is under way, `대기: T177, T181 할 일 1` (what it waits for, in
  words), `대기: T179 (취소됨)` in orange when a predecessor was cancelled, `완료`, `취소됨`, or `작업판에 없음` (dashed,
  cannot be picked). A click picks the task as a line does; ↑ ↓ move within a wave, ← → to the next wave's card at
  the same height. A goal with a cycle shows its path and that pm has to fix the order; a line of `## 순서` that does
  not read is a warning above the waves; 목표 파일 열기 (a goal head's menu) shows the file in the detail's place. With
  an older my-team that has no goal-order, the switch and the two menu items are not there and the board shows the
  panels. A task in a goal's order has 목표, 선행 and 후행 lines under 관련 작업 in its detail, each a link; 목표 goes to
  its card in the 순서 view.
  With nothing picked the list takes the whole window. A picked task or decision opens its detail beside the list, or
  in its place when the window is narrow. Esc closes it. The latest announcement is a line at the top. 팀 개요 in the
  toolbar shows every announcement, each worker's tasks and the recent activity.
  Under the panels, 문서 lists the team's documents: the lines of `<my-team state folder>/docs/<team>/index.md`
  (`~/.my-team/docs/<team>/index.md`), a file kept by hand as `## group` headings over
  `- [title](path or URL): note` lines, a path being relative to that folder. It is one line until unfolded, and
  then at most 0.45 of the list's height. The file is read again after a read of the board when it changed; the app
  never writes it. A click or Return opens a line (↑ ↓ move): a Markdown file in the detail's place, an `http` or
  `https` link in the browser. Any other file leaves the app as a report's path does, in the editor the settings
  name and under the same rules: nothing that runs, installs or goes elsewhere (a script, an executable, an app, an
  installer, an internet shortcut, a folder), and SVG, calendar, contact and profile files not in the macOS
  default app. One exception, for the documents alone: a file named `.html` or `.htm` (a team's mock) goes to
  the macOS default app for it (usually the browser), whatever the editor. An Excalidraw drawing (`.excalidraw`)
  goes to the app macOS has for it whatever the editor, or, with none (most Macs), Finder shows it selected; the
  same rules hold but for the type's own check, as macOS knows no document type for it. A file opens only when its real path (symbolic links and `..` resolved) is in the team's documents
  folder, and a Markdown file is read only when what was opened is in it. A line that does not open (a path that
  leaves the folder, a `file://` address or any other scheme, a refused kind of file) says 열 수 없음 and why on
  the line in a few words, and in full in its tooltip; a line that opens says in its tooltip what opens it (the window, the browser, the editor's name or the
  macOS default app). The line's menu copies the path or the link and shows a file in Finder, without opening
  it. The index file's first link on a list line is the document, the line's other words its note; an image and a
  link written inside code are not links.
  Those lines are 고른 문서. Under them, 모든 문서 lists every document in the folder without anyone listing it:
  the Markdown, `.html`, `.htm`, PDF and `.excalidraw` files (not Excalidraw's `.excalidraw.svg` export; its
  `.excalidraw.md` is Markdown), however deep, but no symbolic link (none is followed), no hidden
  file, nothing inside a bundle (a folder macOS shows as one file, such as an app) and not the index itself. A line has the title (a Markdown file's first heading, else the file's name), the
  path from the folder and when the file last changed; the latest change is first, or 폴더별 groups the lines by
  the folder right under the documents folder, each group foldable. A group shows 20 lines until 더 보기. 문서 걸러
  보기 keeps the lines of both lists whose title or path holds every word typed. Each list folds by its head. A
  line of 모든 문서 opens by the same rules, judged again at the click, with one difference: its `.html` file is
  not opened by a click (Finder에서 보기 and 경로 복사 remain) unless a line of the index opens the same file,
  which the line marks with 고른 문서. The folder is read when the area is unfolded and every 10 seconds while it
  stays so with 모든 문서 unfolded, off the main thread, apart from the board's own reading; a file whose time and size did not change
  keeps its title unread.
  Task boards open as tabs of one window, titled by team, whatever the system's tab preference; opening a team
  already there selects its tab. Other windows, diff windows too, never join them. The tab bar's + opens nothing.
  A decision's line shows its number (`D#6`) where a task line shows its id, then the question; its tooltip and
  VoiceOver begin with `D#6, ` and the question. A decision's detail has its brief, the answer, and its tasks; a task's detail has its decisions. A waiting decision
  is your turn too: it is in the menu bar count and the dropdown, and a new one sends a notification that opens it.
  A task's detail reads as a document: where it is (`shop 작업판 › 진행 중 › T5`), the title, a decision that waits
  for you on a pink ground, then its properties in two columns (state and whose move it is, assignee, reviewer, the
  to-do bar, its decisions, findings, the tasks around it). Under them, the goal, the to-do list as check boxes, the
  ticket's text (open at first), the findings, the history down a line, the commits since the start (while it is in
  progress) and the notes, each a section under a line, and last 작업 정보, folded: the ticket, when it was
  registered, the constraints, the start commit. Its text runs at most 572 pt wide (about 44 Hangul characters)
  times the text size. A decision's detail has the same properties (state, who asked, when, its tasks).
  Markdown in a ticket, a decision brief and a report is drawn: headings, lists, check boxes (`- [ ]`, pictures, not
  controls), callouts (`> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`), rules, tables and code
  blocks with their language. Progress notes, notes and announcements get the inline marks only. Only `http` and
  `https` links open. A submission's report and a review's report (`.md`) fold out under 미리 보기 in the history;
  the file is read each time it opens, never written, and the link above it still opens it in the editor.
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
.build/release/tower-cli --diff <dir>    # a git workspace vs its base branch: base, merge-base, committed/uncommitted file counts, untracked paths, `added`/`removed` lines of both together (a worker line's `+N −M`)
.build/release/tower-cli --usage week    # Claude Code token usage of today, week or month, from the transcripts
```

`--usage` reads `~/.claude/projects` (the first run takes about ten seconds) and keeps hourly sums under
`~/Library/Application Support/ControlTower/usage/v1`, so a day's numbers stay after Claude Code deletes its
transcripts. A response is counted once, however many lines and files it is in. What the numbers can lack:

- Requests Claude Code makes without writing a response to the transcript.
- A transcript that could not be opened: `progress.filesUnreadable` counts those of the last reading. Once such a
  file can be read, its responses from before that reading are still left out, since a later start takes them
  for already stored.
- A session file deleted by hand, for the last hours before the reading after which it was deleted.
- Responses written while the clock was set back by more than an hour. They stay out for good once a reading has
  run with the clock set right again, since a later start takes them for already stored.

## tmux status-right badge (optional)

Build `tower-cli` in release mode first (above), then:

```tmux
set -g status-right '#(~/IdeaProjects/my-productivity/tools/control-tower/scripts/tmux-badge.sh) %H:%M'
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
| a session's worktree (its `cwd`'s git repository): `git ls-files`, the files the user opens in the board's editor, FSEvents on the folder | the editor and its folder tree. Files open locked; the app writes only a file the user unlocked, when they save it, and only over the bytes the edit started from. When the disk changed under an edit that is not saved, nothing is written or merged by itself: a banner asks (비교, 디스크로 다시 읽기, 덮어쓰기, 내 편집 유지), and only 덮어쓰기 writes. It never creates a file, nor writes one that was deleted |
| `~/.claude/projects/*/<id>.jsonl` (`CLAUDE_CONFIG_DIR`), `~/.codex/sessions/**/rollout-*.jsonl` and `session_index.jsonl` (`CODEX_HOME`), first and last 256 KB each | session history: title, workspace, branch, last prompt; only `entrypoint: cli` Claude sessions and Codex TUI / CLI / Desktop sessions |

`MY_TEAM_STATE_ROOT_BASE` overrides `~/.my-team/sessions`, as it does for my-team. Requires `tmux`.

The my-team CLI runs only for a team whose manifest names a task board (its `board` key):
`my-team api board-status --input '{"team_name":"<team>"}' --json`, every 5 s while the board or a task board window
is open and every 15 s while none is, so a decision waiting for the user reaches the menu bar and a notification
with every window closed. While a task board window is open, `my-team api goal-order --input '{"team_name":"<team>"}' --json` runs
with each read of the boards for that window's team (T214). It runs without
`MY_TEAM_WORKER`, `MY_TEAM_STATE_ROOT` and `OMC_TEAM_WORKER` in its environment. That call only reads, and the app
never opens `board.db` itself. With no such team, neither my-team nor `node` needs to be installed to run the app;
building it with `scripts/bundle-app.sh` needs node for the editor page (Menu bar app above).

## Test

```bash
swift test
```

## E2E with a test instance

A second Control Tower, with its own home, my-team state, tmux server, task board and settings, can be driven
through accessibility while the installed one keeps running. It touches none of the user's apps, tmux server or
files: outward actions (focus, resume, notifications, the login item) are lines in `$T/actions.log`
(`TOWER_DRY_RUN`), tmux calls go to the test server's socket (`TOWER_TMUX_SOCKET`), and the task board comes from a
fake `my-team` that answers `board-status` from a fixture.

```bash
# 1. build the test bundle from a copy of the commit under test, not the working tree
W=<scratch>/e2e-<commit>
mkdir -p "$W" && git -C <repo> archive <commit> tools/control-tower | tar -x -C "$W"
(cd "$W/tools/control-tower" && scripts/bundle-app.sh .build/ControlTowerTest.app local.control-tower.test)
#    both arguments, always: bundle-app.sh without them overwrites the installed app
#    as a my-team worker (OMC_TEAM_WORKER=<team>/<worker>) the id becomes local.control-tower.test-<worker>

# 2. start it in the background; out.txt names $T and the app's pid
[CT_TEST_SIZE=1920x1080] [CT_TEST_ORIGIN=40,40] [CT_TEST_FONT_SCALE=1.1] [CT_TEST_APPEARANCE=light|dark] [CT_TEST_VISIBLE=1] \
  scripts/test-instance.sh "$W/tools/control-tower/.build/ControlTowerTest.app" > "$W/out.txt" 2>&1 &

# 3. drive it: only ever the pid out.txt names (ax.swift refuses any app that is not local.control-tower.*)
swiftc -O scripts/ax.swift -o .build/ax               # once: a compiled ax answers in milliseconds. Compile it again
                                                      # whenever the test bundle is built again: an ax from before the
                                                      # windows were hidden (T187) does not list them
.build/ax <app pid> windows                           # window numbers, for screencapture -x -o -l<number>
.build/ax <app pid> press "example-team, 워커"          # fold or unfold a team: its line is one heading whose label reads every count
.build/ax <app pid> action "example-team, 워커" "$(printf 'Name:작업판 열기\nTarget:0x0\nSelector:(null)')"   # the line's 작업판 button: opens the task board window, the fold stays
.build/ax <app pid> select alpha                      # pick a worker, as ↑ and ↓ do; `press "변경 보기"` opens its diff window
.build/ax <app pid> menu 3                            # the menus: each item's key equivalent, and whether it is disabled
.build/ax <app pid> menu-press View "글자 크게"         # what ⌘+ does; `menu-press "Control Tower" "Settings…"` for ⌘, (app commands only)

# 4. stop it: the script removes the app, the test tmux server and $T
kill -TERM <test-instance.sh pid>             # not INT: a bash started with & from a script ignores it
```

Fixture (`scripts/test-instance/fixture.py`): team `example-team` with a worker in each state (alpha 답 기다림,
beta 작업 중, gamma 권한 요청, delta 완료, epsilon 쉬는 중 on a 220-column pane), most in a tmux window of their own;
team `example-panes` (eta, theta, iota) with its workers as panes of one window, as my-team lays a team out; a
loose session; an ended session and a worker of an ended team in history; git repositories in `work/alpha` and
`work/beta` with different committed and uncommitted changes; and a task board for `example-team` with a task in
every group, T5's ticket, T12's decision brief and every report holding each Markdown block the app draws (`fake-my-team.py` answers it; `TestInstanceTests` checks these against the app's parsers).
`scripts/test-instance/docs-fixture.py` writes `example-team`'s documents: an index with Markdown files, an `.html`
file, an example.com link, a file that is not there and lines that must not open (a path and a symbolic link out of
the folder, a `file://` address, a line without a link, a script with execute permission, a folder, an `.svg` file). `CT_TEST_DOCS=none` starts without an index file,
`CT_TEST_DOCS=empty` with one that lists nothing (`DocumentsTests` reads all three as the app does).
The folder also holds what the index does not list, for 모든 문서: 43 documents (30 reports, reviews, tickets, an
`.html` file nobody listed, a `.pdf`) beside files that are no document (a `.txt`, a `.png`, a hidden file); with
`CT_TEST_DOCS=none` or `empty` it holds no document (`DocumentFolderTests`). Typing does not reach the test app, so
`TOWER_DOCS_FILTER=<words>` in the environment starts the app with 문서 걸러 보기 filled.

Usage (`scripts/test-instance/usage_fixture.py`): transcripts with token usage for the dashboard, every name and
number invented. `CT_TEST_USAGE=normal` (the default: 35 days in seven projects, the last 7 days above the weeks
before, cache written again after pauses, sessions compacted 3 times or more), `sparse` (two active days: no
comparison) or `none` (the dashboard has no record to show).

Keys do not reach the test app. It is never the active app, so it has no key window and AppKit drops a key posted
to its pid; making its window key would take the keyboard from the app the user is in. What a key does is checked
another way: a menu item by `menu-press` (`menu` shows which key it is bound to), ↑ and ↓ by `select`, a button by
`press`. A menu item that acts on the focused window (뒤로, 검색, 닫기, 변경 보기, 작업판 보기, 다시 읽기) is
disabled while the app is not active, so those shortcuts, Return, Esc and typing are checked by a person. A right
click's menu may open with `action <text> AXShowMenu`; that is not tried yet.

`menu-press` presses only the app's own commands (AX identifier `menuAction:`): it refuses the Apple, Window and
Help menus and every item AppKit makes (Hide Others, Show All, Services, Quit, copy and paste), which would bring
another app forward, hide the user's apps or end the session. It waits two seconds after each press: the same
item pressed again within about a second counts from the value before (글자 크게 twice gives 1.1, not 1.2).

A window larger than the screen is shrunk to fit by macOS, so a layout reported at 1920×1080 cannot be opened on
a smaller screen. `test-instance.sh` says so and names a size and text scale with the same ratio of window to
text, e.g. `CT_TEST_SIZE=1396x785 CT_TEST_FONT_SCALE=0.8` for 1920×1080 at 1.1 on a 1512×949 screen. It is a
stand-in: sizes that do not scale with the text differ.

Rules while it runs:

- Send nothing to the installed app (`pgrep -f Applications/ControlTower.app`), not even a read.
- No global input: no `CGEvent` posted to the session, no `osascript` keystroke or click, no `cliclick`. A key goes
  to the test pid only (`ax.swift key`), and has no effect there (above).
- Never bring an app forward: no `activate`, `open -a`, `AXRaise`, `AXFrontmost`. AX actions work on a window in
  the back.
- No copy or paste on selectable text or in the search field: those still use the system clipboard (T97).
  `ax.swift` refuses ⌘C, ⌘X, ⌘V and ⌘E (`key`), and pressing the system's Copy, Cut and Paste items in the Edit or a
  context menu (`press`, `action`); the app's own items ("id 복사", "폴더 경로 복사", …) use the test instance's
  pasteboard and pass. `swift scripts/ax.swift check <menu title> [key]` says which way an item goes (T101).
- `ax.swift` does nothing while the screen is locked or the login window is in front, works only in windows
  (AXWindow), and never presses a menu, a menu item or anything inside one through `press`, `select`, `open` or
  `action`: menus go through `menu-press`, which takes the app's own commands only (T119). A context menu's items
  are out of reach too. `ax.swift self-test` checks these rules without an app.
- The test app's windows are on every Space and it never comes forward by itself: AX and `screencapture -l` work
  wherever the user is, another app's full screen Space included. Each window opens at `CT_TEST_ORIGIN` (x,y from
  the main screen's top left), by default in the bottom right corner. Started with `CT_TEST_VISIBLE=1` (next rule)
  they show there, over a full screen app too.
- The windows are not on the user's screen (T187): they are stacked under the desktop picture, at the lowest window
  level. `screencapture -x -o -l<number>` gives the same picture as of a window in view, and `ax.swift` reads and
  acts on them the same way. What does not work on a hidden window is the pointer: hover, drag and anything else a
  person does with the mouse. For that, and to look at the app, start it with `CT_TEST_VISIBLE=1`: the windows are
  then in view at `CT_TEST_ORIGIN`, as they were before, so keep them small and close the instance when done. A
  menu or popover the app opens is a window of its own and may show even when the rest is hidden.
- One test instance at a time with the same bundle id, and stop it as soon as the check is done: its menu bar icon
  shows on the user's screen, and with `CT_TEST_VISIBLE=1` its windows do. Each my-team worker gets its own id: `bundle-app.sh` turns
  `local.control-tower.test` into `local.control-tower.test-<worker>` (the name after the `/` of
  `OMC_TEAM_WORKER`, with anything but letters, digits, `.` and `-` as `-`), so workers can run test instances
  side by side: the settings and the app's own pasteboard (`<bundle id>.pasteboard`) both follow the bundle id.
  Without `OMC_TEAM_WORKER` the id stays `local.control-tower.test`.
- The test bundle's settings domain is emptied at each start (`defaults delete <its bundle id>`); the installed
  app's (`local.control-tower`) is never touched. If an app with that bundle id is already running,
  or another `test-instance.sh` is starting one, `test-instance.sh` stops before emptying it and names the id and
  the running pid on stderr. The second case is a lock on `$TMPDIR/ct-test-lock.<bundle id>` that the script holds
  while it lives; the file stays there afterwards, unlocked. Do not clear `$TMPDIR/ct-test*` wholesale: with a
  running script's lock file removed, a second instance with the same bundle id starts beside it. Each script
  removes its own `$T`.
