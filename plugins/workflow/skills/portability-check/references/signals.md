# 런타임 의존성 계층 · 신호→등급 루브릭 · 행동언어 가이드

> 이 파일이 **CLI-중립 판별 신호 목록의 단일 출처(SSOT)**다.
> 셸 스크립트로 같은 목록을 중복 보관하지 않는 이유: 신호가 두 곳에 있으면 한쪽만
> 갱신되어 어긋난다(스킬↔스크립트 drift). grep은 L1 도구라 스킬 본문에서 바로 구동하면 되고,
> "무엇을 grep할지"라는 정적 지식만 여기에 둔다.

## 1. 런타임 의존성 계층 (spec §5)

스킬이 의존하는 능력을 4계층으로 나눈다. **L0~L1만 SSOT 적격**이다.

| 계층 | 본문에 등장하는 신호 | Claude | Codex | Gemini |
|---|---|---|---|---|
| **L0** 순수 지식 | 워크플로우·체크리스트·원칙·판단 기준 | ✅ | ✅ | ✅ |
| **L1** 기본 도구 | 파일 읽기/쓰기, bash, grep | ✅ | ✅ | ✅ |
| **L2** 서브에이전트 | `subagent_type`, `context: fork`, `Agent(`, `Task tool`, `Skill tool` 체이닝, `TeamCreate` | ✅ | ⚠️ 부분 | ⚠️ `activate_skill` |
| **L3** Claude/MCP/레포-로컬 종속 | `mcp__*`, `omc:*`/`oh-my-claudecode:*` 위임, `--fork-session`, **레포 로컬 CLI 바이너리 의존** | ✅ | ❌ | ❌ |

- **L2**는 세 CLI가 의미는 비슷하나 호출 표면이 달라(`Agent(` vs `activate_skill`),
  특정 도구명을 그대로 쓰면 codex/gemini에서 깨진다. **행동 언어로 추상화하면 이식 가능**(→ B).
- **L3**는 Claude(또는 OMC) 런타임, 혹은 **이 레포에만 있는 CLI 바이너리**에 종속된다.
  복사해도 대상 환경에 그 능력/바이너리가 없다 → **부적격(C)**.
  - 레포 로컬 바이너리 의존이란: `command -v <bin>`으로 선행조건을 검사하거나,
    `tools/` 아래 npm 패키지를 호출하거나, `/<x>-install` 같은 설치 선행 스킬을 전제하는 경우.
    예: `my-team`(tools/my-team CLI + tmux), `my-team-install`. 대상 CLI에 그 바이너리가
    PATH에 없으면 본문 지시가 동작하지 않으므로 "그대로 복사 가능(A)"이 거짓이 된다.

## 2. 탐지 신호 (정규식)

grep `-Ei`(POSIX ERE + 대소문자 무시) 기준. 본문 어디든(frontmatter 포함) 매칭되면 해당 계층으로 친다.
**`-i`(대소문자 무시)는 필수** — `Subagent_Type`·`OMC:`·`MCP__`·`Task Tool` 같은 변형 표기를
놓치면 부적격 스킬이 A로 새기 때문이다.

### L3 (부적격 신호 — 1건이라도 있으면 C)
```
mcp__|(oh-my-claudecode|omc):|--fork-session|command -v (my-team|my-team-install)|tools/my-team
```
- `mcp__` — MCP 서버 도구 직접 호출 (예: `mcp__vault-decision__advise`).
- `(oh-my-claudecode|omc):` — OMC 에이전트/스킬 위임. **정식 표기 `oh-my-claudecode:`와
  축약 `omc:` 둘 다** 매칭해야 한다 (이 환경의 표준 호출은 정식 표기다 — 예 `/oh-my-claudecode:team`).
- `--fork-session` — Claude 세션 포크 플래그.
- `command -v <bin>` / `tools/my-team` — **레포 로컬 CLI 바이너리 의존** (§1 참조).
  새 로컬 바이너리 도구가 생기면 이 그룹에 추가한다. 일반 원칙: 본문에 `command -v <자체바이너리>`
  선행조건 검사가 있으면 그 스킬은 대상 환경에 그 바이너리가 없을 때 깨지므로 C다.

### L2 (서브에이전트/세션 모델 — L3가 없을 때 B)
```
subagent_type|context:[[:space:]]*fork|Agent\(|Task tool|Skill tool|TeamCreate
```
- `subagent_type` — Task 도구의 서브에이전트 지정 인자.
- `context:\s*fork` — frontmatter의 서브에이전트 격리 실행 선언.
- `Agent\(` — 에이전트 호출 구문 (`-i`로 `agent(`도 매칭. 일반 영어 "agent("는 SKILL.md 본문에
  드물어 오탐 위험 < false negative 위험).
- `Task tool` / `Skill tool` — Claude 도구를 이름으로 지목한 체이닝 지시.
- `TeamCreate` — 팀 오케스트레이션 도구.

### 강등 보조 신호 (등급 자체는 아니나, 강등 규칙 §3에 필요)
```
user-invocable:[[:space:]]*false
```
- frontmatter에서 `user-invocable: false`를 자동 수집한다. `context: fork`와 **함께** 있으면
  forked 전용 서브스킬로 C 강등(§3). 이 신호가 Step 1 grep에 빠지면 강등이 자동화되지 않는다.

## 3. 신호 → 등급 매핑 루브릭

| 조건 | 등급 | SSOT 적격 | 의미 |
|---|---|---|---|
| L2·L3 매칭 0건 | **A** | ✅ 적격 | 순수 L0~L1. 어떤 sync 도구든 그대로 복사 가능 |
| L3 0건 + L2 ≥ 1건 | **B** | ⚠️ 조건부 | 추상화(행동언어)하면 이식 가능. 지금 그대로는 깨짐 |
| L3 ≥ 1건 | **C** | ❌ 부적격 | Claude/MCP 런타임 종속. 플러그인에만 남김 |

### 강등 규칙 — forked 전용 서브스킬

`context: fork` **와** `user-invocable: false`가 **둘 다** 있는 스킬은,
신호가 L2뿐이어도 **C로 강등**한다.

- 근거: 이 조합은 "상위 스킬이 Skill tool로만 호출하는 내부 서브스킬"을 뜻한다
  (예: `session-digest`). 단독으로는 절대 호출되지 않으므로
  standalone SSOT 스킬이 될 수 없고, codex/gemini로 복사해도 그를 호출할 상위 체이닝이 없다.
- 즉 "추상화하면 됨(B)"이 아니라 **존재 형태 자체가 Claude 서브에이전트 모델에 묶여 있음(C)**.

### 판정 흐름 (의사코드)
```
if L3 매칭 ≥ 1:                                → C (부적격: 런타임/바이너리 종속)
elif (L2의 context:fork) and (DEMOTE user-invocable:false): → C (부적격: forked 전용 서브스킬)
elif L2 매칭 ≥ 1:                              → B (조건부: 행동언어 재작성 시 가능)
else:                                          → A (적격: CLI-중립)
```
두 강등 조건(`context:fork`, `user-invocable:false`)은 모두 Step 1 grep이 자동 수집한다
(L2 정규식 + DEMOTE 정규식). 실행자가 frontmatter를 수동 재독할 필요가 없다.

## 4. 행동 언어 작성 가이드 (B → A로 가는 길)

L2 신호는 **특정 도구명을 행동 서술로 바꾸면** 사라진다. superpowers 계열 스킬이 쓰는 기법이다.

| 깨지는 표현 (도구명 직접) | CLI-중립 표현 (행동 언어) |
|---|---|
| `Agent(subagent_type=executor)로 구현시켜라` | 서브에이전트를 띄워 구현을 위임하라 |
| `Task tool로 병렬 실행` | 독립 작업을 병렬 서브에이전트로 나눠 실행하라 |
| `Skill tool로 X 스킬 체이닝` | X 절차를 (가능하면 격리된 컨텍스트에서) 수행하라 |

핵심: **"무엇을 시킬지"(행동)는 남기고, "어느 도구로"(CLI 고유 호출 표면)는 지운다.**
그러면 claude는 자기 Task/Agent로, codex/gemini는 각자의 서브에이전트 기능으로 해석한다.

> L3 신호는 행동 언어로도 못 구한다 — MCP 서버/OMC 에이전트라는 **능력 자체**가
> 대상 CLI에 없기 때문이다. L3 스킬은 Claude 플러그인 전용으로 남기는 것이 정답이다 (spec §1 비목표).
