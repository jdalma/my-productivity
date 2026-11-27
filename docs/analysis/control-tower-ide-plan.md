# control-tower IDE 구현 계획: 경로 4(B2) + 작업판 연동 (G4 / T15)

- 요청: 사용자 결정 D#4 "4번 + 작업판 연동으로 진행해"(goal `~/.my-team/docs/my-team/goals/G4-ct-ide-monaco.md` 요청 절). board 창 상세와 작업판 창 상세에 [Monaco 에디터 | 오른쪽 폴더 트리] + 하단 `PaneTerminal`. 에디터는 monaco-vscode-api + monaco-languageclient(B2), 목표 L1~L4.
- 기준: my-productivity main `6c0ca46`. 이 문서 작성 중 코드 수정, 커밋, 설치, 쓰기 명령은 하지 않았습니다. 작업판은 `my-team api board-status --input '{"team_name":"my-team"[,"task":…]}' --json`(읽기 전용)으로만 봤습니다.
- 입력: `docs/analysis/control-tower-ide-feasibility.md`(이하 "종합"), reports T9·T12·T13, 1차 티켓 T14(B2 spike)·T16(FileWatch)·T17(전체 읽기·쓰기 경계), `docs/analysis/control-tower-architecture.md`(이하 "CT 구조"), `docs/analysis/my-team-architecture.md`(이하 "MT 구조").
- 경로 접두어: `core/` = `tools/control-tower/Sources/TowerCore/`, `app/` = `tools/control-tower/Sources/TowerApp/`, `mt/` = `tools/my-team/src/`. 기능 단계 L1~L4는 종합 머리말 정의를 따릅니다.
- 표기: [확인] 파일·명령으로 검증, [문서] 공식 출처(원 보고서 링크), [추론] 검증하지 않음.

## 0. 결론

1. K1~K13 중 엔진과 무관한 7개(K1, K3, K7, K9, K10, K11, K13)는 내용이 그대로 남습니다. K1·K7 검증부는 T17, K3은 T16으로 이미 1차에 들어가 있습니다(T16·T17 티켓 What).
2. 바뀌는 것은 다섯입니다. K2·K4·K5는 "보기 칸"이 네이티브 `FileCodeView`에서 WKWebView 에디터 칸으로 바뀝니다. K8은 CESE `EditorView`에서 WKWebView 에디터 칸 + Swift↔JS 브리지로, K12는 ChimeHQ LanguageClient에서 "Swift가 언어 서버를 띄우고 JSON-RPC를 브리지로 중계"로 바뀝니다. K6(CESE PoC)은 T14 spike로 대체됩니다.
3. 새로 생기는 것은 둘입니다. K14 Monaco 번들 빌드(`editor-web/`), K15 파일 생성·이름 변경·삭제.
4. Swift 쪽 새 패키지 의존은 필요 없다고 봅니다. WKWebView는 시스템 프레임워크이고, JSON-RPC 프레임(`Content-Length`)은 직접 자릅니다(T12 §1.5) [추론]. 번들 위치를 `core/Resources/editor/`로 두면 `Package.swift`의 `.copy("Resources")`(`tools/control-tower/Package.swift:16`)가 그대로 담습니다 [확인]. 단 `scripts/bundle-app.sh:30`이 `cp Sources/TowerCore/Resources/*`(재귀 없음)이라 폴더를 복사하지 못하므로 이 줄은 바뀌어야 합니다 [확인: `sed -n 28,30p tools/control-tower/scripts/bundle-app.sh`].
5. 작업판 연동 후보 6개(W1~W6) 모두 my-team 변경 없이 됩니다. 필요한 값(`repro`, `summary`, `report_path`, `focus`, `repo`, `base_commit`, `commits`)은 `board-status` task 응답에 이미 있습니다(`mt/board/core/queries.js:256-296`) [확인]. control-tower 쪽은 `TaskBoardLanding`이 `repo`·`base_commit`·`commits`를 decode하지 않으므로(`core/TaskBoard.swift:849-889`) decode 추가가 필요합니다 [확인]. 계약 변경은 "finding에 구조화된 위치 필드"를 원할 때만 생기며 이 계획은 쓰지 않습니다(§2.7).
6. 2차 티켓은 15개(I1~I15)이고 병렬 묶음 5개로 나뉩니다(§3). 열린 결정 D#5~D#11 중 D#10·D#11이 가장 앞(I2 번들 빌드)을 막고, D#5·D#8이 에디터 상태 모델(I7)을, D#6·D#7이 작업판 배치(I6)를, D#9가 LSP(I11)를 막습니다(§4).

## 1. K 단계 재작성 (B2 기준)

각 단계: 무엇 / 파일 / 선행. "1차"는 G4 1차 티켓(T14·T16·T17)에 이미 들어간 범위입니다.

### 1.1 남는 것

| # | 무엇 | 파일 | 선행 | 1차 매핑 |
|---|---|---|---|---|
| K1 | 작업 트리 파일 전체 읽기. `readWorkingFile`의 2000줄 창(`core/Navigation.swift:89`) [확인]과 별개 함수. 크기 상한, binary 판정(NUL 8000 byte, 비 UTF-8, `:87` 주석) 유지, 내용 SHA-256 반환 | `core/Navigation.swift` 또는 새 `core/WorkingFileIO.swift` | 없음 | T17 What 1 |
| K3 | `FileWatch`: worktree 루트 FSEvents(file events flag), 첫 이벤트 75 ms 후 flush·이후 100 ms 고정 주기, 무시 목록, overflow 시 전체 재확인, 삭제 250 ms 지연. 배치·판정은 순수 함수 | 새 `core/FileWatch.swift` | 없음 | T16 What 1~4 |
| K7 | 저장: 쓰기 경로 검증(realpath, symlink 탈출 거부, `core/DocumentFolder.swift:92-97` `documentTarget`과 같은 방식 [확인]), compare-and-write, 같은 내용 쓰기 생략, 파일별 직렬화, self-write registry TTL 750 ms(T12 §4 표) | `core/WorkingFileIO.swift` | K1 | T17 What 2~3. 앱 연결(브리지의 `writeFile`)은 I4 |
| K9 | 키 라우팅. 에디터(웹뷰) 포커스 판정 + 메뉴 가드. `app/BoardView.swift:75`의 `PaneTerminalView.focused() == nil` 가드 [확인]를 "웹뷰가 first responder면 겹치는 메뉴 비활성"으로 확장(T12 §3.1 정할 규칙) | `app/BoardView.swift`, `app/TowerApp.swift:176-229`, 새 `app/EditorWebView.swift` | T14 spike 2 결과, I4 | 없음. 2차 I8 |
| K10 | README read-only 문구(`ct/README.md:5`, 종합 §6 그 밖의 위험 9)와 데이터 소스 표에 편집·언어 서버 실행 예외 추가 | `tools/control-tower/README.md` | D#5, D#7 답 | 2차 I7과 같은 PR |
| K11 | L3: `GitRead`(`core/Diff.swift:7-15`) [확인]에 `grep` 추가, 결과 파서, quick open 퍼지 매처(후보 `workspaceFiles`, `core/Diff.swift:183`) [확인]. UI는 Swift 쪽 목록 → 결과 클릭 시 브리지 `openFile(path, line)` | `core/Diff.swift`, 새 `core/Search.swift`, `app/IdeArea.swift` | I4 | 없음. 2차 I10 |
| K13 | 재접속 scrollback(`capture-pane -S`), IDE와 독립 | `app/PaneControl.swift` | 없음 | 없음. 2차 I15와 무관, 언제든 |

- B2에서 K11의 대안으로 VS Code search 서비스 override가 있지만(T12 §5 L3 행) [추론], 검색 실행은 Swift `git grep`으로 두는 쪽이 R54 경계(앱이 실행 대상을 정함)와 맞습니다. 웹뷰가 프로세스를 띄울 수 없기 때문이기도 합니다 [추론].

### 1.2 바뀌는 것

| # | 종합 §4의 원래 내용 | B2 기준 | 파일 | 선행 |
|---|---|---|---|---|
| K2 | 코드 보기와 트리를 `ChangesState`에서 분리 | 트리(`folderTree`, `app/ChangeTree.swift:32` [확인])만 분리합니다. 코드 보기는 Monaco가 맡으므로 `FileCodeView`(`app/CodeView.swift:78`) [확인]는 diff 창 전용으로 남깁니다. 트리 노드 모델을 `WorkspaceDiff` 없이도 그릴 수 있게(변경 표시는 선택) | `app/ChangeTree.swift`, `app/ChangesView.swift`, `app/DiffWindow.swift` | 없음 |
| K4 | board 상세 배치(`FileCodeView` 보기) | `app/BoardView.swift:783-791`의 terminal 분기 [확인]를 새 `app/IdeArea.swift`로: 위 [EditorWebView \| 트리(오른쪽, 탐색기·변경 목록 탭)], 아래 `PaneTerminal` 전폭(ignore-size 유지, 종합 §1). 비율 저장(worktree별, sidebar 폭 전역, 종합 §3 가져올 설계 2), 트리 접기, 최소 창 760×440(`BoardView.swift:41`) 재검토 | `app/BoardView.swift`, 새 `app/IdeArea.swift`, 새 `core/IdeLayout.swift`(비율·접힘 순수 모델) | K2, I4, K3(T16) |
| K5 | 작업판 상세에서 ticket·보고서를 앱 안 보기로 | `app/TaskBoardView.swift:674`의 `TaskDetailView` 자리를 [기존 상세(스크롤) \| IdeArea] 또는 탭으로. `narrow` 규칙(`TaskBoardView.swift:389-390,620`) [확인] 때문에 좁을 때는 상세와 IdeArea를 탭 전환으로 [추론]. 트리 루트는 D#6. `OpenPath`(`app/FileEditor.swift:149`) 행 중 텍스트 문서는 IdeArea로 열고, R54 M1 `openRefusal`(`FileEditor.swift:33-45`) [확인]은 외부 앱 열기 경로에 그대로 둡니다 | `app/TaskBoardView.swift`, `app/TaskDetailView.swift`, `app/TaskBoardDocuments.swift:164-175` | K4, D#6, D#7 |
| K6 | CESE PoC | 폐기. T14 spike(버전 조합, 번들 크기, worker 로딩, 브리지 한 바퀴, 키, LSP 한 바퀴)가 같은 자리입니다(T14 What 1~7) | 레포 밖 `~/.my-team/docs/my-team/spikes/T14/` | 없음 |
| K8 | CESE `EditorView`, 버퍼·탭·dirty·배너, `Package.swift` 의존 추가 | 두 티켓으로 나눕니다. (a) I4 `EditorWebView`: `WKURLSchemeHandler`로 `ct-editor://` 서빙(T12 §1.2 권장 2번), `WKScriptMessageHandlerWithReply`(JS→Swift, macOS 11+) + `callAsyncJavaScript`(Swift→JS, macOS 12+) 브리지(T12 §1.3), 테마는 앱 effective appearance 관찰 → `setTheme`(T12 §3.2), 글자 크기 `FontScale` → `updateOptions`(T12 §3.3). (b) I7 버퍼 정본·탭 모델·dirty·외부 변경 배너 4택(종합 §3 가져올 설계 5·6). `Package.swift` 의존 추가 없음(§0 4번) | (a) 새 `app/EditorWebView.swift`, 새 `core/EditorBridge.swift`(메시지 enum·Codable, 순수) (b) 새 `core/EditorBuffers.swift`, `app/IdeArea.swift` | (a) T14, I2(K14), T17 (b) I4, T16, D#5, D#8 |
| K12 | ChimeHQ LanguageClient 계열 Swift 패키지 | LSP 중계. Swift가 언어 서버를 `Process` + stdio로 띄우고(`runCommand` PATH 보강, `core/Support.swift:70-82`), `Content-Length` 프레임을 잘라 JSON 본문을 브리지로 넘깁니다. JS 쪽은 `MonacoLanguageClient`의 `messageTransports`에 브리지 기반 MessageReader/Writer를 줍니다(T12 §1.5) [추론]. 서버는 (언어, worktree 루트)당 1개, 창이 그 루트를 더 보지 않으면 종료, 앱 종료 시 전부 종료 | 새 `core/LanguageServer.swift`(프레임 파서·수명 정책, 순수), 새 `app/LanguageServerHost.swift`, `editor-web/src/lsp-transport.ts` | I4, D#9 |

### 1.3 새로 생기는 것

| # | 무엇 | 파일 | 선행 |
|---|---|---|---|
| K14 | Monaco 번들 빌드. 레포 안 `tools/control-tower/editor-web/`(Vite + TS, React 없음, T12 §4 첫 행)에서 `@codingame/monaco-vscode-*` + `monaco-languageclient`를 T14가 확정한 버전 조합으로 고정(`package-lock.json`). 산출물은 `core/Resources/editor/`. 서비스 묶음은 textmate·theme·keybindings·languages·files 최소 구성(T14 What 1), extension host는 D#10. 포함 패키지 라이선스 목록을 빌드가 생성해 `core/Resources/NOTICE.md`에 붙임(T12 §1.6) | `tools/control-tower/editor-web/**`, `core/Resources/editor/**`(D#11 a일 때만 커밋), `scripts/bundle-app.sh:28-30` | T14, D#10, D#11 |
| K15 | 파일 생성·이름 변경·삭제. 트리 context menu → Swift. 경로 검증은 K7 함수 재사용(새 경로·대상 경로 모두 worktree 안, realpath). 삭제는 휴지통(`FileManager.trashItem`)으로 [추론]. 이름 변경·삭제 대상이 열린 버퍼면 버퍼 경로 갱신 또는 "삭제됨" 표시(종합 §3 가져올 설계 9). 자기 동작은 self-write registry에 등록해 K3 이벤트와 중복 처리하지 않음 | `core/WorkingFileIO.swift`, `app/IdeArea.swift`(트리 menu) | K7(T17), K3(T16), I5. 허용 범위는 D#5 |

### 1.4 브리지 메시지 (I4에서 고정, 이후 티켓이 늘림)

| 방향 | 메시지 | 쓰는 단계 |
|---|---|---|
| JS→Swift (reply) | `readFile(path)` → `{text, hash, lang}` / `writeFile(path, text, baseHash)` → `ok \| conflict(diskHash) \| refused(reason)` | K1, K7 |
| JS→Swift (reply) | `lsp.send(serverId, json)` | K12 |
| JS→Swift (fire) | `dirtyChanged(path, dirty)`, `cursor(path, line, col)`, `ready` | K8, W4 |
| Swift→JS | `openFile(path, text, hash, lang, line?)`, `fileChangedOnDisk(path, text?, hash?)`, `fileDeleted(path)`, `setTheme`, `setFontSize`, `setReadOnly(path, bool)` | K4, K8, D#5 |
| Swift→JS | `openDiff(left: {label, text}, right: {label, text}, lang)`, `setMarkers(path, [{line, severity, message}])` | W2, W5 |
| Swift→JS | `lsp.receive(serverId, json)` | K12 |

- 모든 Swift→JS 호출은 `callAsyncJavaScript`의 `arguments`로 값을 넘기고 문자열로 JS를 조립하지 않습니다(T12 §1.3).
- `readFile`·`writeFile`의 경로는 JS가 보내도 Swift가 현재 창의 허용 루트 안인지 매번 다시 판정합니다. 웹뷰는 신뢰 경계 밖으로 둡니다 [추론].

## 2. 작업판 연동 기능

공통 사실:
- control-tower는 작업판을 `my-team api board-status --json`으로만 읽습니다(`core/TaskBoard.swift:3-4`, CT 구조 §2.2) [확인]. task를 주면 family 전체(`root, tasks, answers, progress, landings, verdicts, findings, fixed_elsewhere, notes`)가 옵니다(`mt/board/core/queries.js:256-296`) [확인: T10 응답 키 목록]. control-tower decode는 `TaskFamily`(`core/TaskBoard.swift:943`), `readTaskFamily`(`:1009`).
- 열(board.db): `tasks.base_commit`, `landings.repo·commit·base_commit·commits·focus·report_path·review_report_path`, `verdicts.report_path`, `findings.summary·repro`(`mt/board/store/sqlite/schema.js:16-39`, 필드 계약 `mt/board/core/contract.js:50-94`) [확인].
- `repro`·`summary`는 자유 텍스트입니다(`mt/board/core/service.js:553`의 `text(f.repro, 'repro')`) [확인]. 실제 값은 `Name.swift:123`, `sed -n '198,234p' /abs/path`, `git show 6c0ca46:tools/…/X.swift | sed -n 255,258p` 같은 형태입니다 [확인: T1·T3·T9·T11·T12 family의 findings]. 그래서 위치는 control-tower가 파싱합니다.
- 문서 태스크의 landing은 `repo`·`commit`·`base_commit`이 빈 문자열이고 `commits`가 `[]`입니다(`service.js:439-440,451`) [확인: T10#1 응답].
- 워커 worktree는 워커별로 재사용됩니다(`.worktrees/dev-tower`가 T4·T6에, `dev-myteam`이 T5·T7에) [확인: T4~T7 landing `repo`]. done 태스크의 `landing.repo`는 지금 다른 태스크 브랜치일 수 있으므로, 지난 태스크의 내용은 작업 트리가 아니라 커밋 객체(`git show <commit>:<path>`)로 읽어야 합니다 [추론].

### 2.1 W1 finding·보고서의 파일:줄 → 에디터 이동

- 무엇: finding의 summary·repro, 담당·리뷰 보고서 안의 `path:line[-line]`, `sed -n 'a,bp' path`, `<commit>:path`를 링크로 바꾸고, 클릭하면 IdeArea 에디터가 그 파일을 열고 그 줄로 이동·강조합니다.
- 데이터 출처:
  - finding: `findings.summary`, `findings.repro`(`schema.js:34-39`). control-tower decode `TaskBoardFinding.summary·repro`(`core/TaskBoard.swift:174-184`) [확인]. 현재 표시는 summary `app/TaskDetailView.swift:657`, repro는 "재현" DisclosureGroup 안 `CopyText`(`:668-675`) [확인].
  - 보고서: `landings.report_path`, `verdicts.report_path`(`schema.js:25,31`). decode `TaskBoardLanding.reportPath`(`core/TaskBoard.swift:857,881`), `TaskBoardVerdict.reportPath`(`:896,911`). 표시 `OpenPath` 행 `app/TaskDetailView.swift:772-773`(담당), `:786`(리뷰), ticket `:838` [확인].
- 경로 해석 순서 [추론]: (1) 절대 경로 (2) `<commit>:<rel>` → finding의 `verdict_id` → `verdicts.landing_id` → `landings.repo`에서 `git show` (3) 상대 경로 → 같은 landing의 `repo`, 없으면(문서 태스크) 담당 워커 cwd(`app/TaskDetailView.swift:332`의 `workerRow(t.assignee)?.session.cwd`), 그것도 없으면 링크 대신 텍스트 그대로. 파일 이름만 있는 `X.swift:123`은 `workspaceFiles`에서 basename 유일 매치일 때만 링크.
- 화면: 작업판 창 상세(findings 절, 이력 절 보고서 행). 보고서는 IdeArea에 Markdown으로 열리고, 그 안의 `path:line`도 같은 파서로 링크(Monaco link provider, JS 쪽) [추론].
- 필요한 K: K1, K4·K5(IdeArea), K8a(I4 `openFile(…, line)`). `<commit>:path`는 `GitRead`에 `show` 추가가 필요합니다(지금 허용 enum에 없음, `core/Diff.swift:7-15`) [확인]. 열린 파일은 읽기 전용(커밋 내용이므로).
- my-team 변경: 없음.
- 확인: 파서는 `swift test`(TowerCoreTests에 위 세 형태와 오탐 사례: URL `http://x:80`, 시간 `12:30`) RED→GREEN.

### 2.2 W2 태스크 base 대비 landing diff를 Monaco diff로

- 무엇: 이력의 제출(landing) 행에 "diff" 버튼. 파일 목록(변경 파일 트리)을 오른쪽에, 선택 파일을 Monaco diff editor(왼쪽 `base_commit:path`, 오른쪽 `commit:path`)로 보여 줍니다. 진행 중 태스크는 `task.base_commit` 대 작업 트리 HEAD+미커밋(기존 `commitFlow`와 같은 기준).
- 데이터 출처:
  - `landings.repo·base_commit·commit·commits`(`schema.js:23-24`). `base_commit`은 "마지막 approve된 landing commit, 없으면 task base"입니다(`mt/board/core/service.js:451-456`) [확인]. 그래서 두 번째 제출의 diff는 "앞 승인 이후 변경"이고, 태스크 전체 diff는 `tasks.base_commit..landing.commit`입니다.
  - control-tower decode: `TaskBoardLanding`에 `repo`, `baseCommit`, `commits`가 없습니다(`core/TaskBoard.swift:849-889`의 CodingKeys) [확인]. 세 필드를 optional로 추가합니다(하위 호환 decode 관례, CT 구조 §2.2 끝).
  - `tasks.base_commit`: decode 있음(`TaskBoardTask.baseCommit`, `core/TaskBoard.swift:16`), 표시 `app/TaskDetailView.swift:841`, 진행 중 커밋 흐름 `commitFlow`(`core/TaskTracking.swift:226-234`, 호출 `app/TaskDetailView.swift:376-379`) [확인].
- 읽기: 파일 목록 `git diff --name-status base commit`(`GitRead.diff` 이미 허용), 내용 `git show <rev>:<path>`(`GitRead`에 `show` 추가). `--end-of-options` 관례(`TaskTracking.swift:231`) 유지.
- 화면: 작업판 창 상세의 IdeArea 에디터 칸에 diff 탭. 트리 칸은 "변경 목록" 탭(종합 §3 가져올 설계 1)에 diff 파일 목록.
- 필요한 K: K2(트리 분리), K5, I4 `openDiff`. diff 창(`app/DiffWindow.swift`)은 그대로 두고 대체하지 않습니다.
- my-team 변경: 없음(필드는 이미 응답에 있음 [확인: T4#1 `repo`·`base_commit`·`commits` 값]).
- 문서 태스크(`commit == ""`)는 버튼을 숨깁니다.

### 2.3 W3 워커가 지금 고치는 파일 표시 + 편집 경고

- 무엇: 트리와 탭에 "워커가 최근 N초 안에 쓴 파일" 표시(점·색). 그 파일을 사용자가 편집하려 하면 경고 배너("analyst가 12초 전에 이 파일을 썼습니다"), D#5가 b면 잠금 해제 동작에 이 경고를 붙입니다.
- 데이터 출처:
  - FileWatch(K3, T16) 이벤트 on 워커 cwd. cwd는 `Session.cwd`(`core/Model.swift:61`) [확인], 작업판에서는 `workerRow(t.assignee)?.session.cwd`(`app/TaskDetailView.swift:332`, 구현 `app/TaskBoardView.swift:710-712`) [확인].
  - 워커 바쁨 상태 `Status.busy|wait`(`core/Model.swift:11-12`) [확인]. busy일 때만 "고치는 중"으로 [추론].
  - 미커밋 변경 목록: `workspaceDiff`(`core/Diff.swift:159`)의 diff-index 결과. 지금 diff 창과 `WorkerDiffTotals`(`app/WorkerDiffTotals.swift`)가 같은 값을 씁니다.
  - 귀속의 한계: FileWatch는 "누가" 썼는지 모릅니다. 같은 worktree에 쓰는 주체가 워커뿐이고 사용자 저장은 self-write registry가 걸러내므로, "self-write가 아닌 쓰기 = 워커"로 봅니다 [추론]. 더 정확히 하려면 Claude transcript의 Edit/Write tool_use `file_path`를 읽어야 하는데, 지금 control-tower에는 tool_use 파서가 없습니다(`core/` 전체 grep `tool_use` 0건) [확인]. 이 계획은 transcript 파싱을 넣지 않습니다.
- 화면: board 창 상세 IdeArea(워커 = 그 행의 세션), 작업판 창 상세 IdeArea(D#6 a·c일 때). 트리 행 표시, 에디터 탭 표시, 편집 경고 배너.
- 필요한 K: K3, K4/K5, K8b(I7 배너·잠금).
- my-team 변경: 없음.

### 2.4 W4 태스크별 열린 파일 기억

- 무엇: 작업판 상세에서 태스크를 바꾸면 그 태스크에서 마지막으로 열었던 탭·커서·트리 펼침을 복원합니다. board 창은 worktree별(종합 §3 가져올 설계 2).
- 데이터 출처: 앱 자체 저장. 작업판 쪽 prefs는 이미 `@AppStorage` JSON으로 저장합니다(`app/TaskBoardView.swift:394-396,409`, 인코딩 `core/TaskBoard.swift:739-748`의 `readPanelPrefs`·`storedPanelPrefs`) [확인]. 같은 방식으로 키 `(team, task id)` → `{tabs:[path], active, cursor:{path:line}}`. 저장 크기 상한(태스크 수 N, 오래된 것부터 버림) [추론].
- 화면: 작업판 창 상세 IdeArea.
- 필요한 K: K5, I7(탭 모델), 브리지 `cursor`.
- my-team 변경: 없음. 태스크 키는 `tasks.id`.
- 확인: 저장·복원 순수 함수 `swift test`, 수동: T_a에서 파일 2개 열고 T_b로 갔다가 돌아오면 같은 탭과 줄.

### 2.5 W5 열린 finding을 에디터 gutter 표시로

- 무엇: 태스크의 open finding이 가리키는 `path:line`이 지금 열린 파일이면 그 줄에 severity 색 marker와 hover(summary, finding id). 수정 중인 사람이 지적을 코드 옆에서 봅니다.
- 데이터 출처: W1 파서 결과 + `TaskDetail.openFindings`(`core/TaskBoard.swift:1107`, open 판정 `findingStatus` `:1025`) [확인]. 줄은 finding이 쓰인 커밋 기준이라 이후 편집으로 어긋날 수 있습니다. 그 파일이 `raisedIn` landing 커밋 이후 바뀌었으면 marker를 "위치 추정"으로 흐리게 표시 [추론].
- 화면: 작업판 창 상세 IdeArea 에디터. board 창에서도 그 워커가 담당한 태스크의 open finding을 쓸 수 있으나(`workerTasks`, `core/TaskBoard.swift:1143`) 범위는 작업판 창으로 시작합니다.
- 필요한 K: W1, I4 `setMarkers`.
- my-team 변경: 없음.

### 2.6 W6 리뷰어에게 남긴 "볼 곳"(landing.focus)의 파일:줄

- 무엇: landing의 `focus` 목록(리뷰어에게: 볼 곳)도 W1 파서로 링크화합니다. 리뷰어가 control-tower에서 리뷰할 때 바로 그 줄로 갑니다.
- 데이터 출처: `landings.focus`(`schema.js:25`, `contract.js:70`의 `focus: list(req)`, 입력 `service.js:442`) [확인]. decode `TaskBoardLanding.focus`(`core/TaskBoard.swift:855`), 표시 `app/TaskDetailView.swift:765-767` [확인].
- 해석 기준 커밋: 그 landing의 `commit`(작업 트리가 아니라 제출 시점 내용). 진행 중이면 작업 트리.
- 필요한 K: W1과 같음.
- my-team 변경: 없음.

### 2.7 넣지 않은 후보와 계약 변경 여부

- `check_cmd`·`rerun_cmd`를 에디터에서 실행: 앱이 보드 문자열을 실행하게 되므로 R54 M1 취지(`app/FileEditor.swift:27-32` 주석)와 충돌합니다. 넣지 않습니다.
- finding에 `file`·`line` 구조화 필드 추가: `findings` 테이블과 `KINDS.finding`(`contract.js:86-93`) 변경 + schema 7 migration + `board-verdict` 입력 변경이 필요한 **계약 변경**입니다. W1 파서의 오탐·누락이 실사용에서 문제가 될 때 다시 봅니다. 이 계획에서는 요청하지 않습니다.
- 커밋 흐름(`commitFlow`) 줄 클릭 → 그 커밋 diff: W2의 변형으로 I13에 포함합니다(같은 `openDiff`, 기준만 `<sha>^..<sha>`).

## 3. 티켓 분할과 순서

1차(진행 중): T14 B2 spike, T16 FileWatch(K3), T17 전체 읽기·쓰기 경계(K1 + K7 검증부), T15 이 문서. 2차는 아래 I1~I15이고 G4 "순서" 절에 추가될 후보입니다. 모든 코드 티켓은 `cd tools/control-tower && swift test` 통과를 닫는 조건으로 하고, 수동 시나리오는 `scripts/test-instance.sh`(별도 HOME·tmux 소켓·`TOWER_DRY_RUN`)로 돌립니다(종합 §4 끝).

### 3.1 티켓 표

| # | 범위(K/W) | 모듈·파일 경계 | 선행 | 확인 방법 |
|---|---|---|---|---|
| I1 | W1·W6 파서, W2 git 읽기 | TowerCore만: 새 `core/FileRefs.swift`(텍스트 → `[FileRef{path, lineStart, lineEnd?, commit?}]`), `core/Diff.swift` `GitRead.show` 추가 + `diffFiles(base:head:)`·`fileAt(rev:path:)`, `core/TaskBoard.swift` `TaskBoardLanding`에 `repo`·`baseCommit`·`commits` decode | 없음 | `swift test`: 파서 표본(T1~T12 실제 repro 문자열을 fixture로), 오탐 사례, 임시 git repo에서 show·name-status, 옛 응답(필드 없음) decode |
| I2 | K14 | `tools/control-tower/editor-web/` 신설, `scripts/bundle-app.sh:28-30`, `core/Resources/editor/`, NOTICE | T14, D#10, D#11 | `npm ci && npm run build` 산출물 크기 기록, `scripts/bundle-app.sh` 후 `.app/Contents/Resources/editor/index.html` 존재. D#11 b면 node 없는 PC에서 빌드 실패 메시지 확인 |
| I3 | K2 | TowerApp: `app/ChangeTree.swift`, `app/ChangesView.swift`, `app/DiffWindow.swift` | 없음 | `swift test`(ChangesStateTests, ChangeTreeTests, CodeNavigationTests 통과) + diff 창 수동(트리 클릭, ⌘클릭 정의 이동) |
| I4 | K8a + 브리지 | 새 `app/EditorWebView.swift`(scheme handler, message handler), 새 `core/EditorBridge.swift`(메시지 Codable·경로 재판정, 순수) | T14, I2, T17 | `swift test`: 메시지 encode/decode, 허용 루트 밖 `readFile`·`writeFile` 거부. 수동: 테스트 인스턴스에서 파일 열기 → 편집 → 저장 → 디스크 반영, 웹 인스펙터 콘솔에 worker 오류 없음 |
| I5 | K4 | `app/BoardView.swift:783-791`, 새 `app/IdeArea.swift`, 새 `core/IdeLayout.swift` | I3, I4, T16 | `swift test`(비율·접힘 모델). 수동: 워커 선택 → 트리 → 파일 열기 → 워커가 그 파일 수정 → 5초 안에 화면 갱신(깨끗한 버퍼), 터미널 입력 중 ⌘K로 빠져나오기 유지 |
| I6 | K5 | `app/TaskBoardView.swift:620,674`, `app/TaskDetailView.swift`(OpenPath 행 → IdeArea), `app/TaskBoardDocuments.swift:164-175` | I5, D#6, D#7 | `swift test`(TaskDetailTests, TaskBoardDocumentsTests, FileEditorTests). 수동: done task(워커 없음)에서 트리 동작, 좁은 창에서 탭 전환 |
| I7 | K8b + K10 | 새 `core/EditorBuffers.swift`(버퍼 정본·탭·dirty·배너 상태 전이), `app/IdeArea.swift` 배너, `tools/control-tower/README.md` | I4, T16, T17, D#5, D#8 | `swift test`(상태 전이: clean+외부 변경→reload, dirty+외부 변경→배너, Overwrite만 디스크 덮음, 삭제 250 ms). 수동: dirty 상태에서 워커가 같은 파일 수정 → 배너 4택 각각 |
| I8 | K9 | `app/TowerApp.swift:176-229`, `app/BoardView.swift:64-75`, `app/EditorWebView.swift`(포커스 판정), `editor-web/src/keys.ts` | I4, T14 spike 2 | `swift test`(포커스 → 키 소비자 판정 함수). 수동: 에디터·터미널·트리 포커스별 ⌘F, ⌘K(chord 포함), Esc, ⌘[, ⌘], ⌘D, ⌘W, ⌘Z, ⌘P, ⌘⇧P, ⌘+/- (종합 §6 표 전 행) |
| I9 | K15 | `core/WorkingFileIO.swift`(create/rename/trash + 경로 검증), `app/IdeArea.swift` 트리 menu | T17, T16, I5, D#5 | `swift test` RED→GREEN: worktree 밖 대상·symlink 탈출 거부, 이름 충돌, 열린 버퍼 경로 갱신. 수동: 생성·이름 변경·삭제 후 트리와 워커 `git status` 일치 |
| I10 | K11 | `core/Diff.swift`(`GitRead.grep`), 새 `core/Search.swift`, `app/IdeArea.swift` | I4 | `swift test`(grep 출력 파서, 퍼지 점수). 수동: orca 규모 worktree에서 검색 1초 안팎(종합 §1 L3 행 기준 0.75~0.83초) |
| I11 | K12 | 새 `core/LanguageServer.swift`(프레임 파서·수명), 새 `app/LanguageServerHost.swift`, `editor-web/src/lsp-transport.ts` | I4, D#9 | `swift test`(분할·결합 프레임, 다중 메시지 한 read, 서버 종료 시 정리). 수동: 이 레포 Swift 파일에서 sourcekit-lsp completion·정의 이동·진단(T14 What 6과 같은 시나리오) |
| I12 | W1·W6·W5 | `app/TaskDetailView.swift:657,668-675,765-773,786`(링크화), `app/IdeArea.swift`(`openFile(line)`, `setMarkers`) | I1, I6 | 수동: 실제 finding(예: T9 family `R9 L1`)에서 링크 클릭 → 그 줄. 파일 없음·문서 태스크·`<commit>:path` 각 경로 |
| I13 | W2(+커밋 흐름 클릭) | `app/TaskDetailView.swift`(제출 행 버튼, `commitFlowView` `:560`), `app/IdeArea.swift` diff 탭 | I1, I6 | 수동: T4#1(`repo` dev-tower, base 6c0ca46, commit 60ac75b)에서 파일 목록·diff 표시, 문서 태스크는 버튼 없음 |
| I14 | W3·W4 | `app/IdeArea.swift`(트리·탭 표시, 편집 경고), `core/IdeLayout.swift`(태스크별 열린 파일 저장) | T16, I6, I7 | `swift test`(최근 쓰기 집합 만료, 저장·복원). 수동: 워커가 파일을 쓰는 동안 표시와 경고, 태스크 전환 복원 |
| I15 | K13 | `app/PaneControl.swift` | 없음 | `swift test`(PaneControlTests) |

### 3.2 병렬 묶음과 순서

| 묶음 | 티켓 | 시작 조건 | 비고 |
|---|---|---|---|
| P0 | I1, I3, I15 | 지금(1차와 병렬 가능) | 서로 파일이 겹치지 않습니다(TowerCore 파서·git / diff 창 트리 / PaneControl) |
| P1 | I2 | T14 결과 + D#10·D#11 답 | 레포 밖 spike 코드를 레포 안으로 옮기는 단계 |
| P2 | I4 | I2, T17 머지 | 이후 모든 UI의 기반. 단독 |
| P3 | I5, I8, I10, I11 | I4 머지(I5는 I3·T16도, I11은 D#9도) | I5와 I8은 `app/BoardView.swift`를 함께 건드립니다. I8은 `:64-75`, I5는 `:783-791`이라 충돌 범위는 작지만 같은 파일이므로 I5 먼저 머지 [추론] |
| P4 | I6, I7, I9 | I5 머지(+ 각 결정) | I6·I7·I9 모두 `app/IdeArea.swift`를 건드립니다. 영역(I6 루트 선택, I7 배너, I9 트리 menu)을 나누고 순차 머지 |
| P5 | I12, I13, I14 | I6 머지(I14는 I7도) | `app/TaskDetailView.swift` 공유. I12(findings·이력 행)와 I13(제출 버튼·커밋 흐름)은 줄 범위가 다름 |

- 임계 경로: T14 → (D#10, D#11) → I2 → I4 → I5 → I6 → I12/I13. 결정이 늦으면 P0과 I3만 진행됩니다.
- 한 워커 연속 배정이 유리한 묶음: I4→I8(브리지·포커스), I5→I6(배치), I12→I13(`TaskDetailView`) [추론].

## 4. 열린 결정 D#5~D#11의 영향

목표 단계는 L1~L4로 정해졌습니다(D#4). 종합 §5의 6·7·8·10·12번은 경로 4에 해당하지 않아 제외합니다. 각 결정의 선택지·권장은 작업판 `decisions`(board-status)의 내용입니다.

### D#5

- 질문: 에이전트 worktree 편집: (a) 바로 편집, 충돌은 배너 4택 / (b) 기본 읽기 전용, 잠금 해제 후 편집 (권장 b)
- 영향 티켓: I4, I7, I9, I14, K10
- 답 (a) 브리지 `setReadOnly` 불필요, I7 배너가 주 경로, I14 경고는 표시만.
- 답 (b) I7에 잠금 상태(파일별 또는 worktree별) 추가, `setReadOnly` 기본 true, 잠금 해제 동작에 W3 경고 연결, I9 생성·이름 변경·삭제도 잠금 해제 뒤에만. README 문구(K10)가 "사용자가 잠금을 푼 파일만 씀"으로 좁아짐

### D#6

- 질문: 작업판 상세 트리 폴더: (a) 담당 워커 worktree / (b) 팀 문서 폴더 / (c) 둘 다(루트 전환) (권장 c)
- 영향 티켓: I6, I12, I13, I14
- 답 (a) 워커가 없으면 트리가 빔. done 태스크는 `landing.repo`(I1 decode)로 대체할 수 있으나 그 worktree는 다른 태스크로 넘어갔을 수 있어(§2 공통 사실) 내용은 커밋 객체로만 [추론].
- 답 (b) `listFolderDocuments`(`core/DocumentFolder.swift:69`)·`documentTarget`(`:92-97`) 재사용으로 I6이 가장 작아짐. I12의 코드 경로 링크는 트리 밖 파일을 열게 되므로 "트리 루트와 무관하게 에디터만 연다" 규칙 필요, I14는 작업판 창에서 빠짐.
- 답 (c) I6에 루트 전환 UI(탭 2개 또는 picker)와 W4 저장 키에 루트 포함

### D#7

- 질문: 작업판 문서 편집: (a) 편집, 문서 폴더 안만 저장 / (b) 읽기만 (권장 a)
- 영향 티켓: I4, I6, I7, K10
- 답 (a) K7 허용 루트에 팀 문서 폴더 추가(T17 경로 검증 함수가 루트 목록을 받도록), 문서 탭은 D#5와 무관하게 편집 가능.
- 답 (b) 문서 탭은 항상 `setReadOnly(true)`, I6은 보기만이라 작아짐

### D#8

- 질문: 두 창 에디터 상태: (a) 버퍼 앱 전역, 탭 창별 / (b) 창별 완전 분리 (권장 a)
- 영향 티켓: I4, I7, I14
- 답 (a) `core/EditorBuffers.swift`가 앱 전역 `@Observable` 정본. 웹뷰마다 Monaco model이 따로 있으므로 한 창의 편집을 다른 창 웹뷰로 push하는 메시지(`bufferChanged(path, text, version)`)가 브리지에 추가됨.
- 답 (b) 창별 버퍼. 같은 파일을 두 창에서 고치면 두 번째 저장이 K7 해시 불일치로 배너가 뜸. I7이 작고 브리지 메시지가 하나 줄어듦

### D#9

- 질문: LSP 대상 언어·설치: (a) 사용자 설치, 앱은 탐색 / (b) 앱이 안내·설치. 언어 후보 Swift, TypeScript, Kotlin, Java, Python (권장 a)
- 영향 티켓: I2, I11
- 언어 집합이 K14 번들의 TextMate 문법·`*-default-extension` 패키지 목록과 I11 서버 탐색 표를 정함.
- 답 (a) I11은 PATH(`core/Support.swift:70-82`)·`JAVA_HOME` 탐색과 "서버 없음" 안내 문구만.
- 답 (b) 설치 명령 실행과 버전 확인이 I11에 추가되고, 앱이 설치 프로세스를 띄우는 새 실행 경로라 R54 검토가 따라옴. Java(jdtls)는 Java 25 이상 필요, Kotlin LSP는 Alpha(종합 §1 L4 행)

### D#10

- 질문: 웹뷰 안 VS Code web 확장 실행: (a) 허용 안 함 / (b) 허용 (권장 a)
- 영향 티켓: I2, I4
- 답 (a) K14에서 extension host worker 서비스를 빼고 문법·테마는 `*-default-extension`만 정적 포함. 번들이 작아지고 T14 spike 1의 extension host worker 항목이 불필요.
- 답 (b) extension host worker와 확장 설치 경로(Open VSX 다운로드 또는 번들 포함)가 필요. 확장 출처 관리와 웹뷰 안 코드 실행을 README·R54 문서에 명시

### D#11

- 질문: Monaco 번들: (a) dist 커밋 / (b) `bundle-app.sh`에 npm 빌드 단계 (권장은 T14 크기 실측 뒤)
- 영향 티켓: I2, (간접) I4 이후 전부
- 답 (a) `core/Resources/editor/`를 커밋. `bundle-app.sh`는 `cp -R`로 바꾸는 한 줄. 의존 갱신 때마다 수 MB diff, public-scan(`scripts/public-scan.sh`) 대상 크기 증가.
- 답 (b) `editor-web/` 소스와 lockfile만 커밋, `bundle-app.sh` 앞에 `npm ci && npm run build`, `swift test`는 번들 없이 돌아야 하므로 I4의 테스트는 리소스 없는 경우를 다룸. 빌드 PC에 node 필요

### 결정 필요(미등록)

작업판에 D#로 올라가 있지 않지만 G4 가정 절의 approval stop에 걸리거나 걸릴 수 있는 항목입니다.

1. `Package.swift` 의존 추가: 이 계획은 추가하지 않습니다(§0 4번). T14가 Swift 쪽 패키지(예: JSON-RPC 라이브러리)를 필요하다고 판단하면 그때 사용자 결정이 필요합니다. 영향: I4, I11.
2. `scripts/bundle-app.sh` 변경: D#11 어느 답이든 `:30` 줄은 바뀝니다(a는 `cp -R`, b는 npm 단계 추가). G4 가정 절은 "public 레포에 dist 커밋"(a)과 "npm 빌드 단계 추가"(b)를 둘 다 approval stop으로 적고 있습니다(`~/.my-team/docs/my-team/goals/G4-ct-ide-monaco.md:15`) [확인]. 따라서 D#11의 답 자체가 그 승인이고, `:30` 변경은 별도 결정이 필요 없습니다. 영향: I2.
3. 언어 서버 프로세스 실행: 앱이 git·tmux·my-team 외의 실행 파일(sourcekit-lsp 등)을 처음 띄웁니다. 종합 §2 선택지 4는 "언어 서버 실행은 앱이 통제"로 R54와 충돌하지 않는다고 봤습니다(T12 §5 R54 행). 실행 대상을 고정 목록(언어 → 실행 파일 이름)으로만 두면 별도 결정 없이 진행 가능하다고 봅니다 [추론]. 영향: I11.

## 5. 위험과 미확인

1. T14 결과 의존: worker 로딩(spike 1), 키 순서(spike 2), languageclient 버전 정렬(monaco-languageclient 11.0.3 기준 monaco-vscode-api 37.6.0, 최신 40.1.0 [문서, T12 §1.5])이 실패하면 I2·I4·I8·I11의 형태가 바뀝니다. spike 1 실패 시 blob worker 우회(T12 §1.2), spike 2에서 웹뷰가 key equivalent를 먼저 받지 못하면 I8이 `performKeyEquivalent` override 서브클래스로 커집니다 [추론].
2. ⌘K: board 창 숨은 검색 버튼(`app/BoardView.swift:66-69`) [확인]와 Monaco chord 접두어가 겹칩니다. 규칙은 "웹뷰 포커스면 숨은 버튼 비활성"이고, 터미널에서 빠져나오는 용도는 터미널 포커스일 때만 유지합니다(I8).
3. 웹뷰 메모리: 창마다 WebContent 프로세스 1개 + 언어 서버(T9 §5.4) [추론]. 미측정입니다. I5 수동 시나리오에서 Activity Monitor 값을 기록합니다.
4. W1 파서 오탐: `12:30`, URL 포트, `T75#2` 같은 보드 id. fixture를 실제 repro 문자열로 두고, 링크는 해석이 성공한 경우에만 붙입니다.
5. 공유 worktree: 워커 worktree가 태스크 사이에 재사용되므로(§2 공통 사실) 지난 태스크를 작업 트리로 보여 주면 틀린 내용이 됩니다. W1·W2·W6은 landing 커밋 기준으로 읽습니다.
6. 문법 강조 이원화: diff 창 highlight.js, 에디터 TextMate(T12 §1.4). 이 계획은 diff 창을 바꾸지 않습니다.
