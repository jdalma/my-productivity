---
name: my-team
description: Multi-project tmux worker orchestration. Spawn N CLI workers in tmux panes, each at its own project cwd, with shared mailbox for collaboration. Use when several distinct projects need to be edited and discussed by separate workers in one coordinated session.
aliases: []
---

# my-team Skill

Spawn coordinated CLI workers (claude / codex / gemini / cursor) across multiple project directories. Each worker runs in its own tmux pane at its own project cwd, with mailbox-based worker-to-worker communication.

## ⚠️ Prerequisite — CLI 설치 확인

이 스킬은 `my-team` CLI 바이너리(`tools/my-team` npm 패키지)를 호출한다. PATH에 없으면 동작하지 않는다.

```bash
command -v my-team  # 없으면 → 사용자에게 안내
```

미설치 상태이면 작업 시작 전에 사용자에게 안내한다:

> `my-team` CLI가 PATH에 없습니다. `/my-team-install`을 먼저 호출해서 설치한 뒤 다시 시도해주세요.

자동으로 install을 호출하지 마라. 사용자가 명시적으로 `/my-team-install`을 실행한 뒤 본 스킬을 다시 호출하는 흐름.

## Usage

```bash
# 1. Write a config file (my-team.json or team.json)
cat > my-team.json <<'EOF'
{
  "team_name": "my-feature",
  "workers": [
    {
      "name": "backend",
      "cwd": "/Users/me/IdeaProjects/atiissu-backend",
      "agent_type": "claude",
      "description": "백엔드 담당 (peers가 보는 한 줄 역할)",
      "extra_prompt": "백엔드 담당. 첫 작업은 주문 API 추가 — POST /orders, 검증 규칙은 ..."
    },
    {
      "name": "order",
      "cwd": "/Users/me/IdeaProjects/iic-ucp-order",
      "agent_type": "codex",
      "description": "주문 도메인",
      "extra_prompt": "주문 도메인 담당. 첫 작업은 캐시 추가 — Redis로 ..."
    }
  ]
}
EOF

# 2. Boot
my-team start --config ./my-team.json

# 3. Inspect
my-team status --team my-feature   # 워커별 state/blocked 사유 + spool/unread/pending 으로 멈춘 워커 식별
my-team monitor my-feature   # peer 메시지 실시간 tail

# 4. 도중에 워커한테 추가 지시 → 해당 워커의 tmux pane에 직접 타이핑
#    한 레포를 병렬로: 워커 pane에 "이 작업을 나눠서 워크트리 워커를 추가해"라고 하면
#    워커가 add-worker --worktree <branch> 로 peer를 띄운다 (경로 <repo>/.worktrees/<name>)
#    워커끼리는 my-team api send-message 호출 (워커 LLM이 AGENTS.md에 따라)

# 5. Shutdown (state도 정리: state_root → <state_root>.bak 백업 후 삭제)
my-team shutdown --team my-feature
```

**워커별 스킬 스택**: 워커는 기본 plain(전역 스킬만)으로 띄운다. config를 쓰거나 `add-worker`를 호출하기 전에 `$HOME/IdeaProjects/my-claude-plugin/stack/CATALOG.md`가 있으면 읽고, 그 §0(팀 설계 절차)부터 따라 워커마다 스택을 골라 `launch_args`(`--plugin-dir` 절대경로)와 `extra_prompt`(사용 규칙)를 조합한다. 파일이 없으면 스택 단계만 건너뛰고 아래 절차는 그대로 따른다.

**사용자가 "이 작업을 할 팀을 만들어줘"라고 할 때의 절차**:
1. 대상 레포를 조사한다 (README, 의존성, 배포 파일, `git status`·`git log`, 가능하면 테스트). 조사 결과와 함께 팀을 제안한다. 목표가 모호하면 팀을 짜기 전에 번호 선택지로 묻는다.
2. config는 `~/teams/<team>.json`에 쓴다 (레포 밖, 기존 팀 config와 같은 위치). `my-team start --config <path> --dry-run`으로 검증한다.
3. 권한 우회 플래그(`--dangerously-skip-permissions`) 여부를 사용자에게 묻는다. 클라우드 CLI·운영 시스템에 닿는 팀이면 그 위험을 함께 적는다.
4. `my-team start` 출력의 경고를 확인한다. my-team은 pane이 질문(셸 `[Y/n]`, CLI 업데이트 메뉴 `› 1. ...`)을 띄우고 있으면 입력·Enter를 보내지 않고 경고한다:
   - `is waiting on a shell prompt` → 그 pane에서 사용자가 답하면 my-team이 이어서 워커를 띄운다(`MY_TEAM_SHELL_READY_TIMEOUT_MS`, 기본 30초). 시간 안에 답이 없으면 `NOT launched`와 함께 실행 명령이 출력된다 → 답한 뒤 그 명령을 pane에 입력한다.
   - `startup notice NOT delivered` → 그 pane의 질문에 답한 뒤 경고에 찍힌 notice 문장을 입력한다. CLI 업데이트 여부는 사용자가 정한다(업데이트하면 CLI가 종료되므로 같은 명령으로 재실행).
   - 경고가 없어도 `tmux capture-pane -p -t <pane>`으로 각 pane을 한 번 훑는다 (notice가 입력창에 남아 제출되지 않았으면 Enter).
   - 마지막으로 `my-team status --team <team>`에서 전원 alive를 확인하고 보고한다.

**정리는 반드시 `my-team shutdown`으로**: state를 비우는 건 `shutdown`뿐이다. `tmux kill-session`으로 세션만 죽이면 state 디렉토리가 남아, 같은 `team_name`으로 다시 `start`할 때 이전 run의 `events.jsonl` / `archive` / `mailbox`를 그대로 상속한다.

**도중 작업 지시**: `my-team msg` / `my-team add-task` 명령은 없다. 사용자가 워커한테 추가 일감을 줄 때는 그 워커의 tmux pane에 직접 입력한다. 워커끼리 일감을 위임할 때는 `my-team api send-message`로 peer 메시지를 보낸다.

## When to use

Reach for `my-team` when **multiple unrelated repos** need to be edited and discussed by separate external CLI workers in one coordinated session, each rooted at its own `cwd`.

## Defining characteristics

- **Per-worker cwd** — each worker runs at its own `cwd`; a single team can span multiple unrelated repos.
- **Worktree per worker on demand** — `add-worker --worktree <branch>` creates `<repo>/.worktrees/<name>` and boots the worker there (parallel work on one repo). Merging and `git worktree remove` stay the user's job.
- **Retiring a worker** — `remove-worker --team <team> --name <worker>` is the inverse of `add-worker`: off the roster, pane closed. The departure notice goes only to workers it affects — those with an open question addressed to it (read from their `sent_pending`) plus the orchestrator(s); everyone else sees the change in their next `mailbox-list` roster. State files and worktree dirs are kept.
- **No task lifecycle** — my-team tracks no shared task objects (no claim/transition); roles are fixed at spawn.
- **User→worker channel** — the user types directly into the worker's tmux pane (no message CLI command).
- **State root** — `~/.my-team/sessions/<team>/`.
- **Peer-symmetric by default, roles optional** — with no `role` fields, workers communicate peer-to-peer via mailbox. A config may declare `role: "orchestrator" | "worker"` per worker: orchestrators initiate/delegate and are the team's cross-team gateway. Roles gate cross-team sends only — same-team worker→worker sends stay open in code — but in a role team the prompt routes collision checks through the orchestrator, so a direct worker→worker send is for topics the orchestrator delegated. Role 선언 시 orchestrator 최소 1명 필수.
- **File overlap is not policed** — parallel work on one repo runs on separate git worktrees (`add-worker --worktree`), so two workers never share a working tree and git resolves the rest at merge time. Nobody tracks file ownership, and workers do not ask each other what they are editing. To keep that premise true, `add-worker` refuses a `--cwd` an existing worker already uses (two workers in one working tree overwrite each other with no merge conflict to catch it); the error points at `--worktree <branch>`, and `--allow-shared-cwd` is the deliberate override.
- **Orchestrator narrates team changes** — in a role team, a worker joining mid-session sends it ONE report-in message (name, cwd, one-line assignment) so it can tell the user who joined and why, and whose work finished on a removal. That is a local print in its own pane, not a team broadcast. Workers do not greet each other on join — they appear in everyone's next `mailbox-list` roster.

## Worker AGENTS.md

Each worker gets a per-worker `AGENTS.md` overlay under `<state_root>/workers/<name>/AGENTS.md`. The worker's `extra_prompt` (its initial work brief) renders into the `## Role Context` section; peers see only the one-line `description` field via the `## Team Roster`. 그 로스터는 부팅 스냅샷이다 — `add-worker`로 합류한 워커는 기존 워커가 매 사이클 호출하는 `api mailbox-list` 응답의 `roster`로 전달된다(`description`은 manifest에 저장됨). 다른 팀 명단은 `api roster --input '{"team_name":"<팀>"}'`로 읽는다(지시받은 팀만, 스캔 금지).

## Communication channels

my-team은 기본이 **peer-to-peer 모델**이다 (task lifecycle 없음). 채널은 두 개뿐이다. `role` 필드를 선언한 팀에서는 cross-team 발신이 orchestrator로 제한된다(팀 내부는 누구나 누구에게나 발신 가능).

**Cross-team**: `api send-message`에 `"to_team":"<팀이름>"`을 추가하면 다른 실행 중인 팀의 워커에게 팀 이름으로 메시지를 보낼 수 있다(세션명 불필요, 재시작에도 안정). role 팀의 인바운드는 orchestrator만 받는다. 옛 `to_session` 필드는 거부된다.

| Channel | Surface | Notify |
|---------|---------|--------|
| User → worker | 해당 워커의 tmux pane (사용자가 직접 타이핑) | 즉시 (tmux stdin) |
| Worker ↔ worker | `mailbox/<w>.json` + `incoming-spool/<w>/` | worker calls `my-team api send-message`, recipient gets `new-message:<from>` tmux trigger |
| Worker → user | 해당 워커의 pane stdout | 사용자가 pane을 직접 본다 |

**금지된 경로** (워커 LLM이 위반하면 안 됨):
- 다른 워커의 pane에 `tmux send-keys`로 직접 입력 박기 — manifest의 pane id는 사용자의 모니터링용이지 워커간 제어 surface가 아니다.
- `my-team msg` 호출 — 이 명령은 제거됐다. 사용자→워커는 pane 직접 입력 한 가지뿐.

## Worker succession (컨텍스트가 찼을 때 워커 교대)

`/clear` 대신 **후임 워커를 옆에 띄우고 전임과 대화하게 한다.** handoff 문서는 압축본이라 버려진 맥락이 있다 — 후임이 문서를 읽고 궁금한 것을 전임에게 직접 묻는 것이 이 절차의 핵심이다.

**전임 워커 pane에서** — 사용자가 "교대해" 뒤에 후임이 집중할 내용을 한두 줄 덧붙인다 (예: `교대해. 집중: 주문 API 재시도 로직만, 캐시는 건드리지 마`). 전임은 그 문장을 **그대로** `--extra-prompt`의 `사용자 지시:` 줄에 싣는다 — 요약하거나 자기 해석으로 바꾸지 않는다:

```bash
/handoff                                   # docs/handoffs/<file>.md — 지금까지와 동일
my-team add-worker --team <team> --name <me>-2 --cwd "$PWD" --agent-type <same> \
  --description "<same one-liner>" \
  --extra-prompt "<me>의 후임. 사용자 지시: <사용자가 pane에 적은 문장 그대로>. 1) CLAUDE.md를 읽고 /takeover docs/handoffs/<file>.md 를 실행한다. 2) 문서를 읽고 궁금한 것을 전부 전임 <me>에게 send-message(expects_reply)로 묻는다 — 한 통에 최대한 묶되, 답을 보고 생긴 후속 질문도 계속 묻는다. 3) 더 물을 것이 없으면 <me>에게 '인계 완료'를 보내고 my-team remove-worker --team <team> --name <me> 를 실행한다."
```

사용자 지시가 없으면 `사용자 지시:` 줄을 생략한다. 후임은 handoff 문서와 사용자 지시가 어긋나면 사용자 지시를 우선한다.

이후 전임은 **후임의 질문에 답하는 것 외에 아무 작업도 하지 않는다.** 남은 컨텍스트는 전부 답변에 쓴다.

규칙:
- **인계 브리프는 `--extra-prompt`, 질문은 mailbox.** Role Context는 AGENTS.md 파일로 남아 후임이 다시 `/clear` 해도 `/my-team-resume`으로 되찾는다. mailbox 메시지는 delivered 후 아카이브로 빠지므로 브리프 운반체로 쓰지 않는다.
- **`--extra-prompt`에 handoff 본문을 복사하지 않는다.** 경로 + 위 세 단계면 충분하다. stale 판정(`head_commit`)은 `/takeover`가 문서로 한다.
- **전임의 컨텍스트는 거의 없다.** 후임은 질문을 가능한 한 묶어 보내고, 전임은 답만 한다. 대화 횟수 제한은 없지만 전임이 도중에 끊길 수 있음을 전제한다.
- **`remove-worker`는 후임이 실행한다.** 이 명령은 pane을 죽인 뒤 피어에게 이탈 통지를 보내므로, 전임이 자기 자신을 제거하면 통지 전에 죽는다.
- **이름은 세대 접미사(`backend` → `backend-2`).** 같은 이름은 거부된다. 피어는 `remove-worker`의 이탈 통지와 `mailbox-list`의 `roster`로 새 이름을 안다.

## Worker closeout (작업 종결 보고 → 검증 → 제거/재개 브리프)

워커의 티켓이 끝났을 때는 succession 이 아니라 **`/my-team-closeout`** 을 쓴다. 워커가 생성자(보통 orchestrator)에게 증거 기반 완료 보고를 보내고, 생성자가 티켓과 대조 검증한 뒤 **완료면 `remove-worker` + 종결 문서, 미완료면 다른 워커가 바로 이어받을 수 있는 재개 브리프를 쓴다(전임은 유지)**. 제거는 항상 보고받은 쪽이 실행한다 — 자기 자신을 제거하면 이탈 통지 전에 죽는다. 상세 절차·템플릿은 `my-team-closeout` 스킬.

## Constraints

- 1–10 workers per team
- Worker name: `[a-zA-Z0-9-]+`
- `cwd`: absolute or `~`-prefixed (no relative paths)
- Same `team_name` cannot run twice (refused with AC-28 error)
- agent CLI must be installed on PATH (claude / codex / gemini / cursor-agent)

## Environment variables

| Var | Default | Effect |
|-----|---------|--------|
| `MY_TEAM_STATE_ROOT_BASE` | `~/.my-team/sessions` | base directory for sessions |
| `MY_TEAM_STATE_ROOT` | (set by `start`) | absolute state root for current invocation |
| `MY_TEAM_NO_RC` | (unset) | if `1`, workers skip sourcing zshrc/bashrc |
| `MY_TEAM_SHELL_READY_TIMEOUT_MS` | `30000` | how long to wait for a worker CLI prompt |

See PLAN.md for the full 31-criterion acceptance set and design rationale.
