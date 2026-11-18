# my-team — 워커 통신 아키텍처

> 본 문서는 `tools/my-team` CLI가 워커끼리 어떻게 메시지를 주고받게 하는지의 내부 메커니즘을 정리한다. 사용자 가이드는 `README.md`, 워커 부팅 프롬프트는 [`worker-bootstrap.md`](worker-bootstrap.md), 초기 설계 의도(역사적 기록)는 `PLAN.md`.
>
> **현재 모델 (옵션 B 컷오버 이후)**
> - **사용자 → 워커**: 사용자가 그 워커의 tmux pane에 직접 타이핑한다. 별도 CLI 명령이나 파일 채널이 없다.
> - **워커 ↔ 워커**: `my-team api send-message`로 mailbox + incoming-spool에 메시지를 떨어뜨리고, 수신자 pane에 짧은 `new-message:<from>` 트리거를 쏜다. 수신자는 트리거를 받거나 자기 work cycle 끝에 `api mailbox-list`로 자기 mailbox를 폴링해 메시지를 흡수한다.
> - **워커 → 사용자**: 별도 채널 없음. 사용자가 그 워커의 pane stdout을 직접 본다.
>
> **대상 코드**: `src/lib/tmux-comm.js`, `src/lib/events.js`, `src/commands/api/send-message.js`, `src/commands/{monitor,start,shutdown}.js`, `src/lib/tmux-session.js`
>
> **시각 다이어그램**:
> - [`worker-message-flow.html`](worker-message-flow.html) — **현행 모델 기준** peer 메시지 흐름을 한 장으로 보여주는 단일 HTML (브라우저로 열면 됨). spool→mailbox 데이터 흐름, ①~⑦ 단계, 설계 근거 FAQ(왜 spool이 필요한가 / 수신자 메시지 구분 / 흡수 담당) 포함.
> - [`diagrams/communication-flow.excalidraw`](diagrams/communication-flow.excalidraw)는 옵션 B 이전(채널 4개 시대)을 묘사한다. peer mailbox 사이클(§3 이하)은 그대로 유효하지만 user→worker free-form 레인은 폐기됐다. (구버전 — 최신 시각 자료는 위 HTML 참조)

---

## 1. 한눈에 보는 데이터 흐름

```
            user (host pane)
                  │
                  ▼  (직접 타이핑)
   ┌──────────────────────────────────────────┐
   │             tmux session                 │
   │                                          │
   │  ┌──────────┐         ┌──────────┐       │
   │  │ worker A │         │ worker B │       │
   │  └────┬─────┘         └────┬─────┘       │
   └───────┼────────────────────┼─────────────┘
           │                    │
   send-message API     mailbox-list API
           │                    │
           ▼                    │
   incoming-spool/B/<id>.json  ─┘   absorb spool
           │                    │
           │ tmux trigger        │
           │ "new-message:A"     │
           └───── pane stdin ───►│
                                 ▼
                          mailbox/B.json (inbox map)
                                 │
                        mark-delivered API
                                 ▼
                          archive/B.jsonl (durable, append-only)
                                 │
                                 ▼
                          events.jsonl  ← monitor가 tail
```

## 2. 채널 매트릭스

| # | 채널 | 송신자 | 표면 | 알림 | 영속성 |
|---|------|--------|------|------|--------|
| 1 | **사용자 → 워커** | 사용자 (host pane) | 워커 pane의 stdin (tmux 키 입력) | 즉시 | tmux scrollback에만 |
| 2 | **워커 → 워커** | 워커 LLM | `incoming-spool/<to>/<msg>.json` → `mailbox/<to>.json` → `archive/<to>.jsonl` | `new-message:<from>` tmux 트리거 (best-effort) | mailbox + archive (영구) + events.jsonl |
| 3 | **워커 → 사용자** | 워커 LLM | 워커 pane의 stdout | 없음 — 사용자가 pane 관찰 | tmux scrollback |

채널이 셋뿐이다. 옵션 B 이전에 있던 `inbox.md` (사용자→워커 자유 텍스트), `tasks/<id>.json` (사용자→워커 정형 task), `leader/inbox.md` (워커→leader) 세 채널은 제거됐다.

### 2.1 식별자 일관성 — `config.workers[].name` 단일 source

워커 이름(`config.workers[].name`)이 모든 식별 surface에서 동일하다:
- mailbox 파일명 — `mailbox/<name>.json`
- archive 파일명 — `archive/<name>.jsonl`
- incoming-spool 디렉토리 — `incoming-spool/<name>/`
- tmux pane title — `select-pane -T '<name>'` + `@worker_name` 옵션 (`start.js`)
- API `send-message`의 `to_worker` / `from_worker` 인자
- AGENTS.md overlay의 `## Team Roster` 항목

→ 워커 LLM이 화면에서 보는 이름 그대로 `to_worker`로 쓰면 된다.

## 3. peer 메시지 한 사이클 — "쓰고 → 알린다"

`api send-message`가 호출되면 4단계로 진행한다 (`tmux-comm.js:queueDirectMessage`):

```
sender 워커 LLM
    │
    │ my-team api send-message --input {team_name, from_worker, to_worker, body, expects_reply?, reply_to?}
    ▼
[1] sender의 mailbox.sent_pending에 메시지 등록  (expects_reply=true일 때만)
    │   ← 크래시 안전: 이 단계 후 어떤 실패가 나도 sender는 자기가 보낸 사실을 안다
[2] sender archive/<from>.jsonl에 direction=out으로 append
    │   ← durable 송신 기록
[3] incoming-spool/<to>/<msg_id>.json 파일을 떨어뜨림
    │   ← 이게 곧 delivery commit. 파일별 unique id로 동시성 충돌 없음
[4] tmux send-keys로 수신자 pane에 'new-message:<from>' 토큰 입력 (best-effort)
    │   ← trigger 실패해도 spool은 이미 있음 → 수신자가 self-poll로 발견 가능
    ▼
events.jsonl에 append (audit log)
```

수신자 워커 LLM은:

```
[A] 자기 사이클 끝마다 또는 trigger를 보면 → my-team api mailbox-list
    │
    ▼
[B] mailbox-list가 incoming-spool/<to>/*.json을 모두 mailbox.inbox로 흡수
    │   (absorbIncomingSpool — spool 파일은 흡수 후 unlink)
    │   동시에 흡수된 메시지 중 reply_to가 자기 sent_pending에 있으면 그 항목 제거
[C] mailbox.inbox에서 읽지 않은 메시지를 created_at 오름차순으로 반환
    │
    ▼
[D] 각 메시지 처리 후 → my-team api mailbox-mark-delivered
    │   mailbox에서 제거 + archive/<to>.jsonl에 direction=in으로 append
```

### 3.1 핵심 보장

| 항목 | 보장 | 메커니즘 |
|------|------|----------|
| 동시 송신 race-free | ✅ | spool은 파일당 unique `message_id` 이름 → 송신자끼리 충돌 불가 |
| 수신자 mailbox 일관성 | ✅ | mailbox.json은 수신자(=소유자) 만 쓴다. 송신자는 spool에만 떨어뜨림 |
| torn write 방지 | ✅ | mailbox.json은 `atomicWriteJson` (write-temp + rename) |
| audit 보존 | ✅ | archive는 append-only jsonl + events.jsonl도 별도로 append |
| 트리거 손실 복구 | ✅ | tmux trigger는 best-effort; mailbox-list 자가 폴링이 진짜 source of truth |

### 3.2 expects_reply / reply_to 상관관계

`expects_reply: true`를 설정한 송신은 sender의 `sent_pending` 맵에 등록된다. 그 메시지에 대한 답장은 `reply_to: <original_id>`로 송신하며, 수신자의 mailbox-list가 sent_pending에서 자동으로 해당 항목을 제거한다. 답장 자체는 `expects_reply: false`여야 한다 (`worker-bootstrap.md`의 발신 룰 참조).

reply_to 해석 순서:
1. **sent_pending hit** — 내가 보낸 질문에 대한 답이다.
2. **archive-lookup (direction=out)** — 옛날 내가 expects_reply 없이 보낸 메시지에 누가 늦게 답한 경우.
3. **archive-lookup (direction=in)** — 내가 옛날에 받은 메시지에 대한 follow-up.
4. 어디서도 못 찾으면 → peer 버그. body 자체만으로 처리.

### 3.3 broadcast는 없다

`api send-message`는 1:1 전송이다. broadcast는 없다. 내부 helper(`queueBroadcastMessage`)는 부르는 곳이 없어 T63e2에서 지웠다. 워커가 여러 peer에 동시에 질문하려면 각각 별도 `send-message` 호출을 해야 한다. 그래야 답마다 자기 message_id의 reply_to로 이어진다.

## 4. 메시지 스펙

### 4.1 peer mailbox 메시지

`mailbox/<to>.json` (스키마 v2):

```jsonc
{
  "schema_version": 2,
  "worker": "<to>",
  "inbox": {
    "<message_id>": {
      "message_id": "<ts>-<rand>",
      "from_worker": "<from>",
      "to_worker": "<to>",
      "body": "<자유 텍스트>",
      "reply_to": "<orig_id>" | null,
      "expects_reply": false,
      "created_at": "<ISO>"
    }
  },
  "sent_pending": {
    "<message_id>": {
      "message_id": "<id>",
      "to_worker": "<peer>",
      "body": "...",
      "expects_reply": true,
      "sent_at": "<ISO>"
    }
  }
}
```

`incoming-spool/<to>/<msg_id>.json`은 위 `inbox[<id>]` 한 항목과 같은 shape의 단일 객체. mailbox-list가 흡수 후 unlink한다.

`archive/<who>.jsonl`은 한 줄에 하나의 객체:
- `{ ...message, direction: "out" }` — 자기가 send-message 보낼 때 append
- `{ ...message, direction: "in" }` — mailbox-mark-delivered 호출 시 append

스키마 mismatch (v1 또는 schema_version 누락)는 mailbox-list가 throw한다. 자동 마이그레이션 없음 — 운영자가 shutdown 후 재시작하라는 메시지가 나온다.

### 4.2 events.jsonl

팀의 타임라인. 메시지(`send-message`), tmux shim의 거부(`tmux-denied`), worker guard hook의 거부(`tool-denied`)가 한 줄씩 append된다. 모든 새 줄은 `ts`, `type`, `team`, `worker`를 가진다. 줄 종류별 키, 길이 상한, 옛 줄 읽는 규칙은 [events-format.md](events-format.md)에 있고, 코드의 정의는 `src/lib/events.js`의 `EVENT_TYPES` 하나다.

```jsonc
{ "ts": "<ISO>", "type": "message", "team": "<보낸 팀>", "worker": "<from>", "from": "<from>", "to": "<to>",
  "body": "...", "message_id": "<id>", "reply_to": "<id>" | null, "expects_reply": false }
```

메시지 전달 뒤에 쓰므로, 기록에 실패해도 send-message는 ok와 `warning`을 돌려준다(재전송 중복 방지). `my-team monitor <team>`은 `readEvent`로 이 파일을 읽어 실시간 출력한다.

## 5. tmux 트리거 토큰

남은 토큰은 단 하나:

| 토큰 | 의미 | 발신처 |
|------|------|--------|
| `new-message:<from>` | "당신 mailbox에 <from>이 보낸 새 메시지가 있다" | `tmux-comm.js:queueDirectMessage` step 4 |

옵션 B 이전에 있던 `check-inbox`, `new-task:<id>` 토큰은 제거됐다.

### 5.1 `sendToWorker` robust 처리 (`tmux-session.js`)

워커 pane이 busy 상태일 때 `send-keys`는 토큰이 흡수돼 사라지는 일이 있다. 그래서 `sendToWorker`는 다음 가드를 거친다:

1. **copy-mode 가드** — pane이 copy-mode이면 전송 자체 거부
2. **busy 감지** — `paneHasActiveTask` ("esc to interrupt" / "background terminal running" 신호) 발견 시 round 1에서 Tab+Enter (codex의 "interrupt and submit" 컨벤션). 다른 CLI에서는 Tab이 다르게 해석될 수 있어 알려진 한계.
3. **trust prompt 감지** — 첫 부팅의 "Do you trust the contents of this directory?" 다이얼로그가 떠 있으면 C-m 두 번으로 통과.
4. **send → 6라운드 poll** — 메시지를 `-l --`(literal)로 입력 후, pane tail에 그대로 남아있으면(=아직 안 먹힘) Enter 다시 보냄. 최대 6번 시도.

200자 제한은 그대로 유지된다 — 본문은 mailbox에 있고 트리거는 짧은 알림이라는 분리 원칙.

## 6. 호스트 pane (예전엔 "leader pane")

`manifest.json`의 `leader_pane` 필드는 tmux 토폴로지의 첫 번째 pane을 가리킨다. 이 pane은 **orchestrator가 아니다** — peer-to-peer 모델에서는 leader 역할이 없다. 단지 다음 둘 중 하나다:

- **in-place 모드**: 사용자가 `my-team start`를 친 그 pane (사용자의 본거지)
- **detached 모드**: `my-team start --detached`로 새 세션을 만들 때 생기는 빈 host pane. start.js가 자동으로 `my-team monitor <team>`을 그 pane에 실행시켜 사용자가 attach하면 즉시 peer 트래픽을 본다.

식별자 이름은 OMC 호환을 위해 `leader_pane`을 유지했지만, 의미는 "host pane"이다 (`tmux-session.js`의 `createTeamSession` docstring 참조).

## 7. 동시성·일관성 처리

| 위협 | 보호 |
|------|------|
| 두 송신자가 동시에 같은 수신자에게 send-message | spool 파일명이 `message_id`로 unique → 충돌 불가 |
| send-message 도중 sender 크래시 | step 1(sent_pending)을 먼저 → 송신자가 자기 발송을 안다. step 3 전이면 수신자는 모름 (re-send 필요) |
| mailbox-list 도중 수신자 크래시 | spool 파일은 흡수 후 unlink. 중간 크래시 시 일부 spool 남음 → 다음 mailbox-list가 마저 흡수 |
| 같은 message_id 중복 흡수 | mailbox.inbox는 객체 키이므로 동일 id면 덮어쓰기 (멱등) |
| schema 변경 | schema_version mismatch는 throw — 운영자가 강제 셔다운 |
| add-worker 도중 팀 shutdown | 페인 생성 후 manifest append 직전 manifest를 **reload** — 사라졌으면("team shut down mid-operation") 새 페인 kill + abort. 락은 없음(레포의 직렬-인간 모델) |

## 7.5 mid-session 워커 추가 (`add-worker`)

실행 중인 팀에 워커 하나를 더 붙이는 경로. `start`가 토폴로지 전체를 한 번에 굽는 것과 달리, `add-worker`는 이미 살아있는 세션에 페인 하나를 split 한다.

- **`createTeamSession`을 재사용하지 않는다.** 그 함수는 `detectTeamMultiplexerContext()`로 호출자 셸의 `env.TMUX`를 읽는데(`tmux-session.js:197`), `add-worker` 프로세스는 팀 tmux 세션 **밖**에서 돈다. 재사용하면 두 번째 고아 세션이 생긴다. 대신 manifest에서 가져온 기존 워커 페인 id를 앵커로 `addWorkerPane(session_name, anchorPaneId, worker)`가 직접 `split-window` 한다.
- **전달(delivery)의 단일 source는 `manifest.workers` append.** `send-message`는 매 호출 sender/recipient의 roster 멤버십을 enforce하므로(`send-message.js:58,65`), 새 워커를 `manifest.workers`에 넣는 것이 새 워커로/에서의 메시징의 **필요충분조건**이다. AGENTS.md는 이 경로에 없다.
- **인지(awareness)는 `mailbox-list`의 `roster`가 전담 (2026-09-17 개정).** 이미 떠 있는 기존 워커 LLM은 launch 시 한 번 읽은 AGENTS.md로 peer 목록을 고정한다. 디스크의 AGENTS.md를 다시 써도 런타임 LLM에 도달하지 못하므로 **재작성하지 않는다.** 대신 모든 워커가 매 사이클 호출하는 `api mailbox-list`가 응답마다 manifest 기준 최신 `roster`를 동봉한다(`mailbox-list.js:19`). 새 피어의 *존재*는 이 경로만으로 전원에게 도달하므로 **별도 인사 메시지가 필요 없다.**
  - **왜 전원 인사를 없앴나.** 이전 설계는 D가 부팅 직후 기존 워커 *각각*에게 `expects_reply=true`로 인사하도록 했다. 존재 인지는 이미 roster가 하고 있었으므로 중복 채널이었고, 합류 1건당 2N통(인사 N + 회신 N)을 발생시켜 점대점 메시지가 폭증했다.
  - **합류 보고는 사용자 알림용 1통.** D의 startup notice는 **orchestrator에게만 1통**(이름·cwd·담당 한 줄)을 `expects_reply` 없이 보내라고 지시한다. 목적은 orchestrator가 "누가 무슨 일로 합류했다"를 자기 pane stdout으로 사용자에게 알리는 것이다. role 없는 peer 팀은 orchestrator가 없으므로 보고 자체가 없고 roster에만 의존한다.
  - **파일 겹침은 관리하지 않는다.** 한 레포 병렬 작업은 `add-worker --worktree`로 각자의 git worktree에서 돈다. 워킹 트리가 물리적으로 분리되므로 두 워커가 같은 파일을 동시에 덮어쓸 일이 없고, 나머지는 머지 시점에 git이 처리한다. 따라서 워커별 파일 소유권 맵을 만들지 않고, 워커끼리 "뭐 편집 중이냐"를 묻지도 않는다. 그런 대화는 O(N²)인데 얻는 것이 없다.
    - **공유 cwd는 코드가 막는다.** 위 전제(워크트리로 분리됨)가 성립하지 않는 유일한 경우가 같은 `--cwd` 공유인데, 이때는 브랜치까지 같아 머지 충돌조차 나지 않고 한쪽 편집이 조용히 덮어써진다. 그래서 `add-worker`는 manifest에 같은 cwd를 쓰는 워커가 하나라도 있으면 **거부**한다(`add-worker.js`, 부작용 이전 검증 구간). 에러 메시지가 `--worktree <branch>`를 안내하고, 의도적 공유는 `--allow-shared-cwd`로만 가능하다. 비교는 tilde 확장 + `resolve()`를 거친 정규 경로로 한다. `realpath()`는 쓰지 않으므로(부작용 없는 검증을 유지) 심볼릭 링크로 만든 중복은 통과한다 — 수용된 한계다.
  - **이탈 통지 대상은 코드가 판정한다.** `remove-worker`는 남은 각 워커의 mailbox `sent_pending`을 읽어 `to_worker`가 제거 대상인 워커(= 못 받을 답을 기다리는 워커)만 고르고, 거기에 orchestrator를 더한다(`remove-worker.js`). 이건 LLM 추측이 아니라 디스크에 기록된 사실이다(`tmux-comm.js:290`). 둘 다 비면(레거시 peer 팀) 침묵을 피하려 기존대로 전원에게 보낸다.
- **fail-safe 순서.** 검증(부작용 0) → state dir + 새 워커 AGENTS.md → 페인 split → CLI spawn → ready 대기 → 라벨/레이아웃 재assert → **manifest reload + append (커밋 포인트)** → D에게 보고 트리거 startup notice. 페인 split 이후 어떤 실패든 새 페인만 kill하고 manifest는 건드리지 않는다. 호스트(leader) 페인은 절대 kill하지 않는다.
- **권한 플래그(`--launch-arg`).** start의 `launch_args`와 동등하게, add-worker도 `--launch-arg`(반복)로 권한 우회 플래그(예: `--dangerously-skip-permissions`)를 워커 CLI에 forward한다. **이 플래그가 없으면 추가된 워커는 supervised 모드**로 떠서 첫 권한 프롬프트에서 멈춘다 — 사용자가 해당 pane에서 응답해야 진행된다. 자율 워커를 원하면 `--launch-arg`로 우회 플래그를 넘긴다. (start과 달리 `--env`는 의도적으로 제외 — 최소 표면. `--description`은 로스터용, `--extra-prompt`는 Role Context 브리핑용으로 받는다.)
- **`--worktree <branch>` (한 레포 병렬 작업).** `--cwd`의 git 레포에서 `git worktree add <root>/.worktrees/<name> [-b] <branch>`를 실행하고 그 경로를 워커 cwd로 쓴다. `.worktrees/`는 `.git/info/exclude`에 추가해 메인 체크아웃의 `git status`를 더럽히지 않는다. 페인 split 이후 실패 시 방금 만든 워크트리도 `git worktree remove --force`로 되돌린다. 병합 후 워크트리 제거는 사용자 몫이며 `shutdown`은 pane만 죽인다. 워커가 직접 이 명령을 호출할 수 있도록 AGENTS.md에 레시피가 들어가며(허용된 유일한 비-api 서브커맨드), `--launch-arg` 없이 호출하면 호출한 워커(`MY_TEAM_WORKER`)의 `launch_args`(manifest에 저장)를 상속한다. 팀 내부 worker→worker 발신은 코드상 열려 있다(role 가드는 cross-team에만 적용). 다만 role 팀의 프롬프트는 충돌 협의를 orchestrator 경유로 규정하므로, 워커끼리의 직접 발신은 orchestrator가 명시 위임한 경우에 한정된다.
- **cwd 정규화.** `--cwd ~/foo` 같은 tilde 경로는 `validateWorker`가 절대경로로 확장한 값이 tmux split-window와 manifest에 저장된다(start과 동일 표현). literal `~`가 새는 일은 없다.
- **동적 로스터.** `start`와 `add-worker`가 워커의 `description`(없으면 `extra_prompt` 첫 줄)을 manifest에 저장한다. `api mailbox-list`는 응답마다 manifest 기준 `roster`(name/agent_type/role/description)를 동봉하므로, 부팅 후 합류한 워커도 기존 워커의 다음 self-poll에 로스터로 도달한다. AGENTS.md의 로스터는 부팅 스냅샷임을 본문에 명시한다. 다른 팀의 로스터는 `api roster --input '{"team_name":"<팀>"}'`(pure)로 읽는다 — 지시받은 팀만 조회하며, 팀 탐색(스캔) 금지 규칙은 유지된다.

## 8. 빠진 기능 / 한계

- **신뢰성 있는 알림 없음**: tmux trigger는 best-effort. 수신자 mailbox-list 자가 폴링이 진짜 보장. 시간 민감한 워크플로우는 워커 LLM이 적극적으로 폴링하도록 하라.
- **delivery latency 측정 없음**: my-team은 송수신 사이 경과 시간을 측정/경고하지 않는다. sent_pending이 너무 많이 쌓이면 워커 LLM이 stdout으로 사용자에게 알리도록 AGENTS.md에 적혀 있다.
- **워커 → 사용자 인접 채널 없음**: 워커가 사용자에게 알리려면 자기 pane stdout 외 길이 없다. 사용자가 pane을 보고 있어야 한다.
- **multi-host tmux 지원 없음**: 모든 워커는 같은 호스트 같은 tmux session 안에 있다.

## 9. 변경 시 체크리스트

코드 변경 후 본 문서를 동기화해야 하는 경우:

- `send-message`/`mailbox-list`/`mark-delivered`/`archive-lookup` 스펙 변경 → §3, §4.1
- `events.jsonl` 포맷 변경 → §4.2
- tmux 트리거 토큰 추가/변경 → §5
- mailbox/archive/spool 스키마 변경 → §4.1, MAILBOX_SCHEMA_VERSION 증가, mailbox-list throw 메시지 업데이트
- host pane(=leader_pane) 의미 변경 → §6

## 10. monitor 자동 시작 — detached 모드 한정 (`start.js`)

`session_mode === 'detached-session'`이면 start.js가 host pane에 `my-team monitor <team>` 명령을 `send-keys + Enter`로 자동 실행한다. 사용자가 `tmux attach`하는 순간 peer 트래픽이 흐른다. in-place 모드에서는 host pane이 사용자의 입력 pane이므로 자동 실행 안 하고 tip만 stdout으로 알린다.

## 11. 참고

- [`worker-message-flow.html`](worker-message-flow.html) — 현행 peer 메시지 흐름 시각 자료 + 설계 근거 FAQ (브라우저로 열기)
- `worker-bootstrap.md` — 워커 부팅 시 AGENTS.md overlay 구조
- `README.md` — 사용자 가이드, launch_args, 권한 모드별 권장 설정
- `PLAN.md` — 초기 설계 (옵션 B 컷오버 이전 모델 기록)
