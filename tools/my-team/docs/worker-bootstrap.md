# my-team — 워커 부트스트랩 프롬프트 / 강제 지시

> 본 문서는 `my-team start`가 각 워커 CLI(claude/codex/gemini/cursor)에게 어떤 "최초 프롬프트와 강제 지시"를 주입하는지 정리한다. 사용자 가이드는 `README.md`, 통신 메커니즘은 [`architecture.md`](architecture.md), 초기 설계 의도는 `PLAN.md`.
>
> **현재 모델 (옵션 B 컷오버 이후)** — 워커는 부팅 시 단 하나의 instruction surface만 받는다: **`AGENTS.md` 오버레이**. 그 외에 옛 시점의 `inbox.md` 첫 작업 지시서, mandatory task lifecycle workflow, `check-inbox` 트리거는 모두 제거됐다.
>
> **대상 코드**: `src/lib/worker-bootstrap.js`, `src/lib/prompt-helpers.js`, `src/commands/start.js`
>
> **세션 도중 합류하는 워커**(`add-worker`)의 주입 프롬프트와 role 게이트·보고 빈도 분석은 [`add-worker-prompts.md`](add-worker-prompts.md).
>
> **관련 다이어그램**: peer 메시지 흐름의 현행 시각 자료는 [`worker-message-flow.html`](worker-message-flow.html)(브라우저로 열기). 옵션 B 이전(inbox.md 시대)의 excalidraw 다이어그램은 삭제됐다.

---

## 1. 한눈에 보는 부팅 흐름

```
my-team start --config my-team.json
        │
        ▼
[1] config 검증 (workers[].task 필드 발견 시 hard-reject)
        │
        ▼
[2] tmux 세션 + 워커당 pane 생성 (per-worker cwd)
        │
        ▼
[3] 워커마다:
      a. 상태 디렉터리 ensure
      b. AGENTS.md 오버레이 생성 → workers/<name>/AGENTS.md
      c. 워커 CLI를 그 pane에서 spawn (--dangerously-* flags 포함)
      d. pane title을 워커 이름으로 박음 (@worker_name + select-pane -T)
        │
        ▼
[4] 모든 pane이 ready (CLI prompt 등장) 대기
        │
        ▼
[5] 각 pane에 시작 안내 한 줄 전송:
    "Team is live. Follow <AGENTS.md path> for the peer protocol;
     wait for user input in this pane or peer messages in your mailbox."
        │
        ▼
[6] manifest.json persist + detached 모드면 host pane에 monitor 자동 실행
```

부팅 후 워커는 **idle 상태**로 대기한다. 사용자가 그 pane에 입력하거나 peer가 `api send-message`로 메시지를 보낼 때까지 자발적으로 일하지 않는다.

## 2. `AGENTS.md` 오버레이 (`generateWorkerOverlay`)

워커별 `workers/<name>/AGENTS.md` 파일로 작성된다. 이 파일은 `state_root` 아래에 있고 워커의 `cwd`가 아니므로 CLI가 자동 로드하지 않는다 — §6의 시작 안내가 절대 경로를 알려주면 워커가 한 번 읽는다.

### 골격 구성 요소

| 섹션 | 내용 |
|------|------|
| `# Team Worker Protocol` (헤더) | "팀 <name>의 워커 중 하나"라는 한 줄 + user는 pane으로, peer는 mailbox로 본다 |
| `## Identity` | team_name, worker name, agent_type, `OMC_TEAM_WORKER` env |
| `## Team Roster` | 모든 워커 한 줄씩: `- **name** [agent_type] — role`. role은 config의 `description` (없으면 `extra_prompt` 첫 줄). 부팅 스냅샷이며, 최신 로스터는 `mailbox-list` 응답의 `roster`가 권위 있다고 명시. WORKER role은 "로스터에 보인다고 메시지 보낼 이유는 아니다"(orchestrator 경유)로, peer 팀은 "범위 밖이면 그 피어에게 직접 보내라"로 분기 |
| `## Liveness` | `status.json` 갱신 안내 (`my-team status`가 읽는다) |
| `## Message Protocol` | user와는 pane stdout과 CLI 확인 프롬프트로 말한다. peer 채널을 api send-message 하나로 제한하는 금지(`tmux send-keys`, `my-team msg`)는 `## Rules`에 있다 |
| `## Message Protocol > Talk to other workers via CLI API` | 6개 명령 한 줄씩 (send-message 1-way / send-message expects_reply / 답장 / mailbox-list / mark-delivered / archive-lookup) |
| `### Messaging a worker in ANOTHER team (cross-team)` | 다른 팀 워커에게 보내는 방법. orchestrator와 역할 없는 peer 팀에만 있고, WORKER에는 없다 |
| `### All worker-to-worker messaging is ASYNCHRONOUS` | 절대 블로킹하지 말라는 원칙 — **작업판이 없는 팀만** |
| `### Message correlation` | message_id / reply_to / sent_pending 메커니즘 설명 — 작업판이 없는 팀만 |
| `### MANDATORY — Mailbox self-poll discipline` | 사이클 끝마다 + new-message 트리거 받을 때 mailbox-list, 처리 후 mark-delivered — 작업판이 없는 팀만 |
| `### Handling a received message — reply_to resolution order` | sent_pending hit → archive-lookup 순서 — 작업판이 없는 팀만 |
| `### Asking several peers` | broadcast는 없다. 여럿에게 물으려면 각자에게 `expects_reply`로 보낸다 — 작업판이 없는 팀만 |
| `### Mailbox: questions and notices only` | 위 네 절(비동기, correlation, self-poll, reply_to 해석)과 여럿에게 묻기를 불릿으로 압축한 절. archive-lookup의 direction 해석, 못 찾은 reply_to는 pane에 남기기, `expects_reply: false`에는 답장하지 않기를 포함한다 — **작업판 팀만** |
| `## Team Role: ORCHESTRATOR` | 위임 규율 + cross-team 게이트웨이 + **Team changes**(합류 보고 1통을 받아 사용자에게 stdout으로 알림, 파일 겹침은 관리하지 않음) — `workerRole`이 non-null일 때만 |
| `## Team Board` | 작업판 사용법. config `board`가 있는 팀에만 |
| `## Team Role: WORKER` | 오케스트레이터에게만 blocked/done 보고, 파일 조율 없음(워크트리가 워킹 트리를 분리하므로 피어에게 편집 중인 파일을 묻지 않음), 합류 시 자기소개 금지 — `workerRole`이 non-null일 때만 |
| `## Rules` | 파일 범위, 팀 접근 제한, 병렬 작업(add-worker), 피어 제거, 교대, closeout, blocked 보고 (아래) |
| Agent-type guidance | claude/codex/gemini/cursor 별 추가 룰 |
| `## Role Context` | config의 `extra_prompt`가 그대로 들어감 (없으면 생략) |

작업판 팀(config `board`)에서는 일을 작업판으로 주고받는다. 그래서 Team Role의 위임·보고 줄과 Rules의
add-worker Spawn protocol이 메시지 대신 작업판을 가리키는 문장으로 바뀐다: 티켓은 작업 하나로 올리고, 완료는
`board-land`로 기록하고, 진행은 `board-progress`로 남긴다. 메시지는 결정이나 논의가 필요할 때와, 지침이 pm에게 알리거나 요청하라고 한 때에 보낸다. Rules의 Closeout과 Succession도 작업판을
거친다: closeout은 `board-land` 뒤에 하고, 교대할 때는 남은 작업을 pm이 후임에게 `board-assign`한다.

### 규칙 (`## Rules`)

`## Rules`의 불릿은 다음과 같다 (정확한 문구는 `generateWorkerOverlay`의 렌더로 확인한다).

- `## Role Context` 브리프 밖의 파일을 고치지 않는다.
- *팀*은 `my-team api ... --json`, `add-worker`, `remove-worker`로만 건드린다. tmux pane·session을 만들지 않는다. shim이 덮지 않는 tmux(절대 경로)로도 만들지 않는다.
  다른 워커의 pane에 타이핑하지 않는다
  (mailbox가 유일한 peer 채널이며 PATH의 tmux shim이 `send-keys`와 pane·session 생성을 거부한다. `my-team msg`는 없다).
  중첩 팀(`my-team start` 등)을 띄우지 않는다.
- 자기 CLI의 sub-agent와 workflow는 써도 된다. 같은 세션 안에서 돌고 팀원이 아니다.
- **Parallel work on one repo**: 독립적으로 나뉘는 일은 `add-worker --worktree <branch>`로 별도 worktree의 peer에게 맡긴다.
  `--allow-shared-cwd`는 사용자가 정할 일이다. 스폰 규약(`--extra-prompt`에 반드시 넣을 문구, orchestrator에게 1통 보고, ticket 구성)이 따른다.
  작업판 팀에서는 일을 메시지 대신 pm이 작업판 task로 올려 그 peer에게 배정한다.
- **Retiring a peer you spawned**: 일이 끝나고 머지된 peer는 `remove-worker`로 내보낸다. 작업 중인 peer나 자기 자신은 제거하지 않는다.
- **Succession**: 사용자가 교대를 지시하면 `my-team` 스킬의 Worker succession 절차를 따른다.
- **Closeout**: 사용자가 마무리를 지시하면 `my-team-closeout` 스킬로 증거 기반 최종 보고를 보낸다. 작업판 팀은 `board-land`와 verdict를 먼저 거친다.
- 막히면 status 파일에 `{"state": "blocked", "reason": "..."}`를 쓰고 pane stdout에 알린다.

`tmux send-keys` 금지와 `my-team msg` 금지는 실제 사고 대응이다. 워커 LLM이 두 우회 경로를 모두 쓴 사례가 있었다.

### 에이전트 타입별 가이드 (요약)

| agent_type | 추가 룰 |
|------------|---------|
| **claude** | "Role Context의 작업 브리프에 집중. 위험 명령 전 native permission prompt로 사용자 확인" |
| **codex** | "짧고 명시적인 `api ... --json` 호출 + 실패 시 stderr 그대로 사용자에게 surface" |
| **gemini** | "작은 verifiable 증분 + commit-sized scope" |
| **cursor** | "REPL이라 /exit 절대 하지 말 것" |

옵션 B 이전 가이드에 있던 "exit 전 transition-task-status 호출" 의무는 제거됐다 (task lifecycle 자체가 없음).

## 3. `extra_prompt` — 워커의 첫 작업 브리프

옵션 B에서 `workers[].task.{subject,description}` 필드는 제거되고 모든 부팅 시 작업 지시가 **`workers[].extra_prompt`** 로 일원화됐다.

```jsonc
{
  "name": "alpha",
  "agent_type": "claude",
  "description": "Backend API owner — peers see this one-liner",
  "extra_prompt": "Project A is the backend. First job: POST /orders with validation rules in §3 of the spec. Owner: alpha."
}
```

- `description` (옵션) — 한 줄. peer의 AGENTS.md `## Team Roster`에 노출. 없으면 `extra_prompt` 첫 줄로 fallback.
- `extra_prompt` (옵션) — 자유 길이. 본인 AGENTS.md의 `## Role Context` 섹션에 그대로 들어감. 첫 작업 지시 + 도메인 컨텍스트 + 제약 등 무엇이든.

`extra_prompt_file`로 외부 파일에서 읽을 수도 있다 (parser는 둘 다 있으면 inline `extra_prompt`를 쓰고 경고).

## 4. 환경 변수 주입 (`start.js`)

워커 CLI는 다음 env로 spawn된다:

| 변수 | 값 | 용도 |
|------|-----|------|
| `MY_TEAM_WORKER` | `<team>/<name>` | 자기 정체성 |
| `MY_TEAM_STATE_ROOT` | 절대 경로 | 상태 디렉토리 위치 (state-paths.js가 사용) |
| `OMC_TEAM_WORKER` | `<team>/<name>` | OMC 호환 (워커 LLM이 자기가 my-team 워커임을 안다) |
| `...config.workers[].env` | 사용자 지정 | 워커별 추가 env (DB URL, API token 등) |

## 5. Pane title 고정 (`start.js` + `tmux-session.js`)

워커 CLI는 OSC title sequence를 계속 emit하므로 일반 `select-pane -T`로 박은 라벨이 곧 덮어쓰여진다. 그래서 pane-scoped user option `@worker_name`을 별도로 박고, pane-border-format이 이걸 우선 표시하도록 설정한다 (`tmux-session.js`의 `createTeamSession`). pane title은 cosmetic fallback.

→ 사용자가 그리드에서 보는 라벨이 항상 `config.workers[].name`이다.

## 6. 부팅 시 시작 안내 (`start.js`)

각 워커 pane이 ready 상태에 들어간 후, start.js는 짧은 안내 한 줄을 send-keys로 보낸다:

```
Team is live. Follow <state_root>/workers/<name>/AGENTS.md for the peer protocol;
wait for user input in this pane or peer messages in your mailbox.
```

이걸 받은 워커 LLM은 경로의 AGENTS.md를 읽고 idle 진입한다. 이 안내가 워커가 오버레이 경로를 아는 유일한 통로다.

옵션 B 이전에는 `generateTriggerMessage`가 `Read <inbox.md path>, execute now, report concrete progress.`를 보냈지만, inbox.md 폐기 후 그 헬퍼도 함께 제거됐다.

### 압축 뒤 다시 넣기 (claude 워커만, `lib/protocol-reload.js`)

AGENTS.md는 system prompt가 아니라 대화 중에 읽은 파일이라, 대화가 압축되면 요약에 남은 만큼만 유지된다.
claude 워커는 `--settings <state_root>/workers/<name>/guard-settings.json`으로 SessionStart 훅(matcher
`compact`)을 받는다. 압축 직후 이 훅이 AGENTS.md를 다시 출력하고, Claude Code가 그 출력을 컨텍스트에 넣는다.

- Claude Code는 훅 하나의 출력이 10,000자를 넘으면 파일로 빼고 앞 2,000자와 그 파일 경로만 컨텍스트에 넣는다. 그래서 파일을 9,000자 이하의 줄 단위 조각으로 나누고
  조각마다 훅 명령 하나(`worker-protocol-hook.js --file <AGENTS.md> --part <n>`)를 둔다.
- 훅 명령은 동시에 실행되어 조각이 파일 순서대로 도착하지 않는다. 조각마다 첫 줄에 `part n of N`을 적는다.
- 조각 수는 워커를 띄울 때의 AGENTS.md로 정한다. `start`와 `add-worker`가 AGENTS.md를 쓸 때 설정 파일도 다시 쓴다.
- deny 규칙(PreToolUse 훅)이 있으면 같은 파일에 함께 들어간다. `launch_args`에는 남기지 않는다.
- Claude Code는 명령줄의 마지막 `--settings`만 쓴다. 워커의 `launch_args`에 `--settings`가 있으면 그 내용을 이 파일에
  합친다(설정은 그대로, 훅은 나란히). 읽지 못하면 경고를 내고 my-team의 훅만 적용한다.
  훅을 끄는 설정(`disableAllHooks`, `allowManagedHooksOnly`)과 형식이 틀린 훅은 경고를 내고 뺀다.
- 9,000자를 넘는 한 줄(한 줄로 쓴 `extra_prompt`)은 그 길이로 잘라 여러 조각에 나눠 넣는다.
- codex, gemini, cursor 워커에는 이 장치가 없다. `/clear` 뒤의 복구는 `/my-team-resume` 스킬이 한다.

## 7. 사용자가 자유롭게 주입할 수 있는 채널

| 채널 | 방법 | 영속성 |
|------|------|--------|
| **부팅 시 작업 브리프** | `config.workers[].extra_prompt` (또는 `extra_prompt_file`) | AGENTS.md `## Role Context`로 영구 |
| **도중 추가 지시** | 사용자가 그 워커의 tmux pane에 직접 타이핑 | tmux scrollback only |
| **peer 알림** | 워커끼리 `api send-message` (워커 LLM이 호출) | mailbox + archive + events.jsonl |

옵션 B 이전에 있던 `my-team msg`, `my-team add-task`, `workers/<w>/inbox.md`는 더 이상 채널이 아니다.

## 8. 보안 — 프롬프트 인젝션 방어

- `description`, `extra_prompt`는 `sanitizePromptContent`로 정제된 뒤 AGENTS.md에 박힘 (마크다운 escape + 길이 제한).
- 사용자가 워커 pane에 직접 타이핑하는 텍스트는 신뢰 채널 (사용자가 곧 운영자).
- peer 메시지 body는 정제하지 않는다 — 송수신 워커 모두 같은 권한 수준이라는 가정. 악성 peer 시나리오는 my-team의 위협 모델 밖.

## 9. 요약 표

| 레이어 | 파일 | 누가 작성 | 워커가 언제 읽나 |
|--------|------|-----------|------------------|
| ① AGENTS.md 오버레이 | `workers/<name>/AGENTS.md` | start.js가 부팅 시 generate | 시작 안내(§6)를 받은 직후 1회. claude 워커는 압축 뒤마다 훅이 다시 넣는다(§6) |
| ② Role Context (extra_prompt) | AGENTS.md `## Role Context` | 사용자의 config | ①에 포함되어 부팅 시 1회 |
| ③ peer 메시지 | `mailbox/<name>.json` | peer가 `api send-message` | new-message 트리거 또는 사이클 끝마다 폴링 |
| ④ 사용자 자유 입력 | 워커 pane stdin | 사용자가 직접 타이핑 | 즉시 (tmux 키 입력) |

옵션 B 이전 레이어 ②(`inbox.md`)와 mandatory task lifecycle workflow는 제거됐다.

## 10. 변경 시 체크리스트

- AGENTS.md overlay 섹션 추가/제거 → §2 표 업데이트
- 새 금지 룰 → §2 `## Rules` 불릿 목록 갱신 + 사고 사례 출처 추가 (LLM이 룰의 *이유*를 알면 더 잘 지킨다)
- 에이전트별 가이드 변경 → §2 "에이전트 타입별 가이드" 표
- start.js의 시작 안내 문구 변경 → §6
- env 변수 추가/변경 → §4
