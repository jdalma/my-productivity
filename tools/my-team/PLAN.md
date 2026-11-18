# my-team — 구현 계획 (PLAN.md)

> **상태**: `구현 완료` (테스트 65개 통과). 본 PLAN의 §1~§7은 초기 설계 의도 기록용 역사 문서다 — 현재 정상 동작 명세는 `README.md`와 `docs/architecture.md`를 따른다.
> **실제 위치**: `~/IdeaProjects/my-claude-plugin/tools/my-team/` (본문 §1~§7의 `plugins/teams/` 경로는 초안 시점 계획이며 실제와 다름)
> **추정 규모**: 1,200–1,500줄, 작업 기간 2–3일
> **라이선스**: MIT (OMC `oh-my-claude-sisyphus` 차용 표시)

> ⚠️ **옵션 B 컷오버 노트** — 본 PLAN의 다음 항목들은 *제거되었고 더 이상 유효하지 않다*:
> - **AC-8 (`my-team msg`)**: 명령 자체 제거. user→worker는 워커 tmux pane 직접 입력만.
> - **AC-11 (`my-team add-task`)**: 명령 자체 제거. 부팅 시 task는 `workers[].extra_prompt`로 일원화.
> - **AC-31 (`claim-task` noop) + 모든 task lifecycle API** (`api create-task`, `api read-task`, `api transition-task-status`, `api claim-task`): 통째로 제거. my-team은 task 상태머신을 추적하지 않는다.
> - **`workers[].task` config 필드**: 사용 시 parser가 hard-reject (사용자가 `extra_prompt`로 마이그레이션).
> - **`inbox.md`, `tasks/<id>.json`, `leader/inbox.md`** state 파일: 더 이상 생성/사용되지 않는다.
> - **`check-inbox`, `new-task:<id>` tmux trigger 토큰**: 폐기. 남은 트리거는 `new-message:<from>`뿐.
>
> 본문의 §1~§7 설명은 초기 설계 의도를 기록하기 위해 그대로 둔다 (역사적 문서로서의 가치). 현재 정상 동작 명세는 `README.md`와 `docs/architecture.md`의 옵션 B 노트를 따른다.

---

## 1. 요구사항 요약

OMC `omc team`이 단일 cwd만 받는 한계를 극복하기 위한 멀티 프로젝트 워커 협업 도구. tmux 페인 운영과 메일박스 통신은 OMC에서 차용하되, **워커별 cwd를 직접 지정**할 수 있게 한다.

### 핵심 기능
- 워커마다 다른 프로젝트 디렉토리(`cwd`)에서 시작
- worktree 생성·관리는 사용자 책임 (도구는 경로만 전달받음)
- OMC `generateWorkerOverlay()` 시스템 프롬프트 그대로 사용 + `extra_prompt` 슬롯
- 부팅 task는 옵션 (있으면 즉시 시작, 없으면 inbox 폴링 대기)
- 러닝 중 task 동적 추가 가능 (사용자 / 워커 양쪽)
- 워커끼리 mailbox 자동 통신 (OMC write-then-notify 패턴)

### 비기능 요구사항
- OMC 의존 없이 독립 실행 (npm 글로벌 OMC 설치 무관)
- 단일 프로세스 모델 (분산 락 / dispatch queue 없음)
- claim_token 메커니즘 없음 (워커=프로젝트 1:1 매핑이라 race condition 불필요)
- Node.js ≥ 20, ESM, TypeScript 또는 순수 JavaScript

---

## 2. 합의된 결정사항

| 항목 | 결정 |
|------|------|
| 도구 이름 | `my-team` |
| 설치 위치 | `~/IdeaProjects/my-claude-plugin/plugins/teams/` |
| config 형식 | JSON |
| start 호출 | config 파일 + 인라인 둘 다 지원 |
| 사용자 명령 | 6개 (`start`, `status`, `add-worker`, `monitor`, `shutdown`, `api`) |
| api 서브명령 | 4개 (`send-message`, `mailbox-list`, `mailbox-mark-delivered`, `archive-lookup`) |
| 부팅 task | 옵션 (워커마다 있어도/없어도 됨) |
| shutdown 옵션 | `--force`만, grace는 환경변수 |
| status `--watch` | 제외 (`watch` 명령으로 대체) |
| 제거 명령 | `broadcast`, `list-tasks`, `show-task` |
| AGENTS.md | OMC `generateWorkerOverlay()` 그대로, `formatOmcCliInvocation` stub만 교체 |
| config 자동 탐색 | `--config` 미지정 시 호출자 cwd에서 `my-team.json` → `team.json` 순으로 탐색 |
| `extra_prompt` vs `extra_prompt_file` | 인라인(`extra_prompt`) 우선. 동시 지정 시 파일 무시 + stderr 경고 |
| 같은 팀 이름 재시작 | 에러로 거부 (기존 팀 종료 후 재시작 강제). 자동 덮어쓰기 안 함 |
| agent_type CLI 미설치 | 부팅 시작 시 즉시 실패 (`<cli>: command not found`) |
| 호출자 cwd | 워커 cwd와 완전 분리. 어떤 폴더에서 호출해도 워커는 config 절대경로에서 시작 |
| 언어 | **JavaScript (ESM)**. TypeScript 미사용. OMC 차용 `.js`를 그대로 써서 빌드 스텝 제거 |
| 디렉토리 | `src/` 한 곳만. `dist/` 없음. `bin/my-team` → `src/cli.js` 직접 호출 |
| 의존성 | **`commander` 1개**. JSON 검증은 단순 함수로 inline (ajv 미사용) |
| 테스트 | **`node --test`** (Node 20 표준). vitest 미사용 |

---

## 3. 인수 조건 (Acceptance Criteria)

### 부팅 (start)
- [ ] **AC-1**: `my-team start --config ./team.json`으로 워커 N(1–10)명 부팅. 각 워커는 config의 `cwd` 절대경로에서 시작
- [ ] **AC-2**: tmux `pane_current_path`가 워커별 cwd와 일치 (검증: `tmux list-panes -a -F '#{pane_id} #{pane_current_path}'`)
- [ ] **AC-3**: `$TMUX` 있으면 split-pane, 없으면 detached-session 모드 자동 분기 (OMC `detectTeamMultiplexerContext` 차용)
- [ ] **AC-4**: 각 워커 AGENTS.md가 `<state_root>/workers/<name>/AGENTS.md`에 작성됨. `## Role Context` 섹션에 `extra_prompt`가 박힘
- [ ] **AC-5**: `task` 필드 있는 워커는 `tasks/<id>.json` 생성, AGENTS.md `## Your Tasks`에 박힘. 없는 워커는 "No tasks assigned yet"
- [ ] **AC-6**: 인라인 모드 `--worker name:agent_type:cwd` 반복으로 부팅 가능 (extra_prompt/task 없음)
- [ ] **AC-7**: `--dry-run` 시 페인 안 띄우고 plan만 stdout에 출력

### 통신
- [ ] **AC-8**: `my-team msg --to <worker> --body <text>` 호출 시 워커 `inbox.md`에 어펜드 + tmux 트리거 발송. 200자 초과 메시지는 거부
- [ ] **AC-9**: 워커가 `my-team api send-message`로 다른 워커에게 메시지 송신 가능. 받는 워커 `mailbox.json`에 어펜드 + 트리거
- [ ] **AC-10**: 받는 워커 페인이 busy 상태여도 OMC `sendToWorker` 휴리스틱(Tab + C-m, copy-mode 가드, trust prompt 자동 처리)이 동작

### task lifecycle
- [ ] **AC-11**: `my-team add-task --worker <name> --subject <s> --description <d>`로 새 task 생성. ID는 자동 증가. 워커 inbox 알림 발송
- [ ] **AC-12**: 워커가 `my-team api transition-task-status`로 task를 `pending → in_progress → completed/failed` 전이 가능
- [ ] **AC-13**: 워커가 `my-team api create-task`로 자기/다른 워커에게 새 task 등록 가능
- [ ] **AC-14**: `my-team api read-task --input '{"team_name":"...","task_id":"..."}' --json`로 task 전체 조회

### 상태 / 종료
- [ ] **AC-15**: `my-team status --team <name>`이 워커 alive/cwd/pane_id, task 통계(pending/in_progress/completed/failed) 출력
- [ ] **AC-16**: `my-team status --json`이 기계 파싱 가능한 JSON 출력
- [ ] **AC-17**: `my-team shutdown --team <name>` 시 graceful 10초 대기 후 페인 kill. `--force` 시 즉시 kill
- [ ] **AC-18**: split-pane 모드에서 shutdown 시 사용자 페인(=리더)은 절대 안 죽임 (OMC 가드 차용)

### 안전 / 보안
- [ ] **AC-19**: 워커 이름은 `[a-zA-Z0-9-]+` 만 허용 (sanitize)
- [ ] **AC-20**: 워커 `cwd`는 절대경로 또는 `~`로 시작. 상대경로 거부
- [ ] **AC-21**: 모든 상태 파일은 0o600 권한, 디렉토리는 0o700 (OMC `fs-utils` 차용)
- [ ] **AC-22**: 메일박스/inbox 경로가 `state_root` 밖으로 벗어나면 거부 (`validateResolvedPath`)

### 호출자 / 환경 분리
- [ ] **AC-23**: 호출자 cwd가 어디든(`~/work-log`, `/tmp`, `/`) 정상 동작. 워커 cwd는 호출자와 무관하게 config 절대경로로 결정됨
- [ ] **AC-24**: `state_root`는 절대경로 또는 `~` 시작 강제. 상대경로 거부
- [ ] **AC-25**: config 파일 경로(`--config`)는 호출자 cwd 기준 상대경로 허용 (`./team.json`, `../team.json`)

### config 동작 / 충돌 처리
- [ ] **AC-26**: `--config` 미지정 시 호출자 cwd에서 `my-team.json` → `team.json` 순으로 자동 탐색. 둘 다 없으면 에러
- [ ] **AC-27**: 워커에 `extra_prompt`와 `extra_prompt_file` 둘 다 있으면 인라인 우선 + stderr에 경고 출력
- [ ] **AC-28**: 같은 `team_name`으로 두 번 `start` 호출 시 (`tmux has-session` 으로 감지) 에러로 거부. 메시지: "Team '<name>' is already running. Use 'my-team shutdown' first."
- [ ] **AC-29**: config의 `agent_type` 에 해당하는 CLI 바이너리가 PATH에 없으면 부팅 시작 전 즉시 실패. 메시지: "Worker '<name>' requires '<cli>', but command not found. Install: <hint>"

### 리더 페인 / 리더 LLM
- [ ] **AC-30**: 리더 페인은 사용자 페인을 그대로 사용. LLM 부재 셸이면 사용자가 직접 명령으로 분배 (시나리오 A). LLM이 떠 있으면 리더 LLM이 자연어로 받아 자동 오케스트레이션 가능 (시나리오 B). 도구 동작은 두 모드에서 동일

### 워커 lifecycle 구현 단순화
- [ ] **AC-31**: 워커가 `my-team api claim-task` 호출 시 (OMC AGENTS.md 호환용) 도구는 적당한 noop 응답을 돌려준다. `claim_token`을 발급하긴 하되 검증 안 함. AGENTS.md 본문은 OMC 그대로 두고 도구 측에서만 단순화 (race condition은 워커=프로젝트 1:1 매핑이라 실제로 안 일어남)
- [x] **AC-32**: `my-team add-worker --team <n> --name <n> --agent-type <t> --cwd <c>`로 **실행 중인** 팀에 워커 페인 하나를 추가한다. 새 워커는 `manifest.workers`에 등록되어 즉시 send/recv 가능하고(`send-message`가 매 호출 roster 멤버십을 enforce하므로 append가 전달의 필요충분조건), 기존 워커는 in-pane notice로 새 peer를 통보받는다. 기존 워커의 `AGENTS.md` roster는 정적이라 갱신하지 않는다(떠 있는 워커 LLM은 이미 로드한 AGENTS.md를 쓰므로 디스크 재작성이 런타임에 도달하지 못함). 검증·페인 생성·manifest append 순서는 fail-safe (manifest append = 커밋 포인트; 그 전 실패는 부작용 없음, 그 후 실패는 새 페인만 kill)

---

## 4. 디렉토리 구조

```
~/IdeaProjects/my-claude-plugin/plugins/teams/
├── PLAN.md                      ← 이 문서
├── plugin.json                  ← Claude Code plugin 메타
├── README.md                    ← 사용자 문서
├── package.json                 ← npm 메타 (선택)
├── bin/
│   └── my-team                  ← shebang `#!/usr/bin/env node`, dist/cli.js 호출
├── src/
│   ├── cli.js                   ← 진입점, 서브커맨드 라우팅
│   ├── commands/
│   │   ├── start.js             ← 팀 부팅
│   │   ├── status.js            ← 상태 조회
│   │   ├── msg.js               ← 워커 inbox 메시지
│   │   ├── add-task.js          ← 정형 task 등록
│   │   ├── shutdown.js          ← 팀 종료
│   │   └── api/                 ← 워커 LLM 내부 API
│   │       ├── transition-task-status.js
│   │       ├── send-message.js
│   │       ├── read-task.js
│   │       └── create-task.js
│   ├── lib/                     ← OMC 차용/stub 모듈
│   │   ├── tmux-utils.js        ← OMC 그대로 차용
│   │   ├── tmux-session.js      ← OMC 변형 (workers 배열로 cwd 분기)
│   │   ├── tmux-comm.js         ← OMC 그대로 차용 (저수준 sendTmuxTrigger)
│   │   ├── inbox-outbox.js      ← OMC 그대로 차용 (byte cursor)
│   │   ├── worker-bootstrap.js  ← OMC 그대로 차용 (generateWorkerOverlay)
│   │   ├── task-ops.js          ← 단순화된 task lifecycle (claim 없음)
│   │   ├── state-paths.js       ← OMC 그대로 차용
│   │   ├── team-name.js         ← OMC 그대로 차용 (sanitize)
│   │   ├── fs-utils.js          ← OMC 그대로 차용 (atomic write, 권한)
│   │   ├── prompt-helpers.js    ← stub (sanitizePromptContent만)
│   │   ├── cli-rendering.js     ← stub (formatOmcCliInvocation)
│   │   └── state-root.js        ← stub (config-dir 대체)
│   └── config/
│       ├── schema.js            ← config JSON 검증 (Ajv 또는 단순 검증)
│       └── parser.js            ← config 파싱 + 정규화
├── skills/
│   └── my-team/
│       └── SKILL.md             ← Claude Code skill 등록
├── test/
│   ├── start.test.js
│   ├── msg.test.js
│   ├── task-lifecycle.test.js
│   └── fixtures/
│       └── sample-team.json
└── LICENSE                      ← MIT + OMC 차용 표시
```

---

## 5. 구현 단계 (Implementation Steps)

### Phase 1: OMC 코드 추출 + stub 작성 (Day 1, 오전)

**목표**: OMC 의존성 없이 독립 실행 가능한 핵심 모듈 준비

1. **차용 (그대로 복사)** — `src/lib/`로 복사하면서 import 경로만 상대경로로 조정
   - `dist/cli/tmux-utils.js` → `src/lib/tmux-utils.js`
   - `dist/team/tmux-comm.js` (저수준 함수만)
   - `dist/team/inbox-outbox.js`
   - `dist/team/state-paths.js`
   - `dist/team/team-name.js`
   - `dist/team/fs-utils.js`
   - `dist/team/worker-bootstrap.js`
   - 라이선스 표시 추가: 각 파일 상단에 `Adapted from oh-my-claude-sisyphus (MIT)` 주석

2. **stub 3개 작성**
   - `src/lib/prompt-helpers.js` (10줄): `sanitizePromptContent`만 구현
   - `src/lib/cli-rendering.js` (5줄): `formatOmcCliInvocation` → `my-team <suffix>` 반환
   - `src/lib/state-root.js` (10줄): `getStateRootBase` + `getClaudeConfigDir` 별칭

3. **`tmux-session.js` 변형** — OMC 원본 복사 후 단일 cwd → `workers: WorkerSpec[]` 으로 시그니처 변경
   - `createTeamSession(teamName, workers, options)` 시그니처
   - 루프 안에서 `'-c', workers[i].cwd` 사용
   - 나머지 (페인 ID 추적, 레이아웃, 검증)는 그대로

4. **`task-ops.js` 단순화** — `dist/team/task-file-ops.js`에서 핵심만 추출
   - `readTask`, `writeTask`, `nextTaskId` 유지
   - `withTaskLock`, `claim_token` 검증 메커니즘 제거 (claim-task는 noop 응답으로 처리)
   - `transitionTaskStatus(stateRoot, taskId, newStatus)` 단순화 (~30줄)

4.5. **R2 즉시 검증** — `generateWorkerOverlay()` 호출해 결과 AGENTS.md 문자열에서 `omc team api ...` 가 `my-team api ...` 로 변환됐는지 확인. 안 되면 stub 수정 후 재검증

4.6. **README skeleton 작성** — Phase 4 본격 작성 전 최소 골격 (~30줄): 목적 한 단락, 설치 1줄, "WIP" 표시, config 예시 1개. 외부 사용자가 디렉토리 보고 막막하지 않게

### Phase 2: 사용자 명령 구현 (Day 1, 오후)

5. **`src/cli.js` 진입점** — commander 또는 argv 직접 파싱
   - 글로벌 옵션: `--version`, `--help`, `--verbose`
   - 서브커맨드 라우팅: `start`, `status`, `msg`, `add-task`, `shutdown`, `api`

6. **`commands/start.js`** (가장 큰 모듈, ~300줄)
   - config 파일 파싱 (JSON) 또는 인라인 `--worker` 인자 처리
   - 검증: 워커 이름 `[a-zA-Z0-9-]+`, cwd 절대경로/`~`, agent_type 화이트리스트
   - `setStateRootBase` 호출로 상태 루트 설정
   - `createTeamSession(teamName, workers)` 호출
   - 각 워커별로:
     - `ensureWorkerStateDir()` 호출
     - `task` 있으면 `writeTask()`로 `tasks/<id>.json` 생성
     - `generateWorkerOverlay({ teamName, workerName, agentType, tasks, bootstrapInstructions: extra_prompt, ... })` 호출 → AGENTS.md 작성
     - 초기 inbox.md 작성 (`composeInitialInbox`)
     - `spawnWorkerInPane()` 호출 → CLI 부팅
     - `waitForPaneReady()` 폴링
     - `generateTriggerMessage` + `sendToWorker`로 시작 트리거 발송
   - 옵션: `--dry-run`, `--new-window`, `--detached`

7. **`commands/msg.js`** (~50줄)
   - `appendToInbox()` + `sendTmuxTrigger()`
   - 200자 캡 검증 (트리거만, 본문은 inbox에 무제한)
   - 옵션: `--from-file`, `--no-trigger`

8. **`commands/add-task.js`** (~150줄)
   - `nextTaskId()` 자동 부여 또는 `--id` 명시
   - `writeTask()` 호출로 task 파일 생성
   - 워커 inbox에 알림 어펜드: "New task #N assigned: <subject>. Read tasks/N.json"
   - tmux 트리거 발송 (`--no-notify`로 끌 수 있음)

9. **`commands/shutdown.js`** (~120줄)
   - mode 감지 (split-pane / dedicated-window / detached-session)
   - graceful: shutdown.json sentinel 작성, `MY_TEAM_GRACE_MS`(기본 10000) 대기, kill-pane
   - `--force`: 즉시 kill
   - split-pane 모드는 사용자 페인 보호 (OMC 가드 그대로)

10. **`commands/status.js`** (~150줄)
    - `tmux list-panes -a -F '#{pane_id} #{pane_current_path} #{pane_dead}'` 실행
    - `tasks/*.json` 모두 읽어 통계
    - `workers/*/heartbeat.json` 또는 `pane_current_command`로 alive 판정
    - 사람 친화적 출력 + `--json`

### Phase 3: 워커 내부 API 구현 (Day 2, 오전)

11. **`commands/api/transition-task-status.js`** (~40줄)
    - `--input '{"team_name":"...","task_id":"...","from":"...","to":"...","claim_token":"..."}' --json`
    - `claim_token`은 받기만 하고 검증 안 함 (OMC AGENTS.md 호환용)
    - `transitionTaskStatus()` 호출
    - JSON 응답 출력

12. **`commands/api/send-message.js`** (~80줄)
    - `--input '{"team_name":"...","from_worker":"...","to_worker":"...","body":"..."}' --json`
    - `to_worker`의 `mailbox.json`에 메시지 어펜드
    - 받는 워커 페인 ID 조회 → tmux 트리거 발송
    - "leader-fixed" 특수 처리: leader inbox.md에 어펜드

13. **`commands/api/read-task.js`** (~30줄)
    - `--input '{"team_name":"...","task_id":"..."}' --json`
    - `tasks/<id>.json` 읽고 그대로 출력

14. **`commands/api/create-task.js`** (~80줄)
    - `--input '{"team_name":"...","subject":"...","description":"...","assignee":"..."}' --json`
    - `add-task` 명령과 동일 로직, 다른 진입점

### Phase 4: 통합 + 검증 (Day 2, 오후 ~ Day 3)

15. **plugin.json + SKILL.md 작성**
    - `plugin.json`: 이름 `teams`, 버전 0.1.0, 명령/스킬 메타
    - `skills/my-team/SKILL.md`: Claude Code 슬래시 커맨드 등록

16. **테스트 시나리오 — 수동 검증**
    - **시나리오 A**: 단일 워커 부팅 + msg 전송 + shutdown
      ```bash
      my-team start --config ./test/fixtures/single.json
      my-team msg --team t1 --to w0 --body "hello"
      my-team status --team t1
      my-team shutdown --team t1
      ```
    - **시나리오 B**: 2 워커 다른 cwd + 워커 간 mailbox
      ```bash
      my-team start --config ./test/fixtures/two-projects.json
      # 워커 0이 워커 1에게 메시지 송신 시뮬레이션
      my-team api send-message --input '{...}' --json
      my-team status --team t2
      ```
    - **시나리오 C**: task lifecycle
      ```bash
      my-team start --config ./test/fixtures/with-tasks.json
      my-team add-task --team t3 --worker w0 --subject "..." --description "..."
      my-team api read-task --input '{...}' --json
      my-team api transition-task-status --input '{...}' --json
      ```

17. **자동 테스트 (vitest 또는 node:test)**
    - `start.test.js`: tmux 명령 mock, config 파싱·검증
    - `msg.test.js`: appendToInbox + sendTmuxTrigger 호출 검증
    - `task-lifecycle.test.js`: task 파일 생성·전이

18. **README.md 작성**
    - 설치 방법
    - config 파일 예시 (3 프로젝트 시나리오)
    - 명령 reference
    - 주의사항: worktree는 사용자 책임, 단일 프로세스 모델

19. **LICENSE + OMC 차용 표시**
    - MIT 라이선스
    - `NOTICE` 또는 README 끝에: "Adapted from oh-my-claude-sisyphus (https://github.com/Yeachan-Heo/oh-my-claudecode), MIT License"

---

## 6. 위험 / 완화 (Risks & Mitigations)

| 위험 | 완화 |
|------|------|
| **R1**: OMC 코드 차용 시 의존성이 예상보다 깊음 | Phase 1에서 의존성 그래프 검증 우선. 깊으면 stub 추가 작성 |
| **R2**: `formatOmcCliInvocation` stub만 바꿔도 AGENTS.md에 박히는 명령이 정확히 작동하나 미검증 | **Phase 1 끝** 즉시 검증 (워커 부팅까진 안 가도 됨) — `generateWorkerOverlay()` 호출만으로 AGENTS.md 문자열 만들어보고 `my-team api ...` 변환 확인. 결함이면 Phase 2 가기 전 수정 |
| **R3**: 워커 LLM이 OMC AGENTS.md의 `claim-task` 명령을 호출하는데 우리 도구는 미구현 | AGENTS.md를 약간 수정 — `claim-task` 라인을 "transition to in_progress"로 대체. Phase 2에서 `worker-bootstrap.js` 변형 |
| **R4**: tmux 페인의 `--cwd`가 워커별로 다를 때 OMC `sendToWorker` 휴리스틱(busy/copy-mode 감지)이 정상 동작하지 않을 가능성 | tmux는 페인별로 독립 동작하므로 cwd 차이는 무관. 시나리오 B로 검증 |
| **R5**: 단일 프로세스 모델인데 사용자가 동시에 여러 `my-team msg` 명령을 쳐서 race | inbox.md `appendFile`은 OS 레벨 atomic. `tasks/<id>.json`만 atomicWriteJson으로 보호. 충돌 가능성 낮음 |
| **R6**: `--dry-run`이 실제 명령을 안 날리는지 검증 어려움 | 모든 mutation은 `dryRun` 플래그를 통해 console.log만 하도록 일관 처리 |
| **R7**: 사용자가 `~/IdeaProjects/A`처럼 worktree 아닌 일반 디렉토리를 cwd로 줘도 동작해야 함 | git 검사 절대 안 함 (worktree는 사용자 책임). cwd는 단순 디렉토리 존재 검사만 |

### Known Limitations (워커 메시지 수신)

워커 메일박스 self-poll(`mailbox-list` / `mailbox-mark-delivered`) 도입으로
trigger 유실로 인한 미수신은 회복된다. 남은 항목은 아래 K1 하나다.

| # | 결함 | 코드 위치 | 영향 | 회복 가능 여부 |
|---|------|----------|------|---------------|
| **K1** | `sendToWorker`의 trigger 성공 판정이 false-positive 가능 — busy pane에서 키스트로크가 confirm-modal 등에 흡수돼 화면에서 사라지면 "전달 성공"으로 오판, `notified_at`이 잘못 박힘 | `src/lib/tmux-session.js:404-444` (특히 433, 441), `src/lib/tmux-comm.js:88-92` | 워커가 trigger 자체를 못 봄 | 메시지는 파일에 있으므로 self-poll로 *내용*은 회복됨. 즉시성만 손실 |

> **메일박스 동시 쓰기 race — 현 모델에서는 발생 불가, 미래 조건부 이슈.**
> `queueDirectMessage`(송신)와 `mailbox-mark-delivered`(소비 확인)는 모두
> read→modify→write 무락 패턴(`src/lib/tmux-comm.js:76-85`, `mailbox-mark-delivered.js` 동일).
> 그러나 현재 오케스트레이션은 *사람 1명*이 단일 진입점에서 명령을 직렬로
> 실행하는 모델이므로 같은 메일박스 파일을 동시에 건드리는 호출자가 존재하지
> 않는다 — 이 race는 *실현되지 않는다*.
>
> 워커가 서로를 오케스트레이션해 명령이 병렬로 발생하게 되면 그때 비로소
> race가 가능해진다. 그 단계에 진입하기 전 atomic write+rename 또는 JSONL
> 전환으로 선제 보강이 필요하다. **현재 작업 범위에서는 다루지 않는다.**

---

## 7. 검증 단계 (Verification Steps)

도구 동작 검증 (구현 완료 후 사용자가 직접 실행):

```bash
# 1. 디렉토리 + 설치
cd ~/IdeaProjects/my-claude-plugin/plugins/teams
ls bin/my-team src/cli.js src/lib/tmux-session.js  # 핵심 파일 존재 확인

# 2. 헬프
./bin/my-team --help                                # 사용자용 명령 4개(start/status/shutdown/monitor) + api 표시
./bin/my-team start --help                          # 옵션 표시

# 3. dry-run
./bin/my-team start --config ./test/fixtures/two-projects.json --dry-run
# → tmux 명령들이 stdout에 plan으로 출력, 실제 페인 안 뜸

# 4. 실제 부팅 (테스트용 디렉토리 미리 준비)
mkdir -p /tmp/proj-a /tmp/proj-b
./bin/my-team start --config ./test/fixtures/two-projects.json

# 5. 페인 cwd 검증
tmux list-panes -a -F '#{pane_id} #{pane_current_path}'
# → 페인별로 /tmp/proj-a, /tmp/proj-b가 보여야 함

# 6. 메시지 전달
./bin/my-team msg --team test --to w0 --body "hello from user"
# → /tmp/.my-team/sessions/test/workers/w0/inbox.md에 어펜드 확인

# 7. 상태 조회
./bin/my-team status --team test
./bin/my-team status --team test --json | jq .

# 8. task lifecycle
./bin/my-team add-task --team test --worker w0 \
  --subject "test task" --description "do something"
./bin/my-team api read-task --input '{"team_name":"test","task_id":"1"}' --json

# 9. 종료
./bin/my-team shutdown --team test
tmux list-sessions | grep my-team   # → 세션 사라짐 확인
```

---

## 8. 인터페이스 요약

### 8.1 config 파일 (JSON Schema)

```typescript
interface TeamConfig {
    team_name: string;                    // 필수, [a-zA-Z0-9-]+
    state_root?: string;                  // 기본: ~/.my-team/sessions/<team_name>
    new_window?: boolean;                 // 기본: false
    detached?: boolean;                   // 기본: 자동 감지

    workers: WorkerConfig[];              // 1-10 길이
}

interface WorkerConfig {
    name: string;                         // 필수, [a-zA-Z0-9-]+
    cwd: string;                          // 필수, 절대경로 또는 ~ 시작
    agent_type: 'claude' | 'codex' | 'gemini' | 'cursor';

    description?: string;                 // 다른 워커가 Team Roster에서 보는 한 줄 소개
                                          //   (없으면 extra_prompt 첫 줄로 폴백)
    extra_prompt?: string;                // AGENTS.md `## Role Context` 슬롯 (자기 자신용 상세 지시)
    extra_prompt_file?: string;           // 옵션, 파일에서 읽기

    task?: {                              // 부팅 task (옵션)
        subject: string;
        description: string;
    };

    env?: Record<string, string>;         // 추가 환경변수
}
```

### 8.2 CLI 명령 표

| 명령 | 시그니처 | 용도 |
|------|---------|------|
| `start` | `--config <path>` 또는 `--name <n> --worker <spec>...` | 팀 부팅 |
| `status` | `--team <name> [--json]` | 상태 조회 |
| `msg` | `--team <n> --to <worker> --body <text>` | 워커 inbox 메시지 |
| `add-task` | `--team <n> --worker <w> --subject <s> --description <d>` | 정형 task 등록 |
| `shutdown` | `--team <n> [--force]` | 팀 종료 |
| `api transition-task-status` | `--input <json> --json` | (워커용) task 상태 전이 |
| `api send-message` | `--input <json> --json` | (워커용) 워커 간 메시지 |
| `api read-task` | `--input <json> --json` | (워커용) task 조회 |
| `api create-task` | `--input <json> --json` | (워커용) 새 task 생성 |

### 8.3 환경변수

| 변수 | 의미 | 기본값 |
|------|------|--------|
| `MY_TEAM_STATE_ROOT_BASE` | 상태 루트 베이스 경로 | `~/.my-team/sessions` |
| `MY_TEAM_GRACE_MS` | shutdown graceful 대기 | `10000` |
| `MY_TEAM_NO_RC` | 워커 셸이 zshrc/bashrc 안 source | `0` |
| `MY_TEAM_DEBUG` | 디버그 출력 | `0` |

---

## 9. 코드량 분포 추정

| 영역 | 줄 수 | 비고 |
|------|------|------|
| `cli.js` (라우팅) | ~80 | argv 파싱, 서브커맨드 디스패치 |
| `commands/start.js` | ~300 | 가장 큰 모듈, config 검증 + tmux 토폴로지 |
| `commands/status.js` | ~150 | tmux 조회 + task 통계 + 출력 포매팅 |
| `commands/msg.js` | ~50 | append + 트리거 |
| `commands/add-task.js` | ~150 | task 파일 작성 + inbox 알림 |
| `commands/shutdown.js` | ~120 | mode별 종료 분기 |
| `commands/api/*.js` | ~230 (4개 합) | 단순 wrapper |
| `lib/` 차용 | ~600 | OMC 차용 (변형은 ~50줄만) |
| `lib/` stub | ~25 | 3개 stub 합계 |
| `config/parser.js` + `schema.js` | ~100 | JSON 검증 + 정규화 |
| **합계** | **~1,300** | 목표 범위 1,200–1,500 안 |

---

## 10. 다음 단계 (Approval & Execution)

이 plan은 `pending approval` 상태입니다. 사용자가 명시적으로 실행을 승인해야 구현이 시작됩니다.

승인 옵션:
1. **`team` 스킬로 병렬 실행** — Phase 1/2/3을 병렬 에이전트로 분담
2. **`ralph` 스킬로 순차 실행** — 단계별 검증하며 sequential 진행
3. **수동 진행** — 사용자가 단계마다 직접 확인하며 implementation
4. **변경 요청** — 위 plan에 수정사항 반영
5. **거부** — plan 폐기

추천: **2번 (ralph)** — 도구가 작아서 (1,300줄) ralph의 sequential + verification이 충분. team 병렬화 이득은 작고 OMC 코드 차용 검증을 단계별로 하는 게 안전.

---

## 11. 변경 이력

- **2026-05-10 (v1)**: 초안 작성 (Direct mode, 인터뷰 생략 — 사전 대화로 모든 결정사항 합의됨)
- **2026-05-10 (v2)**: PLAN 검토 라운드 1 반영
    - §2 결정사항 5개 추가 (config 자동 탐색, extra_prompt 우선순위, 팀 이름 재시작 거부, CLI 미설치 처리, 호출자 cwd 분리)
    - §3 인수 조건 7개 추가 (AC-23~AC-29: 호출자/환경 분리 + config 동작/충돌 처리)
    - 워커 `cwd` vs `state_root` 절대경로 강제 명시
- **2026-05-10 (v3)**: PLAN 검토 라운드 2 반영 (구현 전략 결정)
    - 언어: JavaScript (ESM), TypeScript 미사용
    - 디렉토리: `src/` 한 곳만, `dist/` 없음
    - 의존성: `commander` 1개만 (JSON 검증은 inline 함수)
    - 테스트: `node --test` (Node 20 표준, vitest 미사용)
- **2026-05-10 (v4)**: PLAN 검토 라운드 3 반영 (운영/검증 결정)
    - §6 R2 검증 시점을 Phase 1 끝으로 앞당김 (조기 검증으로 재작업 방지)
    - §3 AC-30 추가: 리더 페인 시나리오 A(셸)/B(LLM) 구분
    - §3 AC-31 추가: claim-task는 도구가 noop 응답으로 처리, AGENTS.md 안 패치
    - §5 Phase 1 step 4.5 추가: R2 즉시 검증
    - §5 Phase 1 step 4.6 추가: README skeleton 먼저 작성
- **2026-05-20 (v5)**: 워커 메시지 수신 문제 대응
    - 누락 API 구현: `api mailbox-list`, `api mailbox-mark-delivered` (AGENTS.md가 호출하지만 cli.js에 미등록 상태였음 — 워커가 메일박스를 읽을 수단 자체가 없던 결함)
    - 메일박스 메시지에 `consumed_at` 필드 도입 → cursor 역할. `mailbox-list`는 기본적으로 미소비 메시지만 반환
    - `worker-bootstrap.js` AGENTS.md에 self-poll discipline 추가, tmux trigger를 best-effort hint로 격하
    - §6 Known Limitations 추가: K1(trigger false-positive). 메일박스 동시 쓰기는 단일 작업자 모델에서 발생 불가 — 미래 조건부 이슈로 기록
- **2026-05-20 (v6)**: 워커 통신 모델을 비동기 단일 모델로 단순화
    - body convention 토큰 전면 제거 (`[BLOCKING]` / `[BLOCKED]` / `[NONBLOCKING]` / `[REQUIRES ACK]` / `[ACK]`) — `reply_within` 등은 시스템이 강제하지 않아 워커에게 혼란만 줬음
    - 메시지 스키마에 `reply_to` 필드 도입 (원본 `message_id` 참조) → 비동기 응답을 구조적으로 매칭. `send-message`가 optional `reply_to` 입력을 받음
    - AGENTS.md 재서술: 모든 워커 간 통신은 비동기, 워커는 답을 기다리며 멈추지 않음. 답이 필요한 메시지는 per-cycle `mailbox-list`가 자연히 surface
- **2026-05-20 (v7)**: 워커 `description` 필드 도입 (피어 인식)
    - config WorkerConfig에 optional `description` 추가 — 다른 워커가 Team Roster에서 보는 한 줄 소개. 없으면 `extra_prompt` 첫 줄로 폴백 (후방 호환)
    - `extra_prompt`(자기 자신용 상세 지시)와 역할 분리 — 이전엔 roster가 `extra_prompt` 첫 줄을 재활용하던 암묵적 구조였음
    - AGENTS.md Team Roster 섹션에 "스코프 밖 문제는 역할이 맞는 peer에게 위임하라" 안내 추가 → 워커가 도움 요청 여부를 스스로 판단

---

## 부록 A: OMC 차용 모듈 명세

| OMC 원본 | 우리 위치 | 변경 사항 |
|---------|---------|---------|
| `dist/cli/tmux-utils.js` | `src/lib/tmux-utils.js` | 그대로 |
| `dist/team/tmux-session.js` | `src/lib/tmux-session.js` | `createTeamSession` 시그니처 변경: `cwd: string` → `workers: WorkerSpec[]`. 루프 안 `-c workers[i].cwd` |
| `dist/team/tmux-comm.js` | `src/lib/tmux-comm.js` | 저수준 함수만 (`sendTmuxTrigger`, `queueInboxInstruction` 단순 버전, `queueDirectMessage`, `queueBroadcastMessage`). dispatch queue 의존 없음 |
| `dist/team/inbox-outbox.js` | `src/lib/inbox-outbox.js` | 그대로 |
| `dist/team/worker-bootstrap.js` | `src/lib/worker-bootstrap.js` | 그대로. AGENTS.md 본문에서 `claim-task` 부분만 텍스트 패치 (선택) |
| `dist/team/state-paths.js` | `src/lib/state-paths.js` | 그대로 |
| `dist/team/team-name.js` | `src/lib/team-name.js` | 그대로 |
| `dist/team/fs-utils.js` | `src/lib/fs-utils.js` | 그대로 |
| `dist/team/task-file-ops.js` | `src/lib/task-ops.js` | 단순화. `withTaskLock`, `claim_token` 검증 제거. `transitionTaskStatus` 단순화 |

## 부록 B: stub 모듈 명세

| OMC 원본 | 우리 stub | 줄 수 |
|---------|---------|------|
| `dist/agents/prompt-helpers.js` (195줄) | `src/lib/prompt-helpers.js` | 10 (sanitizePromptContent만) |
| `dist/utils/omc-cli-rendering.js` (46줄) | `src/lib/cli-rendering.js` | 5 (formatOmcCliInvocation → `my-team <suffix>`) |
| `dist/utils/config-dir.js` (46줄) | `src/lib/state-root.js` | 10 (state_root_base + getClaudeConfigDir 별칭) |

## 부록 C: 사용 안 하는 모듈

- `dist/team/dispatch-queue.js` (~600줄): 분산 락, 상태머신, hook dispatch — 단일 프로세스 모델이라 불필요
- `dist/team/mcp-comm.js`: dispatch queue를 사용하는 high-level wrapper. 우리는 저수준 `tmux-comm.js`만 사용
- `dist/team/git-worktree.js`: worktree는 사용자 책임
- `dist/team/factcheck/`, `dist/team/delegation-routing/`, `dist/team/planning/`: OMC 거버넌스, 무관
- `claim-task` 핸들러 (`api-interop.js` 일부): race condition 불필요한 워커=프로젝트 1:1 모델
