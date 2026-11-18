# CLI-중립 스킬 배포 — Shim 아키텍처 설계

> 작성: 2026-06-24 · 상태: 설계 확정 (구현 전)
>
> 순수 마크다운 `SKILL.md`를 SSOT로 두고, claude/codex(추후 gemini)에 동일 스킬로
> 배치되도록 하는 shim 아키텍처. 본 문서는 brainstorming 세션의 산출물이며,
> 다음 단계는 구현 계획(writing-plans)이다.

## 1. 목표와 비목표

### 목표
- **CLI에 종속되지 않는 순수 마크다운**으로 스킬을 정의한다 (SSOT).
- 그 SSOT를 **claude / codex**(추후 gemini)에서 각자의 네이티브 스킬로 인식되게 한다.
- 이 레포는 **public**이므로 회사·도메인 식별자를 자산에 담지 않는다.

### 비목표 (이번 범위 밖)
- 커맨드(slash command)의 CLI-중립화 — Gemini는 `.toml`이라 포맷이 근본적으로 다름.
- MCP 서버 정의의 SSOT화 — JSON↔TOML + http 키 충돌로 어댑터가 필요 (후순위).
- C등급(런타임 종속) 스킬의 이식 — Claude 플러그인에만 남긴다.
- Gemini 실제 배치 — 설계만 열어두고 구현은 후속.
- **실제 각 CLI로의 복사·prefix·등록 — 이 레포의 책임이 아니다** (§2-6 참조).
  그건 SSOT 디렉토리를 소비하는 외부 sync 도구의 일이다.

## 2. 조사로 확정된 사실 (설계의 전제)

이 설계는 추측이 아니라 다음 검증 결과 위에 선다.

### 2-1. 세 CLI가 이미 `SKILL.md + YAML frontmatter`로 수렴
| | Claude | Codex | Gemini |
|---|---|---|---|
| 스킬 경로 | `~/.claude/skills/`, `.claude/skills/`, 플러그인 | `~/.agents/skills/`, `$CWD/.agents/skills` | `~/.gemini/skills/` 또는 별칭 `~/.agents/skills/` |
| 파일명 | `SKILL.md` | `SKILL.md` | `SKILL.md` |
| frontmatter | YAML (`name`, `description`) | YAML (`name`, `description` 필수) | YAML (`name`, `description` 필수) |
| 본문 | 마크다운 | 마크다운 | 마크다운 |

→ **스킬 레이어는 변환이 아니라 복사가 본질.** Codex/Gemini는 `~/.agents/skills` 규약으로 수렴.

### 2-2. 심링크는 세 CLI 모두 신뢰 불가
- Codex: 문서는 "지원" 주장하나 GitHub 이슈(#11314)는 미동작, "not planned"로 종료.
- Gemini: GEMINI.md 심링크 안 읽힘(#11547, "not planned"), commands 디렉토리 심링크 과거 미동작.
- → **실제 파일 복사(rsync)만 안전.** 이 레포의 기존 SessionStart rsync 패턴과 정합.

### 2-3. Codex는 모르는 frontmatter 키를 무시한다
- `disable-model-invocation` 등 Claude 전용 키가 섞여 있어도 에러 없이 인식.
- → **단일 SKILL.md를 유지할 수 있다** (CLI별 키 제거 스텝 불필요).

### 2-4. PATH 가로채기 자리는 하나뿐 — 외부 sync 도구가 이미 점유
- 현재 `codex`가 외부 sync 도구의 PATH shim으로 잡힘.
- PATH 맨 앞은 한 자리뿐이라 **두 번째 PATH shim은 본질적으로 공존 불가**.
- 외부 sync 도구는 *멀티소스로 설계됨* (스킬 디렉토리·prefix를 소스 하나로 등록).
  → my-claude-plugin은 그 "소스 하나"가 된다.

### 2-5. 현재 레포 스킬의 이식성 현실
- A등급(순수 마크다운) 2개, B등급(추상화 시 가능) 6개, **C등급(런타임 종속) 9개**.
- C등급은 `Skill tool` 체이닝, `context: fork`, `subagent_type`, MCP `vault-decision`에 종속.
- → **"모든 스킬을 이식"은 비현실적.** CLI-중립인 것만 선별한다.

### 2-6. 관심사 분리 — 이관(sync)은 이 레포의 책임이 아니다
- "디렉토리 경로를 받아 각 CLI 스킬 경로로 복사·prefix·고아 정리"하는 것은
  **외부 sync 도구의 책임**이다. 외부 sync 도구는 이미
  스킬 디렉토리·prefix를 받아 이 일을 한다.
- 따라서 이 레포는 **"어떤 sync 도구든 먹을 수 있는 깨끗한 CLI-중립 스킬 디렉토리"를
  제공하는 데까지만** 책임진다. 소스 등록·prefix 재작성·codex 배치는 전부 외부 도구 일.
- 외부 sync 도구는 이 SSOT를 소비할 수 있는 **여러 클라이언트 중 하나의 예시**일 뿐이며,
  이 레포가 그것에 런타임 의존하지 않는다 (public ↔ private 결합 회피).

## 3. 확정된 설계 결정

| # | 결정 | 선택 | 근거 |
|---|---|---|---|
| 1 | SSOT 포맷 | 표준 `SKILL.md` 그대로 | 2-1 — 세 CLI 수렴, 변환 불필요 |
| 2 | 대상 범위 | CLI-중립 스킬만 (L0~L1) | 2-5 — C등급은 복사해도 안 돎 |
| 3 | 이관(sync) 책임 | 이 레포 밖 — sync 도구가 담당 | 2-6 — 관심사 분리 |
| 4 | sync 도구 | 이 레포는 새 shim 안 만듦, 외부 도구가 소비 | 2-4 — PATH 자리 하나뿐, 외부 sync 도구가 점유 |
| 5 | 결합 | 외부 도구 등록은 로컬에서만 | public ↔ private 분리 |
| 6 | prefix 권장값 | `my` (안내값일 뿐, 강제 아님) | 레포 정체성. prefix 부여는 sync 도구 일 |
| 7 | MCP | 후순위 (이번엔 스킬만) | 변환 어댑터 필요, YAGNI |

## 4. 아키텍처

이 레포의 책임 경계(굵은 박스)와 외부 sync 도구의 책임을 분리해서 본다.

```
╔══════════════════════════════════════════════════════════════╗
║  이 레포의 책임 (my-claude-plugin, public)                     ║
║  ┌────────────────────────────────────────────────────────┐  ║
║  │ ① SSOT: plugins/workflow/skills/<name>/SKILL.md         │  ║
║  │    · L0~L1만 (순수 지식 + 기본 도구)                      │  ║
║  │    · frontmatter: name, description (Claude 전용 키 무시) │  ║
║  │ ② 린터: portability-check (①이 CLI-중립임을 보증)         │  ║
║  └────────────────────────────────────────────────────────┘  ║
╚════════════════════════════════╤═════════════════════════════╝
                                 │  "여기 깨끗한 디렉토리가 있다"
          ┌──────────────────────┴───────────────────────┐
          │   외부 sync 도구의 책임 (이 레포 밖)               │
          │   · 디렉토리 경로를 받아 각 CLI 스킬 경로로 복사    │
          │   · 충돌 회피 prefix(예: my-) 부여, 고아 정리       │
          ▼                                                ▼
   claude 캐시 rsync                      ~/.codex/skills/my-<name>/
   (무변환, 플러그인 네임스페이스)          (rsync + prefix 재작성)
                                          (추후) ~/.agents/skills/ → Gemini
```

**Claude는 sync 도구가 없어도** 이 레포의 기존 SessionStart rsync 훅으로 동작한다
(플러그인 네임스페이스 `workflow:<name>`). Codex/Gemini만 외부 sync 도구를 거친다.

**Gemini 확장 지점**: `~/.agents/skills/`가 이미 존재하고 Codex/Gemini 공유 규약이므로,
sync 도구가 `~/.agents/skills` 타겟을 추가하면 Gemini도 커버 — 이 역시 외부 도구 일.

## 5. 런타임 의존성 계층 (CLI-중립 판별 기준)

스킬이 의존하는 능력을 4계층으로 나눠, **L0~L1만 SSOT 적격**으로 본다.

| 계층 | 신호 (본문에 등장 시) | Claude | Codex | Gemini |
|---|---|---|---|---|
| L0 순수 지식 | 워크플로우·체크리스트·원칙 | ✅ | ✅ | ✅ |
| L1 기본 도구 | 파일 읽기/쓰기, bash, grep | ✅ | ✅ | ✅ |
| L2 서브에이전트 | `Agent(subagent_type=...)`, `Task`, `context: fork`, Skill tool 체이닝 | ✅ | ⚠️ 부분 | ⚠️ `activate_skill` |
| L3 Claude/MCP 종속 | `mcp__*`, `omc:*` 위임, `--fork-session` | ✅ | ❌ | ❌ |

신규 스킬은 L2가 필요하면 **행동 언어**로 작성한다 (특정 도구명 대신
"서브에이전트를 띄워라" — superpowers 스킬이 쓰는 기법). 그러면 처음부터 이식 가능.

## 6. 구현 대상 (이 레포가 새로 만들 것 — 2가지)

> 이관(sync)은 §2-6대로 외부 도구 책임이므로 이 레포의 산출물에서 제외한다.

### 6-1. CLI-중립 스킬 디렉토리 (SSOT)
- 기존 `plugins/workflow/skills/`에서 A등급만 선별하거나, 신규는 처음부터 CLI-중립으로 작성.
- 본문에 L2/L3 신호 금지.

### 6-2. 이식성 린터 `portability-check`
- SKILL.md를 grep해 L2/L3 신호(`subagent_type`, `context: fork`, `mcp__`, `omc:`,
  `--fork-session`)를 탐지 → 등급(A/B/C) 산출, SSOT 부적격 경고.
- 표현 계층: markdown 스킬 또는 간단한 셸 스크립트 (레포 CLAUDE.md "스킬>훅" 우선순위 준수).
- **가장 중요한 가드** — "복사했는데 안 도는 스킬"을 사전 차단.

### (선택) 6-3. sync 도구용 안내 한 줄 — 문서로만
- 이 레포는 sync 자체를 구현하지 않지만, "외부 sync 도구에 이 디렉토리를 어떻게 넘기는가"를
  README에 **예시 한 줄**로 안내할 수 있다 (prefix 권장값 `my` 포함).
- 회사 식별자는 자산·문서에 담지 않는다. "외부 sync 도구"처럼 일반 표현으로.
- 실제 등록은 사용자 로컬에서 수행 (git 비추적).

## 7. 데이터 흐름 (스킬 1개가 Codex에 뜨기까지)

이 레포 책임은 ①②까지. ③~⑥은 외부 sync 도구가 한다 (참고용으로만 표기).

```
[이 레포]  ① 작성:  plugins/workflow/skills/<name>/SKILL.md  (SSOT)
           ② 보증:  portability-check 통과 (CLI-중립 확인)
─────────────────────── 책임 경계 ───────────────────────
[외부 도구] ③ 등록:  sync 도구 설정에 디렉토리 경로 한 줄 (최초 1회, 로컬)
           ④ 트리거: `codex`(또는 `claude`) 실행 → sync 도구가 가로챔
           ⑤ sync:  rsync + prefix 재작성 → ~/.codex/skills/my-<name>/
           ⑥ 노출:  Codex `$/skills` 메뉴에 my-<name> 등장 → 동작
```
- Claude 쪽: **외부 도구 없이도** 이 레포의 기존 SessionStart rsync 훅이
  `plugins/workflow/`를 캐시로 복사 → 플러그인 네임스페이스(`workflow:<name>`)로 노출. 변환 0.
- ③은 한 번만. 이후 SKILL.md 수정 후 `codex` 실행만으로 ⑤가 멱등 rsync로 최신화
  (`rsync -a`로 원본을 매번 다시 받은 뒤 재작성 → 누적 오염 없음).

## 8. 실패 모드와 대응

| 실패 모드 | 원인 | 대응 | 책임 |
|---|---|---|---|
| C등급 스킬이 SSOT에 섞임 | 런타임 신호를 모르고 등록 | **portability-check 린터**가 차단 | 이 레포 |
| frontmatter 충돌 | Claude 전용 키 | 검증됨: Codex는 모르는 키 무시 | 이 레포 |
| public 레포에 식별자 유출 | 문서·자산에 회사명 | 자산엔 도메인 무포함, sync 도구는 일반 표현 | 이 레포 |
| prefix 충돌 | `my-`가 다른 codex 스킬과 겹침 | prefix 스코프 고아 정리 (`my-*`만) | 외부 도구 |
| sync 도구 미설치 PC | 외부 shim 없는 PC | Claude는 SessionStart 훅으로 동작 (Codex/Gemini는 sync 도구 필요) | — |
| sync 실패/지연 | git pull 초과 등 | sync 도구의 fail-open | 외부 도구 |

## 9. 검증 (성공 기준)

이 레포 책임(1)이 핵심 가드. 2~5는 외부 sync 도구와 함께하는 end-to-end 확인.

1. **린터 (이 레포 핵심)**: A등급 스킬 → 통과. C등급(`slice-tdd` 등) →
   "subagent_type 발견, 부적격" 경고.
2. **Codex 노출**: sync 후 `codex` 실행 → `$/skills`에 `my-<name>` → 호출 시 SSOT 본문 로드.
3. **멱등성**: `codex` 2회 실행 후 `~/.codex/skills/my-<name>/SKILL.md` 해시 동일.
4. **Claude 동등성**: 새 세션에서 `/workflow:<name>` → 동일 SSOT 본문.
5. **격리**: `my-` 외 다른 codex 스킬(OMC 등) 미손상.

## 10. 참고

- 이 SSOT를 소비할 수 있는 sync 도구의 한 예시는 "디렉토리 경로 + prefix"를 받는
  멀티소스 sync 메커니즘이다 (PATH 가로채기 + rsync + prefix 재작성 + 고아 정리).
  이 레포는 그런 도구에 의존하지 않으며, 깨끗한 SSOT 디렉토리만 제공한다.
- MCP 서버 설정 비교(후순위 참고): 세 CLI 모두 stdio `command/args/env` 3-튜플 공통,
  단 Claude/Gemini=JSON, Codex=TOML, http transport는 키·인증 표현이 전부 달라 어댑터 필요.
  특히 `url` 키 의미 충돌(Codex=streamable-http vs Gemini=SSE) 주의.
