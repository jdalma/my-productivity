# `my-team add-worker` 최종 실행 체크리스트 (EXECUTION CHECKLIST)

설계 출처: `/Users/me/IdeaProjects/my-productivity/tools/my-team/docs/add-worker-implementation-plan.md` (§0 사용자 결정 확정). 위→아래로 따라가면 재설계 없이 구현 완료되도록 작성. 경로는 `tools/my-team/` 기준.

---

## 1. 선행 확인 (drift 반영)

진짜 "drift"는 3건. 재검증 노트 `drift_found` 10여 항목 중 대부분(add-worker.js, addWorkerPane, 테스트, CLI 등록)은 **설계가 만들기로 한 미생성 산출물** = 구현 스코프이지 drift가 아니다. §2가 채운다.

### 진짜 drift 3건
1. **parser.js export가 2개 필요 (설계 §3 파일표는 1개만 명시).** §3 표(line 81)는 `validateWorker`만 적었으나 §4.1(line 102)이 `WORKER_NAME_PATTERN.test()`를 쓴다. `WORKER_NAME_PATTERN`은 `parser.js:17`에 있으나 **미export**. → §2-A에서 `validateWorker`(112)·`WORKER_NAME_PATTERN`(17) 둘 다 export.
2. **테스트 fixture가 3-field로 stale.** `send-message.test.js:36`은 `{name, pane_id, inbox_path}`. add-worker는 `manifest.workers[0].pane_id`를 liveness 앵커로 쓰고 5-field shape에 append. → 새 fixture는 패턴 복사하되 **5-field로** 작성(§4). send-message.test.js는 안 건드림.
3. **tmux 테스트 seam 미확정(OR) — DI로 확정.** §5(line 143)가 "주입 가능하게 하거나/분리"를 OR로 남김. §4.1 liveness 게이트(`isWorkerAlive(manifest.workers[0].pane_id)`)가 테스트 env(tmux 없음→false/throw)에서 **모든 테스트를 "team session not live"로 조기 종료**시켜 cap/name/cwd 케이스가 엉뚱한 에러로 실패. → `runAddWorker(opts, deps={})` **DI seam 채택**(§2-D). cli.js는 `runAddWorker(opts)`로 호출(기본값 적용→프로덕션 시그니처 오염 0). 설계 §5가 요구한 in-scope, 투기적 추상화 아님.

### export 5개는 drift 아님 — 설계 지시한 1줄 변경
`validateWorker`(parser.js:112), `AGENT_CLI`(start.js:36), `commandExists`(start.js:43), `validateAgentCLIs`(start.js:98) + 위 `WORKER_NAME_PATTERN` — `export` 키워드만 추가.

### commit 04aea9c — **confirmed-no-impact**
template-only(`worker-bootstrap.js` 6줄 Rules 텍스트 + `docs/worker-bootstrap.md` 미러). `generateWorkerOverlay`(65)·`ensureWorkerStateDir`(258) 시그니처 불변, 70 tests green. 새 워커 능력(sub-agents/동적 워크플로우)은 워커 자기 작업 한정, add-worker surface(topology/peer-channel 여전히 locked)와 무관. **반영할 변경 없음.**

---

## 2. 구현 순서 체크리스트 (의존성 순서)

### A. `src/config/parser.js` — export 2개
- [ ] `parser.js:17` → `export const WORKER_NAME_PATTERN = /^[a-zA-Z0-9-]+$/;`
- [ ] `parser.js:112` → `export function validateWorker(w, idx, seen)` (시그니처 불변; cwd 존재/디렉토리·agent_type whitelist·env·launch_args 검증 재사용)

### B. `src/commands/start.js` — export 3개
- [ ] `start.js:36` → `export const AGENT_CLI = {` (const, 함수 아님; `agent_type → {bin, hint}`)
- [ ] `start.js:43` → `export function commandExists(cmd)` (완전성 목적; 실호출은 `validateAgentCLIs` 내부에서만 — add-worker 직접 호출 안 함)
- [ ] `start.js:98` → `export function validateAgentCLIs(config)` (⚠️ `config.workers` 배열 순회 — add-worker는 `{workers:[newWorker]}`로 **감싸서** 호출. 맨몸 배열 `[{...}]`은 TypeError)

### C. `src/lib/tmux-session.js` — 신규 `addWorkerPane` (단일 워커)
- [ ] 신규 `export async function addWorkerPane(sessionName, anchorPaneId, worker, options = {})`. **`createTeamSession` 재사용 금지**(`detectTeamMultiplexerContext`가 호출자 `env.TMUX`를 읽어 고아 세션 생성, `tmux-session.js:197`).
  - [ ] `worker.cwd` 없으면 throw (`createTeamSession:285` 미러)
  - [ ] `const splitResult = await tmuxCmdAsync(['split-window','-h','-t',anchorPaneId,'-d','-P','-F','#{pane_id}','-c',worker.cwd]);` — **타깃은 anchorPaneId(pane), session 아님.** `283-292`를 **단일 워커로** 추출 — 루프 없음(재검증 노트의 `for` 루프 설명은 `createTeamSession`에서 잘못 복사된 것; 무시). `-h`/`-v` 무관(`applyTeamLayout` 재타일링)
  - [ ] `const paneId = splitResult.stdout.split('\n')[0]?.trim();` 없으면 throw
  - [ ] `await tmuxExecAsync(['set-option','-p','-t',paneId,'@worker_name',worker.name]).catch(()=>{})` (`298-300` 미러)
  - [ ] `await applyTeamLayout(sessionName);`
  - [ ] `return { paneId };`

### D. `src/commands/add-worker.js` — 신규 `runAddWorker` (§4 fail-safe)

- [ ] imports:
  ```js
  import { join } from 'path';
  import { writeFile } from 'fs/promises';
  import { loadManifest, manifestPathForTeam } from './_manifest.js';
  import { WORKER_NAME_PATTERN, validateWorker } from '../config/parser.js';
  import { AGENT_CLI, validateAgentCLIs } from './start.js';
  import { sanitizeName } from '../lib/team-name.js';
  import { ensureWorkerStateDir, generateWorkerOverlay } from '../lib/worker-bootstrap.js';
  import { atomicWriteJson } from '../lib/fs-utils.js';
  import {
    isWorkerAlive, addWorkerPane, applyTeamLayout, sendToWorker,
    spawnWorkerInPane, waitForPaneReady, tmuxExecAsync,
  } from '../lib/tmux-session.js';
  ```
- [ ] **DI seam 시그니처** (테스트 주입용; cli.js는 기본값 호출):
  ```js
  export async function runAddWorker(opts, deps = {}) {
    const {
      isWorkerAlive: _isWorkerAlive = isWorkerAlive,
      addWorkerPane: _addWorkerPane = addWorkerPane,
      spawnWorkerInPane: _spawnWorkerInPane = spawnWorkerInPane,
      waitForPaneReady: _waitForPaneReady = waitForPaneReady,
      sendToWorker: _sendToWorker = sendToWorker,
      killPane: _killPane = (id) => tmuxExecAsync(['kill-pane', '-t', id]),
    } = deps;
  ```

**Step 1 — 검증 게이트 (부작용 0, 실패 즉시 throw, 롤백 불필요):**
- [ ] 필수 플래그: `!opts.team / !opts.name / !opts.cwd / !opts.agentType` 각각 throw (`required`/필드명 포함)
- [ ] **camelCase→snake_case 매핑** (Commander: `--agent-type`→`opts.agentType`, `--state-root`→`opts.stateRoot`; 검증기는 `w.agent_type` 읽음):
  ```js
  const newWorker = { name: opts.name, cwd: opts.cwd, agent_type: opts.agentType };
  ```
  (⚠️ `opts.agent_type`은 `undefined` — silently 통과 후 spawn에서 죽음)
- [ ] `const manifest = loadManifest(opts.team, opts.stateRoot);` — 없으면 `_manifest.js:19` "Is the team running?" throw
- [ ] **liveness**: `if (!(await _isWorkerAlive(manifest.workers[0].pane_id))) throw new Error('team session not live')` (첫 워커 pane, §0 #5)
- [ ] **cap**: `if (manifest.workers.length + 1 > 10) throw` ("10" 포함)
- [ ] **raw 이름**: `if (!WORKER_NAME_PATTERN.test(opts.name)) throw`
- [ ] **중복(raw)**: `if (manifest.workers.some(w => w.name === opts.name)) throw new Error('duplicate worker name')`
- [ ] **sanitized 충돌(50자)**: `const sn = sanitizeName(opts.name); if (manifest.workers.some(w => sanitizeName(w.name) === sn)) throw new Error('sanitized name collision')`
- [ ] **필드 검증**: `validateWorker(newWorker, manifest.workers.length, new Set(manifest.workers.map(w => w.name)))`
- [ ] **CLI PATH**: `validateAgentCLIs({ workers: [newWorker] })` (⚠️ **객체로 감싸기**)

**Step 2 — state dir + 새 워커 AGENTS.md (idempotent, pane 미생성):**
- [ ] `const stateRoot = manifest.state_root;`
- [ ] `await ensureWorkerStateDir(opts.team, opts.name, stateRoot);`
- [ ] `const teamRoster = [...manifest.workers.map(w => ({ name: w.name, agentType: w.agent_type, role: '' })), { name: opts.name, agentType: opts.agentType, role: '' }];` (기존 role은 manifest에 없어 빈 문자열 — §0 #1 한계, 정상)
- [ ] `const overlay = generateWorkerOverlay({ teamName: opts.team, workerName: opts.name, agentType: opts.agentType, bootstrapInstructions: '', instructionStateRoot: stateRoot, cwd: opts.cwd, teamRoster });`
- [ ] `const overlayPath = join(stateRoot, 'workers', opts.name, 'AGENTS.md'); await writeFile(overlayPath, overlay, 'utf-8');`

**Step 3 — pane split (이후 모든 실패는 새 paneId만 kill):**
- [ ] `const { paneId } = await _addWorkerPane(manifest.session_name, manifest.workers[0].pane_id, { name: opts.name, cwd: opts.cwd });`
  - *롤백*: split 실패 시 paneId 없음 → throw

**Step 4 — CLI spawn (full envVars 필수, start.js:214-223 그대로):**
- [ ] `try {` 시작 (step 4~7 감싸기)
  ```js
  const startConfig = {
    teamName: opts.team,
    launchBinary: AGENT_CLI[opts.agentType].bin,
    launchArgs: [],
    envVars: {
      MY_TEAM_WORKER: `${opts.team}/${opts.name}`,
      MY_TEAM_STATE_ROOT: stateRoot,
      OMC_TEAM_WORKER: `${opts.team}/${opts.name}`,
    },
  };
  await _spawnWorkerInPane(manifest.session_name, paneId, startConfig);
  ```
  - *롤백*: catch → `await _killPane(paneId); throw e;`

**Step 5 — ready 대기:**
- [ ] `await _waitForPaneReady(paneId, { timeoutMs: 30000 });` — timeout/실패 → catch에서 kill + throw

**Step 6 — 레이아웃/라벨 재assert (cosmetic, 실패 무시):**
- [ ] `await tmuxExecAsync(['set-option','-p','-t',paneId,'@worker_name',opts.name]).catch(()=>{});`
- [ ] `await applyTeamLayout(manifest.session_name).catch(()=>{});`

**Step 7 — manifest reload + append (커밋 포인트):**
- [ ] reload: `const fresh = loadManifest(opts.team, opts.stateRoot);` — ENOENT/throw면 catch에서 `await _killPane(paneId); throw new Error('team shut down mid-operation');`
- [ ] `fresh.workers.push({ name: opts.name, pane_id: paneId, cwd: opts.cwd, agent_type: opts.agentType, overlay_path: overlayPath });` (**정확히 5개 필드, 이 순서**)
- [ ] `atomicWriteJson(manifestPathForTeam(opts.team, opts.stateRoot), fresh);` (write 실패 → catch에서 kill + throw)
- [ ] `try` 닫고 `catch (e) { await _killPane(paneId).catch(()=>{}); throw e; }`

**Step 8 — 알림 (best-effort, 실패해도 성공, 롤백 없음):**
- [ ] 새 워커 pane startup notice (start.js:259 패턴): `_sendToWorker(manifest.session_name, paneId, \`Team is live. Follow ${stateRoot}/workers/${opts.name}/AGENTS.md for the peer protocol; wait for user input or peer messages.\`)` — try/catch warn
- [ ] 기존 각 워커 pane: `for (const w of manifest.workers) { _sendToWorker(manifest.session_name, w.pane_id, \`New peer available: ${opts.name} [${opts.agentType}] — message via send-message\`).catch(()=>{}); }` (200자 이내)
- [ ] `return { name: opts.name, pane_id: paneId, overlay_path: overlayPath };`

### E. `src/cli.js` — 커맨드 등록
- [ ] import 블록(line 20 부근, `runMonitor` 다음)에 `import { runAddWorker } from './commands/add-worker.js';`
- [ ] monitor 블록(끝 line 111)과 `api` 블록(line 113) 사이 삽입:
  ```js
  program
    .command('add-worker')
    .description('Add one worker to a running team mid-session')
    .requiredOption('--team <name>', 'team name')
    .requiredOption('--name <name>', 'worker name')
    .requiredOption('--agent-type <type>', 'agent type (claude|codex|gemini|cursor)')
    .requiredOption('--cwd <path>', 'worker working directory')
    .option('--state-root <path>', 'override state root')
    .action(async (opts) => { await runAddWorker(opts); });
  ```
- [ ] cli.js 상단 docstring(line 4-5) user-facing 목록에 `add-worker` 추가

### F. 테스트 → §4   |   G. 문서 → §5

---

## 3. 검증 게이트 (RED→GREEN 명시)

- [ ] **A 후**: `node -e "import('./src/config/parser.js').then(m => console.log(typeof m.validateWorker, m.WORKER_NAME_PATTERN.source))"` → `function ^[a-zA-Z0-9-]+$`
- [ ] **B 후**: `node -e "import('./src/commands/start.js').then(m => console.log(typeof m.AGENT_CLI, typeof m.validateAgentCLIs, typeof m.commandExists))"` → `object function function`
- [ ] **C 후**: `node -e "import('./src/lib/tmux-session.js').then(m => console.log(typeof m.addWorkerPane))"` → `function`
- [ ] **회귀**: 여기서 `npm test` 1회 — export 추가가 기존 70 tests 안 깨짐(여전히 70 green)
- [ ] **RED 먼저**: §4 테스트 파일을 **add-worker.js 구현 전에** 작성 → `node --test test/commands/add-worker.test.js`로 import 실패/throw RED 확인
- [ ] **GREEN**: D(add-worker.js) 구현 후 `node --test test/commands/add-worker.test.js` → 케이스 전부 pass
- [ ] **E 후**: `node src/cli.js add-worker --help` → 4개 requiredOption + `--state-root` 출력
- [ ] **최종**: `npm test` 전체(70 → ~80 green) + overlay smoke(§6)

---

## 4. 테스트 체크리스트 (`test/commands/add-worker.test.js`)

**fixture (send-message.test.js:27-48 패턴, 단 5-field):**
- [ ] imports: `node:test`, `node:assert/strict`, `fs`(mkdtempSync/mkdirSync/writeFileSync/readFileSync/existsSync/rmSync), `os`(tmpdir), `path`(join), `runAddWorker`
- [ ] `setupTeam({ teamName='t1', workers=['alice','bob'] })`:
  - [ ] `const base = mkdtempSync(join(tmpdir(),'my-team-test-'));`
  - [ ] `const stateRoot = join(base, teamName); mkdirSync(stateRoot,{recursive:true}); mkdirSync(join(stateRoot,'mailbox'),{recursive:true});`
  - [ ] manifest **5-field**: `workers.map(name => ({ name, pane_id:'%0', cwd:'/tmp', agent_type:'claude', overlay_path:'' }))` + `{ team_name, state_root:stateRoot, session_name:'test-session', workers, leader_pane:'%0' }`
  - [ ] `writeFileSync(join(stateRoot,'manifest.json'), JSON.stringify(manifest));`
  - [ ] `process.env.MY_TEAM_STATE_ROOT_BASE = base;`
- [ ] `cleanup(ctx)`: `delete process.env.MY_TEAM_STATE_ROOT_BASE; delete process.env.MY_TEAM_STATE_ROOT; rmSync(ctx.base,{recursive:true,force:true});`
- [ ] **stub 정책**: tmux 함수만 `deps`로 주입 — `isWorkerAlive: async()=>true`, `addWorkerPane: async()=>({paneId:'%9'})`, `spawnWorkerInPane: async()=>{}`, `waitForPaneReady: async()=>{}`, `sendToWorker: async()=>true`, `killPane: spy`. `ensureWorkerStateDir`/`generateWorkerOverlay`/`writeFile`/`atomicWriteJson`/`loadManifest`는 **실제로** mkdtemp dir에 실행하고 **디스크로 assert**.

**케이스 (설계 §5:145-155, 10건):**
- [ ] 1. `runAddWorker({})` → throw `/team|required/`
- [ ] 2. `{team:'t1'}` → throw `/name|required/`
- [ ] 3. `{team:'t1',name:'c'}` → throw `/cwd|required/` *(isWorkerAlive 주입 true 필요)*
- [ ] 4. `{team:'t1',name:'c',cwd:'/tmp'}` → throw `/agent|required/`
- [ ] 5. manifest.json 미생성 → `loadManifest` throw `/running/`
- [ ] 6. 이름 중복(raw, `name:'alice'`) → throw `/duplicate|alice/`
- [ ] 7. sanitized 충돌(50자 초과 prefix 동일) → throw `/collision|sanitiz/`
- [ ] 8. cap 초과(`workers` 10명 + 1) → throw `/10|cap|exceed/`
- [ ] 9. `--cwd '/nonexistent/path'` → `validateWorker` throw `/exist|director/`
- [ ] 10. **성공**: `setupTeam({workers:['alice']})` + 유효 opts → 디스크 manifest.json 재read해 `workers`에 5-field 엔트리(`{name, pane_id:'%9', cwd, agent_type, overlay_path}` 모두 present)

**추가 assert (설계 §5 8-10 + 디스크 기반):**
- [ ] 11. overlay 파일: `existsSync(join(stateRoot,'workers',opts.name,'AGENTS.md'))` true이고 내용에 새 peer 이름 포함
- [ ] 12. 기존 워커 manifest 엔트리 불변(alice 그대로)
- [ ] 13. **기존 AGENTS.md 불변**(§0 #1): fixture에서 `workers/alice/AGENTS.md`를 마커 텍스트로 **먼저 생성**, add-worker 후 내용 **변경 안 됨** assert
- [ ] 14. **rollback**: `spawnWorkerInPane: async()=>{throw new Error('boom')}` + `killPane` spy 주입 → reject, spy가 `'%9'`로 호출, 디스크 manifest.json `workers` **미변경**(append 안 됨) assert

---

## 5. 문서 갱신 체크리스트 (설계 §6)

### `README.md`
- [ ] **240-244행 분리**: "no user→worker CLI command for mid-session messaging"를 **메시징**(여전히 미지원, pane 직접 입력)과 **워커 추가**(`add-worker` 지원)로 분리 서술
- [ ] **Commands 표(212-222)**에 행 추가: `add-worker` — `Add one worker to a running team mid-session (--team --name --agent-type --cwd)`

### `PLAN.md`
- [ ] **AC-32 신규**(현 최고 AC-31): "`my-team add-worker --team --name --agent-type --cwd`는 실행 중 팀에 워커 pane 하나를 추가한다. 새 워커는 `manifest.workers`에 등록되어 send/recv 가능, 기존 워커는 in-pane notice로 새 peer를 통보받는다. 기존 워커 AGENTS.md는 정적이라 갱신하지 않는다(§0 #1)."
- [ ] **§2 결정 표 stale 수정**: 사용자 명령을 현재 실제(`start`,`status`,`monitor`,`shutdown`,`api`) + `add-worker`로 교정. api 서브명령은 4개(`send-message`,`mailbox-list`,`mailbox-mark-delivered`,`archive-lookup`)로 교정
- [ ] **§8.2 CLI 표 stale 수정**: 제거된 `msg`/`add-task`/`api transition-task-status`/`api read-task`/`api create-task` 행 제거, `monitor`·`add-worker` 행 추가

### `docs/architecture.md`
- [ ] 신규 섹션 "mid-session 워커 추가": (a) `manifest.session_name`에 `split-window`로 pane 추가(**`createTeamSession` 아님** — `detectTeamMultiplexerContext`가 호출자 TMUX 읽어 고아 세션 생성, `tmux-session.js:197`); (b) `manifest.workers` append가 전달의 단일 소스(`send-message.js:47,58,65`); (c) 떠 있는 워커 LLM은 정적 AGENTS.md로 고정 — 디스크 재작성이 런타임 LLM을 갱신 못 하므로 in-pane notice가 인지의 유일 채널; (d) `description`/`extra_prompt` 미저장으로 roster 재생성은 lossy

---

## 6. 완료 정의 (Definition of Done)

- [ ] §2~§5의 모든 `- [ ]` 박스 체크 완료
- [ ] `npm test` 전체 green — **70 → ~80**(add-worker 10 케이스). export 추가가 기존 70개를 깨지 않음
- [ ] **overlay smoke**: `node -e "import('./src/lib/worker-bootstrap.js').then(m => console.log(m.generateWorkerOverlay({teamName:'t', workerName:'b', agentType:'claude', bootstrapInstructions:'', instructionStateRoot:'/tmp/x', cwd:'/tmp', teamRoster:[{name:'a',agentType:'claude',role:''},{name:'b',agentType:'claude',role:''}]})))"` → 출력 roster에 `a`,`b` 모두 렌더
- [ ] **수동 dry-run** (실제 tmux에서 워커 추가 + peer 메시징 증명):
  1. `my-team start --name demo --worker a:claude:/tmp` — 워커 `a` 1명으로 기동
  2. `my-team add-worker --team demo --name b --agent-type claude --cwd /tmp` — 워커 `b` 추가(새 pane split + b CLI 기동)
  3. `my-team status --team demo` — `manifest.workers`에 `a`,`b` **둘 다** 표시(= append 증명)
  4. **peer 전달 증명**(§1 단일 정답 게이트): a pane에서 b에게 메시지 → b의 `my-team api mailbox-list --input '{"team_name":"demo","worker":"b"}' --json`에 도착 확인(= manifest append만으로 새 워커 send/recv 입증). ⚠️ input key는 `worker`이지 `worker_name`이 아님(`mailbox-list.js:9,33`)
  5. 기대: a pane에 `New peer available: b [claude]` notice가 떴고, b의 AGENTS.md roster에 `a` 포함

---

**구현 산출물 경로**: 수정 — `src/config/parser.js`(17,112), `src/commands/start.js`(36,43,98), `src/lib/tmux-session.js`(addWorkerPane 신규), `src/cli.js`(import+command). 신규 — `src/commands/add-worker.js`, `test/commands/add-worker.test.js`. 문서 — `README.md`, `PLAN.md`, `docs/architecture.md`.