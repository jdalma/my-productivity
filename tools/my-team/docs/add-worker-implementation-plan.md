# add-worker 구현 계획 (FINAL)

`my-team add-worker` — 이미 실행 중인 팀 세션에 워커 **하나**를 mid-session으로 추가한다. 5개 축(tmux-topology, state-manifest, roster-resync, validation-edge, tests-docs)의 hardened 분석을 코드베이스 직접 검증으로 ground-truth 한 뒤 단일 계획으로 병합했다.

## 0. 확정된 사용자 결정 (2026-06-05)

코딩 전 게이트였던 3개 결정이 확정되었다. 아래 §2의 [사용자 결정 필요] 항목은 모두 이 결정으로 닫힌다.

1. **Roster 재동기화 → 디스크 AGENTS.md 재작성 안 함 (§2 결정 #1 = 옵션 1).** 대신 **새 워커 합류 시 기존 모든 워커 pane에 in-pane notice를 보낸다.** 인지는 in-pane notice가 전담하고, 디스크의 기존 워커 AGENTS.md는 건드리지 않는다(role 텍스트 손실·부작용 회피). 알려진 한계: in-pane notice는 best-effort(busy pane이면 유실, 200자 제한)이며, 기존 워커 CLI가 재시작되면 그 워커의 정적 AGENTS.md roster에는 새 peer가 없다.
2. **CLI 표면 → 최소 (§2 결정 #2 = 옵션 1).** `--team --name --agent-type --cwd` (+ `--state-root`). 새 워커의 roster role은 빈 문자열. `--description`/`--extra-prompt`/`--launch-arg`/`--env-var`는 포함하지 않는다.
3. **동시성 → 문서화 + ENOENT 가드 (§2 결정 #3 = 옵션 1).** 락파일 없음. manifest 최종 write 직전 reload, ENOENT면 "team shut down mid-operation"으로 abort + 새 pane kill. add-worker-vs-shutdown 레이스는 레포의 직렬-인간 모델과 일관된 known limitation으로 문서화.

§7 미해결 질문 중 #4(in-pane notice 포맷 → 자유 텍스트), #5(liveness 앵커 → 첫 워커 pane)는 권장안으로 확정. **남은 코딩 전 미결: 없음.**

## 1. 결론 요약

**구현 가능하다.** 막는 요소는 없다. 단일 정답 게이트는 "기존 워커가 새 peer를 어떻게 알게 되는가"(roster re-sync)이며, 코드 검증 결과 다음과 같이 해소된다:

- **전달(delivery)**: `send-message.js`는 매 호출마다 `manifest.workers`를 다시 읽어 sender/recipient를 검증한다 (`send-message.js:47,58,65`). 따라서 **`manifest.workers`에 새 워커 엔트리를 append 하는 것만으로 새 워커로/에서의 메시지 전달이 필요충분조건으로 성립**한다. AGENTS.md는 이 경로에 없다.
- **인지(awareness)**: 기존 워커의 LLM은 **실행 시점에 한 번 읽은 AGENTS.md**로 peer 목록을 고정한다. 디스크의 AGENTS.md를 다시 써도 **이미 떠 있는 LLM 프로세스는 갱신되지 않는다**. 런타임에 알리는 유일한 채널은 **pane 내 in-pane notice**(`sendToWorker`)다.

→ **해소책 = `manifest.workers` append (전달) + 기존 워커 pane에 새 peer를 이름으로 명시하는 in-pane notice (인지).** 기존 워커 AGENTS.md 디스크 재작성은 "선택적 재시작 보험"일 뿐이고 **lossy**하다 — `description`/`extra_prompt`가 manifest에 저장되지 않으므로(`start.js:229-235`) 재생성 시 roster의 role 텍스트가 사라진다. tmux-topology 분석이 헤드라인으로 내세운 "모든 overlay 재생성"은 **인지 메커니즘이 될 수 없으므로** 이 섹션을 주도해서는 안 된다.

두 번째로 검증된 핵심: **`createTeamSession()`은 재사용 불가.** `detectTeamMultiplexerContext()`가 호출자 셸의 `env.TMUX`를 읽어(`tmux-session.js:197-198`) add-worker가 tmux 밖에서 호출되면 **두 번째 고아 세션**을 만든다. 새 워커는 `manifest.session_name`을 split 타깃으로 직접 사용해야 한다.

## 2. 설계 결정

### (a) 기존 워커가 새 peer를 알게 되는 방법 — [확정: manifest append + in-pane notice]

`send-message`가 roster whitelist를 매 호출 enforce 하므로(`manifest.workers.find()`, `send-message.js:58,65`):

| 메커니즘 | 효과 | 트레이드오프 |
|---------|------|------------|
| `manifest.workers` append | 전달의 필요충분조건. 새 워커가 send/recv 가능 | 단독으로는 기존 LLM이 새 peer 존재를 모름 |
| in-pane notice (`sendToWorker`) | 떠 있는 LLM에게 런타임으로 새 peer를 이름으로 알림 | best-effort(busy pane이면 유실), 200자 제한 |
| 기존 워커 AGENTS.md 디스크 재작성 | 워커 CLI 재시작 시에만 반영되는 보험 | **lossy**(role 텍스트 손실), 워커가 읽는 파일을 건드리는 부작용 |

**확정**: append + in-pane notice를 채택. 디스크 재작성은 아래 [사용자 결정 필요 #1]로 분리.

### (b) CLI 플래그 설계 — status/shutdown 관례 미러링

- `--team <name>` (required), `--name <name>` (required), `--agent-type <type>` (required), `--cwd <path>` (required), `--state-root <path>` (optional).
- 반복 옵션 `--launch-arg`, `--env-var key=value`는 start의 `--worker` 반복 패턴을 따른다.
- 콜론 패킹(`name:agent:cwd`) 대신 **명시적 플래그** 사용(inline `--worker` spec과 달리 mid-session은 명확성이 중요).
- **`--state-root` 주의(pre-existing, add-worker가 만든 문제 아님)**: `send-message.js:47`은 `loadManifest(team_name)`을 stateRoot 인자 없이 호출하므로 워커의 peer 메시징은 default base(`MY_TEAM_STATE_ROOT_BASE` 또는 `~/.my-team/sessions/<team>`)로만 manifest를 찾는다. custom state_root 팀은 이미 `MY_TEAM_STATE_ROOT_BASE`가 필요하다. add-worker는 start와 **동일한 env 계약**(`MY_TEAM_STATE_ROOT`)으로 spawn 하면 되고, 이 한계를 여기서 고치지 않는다.

### (c) 실패/롤백 순서 — manifest append가 트랜잭션 커밋 포인트

manifest append를 **마지막**에 둔다. split 이후 어떤 단계든 실패하면 **새 pane만** kill, **leader는 절대 kill 하지 않는다**(`killWorkerPanes`는 leader를 skip, `tmux-session.js:507`). 상세는 §4.

### 동시성 — [확정: 락 없음, 직렬-인간 모델 유지]

README 206-209가 명시: "a single human drives commands serially — no concurrent writers", RMW는 의도적으로 unlocked. validation-edge 분석의 "lockfile REQUIRED"는 **레포 모델과 CLAUDE.md 단순함-우선 원칙에 정면 위배**다. 락파일을 추가하지 않는다. 대신 **싼 가드**: 최종 write 직전에 manifest를 reload, ENOENT면 "team was shut down mid-operation"으로 abort + 새 pane kill. add-worker-vs-shutdown 레이스는 기존 모델과 일관된 known limitation으로 문서화.

### 거부된 over-engineering (CLAUDE.md 외과적 변경 원칙)

- **`ensureWorkerStateDir`에 `incoming-spool/<name>` pre-create 추가 안 함**: `absorbIncomingSpool`이 ENOENT를 이미 삼키고(`tmux-comm.js:156-158`), `dropSpoolMessage`가 lazy 생성한다(`tmux-comm.js:140`). start.js가 공유하는 함수에 대한 drive-by 변경 — 생략.
- **`updateManifest`/공유 agent-cli 모듈은 순 코드를 줄일 때만**. 아니면 `validateWorker`/`AGENT_CLI`/`validateAgentCLIs`를 제자리에서 export 하고 RMW를 인라인. 투기적 추상화 금지.

### [사용자 결정 필요]

**#1 — 기존 워커 AGENTS.md 디스크 재작성 여부**
1. **재작성 안 함** (권장): manifest append + in-pane notice만. 단순, 부작용 없음, role 텍스트 손실 없음. 단점: 기존 워커 CLI가 재시작되면 AGENTS.md roster에 새 peer가 없다(in-pane notice로만 알았으므로 컨텍스트에서 사라질 수 있음).
2. **재작성 함**: 모든 기존 워커의 AGENTS.md를 새 roster로 다시 쓴다. 장점: 재시작 시에도 새 peer가 roster에 남음. 단점: `description`/`extra_prompt`가 manifest에 없어 **role 텍스트가 빈 문자열로 손실**되고, 워커가 읽고 있을 수 있는 파일을 건드린다.
3. **재작성 + role 보존**: manifest 스키마에 `description`/`extra_prompt`를 추가 저장하도록 start.js도 함께 수정. 장점: 손실 없는 재작성. 단점: start.js 스키마 변경(범위 확대), 외과적 변경 원칙에서 벗어남.

**#2 — CLI 표면 범위**
1. **최소** (권장): `--name`, `--agent-type`, `--cwd`만. 새 워커 roster role은 빈 문자열. 단순.
2. **확장**: `--description`(peer roster용 한 줄), `--extra-prompt`/`--extra-prompt-file`(새 워커 자기 지시), `--launch-arg`, `--env-var`까지. start의 워커 정의와 동등. 단점: 표면 증가, #1-3과 연동 시에만 description이 의미 있음.

**#3 — 동시성 자세** (권장: 문서화, 락 없음)
1. **문서화만** (권장): reload-ENOENT 가드 + known limitation 명시. 레포 모델 일관.
2. **락파일**: `state_root/.add-worker.lock`. 레포의 직렬-인간 모델·단순함 원칙과 충돌. 비권장.

> auto-spawn 여부는 [사용자 결정 필요]가 아니다 — "워커를 추가한다"는 곧 "pane에서 도는 CLI"를 의미하므로 auto-spawn이 기능 정의 자체다. 기본값으로 수행한다.

## 3. 수정/신규 파일 목록 (구현 순서)

| 파일 경로 | 신규/수정 | 구체적 변경 | risk |
|----------|----------|-----------|------|
| `src/config/parser.js` | 수정 | `function validateWorker`(112) → `export function validateWorker`. add-worker가 필드 검증(cwd 존재/디렉토리, agent_type whitelist, env, launch_args)을 재사용. `seen` Set을 manifest 워커 raw 이름으로 미리 채워 호출 | low |
| `src/commands/start.js` | 수정 | `AGENT_CLI`(36), `commandExists`(43), `validateAgentCLIs`(98)에 `export` 추가 (또는 `src/lib/agent-cli.js`로 이동 — 순 코드 줄 때만). add-worker가 PATH 검증·bin 매핑 재사용 | low |
| `src/lib/tmux-session.js` | 수정 | 신규 export `async function addWorkerPane(sessionName, anchorPaneId, worker, options)`. `manifest.session_name`을 타깃으로 `split-window -t <anchor> -c <cwd> -d -P -F '#{pane_id}'`(283-292 로직 추출), `@worker_name` set-option(298-300 재assert 포함), `applyTeamLayout` 호출. `{paneId}` 반환. **`createTeamSession` 재사용 금지** | medium |
| `src/commands/add-worker.js` | 신규 | `runAddWorker(opts)` 구현 (§4 순서 그대로) | high |
| `src/cli.js` | 수정 | `import { runAddWorker }`(line 21 부근). monitor(111)와 api(114) 사이에 `.command('add-worker')` 블록: `--team`/`--name`/`--cwd`/`--agent-type` requiredOption + `--state-root` option. 최상위 user 커맨드(api 하위 아님) | low |
| `test/commands/add-worker.test.js` | 신규 | send-message.test.js fixture 패턴 따라 작성 (§5) | low |
| `README.md` | 수정 | 240-244 "no mid-session command" 분리 + Commands 표(212-222)에 add-worker 행 | low |
| `PLAN.md` | 수정 | AC-32 추가. §2·§8.2 stale 표 갱신 | low |
| `docs/architecture.md` | 수정 | mid-session 워커 추가 섹션: session_name split, manifest append, roster 인지 한계 | medium |

> dedupe: 5개 분석이 모두 제안한 `_manifest.js`의 `updateManifest` 헬퍼, `state-root.js`의 `isTeamRunning` 헬퍼, `worker-bootstrap.js`의 spool-precreate 변경은 **순 코드 절감 없으면 생략**(위 over-engineering 거부 참조). `generateWorkerOverlay`는 `params` 플랫 객체 시그니처(`worker-bootstrap.js:65`) 그대로 재사용 — 변경 불필요.

## 4. 구현 순서 (fail-safe)

manifest append = 커밋 포인트. split **이전** 실패는 부작용 없음(검증만). split **이후** 실패는 새 pane만 kill.

1. **검증 (부작용 없음, 실패 시 즉시 throw)**
   - `--team`/`--name`/`--cwd`/`--agent-type` 필수 확인.
   - `loadManifest(opts.team, opts.stateRoot)` — 없으면 "team not running".
   - **liveness**: 기존 워커 중 하나의 pane을 `isWorkerAlive`로 확인(`manifest.workers[0].pane_id` 권장). 죽었으면 "team session not live".
   - **cap**: `manifest.workers.length + 1 <= 10` (config의 fresh-array cap이 아님).
   - **이름 검증**: `WORKER_NAME_PATTERN` (raw, parser와 동일) + `sanitizeName(newName)`이 기존 `manifest.workers`의 어떤 `sanitizeName(w.name)`과도 충돌 안 함. (참고: `WORKER_NAME_PATTERN`이 이미 underscore를 막으므로 live 충돌 벡터는 **50자 truncation**뿐 — 과도 문서화 불필요.)
   - **export된 `validateWorker`** 호출(cwd 존재/디렉토리 등).
   - **export된 `validateAgentCLIs`** 호출(agent bin이 PATH에).
   - *롤백*: 불필요 (아직 아무것도 안 만듦).

2. **새 워커 state dir + AGENTS.md**
   - `ensureWorkerStateDir(team, name, state_root)` (워커 dir + mailbox dir).
   - 새 워커 roster = `manifest.workers` + 새 워커로 구성, `generateWorkerOverlay({...params, teamRoster})` 호출 후 `workers/<name>/AGENTS.md` write. (기존 워커는 role 텍스트가 manifest에 없으므로 roster에서 빈 role로 표시됨 — 한계 문서화.)
   - *롤백*: idempotent(`recursive:true`), 실패 시 throw, pane 미생성이라 정리 불필요.

3. **pane split** — `addWorkerPane(manifest.session_name, anchorPaneId, {name, cwd}, {sessionMode})` 호출. paneId 캡처.
   - *롤백*: split 실패 시 throw. **이후 단계부터 모든 실패는 이 paneId만 kill.**

4. **CLI spawn** — `spawnWorkerInPane(manifest.session_name, paneId, startConfig)`. **startConfig는 full envVars 블록 필수**: `MY_TEAM_WORKER`, `MY_TEAM_STATE_ROOT`, `OMC_TEAM_WORKER`, `...(env||{})` (start.js:218-223 그대로). 빠지면 워커가 자기 정체성·state를 못 찾아 죽는다.
   - *롤백*: 실패 시 `kill-pane -t <paneId>`, throw.

5. **ready 대기** — `waitForPaneReady(paneId, {timeoutMs:30000})`.
   - *롤백*: timeout이면 **새 pane kill**(고아 상태 discard), throw. 사용자가 retry 가능.

6. **레이아웃/라벨 재assert** — `@worker_name` set-option + `applyTeamLayout(manifest.session_name)` (start.js:247-251 미러). border 라벨 보장.
   - *롤백*: 실패 무시(cosmetic).

7. **manifest reload + append (커밋 포인트)**
   - manifest를 **다시 읽음**(reload-ENOENT 가드). ENOENT면 "team shut down mid-operation" → 새 pane kill, throw.
   - `manifest.workers.push({ name, pane_id, cwd, agent_type, overlay_path })` — **5개 필드 모두**(overlay_path 누락 시 다운스트림 깨짐).
   - `atomicWriteJson(manifestPath, manifest)`.
   - *롤백*: write 실패 시 새 pane kill, throw.

8. **알림 (best-effort, 실패해도 성공 처리)**
   - 새 워커 pane에 startup notice(start.js:259 패턴).
   - **기존 각 워커 pane에 in-pane notice**: 새 peer를 이름+agent_type으로 명시 (예: `New peer available: <name> [<agent>] — message via send-message`). 200자 이내.
   - [사용자 결정 #1-2/3 선택 시] 기존 워커 AGENTS.md 재작성.
   - *롤백*: 없음(이미 커밋됨). 알림 실패는 warn만.

## 5. 테스트 계획

**신규**: `test/commands/add-worker.test.js`. `node:test` + `send-message.test.js`의 `setupTeam`/`cleanup` fixture 패턴(`send-message.test.js:27-48`)을 따른다:
- `mkdtempSync(join(tmpdir(),'my-team-test-'))` → state_root, `manifest.json`(기존 워커 배열 포함), `mailbox/` 생성.
- **`process.env.MY_TEAM_STATE_ROOT_BASE = base`** 설정(send-message가 default base로 manifest를 찾으므로 — fixture line 40과 동일).
- cleanup에서 env 삭제 + `rmSync(base, {recursive,force})`.

**tmux 모킹**: 테스트에 실제 tmux pane이 없으므로(`send-message.test.js:15` 참조), `addWorkerPane`/`spawnWorkerInPane`/`waitForPaneReady`/`sendToWorker`를 주입 가능하게 하거나, 검증-only/manifest-only 경로를 tmux 호출과 분리해 단위 테스트. (start.js에 커맨드 레벨 테스트가 없는 것과 일관되게, **검증·manifest·rollback 로직에 집중**하고 tmux side는 stub.)

**assert 케이스**:
1. `--team`/`--name`/`--cwd`/`--agent-type` 누락 시 각각 throw.
2. manifest 없음 → "not running" throw.
3. 이름 중복(raw) → reject.
4. sanitized 충돌(50자 truncation 케이스) → reject.
5. cap 초과(기존 10명) → reject.
6. `--cwd` 미존재 → reject (validateWorker 경유).
7. 성공: `manifest.workers`에 새 엔트리 + 5개 필드 모두, overlay_path 정확.
8. 새 워커 `workers/<name>/AGENTS.md` 작성됨, 새 roster에 모든 peer 포함.
9. [#1-1 선택 시] 기존 워커 AGENTS.md **변경 안 됨**(stale roster 유지) 확인.
10. spawn/ready 실패 시 새 pane kill 호출됨, manifest **미변경** 확인.

## 6. 문서/PLAN 갱신

### README.md
- **240-244행 분리** (현재: "There is intentionally no user→worker CLI command for mid-session messaging. To give a worker a new instruction, type into its tmux pane directly. The old `my-team msg` / `my-team add-task` commands were removed..."):
  → user→worker mid-session **메시징**은 여전히 미지원(사용자가 pane에 직접 입력)이지만, mid-session **워커 추가**(`add-worker`)는 별개의 지원 기능임을 명시. 두 개념을 분리 서술.
- **Commands 표(212-222)**: `add-worker` 행 추가 — `Add one worker to a running team mid-session (--team --name --agent-type --cwd)`.

### PLAN.md
- **AC-32 신규**(현재 최고 AC-31): "`my-team add-worker --team <n> --name <n> --agent-type <t> --cwd <c>`는 실행 중인 팀에 워커 pane 하나를 추가한다. 새 워커는 `manifest.workers`에 등록되어 send/recv 가능하고, 기존 워커는 in-pane notice로 새 peer를 통보받는다. 기존 워커의 AGENTS.md roster는 정적이라 [#1 결정에 따라] 갱신/미갱신된다."
- **§2 결정 표(46-49행) stale 수정**: "사용자 명령 6개(`start`, `status`, `msg`, `add-task`, `shutdown`, `api`)" → 현재 실제(`start`, `status`, `monitor`, `shutdown`, `api`) + `add-worker`. "api 서브명령 4개(`transition-task-status`...)"도 현재 4개(`send-message`, `mailbox-list`, `mailbox-mark-delivered`, `archive-lookup`)로 교정.
- **§8.2 CLI 표(432-470행) stale 수정**: `msg`/`add-task`/`api transition-task-status`/`api read-task`/`api create-task` 행 제거(이미 제거된 명령), `monitor`·`add-worker` 행 추가. (이 표는 Option-B cutover 이전 상태로 drift 되어 있음.)

### docs/architecture.md
- 신규 섹션: mid-session 워커 추가 메커니즘. (a) `manifest.session_name`에 `split-window`로 pane 추가(**`createTeamSession` 아님** — `detectTeamMultiplexerContext`가 호출자 TMUX를 읽어 고아 세션을 만들기 때문, `tmux-session.js:197-198`); (b) `manifest.workers` append가 전달의 단일 소스(`send-message.js:47,58,65`); (c) 기존 워커 LLM은 정적 AGENTS.md로 고정 — 디스크 재작성이 런타임 LLM을 갱신하지 못하므로 in-pane notice가 인지의 유일 채널; (d) `description`/`extra_prompt` 미저장으로 peer roster 재생성은 lossy.

## 7. 미해결 질문 (코딩 전 결정 필요)

1. **[핵심] 기존 워커 AGENTS.md 디스크 재작성 여부** — §2 [사용자 결정 #1]. 1(안 함, 권장) / 2(함, lossy) / 3(함+start.js 스키마에 role 저장). 인지는 어차피 in-pane notice가 담당하므로 재작성은 재시작 보험일 뿐.
2. **CLI 표면 범위** — §2 [사용자 결정 #2]. 최소(name/agent/cwd, 권장) vs 확장(+description/extra-prompt/launch-arg/env-var). #1과 연동(#1-1 선택 시 description은 새 워커 roster에만 의미).
3. **동시성 자세** — §2 [사용자 결정 #3]. 문서화+ENOENT 가드(권장) vs 락파일(레포 모델 위배, 비권장).
4. **in-pane notice 포맷** — 자유 텍스트(`New peer available: <name> [<agent>]`) vs 구조화 트리거. 권장: 자유 텍스트(LLM이 자연어로 읽음, 200자 제한).
5. **liveness 앵커** — 검증 시 `leader_pane`을 체크할지 `workers[0].pane_id`를 체크할지. split-pane 모드에선 leader가 사용자 pane이므로 항상 alive — 워커 pane 체크가 "팀이 정말 살아있나"를 더 정확히 잡음. 권장: 첫 워커 pane.

> 검증 완료(코딩 불필요로 확정): `createTeamSession` 재사용 금지, `--state-root`는 status/shutdown 미러(send-message의 default-base 한계는 pre-existing), spawn 시 full envVars 필수, AC 번호는 AC-32, manifest append가 커밋 포인트.