---
name: my-team-closeout
description: my-team 워커의 작업 종결(closeout) 프로토콜 — 보고 → 검증 → 제거 또는 재개 브리프. 두 상황에서 반드시 사용한다. (1) 보고자: my-team 워커 pane에서 사용자가 "/my-team-closeout", "closeout", "마무리 보고해", "작업 끝났으니 PM(생성자)에게 보고하고 정리해", "이 워커 정리해"라고 하면, 자신을 생성한 워커(spawner, 보통 orchestrator)에게 증거 기반 완료 보고를 보낸다. (2) 수신자: 메일박스에 kind가 `closeout`인 메시지가 도착한 워커는 이 스킬의 수신자 절차로 처리한다 — 티켓과 대조 검증 후 전부 완료면 remove-worker + 종결 문서, 미완료면 다른 워커가 add-worker로 바로 이어받을 수 있는 재개 브리프를 쓴다(전임 유지). 단일 세션 인계용 /handoff·/takeover와 다르다 — 팀 메일박스·roster·remove-worker를 다루는 쪽이 이 스킬이다.
---

# my-team closeout — 워커 종결 보고 · 검증 · 제거/재개 브리프

워커가 "끝났다"고 말하는 것과 팀이 "끝났다"고 아는 것은 다르다. 이 스킬은 그 간극을 두 단계로 메운다.
**보고자**(워커)는 티켓의 산출물 하나하나에 재실행 가능한 증거를 붙여 보고하고, **수신자**(그 워커를 만든 쪽)는 그 증거를 자기 손으로 다시 확인한 뒤에만 pane을 닫는다. 검증 없이 제거하면 "완료"라는 한 단어에 팀 전체가 기대게 된다.

제거는 항상 수신자가 한다. `remove-worker`는 pane을 죽인 뒤 피어에게 이탈 통지를 보내므로 자기 자신을 제거하면 통지 전에 죽는다.

**작업판 팀**(팀 config에 `board`가 있는 팀)에서는 작업 상태와 판정이 작업판에 있다. 아래 절차를 이렇게 바꿔 읽는다.

- 보고자는 맡은 작업을 `board-land`로 제출하고 판정을 받은 뒤에 A 절차를 시작한다. `changes` 판정을 고치는 일은 새 작업이 아니라 맡은 작업의 일부다(A5의 "새 작업 금지"에 걸리지 않는다).
- A1의 티켓은 메시지가 아니라 작업의 `ticket` 파일이다. A4의 `reply_to`는 뺀다.
- 보고서의 산출물 대조에는 작업 id와 그 판정(`board-status`에 `task`를 준 결과)을 적는다. 작업 상태를 메시지 본문에 다시 풀어 쓰지 않는다.
- 수신자는 B1에서 티켓을 `board-status`로 찾고, B2에서 작업판의 판정부터 읽는다. `review`인 작업은 미완료가 아니라 판정 대기다. 재개 브리프를 쓰지 않고 판정을 기다린다. approve가 아닌 판정이 남은 작업만 미완료로 본다.
- 재개 브리프의 후임 투입 초안에는 메시지로 완료를 보고하라는 문장 대신, 자기 AGENTS.md Rules의 add-worker Spawn protocol 문장(작업판용)을 쓴다. 후임의 일은 pm이 작업판에 올린다.

## 0. 공통 — 컨텍스트 추출

```bash
# <skill-dir> = 이 스킬이 로드될 때 안내되는 "Base directory for this skill"
<skill-dir>/scripts/closeout-context.sh            # 보고자: 자기 자신
<skill-dir>/scripts/closeout-context.sh <worker>   # 수신자: 보고해 온 워커
```

읽기 전용이다. 팀·생성자(`spawner`: Role Context의 "Spawned by X" / "Message X ONLY", 없으면 roster의 orchestrator)·수신했던 티켓 목록·`sent_pending`·status·보고서 경로·git 상태를 JSON으로 준다. `ok:false`면 my-team 워커 pane이 아니다 — 그 사실만 알리고 중단한다.

---

## A. 보고자 절차 (워커 pane에서 사용자가 호출)

### A1. 티켓 확정

`tickets[]`에서 이번 작업의 티켓(생성자가 kind `question`으로 보낸 메시지)을 고른다. 여러 건이면 사용자에게 어느 것인지 묻는다. 티켓 본문과 거기 적힌 문서 경로를 다시 읽어 **요구된 산출물 목록**을 뽑는다. 작업 중 기억이 아니라 티켓 원문 기준이다 — 중간에 범위가 바뀌었으면 그 사실도 산출물 행으로 적는다.

### A2. 검증표 작성

산출물 하나당 한 행. 각 행의 증거는 **수신자가 그대로 재실행할 수 있는 명령 또는 열어볼 수 있는 경로**여야 한다. "테스트 통과함"은 증거가 아니고 `./gradlew :api:test → BUILD SUCCESSFUL, 157건`이 증거다. 증거를 못 붙이는 행은 상태를 `미검증`으로 둔다. 미검증은 완료가 아니다.

추가로 항상 확인하는 네 가지: `sent_pending`이 비었는가(답 안 받은 질문이 남으면 끝난 게 아니다), 작업 트리가 깨끗하고 push됐는가(`git.dirty`, `ahead_behind`), 티켓 범위 밖에서 발견해 손대지 않은 것이 무엇인가, 사용자·수신자가 아직 해야 할 일(머지·배포·수동 실행)이 무엇인가.

### A3. 보고서 파일 작성

경로는 스크립트가 준 `report_path`(`$MY_TEAM_STATE_ROOT/workers/<me>/closeout-report.md`). 워크트리가 아니라 팀 state 디렉터리에 두는 이유는, 워커가 제거돼도 mailbox·archive와 함께 남기 때문이다. 템플릿은 아래 「보고서 템플릿」.

### A4. 보고 전송

```bash
my-team api send-message --input '{"team_name":"<team>","from_worker":"<me>","to_worker":"<spawner>","kind":"closeout","reply_to":"<ticket message_id>",
 "body":"<me>: 주장=완료|미완료, 산출물 <N>건 중 완료 <k>·미완료 <m>·미검증 <u>. 보고서=<report_path>. 수신 절차=my-team-closeout 스킬 §B. 미완료 요지: <한 줄, 없으면 없음>"}' --json
```

`kind: closeout`으로 수신자가 일반 보고와 구분한다. `reply_to`를 티켓에 걸어야 수신자의 `sent_pending`에서 그 티켓이 닫힌다. closeout은 질문처럼 내 `sent_pending`에 남아 수신자의 판정(제거 또는 브리프 경로)을 기다린다.

### A5. 전송 후

status.json을 갱신한다: 완료 주장이면 `{"state":"done","reason":"closeout 보고, 검증 대기"}`, 미완료 주장이면 `state:"idle"`에 미완료 요지를 적는다. 이후 **새 작업을 시작하지 않는다.** 수신자의 질문에 답하는 것만 한다 — 수신자가 재검증하는 동안 코드가 움직이면 검증이 무효가 된다. 사용자가 pane에서 새 지시를 주면 그때는 따른다(closeout은 자동 취소되므로 수신자에게 한 줄 알린다).

---

## B. 수신자 절차 (kind `closeout` 메시지를 받은 pane)

### B1. 자료 모으기

`closeout-context.sh <worker>`로 그 워커의 상태를 보고, 메시지의 `reply_to`로 원 티켓을 `archive-lookup`하고, `report_path`의 보고서를 읽는다. 티켓에 적힌 문서(PROMPT·HANDOFF 등)도 다시 연다. 수신자는 티켓을 쓴 쪽이라 요구사항의 의도를 가장 잘 안다 — 보고서의 산출물 목록을 그대로 받지 말고 **티켓에서 자기 손으로 목록을 다시 뽑아** 보고서와 대조한다. 빠진 행이 가장 흔한 누락이다.

### B2. 독립 검증

보고서의 행마다 증거를 **직접 재실행하거나 열어본다**(git log origin/<branch>, PR 상태 API, 파일 존재, 테스트 결과 XML, 문서 내용). 판정은 세 값뿐이다:

- `완료` — 수신자가 확인함
- `미완료` — 요구와 다르거나 남은 일이 있음
- `검증불가` — 증거가 없거나 수신자 환경에서 재현 못 함

**검증불가는 제거 판단에서 미완료로 친다.** 워커의 말만으로 pane을 닫지 않기 위해서다. 보고서와 수신자 판정이 어긋나는 행이 있으면 질문을 **한 통에 묶어** kind `question`으로 보내고 답을 받아 재판정한다. 한 왕복으로 해소되지 않는 행은 미완료로 두고 브리프에 그 경위를 적는다 — 끝없이 핑퐁하는 것보다 사용자가 보고 결정하는 편이 빠르다.

### B3-a. 전부 완료 → 종결 문서 → 제거

1. 「종결 문서 템플릿」으로 `<docs>/closeouts/<YYYY-MM-DD>-<worker>-DONE.md`를 쓴다(위치 규칙은 아래). 팀의 기억은 이 파일이다 — 워커의 pane·컨텍스트는 곧 사라진다.
2. `mailbox-mark-delivered`로 closeout 메시지를 소비한다.
3. `my-team remove-worker --team <team> --name <worker>` 실행. 워커에게 따로 답장하지 않는다 — 제거가 곧 답이고, 이탈 통지는 CLI가 보낸다.
4. 이 pane stdout에 한 줄: 누구의 무슨 작업이 끝났고 문서가 어디 있는지. 워크트리(`.worktrees/<worker>`)와 브랜치 정리는 사용자 몫이므로 같이 적는다.

### B3-b. 미완료 있음 → 재개 브리프 → 전임 유지

1. 「재개 브리프 템플릿」으로 `<docs>/closeouts/<YYYY-MM-DD>-<worker>-RESUME.md`를 쓴다. 기준은 하나다: **이 파일과 코드만 가진 새 워커가 질문 없이 첫 커밋을 만들 수 있는가.** 미완료 항목마다 현재 상태·다음 액션·입력 경로·검증 방법·블로커·실행 주체를 적고, `add-worker --extra-prompt`에 그대로 넣을 수 있는 브리프 초안과 티켓 초안까지 포함한다. 완료된 행도 요약으로 남긴다 — 후임이 끝난 일을 다시 하지 않도록.
2. 워커에게 kind `answer`와 `reply_to`로 답한다: 판정 결과(완료 k·미완료 m·검증불가 u), 브리프 경로, "pane 유지 — 추가 지시 대기". 후임 `add-worker`는 **하지 않는다.** 재개 시점·범위·누가 할지는 사용자 결정이다.
3. `mailbox-mark-delivered`. stdout에 미완료 건수와 브리프 경로를 적어 사용자가 결정할 수 있게 한다.

---

## 문서 위치 규칙 `<docs>`

1. 티켓이 가리킨 문서(PROMPT·HANDOFF·REPORT 등)가 있는 디렉터리가 있으면 그 디렉터리. 티켓과 종결이 한 곳에 모여야 다음에 찾는다.
2. 없으면 수신자 cwd의 `docs/team/`.
`closeouts/` 하위 디렉터리는 없으면 만든다. 파일명은 날짜가 맨 앞이라 글롭·정렬로 찾힌다.

---

## 보고서 템플릿 (보고자 → `closeout-report.md`)

```markdown
# Closeout report — <worker> — <YYYY-MM-DD>
ticket: <message_id> from <spawner> (<created_at>) · 티켓 문서: <경로들>
claim: 완료 | 미완료
cwd: <cwd> · branch: <branch>@<head> · dirty: no · push: 완료
## 산출물 대조
| # | 티켓 요구 | 상태(완료/미완료/미검증) | 증거 — 재실행 명령 또는 경로 → 기대 결과 |
|---|---|---|---|
## 결정·가정 (PR 본문·보고 문서에 없는 것만)
## 미완료 · 범위 밖 · 남이 해야 할 일
- <항목>: 현재 상태 / 다음 액션 / 입력 경로 / 검증법 / 블로커 / 주체(사용자·SRE·다른 팀)
## 함정 (이번에 시간을 먹은 것 — 없으면 "없음"이라고 쓴다)
## 수신자가 재실행할 검증 명령
```

## 종결 문서 템플릿 (수신자 → `*-DONE.md`)

```markdown
# Closeout — <worker> — <티켓 한 줄> — <YYYY-MM-DD>
ticket: <message_id> · 보고서: <report_path> · 검증자: <수신자>
## 결과
- 산출물: PR/커밋/문서 경로 (상태: 머지됨/OPEN 등)
- 검증: 행별 판정과 수신자가 직접 확인한 방법
## 결정 (정본에 반영할 것 — 반영했으면 어디에)
## 남은 운영 작업 (사용자·SRE 등 코드 밖 — 주체와 선행조건)
## 정리
- remove-worker 실행 시각 · 워크트리/브랜치 정리는 사용자 몫
```

## 재개 브리프 템플릿 (수신자 → `*-RESUME.md`)

```markdown
# Resume brief — <worker> 작업 — <YYYY-MM-DD>
ticket: <message_id> · 원 티켓 문서: <경로> · 전임 보고서: <report_path> · 전임 pane: 유지 중
## 목표 (티켓 원문 기준, 바뀐 범위 포함)
## 완료된 것 (후임이 다시 하지 않도록 — 증거 포함)
## 미완료 항목
### <항목 1>
- 현재 상태: (코드·문서·외부 시스템이 지금 어떤가 — 사실만)
- 다음 액션: (첫 번째로 할 구체 행동)
- 입력: (파일:라인, 문서 경로, 명령)
- 검증: (끝났음을 어떻게 확인하는가 — 명령·기대 출력)
- 블로커·선행조건: (무엇이 풀려야 하는가, 누가)
- 주체: 후임 워커 | 사용자 | 외부
## 환경
cwd · branch@head · 워크트리 여부 · 빌드/테스트 명령 · 이번 작업에서 걸린 함정
## 후임 투입 초안 (사용자가 결정하면 그대로 사용)
- add-worker: `my-team add-worker --team <team> --name <worker>-2 --agent-type <type> --cwd <repo> --worktree <branch> --description "<한 줄>" --extra-prompt "Spawned by <수신자>. 이 브리프 <경로>를 먼저 읽는다. Message <수신자> ONLY (a) 결정 필요 시 kind question 1통 (b) 완료 시 티켓에 kind answer·reply_to 로 최종 보고 1회."`
- 티켓 초안: 목표 + 입력 경로 + 산출물 + "완료 시 이 메시지에 reply_to"
## 미해결 질문 (사용자 답 필요)
```

---

## 하지 말 것

- 보고자가 자기 자신을 `remove-worker`하지 않는다 — 통지 전에 pane이 죽는다.
- 수신자가 보고서의 "완료"를 재확인 없이 받아들이지 않는다 — 검증불가는 미완료다.
- 미완료인데 후임을 자동으로 띄우지 않는다 — 비용과 범위는 사용자 결정이다.
- 보고서 본문을 메시지에 싣지 않는다 — 경로만. 메시지는 delivered 후 아카이브로 빠지고, 파일은 남는다.
- `/handoff`·`/takeover`로 대체하지 않는다 — 그쪽은 같은 pane의 다음 세션용이고, 여기는 다른 pane에 결과를 넘기고 roster를 바꾸는 절차다.
