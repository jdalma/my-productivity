---
name: vault-prune
description: memory-palace류 vault에서 지우고 싶은 내용·주제·주장·Decision·Note 일부를 안전하게 제거하기 전에, 관련 Note/Decision/Source/MOC/index/log/backlink를 모두 찾아 영향 범위를 보여주고 삭제·아카이브·부분 편집 수준을 질문한다. 사용자가 "이 내용 vault에서 지우고 싶어", "Decision에서 이 주장 삭제", "관련 내용 다 찾아서 어디까지 삭제할지 물어봐", "vault 내용 정리/제거/숨김/아카이브", "/vault-prune" 같이 요청할 때 사용. 승인 전 파괴적 변경 금지.
---

# vault-prune — 삭제 전 영향 탐색 → 수준 협상 → 안전 제거

> vault에서 무언가를 지우기 전에, **어디까지 지울지** 안전하게 협상한다.
> 바로 지우지 않는다: 탐색 → 영향 리포트 → 삭제 수준 질문 → 승인 후에만 편집.
> ingest(심기) · atomize(승격)와 함께 vault 수명주기의 **삭제 축**을 담당한다.

## When to use

- vault에서 특정 내용/주제/주장을 지우거나 숨기고 싶을 때
- 무엇이 그 내용과 엮여 있는지(backlink·MOC·index·log) 먼저 파악하고 싶을 때
- 되돌리기 어려운 삭제 전에 영향 범위와 삭제 수준을 협상하고 싶을 때

## Vault 위치와 계약

- vault 경로: 인자로 주어지면 그것, 없으면 `~/knowledge/memory-palace`.
- 폴더 모델·frontmatter·파일명 규칙은 이 스킬에 적지 않는다. 작업 전에 vault 루트
  규칙 문서(`AGENTS.md` 또는 동등물)와 대상 폴더 규칙 문서를 읽어 그대로 따른다.
  아래의 Inbox·Notes·Maps·Sources·Archive는 폴더 *역할* 이름이다. 실제 폴더명은
  규칙 문서에서 찾는다.

## Search Scope

기본 검색 대상: `index.md`, Maps(MOC), Notes(Note·Decision), Sources, `log.md`

보조 검색 대상 (사용자가 명시하거나 관련될 때만):

- Inbox — raw input까지 포함하라고 했거나 최근 import와 관련될 때만
- Archive — 이미 퇴역한 기록까지 제거/확인해야 할 때만
- 구현 계획 문서 폴더 — 삭제 대상과 직접 관련될 때만. vault knowledge로 승격하지 않는다

## Discovery Workflow

1. 삭제 대상 표현을 정규화한다 — 직접 키워드 / 동의어·약어 / 관련 파일명 /
   관련 Decision 제목 / 관련 Source 제목.
2. grep류 검색으로 본문, frontmatter, 링크를 찾는다.
3. backlink를 찾는다 — `[[대상]]`, frontmatter `sources`/`mocs`/`derived_notes`,
   `index.md`·MOC·`log.md` 항목.
4. 후보를 분류한다.
   - **직접 삭제 후보**: 사용자가 지운다고 말한 내용 자체
   - **강한 관련 후보**: 같은 주장/결정/근거를 재서술하는 곳
   - **약한 관련 후보**: 링크·출처·역사적 언급만 있는 곳
   - **보존 후보**: provenance나 append-only 기록으로 남기는 편이 나은 곳
5. 삭제 범위 질문을 만든다.

## Deletion Levels

항상 아래 수준 중 하나 이상으로 제안한다.

- **Level 0**: 조사만 하고 수정하지 않음
- **Level 1**: 기본 query 경로에서 제거 (`index.md`·MOC·관련 Note 링크에서 제거, 파일은 유지)
- **Level 2**: Archive 이동 (Archive 폴더로 이동, `status: archived`, active index/MOC에서 제거)
- **Level 3**: 부분 삭제/수정 (특정 섹션·문단·frontmatter 후보만 제거, Note의 `decision_candidates` 정리 포함)
- **Level 4**: 파일 완전 삭제 (active 파일 삭제, backlink 정리, Source `derived_notes` 정리)
- **Level 5**: 민감정보 purge (Source·log·Archive까지 포함, 범위 별도 확인, 기본값으로 선택하지 않음)

Decision은 기본적으로 **Level 2 Archive** 또는 **"Superseded by [[새 Decision]]"**를 우선 제안한다.
완전 삭제는 사용자가 명확히 원하거나 민감정보/잘못된 import일 때만 제안한다.

## Impact Report

쓰기 전 반드시 다음 형태로 보고한다.

```text
삭제 대상 해석:
- ...

발견한 관련 항목:
- 직접: ...
- 강한 관련: ...
- 약한 관련: ...
- 보존 권장: ...

선택 가능한 삭제 범위:
1. 보수적: ...
2. 표준: ...
3. 강함: ...

확인 질문:
- 어느 범위로 진행할까요?
- Source/log/Archive까지 포함할까요?
```

질문은 1~3개로 제한한다. 사용자가 이미 명확한 수준을 지정했다면 그 수준으로
진행하되, `log.md` rewrite·민감정보 purge·대량 파일 삭제처럼 되돌리기 어려운
작업은 다시 확인한다.

## Write Order

승인 후에만 작성한다.

1. 대상 파일 편집 또는 이동
2. backlink 정리
3. Source `derived_notes` / Note `sources` / MOC 링크 정리
4. `index.md` 갱신
5. 관련 MOC 갱신
6. 실제 vault knowledge 변화면 `log.md` append
7. 결과 검증

## Editing Rules

- 사용자 삭제 의도를 보존한다. 삭제하지 말라고 한 주변 맥락은 남긴다.
- Source의 원문성은 보존한다. Source 수정은 provenance/링크 정리 위주로 하고, 원문 삭제는 별도 확인한다.
- `log.md`는 append-only가 기본이다. 과거 로그 rewrite는 민감정보 purge일 때만 별도 확인한다.
- Query 기본 경로에서 숨기는 목적이면 삭제보다 Archive 또는 index/MOC unlink를 우선한다.
- 삭제 후 고아 링크를 남기지 않는다.

## Verification

완료 전 확인한다.

- 삭제 대상 키워드가 승인 범위 밖에 남아 있지 않은가 (grep류로 확인)
- 깨진 `[[링크]]`가 없는가
- Decision/Note/Source frontmatter가 각 폴더 규칙 문서 계약을 만족하는가
- `index.md`, MOC, `log.md` 변경이 승인 범위와 일치하는가
- Inbox, Archive 포함 여부가 사용자의 선택과 일치하는가
