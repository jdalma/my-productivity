# control-tower IDE화 구현 가능성 종합 (G3 / T10)

- 요청(G3, 2026-11-24): control-tower의 터미널 영역과 상세 영역을 VS Code 같은 IDE로 쓰고, 오른쪽에 프로젝트 폴더를 둔다. orca를 참고한다. "비용은 생각하지마".
- 대상 영역: board 창 상세(`DetailView`)와 작업판 창 상세(`TaskDetailView`) 둘 다입니다(사용자 결정, G3 가정).
- 기준: my-productivity main `6c0ca46`, orca `30c09a46` [확인] (`git rev-parse --short HEAD` 양쪽). 이 문서 작성 중 코드 수정, 커밋, 설치는 하지 않았습니다.
- 입력: T8(orca 에디터·탐색기), T9(control-tower 구조와 경로 A~E), T11(경로 A 부품), T12(경로 B·C), T13(orca 터미널·레이아웃·동시 편집)과 각 리뷰 R8~R12, `docs/analysis/control-tower-architecture.md`(T2). 보고서 위치는 `~/.my-team/docs/my-team/reports/`이고, 아래에서는 "T9 §2 기능 단계 표"처럼 절 이름으로 가리킵니다.
- 경로 접두어: `ct/` = `tools/control-tower/`. 기능 단계 L1~L5와 경로 A~E는 T9 §2, §3의 정의를 따릅니다.
  - L1 오른쪽 폴더 트리 + 읽기 전용 보기, L2 편집·저장·탭·dirty, L3 프로젝트 검색·quick open, L4 LSP, L5 VS Code 확장 호환.
  - A 네이티브 Swift 에디터, B WKWebView + Monaco(B1 순수 monaco-editor, B2 monaco-vscode-api + monaco-languageclient, T12 §5 구분), C VS Code 웹판 내장(code-server / openvscode-server), D 외부 VS Code 연동, E Electron 재작성 또는 orca 채택.
- 표기: [확인] 파일·명령으로 검증, [문서] 공식 출처(링크는 원 보고서에 있음), [추론] 검증하지 않음.

## 1. 결론

| 단계 | 판정 | 근거 |
|---|---|---|
| L1 | 구현 가능 | 트리·읽기 전용 보기 부품이 diff 창에 이미 있습니다. `folderTree`(`ct/Sources/TowerApp/ChangeTree.swift:31-38`), `workspaceFiles`(`ct/Sources/TowerCore/Diff.swift:183-188`), `FileCodeView`(`CodeView.swift:78-166`), `DiffTreeSidebar`(`DiffWindow.swift:124`) [확인, T9 §2 기능 단계 표]. 넣을 자리는 board 상세 `detailBody`의 terminal 분기 한 곳(`BoardView.swift:783-791`) [확인] |
| L2 | 조건부 | 앱 전체에 작업 트리 쓰기 코드와 파일 감시가 0건입니다(T9 요약, T13 §3.5 끝 "control-tower 현황과의 대응"). 저장 경로 검증, FSEvents 감시, dirty 충돌 처리를 처음 만들어야 합니다. 조건은 두 가지입니다. (1) 편집 허용 범위를 사용자가 정한다(§5). (2) 에디터 엔진의 PoC가 통과한다(A는 CESE 빌드·라이선스, B는 spike 1 worker 로딩) |
| L3 | 구현 가능 | `git grep`이 orca 규모(34,382 파일)에서 0.75~0.83초(warm) [확인, T11 §4]. quick open 후보는 `workspaceFiles`(orca 0.15초) [확인, T11 §2]. 새 의존성이 없습니다 |
| L4 | 조건부 | 언어 서버 공급이 조건입니다. A는 ChimeHQ LanguageClient(BSD-3) 외 유지되는 Swift 선택지가 없고 열린 이슈 #22·#24·#27(종료 문제)이 있습니다 [확인, T11 §3]. B는 B2 스택(monaco-vscode-api 위에서만 도는 languageclient) 전환이 필요합니다 [문서, T12 §1.5]. Kotlin LSP는 Alpha, jdtls는 Java 25 이상이 필요합니다 [확인, T11 §3 언어 서버 표] |
| L5 | 사실상 불가 (VS Code 동등 수준). Open VSX 한정이면 C로 조건부 | MS Marketplace 확장은 약관상 MS 제품 전용이라 어느 경로로도 쓸 수 없습니다 [문서, T12 §2.4]. C(code-server)는 Open VSX 확장만 됩니다 [문서, T12 §0]. B2는 web worker 확장만 됩니다 [문서, T12 §5]. A·B1·E는 불가입니다(T9 §2 기능 단계 표, T11 §5) |

- 경로 A 결론에 붙는 한 줄: CodeEditSourceEditor(CESE) 본체는 MIT이지만, 필수 의존 CodeEditLanguages·CodeEditSymbols에는 LICENSE 파일이 없습니다 [확인, T11 결론 1, R10 S1]. 이 binary가 .app에 들어가므로 배포 전에 사용자 결정이 필요합니다(§5 6번).
- 두 창의 차이: board 상세는 프로젝트 폴더가 항상 있습니다(`s.cwd`, `BoardView.swift:729`). 작업판 상세는 고정 폴더가 없고, 담당 워커 cwd는 워커가 살아 있을 때만 있습니다(`TaskBoardView.swift:708-712`의 `workerRow`가 live 행에서만 찾음) [확인, T9 §1.4]. 그래서 작업판 쪽 L1은 "어느 폴더를 트리로 볼지"를 정해야 완성됩니다(§5 3번).
- 터미널은 지금의 `PaneTerminal`(SwiftTerm + tmux control mode)을 그대로 둡니다. orca의 pty daemon이 하는 일(앱과 수명 분리, 재접속 화면)은 tmux가 이미 합니다 [T13 요약 1, §1.5]. `ignore-size`로 붙어 pane 크기를 바꾸지 않으므로 터미널은 하단 전폭에 두는 배치가 맞습니다(`PaneControl.swift:140`, `PaneTerminal.swift:322`) [확인, T9 §1.2, T13 §4.2 B3].

## 2. 선택지

공통 전제: 선택지 1~4는 터미널을 네이티브 `PaneTerminal`로 두고, 1단계(오른쪽 트리 + 읽기 전용 보기)를 같은 네이티브 부품으로 시작할 수 있습니다. 에디터 엔진은 2단계에서 갈립니다.

### 선택지 1. 경로 A, 읽기 전용 IDE (L1 + L3, 편집 없음)

- 내용: board 상세를 [에디터 보기 | 트리(오른쪽)] 위, 터미널 아래로 나눕니다. 작업판 상세에서는 ticket, 보고서, 문서를 앱 안 보기로 엽니다. 저장 기능은 만들지 않습니다.
- 두 창: board는 워커 cwd 트리. 작업판은 §5 3번 결정에 따른 폴더 트리 + 기존 `OpenPath` 행을 앱 안 보기로 바꿉니다(`TaskDetailView.swift:772,786,805`, `TaskBoardDocuments.swift:164-175`) [확인, T9 §4 표].
- 장점:
  - 사용자 체감: 워커가 고치는 파일을 앱을 떠나지 않고 봅니다. 깨끗한 버퍼 자동 reload(T13 §4.1 A7)로 에이전트 변경이 실시간으로 보입니다.
  - 유지보수: 외부 의존 추가 0개. 기존 `FileCodeView`, highlight.js, `DeclIndex` 재사용.
  - 안전 규칙: 앱이 작업 트리에 쓰지 않으므로 README의 "Read-only except for what the user asks for"(`ct/README.md:5`) [확인]와 R54(`FileEditor.swift:27-45`)를 그대로 지킵니다.
  - 에이전트 충돌: 없습니다. 앱은 읽기만 합니다.
- 단점:
  - "VS Code처럼 쓴다"는 요청의 편집 부분을 채우지 못합니다. 편집은 여전히 외부 에디터(D)로 갑니다.
  - `FileCodeView`는 `Text`를 `LazyVStack`으로 쌓는 구조라(`CodeView.swift:134-145`) 큰 파일 보기 성능과 2000줄 창 제한(`Navigation.swift:89`)을 손봐야 합니다 [확인].
- 트레이드오프: 가장 작은 범위로 레이아웃·트리·감시를 먼저 검증하고, 편집 여부는 써 본 뒤 정합니다. 선택지 2·3·4의 1단계와 같은 작업이라 버려지는 코드가 거의 없습니다.

### 선택지 2. 경로 A, 단계형 네이티브 IDE (L1 → L2 → L3 → L4)

- 내용: 선택지 1 위에 CESE(`exact` pin) 기반 편집, compare-and-write 저장, dirty 충돌 배너, `git grep` 검색, quick open, ChimeHQ LanguageClient 기반 LSP를 순서대로 올립니다(T11 §5 권장 조합).
- 두 창: board 상세는 [에디터 탭 | 트리] + 터미널. 작업판 상세는 4단 배치 공간이 없으므로(`narrow` 규칙, `TaskBoardView.swift:389-390,620`) 상세 안 탭 또는 시트로 에디터를 띄웁니다 [추론, T9 §4 표]. 버퍼는 앱 전역 1개, 탭 목록은 창별(T9 §4 에디터 상태 공유) [추론].
- 장점:
  - 사용자 체감: 앱 안 통합이 가장 깊습니다. 키 우선순위를 `performKeyEquivalent` override로 직접 제어할 수 있습니다 [추론, T9 §5.2].
  - 유지보수: 빌드가 SwiftPM만으로 유지됩니다. 네트워크 포트, node 런타임, npm 단계가 없습니다.
  - 안전 규칙: 실행 능력이 있는 부품이 없어 R54 취지("클릭이 실행으로 이어지지 않음")와 충돌하지 않습니다. L4에서 언어 서버를 앱이 직접 띄우지만 실행 대상은 앱이 정합니다(T12 §5 R54 행과 같은 판단).
  - 에이전트 충돌: orca의 정책(깨끗하면 reload, dirty면 배너 4택, 내용 해시 compare-and-write)을 Swift로 그대로 옮길 수 있습니다(T13 §3.3, §4.1 A7~A10).
- 단점:
  - CESE README가 "not ready for production use"이고, 마지막 release가 2025-09-16(0.15.2), 큰 파일 스크롤 이슈 #358이 열려 있습니다 [확인, T11 §1].
  - CESE 필수 의존 2개의 LICENSE 부재(§1). 의존 패키지가 SwiftTerm 1개에서 약 15개로 늘어납니다 [T11 §5].
  - L4는 언어별 서버 탐색, PATH(`TowerCore/Support.swift:70-82`), 수명 정책을 앱이 떠안습니다 [확인, T11 §3].
  - 문법 강조가 두 체계(diff 창 highlight.js, 에디터 tree-sitter)로 나뉩니다.
- 기존 안전 규칙과의 충돌: 저장 기능이 앱 최초의 작업 트리 쓰기입니다. README의 read-only 문구와 아키텍처 문서의 "읽기 전용" 경계(T2 §6의 1번, 7번)를 고쳐야 합니다. 편집은 사용자가 요청한 동작이므로 README 예외 목록에 한 줄을 더하는 형태가 됩니다 [추론].
- 에이전트 작업과의 충돌: 에이전트가 쓰는 worktree에 사용자가 저장하면 에이전트의 다음 Edit가 실패하거나 사용자 변경을 덮습니다(T9 §5.1). orca 배너의 Overwrite만 디스크 새 내용을 덮는 유일한 명시적 동의입니다(T13 §3.3). 편집 허용 범위는 §5 2번에서 정합니다.
- 트레이드오프: 구현량은 많지만 기존 코드 재사용이 가장 높고(T9 §3 경로 비교 "기존 코드 재사용: 높음"), 런타임 위험이 가장 작습니다. 대신 에디터 패키지의 유지보수 정체를 이 레포가 떠안습니다. PoC가 막히면 NSTextView(TextKit 1) + 기존 highlight.js로 L2만 먼저 갑니다(T11 §5 대안 열, T9 §3 A의 TextKit 2 성능 보고).

### 선택지 3. 경로 B1, WKWebView + 순수 monaco-editor (L1~L3)

- 내용: 트리와 터미널은 네이티브, 에디터 칸만 WKWebView 안 Monaco입니다. 번들은 `WKURLSchemeHandler` 자체 scheme으로 서빙하고, 파일 IO와 감시는 Swift가 맡습니다(T12 §1.2, §1.3).
- 두 창: 선택지 2와 같은 배치. 웹뷰는 창마다 WebContent 프로세스 1개입니다 [추론, T9 §5.4].
- 장점:
  - 사용자 체감: 편집 감각이 VS Code와 같습니다(같은 에디터 코어). 파일 내 찾기, 다중 커서가 기본으로 있습니다.
  - 유지보수: monaco-editor는 활발합니다(v0.58.0, 2026-11-23) [문서, T9 §3 B]. orca가 같은 구성을 운영합니다(worker 5종, 진단 끔, 테마 연동, T12 §4).
  - 안전 규칙: 네트워크 노출이 없고(custom scheme), 실행 능력이 없어 R54 유지가 가능합니다(T12 §5).
- 단점:
  - spike 1: custom scheme에서 Monaco ESM module worker가 뜨는지 확인한 자료가 없습니다. 실패하면 blob worker 우회 [추론, T12 §1.2].
  - spike 2: WKWebView가 key equivalent를 메뉴보다 먼저 받는지 문서로 확인하지 못했습니다(T12 §3.1). §6 단축키 충돌 표 참고.
  - 빌드에 npm 단계가 생기거나, Vite 산출물(dist)을 public 레포에 커밋해야 합니다(T12 §1.1, §6 사용자 결정 2).
  - L4로 가려면 B2로 스택을 갈아야 합니다(languageclient가 순수 monaco-editor에서 돌지 않음, T12 §0).
  - 문법 강조가 highlight.js와 Monarch로 나뉩니다(T9 §3 B 막히는 점 2).
- 에이전트 작업과의 충돌: 선택지 2와 같은 정책을 Swift 쪽에서 구현하고 JS로 push합니다. 자기 저장 직후 감시 이벤트를 무시하는 창이 필요합니다(orca self-write registry TTL 750 ms, T12 §4 표).
- 트레이드오프: 편집 품질을 얻는 대신 웹뷰 경계(키, worker, 브리지)와 JS 빌드 체인을 새로 유지합니다.

### 선택지 4. 경로 B2, monaco-vscode-api + monaco-languageclient (L1~L4, L5는 web 확장 일부)

- 내용: 선택지 3의 에디터를 VS Code 서비스 재구현 스택으로 바꿉니다. TextMate 문법과 VS Code 테마가 들어오고, 언어 서버는 Swift가 stdio로 띄워 `WKScriptMessageHandler`로 중계합니다(T12 §1.4, §1.5).
- 장점: 색과 동작이 VS Code와 같아집니다. L4가 포트 없이 연결됩니다 [추론, T12 §1.5]. web 확장 일부가 돕니다 [문서/추론, T12 §0].
- 단점:
  - 버전 정렬: `monaco-languageclient` 11.0.3은 monaco-vscode-api 37.6.0(최신 40.1.0보다 major 3판 뒤)과 monaco-editor 0.57.0(최신 0.58.0보다 한 판 뒤) 기준입니다 [문서, T12 §1.5, §5 주된 위험 행]. 의존 34개 중 30개가 `@codingame/monaco-vscode-*`입니다 [R11 대조].
  - spike 1·2에 더해 스택 크기가 미측정입니다(T12 §5 크기 행).
  - 단축키 충돌이 B1보다 큽니다. VS Code keybinding 서비스가 ⌘K chord, ⌘P, ⌘⇧P를 씁니다(§6).
- 안전 규칙: web 확장이 웹뷰 안에서 코드를 실행합니다. R54 해제는 아니지만 "확장 실행"을 허용할지 정해야 합니다 [추론].
- 에이전트 충돌: 선택지 3과 같습니다.
- 트레이드오프: VS Code와 가장 비슷한 화면을 앱 안 통합으로 얻는 대신, 서로 맞물린 버전 묶음을 계속 따라가야 합니다.

### 선택지 5. 경로 C, code-server 내장 (L1~L4, L5는 Open VSX 한정)

- 내용: code-server 인스턴스 1개를 띄우고, WKWebView마다 `?folder=<worktree>`로 엽니다. 탐색기는 `"workbench.sideBar.location": "right"`로 오른쪽에 둡니다(T12 §2.2, §2.5). openvscode-server는 102개 릴리스 전부 Linux 자산만 있어 macOS에서는 직접 빌드해야 하므로 제외합니다 [문서, T12 §2.1].
- 장점:
  - 사용자 체감: 기능이 완성돼 있습니다. 탭, 검색, 설정, 테마, 확장 UI가 그대로입니다.
  - 유지보수: 에디터 자체를 만들 일이 없습니다. 배치와 프로세스 수명만 씁니다(T9 §3 경로 비교 "낮음(배치만)").
- 단점:
  - 런타임: node 서버 + extension host + WebContent 상주. 최소 요구 1 GB RAM, 2 core [문서, T12 §0]. 실행물 arm64 약 247 MB [문서, T9 §3 C].
  - 보안: WebSocket이 필수라 localhost TCP 포트가 열립니다. 127.0.0.1 바인드, 무작위 포트와 비밀번호가 필요합니다 [추론, T12 §2.3].
  - 공식 지원 브라우저에 Safari/WebKit 명시가 없습니다 [문서, T9 §3 C].
  - 터미널이 둘이 됩니다(VS Code 통합 터미널과 PaneTerminal). 워커 pane은 VS Code 쪽으로 옮길 수 없습니다(T9 §3 C 막히는 점 2).
  - 작업판 상세에는 맞지 않습니다. 4단 배치 공간이 없어 별도 창이나 시트가 되고, 그 경우 `Tower.windows` activation 정책 계산에 새 창을 넣어야 합니다(T9 §5.3).
- 기존 안전 규칙과의 충돌: 가장 큽니다. 통합 터미널, task, 확장이 임의 코드를 실행하므로 R54 원칙을 이 영역에서 해제해야 합니다(T9 §3 C 막히는 점 1, T12 §2.3). 통합 터미널은 pane 입력 규칙(PaneTerminal만 pane에 쓰고, README는 "never types into a pane"이라고 적음, T2 §6의 1번)과 별개의 쓰기 경로를 하나 더 엽니다.
- 에이전트 작업과의 충돌: VS Code 자체의 외부 변경 처리에 맡깁니다. 앱이 정책을 통제하지 못합니다 [추론].
- 트레이드오프: L5(Open VSX)가 필요하면 유일한 앱 안 선택지입니다. 대신 무게, 보안 설계, R54 해제를 받아들여야 합니다.

### 선택지 6. 경로 D, 외부 VS Code/Cursor 연동

- 내용: board 상세 head의 "변경 보기" 옆(`BoardView.swift:766-772`)과 작업판 상세 담당 워커 줄에 "에디터로 열기"를 둡니다. `code -r <folder>`, `--goto file:line`을 씁니다 [문서, T9 §3 D]. 폴더 열기 규칙을 `FileEditor.swift`에 따로 둡니다(`openRefusal`은 폴더를 거부, `:37`) [확인].
- 장점: 구현이 가장 작고 L1~L5가 전부 있습니다. 앱에 쓰기·실행 능력이 생기지 않습니다.
- 단점: "control tower 안에서 IDE처럼"이라는 요구를 충족하지 않습니다. 특정 폴더의 VS Code 창만 앞으로 가져오는 방법은 확인하지 못했습니다(미확인, T9 §3 D). Cursor CLI 플래그 호환도 미확인입니다.
- 안전 규칙·에이전트 충돌: 앱 쪽 충돌은 없습니다. 충돌 처리는 VS Code가 합니다.
- 트레이드오프: 요구 충족도를 버리고 비용과 위험을 0에 가깝게 합니다. 다른 선택지와 함께 둘 수 있습니다.

### 선택지 7. 경로 E, Electron 재작성 또는 orca 채택

- 내용: control-tower를 Electron(xterm.js + node-pty + Monaco)으로 다시 쓰거나, orca를 IDE로 쓰고 control-tower는 작업판 전용으로 남깁니다(T9 §3 E).
- 장점: orca 수준의 한 화면 IDE(터미널·에디터·diff 탭, 오른쪽 탐색기)를 얻습니다(T8 §1.4).
- 단점: Swift Sources 20,313줄, Tests 13,948줄, `@Test` 849건을 다시 써야 합니다 [확인, T9 §3 E]. orca에는 my-team 작업판, mailbox, 팀 개념이 없습니다. orca는 LSP도 없습니다 [확인, T8 §2.6]. L5는 이 구성으로도 불가입니다.
- 안전 규칙: 기존 R54, dry-run, 테스트 인스턴스 체계를 새로 만들어야 합니다.
- 에이전트 충돌: orca의 정책(T13 §3)을 그대로 얻습니다. orca 채택이면 my-team 워커 pane(tmux)과 orca 터미널(자체 daemon)이 별개라 워커를 orca 안에서 볼 수 없습니다 [추론, T13 §1.1].
- 트레이드오프: 화면 완성도를 위해 기존 자산과 tmux 기반 구조를 버립니다.

### 선택지 요약

| 번호 | 경로 | 도달 단계 | 새 런타임 | R54 | 에이전트 충돌 처리 주체 |
|---|---|---|---|---|---|
| 1 | A 읽기 전용 | L1, L3 | 없음 | 유지 | 해당 없음(쓰기 없음) |
| 2 | A 단계형 | L1~L4 | Swift 패키지, 언어 서버 | 유지 | 앱(orca 정책 이식) |
| 3 | B1 | L1~L3 | WebContent | 유지 | 앱 |
| 4 | B2 | L1~L4, L5 web 확장 일부 | WebContent + 언어 서버 | 확장 실행 판단 필요 | 앱 |
| 5 | C code-server | L1~L4, L5 Open VSX | node 서버 약 247 MB | 해제 필요 | VS Code |
| 6 | D 외부 | 외부에서 전부 | 없음 | 유지 | VS Code |
| 7 | E 재작성/orca | orca 수준, L4·L5 없음 | Electron | 재구축 | orca 정책 |

## 3. 권장안

권장: 선택지 2(경로 A 단계형). 1단계는 선택지 1과 같은 범위(L1 + 감시)로 시작하고, L2 진입 전에 CESE PoC와 라이선스 결정을 받습니다. L5가 필수라고 답하면 권장은 선택지 5로 바뀝니다.

이유:
1. 재사용: L1 부품이 전부 이 코드베이스에 있습니다(T9 §2 기능 단계 표). 1단계는 선택지 1~4가 공유하므로, 에디터 엔진 결정을 L2 직전까지 미뤄도 버려지는 작업이 거의 없습니다.
2. 안전 규칙: 네트워크 포트, node 런타임, 확장 실행이 없습니다. R54를 해제하지 않습니다. 키 우선순위를 네이티브에서 통제할 수 있어 WKWebView spike 2 같은 미확인 항목이 없습니다.
3. 에이전트 동시 편집: control-tower의 기본 상황은 워커가 같은 worktree를 계속 고치는 것입니다(T11 §2 파일 감시). orca가 운영 중인 정책(T13 §3.1~3.4)을 앱이 직접 구현해 통제할 수 있는 경로가 A와 B입니다. B는 웹뷰 경계가 하나 더 있습니다.
4. 빌드: SwiftPM 단일 빌드(`ct/Package.swift`, 외부 의존 SwiftTerm 1개)를 유지합니다. B는 npm 단계 또는 dist 커밋, C는 수백 MB 동봉 또는 설치 탐색이 생깁니다.
5. 위험 제어: CESE가 막히면 NSTextView(TextKit 1) + 기존 highlight.js로 L2를 좁히는 후퇴 경로가 있습니다(T11 §5). 이 코드베이스는 이미 TextKit 1을 씁니다(`CodeView.swift:56-74`) [확인, T9 §3 A].

### orca에서 가져올 설계

모두 설계(자료 구조, 타이밍, 정책)이며 코드 복사는 하지 않습니다. orca는 MIT이고 코드를 번역해 옮기면 `Resources/NOTICE.md`에 고지를 추가합니다 [T13 §4.3, T8 §6.1].

1. 오른쪽 sidebar의 탐색기 탭, 같은 자리에 변경 목록(source control) 탭 [T13 §4.1 A4]. control-tower에서는 폴더 트리와 기존 `ChangeTree` 변경 목록을 탭으로 둡니다.
2. 레이아웃 비율 저장, worktree(워커 cwd)별 열린 파일, sidebar 폭은 전역 [T13 §4.1 A3]. 크기는 픽셀이 아니라 비율로 저장합니다(T13 §2.4).
3. watcher 배치: 첫 이벤트 75 ms 후 flush, 이후 100 ms 고정 주기, trailing debounce 금지("Trailing debounce stalls under continuous agent writes") [T13 §3.1, §4.1 A5].
4. 무시 목록(`.git`, `node_modules`, `build` 등)과 overflow 시 전체 재확인 [T13 §4.1 A6]. FSEvents `MustScanSubDirs`가 overflow에 해당한다는 판단은 [추론]입니다.
5. 깨끗한 버퍼 자동 reload(커서·스크롤 유지), 숨은 탭은 stale 표시만 [T13 §3.2, A7]. L1부터 씁니다.
6. dirty 버퍼는 reload하지 않고 배너 4택, 자동 merge 없음 [T13 §3.3, A8]. 근거는 orca `src/renderer/src/components/editor/external-changes/ExternalFileChangeBanner.tsx:209-235`입니다. Compare `:210`, Reload from Disk `:214`, Overwrite `:219`, Keep My Edits `:233` [확인: `sed -n '209,235p'`, orca 30c09a46]. Reload에는 8초 되돌리기 toast가 있습니다(`:30`, T13 §3.3).
7. 저장은 로드 시점 내용 해시와 디스크를 비교한 뒤에만(compare-and-write), 파일별 직렬화 안에서 [T13 §3.3, A9]. Swift에서는 CryptoKit SHA-256 [추론].
8. 자기 저장 직후 감시 이벤트를 무시하는 self-write registry(TTL 750 ms) [T12 §4 표].
9. 삭제 표시 250 ms 지연(원자적 저장을 삭제로 오인하지 않음), 자동 저장은 삭제된 파일을 되살리지 않음 [T13 §3.4, A10].
10. 재접속 첫 화면에 scrollback 포함(`capture-pane -S -<n>`, `Tmux.swift:74`에 같은 형태가 있음) [T13 §4.1 A1]. IDE화와 독립인 터미널 개선이라 별도 티켓입니다.

### orca에서 가져오지 않을 것

1. pty daemon, headless emulator, 자체 wire protocol, 디스크 checkpoint. tmux가 같은 일을 합니다 [T13 §4.2 B1].
2. xterm.js, node-pty. SwiftTerm이 대응 부품입니다 [B2].
3. 화면 크기가 pty 크기를 정하는 방식. 사용자의 Ghostty와 같은 pane을 보므로 `ignore-size`를 유지합니다 [B3].
4. 가짜 tmux shim [B4].
5. 터미널과 에디터가 한 탭 바에 섞이는 모델, 탭 drag-to-split, 터미널 내부 2단 split tree. 터미널은 워커당 pane 1개 고정이라 터미널 영역과 에디터 탭 영역을 분리합니다 [B5, B6].
6. 범용 이진 split tree(T13 A2)는 지금은 가져오지 않습니다. 배치가 [에디터 | 트리] + 하단 터미널로 고정이고 drag-to-split이 범위 밖이므로, 고정 3영역 + 비율 저장으로 충분합니다. 자유 분할이 필요해지면 그때 A2를 씁니다.
7. hook 서버 + OSC 7501 상태 수집. my-team `status.json`이 정본입니다 [B7].
8. native chat, browser, simulator 탭 [B8].
9. orca 소스 코드 자체(React/Electron 전용) [B9]와 SQLite profile 저장소 [B10].
10. 번들 ripgrep. `git grep`으로 시작하고 측정상 부족할 때 다시 봅니다 [T11 §4].

## 4. 권장안 구현 계획 초안

티켓 후보는 모듈·파일 경계로 나눴습니다. 순서는 위에서 아래입니다. 각 단계는 앞 단계가 끝나야 시작합니다(K3는 K1과 병행 가능).

| # | 단계 | 범위 (파일) | 확인 방법 |
|---|---|---|---|
| K1 | L1 | TowerCore: 전체 파일 읽기. `readWorkingFile`의 2000줄 창(`Navigation.swift:89`) 대신 전체 읽기 함수 추가, binary 판정 유지 | `swift test` (NavigationTests에 큰 파일, binary 케이스 추가 RED→GREEN) |
| K2 | L1 | TowerApp: 코드 보기와 트리를 `ChangesState`에서 분리(`CodeView.swift:81`, `ChangesView.swift:50,200`, `DiffWindow.swift:124`). diff 창 동작은 그대로 | `swift test` (ChangesStateTests, ChangeTreeTests, CodeNavigationTests 통과) + diff 창 수동 확인(트리 클릭, ⌘클릭 정의 이동) |
| K3 | L1 | TowerCore: `FileWatch` 신설. 워크트리 루트 FSEvents(파일 이벤트 flag), 75/100 ms 배치, 무시 목록, overflow 처리, 삭제 250 ms 지연. 배치·판정은 순수 함수로 분리 | `swift test` (배치 함수 단위 테스트 + 임시 폴더에 쓰기/rename/삭제 후 이벤트 도착 확인) |
| K4 | L1 | TowerApp: board 상세 배치. `BoardView.swift:783-791` terminal 분기를 [보기 \| 트리(오른쪽)] 위 + `PaneTerminal` 하단 전폭으로 바꿈. 새 `IdeArea.swift`. 트리 접기, 비율 저장(worktree별), 최소 창 크기 760×440(`BoardView.swift:41`) 재검토 | `swift test` (비율·접힘 상태 모델) + `scripts/test-instance.sh` 수동 시나리오: 워커 선택 → 트리 표시 → 파일 열기 → 워커가 그 파일 수정 → 5초 안에 화면 갱신. 터미널 입력 중 ⌘K로 빠져나오기 유지 |
| K5 | L1 | TowerApp: 작업판 상세. ticket·보고서·문서 행을 앱 안 보기로 열기(`TaskDetailView.swift:772,786,805`, `TaskBoardDocuments.swift:164-175`). 트리 폴더는 §5 3번 결정. R54 M1 검사(`openRefusal`, 절대 경로, 일반 파일) 유지 | `swift test` (TaskDetailTests, TaskBoardDocumentsTests, FileEditorTests) + 수동: done task(워커 없음)에서 트리 동작 |
| K6 | L2 준비 | PoC(코드 머지 없음): CESE를 이 앱에 넣어 `swift build`, `scripts/bundle-app.sh` 통과 여부(SwiftLintPlugin, xcframework), orca 큰 파일 스크롤·강조, Swift 6 경고. 결과로 §5 6·7·8번 결정 | PoC 보고서. 판정 기준: 빌드 성공, 34,382 파일 worktree에서 트리 펼침과 큰 파일 스크롤이 끊기지 않음 |
| K7 | L2 | TowerCore: 저장. 쓰기 경로 검증(worktree 또는 허용 폴더 안, realpath로 symlink 탈출 차단, `DocumentFolder.swift:92-97`과 같은 방식), 내용 해시 compare-and-write, self-write registry. 앱 최초의 작업 트리 쓰기 | `swift test` RED→GREEN: worktree 밖 경로 거부, symlink 탈출 거부, 해시 불일치 시 쓰지 않음, 같은 내용이면 쓰기 생략 |
| K8 | L2 | TowerApp: `EditorView.swift`(CESE 또는 후퇴안), 버퍼·탭 모델(버퍼는 앱 전역, 탭은 창별, §5 5번), dirty 표시, 충돌 배너 4택. `Package.swift` 의존 추가, `Resources/NOTICE.md` 고지 | `swift test` (버퍼·탭·배너 상태 전이) + 수동: dirty 상태에서 워커가 같은 파일 수정 → 배너 → Compare/Reload/Keep/Overwrite 각각 |
| K9 | L2 | TowerApp: 키 라우팅. 에디터 포커스 판정 함수와 메뉴 가드(`BoardView.swift:75`의 `PaneTerminalView.focused() == nil` 패턴 확장). §6 충돌 표의 키 전부 | `swift test` (포커스 상태 → 소비자 판정 함수) + 수동: 에디터·터미널·사이드바 포커스별 ⌘F, ⌘K, Esc, ⌘[, ⌘], ⌘D, ⌘W, ⌘Z |
| K10 | 문서 | README의 read-only 문구(`ct/README.md:5`)와 데이터 소스 표에 편집 예외 추가 | 리뷰 |
| K11 | L3 | TowerCore: `GitRead` 허용 enum(`Diff.swift:7-15`)에 `grep` 추가, 결과 파서. quick open 퍼지 매처. TowerApp: 검색 결과 목록, ⌘P | `swift test` (파서, 매처 점수) + 수동: orca worktree에서 검색 1초 안팎 |
| K12 | L4 | TowerCore/TowerApp: ChimeHQ LanguageClient·LanguageServerProtocol·JSONRPC·ProcessEnv, 서버 탐색·수명(앱이 `Process` 직접 종료), 문서 sync, completion·정의 이동·진단. 대상 언어는 §5 9번 | `swift test` (메시지 변환, 수명 정책) + 수동: 이 레포에서 sourcekit-lsp로 정의 이동·진단 |
| K13 | 터미널 | (IDE와 독립) `capture-pane -S`로 재접속 scrollback, `PaneControl.swift` | `swift test` (PaneControlTests) |

- 각 단계는 `cd tools/control-tower && swift test`가 통과해야 닫습니다(현재 849건 통과, T2 §5.3).
- 수동 시나리오는 설치본을 덮지 않도록 `scripts/test-instance.sh`(별도 HOME, tmux 소켓, `TOWER_DRY_RUN`)로 돌립니다(T2 §5.3).

## 5. 사용자가 정해야 할 항목

답은 "번호+기호"로 합니다(예: 1a, 2b, 6a).

1. 목표 단계: (a) L1~L3(보기, 편집, 검색), (b) L4(LSP)까지, (c) L5(확장) 필수 중 어느 쪽입니까?
   - (a) L1~L3: 선택지 2의 K1~K11까지. 언어 서버 공급 부담이 없습니다.
   - (b) L4: K12 추가. 언어별 서버 설치와 수명 관리를 앱이 떠안습니다.
   - (c) L5 필수: 앱 안에서는 선택지 5(Open VSX 한정)만 남고, R54 해제가 따라옵니다.
2. 편집 허용 범위: 에이전트가 작업 중인 worktree를 앱 안에서 편집 가능(충돌은 배너 4택)으로 둘 것과, 기본 읽기 전용(명시적 잠금 해제 후 편집)으로 둘 것 중 어느 쪽입니까?
   - (a) 편집 가능: 체감은 VS Code와 같습니다. 에이전트의 다음 Edit가 실패할 수 있고, 충돌 판단이 사용자에게 자주 옵니다.
   - (b) 읽기 전용 기본: 에이전트 작업을 깨지 않습니다. 편집 전 한 번의 동작이 더 필요합니다. "워커가 멈춤(wait) 상태일 때만 편집 허용" 같은 상태 연동은 이 안의 변형입니다 [추론].
3. 작업판 상세의 프로젝트 폴더: (a) 담당 워커 worktree, (b) 팀 문서 폴더, (c) 둘 다 중 어느 쪽입니까?
   - (a) worktree: 코드 트리가 됩니다. 워커가 내려가면(done task) 트리가 빕니다(T9 §1.4).
   - (b) 문서 폴더: 항상 있습니다. 코드가 아니라 ticket·보고서 트리가 됩니다. symlink 미추적과 폴더 밖 차단이 이미 있습니다(`DocumentFolder.swift:66-97`).
   - (c) 둘 다: 트리 두 개 또는 루트 전환이 필요합니다. (a)·(b)의 장단점을 함께 가집니다 [추론].
4. 작업판 문서(ticket, 보고서, goal)를 앱 안에서 편집 가능하게 할 것과 읽기만 할 것 중 어느 쪽입니까?
   - (a) 편집: 사용자가 ticket을 바로 고칠 수 있습니다. 경로가 에이전트가 쓴 문자열에서 오므로 저장 허용 범위(문서 폴더 안)를 따로 둬야 합니다(T9 §4 R54 행).
   - (b) 읽기만: R54 M1을 그대로 씁니다.
5. 에디터 상태를 두 창이 공유할 것과 창별로 분리할 것 중 어느 쪽입니까?
   - (a) 공유(버퍼 앱 전역, 탭 창별 절충 포함): 같은 파일을 두 창에서 열어도 dirty 충돌이 없습니다.
   - (b) 분리: diff 창처럼 단순합니다. 같은 파일을 두 창에서 고치면 디스크 기준 충돌 처리가 필요합니다(T9 §4).
6. CESE 의존성 라이선스(R10 S1, T11 §6 1(a)): LICENSE 파일이 없는 필수 의존 CodeEditLanguages·CodeEditSymbols를 .app에 넣어 배포하는 것을 받아들일 것과, 받아들이지 않을 것 중 어느 쪽입니까?
   - (a) 받아들임: L2·L4로 가는 길이 가장 짧습니다. public 레포에 사용 허락이 표기되지 않은 binary를 배포하는 상태가 됩니다.
   - (b) 받아들이지 않음: upstream에 라이선스 명시를 요청하고 기다리거나, 두 패키지를 빼고 강조와 심볼을 직접 공급합니다(`HighlightProviding` 교체, 비용 증가).
7. STTextView(GPLv3 또는 유료 상용, T11 §6 1(b)): 후보로 남길 것과 제외할 것 중 어느 쪽입니까?
   - (a) 남김: 엔진(TextKit 2)과 유지 상태가 가장 좋습니다. 레포 라이선스(현재 루트 LICENSE 없음 [확인: `ls LICENSE*` 결과 없음])를 GPLv3 호환으로 함께 정해야 합니다.
   - (b) 제외: 레포 라이선스 결정이 필요 없습니다. CESE가 막히면 후퇴안은 NSTextView입니다.
8. CESE의 "not ready for production" 상태(T11 §6 2)를 받아들일 것과, L2를 NSTextView(TextKit 1) + highlight.js로 좁힐 것 중 어느 쪽입니까?
   - (a) CESE: completion·정의 이동 hook이 있어 L4까지 짧습니다. 정체된 패키지의 버그를 이 레포가 고쳐야 할 수 있습니다.
   - (b) NSTextView: 의존 추가가 없습니다. L4 hook(completion 창, gutter)을 직접 만들어야 합니다.
9. (L4를 고를 때) 언어 서버 설치를 사용자가 brew/npm으로 할 것과 앱이 안내·설치까지 할 것 중 어느 쪽입니까? 대상 언어(Swift, Kotlin, Java, TypeScript, Python)는 무엇입니까?
   - (a) 사용자 설치: 앱은 탐색만 합니다(PATH, `JAVA_HOME`은 ProcessEnv로 수집, T11 §3).
   - (b) 앱 설치: 체감은 좋지만 설치 실패와 버전 관리를 앱이 떠안습니다.
10. (L4를 고를 때) 최소 macOS를 14로 유지할 것과 15로 올릴 것 중 어느 쪽입니까?
    - (a) 14 유지: ChimeHQ 계열을 씁니다.
    - (b) 15: Apple `swift-tools-protocols`(Apache-2.0, macOS 15 이상)도 고를 수 있습니다(T11 §3). 사용자 PC가 모두 15 이상인지는 확인하지 않았습니다.
11. (선택지 3·4를 고를 때) Monaco 웹 산출물을 dist로 커밋할 것과 `bundle-app.sh`에 npm 빌드 단계를 넣을 것 중 어느 쪽입니까?
    - (a) dist 커밋: 빌드는 SwiftPM만 유지합니다. public 레포에 수 MB(전 언어 기준 17.9 MB)가 커밋됩니다(T12 §1.1, T9 §3 B).
    - (b) npm 단계: 레포는 가볍습니다. 빌드에 node가 필요해집니다.
12. (선택지 5를 고를 때) code-server를 (a) 앱에 동봉할 것과 (b) 사용자 설치 경로를 탐색할 것 중 어느 쪽입니까? 함께 R54 해제 범위(통합 터미널, task, 확장)를 정해야 합니다(T9 §6 4번, T12 §6).
    - (a) 동봉: 설치 단계가 없습니다. .app이 약 247 MB 커집니다. 첫 실행 다운로드 방식이면 무결성 검증이 추가로 필요합니다(T12 §2.1).
    - (b) 설치 경로 탐색: 앱은 가볍습니다. 사용자가 code-server를 따로 설치·갱신해야 합니다.

## 6. 위험과 미확인 사항

### 단축키 충돌 (R9 S1, R11 L2 반영)

현재 키 소비자는 다섯입니다 [T9 §5.2, R9 S1 반영본].
1. board 창 앱 메뉴: ⌘R, ⌘+/-/0, ⌘D, ⌘⇧T, ⌘1/2, ⌘⌥방향키, Esc, ⌘[, ⌘], ⌘F (`TowerApp.swift:176-229`) [확인].
2. 숨은 버튼: board의 ⌘K(검색 포커스, `BoardView.swift:64-69`)와 ⌘=(글자 크게의 다른 키, `FontScaleAlias`, `DiffWindow.swift:100-104`) [확인].
3. MenuBarExtra 메뉴: ⌘B, ⌘,, ⌘Q (`TowerApp.swift:88-91`).
4. SwiftUI 기본 메뉴: 대체한 것은 `.newItem`뿐입니다(`TowerApp.swift:176`) [확인]. 편집(⌘Z/⌘X/⌘C/⌘V/⌘A)과 창(⌘W, ⌘M) 메뉴가 남는 것으로 봅니다 [추론: 실행 중 앱에서 확인하지 않음].
5. PaneTerminal local monitor: 포커스가 터미널일 때만 Esc, ⌘V, 선택 중 ⌘C (`PaneTerminal.swift:266-279`, 판정 `:270`) [확인].

| 키 | 지금 소비자 | 에디터에서의 의미 | 영향 경로 |
|---|---|---|---|
| ⌘K | board 숨은 "검색" 버튼(`BoardView.swift:66-69`), 터미널에서 빠져나오는 키 | Monaco·VS Code chord 접두어(⌘K ⌘C 등) | B, C에서 chord가 끊길 수 있음(spike 2). A는 VS Code 키맵을 따르지 않으면 해당 없음 |
| ⌘F | 메뉴 "검색"(`:228`) | 파일 내 찾기 | A, B, C |
| Esc | "이동 > 닫기"(`:222-224`), 터미널 우선 | 위젯 닫기 | A, B, C |
| ⌘[ / ⌘] | 뒤로·앞으로(`:225-226`) | 들여쓰기 줄이기·늘리기 [추론] | A, B, C |
| ⌘D | 변경 보기 | 다음 일치 선택 | B, C |
| ⌘+/-/0, ⌘= | 앱 글자 크기 | 에디터 확대 | B, C (pageZoom 또는 fontSize로 맞춤, T12 §3.3) |
| ⌘W | 기본 창 메뉴 [추론] | 에디터 탭 닫기 | C에서 에디터 대신 창이 닫힐 수 있음 [추론, T12 §3.1] |
| ⌘Z, ⌘A | 기본 편집 메뉴 [추론] | undo, 전체 선택 | 에디터가 first responder면 보통 에디터가 받음 [추론] |
| ⌘P, ⌘⇧P | 자체 commands와 `keyboardShortcut` 전수 검색에 없음 [확인, T9 §5.2]. 기본 메뉴(인쇄 등)는 실행 앱에서 미확인 | quick open, 명령 팔레트 | B2, C, 그리고 A의 K11 |

- 원칙: 포커스를 가진 영역이 우선하고, 앱 메뉴는 포커스가 없을 때만 받습니다. `firstResponder === self` 판정과 `BoardView.swift:75`의 가드를 에디터로 확장합니다(T9 §5.2, T12 §3.1).
- A는 `performKeyEquivalent`로 제어할 수 있습니다 [추론]. B·C는 WKWebView가 key equivalent를 메뉴보다 먼저 받는지 문서로 확인하지 못했습니다. spike 2(T12 §6 실측 2)로 ⌘F, Esc, ⌘D, ⌘K chord, ⌘[, ⌘], ⌘+/-, ⌘W를 확인해야 합니다.

### 경로 B·C 비교 요약 (R11 반영)

| | B1 | B2 | C code-server |
|---|---|---|---|
| 핵심 버전 | monaco-editor v0.58.0 (2026-11-23) [문서] | monaco-languageclient 11.0.3 기준 monaco-vscode-api 37.6.0, 최신 40.1.0보다 major 3판 뒤. monaco-editor 0.57.0, 최신 0.58.0보다 한 판 뒤 [문서, T12 §1.5] | v4.146.0 (2026-11-20) [문서, T9 §3 C] |
| 도달 | L1~L3 | L1~L4, L5 web 확장 일부 | L1~L4, L5 Open VSX |
| 첫 spike | 1(worker), 2(키) | 1, 2 + 버전 정렬 | 2 + 기동 시간·메모리 실측 |
| 네트워크 | 없음 | 없음 | localhost 포트 + 인증 |
| R54 | 유지 | 확장 실행 판단 | 해제 필요 |
| 라이선스 | MIT | MIT | code-server MIT, openvscode-server MIT [문서, T9 §3 C, T12 §2.1] |

orca의 Monaco 사용 방식(worker 5종, 진단 끔, 테마 연동, 단축키 DOM 처리)은 T8 보고서(`reports/T8-orca-ide-analysis.md` §2)와 T12 §4가 다룹니다.

### 라이선스 표

| 경로 | 부품 | 라이선스 | 근거 |
|---|---|---|---|
| 공통 | 이 레포 | 루트 LICENSE 없음 | [확인] `ls LICENSE*` 결과 없음 |
| 공통 | SwiftTerm 1.99.1 (기존) | MIT | [문서, T13 §4.3], `ct/Sources/TowerCore/Resources/SwiftTerm-LICENSE` [확인, T13] |
| 공통 | orca (설계 참고) | MIT, Copyright (c) 2026 Lovecast Inc. | [확인] `orca/LICENSE:1-3` (T8 §6.1, T13 §4.3) |
| A | CodeEditSourceEditor 0.15.2, CodeEditTextView 0.12.1 | MIT | [확인, T11 §1] |
| A | CodeEditLanguages, CodeEditSymbols (CESE 필수 의존) | LICENSE 파일 없음 | [확인, T11 §1, R10 S1] |
| A | STTextView 2.4.1 | GPLv3 또는 유료 상용 | [확인, T11 §1] |
| A | ChimeHQ LanguageClient, LanguageServerProtocol, JSONRPC, ProcessEnv | BSD-3-Clause | [확인, T11 §3] |
| A | swift-tree-sitter 0.10.0 | BSD-3-Clause | [문서, T9 §3 A] |
| A | swiftlang/swift-tools-protocols | Apache-2.0 (macOS 15 이상) | [확인, T11 §3] |
| A/B | ripgrep (선택) | MIT/Unlicense | [추론, T11 §4: LICENSE 미확인]. T8 §6은 [문서] MIT OR Unlicense |
| B | monaco-editor, @codingame/monaco-vscode-api, monaco-languageclient | MIT | [문서, T12 §1.6] |
| B | vscode-textmate, vscode-oniguruma | MIT | [문서, T12 §1.4] |
| C | code-server | MIT | [문서, T9 §3 C, T12 §2.1] |
| C | openvscode-server | MIT | [문서, T9 §3 C, T12 §2.1] |
| C | Open VSX 확장 | 각 확장 라이선스 + Eclipse 이용약관 | [문서, T12 §2.4] |
| C | MS Marketplace 확장 (Pylance, C# Dev Kit 등) | 약관상 MS 제품 전용, 사용 불가 | [문서, T12 §2.4, T9 §3 C] |

### 그 밖의 위험

1. 에이전트 동시 편집: FSEvents는 advisory라 누락이 있을 수 있습니다. 저장 직전 해시 비교를 항상 같이 합니다(T11 §2 파일 감시 주의 행). 에이전트가 atomic rename으로 저장하면 vnode 감시는 끊기므로 경로 기준 FSEvents를 씁니다 [추론, T9 §5.1].
2. 큰 트리: SwiftUI `List` 계층 성능 문제가 포럼에 보고돼 있습니다. orca 규모(34,382 파일)에서 끊기면 `NSOutlineView`로 바꿉니다(T11 §2 트리 뷰) [문서/추론].
3. 큰 파일: 어느 에디터 후보도 직접 측정하지 않았습니다. TextKit 2 큰 문서 성능은 포럼 보고만 있습니다(T9 §3 A, T11 확인하지 않은 것).
4. 빌드: CESE의 SwiftLintPlugin build plugin이 `swift build`와 `bundle-app.sh`에 주는 영향은 확인하지 않았습니다(T11 §1 접점). K6 PoC 항목입니다.
5. Swift 6 경계: 의존 패키지는 각자 tools-version 모드로 빌드되므로 import는 될 것으로 보지만 빌드로 확인하지 않았습니다 [추론, T9 §3 A, T11 §3].
6. 레이아웃 폭: 최소 창 760×440과 sidebar 최소 300을 빼면 작은 창에서 에디터와 트리 폭이 부족합니다 [추론, T9 §4 표]. 트리 접기나 최소 크기 상향이 필요합니다.
7. 터미널 출력 폭주: `PaneStream`에 flow control이 없고 `AsyncStream` 기본 buffering이 unbounded로 보입니다 [추론, T13 §1.5]. 에디터와 무관하지만 한 화면에 부하가 몰리면 드러날 수 있습니다.
8. 메뉴바 앱 활성화: 새 창(독립 에디터 창, C의 별도 창)을 만들면 `Tower.windows`의 정책 계산에 넣어야 Dock과 ⌘Tab에서 사라지지 않습니다(T9 §5.3, `Tower.swift:309`).
9. 문서 불일치: README "never types into a pane"(`ct/README.md:5`)는 이미 PaneTerminal 입력과 어긋나 있습니다(T2 §6의 1번). 편집 기능을 넣기 전에 read-only 문구를 함께 고쳐야 혼선이 커지지 않습니다(K10).
10. 미측정: 언어 서버별 메모리, code-server 기동 시간과 상주 메모리, Monaco 선택 번들 크기, WKWebView `prefers-color-scheme`가 앱 화면 선택을 따르는지(T12 §3.2, §6).

## 7. 보고서 간 불일치 (이 문서의 처리)

1. STTextView: T9 §3 A는 "사실상 제외", T11 §1은 "사용자 결정 항목". T9가 같은 항목은 T11 값을 우선한다고 적었으므로 T11을 따릅니다(§5 7번).
2. 경로 B의 L5: T9 §3 B와 경로 비교표는 "불가", T12 §0·§5는 B2에서 "web 확장 한정 부분 도달"입니다. T12를 따르되 어떤 확장이 실제로 도는지는 [추론]으로 둡니다.
3. openvscode-server: T9 §3 C는 macOS 실행물·확장 마켓 "미확인", T12 §2.1은 Linux 자산만 있음과 Open VSX를 확인했습니다. T12를 따릅니다.
4. 경로 E의 L4: T9 경로 비교표는 "미확인(T8)", T8 §2.6은 orca에 LSP가 없음을 확인했습니다. 선택지 7에 반영했습니다.
5. Monaco 커밋 크기: T9 §3 B는 "수십 MB", T12 §1.1은 "수 MB(전 언어 17.9 MB)". 언어를 고르면 줄어드는 값이라 §5 11번에 17.9 MB(전 언어 기준)로 적었습니다.
6. `PaneControl.swift` 입력 줄 인용: T2 §2.6은 `:166-175`, T9 §1.2는 `:167-177`, T13 §1.5는 `:167-170`, `:173-177`입니다. 내용은 같고 범위만 다릅니다. 이 문서는 해당 줄을 인용하지 않았습니다.
7. T9 §1.3의 웹뷰 충돌 키 나열에는 ⌘R이 있지만 T9 §5.2 충돌 목록에는 없습니다. ⌘R은 에디터의 기본 동작과 겹치는 근거가 없어 §6 표에서 뺐습니다 [추론].

## 8. 지적 반영 확인

| ID | 내용 | 확인 결과와 반영 위치 |
|---|---|---|
| R9 L1 | T9 인용 줄 4건(`BoardView.swift:41`, `PaneTerminal.swift:270`, `FileEditor.swift:74-81`, `:94-95`) | T9 갱신본 §1.1·§4 표(`:41`), §1.3(`:270`), §3 D(`:74-81`), §5.5(`:94-95`) 반영 확인. 이 문서 §4 K4, §6 단축키 목록에서 같은 줄을 씁니다(`BoardView.swift:41`, `PaneTerminal.swift:270`는 `sed -n`으로 직접 확인) |
| R9 L2 | 수치 3건(언어 10종, TowerCoreTests 441, 렌더링 테스트 파일 9개) | T9 갱신본 §2 L1 행(10개 언어), §3 E(441, 합 849), §5.5(9개) 반영 확인. 이 문서 선택지 7은 849건을 씁니다 |
| R9 L3 | "live일 때만"의 근거 줄 | T9 갱신본 §1.4가 `TaskBoardView.swift:708-712`로 가리킵니다. 이 문서 §1 두 창의 차이에 같은 줄을 씁니다 |
| R9 S1 | §5.2 키 소비자 목록 누락(⌘=, MenuBarExtra, 기본 메뉴)과 ⌘P 근거 | T9 갱신본 §5.2가 소비자 5개와 "⌘P는 전수 검색에 없음 [확인], 기본 메뉴는 미확인 [추론]"으로 고쳐졌습니다. 이 문서 §6 단축키 충돌의 소비자 목록과 ⌘P 행에 반영 |
| R10 L1 | T9를 줄 번호 대신 절 이름으로 인용 | T11 갱신본이 "T9 §2 기능 단계 표", "T9 §요약", "T9 §5 공통 위험"으로 바꾼 것을 확인. 이 문서도 T9를 절 이름으로만 가리킵니다 |
| R10 S1 | CESE 필수 의존 2개의 LICENSE 부재 | T11 갱신본 결론 1과 §6 1(a)(b) 분리 확인. 이 문서 §1 경로 A 한 줄, §5 6번(CESE 의존성), §5 7번(STTextView), 라이선스 표 |
| R11 L1 | monaco-vscode-api 버전 서술과 `TowerApp.swift` 줄 | T12 갱신본 §1.5와 §5가 "37.6.0, 최신 40.1.0보다 major 3판 뒤, monaco-editor 0.57.0 대 0.58.0 한 판 뒤"로 일치합니다. §3.3은 `183-185행`이고 `sed -n '183,185p'`로 ⌘+/-/0 확인. 이 문서 선택지 4, §6 B·C 비교표 |
| R11 L2 | spike 2 키 목록에 board ⌘K 누락 | T12 갱신본 §3.1 4번과 §6 실측 2에 ⌘K(chord) 추가 확인. 이 문서 §6 단축키 표 첫 행, R9 S1 소비자 목록과 함께 맞춤 |
| R11 L3 | T8 보고서 참조 한 줄 | T12 갱신본 머리말에 T8 참조 추가 확인. 이 문서 §6 B·C 비교표 아래 한 줄 |
| R11 S1 | 경로 C 라이선스(code-server, openvscode-server 둘 다 MIT) | T12 갱신본 §2.1 표에 라이선스 행 추가 확인. 이 문서 §6 B·C 비교표 라이선스 행, 라이선스 표 C 행 |
| R12 L1 | 외부 변경 배너 근거를 `ExternalFileChangeBanner.tsx:209-235`로 | T13 갱신본 §3.3이 `:209-235`로 고쳐진 것을 확인. orca 30c09a46에서 `sed -n '209,235p'`로 Compare `:210`, Reload from Disk `:214`, Overwrite `:219`, Keep My Edits `:233` 확인. 이 문서 §3 가져올 설계 6번 |

미반영 항목은 없습니다.
