# control-tower 아키텍처 분석 (T2)

- 대상: `tools/control-tower` (기준 커밋 `6c0ca46`, 2026-11-23 시점 main)
- 방법: 코드 읽기만 했다. 코드 수정·커밋·my-team 상태 쓰기 명령 실행 없음.
- 경로 약어: `ct/` = `tools/control-tower/Sources/`, `ctt/` = `tools/control-tower/Tests/`, `mt/` = `tools/my-team/src/`. 나머지는 레포 루트 기준 상대 경로, 런타임 경로는 `~/`.
- 근거 표기: 모든 사실 진술에 `path:line`을 단다. 직접 확인하지 않은 항목은 **(추론)** 으로 표시한다.

---

## 1. 모듈 구조

### 1.1 SwiftPM target

`tools/control-tower/Package.swift` (swift-tools 6.0, macOS 14+, `Package.swift:1,6`)

| target | 종류 | 의존 | 근거 |
|---|---|---|---|
| `TowerCore` | library (`Resources/` copy) | 없음 | `Package.swift:8,16` |
| `tower-cli` | executable | TowerCore | `Package.swift:9,17` |
| `TowerApp` | executable (SwiftUI 앱) | TowerCore, SwiftTerm | `Package.swift:18` |
| `TowerTestSupport` | target (`Tests/TowerTestSupport`) | 없음 | `Package.swift:19` |
| `TowerCoreTests` | test (`Fixtures` 제외) | TowerCore, TowerTestSupport | `Package.swift:20` |
| `TowerAppTests` | test | TowerApp, TowerCore, TowerTestSupport | `Package.swift:21` |

외부 의존은 SwiftTerm `exact: 1.99.1` 하나뿐이며 board의 pane terminal(T46) 용도다 (`Package.swift:11-13`). `TowerCore/Resources/`에는 `highlight.min.js`와 라이선스 파일이 있다.

역할 분담: README가 "`TowerCore` collects and judges, `TowerApp` is the menu bar app, and `tower-cli` prints the same data for scripts"라고 정의한다 (`tools/control-tower/README.md:7`).

### 1.2 TowerCore 주요 타입 (파일별)

| 파일 | 주요 타입/함수 | 역할 |
|---|---|---|
| `ct/TowerCore/Model.swift` | `AgentKind`:5, `Status`:11, `TmuxRef`:16, `StateFile`:29, `Session`:57, `Worker`:140, `Team`:217, `Board`:255 | 스냅샷 데이터 모델 (Codable, `--once` JSON 형태) |
| `ct/TowerCore/Collect.swift` | `CollectDeps`:4, `join`:58, `enrich`:141, `Snapshot`:170, `snapshot`:177, `collect`:211, `collectSnapshot`:216 | 수집 파이프라인 진입점 |
| `ct/TowerCore/Sources/MyTeam.swift` | `stateRootBase`:7, `Manifest`:16, `RawTeam`:43, `loadTeams`:107, `teamStatus`:137, `mailCounts`:183, `toTeam`:205 | my-team 상태 파일 직접 읽기 |
| `ct/TowerCore/Sources/Tmux.swift` | `paneFormat`:5, `listPanes`:65, `listClients`:69, `capturePane`:73 | tmux 읽기 전용 호출 |
| `ct/TowerCore/Sources/Claude.swift` | `ClaudeRecord`:3, `SessionJson`:18, `fromSessionJson`:93, `loadClaudeSessions`:117 | `~/.claude/sessions/<pid>.json` 읽기 |
| `ct/TowerCore/Sources/Codex.swift` | `pickCandidates`:38, `openFiles`:57, `classifyRollout`:78, `loadCodexSessions`:133 | Codex 프로세스와 rollout 파일 매칭 |
| `ct/TowerCore/Sources/Ps.swift` | `psSnapshot`:84, `envOf`:99, `ancestors`:105 | sysctl `KERN_PROC_ALL` 기반 프로세스 목록 |
| `ct/TowerCore/Sources/History.swift` | `HistoryRoots`:90, `transcriptFiles`:244, `myTeamBootstrap`:312, `collectHistory`:345 | 과거 세션 목록 (resume 대상) |
| `ct/TowerCore/Sources/ClaudeUsage.swift` | `usageFiles`:14, `parseUsageChunk`:84 | transcript의 usage 라인 파싱 |
| `ct/TowerCore/Usage.swift` / `UsageStore.swift` | `UsageTokens`:12, `UsageLedger`:265, `refresh`:364, `sessionTotals`:489 / `UsageStore`:66 | 토큰 사용량 원장, 증분 읽기 + 로컬 저장 |
| `ct/TowerCore/WorkerCache.swift` | `cacheHitRate`:20, `cacheHitIsLow`:38, `workerCacheState`:54 | 워커별 cache hit rate |
| `ct/TowerCore/TaskBoard.swift` | `TaskBoardTask`:7, `TaskBoardStatus`:230, `runMyTeamApi`:297, `readTaskBoards`:327, `TaskFamily`:943, `readTaskFamily`:1009 | `my-team api board-status` 호출과 응답 모델, 패널 분류 |
| `ct/TowerCore/GoalOrder.swift` | `GoalOrder`:9, `parseGoalOrder`:69, `readGoalOrders`:91 | `my-team api goal-order` 호출 |
| `ct/TowerCore/Focus.swift` | `FocusPlan`:5, `tmuxCommand`:34, `myTeamBin`:59, `planFocus`:70, `planResume`:114, `planTerminal`:125, `pickTerminal`:178 | focus/resume argv 계획만 세운다 (실행 안 함, `Focus.swift:3-4`) |
| `ct/TowerCore/Diff.swift` | `GitRead`:7, `git`:20, `diffTotal`:143, `workspaceDiff`:159 | 읽기 전용 git diff |
| `ct/TowerCore/Support.swift` | `resolveExecutable`:79, `childEnvironment`:87, `myTeamEnvironment`:97, `runCommand`:107 | 공통 subprocess 실행기 |
| `ct/TowerCore/Documents.swift` | `documentsFolder`:256 | `~/.my-team/docs/<team>` 문서 인덱스 |
| 기타 | `Status.swift`(my-turn 판정, permission prompt), `Display.swift`(`myTurnCount`:110), `Decisions.swift`, `TaskTracking.swift`, `Markdown.swift`, `Syntax.swift`, `WordDiff.swift`, `Declarations.swift`, `Navigation.swift`, `UsageAdvice*.swift`, `UsageInsight.swift`, `UsageReport.swift` | 표시·판정 로직 |

### 1.3 TowerApp: 진입점과 Scene 구성

- `@main struct TowerApp: App` — `ct/TowerApp/TowerApp.swift:4-5`. `@NSApplicationDelegateAdaptor`로 `AppDelegate`를 붙이고 (`TowerApp.swift:6`), `AppDelegate`가 유일한 `Tower` 인스턴스를 소유한다 (`ct/TowerApp/Launch.swift:28-29`).
- `AppDelegate.applicationDidFinishLaunching`: login item 실행이면 board를 열지 않는다 (`Launch.swift:31-36`). 재실행 시 board를 앞으로 (`Launch.swift:39-43`). launch 이벤트를 `~/Library/Logs/ControlTower/launch.log`에 20줄까지 남긴다 (`Launch.swift:46-54`).

Scene 구성 (`ct/TowerApp/TowerApp.swift:9-38`):

| Scene | id | 내용 | 근거 |
|---|---|---|---|
| `MenuBarExtra` (`.menu` 스타일) | - | `MenuContent` + `MenuBarLabel`(my-turn 숫자) | `TowerApp.swift:10-15`, `:43-64`, `:67-107` |
| `Window("Control Tower")` | `board` | `BoardView` (사이드바 + 상세 + 대시보드) | `TowerApp.swift:17-21` |
| `WindowGroup("변경", for: DiffTarget)` | `diff` | `DiffWindow`, workspace당 1창 | `TowerApp.swift:23-27`, `ct/TowerApp/DiffWindow.swift:6-12` |
| `WindowGroup("작업판", for: TaskBoardTarget)` | `taskBoard` | `TaskBoardWindow`, team당 1창 | `TowerApp.swift:29-33`, `ct/TowerApp/TaskBoardWindow.swift:6,34` |
| `Settings` | - | `SettingsView` (SMAppService login item, appearance) | `TowerApp.swift:35-37`, `ct/TowerApp/LoginItem.swift:8-9` |

- `TowerCommands`가 메인 메뉴(새 팀 만들기, 다시 읽기 ⌘R, 변경 보기 ⌘D, 작업판 보기 ⇧⌘T, 이동 메뉴)를 정의한다 (`TowerApp.swift:167-231`).
- 열린 창이 하나라도 있으면 `.regular`, 없으면 `.accessory`(메뉴바 아이콘만) activation policy로 전환한다 (`ct/TowerApp/Tower.swift:301-323`). Info.plist의 `LSUIElement=true`로 시작한다 (`tools/control-tower/scripts/bundle-app.sh:53`).

TowerApp 주요 파일 역할:

| 파일 | 역할 |
|---|---|
| `Tower.swift` | 상태 모델(`Tower`:7)과 모든 polling loop, focus/resume/launch/shutdown 액션 |
| `BoardView.swift`, `Sidebar.swift` | board 창: 팀·워커·loose 세션·history 행, 상세(`PaneTerminal` 포함) |
| `Dashboard*.swift` | 사용량 대시보드 (`UsageDashboard`:`Dashboard.swift:30`, `UsageAdvisor`:`DashboardAdvice.swift:11`) |
| `TaskBoard*.swift`, `TaskDetailView.swift`, `GoalOrder*.swift`, `Decision*.swift` | 작업판 창 (패널/goal-order 뷰, 결정 브리프) |
| `DiffWindow.swift`, `ChangesView.swift`, `ChangeTree.swift`, `CodeView.swift` | diff 창 (`ChangesState`:`ChangesView.swift:50`) |
| `PaneControl.swift`, `PaneTerminal.swift` | tmux control mode 클라이언트(`PaneStream`:`PaneControl.swift:107`)와 SwiftTerm 뷰 |
| `FocusRunner.swift` | argv 배열 실행기 (shell 없음, dry-run 지원) |
| `TeamLaunch.swift` | `~/teams` config 목록, 팀 실행·재개·종료 명령 생성 |
| `Notifier.swift` | `UNUserNotificationCenter` 알림 (`Notifier.swift:16`) |

### 1.4 tower-cli

`ct/tower-cli/main.swift` 단일 파일. 플래그별 동작 (`main.swift:1-8` 주석, 분기 `:54-95`):

- `--once`: `collect()` 결과 Board JSON (`main.swift:57-58`)
- `--count`: my-turn 수, 0이면 출력 없음 (`main.swift:54-56`). `scripts/tmux-badge.sh`가 이것을 쓴다 (`tools/control-tower/scripts/tmux-badge.sh:5-7`).
- `--history [--limit N]` (`main.swift:59-62`), `--diff <dir>` (`:63-75`), `--usage [today|week|month] [--timing]` (`:76-92`)

---

## 2. 데이터 소스

### 2.0 전체 흐름

```
                       +-------------------- TowerCore.snapshot(deps:) ---------------------+
 sysctl KERN_PROC_ALL -> psSnapshot ------------------------------+                         |
 tmux list-panes -a   -> listPanes  ----+                         |                         |
 ~/.my-team/sessions/*/manifest.json    +-> loadTeams/teamStatus -+-> toTeam --+            |
   └ state_root/{workers/*/status.json,     (RawTeam)                          |            |
      mailbox/*.json, incoming-spool/*}                                        v            |
 tmux list-clients    -> listClients -------------------------------------> join() -> enrich() -> Snapshot
 ~/.claude/sessions/<pid>.json -> loadClaudeSessions ----------------------^      ^  (transcript tail,
 libproc open files + ~/.codex  -> loadCodexSessions ----------------------^      |   capture-pane)
                       +--------------------------------------------------------------------+
                                                   | Task.detached, 5 s
                                                   v
                                    Tower (@MainActor @Observable)
            +-------------+-------------+-------------+--------------------+-------------------+
            | board       | history     | taskBoards  | goalOrders         | diffTotals/usage  |
            |  5 s        |  15 s       |  5 s / 15 s | open window only   | 5 s / 60-300 s    |
            v             v             v             v                    v
      MenuBarExtra   BoardView      TaskBoardWindow (my-team api ... subprocess)  DiffWindow / Dashboard
```

### 2.1 my-team 워커 데이터: 파일 직접 읽기

- 원칙: "Read-only: reads my-team's state files the way `my-team status --all --json` does (tools/my-team/src/commands/status.js). Nothing here writes, absorbs or consumes." (`ct/TowerCore/Sources/MyTeam.swift:3-4`). 즉 워커 목록은 `my-team status` subprocess가 아니라 파일을 직접 읽는다.
- state base: `MY_TEAM_STATE_ROOT_BASE`(trim, `~` 확장) 또는 `~/.my-team/sessions` (`MyTeam.swift:7-13`).
- 팀 디렉토리 열거: `.bak` 접미사와 `.omc` 제외, 디렉토리만, 이름순 (`MyTeam.swift:119-122`). base가 없으면 빈 목록, 열거 실패만 throw (`MyTeam.swift:110-116`). manifest decode 실패는 해당 팀만 skip (`MyTeam.swift:124-130`).
- `manifest.json` decode 필드: `team_name`, `state_root`, `session_name`, `started_at?`, `group?`, `board?`(존재 여부만, `Present`), `workers[]`{`name`, `pane_id`, `cwd?`, `agent_type?`, `role?`, `description?`} (`MyTeam.swift:16-40`, snake_case 변환 `:118`).
- liveness: manifest의 session(`:` 앞) 안의 pane 중 `@worker_name == name && pane_id 일치`인 pane이 있으면 alive. 팀은 워커 하나라도 alive면 alive (`MyTeam.swift:134-138,152,173`). 이후 `filter(\.teamAlive)`로 죽은 팀은 board에서 제외 (`ct/TowerCore/Collect.swift:183`).
- 워커별 파일 (모두 manifest의 `state_root` 기준):
  - `incoming-spool/<w>/*.json` 개수 → `spool` (`MyTeam.swift:153,177-179`)
  - `workers/<w>/status.json`의 `state`, `reason`, `updated_at` (문자열 아니면 해당 필드만 버림) (`MyTeam.swift:155-161`)
  - `mailbox/<w>.json`: `schema_version == 2` 아니면 에러, `inbox` 개수 → unread, `sent_pending` 개수와 가장 이른 `sent_at` (`MyTeam.swift:162-169,183-203`). 파싱 실패는 워커 `reason`에 "mailbox unreadable"로 들어간다 (`MyTeam.swift:166-167`).
- `events.jsonl`, `archive/`, `board.db`는 TowerCore가 직접 열지 않는다. `ct/` 전체 grep에서 `events.jsonl`/`board.db` 접근 코드는 없고 `board.db`는 "never opens" 주석에만 나온다 (`ct/TowerCore/TaskBoard.swift:3-4`).
- agent 종류: manifest `agent_type == "codex"`만 codex, 나머지(gemini 등)는 claude로 취급하며 이후 프로세스 매칭 결과로 덮어쓴다 (`MyTeam.swift:222-224`, `Collect.swift:124`).
- 실패 처리: `loadTeams`가 throw하면 팀 없이 board를 만들고 `myTeamError`에 담는다 (`Collect.swift:182-188`). UI는 메뉴 첫 줄과 board 창 경고 줄로 표시한다 (`ct/TowerApp/TowerApp.swift:73-76,110-121`).

### 2.2 작업판(board.db): `my-team api` subprocess 경유

- "Read only, through `my-team api board-status --json`: the app never opens board.db and never runs a command that writes." (`ct/TowerCore/TaskBoard.swift:3-4`)
- 호출 형태: `[myTeamBin, "api", <command>, "--input", <json>, "--json"]`, timeout 3초, env에서 `MY_TEAM_WORKER`, `MY_TEAM_STATE_ROOT`, `OMC_TEAM_WORKER` 제거 (`TaskBoard.swift:256-257,297-303`). 실행기는 `runCommand` (shell 없이 Process, PATH 보강, stderr는 임시 파일) (`ct/TowerCore/Support.swift:107-120`).
- `myTeamBin`은 PATH + Homebrew 경로에서 `my-team`을 찾은 절대 경로 (`ct/TowerCore/Focus.swift:59`, `Support.swift:70-82`).
- 호출 종류:
  - `board-status {"team_name"}` → `TaskBoardStatus` (`TaskBoard.swift:307-318`). manifest에 `board` 키가 있는 팀만 호출 (`TaskBoard.swift:321-325`).
  - `board-status {"team_name","task"}` → `TaskFamily` (`TaskBoard.swift:1009-1010`)
  - `goal-order {"team_name"}` → `[GoalOrder]`, 작업판 창이 열린 팀만 (`ct/TowerCore/GoalOrder.swift:78-98`)
- 응답 해석 (`TaskBoard.swift:270-288`): SIGTERM/SIGKILL + 빈 stdout → `.timeout`; exit 126/127 → `.launch`; `{"ok":false,"code","message"}` → `.code`; 그 외 decode 실패 → `.unreadable`. goal-order는 stderr에 `unknown command 'goal-order'`가 있으면 `.unsupported`로 보고 뷰를 숨긴다 (`GoalOrder.swift:69-75`).
- 하위 호환 decode: `history`, `waiting`, `progressSummary`, `decisions` 모두 optional이며 "absent from an older my-team"으로 처리 (`TaskBoard.swift:24-29,236`). `TaskHistory`와 `TaskWaiting.options`는 필드 단위로 lossy decode (`TaskBoard.swift:35-58,113-125`).

### 2.3 Claude Code 세션

- 실행 중 세션: `~/.claude/sessions/<pid>.json`을 이름순으로 읽는다 (`ct/TowerCore/Sources/Claude.swift:117-125`). 필드 `pid`, `cwd` 필수, 나머지 lossy (`Claude.swift:18-51`). pid가 죽었으면 버린다 (`Claude.swift:69-71,99`). `status == "busy"`만 busy, 나머지 wait (`Claude.swift:106`). `tmux` 필드로 pane을 안다 (`Claude.swift:110`).
- stale 판정: `procStart`(ctime, UTC)와 ps 시작 시각 차가 5초 초과면 pid 재사용으로 보고 제외 (`ct/TowerCore/Collect.swift:75-81,93`).
- transcript 위치: `~/.claude/projects/<cwd의 비영숫자를 '-'로>/<sessionId>.jsonl`, 없으면 모든 project dir에서 탐색 (`Claude.swift:60-67,73-79`).
- 마지막 user/assistant 메시지: transcript 마지막 200 KB (`ct/TowerCore/Status.swift:111-125`).
- permission prompt: `tmux capture-pane -p -S -40` 결과로 판정 (`ct/TowerCore/Sources/Tmux.swift:73-75`, `Collect.swift:152-154`).
- 과거 세션(history): `CLAUDE_CONFIG_DIR`(없으면 `~/.claude`)`/projects/*/*.jsonl`, 파일 앞뒤 256 KB만 파싱, `entrypoint == "cli"`만 (`ct/TowerCore/Sources/History.swift:4-5,94-98,109,244-250`). resume 명령은 `claude --resume <id>` (`History.swift:330`).

### 2.4 Codex 세션

- 후보 프로세스는 ps 행에서 고르고 (`ct/TowerCore/Sources/Codex.swift:38`), libproc `PROC_PIDLISTFDS`로 열린 파일 중 `/sessions/.../rollout-*.jsonl`을 찾는다 (`Codex.swift:30-31,57-76`). app-server 데몬이 연 rollout은 cwd가 같은 것 중 최신 mtime으로 배정 (`Codex.swift:140-167`).
- 상태: rollout 마지막 300,000 바이트에서 `task_started` vs `task_complete`/`turn_aborted` 위치로 busy/wait 판정 (`Codex.swift:16,78-91,171`).
- 제목: `~/.codex/session_index.jsonl` (`Codex.swift:122-131,135`).
- history: `CODEX_HOME`(없으면 `~/.codex`)`/sessions/**/rollout-*.jsonl`, originator가 `codex-tui`/`codex_cli_rs`/`Codex Desktop`인 것만 (`History.swift:98,107,251-254`). resume 명령 `codex resume <id>` (`History.swift:330`).

### 2.5 Cache hit rate

- 원장: `UsageLedger.shared`가 `CLAUDE_CONFIG_DIR`/`~/.claude` 아래 projects transcript를 증분 읽기(파일별 offset)하고, 합계를 `~/Library/Application Support/ControlTower/usage/v1`에 저장한다 (`ct/TowerCore/Usage.swift:265-266,307-312,364-400`). 파일 목록은 `<projects>/<dir>/<session>.jsonl`과 `<session>/subagents/` (`ct/TowerCore/Sources/ClaudeUsage.swift:11-24`). 토큰 필드는 `cache_read_input_tokens`, `cache_creation_input_tokens` 등 (`ClaudeUsage.swift:116-121`).
- 정의: `cacheRead / (input + cacheCreation + cacheRead)` (`ct/TowerCore/WorkerCache.swift:19-23`). 응답 20개 미만이면 판단 보류, 90% 미만이면 low (`WorkerCache.swift:33-41`).
- 워커 연결: 실행 중 워커의 `session.transcript` 집합을 `UsageDashboard.workerTranscripts`로 넘기고 (`ct/TowerApp/DashboardView.swift:35`, `ct/TowerApp/Dashboard.swift:53-54,362`), `sessionTotals`로 세션 전체 합계를 받아 (`Dashboard.swift:67,84`, `Usage.swift:489`) `workerCacheState`로 표시 (`Dashboard.swift:371,407-410`). codex 워커는 `.codex`로 제외 (`WorkerCache.swift:55`).
- 이 앱이 디스크에 쓰는 것은 이 usage 저장소, advice 저장(`ct/TowerCore/UsageAdvice.swift:201,216`), launch.log, UserDefaults뿐이다 (grep `write(to|createFile|UserDefaults` 결과 기준).

### 2.6 tmux

- 읽기: `tmux list-panes -a -F "<session>\t<window_id>\t<pane_id>\t<pane_pid>\t<pane_dead>\t<@worker_name>\t<pane_title>\t<pane_current_path>"`, `list-clients`, `capture-pane`; 모두 timeout 2초, 실패 시 빈 문자열 (`ct/TowerCore/Sources/Tmux.swift:5-10,60-75`). 파일 머리 주석: "Nothing here may select, send keys to, or kill anything." (`Tmux.swift:3`).
- tmux 바이너리: 해석된 절대 경로 + `TOWER_TMUX_SOCKET`이 있으면 `-S <socket>` (`ct/TowerCore/Focus.swift:29-38`).
- 프로세스↔pane 매칭: Claude는 `tmux` 필드 우선, 없으면 조상 pid로 pane 탐색. Codex는 조상 pid로만 (`Collect.swift:83-116`). 한 워커 pane을 두 번째 프로세스가 주장하면 loose로 떨어진다 (`Collect.swift:66-73`).

**Focus/jump (더블클릭)**

1. board 행 더블클릭/Return → 행 메뉴 첫 항목 실행 (`ct/TowerApp/BoardView.swift:222,259-262`). live 행은 `.focus` → `tower.focus(handle)` (`BoardView.swift:268`). 메뉴바 항목도 같은 경로 (`ct/TowerApp/TowerApp.swift:94-96`).
2. `Tower.focus`: `listClients()` 후 `planFocus` (`ct/TowerApp/Tower.swift:169-175`).
3. `planFocus` (`ct/TowerCore/Focus.swift:70-92`):
   - `pid:` handle(tmux 밖): `TERM_PROGRAM`으로 앱을 찾아 `open -a <app>`
   - attached 세션: `tmux select-window` + `select-pane` + `open -a Ghostty`
   - detached 세션: select 후 Ghostty AppleScript로 새 창에서 `tmux attach -t <session>`
4. Ghostty로 끝나는 계획이면 마지막 `open`을 떼고, AppleScript로 Ghostty terminal 목록을 읽어 (`Focus.swift:149-172`) 탭 하나로 좁혀지면 `focus terminal id`를 실행 (`Tower.swift:176-189`, `Focus.swift:178-202`).
5. 실행은 `FocusRunner.run`: argv[0]이 `tmux`면 해석된 tmux prefix, 그 외 상대 이름은 `/usr/bin/<name>`, shell 없음, `TOWER_DRY_RUN`이면 파일에 기록만 (`ct/TowerApp/FocusRunner.swift:14-35`).
- history 행 더블클릭: 실행 중이면 focus, 아니면 `planResume`으로 새 Ghostty 창에서 `claude --resume`/`codex resume` (`Tower.swift:197-212`, `Focus.swift:114-119`).

**PaneControl / PaneTerminal (board 상세의 라이브 pane)**

- `PaneStream.start()`가 `tmux -C attach-session -t <session> -f ignore-size`로 control mode 클라이언트를 띄운다 (`ct/TowerApp/PaneControl.swift:137-162`). `%output <pane>` 줄을 파싱해 SwiftTerm에 넣는다 (`PaneControl.swift:20-60`).
- 사용자 입력은 `send-keys -H -t <pane> <hex>`로, 붙여넣기는 `set-buffer` + paste로 pane에 전달한다 (`PaneControl.swift:166-175`). 즉 이 경로는 pane에 쓴다 (5장 불일치 항목 참조).
- 상세 화면에 `PaneTerminal(ref:)`로 붙고, pane마다 새 tmux 클라이언트를 만든다 (`ct/TowerApp/BoardView.swift:785-788`).

### 2.7 git diff

- 허용 subcommand를 enum으로 제한: `diff`, `ls-files`, `merge-base`, `rev-parse`, `symbolic-ref`, `for-each-ref`, `diff-index`, `log` (`ct/TowerCore/Diff.swift:7-15`).
- 실행: `git --no-optional-locks -C <dir> <cmd> ...`, timeout 20초, env로 `GIT_OPTIONAL_LOCKS=0`, `core.quotepath=off` (`Diff.swift:20-23`). 미커밋 diff는 index를 건드리지 않는 `diff-index`를 쓴다 (`Diff.swift:10-12`).
- 사용처:
  - 워커 행의 +/- 합계: `WorkerDiffTotals.refresh` → `diffTotal(at:pins:)`, 5초 loop (`ct/TowerApp/WorkerDiffTotals.swift:13-33`, `ct/TowerApp/Tower.swift:75-80`, `Diff.swift:143-157`)
  - diff 창: `ChangesView`가 `.task(id: LoadKey(workspace, at: board.at, pins))`로 board 갱신(5초)마다 재로딩 (`ct/TowerApp/ChangesView.swift:293`, `ct/TowerApp/DiffWindow.swift:59`)
  - CLI `--diff` (`ct/tower-cli/main.swift:63-75`)
- base branch pin은 UserDefaults에 저장 (`ChangesView.swift:8,344`).

---

## 3. 갱신 흐름

### 3.1 polling 주기

Timer/DispatchSource/FSEvents는 쓰지 않는다. `ct/` 전체 grep 결과 주기 작업은 모두 `Task { while true { ...; Task.sleep } }` 또는 SwiftUI `.task`/`TimelineView`다.

| 대상 | 주기 | 근거 |
|---|---|---|
| board 스냅샷 (`refresh` → `collectSnapshot`) + `~/teams` config 목록 | 5초 (수행 후 sleep) | `ct/TowerApp/Tower.swift:62-67,94-109` |
| 작업판 `board-status` (+ 선택 task family, goal-order) | 5초 tick. 창이 모두 닫혀 있으면 15초에 1회 | `Tower.swift:69-74,127-156,341-347` |
| 워커 diff 합계 | 5초 | `Tower.swift:75-80` |
| history 스캔 | 15초 (board 첫 수집 전엔 1초 대기) | `Tower.swift:81-91` |
| 사용량 원장 | today 60초, 그 외 300초. 대시보드가 화면에 있을 때만 | `ct/TowerApp/Dashboard.swift:115-122`, `ct/TowerApp/DashboardView.swift:34,108-121` |
| 사용량 첫 읽기 중 진행률 | 250 ms | `Dashboard.swift:94-100` |
| 작업판 문서 폴더 | 10초 | `ct/TowerApp/TaskBoardDocumentsArea.swift:48,108-121` |
| 작업판 경과 시간 표시 | 15초 `TimelineView` | `ct/TowerApp/TaskBoardView.swift:446` |
| diff 창 | board 갱신마다 (`board.at` 키) | `ct/TowerApp/ChangesView.swift:293` |

즉시 재읽기 트리거: ⌘R(`ct/TowerApp/TowerApp.swift:179`), board 창 열림 또는 새 작업판 창 열림(`Tower.swift:40-45`), 작업 선택 변경(`Tower.swift:34-36`).

### 3.2 상태 모델

모두 `@MainActor @Observable` class다.

| 타입 | 위치 | 보유 상태 |
|---|---|---|
| `Tower` | `ct/TowerApp/Tower.swift:6-7` | `board`, `myTeamError`, `history`, `taskBoards`, `goalOrders`, `taskFamilies`, `launches`, `shutdowns`, `teamConfigList`, `launchWorkers`, `windows`, `failure` (`:8-38`) |
| `UsageDashboard` | `ct/TowerApp/Dashboard.swift:29-30` | 사용량 report, period, workerTranscripts/Totals |
| `WorkerDiffTotals` | `ct/TowerApp/WorkerDiffTotals.swift:4-5` | `byFolder` |
| `UsageAdvisor` | `ct/TowerApp/DashboardAdvice.swift:10-11` | `claude -p` 분석 결과 |
| `ChangesState` | `ct/TowerApp/ChangesView.swift:49-50` | diff 창 1개의 로드 상태 |
| `PaneLink` | `ct/TowerApp/PaneTerminal.swift:44-45` | pane terminal 입력 상태 |

### 3.3 수집 → UI 경로

1. `Tower.refresh()`가 `Task.detached { await collectSnapshot() }`로 main actor 밖에서 수집 (`Tower.swift:94-97`).
2. `snapshot(deps: .live)` (`ct/TowerCore/Collect.swift:177-195`): `psSnapshot` → `listPanes` → `loadTeams(panes)`(팀 alive 필터) → `loadCodexSessions(rows)` → `listClients` → `toTeam` → `join(...)` → `markTerminals` → `enrich`. 소스는 순차 실행이며 느려지면 병렬화하라는 `ponytail:` 주석이 있다 (`Collect.swift:209-210`).
3. `join`: 워커 pane 키 `(session, pane)`에 프로세스를 배정하고 남은 프로세스는 `loose` (`Collect.swift:58-138`). `enrich`: transcript tail, `TERM_PROGRAM`, pane capture로 permission prompt와 `myTurn` 재계산 (`Collect.swift:141-166`). my-turn 기본 규칙은 `(status == .wait && spool == 0) || permissionPrompt` (`ct/TowerCore/Status.swift:7-8`).
4. main actor에서 `newlyMyTurn(prev:next:)`로 false→true 전이만 알림 (`Tower.swift:99-101`, `ct/TowerApp/Notifier.swift:8-12`). 이어 `board` 교체, launch/shutdown 진행 상태 정산 (`Tower.swift:102-104`).
5. View는 `tower.board` 등을 직접 읽는다. 메뉴바 숫자는 `tower.myTurn` = `myTurnShown(board, taskBoards:)` (`Tower.swift:111`, `ct/TowerApp/TowerApp.swift:48`, `ct/TowerApp/Sidebar.swift:717`).
6. 작업판 쪽은 `reloadTaskBoards()`가 선택된 family → 전 팀 `readTaskBoards` → 새 결정 알림(`decisionsToNotify`) → `goalOrders` 순으로 갱신하고, 실행 중 선택이 바뀌었으면 재귀 호출 (`Tower.swift:127-156`).

---

## 4. my-team과 공유하는 경계 (계약)

"깨지는 쪽"은 한쪽이 바뀔 때 오동작하는 쪽이다. my-team이 producer, control-tower가 consumer인 계약이 대부분이다.

### C1. state base 경로와 팀 디렉토리 배치

- CT: `MY_TEAM_STATE_ROOT_BASE` 또는 `~/.my-team/sessions`, `.bak`/`.omc` 제외 (`ct/TowerCore/Sources/MyTeam.swift:7-13,120`)
- MT 읽는 쪽: 같은 규칙 (`mt/lib/state-root.js:36-38`, `mt/commands/status.js:50-53`)
- MT 쓰는 쪽: 규칙이 다르다. config에 `state_root`가 없으면 parser가 `~/.my-team/sessions/<team>`으로 고정하고 `MY_TEAM_STATE_ROOT_BASE`를 보지 않는다 (`mt/config/parser.js:139-147`).
- 깨지는 쪽: my-team이 base 경로나 제외 규칙을 바꾸면 CT가 팀을 못 찾거나 백업 디렉토리를 팀으로 읽는다. CT 테스트가 같은 규칙을 고정한다 (`ctt/TowerCoreTests/MyTeamStateTests.swift:5`, `MyTeamPathTests.swift`). 또 `MY_TEAM_STATE_ROOT_BASE`를 설정한 환경에서 `my-team start`한 팀은 기본 경로에 manifest가 쓰이므로, 같은 변수를 보는 CT와 `my-team status --all`이 그 팀을 못 찾는다 (쓰는 쪽 `mt/config/parser.js:146` vs 읽는 쪽 `MyTeam.swift:7-13`, `mt/commands/status.js:50-53`).

### C2. `manifest.json` 필드

- MT producer: `team_name`, `state_root`, `session_name`, `session_mode`, `leader_pane`, `started_at`, `group?`, `board?`, `knowledge?`, `workers[]` (`mt/commands/start.js:302-313`); worker는 `name`, `pane_id`, `cwd`, `agent_type`, `role`, `description`, `launch_args`, `overlay_path` (`mt/commands/start.js:401-414`). 저장 `atomicWriteJson` (`mt/commands/start.js:477-478`).
- 위치: CT는 `<base>/<dir>/manifest.json`만 연다 (`MyTeam.swift:111,124`). manifest의 `state_root` 값으로 찾지 않으므로 base 밖에 state_root를 둔 팀은 보이지 않는다 (6-3).
- CT consumer 필수 필드: `team_name`, `state_root`, `session_name`, `workers[].name`, `workers[].pane_id` (`MyTeam.swift:16-40`). 하나라도 빠지거나 타입이 바뀌면 그 팀 전체가 skip된다 (`MyTeam.swift:124-130`).
- `board`: CT는 값과 무관하게 존재만 본다 (`MyTeam.swift:23-31`). MT 값은 `{"store": ...}` 객체 (`mt/config/parser.js:101-107`). 키 이름이 바뀌면 CT가 작업판을 전혀 읽지 않는다 (`ct/TowerCore/TaskBoard.swift:321-325`).
- `teamBase`는 manifest를 `json` 딕셔너리로 다시 읽어 `group`, `workers[].{name, role, agent_type, cwd, description, launch_args}`를 재사용한다 (`ct/TowerApp/TeamLaunch.swift:179-199`). manifest 위치를 `<stateBase>/<team>/manifest.json`으로 가정한다 (`TeamLaunch.swift:185`). 이 가정은 manifest의 실제 `state_root` 값이 아니라 디렉토리명 = 팀명에 기대고 있다.
- 깨지는 쪽: CT. MT가 필드를 추가하는 것은 안전하고, 이름 변경·삭제는 CT를 깬다.

### C3. liveness 판정 (`@worker_name` pane option)

- MT: `session_name.split(':')[0]` 세션 안의 `(worker, paneId)` 일치 (`mt/lib/team-liveness.js:38-46`). pane 테두리에 `@worker_name` 사용 (`mt/lib/tmux-session.js:52-60`).
- CT: 같은 규칙을 Swift로 복제 (`MyTeam.swift:134-138,152,173`).
- 깨지는 쪽: 양쪽. 로직이 복제돼 있어 MT만 규칙을 바꾸면 `my-team status`와 CT가 다른 답을 낸다. 공유 테스트는 없다 (CT 테스트는 손으로 쓴 manifest 사용, `ctt/TowerCoreTests/MyTeamStateTests.swift:19-25`).

### C4. `workers/<w>/status.json`

- MT: 워커 LLM에게 `{"state": "idle", "updated_at": ...}`, blocked 시 `reason` 기록을 지시 (`mt/lib/worker-bootstrap.js:229,273-279`). MT 자신은 `state`, `reason`만 읽는다 (`mt/commands/status.js:21-26`).
- CT: `state`, `reason`, `updated_at` 문자열만 (`MyTeam.swift:155-161`).
- 깨지는 쪽: CT (표시 누락). 내용을 LLM이 쓰므로 형태 보장이 약하고, CT는 필드 단위로 관대하게 읽는다.

### C5. mailbox / incoming-spool

- MT: mailbox schema v2 `{schema_version, worker, inbox{}, sent_pending{}}`, spool `incoming-spool/<to>/<id>.json` (`mt/lib/tmux-comm.js:7-23,54`). 버전 불일치 메시지 (`mt/lib/handler-guards.js:43-52`).
- CT: `schema_version == 2` 하드코딩, 같은 에러 문구 복제 (`MyTeam.swift:181-198`). spool은 `.json` 파일 수 (`MyTeam.swift:177-179`).
- 깨지는 쪽: CT. `MAILBOX_SCHEMA_VERSION`을 3으로 올리면 CT의 모든 워커 `reason`이 "mailbox unreadable"이 된다. 팀 자체는 계속 보인다 (`MyTeam.swift:164-168`).

### C6. `my-team api board-status` / `goal-order` JSON

- 호출: `my-team api <cmd> --input '{"team_name":..}' --json` (`ct/TowerCore/TaskBoard.swift:297-310`). MT 쪽 정의 `mt/cli.js:231-236,258`, 에러 형태 `{ok:false, code, message}` (`mt/cli.js:78`).
- 응답 (board-status, task 없음): `{ok, store, tasks, workers[{name, role, assigned, in_hand, reviewing}], open_findings, recent, announcements, decisions}` (`mt/commands/api/board-status.js:6-8`, `mt/board/core/queries.js:303-321`). CT `TaskBoardStatus`는 `tasks`, `workers`, `openFindings`, `recent`, `announcements`, `decisions?`를 decode (`TaskBoard.swift:230-237`). `store`, `in_hand`는 무시.
- 응답 (task 지정): `{root, tasks, answers, progress, landings, verdicts, findings, fixed_elsewhere, notes}` (`mt/board/core/queries.js:286-297`) → CT `TaskFamily` (`TaskBoard.swift:943`).
- goal-order: `{ok, goals:[{id, title, path, waves, ready_now, unregistered, cycle, errors}]}` (`mt/commands/api/goal-order.js:9`) → CT `GoalOrder` (`ct/TowerCore/GoalOrder.swift:9-23`).
- 외부자 차단: MT는 `MY_TEAM_WORKER`가 다른 팀이면 `forbidden` (`mt/board/compose.js:98-103`). CT는 그 변수들을 제거하고 실행한다 (`TaskBoard.swift:256-257`).
- 깨지는 쪽: CT. 필수 필드(`TaskBoardTask.id/title/state/priority`, `TaskBoardWorker.assigned/reviewing`, `TaskBoardEvent.seq/at/action` 등) 이름 변경은 board 전체 decode 실패(`.unreadable`)가 된다 (`TaskBoard.swift:7-15,167-171,205-208`). optional 필드 추가는 안전하다.

### C7. board store schema version

- MT: `SCHEMA_VERSION = 6` (`mt/board/core/contract.js:36`). 파일이 더 새 버전이면 `SchemaTooNew`로 거부 (`mt/board/store/sqlite/index.js:105-106`). 더 낡은 파일은 메모리로 복사해 migration한다는 주석 (`mt/board/store/sqlite/index.js:15`).
- CT: schema를 모른다. `board.db`를 직접 열지 않으므로 schema 변경은 my-team CLI가 흡수한다 (`ct/TowerCore/TaskBoard.swift:3-4`).
- 깨지는 쪽: 설치된 `my-team` 버전과 board 파일 버전이 어긋나면 CT에는 `{ok:false, code}` → `.code(...)` 실패로 보인다 (`TaskBoard.swift:283`). CT 코드 수정은 필요 없다.

### C8. `~/teams/*.json` config 형식 (group 포함)

- MT parser: `{team_name, group?, state_root?, new_window?, detached?, board?, solo?, workers[]}` (`mt/config/parser.js:5,122`). `group`은 `/^[a-z0-9][a-z0-9-]{0,48}[a-z0-9]$/` (`mt/config/parser.js:132-135`), manifest에 기록 (`mt/commands/start.js:309`), `status --json` 출력에 `group` (`mt/commands/status.js:66`).
- CT: `~/teams` 고정 (`ct/TowerApp/TeamLaunch.swift:8`). `*.json` 중 `.resume.json`·`.bak` 포함 이름 제외, `team_name` 문자열과 비어 있지 않은 `workers` 배열만 요구, `group`은 비어 있지 않은 문자열이면 채택 (`TeamLaunch.swift:242-264`). 표시: 메뉴 부제와 툴팁 (`TeamLaunch.swift:409-413,440-441`). 실행 중 팀의 group은 manifest에서 읽는다 (`MyTeam.swift:22,146`, `ct/TowerCore/Collect.swift:135`).
- 새 팀 만들기: Claude에게 group을 물어 `~/teams/<team>.json`에 쓰라는 프롬프트로 터미널을 연다 (`TeamLaunch.swift:160-168`).
- 깨지는 쪽: CT는 형식 검증을 하지 않으므로 MT parser가 거부하는 config도 메뉴에 나오고, 실패는 터미널 창 안에서 드러난다 (`TeamLaunch.swift:281-291`).

### C9. `my-team status --team <t> --json` (팀 실행 스크립트)

- CT: 실행·재개 셸 스크립트가 `status --team "$team" --json | plutil -extract team_alive raw`와 `-extract session raw`를 사용 (`ct/TowerApp/TeamLaunch.swift:119-130,281-291`).
- MT: `teamStatus`가 `team_alive`, `session`(= `manifest.session_name`) 키를 낸다 (`mt/commands/status.js:64-73,111-113`).
- 깨지는 쪽: CT. 키 이름이 바뀌면 이미 실행 중인 팀에 `start`를 한 번 더 하거나("두 start가 경합", `TeamLaunch.swift:116-117`), attach를 못 하고 종료한다 (`TeamLaunch.swift:126`).

### C10. `my-team start --continue --config` / `shutdown --team`

- CT 실행: `"$myTeam" start --continue --config <path>` (`TeamLaunch.swift:123,285`), 종료: `[myTeam, "shutdown", "--team", team]`을 `myTeamEnvironment()`(워커 변수 제거)로 실행 (`TeamLaunch.swift:295`, `ct/TowerApp/Tower.swift:263-271`, `ct/TowerCore/Support.swift:97-99`).
- MT: `--config`, `--continue` (`mt/cli.js:103,113`), `shutdown --team` 필수 (`mt/cli.js:145-148`).
- 재개 config: CT가 history에서 run을 재구성해 `~/teams/<team>.resume.json`을 터미널 안에서 쓰게 하고, claude 워커의 `launch_args`에서 `--resume`/`-r`/`--continue`/`-c`를 제거한다 (`TeamLaunch.swift:15-56`, `Tower.swift:222-240`). 주석상 MT의 `continuesConversation`과 같은 규칙을 따른다고 적혀 있고 (`TeamLaunch.swift:40-41`), 실제로 같은 플래그 집합(`--resume`, `-r`, `--resume=`, `--continue`, `-c`)을 본다 (`mt/lib/startup-notice.js:29-32` ↔ `TeamLaunch.swift:42-55`). 한쪽만 플래그를 추가하면 재개 config에 resume 인자가 남는다.
- 깨지는 쪽: CT. 플래그 이름 변경 시 터미널 창에서 실패한다.

### C11. 워커 부트스트랩 프롬프트 (history의 팀 run 식별)

- CT: transcript 첫 prompt가 `Team is live.` 또는 `You just joined team `로 시작하고 `/sessions/<team>/workers/<worker>/` 경로를 포함해야 팀 멤버로 인식한다 (`ct/TowerCore/Sources/History.swift:309-316`). 이 정보로 팀 run을 묶고(`ct/TowerApp/Sidebar.swift:233-250`) 팀 실행 시 resume 여부를 정한다 (`TeamLaunch.swift:384-386`).
- MT: 문구 출처 `mt/lib/startup-notice.js:21`, `mt/commands/add-worker.js:348`. 경로는 overlay path(`state_root/workers/<w>/AGENTS.md`)에서 온다 (`mt/lib/state-paths.js:29`).
- 깨지는 쪽: CT. 문구가 바뀌거나 state_root가 `/sessions/` 아래가 아니면(커스텀 `state_root`, base 이름 변경) history에서 팀 run을 못 찾고 팀 실행이 항상 `.start` 경로로 간다 **(추론: regex와 경로 조합으로 판단, 실제 실행 확인 안 함)**.

### C12. goal 파일과 문서 폴더 위치

- MT: goals는 `dirname(stateRootBase)/docs/<team>/goals` (`mt/commands/api/goal-order.js:32-33`).
- CT: 문서 인덱스를 `dirname(stateRootBase)/docs/<team>/index.md`에서 직접 읽는다 (`ct/TowerCore/Documents.swift:254-268`).
- 깨지는 쪽: CT (문서 탭). goal은 MT CLI를 거치므로 영향 없음.

---

## 5. 테스트 구조와 실행 방법

### 5.1 레이아웃

- 프레임워크: Swift Testing (`import Testing`). XCTest 사용 파일 없음 (grep 결과 69개 파일이 `import Testing`, `XCTest` 0개).
- `ctt/TowerTestSupport/EveryGCDWorkerBlocked.swift`: GCD worker가 모두 막혀도 timeout이 동작하는지 보는 보조 (`ct/TowerApp/FocusRunner.swift:61-62`의 T223 주석과 대응) **(추론: 파일명과 주석 기준)**.
- `ctt/TowerCoreTests/Fixtures/`: `board.json`, `board-decisions.json`, `goal-order.json`, `collect-input.json`, `codex-rollout-tail.jsonl`, `ps-codex.txt`, `transcripts/`. 로더 `ctt/TowerCoreTests/Fixtures.swift:4-11`.

### 5.2 파일별 대상 (테스트 수는 `@Test`/`func test` grep 개수)

TowerCoreTests

| 파일 | 수 | 대상 |
|---|---|---|
| CollectTests | 19 | `join`/`enrich`/`snapshot` (fixture `collect-input.json`) |
| MyTeamStateTests / MyTeamPathTests | 12 / 4 | manifest·status.json·mailbox 읽기, state base 경로 (status.js 대비, `MyTeamStateTests.swift:5`) |
| SourcesTests | 26 | Claude/Codex/tmux/ps 파서 |
| StatusTests / DisplayTests / ModelTests | 11 / 12 / 4 | my-turn, permission prompt, 표시 문자열, Codable |
| FocusTests | 11 | `planFocus`/`planResume`/`pickTerminal` |
| DiffTests / WordDiffTests | 34 / 7 | git diff 파싱, base 해석 |
| HistoryTests / MemberTests | 22 / 7 | history 스캔, bootstrap prompt 인식 |
| TaskBoardTests / TaskFamilyTests / TaskBoardPeopleTests / TaskWaitingTests / TaskTrackingTests | 38 / 9 / 2 / 5 / 20 | board-status decode, 패널 분류, family, waiting brief, 진행 추적 |
| DecisionsTests / GoalOrderTests | 11 / 7 | 결정 목록, goal-order decode·unsupported |
| UsageTests / UsageInsightTests / UsageAdviceTests | 32 / 31 / 12 | 원장 증분 읽기, 분석, advice 실행 |
| DocumentsTests / DocumentFolderTests / MarkdownTests / SyntaxTests / DeclarationsTests / NavigationTests / SplitTests | 17 / 13 / 17 / 9 / 6 / 8 / 4 | 문서·마크다운·코드 보기 |
| CommandTests / ChildEnvironmentTests | 9 / 3 | `runCommand` timeout·env |
| R1RegressionTests / TestInstanceTests | 5 / 14 | 회귀, 테스트 인스턴스 스크립트 |

TowerAppTests

| 파일 | 수 | 대상 |
|---|---|---|
| SidebarTests | 70 | 사이드바 모델, 팀 run (`teamRuns`) |
| TaskBoardViewTests / TaskDetailTests / TaskRowHistoryTests / DecisionViewsTests / GoalOrderLayoutTests | 39 / 15 / 10 / 16 / 11 | 작업판 UI 로직 |
| TeamLaunchTests | 32 | config 목록, resume config, 실행 스크립트 |
| PaneControlTests | 29 | control mode 파서, `PaneStream` |
| DashboardTests / DashboardRenderTests / DashboardAdviceTests | 27 / 4 / 9 | 대시보드 |
| ChangesStateTests / ChangeTreeTests / CodeNavigationTests / DiffContrastTests | 15 / 13 / 7 / 8 | diff 창 |
| FocusRunnerTests / DryRunTests / LaunchTests / NotifierTests / OpenWindowsTests | 3 / 4 / 4 / 4 / 4 | 실행기, dry-run, 시작 종류, 알림, activation policy |
| 기타 (Appearance, FileEditor, FontScale, FullScreen, LineContent, MarkdownShot, MoreBelowView, Pasteboard, RowID, SplitHandleCursor, SplitRowView, TaskBoardDocuments, TaskBoardFolderDocuments, TeamHeaderClick, TestInstanceWindows) | - | 개별 UI 동작 |

my-team과의 실제 계약 테스트(실제 `my-team` 실행 또는 MT fixture 공유)는 없다. CT는 손으로 쓴 manifest와 JSON fixture를 쓰고 (`ctt/TowerCoreTests/MyTeamStateTests.swift:19-25`), E2E용 가짜 my-team은 `board-status`만 응답한다 (`tools/control-tower/scripts/test-instance/fake-my-team.py:3,23-24`).

### 5.3 실행 방법

```bash
cd tools/control-tower
swift test                                   # README.md:270-274
swift build -c release --product tower-cli   # README.md:219
scripts/bundle-app.sh                        # release build, ad-hoc codesign, ~/Applications/ControlTower.app 설치 (README.md:13, bundle-app.sh:23,65-66)
```

- E2E: `scripts/test-instance.sh`가 별도 HOME·my-team 상태·tmux 소켓(`TOWER_TMUX_SOCKET`)·dry-run 로그(`TOWER_DRY_RUN`)로 두 번째 앱을 띄우고 `scripts/ax.swift`로 accessibility 조작한다 (`README.md:276-311`). 테스트 번들은 반드시 인자 2개로 빌드해야 설치본을 덮어쓰지 않는다 (`README.md:288-289`).
- 2026-11-23 실행 결과: `swift test` 849 tests in 3 suites passed, 약 1분 45초 (빌드 포함). 재현: `cd tools/control-tower && swift test`.

---

## 6. 확인된 불일치·위험 (수정하지 않음)

1. **"pane에 쓰지 않는다" 문구와 실제 코드 불일치.** README는 "It never types into a pane" (`tools/control-tower/README.md:5`), FocusRunner 주석은 "Focus is the only thing the app ever does to a pane" (`ct/TowerApp/FocusRunner.swift:12-13`). 하지만 `PaneStream.send`/`paste`가 `send-keys -H`, `set-buffer`로 사용자 입력을 pane에 보낸다 (`ct/TowerApp/PaneControl.swift:166-175`). 문서가 T46 pane terminal 이전 상태로 남은 것으로 보인다 **(추론)**.
2. **Claude/Codex 실행 중 세션 경로가 `CLAUDE_CONFIG_DIR`/`CODEX_HOME`을 무시.** history와 usage는 두 변수를 따르지만 (`ct/TowerCore/Sources/History.swift:94-98`, `ct/TowerCore/Usage.swift:307-311`), 실행 중 세션 수집은 `~/.claude/sessions`, `~/.claude/projects`, `~/.codex`를 하드코딩한다 (`ct/TowerCore/Sources/Claude.swift:59-60,117`, `ct/TowerCore/Sources/Codex.swift:135`). 변수를 설정한 환경에서는 live 세션과 history의 transcript 경로가 달라져 "실행 중" 표시가 어긋날 수 있다 **(추론)**.
3. **`teamBase`의 manifest 경로 가정.** `<stateBase>/<team>/manifest.json`만 본다 (`ct/TowerApp/TeamLaunch.swift:185`). MT config는 `state_root`를 바꿀 수 있지만 (`mt/config/parser.js:5`), manifest 파일 자체는 `config.state_root` 아래에 쓰인다 (`mt/commands/start.js:477`). 커스텀 state_root 팀은 재개 시 manifest의 워커 목록·group을 잃고 config만으로 시작한다 **(추론)**. 영향은 재개에 그치지 않는다. `loadTeams`는 base 바로 아래 디렉토리의 `manifest.json`만 열거하므로 (`ct/TowerCore/Sources/MyTeam.swift:107-125`), base 밖 state_root 팀은 실행 중에도 board와 작업판에 나오지 않는다 (C1, C2).
4. **liveness·mailbox 규칙 이중 구현.** C3, C5처럼 MT 로직을 Swift로 복제했고 공유 fixture나 계약 테스트가 없다. MT 쪽 변경이 CT 테스트를 깨지 않는다.
5. **goal-order unsupported 판정이 commander 에러 문구에 의존.** `unknown command 'goal-order'` 문자열 매칭 (`ct/TowerCore/GoalOrder.swift:71`). commander 버전이 문구를 바꾸면 구버전 my-team에서 `.unsupported` 대신 `.failed`로 보인다 **(추론: commander 문구는 실행으로 확인하지 않음)**.
6. **README 데이터 소스 표 누락.** README 표(`README.md:249-262`)에는 usage 원장(`~/.claude/projects` 증분 읽기 + `~/Library/Application Support/ControlTower/usage/v1` 쓰기), `~/teams/*.json`, `~/.my-team/docs/<team>`, `my-team status/start/shutdown` 실행이 없다. 각각 `Usage.swift:307-311`, `TeamLaunch.swift:8,242`, `Documents.swift:254-258`, `TeamLaunch.swift:119-130,281-295`.
7. **Tmux.swift 주석의 범위.** "Nothing here may select, send keys to, or kill anything" (`ct/TowerCore/Sources/Tmux.swift:3`)는 TowerCore 파일에 한정된 진술이다. 실제 select-window/select-pane은 TowerCore가 계획하고(`ct/TowerCore/Focus.swift:81-84`) TowerApp이 실행한다. 모순은 아니지만 "읽기 전용" 경계가 target 단위로 나뉘어 있다는 점은 유의할 만하다.

## 7. 추론 항목 목록

- C11: 커스텀 state_root 또는 base 이름 변경 시 history에서 팀 run 인식 실패
- 6-1: README/FocusRunner 문구가 T46 이전 상태로 남았다는 경위
- 6-2: `CLAUDE_CONFIG_DIR`/`CODEX_HOME` 설정 시 live/history 불일치 영향
- 6-3: 커스텀 state_root 팀 재개 시 manifest 정보 손실
- 6-5: commander의 unknown command 문구 형태
- 5.1: `EveryGCDWorkerBlocked.swift`의 용도
