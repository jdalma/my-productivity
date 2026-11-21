# my-team — `add-worker`로 합류하는 워커에게 주입되는 프롬프트

> 본 문서는 `my-team add-worker`로 세션 도중 합류하는 워커(티켓 위임 워커, 교대 후임 워커)가 **어떤 프롬프트를, 어떤 순서로, 누구에게서** 받는지 정리한다. `start`로 뜨는 초기 워커의 부트스트랩은 [`worker-bootstrap.md`](worker-bootstrap.md), 통신 메커니즘은 [`architecture.md`](architecture.md).
>
> **대상 코드**: `src/commands/add-worker.js`, `src/lib/worker-bootstrap.js`, `src/lib/tmux-session.js`
>
> **작성 계기 (2026-09-15)**: 티켓 위임 워커가 스폰한 부모 워커에게 진행 상황을 매번 보고하는 현상. 원인은 프롬프트 누락이었고(§4), Rules에 Spawn protocol을 추가해 대응했다(§5).

---

## 1. 한눈에 보는 흐름

```
부모 워커(또는 사용자)가 add-worker 실행
   │
   ├─ ① AGENTS.md 파일 생성   ← 코드가 만드는 고정 규약 + 부모가 쓴 --extra-prompt
   ├─ ② CLI 부팅              ← 프롬프트 없음. env 변수만 세팅
   ├─ ③ 조인 통지 타이핑       ← "①을 읽고 오케스트레이터에게 1통 보고해라"
   └─ ④ 티켓 send-message     ← 부모 LLM이 자유 작성. mailbox로 도착
```

핵심: **워커의 "헌법"은 ① AGENTS.md 파일이고, 이 파일은 시스템 프롬프트로 주입되지 않는다.** ③ 통지가 절대 경로를 알려주면 워커가 파일을 한 번 읽는다. 워커 CLI는 자기 `cwd`에서 부팅되는데 AGENTS.md는 `<state_root>/workers/<name>/`에 있어 CLI가 자동 로드하지 않기 때문이다 (`add-worker.js` Step 8 주석).

## 2. 네 개의 주입 표면

| # | 표면 | 만드는 주체 | 코드 위치 | 워커가 읽는 시점 |
|---|---|---|---|---|
| ① | AGENTS.md 오버레이 | 코드 (`generateWorkerOverlay`) + `--extra-prompt` | `worker-bootstrap.js` `generateWorkerOverlay`, `add-worker.js` Step 2 | ③ 통지를 받은 직후 1회 |
| ② | CLI 부팅 | 코드 (`spawnWorkerInPane`) | `tmux-session.js` `spawnWorkerInPane`, `add-worker.js` Step 4 | 프롬프트 없음 |
| ③ | 조인 통지 | 코드 (고정 문구, role 유무로 분기) | `add-worker.js` Step 8 | 즉시 (pane에 타이핑) |
| ④ | 티켓 | 부모 워커 LLM | 부모의 `api send-message` 호출 | 다음 `mailbox-list` 폴링 |

### ② CLI 부팅에 붙는 env

```
MY_TEAM_WORKER=<team>/<name>
MY_TEAM_STATE_ROOT=<state_root>
OMC_TEAM_WORKER=<team>/<name>
```

`launch_args`는 명시한 `--launch-arg`가 있으면 그것, 없고 **부모 워커가 호출**했으면(`MY_TEAM_WORKER` env로 식별) 부모의 `launch_args`를 상속한다.

### ③ 조인 통지 문구 (2026-09-21 개정)

role을 선언한 팀:

```
You just joined team '<team>'. First action: read <AGENTS.md 절대경로>
for the roster + peer protocol. Then send ONE message (no expects_reply)
to <orchestrator 목록> stating your name, your cwd, and your assignment
in one line. Do not message any other worker.
```

role이 없는 peer 팀:

```
You just joined team '<team>'. First action: read <AGENTS.md 절대경로>
for the roster + peer protocol. Do not introduce yourself to peers —
they see you in the `roster` field of their next mailbox-list.
```

`start`의 초기 워커는 대신 "Team is live. Follow <경로> ...; wait for user input ..."을 받는다.

**왜 전원 인사를 없앴나.** 새 피어의 *존재*는 이미 `mailbox-list` 응답의 `roster`가 매 사이클 전달한다(`mailbox-list.js:19`). 인사는 그 위에 얹힌 중복 채널이면서 합류 1건당 2N통(인사 N + `expects_reply` 회신 N)을 발생시켰다. 대신 오케스트레이터 1명에게 보내는 보고 1통만 남겼다. 목적은 충돌 판정이 아니라 **사용자 알림**이다 — 오케스트레이터가 "누가 무슨 일로 합류했다"를 자기 pane stdout으로 전달한다.

## 3. ① AGENTS.md 오버레이 섹션과 렌더링 조건

| 섹션 | 내용 | 렌더링 조건 |
|---|---|---|
| Team Worker Protocol | "team <name>의 워커 중 하나. 사용자는 각 pane을 보며 직접 타이핑하고, 다른 워커는 mailbox로 닿는다" | 항상 |
| Identity | 팀명, 워커명, agent type, env | 항상 |
| Team Roster | 부팅 시점 팀원(이름·타입·한 줄 설명). "스냅샷이며 `mailbox-list`의 roster가 정본" | 항상 |
| Liveness | `status.json`(idle/working/blocked/done/failed) | 항상 |
| Team Role: ORCHESTRATOR / WORKER | 위임 규율, "블록 시 질문 1통·완료 시 보고 1통", cross-team 게이트 | **`workerRole`이 non-null일 때만** |
| Message Protocol | send-message / mailbox-list / mark-delivered 예시. 비동기 원칙, reply_to 해석 순서, 자기 폴링 의무는 작업판이 없으면 절마다, 작업판 팀은 `### Mailbox: questions and notices only` 한 절로 | 항상 |
| Rules | 파일 범위, tmux 직접 조작 금지, 중첩 팀 금지, **Parallel work(스폰 규약)**, 피어 제거, 교대 | 항상 |
| Agent-Type Guidance | claude/codex/gemini/cursor별 팁 | 항상 (타입별 분기) |
| Role Context | `--extra-prompt` 원문 | extra-prompt 있을 때만 |

### `workerRole` 결정 규칙 (`add-worker.js`)

```js
const teamUsesRoles = manifest.workers.some((w) => w.role === 'orchestrator' || w.role === 'worker');
const workerRole = validated.role ?? (teamUsesRoles ? 'worker' : null);
```

- 팀에 role 선언 워커가 하나라도 있으면 새 워커는 `worker`(또는 `--role` 명시값).
- 없으면 `null` → Team Role 섹션이 통째로 빠지고, Message Protocol에 "There is no orchestrator or leader role in this team, every worker (including you) is a peer"가 렌더링된다.
- SKILL.md 사용 예시 설정에는 `role`이 없으므로 **기본은 빠지는 쪽**이다.

## 4. 분석: "부모에게 완료 시 1회만 보고"가 어디에도 없었던 이유

### 규칙이 존재하는 유일한 곳은 role 게이트 뒤

- `roleGuidance('worker')`: "Message your orchestrator ONLY (a) blocked 시 expects_reply 1통, (b) 완료 시 reply_to 최종 보고 1통. No progress updates, no acknowledgements."
- `roleGuidance('orchestrator')`: "Expect from each worker at most a question when blocked and one final report when done."
- 커밋 4faba0e가 추가한 문장이 정확히 이 둘이고, 둘 다 §3의 조건에 따라 peer 팀에서는 렌더링되지 않는다.
- role 팀이더라도 WORKER 섹션의 "your orchestrator(s)"는 `teamRole === 'orchestrator'` 목록이다. `role: worker`인 부모가 스폰하면 부모는 그 목록에 없다. **부모–자식 관계는 프롬프트 어디에도 모델링돼 있지 않다.**

### 오히려 잦은 메시징을 유도하던 문구 (peer 모드에서 그대로 적용)

| 위치 | 문구 | 효과 |
|---|---|---|
| ③ 조인 인사 | "introduce yourself to every OTHER worker via send-message with expects_reply" | 부팅 직후 N통 발신, 각 피어가 규칙("expects_reply면 답한다")에 따라 N통 회신 |
| Rules · Parallel work (변경 전) | "hand it a ticket via send-message and **coordinate with it directly**" | 지속 왕복 권장 |
| Team Roster | "When a sub-problem ... matches a peer's role, send that peer a message instead of solving it yourself" | 자식에게 부모는 로스터의 한 피어. 이 규칙으로 부모에게 질문 발신 |
| (부재) 부모 쪽 티켓 작성 규칙 | orchestrator 섹션의 "ticket form ... 'reply when done'"은 role 게이트 뒤 | peer 부모는 `--extra-prompt`·티켓에 "진행 상황 알려줘"를 자유롭게 넣을 수 있고 자식은 따른다 |

중립: 자기 폴링 규칙은 `mailbox-list` 호출 빈도이지 발신 빈도가 아니다. Agent-Type Guidance(claude)의 "surface progress via your normal stdout"은 stdout 대상이다.

## 5. 대응 1 (2026-09-15): Rules · Parallel work에 Spawn protocol 추가

`worker-bootstrap.js` Rules의 "Parallel work on one repo" 항목을 다음과 같이 바꿨다. role 여부와 무관하게 모든 워커 오버레이에 렌더링된다.

- 명령 예시에 `--extra-prompt "<the brief below>"` 추가.
- "coordinate with it directly" 삭제.
- **Spawn protocol** 3줄 신설:
  1. `--extra-prompt`에 반드시 넣을 문장을 고정 텍스트로 제공. 스폰한 워커 이름이 치환된다: "Spawned by `<me>`. Message `<me>` ONLY (a) when you need a decision to proceed — one message with expects_reply — or (b) when the ticket is done — one final report (reply_to the ticket). No progress updates, no acknowledgements: progress goes to your status file and your pane's stdout."
  2. 티켓 = goal + inputs(file paths) + deliverable + "reply to this message when done". `expects_reply`로 보내 최종 보고가 부모의 `sent_pending`에 잡히게 한다.
  3. 부모는 진행 상황을 묻지 않는다. status 파일 또는 `my-team status`로 읽는다.

작업판 팀(config `board`)에서는 이 세 줄과 그 위의 "hand it a ticket via send-message"가 작업판용 문장으로 바뀐다.
새 워커의 일은 작업판의 작업으로 올리고(pm이 `board-add`나 `board-assign`으로, 워커는 pm에게 요청), 새 워커는
`board-take`로 시작해 `board-land`로 끝내며, 부모는 진행을 작업판에서 읽는다. `roleGuidance`의 위임·보고 줄도
같은 식으로 바뀐다(§4의 인용은 작업판 없는 팀의 문장이다).

렌더링 확인:

```bash
node -e "import('./src/lib/worker-bootstrap.js').then(m => {
  const out = m.generateWorkerOverlay({ teamName:'demo', workerName:'backend', agentType:'claude', bootstrapInstructions:'', instructionStateRoot:'/tmp/s', teamRoster:[] });
  const i = out.indexOf('**Parallel work on one repo**');
  console.log(out.slice(i, out.indexOf('**Retiring a peer', i)));
})"
```

### 남은 한계와 다음 단계 후보

자식 쪽 규칙은 **부모 LLM이 `--extra-prompt`에 지시문을 그대로 옮기는 데 의존**한다. 부모가 누락하면 자식은 이전과 같이 peer 규칙만 받는다. 재발하면 다음 중 하나로 올린다.

1. `add-worker`가 호출자를 `MY_TEAM_WORKER` env로 식별해 Role Context에 "Spawned by X ..." 문단을 **자동 삽입**. 부모 LLM에 의존하지 않아 확정적이지만, 오버레이 생성기에 parent 파라미터가 늘고 사용자가 직접 add-worker 한 경우와 구분이 필요하다.
2. 현재 WORKER role 규칙을 peer 모드에도 일반화("티켓을 준 피어에게는 blocked/done 시에만"). 검증된 문장을 재사용하지만 "no leader" 모델 정의와 충돌하는 표현이 생겨 문구 조정이 필요하다.

## 5-1. 대응 2 (2026-09-21): 인사 제거 + 파일 겹침 관리 포기

**증상**: 워커가 추가될 때마다 팀 전원에게 인사가 오가 점대점 메시지가 폭증.

**원인 2가지**:

1. ③ 조인 인사가 "every OTHER worker에게 `expects_reply`로 인사"를 고정 지시 → 합류 1건당 2N통.
2. 오버레이 안에서 규칙이 서로 반대 방향이었다. WORKER 섹션은 "충돌 가능하면 피어에게 직접 물어라", ORCHESTRATOR 섹션은 "워커 간 조율은 기본적으로 나를 경유". 워커는 전자를 따라 직접 움직였다.

**변경 내용**:

| 위치 | 변경 |
|---|---|
| `add-worker.js` Step 8 | 전원 인사 → orchestrator에게만 1통 보고(이름·cwd·담당 한 줄), `expects_reply` 없음. role 없는 팀은 인사 자체를 제거 |
| `remove-worker.js` | 남은 전원 통지 → **영향받는 워커만**. 판정 근거는 디스크 사실인 `sent_pending.to_worker`(`tmux-comm.js:290`) + orchestrator. 둘 다 없으면(레거시 peer 팀) 기존대로 전원 |
| `worker-bootstrap.js` WORKER | "피어에게 직접 물어라" 삭제 → "워크트리가 워킹 트리를 분리하므로 파일 조율 자체를 하지 않는다". 합류 시 자기소개 금지 명시 |
| `worker-bootstrap.js` ORCHESTRATOR | **Team changes** 규칙: 합류 보고 1통을 받아 사용자에게 stdout으로 알림(팀 브로드캐스트 금지). 파일 겹침은 관리하지 않는다고 명시 |
| `worker-bootstrap.js` Team Roster | WORKER에게는 "로스터에 보인다고 메시지 보낼 이유는 아니다"로 분기. peer 팀은 기존 문구 유지 |
| `worker-bootstrap.js` Spawn protocol | 워커가 자식을 스폰하면 orchestrator에게 1통 등록(누가 일하고 있는지 그림 유지). 파일 범위는 싣지 않음 |
| `worker-bootstrap.js` worktree 레시피 | "같은 레포를 공유하니 파일 건드리기 전에 서로 물어라" 삭제 → "워크트리가 각자의 워킹 트리를 주므로 물을 필요 없다" + 공유 cwd 거부 안내 |
| `add-worker.js` 검증 구간 | **공유 cwd 가드** 신설: 같은 cwd를 쓰는 기존 워커가 있으면 거부. `--allow-shared-cwd`가 탈출구 |
| `cli.js` | `--allow-shared-cwd` 플래그 추가 |

**왜 파일 겹침을 관리하지 않기로 했나**: 한 레포 병렬 작업은 `--worktree`로 각자의 워킹 트리에서 돈다. 물리적으로 분리돼 있어 같은 파일 동시 수정이 성립하지 않고, 나머지는 머지 시점에 git이 처리한다. 프롬프트로 겹침을 추적하는 것은 LLM의 자연어 대조에 기대는 일이라 신뢰도가 낮은데, 그 대가로 메시지와 규칙만 늘었다.

**"영향받는 워커"(이탈 통지)의 판정 근거**: 코드가 판정한다. 제거된 워커에게 답을 기다리던 워커는 자기 mailbox의 `sent_pending`에 `to_worker`가 그 이름으로 남아 있다. 추측이 아니라 디스크에 있는 사실이다.

**공유 cwd 가드 (같은 날 추가)**: 파일 겹침을 관리하지 않는 전제는 "워크트리로 워킹 트리가 분리된다"이다. 그 전제가 깨지는 유일한 경우가 같은 `--cwd` 공유이고, 이때는 브랜치도 같아 git이 충돌을 보고하지 않는다. 그래서 `add-worker`가 manifest에 같은 cwd를 쓰는 워커가 있으면 **부작용 이전에 거부**한다. 에러가 `--worktree <branch>`를 안내하며, 의도적 공유는 `--allow-shared-cwd`로만 뚫는다. 오버레이의 worktree 레시피에도 "이 에러를 만나면 `--worktree`를 붙여라, `--allow-shared-cwd`는 사용자 판단 영역"을 명시했다.

**메시지 수 (기존 워커 N명 기준)**:

| 사건 | 변경 전 | 변경 후 |
|---|---|---|
| 워커 합류 | 2N (인사 N + 회신 N) | 1 (orchestrator 보고) |
| 워커 제거 | N (in-pane 통지) | 대기 중인 워커 수 + orchestrator |
| 작업 중 충돌 협의 | 워커끼리 수시 질의 | 0 (워크트리 + git 머지) |

## 6. 누가 무엇을 통제하는가 (요약)

| 통제 주체 | 내용 |
|---|---|
| 코드가 고정 | ① 오버레이 전체(Role Context 제외), ③ 조인 통지, ② env |
| 부모 LLM이 작성 | ① Role Context(`--extra-prompt`), ④ 티켓, `--description` 한 줄 |
| 사용자 | pane 직접 타이핑 (tmux stdin) |

"부모에게 언제 보고할지"는 코드 고정 부분에 없었고, 지금은 코드 고정 부분(Rules)이 부모에게 "extra-prompt에 이 문장을 넣어라"고 지시하는 상태다.

## 7. 변경 시 체크리스트

- 오버레이 섹션 추가/제거 또는 렌더링 조건 변경 → §3 표
- `workerRole` 결정 로직 변경 → §3 코드 블록
- 조인 통지 문구 변경 → §2 (role 분기 두 벌 모두)
- 이탈 통지 대상 규칙 변경 → §5-1 (`remove-worker.js`의 `sent_pending` 조회)
- Spawn protocol 문구 변경 → §5 (렌더링 확인 명령으로 검증)
- 자동 삽입(§5 후보 1)으로 전환 시 → §4·§5·§6 전부 갱신
