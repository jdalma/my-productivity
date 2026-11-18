---
name: takeover
description: 사용자가 명시적으로 "/takeover" 슬래시 커맨드를 호출하거나 "/takeover 실행", "takeover 스킬 써" 같이 스킬 이름을 직접 지명할 때만 사용한다. 이전 세션의 handoff 문서(와 있으면 features/<feature-name>/task-index.md)를 읽고, hypothesis로 다루며 실제 코드·git 상태와 대조해 stale 여부를 판정한 뒤 검증 결과를 보고한다. 사용자가 "어제 이어서", "어디까지 했지" 등 의도만 표현하고 스킬을 지명하지 않았다면 절대 자동 호출하지 마라. 자동 제안 금지.
disable-model-invocation: true
---

# takeover — 새 세션 시작 load + verify

## ⛔ 호출 규칙 (가장 중요)

이 스킬은 **사용자가 `/takeover`를 명시적으로 호출했을 때만** 동작한다.

- ❌ 새 세션 첫 턴에 `docs/handoffs/` 발견했다고 자동 제안 금지
- ❌ "어제 이어서" 같은 의도만으로 자동 실행 금지
- ❌ "takeover를 실행할까요?" 식 선제 권유 금지
- ✅ 사용자가 명시적으로 `/takeover` 또는 "takeover 스킬 실행해" 등 지명한 경우만 실행

> 세션 재시작(resume) 계열 내장 명령과 충돌을 피하기 위해 이 스킬은 `takeover`로 명명되었다. handoff(넘기기)의 짝으로 takeover(인수받기)를 의미한다.

## 목적

이전 세션이 작성한 handoff 문서(와 있으면 `features/<feature-name>/task-index.md`)를 hypothesis로 받아들여, **실제 git/코드 상태와 대조**한 뒤 검증 결과를 보고한다. **자동 재개 금지** — 사용자 지시 없이 코드 작성하지 않는다.

handoff가 "사용자가 고른 시점의 수동 압축"이라면 takeover는 그 **재로드**다. 자동 컨텍스트 압축과 달리 요약을 fact로 이어가지 않고, 라인 번호와 commit을 다시 확인한 뒤에만 다음 작업의 전제로 삼는다.

## 핵심 원칙

> 명령형은 새 세션이 맹목적으로 실행하게 만든다. Handoff는 fact가 아니라 hypothesis로 다뤄야 한다.

이 스킬의 모든 단계는 위 원칙을 구현한다.

## 안티 패턴 차단

- ❌ handoff 문서를 fact로 신뢰
- ❌ Candidate Next Action 자동 실행
- ❌ Relevant Files만 보고 실제 읽기 건너뛰기
- ❌ 검증 결과 보고 없이 코딩 시작
- ❌ stale 판정을 날짜만으로 결정
- ❌ task-index.md를 source of truth로 신뢰 (코드와 대조 후에만 판단)
- ❌ task-index.md 수정 (takeover는 읽기·검증·보고만; 수정은 handoff의 역할)

## 실행 흐름

### Step 1: handoff 문서 선택

handoff는 브랜치보다 feature 단위 인계가 더 자연스럽다 (브랜치는 자주 바뀌고 rebase되지만 feature는 오래 간다).
검색 우선순위는 **feature_name 먼저, 브랜치는 fallback**.

```bash
# 0. 현재 브랜치 확인 (git repo인 경우)
git rev-parse --abbrev-ref HEAD 2>/dev/null

# 1. 현재 작업 디렉토리에서 feature_name 추론
#    - features/*/task-index.md가 있으면 그 feature_name 우선 (후보 여러 개면 사용자에게 번호로 제시)
#    - 없으면 현재 브랜치 slug를 feature_name 후보로 사용
current_feature=$(ls features/*/task-index.md 2>/dev/null | head -1 | xargs -I {} grep -m1 "^feature_name:" {} | cut -d: -f2 | xargs)

# 2. 1차 검색 — feature_name으로 frontmatter grep (cross-branch)
if [ -n "$current_feature" ]; then
  grep -l "^feature_name: ${current_feature}$" docs/handoffs/*.md 2>/dev/null | xargs ls -t 2>/dev/null
fi

# 3. 2차 fallback — 브랜치 슬러그 매칭
#    파일명이 <YYYY-MM-DD>-<HHMMSS>-<branch-slug>.md 라 슬러그는 끝에 위치 → *-<slug>.md 유효
ls -t docs/handoffs/*-<current-branch-slug>.md 2>/dev/null | head -5

# 4. 3차 fallback — 모든 handoff에서 최근 N개
#    파일명 prefix가 날짜+시각(HHMMSS)이라 사전순=시간순
ls -t docs/handoffs/*.md 2>/dev/null | head -5
```

- 정확히 1개 매칭: 자동 선택 + 사용자에게 알림
- 여러 개: **feature 그룹핑 형태로 사용자에게 제시**, 선택 받음
- 없음: "사용 가능한 handoff 없음" 보고하고 종료

**다중 후보 제시 형식 (feature 그룹핑)**:

```
[feature: auth-bug-fix]
  1. 2026-05-04-153012-fix-auth-bug.md (최신)
  2. 2026-05-03-091500-fix-auth-bug.md
  3. 2026-04-28-142233-feature-auth-init.md (다른 브랜치, 같은 feature)

[feature: payment]
  4. 2026-05-04-110045-feature-payment.md

[feature 미지정 (legacy, feature_name: (skipped) 또는 누락)]
  5. 2026-04-15-163344-fix-typo.md

선택 (번호):
```

같은 feature_name을 가진 handoff끼리 묶고, 그룹 안에서는 시간 역순(최신 우선) 정렬.
feature_name이 `(skipped)` 또는 누락된 handoff는 "feature 미지정" 그룹으로 별도 표시.

### Step 2: 문서 읽기 + 무결성 체크

선택된 문서를 읽는다. frontmatter에서 다음을 추출:
- `head_commit`
- `merge_base_with_main`
- `branch`
- `session_date`
- `feature_name` (있으면)
- `relevant_files_count`
- `compacted_before_handoff` (있으면. `true`면 이 문서는 자동 압축된 기억으로 쓰였다는 뜻 — Relevant Files 라인 번호와 Traps의 정확도를 더 의심한다)

### Step 3: git 기반 stale 판정 (핵심)

날짜가 아닌 git 상태로 판정한다 (git repo인 경우). 강한 신호 → 약한 신호 순:

```bash
# 1. head_commit이 여전히 존재하는가? (force-push, rebase 감지)
git cat-file -e <head_commit> 2>&1
# 실패 → 강한 경고: "이 handoff가 작성된 commit이 더 이상 존재하지 않음. rebase/force-push 의심"

# 2. 그 사이 변경된 파일 수
git log <head_commit>..HEAD --name-only --pretty=format: 2>/dev/null | sort -u | grep -c .

# 3. Relevant Files 중 변경된 것
for file in <relevant-files>; do
  git log <head_commit>..HEAD -- "$file" --oneline 2>/dev/null
done

# 4. 현재 브랜치 vs handoff.branch
git rev-parse --abbrev-ref HEAD

# 5. dirty worktree
git status --short
```

판정 매트릭스:

| 신호 | 강도 | 행동 |
|------|------|------|
| head_commit 미존재 | 🔴 강함 | "rebase/force-push 발생. 라인 번호 전부 재검증 필요" |
| Relevant Files 중 N개 변경 | 🟠 중간 | "이 파일들 다시 검증 필요: ..." |
| `compacted_before_handoff: true` | 🟠 중간 | "압축 뒤 작성된 handoff. Traps·라인 번호 정확도 낮음" |
| 현재 브랜치 ≠ handoff.branch | 🟡 약함 | "다른 브랜치임. 계속할지 사용자 확인" |
| dirty worktree | 🟡 약함 | "미커밋 변경 있음: ..." |
| 7일 초과 (날짜) | ⚪ 정보 | 약한 정보성 메시지만 |

### Step 3.5: features/<feature-name>/task-index.md 로드 + 검증 (있을 때만)

handoff 문서의 frontmatter `feature_name` 또는 본문 `## TODO Impact` 섹션이 가리키는 슬롯을 찾는다:

```bash
grep -oE "features/[^/]+/task-index\.md" <handoff-path> | head -1
ls features/*/task-index.md 2>/dev/null
```

있으면 **task-index.md를 읽는다**:
- TODO 섹션의 `[x]` 중 의심스러운 것 (handoff에 언급 없음, 코드에 흔적 없음) 식별
- handoff의 Candidate Next Action 중 TODO에 미반영된 것 식별 (다음 handoff 동기화 후보)
- Decisions 섹션을 훑어 이번 작업과 관련된 결정·함정 인용

이 정보는 Step 5 보고에 포함한다. **파일을 수정하지 않는다** — 수정은 handoff의 역할.

### Step 4: Relevant Files 검증

```
for file in Relevant Files (최대 8개):
  해당 라인 범위를 읽는다
  - 파일이 존재하지 않음 → "파일 삭제/이동됨"
  - 라인 번호 범위가 파일 길이 초과 → "라인 drift 발생"
  - 정상 → 핵심 패턴이 여전히 그 라인에 있는지 간단 확인
```

### Step 5: 검증 결과 보고 (구조화된 형태)

```markdown
## Takeover 검증 결과

**Handoff 문서 (선택됨)**: `docs/handoffs/2026-05-04-143022-fix-skills-subskill-chaining.md`
**연결 features/**: `features/handoff-skill/task-index.md` (없으면 "(없음)")
**작성 시점**: 2026-05-04 → 현재 1일 경과

### Feature Timeline (handoff-skill)
*frontmatter에 `feature_name`이 있으면 항상 표시. 같은 feature의 모든 handoff를 시간순으로 묶어 보여줘 사용자가 작업 흐름을 즉시 인식할 수 있게 한다.*

| 날짜 | 브랜치 | 파일 | 상태 |
|---|---|---|---|
| 2026-04-28 | feature/handoff-init | 2026-04-28-101500-feature-handoff-init.md | 과거 (검증 안 함) |
| 2026-05-01 | feature/handoff-init | 2026-05-01-093020-feature-handoff-init.md | 과거 (검증 안 함) |
| 2026-05-04 | fix/skills-subskill-chaining | 2026-05-04-143022-fix-skills-subskill-chaining.md | ⬅ CURRENT (Step 3·4 검증 대상) |

- 표는 같은 `feature_name` 가진 handoff 모두를 cross-branch로 묶음
- 과거 handoff는 *읽지 않음* (참조만). 검증은 CURRENT만.
- `feature_name`이 `(skipped)` 또는 누락된 handoff는 이 표에 포함하지 않음

### Git stale 판정
- ✅ head_commit (403569c) 여전히 존재
- ⚠️ 그 이후 3개 commit 추가됨 (`git log 403569c..HEAD`)
- ✅ 현재 브랜치 일치: fix/skills-subskill-chaining
- ⚠️ dirty worktree: M features/handoff-skill/task-index.md
- ✅ compacted_before_handoff: false

### Relevant Files 검증
- ✅ `path/to/file.kt:L1-L50` — 유효
- 🔴 `path/to/other.kt:L20-L40` — 라인 drift (현재 파일은 80라인까지만)
- ✅ 그 외 4개 파일 유효

### task-index.md 상태 (슬롯 있을 때만)
- TODO: `[x]` 항목 중 의심스러운 것 0개 / Candidate Next Action 중 미반영 `race condition 재현 테스트` 1건
- Decisions: 이번 작업과 관련된 함정 2개 인용

### 문서가 모르는 새 변경
- 새 파일: `src/foo/Bar.kt` (1일 전 추가됨)

### 종합
- 전반적으로 유효. 단, `path/to/other.kt`의 라인 번호는 stale.
- "Candidate Next Action"의 첫 항목은 코드에 이미 적용됨에도 task-index.md TODO에는 미체크. 다음 handoff 호출 시 동기화 후보.

**다음 작업 지시를 기다립니다.**
```

### Step 6: 사용자 지시 대기

검증 결과만 보고하고 대기한다. **자동 진행 금지**. 사용자가 명시 지시("그럼 X부터 진행해")를 줄 때까지 코드 작성/수정/실행하지 않는다.

## Edge Case 처리

| 상황 | 행동 |
|------|------|
| `docs/handoffs/` 디렉토리 자체 없음 + features/ 슬롯도 없음 | "handoff 없음. takeover로 할 일 없음." 보고 후 종료 |
| `docs/handoffs/` 없음 + `features/<name>/task-index.md`는 있음 | 슬롯만 hypothesis로 검증 (Step 3.5만 수행). 보고에 *"handoff 누락 — 직전 세션이 handoff 없이 종료된 것으로 보임. task-index.md가 stale일 가능성 높음"* 명시 |
| handoff 파일 frontmatter 손상 | 손상 사실 보고하고 본문만 읽어 hypothesis로 사용 |
| `head_commit` 필드 누락 (구버전 handoff or non-git) | git 기반 검증 건너뛰고 날짜 기반 약한 검증으로 fallback |
| `compacted_before_handoff` 필드 누락 (구버전 handoff) | 알 수 없음으로 처리. 보고에 표시하지 않음 |
| Relevant Files가 모두 삭제됨 | "이 handoff는 stale 가능성 매우 높음. 새 세션으로 시작 권장" |
| detached HEAD 상태 | 경고: "detached HEAD. 브랜치 비교 의미 없음" |
| features/<feature-name>/ 디렉토리 자체 없음 | task-index.md 상태 섹션 생략, "(연결 features/ 없음)" 명시 |
| 구버전 task-index.md에 Slices 섹션·`plan_status`·`created_by` 등이 남아 있음 | 무시한다. TODO·Decisions 섹션만 본다 |
| feature_name이 `(skipped)` 또는 누락 | Feature Timeline 섹션 생략, "(feature 미지정 — 단발 dump 또는 legacy handoff)" 명시. 다른 handoff와 묶지 않음 |

## Done When

- handoff 문서가 선택되고 읽힘 (또는 폴백 경로로 task-index.md만 검증)
- frontmatter의 `head_commit` 기준으로 git stale 판정 수행됨 (git repo인 경우)
- Relevant Files가 모두 읽히고 라인 번호 유효성 검증됨
- task-index.md가 있으면 hypothesis로 검증됨
- 구조화된 검증 결과가 사용자에게 보고됨
- **자동 진행 없이** 사용자 지시를 대기하는 상태로 종료
