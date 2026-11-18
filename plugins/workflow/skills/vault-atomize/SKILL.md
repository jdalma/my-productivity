---
name: vault-atomize
description: memory-palace류 vault의 Note에 쌓인 decision_candidates를 검토해, 장기 추적 가치가 있는 것만 독립 Decision 노트로 승격한다. 중복 후보를 정리하고, 원본 Note 본문은 불필요하게 재작성하지 않는다. 사용자가 "decision 후보 정리해줘", "이 노트의 결정 분리해줘", "Decision으로 승격", "/vault-atomize" 같이 요청할 때 사용. 자동 git commit 금지.
---

# vault-atomize — decision_candidates → Decision 승격

> Note에 누적된 `decision_candidates`를 모아 클러스터링하고,
> **장기 추적 가치가 있는 항목만** 독립 Decision 노트로 승격한다.
> vault-ingest가 후보로 심은 것을 결정으로 거두는 단계다.

## When to use

- Note의 `decision_candidates`가 쌓여 독립 Decision으로 뽑아낼 때가 됐을 때
- 여러 Note에 흩어진 같은 결정 후보를 하나의 Decision으로 모으고 싶을 때
- vault-ingest 직후, 심어둔 후보 중 승격 대상을 골라낼 때

## Input

호출 인자로 다음 중 하나를 받는다.

- **빈칸** — vault 전체의 Note에서 `decision_candidates`를 수집해 검토한다.
- **Note 경로** — 그 Note의 후보만 검토한다.
- **후보 title** — 특정 후보(또는 그와 묶일 후보들)만 검토한다.

## Vault 위치와 계약

- vault 경로: 인자로 주어지면 그것, 없으면 `~/knowledge/memory-palace`.
- Decision 파일명·frontmatter·필수 섹션·MOC 등록 계약은 이 스킬에 적지 않는다.
  쓰기 전에 vault 루트 규칙 문서(`AGENTS.md` 또는 동등물), Notes·Maps 폴더 규칙 문서,
  Decision 템플릿을 읽어 그대로 따른다.

## 승격 판단

- 같은 결정을 가리키는 후보는 하나로 묶는다 (여러 Note에 흩어진 것 포함).
- 승격 / 유지 / 제거 각각에 근거를 붙인다. **전부 승격하지 않는다.**
  기준은 장기 추적 가치 — 나중에 "왜 그렇게 했지"를 되묻게 될 트레이드오프 선택인가.
- 기존 Decision과 근접 중복이면 새로 만들지 않고 기존 Decision에 연결한다.

## Write Order

1. 대상 Note 수집 (빈칸 / 경로 / title에 따라)
2. 후보 클러스터링
3. 승격 / 유지 / 제거 판단 + 근거
4. 승인 리포트 제시 — **여기서 멈추고 승인을 받는다**
5. 승인 후 Decision 작성 (vault 계약 준수)
6. 원본 Note의 `decision_candidates` 갱신 — 승격분을 Decision 링크로 치환. 본문은
   건드리지 않는다.
7. 실제 vault knowledge 변화일 때만 `index.md`, `log.md`, MOC 갱신

## Verification

- 새 Decision이 Notes 폴더 규칙 문서의 Decision 계약을 만족하는가
- 원본 Note에 남은 `decision_candidates`가 올바른가 (승격분 정리됨)
- 중복 Decision을 만들지 않았는가 (기존 Decision과 근접 중복 확인)
