---
name: my-team-handoff
description: my-team 팀 전체를 shutdown하기 전에 PM(orchestrator)이 모든 워커의 진행 상태를 한 묶음으로 수집·취합하는 팀 단위 handoff. 두 상황에서 반드시 사용한다. (1) PM — my-team PM pane에서 사용자가 "/my-team-handoff", "팀 handoff", "팀 내리기 전에 정리해", "다음에 이어서 하게 전부 정리해" 라고 하면 전 워커에게 상태 보고를 요청하고 ~/.my-team/handoffs/{team}/ 에 team.md로 취합한다. (2) 워커 — 메일박스에 본문이 `[team-handoff]`로 시작하는 메시지가 도착한 워커는 이 스킬의 §B 절차로 자기 상태 파일을 쓰고 회신한다. 워커 1명만 /clear하는 경우(/my-team-resume)나 워커 교대(succession)·티켓 종결(/my-team-closeout)과 다르다 — 이 스킬은 팀을 통째로 내렸다가 같은 config로 다시 띄울 때 쓴다. 재기동 후 로드는 /my-team-takeover.
---

# my-team handoff — 팀 shutdown 전 상태 수집

`my-team shutdown`은 state_root를 `.bak`으로 치우고 모든 워커의 컨텍스트를 날린다. 코드와 git은 디스크에 남지만 **"무엇을 하던 중이었고, 무엇이 막혔고, 누가 무엇을 결정해야 하는가"는 워커의 머릿속에만 있다.** 이 스킬은 shutdown 전에 그것을 파일로 꺼내 둔다.

- **config는 건드리지 않는다.** `my-team.json`은 워커의 거시적 역할·워크스페이스를 담는 재사용 정의다. 작업 상태는 config가 아니라 이 스킬이 만드는 묶음(bundle)에만 들어간다.
- **상태는 워커가 직접 쓴다.** 실패한 시도·암묵적 결정·미커밋 변경의 의도는 그 워커만 안다. PM은 요청하고, 취합하고, 교차 확인한다.
- **문서는 hypothesis다.** 재기동 후 `/my-team-takeover`가 git과 대조해 검증한다. 그래서 git 기준점(`head_commit`)과 라인 번호를 반드시 남긴다.

## 0. 공통 — 정체 확인

```bash
echo "worker=$MY_TEAM_WORKER state_root=$MY_TEAM_STATE_ROOT"
```

`MY_TEAM_WORKER`(`<team>/<worker>`)가 비어 있으면 my-team 워커 pane이 아니다. 그 사실만 알리고 중단한다.

- 메일박스에 `[team-handoff]` 메시지가 와서 호출된 것이면 → **§B (워커)**
- 사용자가 pane에서 호출한 것이면 → **§A (PM)**

---

## A. PM 절차

### A1. 대상 워커와 묶음 경로 정하기

```bash
TEAM="${MY_TEAM_WORKER%%/*}"; ME="${MY_TEAM_WORKER#*/}"
my-team api roster --input "{\"team_name\":\"$TEAM\"}" --json
python3 -c "import json;[print(w['name'],w['cwd'],w['agent_type']) for w in json.load(open('$MY_TEAM_STATE_ROOT/manifest.json'))['workers']]"
my-team api mailbox-list --input "{\"team_name\":\"$TEAM\",\"worker\":\"$ME\"}" --json   # 자기 sent_pending·미읽음
BUNDLE="$HOME/.my-team/handoffs/$TEAM/$(date +%Y-%m-%d-%H%M%S)"; mkdir -p "$BUNDLE/workers"
```

묶음은 state_root 바깥(`~/.my-team/handoffs/<team>/`)에 둔다. state_root 안에 두면 shutdown이 `.bak`으로 옮겨 버린다. 디렉터리명이 날짜·시각이라 `ls -t`로 최신이 찾힌다.

대상은 roster에서 자신을 뺀 전원이다. `add-worker`로 중간 합류한 워커도 포함한다 — 재기동 config에 없을 수 있으므로 takeover가 따로 다룬다.

### A2. 요청 전송

워커마다 한 통씩 보낸다:

```bash
my-team api send-message --input '{"team_name":"<team>","from_worker":"<me>","to_worker":"<w>","expects_reply":true,
 "body":"[team-handoff] 팀 shutdown 전 상태 수집. <bundle>/workers/<w>.md 에 상태 파일을 쓰고 이 메시지에 reply_to로 경로와 한 줄 요약을 회신하라. 수신 절차=my-team-handoff 스킬 §B. 회신 후 새 작업 시작 금지."}' --json
```

본문은 `[team-handoff]`로 시작해야 워커가 일반 지시와 구분한다. 파일 경로를 PM이 지정해 주는 이유는 워커가 묶음 위치를 몰라도 되게 하기 위해서다.

### A3. 회신 수집

`new-message` 알림이 올 때마다 `mailbox-list`로 회신을 처리하고 `mailbox-mark-delivered`한다. `sent_pending`에 남은 워커가 미응답자다.

미응답 워커가 남아 있으면 PM이 그 워커의 상태를 추측해 채우지 않는다. 사용자에게 "<w> 미응답 — 재촉/대기/제외 중 선택"을 묻는다. 제외하면 team.md에 `미응답`으로 남기고, 그 워커 cwd의 `git status`·`git log -5` 결과만 사실로 적는다.

### A4. 교차 확인

각 워커 파일을 읽고 PM이 직접 확인한다:

- **git 기준점**: `git -C <cwd> rev-parse HEAD`가 파일의 `head_commit`과 같은가. 다르면 워커가 회신 후에도 커밋한 것이다 → 해당 워커에게 확인.
- **의존 짝 맞추기**: A가 "B의 X를 기다림"이라고 썼는데 B 파일에 X가 없으면 어긋남이다. team.md의 의존 표에 `불일치`로 적는다.
- **결정 필요 중복·충돌**: 여러 워커가 같은 결정을 다른 전제로 묻고 있으면 하나로 합친다.
- **열린 질문**: 각 워커 파일의 `열린 질문` + PM 자신의 `sent_pending`. shutdown이 메일박스를 치우므로 여기 적지 않은 질문은 사라진다.

### A5. team.md 작성

`<bundle>/team.md`에 아래 「team.md 템플릿」으로 쓴다. PM 자신의 상태(팀 국면, PM이 들고 있던 계획·미배분 작업)도 여기 들어간다 — PM도 shutdown 때 컨텍스트를 잃는다.

### A6. 종료 보고

pane에 출력한다:

```
팀 handoff 완료: <bundle>/team.md
- 워커 <N>명 (회신 <k>, 미응답 <m>)
- 결정 필요 <d>건, 워커 간 불일치 <x>건
- 재기동: my-team shutdown --team <team>  →  my-team start --config <기존 config>  →  PM pane에서 /my-team-takeover
```

**shutdown은 실행하지 않는다.** PM이 자기 팀을 내리면 자기 pane도 죽고, 시점은 사용자가 고른다.

---

## B. 워커 절차 (`[team-handoff]` 메시지를 받은 pane)

### B1. 상태 수집

```bash
git rev-parse HEAD; git rev-parse --abbrev-ref HEAD; git status --short; git log --oneline -10; git diff --stat
my-team api mailbox-list --input '{"team_name":"<team>","worker":"<me>"}' --json   # sent_pending
```

이 세션의 대화에서 추출한다: 받은 티켓·지시, 끝낸 것, 남은 것, 사용자나 PM이 답해야 진행되는 것, 실패한 시도, 다른 워커와 주고받는 것.

### B2. 상태 파일 작성

메시지가 지정한 경로에 아래 「워커 상태 파일 템플릿」으로 쓴다. 원칙:

- **미완료는 상태 서술형.** "X를 구현한다" ❌ → "X 미구현. Y까지 됨" ✅. 재기동 후 워커가 검증 없이 실행하지 않게 하기 위해서다.
- **파일은 라인까지.** `Foo.kt` ❌ → `Foo.kt:L45-L72` ✅. 최대 8개.
- **함정은 비우지 않는다.** 실패가 없었으면 "없음"이라고 쓴다.
- **결정 필요에는 선택지와 트레이드오프를 붙인다.** 재기동 후 PM이 사용자에게 그대로 번호로 물을 수 있어야 한다.
- **미커밋 변경은 커밋하지 않는다.** 디스크에 남으니 의도만 적는다. 커밋·push는 요청받지 않았다.
- 자동 컨텍스트 압축이 이미 일어난 세션이면 `compacted: true`.

### B3. 회신

```bash
my-team api send-message --input '{"team_name":"<team>","from_worker":"<me>","to_worker":"<pm>","reply_to":"<message_id>",
 "body":"[team-handoff] <me>: <path>. 완료 <a>·미완료 <b>·결정 필요 <c>. <한 줄 요약>"}' --json
```

`mailbox-mark-delivered` 후 **새 작업을 시작하지 않는다.** 회신 후 코드가 움직이면 파일의 `head_commit`이 거짓이 된다. 사용자가 pane에서 직접 지시하면 따르되, PM에게 "회신 후 변경 있음"을 한 줄 알린다.

---

## team.md 템플릿

```markdown
---
team: <team>
created_at: <YYYY-MM-DD HH:MM:SS>
pm: <pm worker>
workers: [<w1>, <w2>, ...]
no_reply: [<미응답 워커>]
---

# Team handoff — <team> — <YYYY-MM-DD>

## 팀 국면
(1-3문장. 팀이 지금 무엇을 향해 어디까지 왔는가. 상태 서술형)

## 워커 요약
| 워커 | cwd | branch@head | dirty | 완료 | 미완료 | 결정 필요 | 파일 |
|---|---|---|---|---|---|---|---|

## 결정 필요 (사용자 답 필요)
### D1. <질문>
- 출처: <워커들>
- 선택지: 1) … (장단점) 2) … (장단점)
- 영향 워커: <워커> — 답이 없으면 막히는 항목
(없으면 "없음")

## 워커 간 의존 · 열린 질문
| 기다리는 쪽 | 기다리는 것 | 주는 쪽 | 상태(진행중/불일치/열린 질문) |
|---|---|---|---|

## PM 자신의 상태
- 미배분 작업, 들고 있던 계획, 사용자와 합의한 것 (Working Agreements)

## 팀 단위 함정
(여러 워커에 걸친 것만. 워커 개별 함정은 각 파일에)

## 재개 시 고려 순서 (참고, 실행 명령 아님)
- "D1이 풀리면 <w1>의 X가 먼저 가능할 수 있다" 같은 가능성 표현

## 미응답 워커
- <w>: git 상태만 기록 — <git status/log 요약>
```

## 워커 상태 파일 템플릿 (`workers/<w>.md`)

```markdown
---
worker: <w>
cwd: <abs path>
branch: <branch>
head_commit: <full sha>
dirty: true | false
compacted: false
---

# <w> — 상태

## 담당 (이번 세션에 받은 티켓·지시 요지)

## 완료
- <항목> — 증거: <커밋 sha / PR / 테스트 명령 → 결과>

## 미완료 (상태 서술형)
- <항목>: 현재 어디까지 / 남은 것 / 다음 후보 (가능성 표현)

## 결정 필요
- <질문> — 선택지 1) … 2) … / 누가 답해야 하나(사용자/PM/<워커>) / 막히는 항목

## 의존
- 기다림: <워커>의 <무엇>
- 제공 약속: <워커>에게 <무엇>

## 열린 질문 (sent_pending 포함)

## 함정 (없으면 "없음")
- ❌ <시도> — 실패 이유

## 미커밋 변경의 의도
- <파일> — 무엇을 하려던 변경인가

## Relevant Files (최대 8)
- `path:Lx-Ly` — 왜 중요한가
```

## 하지 말 것

- `my-team.json`에 작업 상태를 쓰지 않는다 — config는 재사용 정의다.
- PM이 미응답 워커의 상태를 추측으로 채우지 않는다 — git 사실만, `미응답` 표시.
- shutdown을 실행하지 않는다.
- 회신 메시지에 상태 본문을 싣지 않는다 — 경로와 한 줄만. 메시지는 shutdown과 함께 `.bak`으로 간다.
