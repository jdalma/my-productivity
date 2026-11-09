---
name: my-team-takeover
description: /my-team-handoff로 저장한 팀 handoff 묶음(~/.my-team/handoffs/{team}/)을 재기동된 팀의 PM(orchestrator)이 로드·검증하고, 결정 필요 항목을 사용자와 정리한 뒤 워커별 재개 브리프를 메일박스로 전달한다. 두 상황에서 반드시 사용한다. (1) PM — 같은 config로 my-team start 한 뒤 PM pane에서 사용자가 "/my-team-takeover", "팀 takeover", "지난번 팀 작업 이어서", "handoff 로드해서 워커들한테 나눠줘" 라고 하면 실행한다. (2) 워커 — 메일박스에 본문이 `[team-takeover]`로 시작하는 메시지가 도착한 워커는 이 스킬의 §B 절차로 브리프를 받아 재개한다. 단일 pane의 /takeover나 워커 1명 복구(/my-team-resume)와 다르다 — 팀 전체 재기동 후의 로드 전용이다.
---

# my-team takeover — 팀 재기동 후 로드 · 검증 · 재배분

`/my-team-handoff`가 shutdown 전에 남긴 묶음을 받아, **PM이 분석하고 워커에게 나눠준다.** 워커가 각자 묶음을 뒤지지 않는다. PM은 팀 전체의 의존과 결정을 보고 있으므로, 결정이 정리된 뒤 워커별로 필요한 것만 전달하는 편이 충돌이 적다.

묶음은 hypothesis다. shutdown과 start 사이에 사용자가 커밋·rebase·머지했을 수 있다. git과 대조하기 전에는 아무것도 워커에게 보내지 않는다.

## 0. 공통 — 정체 확인

```bash
echo "worker=$MY_TEAM_WORKER state_root=$MY_TEAM_STATE_ROOT"
```

비어 있으면 my-team 워커 pane이 아니다 — 알리고 중단한다.
`[team-takeover]` 메시지로 호출됐으면 **§B**, 사용자가 호출했으면 **§A**.

---

## A. PM 절차

### A1. 묶음 선택

```bash
TEAM="${MY_TEAM_WORKER%%/*}"; ME="${MY_TEAM_WORKER#*/}"
ls -td "$HOME/.my-team/handoffs/$TEAM"/*/ 2>/dev/null | head -5
```

- 사용자가 경로를 인자로 줬으면 그것을 쓴다.
- 1개면 자동 선택하고 알린다. 여러 개면 최신부터 번호로 제시한다 (최신 외는 보통 이미 소비된 묶음).
- 없으면 "`<team>` handoff 묶음 없음"을 보고하고 종료한다. 팀 이름이 바뀌었을 수 있으니 `ls ~/.my-team/handoffs/`도 함께 보여준다.

### A2. 읽기

`team.md`와 `workers/*.md` 전부를 읽는다. `compacted: true`인 워커 파일은 라인 번호·함정의 정확도를 낮게 본다.

### A3. 로스터 대조

```bash
python3 -c "import json;[print(w['name'],w['cwd']) for w in json.load(open('$MY_TEAM_STATE_ROOT/manifest.json'))['workers']]"
```

| 상황 | 처리 |
|---|---|
| 묶음과 현재 roster 모두에 있음 | 정상 — A4 검증 대상 |
| 묶음에만 있음 (지난번 `add-worker`로 합류했거나 config에서 빠짐) | 사용자에게 보고. 이어받을 워커를 띄울지는 사용자 결정 — `add-worker` 명령 초안만 제시하고 실행하지 않는다 |
| roster에만 있음 | 새 워커. 받을 상태 없음 — 브리프 대상에서 제외하고 보고만 |
| cwd가 묶음과 다름 | 같은 이름이라도 다른 워크스페이스. 검증은 현재 cwd 기준으로 하고 불일치를 보고 |

### A4. 워커별 git 검증

워커마다 현재 cwd에서 PM이 직접 확인한다:

```bash
C=<cwd>; H=<head_commit>
git -C "$C" cat-file -e "$H" 2>&1                               # 없음 → rebase/force-push. 라인 번호 전부 의심
git -C "$C" rev-parse --abbrev-ref HEAD                          # 파일의 branch와 비교
git -C "$C" log --oneline "$H"..HEAD                             # shutdown 이후 추가 커밋
git -C "$C" log --oneline "$H"..HEAD -- <Relevant Files 경로들>   # 그 중 Relevant Files를 건드린 것
git -C "$C" status --short                                       # 파일의 dirty·미커밋 의도와 비교
```

판정: `유효` / `부분 stale (<파일들>)` / `stale (head 소실)`. 추가 커밋이 미완료 항목을 이미 처리한 것으로 보이면 `처리됨 추정`으로 적는다 — 워커가 같은 일을 다시 하지 않게.

### A5. 사용자에게 보고하고 결정 받기

```markdown
## Team takeover — <team> — 묶음 <bundle 경로> (<N>일 전)

### 워커별 검증
| 워커 | 판정 | 미완료 | 결정 필요 | 비고 |
|---|---|---|---|---|

### 로스터 차이
(없으면 "없음")

### 결정 필요
D1. <질문> (출처 <워커>, 막히는 것 <항목>)
  1) … — 장단점
  2) … — 장단점

### 의존 · 열린 질문
(team.md의 표 중 아직 유효한 것)
```

결정 필요가 있으면 번호로 답을 받는다. 사용자가 일부를 보류하면 그 결정에 막힌 항목은 브리프에서 `보류`로 표시한다. 결정이 없어도 **사용자가 "전달해"라고 하기 전에는 A6으로 가지 않는다.** 재배분 범위(누구를 먼저 재개할지, 어떤 항목을 버릴지)는 사용자 몫이다.

### A6. 워커별 브리프 전달

워커마다 한 통:

```bash
my-team api send-message --input '{"team_name":"<team>","from_worker":"<me>","to_worker":"<w>",
 "body":"[team-takeover] 상태 파일=<bundle>/workers/<w>.md. 수신 절차=my-team-takeover 스킬 §B.\nPM 검증: <유효|부분 stale: 파일들|stale>. shutdown 이후 커밋: <없음|요약>.\n재개 범위: <항목들>\n보류: <항목> (D<n> 미결)\n결정 반영: D<n>=<답> → <영향>\n의존: <누구>의 <무엇> 대기 / <누구>에게 <무엇> 제공\n처리됨 추정(재작업 금지): <항목>"}' --json
```

원칙:
- **경로 + PM 분석만.** 상태 파일 본문은 복사하지 않는다 — 워커가 읽는다.
- **그 워커에 해당하는 결정만.** 팀 전체 결정 목록을 뿌리지 않는다.
- 사용자가 재개하지 않기로 한 워커에게는 보내지 않는다.
- `expects_reply`는 끈다. 워커가 상태 파일과 코드의 어긋남을 발견하면 그때 워커가 질문한다.

### A7. 종료 보고

pane에 한 줄씩: 브리프 보낸 워커, 보류·미배분 항목, 사용자 몫(로스터 차이 대응 등). 묶음 파일은 수정하지 않는다 — 다음 `/my-team-handoff`가 새 묶음을 만든다.

---

## B. 워커 절차 (`[team-takeover]` 메시지를 받은 pane)

1. 메시지가 가리킨 상태 파일을 읽는다. PM의 메시지가 파일보다 우선한다 — 결정 반영·보류·처리됨 추정은 PM이 사용자와 정리한 최신 정보다.
2. Relevant Files를 실제로 열어 파일의 서술과 대조한다. 특히 PM이 `부분 stale`로 지목한 파일.
3. 어긋남이 작업 전제를 바꾸면 PM에게 `expects_reply`로 한 통에 묶어 묻고, 답이 올 때까지 그 항목은 손대지 않는다. 사소한 라인 drift는 묻지 않고 넘어간다.
4. `mailbox-mark-delivered` 후 **재개 범위**에 있는 항목만 진행한다. 보류 항목은 시작하지 않는다.
5. pane에 한 줄: 무엇부터 재개하는지.

---

## 하지 말 것

- git 검증 전에 워커에게 브리프를 보내지 않는다.
- 사용자 승인 없이 결정 필요 항목을 PM이 대신 결정하지 않는다.
- 묶음에만 있는 워커를 자동으로 `add-worker`하지 않는다.
- `my-team.json`을 수정하지 않는다 — config는 재사용 정의다.
- 묶음 파일을 수정하지 않는다 — 기록이다.
