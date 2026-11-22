---
name: handoff
description: 현재 세션의 작업 내용·결정·함정·미완료 작업을 다음 세션으로 넘길 handoff 문서로 작성한다. features/<feature-name>/task-index.md가 이미 있으면 그 TODO 섹션 갱신 후보도 제안한다. 사용자가 /handoff로 직접 호출할 때만 쓴다.
disable-model-invocation: true
---

# handoff — 세션 종료 dump

## ⛔ 호출 규칙 (가장 중요)

이 스킬은 **사용자가 `/handoff`를 명시적으로 호출했을 때만** 동작한다.

- ❌ "오늘 작업 정리해줘" 같은 의도 표현만으로 자동 실행 금지
- ❌ context 사용률 도달, 세션 초기화 감지 등으로 자동 제안 금지
- ❌ "handoff를 만들까요?" 식 선제 권유 금지
- ✅ 사용자가 명시적으로 `/handoff` 또는 "handoff 스킬 실행해" 등 지명한 경우만 실행

## 목적

긴 작업의 컨텍스트를 **사용자가 고른 시점에, 검증 가능한 형태로** 다음 세션에 넘긴다. 자동 컨텍스트 압축은 시점을 고를 수 없고, 실패한 시도를 가장 먼저 버리고, 결과를 fact처럼 이어간다. handoff는 그 셋을 뒤집는다.

1. **세션 dump**: 다음 세션이 hypothesis로 다룰 수 있는 형태로 작업 상태를 `docs/handoffs/`에 떨어뜨린다.
2. **(선택) TODO 동기화**: `features/<feature-name>/task-index.md`가 **이미 있으면** 그 TODO 섹션에서 이번 세션이 완료한 항목과 새로 발견한 항목을 후보로 제안한다. 슬롯이 없으면 이 단계는 건너뛴다. 슬롯을 새로 만들지 않는다.

handoff 문서는 **fact가 아닌 hypothesis** — 다음 세션은 이 문서를 그대로 믿지 않고 코드와 대조 검증한다 (takeover 스킬이 그 역할).

## features/ 슬롯 (선택 사용)

프로젝트가 feature 단위 running TODO를 유지하고 싶으면 사용자가 직접 만든다:

```
features/<feature-name>/task-index.md
```

```markdown
---
feature_name: <feature-name>
---

# <feature-name>

## TODO
- [ ] ...

## Decisions
- ...
```

handoff는 이 파일의 **TODO 섹션만** 수정 후보를 낸다. Decisions 섹션은 읽기 전용(Relevant Files 인용용). 별도의 `decisions.md` 같은 파일은 두지 않는다.

## 핵심 원칙

1. **handoff 출력 문서의 Open Work 섹션은 명령형 금지** — "Implement X" ❌ → "X is not yet implemented" ✅
   다음 세션이 맹목적으로 실행하지 않도록.
   (이 룰은 handoff가 *생성하는 출력 문서*에만 적용된다. 본 SKILL.md 본문의 단계별 지시는 명령형으로 작성한다.)
2. **파일은 라인 번호까지** — `file.kt` ❌ → `file.kt:L45-L72` ✅
3. **프로젝트 지침 파일과 중복 금지** — Prompt for New Chat에 "프로젝트 지침 파일(CLAUDE.md 또는 AGENTS.md)을 먼저 읽어라" 포함. 거기 있는 내용은 handoff에 재진술하지 않는다.
4. **Traps 섹션 비울 수 없음** — 실패 정보가 가장 가치 높음. 이번 세션에 실패가 없었으면 그 사실을 명시.
5. **Relevant Files는 5-8개 권장** — 검증된 매직 넘버는 아님. 다음 세션이 첫 응답 전에 모두 검증할 수 있는 양으로 압축한다는 게 본질. 작업 종류에 따라 조정 가능.
6. **분량은 다음 세션 검증 비용 기준** — 핵심은 "다음 세션이 첫 응답 전에 다 읽고 검증 가능한 양".
7. **task-index.md TODO 섹션 변경은 사용자 확인 후** — 자동 체크/추가 전에 변경 후보를 보여주고 승인받음.
8. **압축 뒤에 쓰지 않는다** — 이 세션에 이미 자동 컨텍스트 압축이 일어났으면 frontmatter에 `compacted_before_handoff: true`를 적는다. 압축 전 세부는 요약으로만 남아 있어 Traps·Relevant Files의 정확도가 낮다는 신호다.

## 작업 단위와 handoff 1회의 관계

**handoff 1회 = TODO 항목 1개 (또는 작은 묶음)** 가 이상적이다. 컨텍스트 사용률 임계값 같은 매직 넘버는 박지 않는다.

다음 신호 중 **하나라도 발생하면 작업 단위가 너무 컸다**는 뜻이고, 그 자리에서 handoff 후 분할을 권장한다:

- handoff Key Decisions이 3개를 초과
- Traps to Avoid가 5개를 초과
- Relevant Files가 8개를 초과
- 작업이 끝나기도 전에 컨텍스트가 답답해짐

TODO 항목 크기 기준: **한 세션에 끝나고, 완료 기준이 검증 가능하고, 결정이 1-2개 안에 떨어지는 단위.**

```markdown
❌ - [ ] Payment MSA 분리                      # 며칠짜리 epic
❌ - [ ] import 정리                            # handoff 비용 > 작업. 그냥 한다
✅ - [ ] OAuth refresh를 TX 밖으로 이동 (PaymentService.refresh)
       - 검증: TestPaymentRefresh.testRefresh가 그린
       - Out of scope: race condition 처리 (별도 항목)
```

외부 의존("백엔드 PR 머지 대기")은 항목이 아니라 **Blocked By**다. 완료된 항목은 삭제하지 않고 `[x]`로 남긴다 (takeover가 흐름 파악에 쓴다).

## 입력 수집

다음 정보를 순서대로 수집한다:

```bash
# 1. 현재 git 상태 (git repo인 경우)
git rev-parse HEAD                    # head_commit (frontmatter용)
git merge-base HEAD main              # merge_base_with_main
git rev-parse --abbrev-ref HEAD       # branch
git status --short
git diff --stat
git log --oneline -10
```

git repo가 아니면 위 명령은 실패한다. 그 경우 frontmatter에서 git 필드 생략하고 `git_context: 없음`으로 기록.

```bash
# 2. 워크트리 경로
pwd

# 3. features/ 슬롯 존재 여부 (있을 때만 TODO 동기화 단계 진입)
ls features/*/task-index.md 2>/dev/null

# 4. 동일 브랜치/날짜의 기존 handoff 존재 여부 확인
ls docs/handoffs/$(date +%Y-%m-%d)-*.md 2>/dev/null
```

기존 파일이 있으면 사용자에게 **overwrite vs append vs 새 파일** 선택을 묻는다.

## 출력 위치

`docs/handoffs/<YYYY-MM-DD>-<HHMMSS>-<branch-slug-or-noname>.md`

- `<YYYY-MM-DD>`: 날짜 prefix (`date +%Y-%m-%d`). takeover가 글롭/정렬로 찾도록 **항상 맨 앞**에 둔다.
- `<HHMMSS>`: 시각 (`date +%H%M%S`). 같은 날 여러 handoff가 충돌하지 않도록 시·분·초로 구분.
- `branch-slug`: 슬래시(`/`)를 하이픈(`-`)으로 변환. 예: `fix/skills-subskill-chaining` → `fix-skills-subskill-chaining`
- git repo가 아니면 branch 부분 대신 작업 디렉토리 베이스명 사용
- 디렉토리 없으면 생성
- `docs/handoffs/`는 `.gitignore`되어야 함 (절대 경로·사용자 선호·secret 노출 방지). 디렉토리 생성 시 `.gitignore`에 추가되어 있는지 확인하고 없으면 추가:
  ```
  docs/handoffs/
  !docs/handoffs/.gitkeep
  ```

## 출력 문서 템플릿

```markdown
---
session_date: 2026-05-04
branch: fix/skills-subskill-chaining
head_commit: 403569cabcdef          # 다음 세션의 stale 판정 기준
merge_base_with_main: 974f78fghijk
worktree: /Users/me/IdeaProjects/example
feature_name: skills-subskill-chaining     # features/ 슬롯명. 없으면 브랜치명에서 추론한 slug
relevant_files_count: 6
compacted_before_handoff: false            # 이 세션에 자동 압축이 선행했으면 true
---

# Handoff — 2026-05-04 — fix/skills-subskill-chaining

## Summary
(1-3문장으로 이번 세션이 무엇을 했는지 상태 서술. 명령형 금지)

## Key Decisions
- **결정 1**: 한 줄 요약
  - **Why**: 근거
  - **Alternatives ruled out**: 폐기 옵션과 폐기 이유

## Traps to Avoid
- ❌ 시도→실패한 접근 + 왜 실패했는지
- ❌ 표면적으로 그럴듯하지만 함정인 패턴
(이번 세션에 실패가 없었으면 "이번 세션은 첫 시도가 모두 통과함"이라고 명시)

## Working Agreements
- 사용자 선호 (예: "PR 만들기 전에 무조건 코드리뷰 받기")
- 이번 세션에서 사용자가 명시한 제약

## Relevant Files (최대 5-8개)
- `path/to/file.kt:L45-L72` — 무엇을 위한 라인인지, 왜 중요한지
- `features/<feature-name>/task-index.md` — TODO + Decisions (슬롯이 있을 때)

## Observed State
- 현재 코드/테스트가 어떤 상태인지 사실만 기록
- (예: "FooService.refresh가 race condition 의심됨. TestFooService.testRefreshConcurrent 실패 중")

## Blocked By
- 무엇이 풀려야 다음 작업이 가능한가
- (예: "백엔드의 user-id 마이그레이션 완료 대기 — 별도 PR #234")

## Candidate Next Action (참고용, 실행 명령 아님)
- "고려해볼 만한 다음 단계는 X일 수 있다"
- (반드시 단정형 아닌 가능성 표현. 다음 세션이 검증 후 결정)

## TODO Impact
- 적용된 변경: features/<feature-name>/task-index.md (TODO 섹션)
  - 체크: N개 (...)
  - 추가: M개 (...)
- (슬롯 없으면 "(features/ 슬롯 없음 — TODO 동기화 생략)")
- (사용자가 n 선택 시 "(미적용)" + 후보 목록)

## Verification Checklist (takeover 스킬이 따를 절차)
- [ ] 이 문서를 먼저 읽기
- [ ] head_commit이 여전히 git에 존재하는지 확인
- [ ] Relevant Files를 모두 읽기 (라인 범위 유효성 확인)
- [ ] features/<feature-name>/task-index.md가 있으면 hypothesis로 검증
- [ ] `git log <head_commit>..HEAD` 로 그 사이 변경 확인
- [ ] 검증 결과 한 단락 보고 후 사용자 지시 대기

## Prompt for New Chat
\`\`\`
docs/handoffs/2026-05-04-153012-fix-skills-subskill-chaining.md 를 먼저 읽어라.
그 다음 프로젝트 지침 파일(CLAUDE.md 또는 AGENTS.md)을 읽고, 이미 거기서 다룬 내용은 재진술하지 마라.
"Relevant Files"의 파일들을 실제로 읽고, 이 문서의 주장(라인 번호 포함)을 코드와 대조해 검증하라.
features/<feature-name>/task-index.md가 있다면 hypothesis로 검증하라.
"Verification Checklist"의 모든 항목을 수행한 뒤, 검증 결과를 한 단락으로 보고하고 내 지시를 기다려라.
\`\`\`
```

## 실행 흐름

1. **git 상태 수집** (위 명령들; git repo 아니면 생략)
2. **features/ 슬롯 식별** (있을 때만)
   - `ls features/*/task-index.md` 결과가 있으면 현재 브랜치명·작업 디렉토리·세션 내용으로 가장 관련 높은 것 선택. 여러 후보면 사용자에게 번호로 제시.
   - 없으면 `feature_name`은 브랜치명에서 kebab-case slug로 추론해 frontmatter에만 기록하고 Step 7을 건너뛴다. **슬롯을 만들지 않고, 만들지 묻지도 않는다.**
3. **트랜스크립트에서 추출**
   - 사용자가 명시한 결정/제약 → Key Decisions, Working Agreements
   - 시도→실패 접근 (대화에서 "그건 안 돼", "그 방식 말고 다른 방법", 사용자 거부 표현) → Traps to Avoid
   - 마지막 작업 지점 → Observed State, Blocked By
   - 이번 세션에서 명시적으로 완료된 TODO 항목 → 체크 후보 (슬롯 있을 때)
   - 이번 세션에서 새로 발견된 후속 과제 → 추가 후보 (슬롯 있을 때)
   - 이 세션에 자동 압축이 선행했는지 확인 → `compacted_before_handoff`
4. **Relevant Files 선정**
   - 이번 세션에 편집·작성·읽은 파일 중 다음 세션이 반드시 봐야 할 5-8개로 압축
   - 라인 번호까지 명시. 광범위하게 읽은 파일은 핵심 함수의 라인 범위만
   - task-index.md가 있으면 우선 포함
5. **명령형 검사** (자체 lint)
   - "Open Work"는 출력 문서의 `## Observed State` / `## Blocked By` / `## Candidate Next Action` 3개 섹션을 묶어 부르는 *논리 그룹명*이다 (실제 마크다운 헤더 아님).
   - 위 3개 섹션의 모든 문장이 "Implement", "Add", "Fix", "Do" 등 명령형 동사로 시작하는지 검사
   - 명령형이면 상태 서술형으로 재작성
6. **`docs/handoffs/<YYYY-MM-DD>-<HHMMSS>-<branch-slug>.md` 작성**
7. **task-index.md TODO 섹션 변경 후보 사용자 확인 + 적용** (Step 2에서 슬롯을 찾은 경우만)
   - 다음 형식으로 사용자에게 변경 후보 제시:
     ```
     [task-index.md 변경 제안: features/payment-msa/task-index.md, TODO 섹션]

     체크할 항목:
       [x] race condition 재현 fixture 정리

     추가할 항목 (TODO 섹션 끝에):
       [ ] backend의 user-id migration 대기 (PR #234)
       [ ] PaymentService 통합 테스트 도커 fixture 정리

     적용하시겠습니까? (y/n/edit)
     ```
   - `y` → 적용
   - `n` → 건너뜀 (handoff 문서에는 "TODO Impact (미적용)"으로만 기록)
   - `edit` → 사용자가 수정한 변경분으로 적용
   - **사용자 확인 없이 자동 수정 금지** (task-index.md는 source of truth). Decisions 섹션은 수정하지 않는다.
8. **사용자에게 종합 보고**: handoff 경로 + TODO 변경 요약 + 한 줄 요약. 질문 없이 끝낸다.

## 예시: Open Work 변환

❌ 명령형:
```
- Implement retry logic in TokenService
- Fix the race condition in FooService
- Add tests for the new endpoint
```

✅ 상태 서술형 (3섹션 분리):
```
## Observed State
- TokenService.refresh는 retry 없이 단발 호출. 401 응답 시 즉시 throw.
- FooService.barCase 테스트가 race condition으로 간헐 실패. 재현율 30%.
- POST /api/widgets 엔드포인트 구현됨. 테스트 미작성.

## Blocked By
- (없음 — 다음 단계는 모두 같은 세션에서 가능)

## Candidate Next Action
- TokenService에 backoff 기반 retry 추가가 가장 영향 큼
- FooService race condition은 lock 도입 vs CAS 방식 결정 필요
- 엔드포인트 테스트는 fixture 재사용 가능성이 높음
```

## task-index.md TODO 섹션 규칙

- **체크박스 추론 보수적으로**: 코드/테스트로 명시 검증된 항목만 `[x]` 체크. "구현한 것 같다" 수준은 건너뛰고 사용자에게 보고만.
- **항목 삭제 금지**: 폐기된 항목은 `~~취소선~~`으로 표시하고 이유 주석 추가, 실제 삭제는 사용자가 직접.
- **섹션 구조 보존**: 기존 헤더·우선순위 표기를 그대로 둠. 신규 항목은 TODO 섹션 끝에 배치. Decisions 섹션은 수정하지 않는다.
- **git에 커밋된 파일이면 변경 후 staging 상태**로 두고 사용자에게 알림 (자동 commit 금지)

## Done When

- `docs/handoffs/<YYYY-MM-DD>-<HHMMSS>-<branch-slug>.md` 가 작성됨
- frontmatter에 `head_commit`, `merge_base_with_main` 포함됨 (git repo인 경우)
- frontmatter에 `feature_name`, `compacted_before_handoff` 존재
- Relevant Files 개수가 8개 이하
- "Open Work" 그룹(=`## Observed State` / `## Blocked By` / `## Candidate Next Action` 3섹션)이 모두 출력 문서에 존재
- 위 3섹션의 모든 문장이 명령형 동사("Implement", "Add", "Fix", "Do")로 시작하지 않음
- `.gitignore`에 `docs/handoffs/` 포함됨
- handoff 문서에 `## TODO Impact` 섹션 존재 (슬롯 없으면 "(features/ 슬롯 없음 — TODO 동기화 생략)" 명시)
- 슬롯이 있었다면 사용자 확인 후 TODO 섹션이 갱신되었거나, 미적용 사실이 handoff 문서에 기록됨
- 사용자에게 던진 질문이 기존 handoff 충돌(overwrite/append/새 파일)과 TODO 적용(y/n/edit) 외에 없음
