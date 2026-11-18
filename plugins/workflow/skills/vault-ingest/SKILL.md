---
name: vault-ingest
description: 문서·URL·붙여넣은 텍스트, 또는 현재 세션 컨텍스트를 memory-palace류 마크다운 vault에 넣는다. 두 모드가 있다. raw 모드는 분류 없이 Inbox에 status:raw로 빠르게 담는다("일단 inbox에 넣어둬", "정리는 나중에, 일단 담아줘", "지금 세션 내용 캡처해줘"). 분류 모드는 Source / Note / Decision 후보로 분류하고 기존 Note·MOC 연결을 검토한 뒤 승인 후에만 vault 본체에 쓴다("vault에 ingest", "이 문서 vault로 넣어줘", "지금 세션 의사결정 vault로 옮겨줘"). "/vault-ingest" 호출 시 사용. 자동 git commit 금지.
---

# vault-ingest — vault 흡수 (raw 담기 / 분류 → 승인 → 쓰기)

```
raw 정보 ──[ingest raw]──▶ Inbox(status:raw) ──[ingest 분류]──▶ Source/Note ──[atomize]──▶ Decision
                                                 └────────────[prune]────────────┘
```

## 모드 판정

호출 문구로 정한다. 어느 쪽인지 불명확하면 한 번 묻는다:
"Inbox에 raw로 담습니까, 분류해서 vault 본체에 넣습니까?"

| | raw 모드 | 분류 모드 |
|---|---|---|
| 트리거 | "일단", "담아둬", "캡처", "나중에 정리" | "ingest", "vault로 넣어줘/옮겨줘", "정리해서" |
| 결과 위치 | Inbox (`status: raw`) | Notes/Sources 등 vault 본체 |
| 기존 노트 탐색·연결 | 안 한다 | 먼저 한다 |
| index/log/MOC 갱신 | 안 한다 (Inbox는 vault knowledge 아님) | 실제 vault knowledge 변화면 한다 |
| 승인 게이트 | 담을 목록 확인만 | 분류안 승인 |

판단 기준: 분류할 준비가 됐으면 분류 모드, 아직 raw면 raw 모드.

## Input

호출 인자로 다음 중 하나를 받는다.

1. **명시 입력** — 파일 경로(여러 개 가능) / URL / 붙여넣은 텍스트.
2. **세션 컨텍스트** — 인자가 비어 있으면 지금까지의 대화에서 추린다. 추린 목록을
   먼저 보여주고 사용자 확인을 받는다. 임의 선별하지 않는다.
   - raw 모드: 아직 파일로 남지 않은 raw 재료(결론 안 난 생각, 참고용 자료, 정리 안 된
     내용). 요약·재서술 없이 원문 발화를 인용 블록으로 담는다. 범위는 "담을지 말지"로만
     좁힌다.
   - 분류 모드: 영속 가치가 있는 결정·근거·교훈.

## Vault 위치와 계약

- vault 경로: 인자로 주어지면 그것, 없으면 `~/knowledge/memory-palace`.
- 폴더 모델·frontmatter·파일명·Inbox 계약·provenance 규칙은 이 스킬에 적지 않는다.
  쓰기 전에 vault 루트 규칙 문서(`AGENTS.md` 또는 동등물), 대상 폴더 규칙 문서,
  필요 시 `templates/`의 템플릿을 읽어 그대로 따른다.

## raw 모드

1. 입력 확보
2. 담을 목록 제시 → 가벼운 확인 (분류하지 않는다)
3. Inbox 계약의 최소 frontmatter(`status: raw`, 불명확하면 `type: note`)로 Inbox 폴더에
   작성. 한 입력은 한 파일. 재작성·요약·쪼개기를 하지 않는다.
4. 결과 보고 — 파일 경로와, 나중에 분류 모드로 소화하면 된다는 안내

금지: 분류, 기존 노트 연결, `index.md`·`log.md`·MOC 갱신.

## 분류 모드

입력을 다음 중 하나로 분류한다.

- **Source 후보** — 외부 원문. 원문성을 보존한다.
- **Note 후보** — 내 언어로 재구성한 지식.
- **Decision 후보** — 트레이드오프를 동반한 선택. ingest 단계에서는 Note의
  `decision_candidates`에 후보로만 적는다. 독립 Decision 승격은 vault-atomize가 판단한다.
- **Inbox 유지** — 아직 분류가 이른 입력. raw 모드와 같은 처리.

순서:

1. 입력 분석
2. 기존 Note/MOC 탐색 (중복·근접 중복). 새 파일보다 기존 Note 확장·MOC 연결을 우선한다.
3. 분류안 제시 — **여기서 멈추고 승인을 받는다**
4. 승인 후 작성. provenance를 남긴다.
5. 실제 vault knowledge 변화일 때만 `index.md`, `log.md`, MOC 갱신.
   구현 계획·마이그레이션 문서는 vault knowledge로 취급하지 않는다.

## Verification

- 파일이 모드에 맞는 폴더에 들어갔는가 (raw → Inbox, 분류 → 대상 폴더)
- frontmatter가 대상 폴더 규칙 문서 계약과 맞는가
- `[[링크]]`가 끊기지 않았는가
- raw 모드에서 `index.md`·`log.md`·MOC를 건드리지 않았고 입력을 재작성하지 않았는가
- 세션 컨텍스트에서 추린 경우, 사용자가 확인한 항목만 들어갔는가
