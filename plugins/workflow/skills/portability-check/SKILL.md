---
name: portability-check
description: 스킬 SKILL.md가 CLI-중립(claude/codex/gemini 공통 복사 가능)인지 검사해 A/B/C 등급과 SSOT 적격 여부를 산출한다. 사용자가 "/portability-check" 슬래시 호출 또는 "스킬 이식성 검사", "SSOT 적격 판정", "이 스킬 codex에서도 도나" 같이 명시 의도를 표현했을 때만 사용. 런타임 종속 신호(subagent_type, context fork, mcp__, oh-my-claudecode/omc 위임, 레포-로컬 CLI 바이너리)를 grep으로 탐지한다. 자동 호출·자동 제안 금지.
disable-model-invocation: true
---

# portability-check — CLI-중립 SSOT 린터

> 순수 마크다운 `SKILL.md`가 **claude/codex/gemini에 그대로 복사해도 도는가**를 검사한다.
> "복사했는데 안 도는 스킬"을 SSOT에 섞기 전에 차단하는 것이 유일한 목적이다.

## ⛔ 호출 규칙

이 스킬은 **사용자가 `/portability-check`를 슬래시로 호출했거나, "스킬 이식성 검사"·"SSOT 적격 판정" 같이 명시 의도를 표현했을 때만** 동작한다.

- ❌ 스킬을 수정·작성하는 흐름에서 자동 실행 금지
- ❌ "이식성 검사할까요?" 식 선제 권유 금지
- ✅ 사용자 명시 호출·지명 시에만 실행

## When to use

- 새 스킬을 SSOT(CLI-중립) 디렉토리에 등록하기 전에 **CLI-중립인지 보증**하고 싶을 때
- 기존 스킬이 codex/gemini로 복사 가능한지(A/B/C) 판정하고 싶을 때
- 외부 sync 도구에 넘길 "깨끗한 디렉토리"를 골라내고 싶을 때

## Input

`/portability-check [path]` — `path`는 검사 대상 디렉토리(기본값: `plugins/workflow/skills`).
대상은 그 아래의 모든 `SKILL.md` 파일이다.

## 판별 기준 (요약)

상세 신호표·등급 루브릭·행동언어 작성 예시는 **단일 출처**인
[`references/signals.md`](references/signals.md)에 있다. 본문은 그 요약만 둔다.

- **L0~L1** (순수 지식 + 파일/bash/grep): 세 CLI 공통 → **SSOT 적격**
- **L2** (서브에이전트·Skill 체이닝·`context: fork`): codex/gemini 부분 지원 → 추상화 시 가능
- **L3** (`mcp__*`, `omc:*`, `--fork-session`): Claude 전용 → **부적격**

## 워크플로우 단계

### 1단계 — 신호 탐지 (grep)

대상 디렉토리의 각 `SKILL.md`에 대해 L2/L3 신호를 grep한다.
`PATH`는 사용자가 준 경로(없으면 기본값)로 치환한다.

```bash
PATH_ARG="${1:-plugins/workflow/skills}"
# L3 — Claude/MCP/레포-로컬 바이너리 전용 (부적격 신호)
L3='mcp__|(oh-my-claudecode|omc):|--fork-session|command -v (my-team|my-team-install)|tools/my-team'
# L2 — 서브에이전트/세션 모델 (추상화 시 가능)
L2='subagent_type|context:[[:space:]]*fork|Agent\(|Task tool|Skill tool|TeamCreate'
# 강등 보조 — context:fork 와 함께 있으면 forked 전용 서브스킬로 C 강등 (2단계 참조)
DEMOTE='user-invocable:[[:space:]]*false'

# grep -i: 대소문자 변형(Subagent_Type, OMC:, Task Tool …)을 놓치지 않기 위해 필수.
# 린터 자신은 신호 문자열을 '데이터'로 담으므로 스캔에서 제외한다 (아래 주의 참조).
find "$PATH_ARG" -name SKILL.md -print | grep -v '/portability-check/' | sort | while read -r f; do
  echo "=== $f ==="
  echo "-- L3 --";     grep -niE "$L3" "$f" || echo "(none)"
  echo "-- L2 --";     grep -niE "$L2" "$f" || echo "(none)"
  echo "-- DEMOTE --"; grep -niE "$DEMOTE" "$f" || echo "(none)"
done
```

> grep 한 줄이 본질적으로 작아 본문에 임베드한다. 신호 목록은 `references/signals.md`가
> 단일 출처이므로, 별도 셸 스크립트로 중복하지 않는다 (CLAUDE.md "단순함 우선").
> 이 grep의 L3/L2/DEMOTE 정규식은 `references/signals.md` §2와 글자 단위로 일치해야 한다 —
> 한쪽만 고치면 drift가 난다.
>
> **주의 — 린터 자기 제외**: `portability-check` 자신의 `SKILL.md`/`references/signals.md`는
> 신호 정규식(`mcp__`, `omc:` …)을 *탐지 대상 데이터*로 담고 있어 grep에 걸린다.
> 이는 런타임 종속이 아니라 신호 목록 자체이므로 **린터는 자기 디렉토리를 스캔하지 않는다**
> (`grep -v '/portability-check/'`). 린터는 가드이지 가드의 대상이 아니다.

### 2단계 — 등급 산출

파일별로 1단계 결과를 [`references/signals.md`](references/signals.md)의 루브릭에 대입한다:

| 발견된 신호 | 등급 | SSOT 적격 |
|---|---|---|
| L2·L3 **0건** | **A** | ✅ 적격 (그대로 복사 가능) |
| L2만 있음 (L3 0건) | **B** | ⚠️ 추상화 시 가능 (행동언어로 재작성 필요) |
| L3 **1건 이상** | **C** | ❌ 부적격 (Claude/MCP/레포-로컬 바이너리 종속) |

판정은 1단계 출력만으로 자동 산출한다 (의사코드: `references/signals.md` §3):

```
if   L3 매칭 ≥ 1:                              → C  (런타임/바이너리 종속)
elif (L2에 context:fork 매칭) and (DEMOTE 매칭): → C  (forked 전용 서브스킬 강등)
elif L2 매칭 ≥ 1:                              → B  (행동언어 재작성 시 가능)
else:                                          → A  (CLI-중립)
```

> **강등 규칙** — `context: fork`(L2) **와** `user-invocable: false`(DEMOTE)가 **둘 다** 잡히면,
> 상위 스킬이 체이닝으로만 호출하는 forked 전용 서브스킬이라 standalone SSOT가 될 수 없다 → **C 강등**.
> DEMOTE 신호를 1단계 grep이 자동 수집하므로 frontmatter를 따로 다시 읽을 필요가 없다.

### 3단계 — 결과 리포트

파일별로 다음 형식으로 보고한다:

```
[등급] <skill-name>   — SSOT <적격|부적격>
  발견 신호:
    L3: <매칭된 줄 또는 (none)>
    L2: <매칭된 줄 또는 (none)>
  판정 근거: <왜 이 등급인지 한 줄>
```

마지막에 요약 한 줄을 덧붙인다:
`총 N개 — A: a개(적격), B: b개, C: c개(부적격)`.
B/C에는 무엇을 고쳐야 적격이 되는지 한 줄 가이드를 단다 (L2→행동언어 재작성, L3→이식 불가).

### 4단계 — 신규 스킬 작성 가이드

C/B 판정이 나왔거나 새 스킬을 SSOT로 만들려는 경우, 특정 도구명 대신
**행동 언어**로 재작성하도록 안내한다 (예: `Agent(subagent_type=executor)` 대신
"서브에이전트를 띄워 ~를 시켜라"). 예시는 `references/signals.md` 참조.

## 참고 — 표현 계층 선택 근거

이 린터는 셸 스크립트가 아니라 **markdown 스킬 + 임베드 grep**이다.
load-bearing한 부분은 파일 스캔(L1 `grep`)이 아니라 **정적 지식**(신호 목록·등급 루브릭)이며,
CLAUDE.md "자산 표현 계층 우선순위"가 Skill(런타임 비용 0) > CLI tool(`tools/`) > Hook 순으로
둔다. 별도 `tools/*.sh`로 빼면 신호 목록이 SSOT 밖에서 중복되고(스킬↔스크립트 동기화 부담),
새 세션 rsync 반영도 잃는다 — "단순함 우선"이 경고하는 오버엔지니어링이다.
