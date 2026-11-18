# 플러그인 비교 분석 — my-claude-plugin 개선 관점

> 출처: `plugin-analysis` 멀티워커 세션 (2026-06-03~04). 4개 워커(my-claude-plugin / oh-my-claudecode / gajae-code / oh-my-openagent)가 각 플러그인을 분석하고 교차 비교.
> 목적: my-claude-plugin(workflow·my-team·orchestrator)의 설계 선택을 외부 플러그인과 대조해 **개선건과 비채택 근거를 영속 기록**. (세션 디렉터리는 팀 종료 시 휘발하므로 repo로 이관.)
> 이 문서는 자급식 요약이다 — 세션 경로에 의존하지 않는다.

---

## 비교 대상

| 플러그인 | 한 줄 정의 | 규모 |
|----------|-----------|------|
| **my-claude-plugin** (이 repo) | 개인 워크플로우 하네스 (markdown 스킬 + my-team CLI + orchestrator) | 경량 (스킬 + my-team ~1300 LOC) |
| **oh-my-claudecode (OMC)** | Claude Code 위 멀티에이전트 오케스트레이션 레이어 ("zero learning curve") | ~284K LOC TS |
| **oh-my-openagent (OMO)** | "에이전트를 위한 하네스" — 반(反)단일벤더 멀티모델 | ~313K LOC TS |
| **gajae-code (gjc)** | 자체 코딩 에이전트 하네스 (Bun+TS+Rust 모놀리식) | 모놀리식 |

---

## 1. 양극 지도 (두 직교 축)

네 플러그인은 두 축에서 서로 다른 좌표를 점한다. **우열이 아니라 설계 선택**이다.

### 축 A — 활성화 철학: 자동 활성 ↔ 명시 호출 전용
```
자동 활성 ◀──────────────────────────────▶ 명시 호출 전용
 OMO        OMC                          my-claude-plugin (workflow)
 IntentGate 이중표면(/skill+CLI)          disable-model-invocation 전면
 키워드 1개  키워드+슬래시                 "자동 호출·제안·escalate 금지"
 → 자율모드  (DISABLE_OMC kill switch)    (키워드 오발동 차단이 설계 핵심)
```
- OMO/OMC는 자동 발동의 대가로 kill switch(`DISABLE_OMC`)를 *필요로 한다*. my-claude-plugin은 정반대 극.
- **핵심**: 깊이 사다리(자동=좋음)가 아니라 양극축. 명시 호출 전용의 "얕음"은 결함이 아니라 의도된 선택.

### 축 B — task 배분: 동적 경쟁 claim ↔ spawn시 정적 역할 배정
```
동적 경쟁 claim ◀───────────────────────▶ 정적 역할 배정
 OMO               gjc                    my-team
 owner없는 pool    워커당 owner-사전배정     spawn시 역할 고정
 순수 claim        task 시드 + claim-token  공유 task 객체 없음
 single-repo       single-repo worktree    cross-cwd (다른 레포 N개)
 leader            leader-orchestrator     peer 대칭 (leader 없음)
```
- **3자 독립 수렴**: gjc·OMO·my-team baseline 셋이 *독립적으로* 같은 판별축에 도달.

### 안전장치 — 2차원 분화 (강제 레이어 × 차단/보고)
| 플러그인 | 강제 레이어 | 차단 vs 보고 |
|----------|-------------|--------------|
| OMO | 빌드게이트(메타감사) + per-line(Hashline) | **하드 차단** (stale edit 거부) |
| OMC | 런타임 훅 | **넛지/self-heal** (`pre-tool-enforcer "never block"`) |
| my-claude-plugin | (a)Tool/CLI 런타임(my-team) + (b)규약·세션경계(workflow) | (a)**하드 fail**(65테스트 회귀보장) / (b)**보고**(takeover git stale, 사람 게이트) |

> **결론**: 안전장치는 절대 우열이 아니라 **각 플러그인의 활성화·편집 모델에 종속된 조건부 정당성**. 예: Hashline은 "자율 에이전트가 사람 게이트 없이 공유 파일 동시 편집"에서만 정당 → OMO는 그 조건에 있어 정당, my-claude-plugin은 명시호출+사람게이트라 보류.

---

## 2. 계보 사실 (출처 귀속 정확성)

OMC↔OMO의 다수 안전장치 메커니즘은 **독립 수렴이 아니라 OMO→OMC 단방향 포팅 파생**이다:
- OMC 코드 다수에 `"Ported from oh-my-opencode"` 주석 (`thinking-block-validator`, `empty-message-sanitizer`, `keyword-detector`).
- OMO 원본 교차확인: `thinking-block-validator` / `empty-content-recovery` / `tool-pair-validator` / `plan-format-validator`.

**함의**: 차용을 *나중에라도* 재검토할 때 OMC 경유가 아니라 **OMO 원본 직참조가 손실 없음**.

> 충실성 노트: peer가 인용한 코드 라인(gjc `team-runtime.ts:869`, OMO `claim.ts:45-95`)은 다른 워커 cwd라 이 워커가 직접 검증하지 못했다 — "peer 코드 보고"로 귀속한다. 가장 강한 증거는 단일 코드 라인이 아니라 **3자 독립 수렴**.

---

## 3. 개선건 — 적용 완료 vs 보류 vs 비채택

### ✅ 이번 세션 적용·검증 완료
| 항목 | 커밋 | 검증 |
|------|------|------|
| orchestrator 문서 경로 정정 (`.claude/agents`→`agents`) | `552e6e6` | grep 0건 잔존 |
| 루트 CLAUDE.md에 orchestrator + my-team 모듈 등록 | `552e6e6` | — |
| my-team PLAN.md 헤더 정정 (구현완료·실위치) | `552e6e6` | — |
| **4-에셋 매트릭스 동일성 검사기** (`plugins/workflow/lib/check-state-matrix.mjs`) | `552e6e6` | RED→GREEN→mutation test 완주 |
| **표현 계층 우선순위 명시화** (Skill/Command > CLI > 훅) | `552e6e6` | OMO 차용, CLAUDE.md |
| **my-team api `[mutating]`/`[pure]` 태그** | `e3ce89a` | `api --help`+README 노출, 테스트 65개 통과 |

> 매트릭스 검사기는 실제 drift(`takeover`가 `slice-tdd`를 옛 이름 `tdd`로 표기)를 잡아 정정했다. OMO의 "불변식을 문서가 아니라 테스트로 강제" 발상을 TS-compiler 장치 전체가 아니라 알맹이만 외과적으로 흡수한 사례.
> api 태그: `mailbox-list`는 이름이 "list"인데 spool을 흡수해 mailbox를 재기록하는 **숨은 mutating** — self-poll 규율이 동작하는 메커니즘. `[pure]`는 archive-lookup/status/monitor 3개뿐.

### 🔜 보류 (forward 후보 — 트레이드오프 명시)
| 항목 | 출처 | 보류 사유 |
|------|------|-----------|
| events.jsonl lite audit (lifecycle 이벤트 전용 감사레인) | gjc | K1 trigger false-positive 진단엔 유용하나 **경량 정체성 충돌** |
| 모델 라우팅 스코어러 | OMC/OMO | 규모상 과함. 자동 모델선택 필요가 실증되면 재검토 |

### 🚫 의도적 비채택 — 정당화 확증 (반증 조건 포함)
| 항목 | 판정 | 반증 조건 (도입 시 재검토) |
|------|------|---------------------------|
| claim-token | N/A — 잠글 공유 task 객체 부재 | 다중 consumer 공유 task 큐 도입 시 |
| worktree 자동 integration | 구조적 N/A — cross-cwd라 단일 공유 repo 부재 | single-repo 동시수정 모드 도입 시 |
| leader·task lifecycle | 다른 모델 채택(peer 대칭) | 워커 의존성 조정 필요 시 |
| Hashline 해시페어링 | 보류 — 이미 takeover의 cross-session stale 탐지 보유 | 자율 에이전트 사람게이트 없는 공유파일 동시편집 시 |
| 키워드 의도근접 판정 | 비채택 — 반대 철학(명시 호출 전용) | (철학 불변 시 영구) |
| 메타감사 빌드게이트 전체 / SLOP 3단 필터 | N/A / 비채택 — 단순함 우선에 과함 | — |

> **삭제 3종(claim-token/worktree/leader) 결론**: 3자 독립 수렴 + OMO가 gajae 반증조건 3개를 코드로 전부 실증(peer 보고) → my-team의 삭제는 **반증이 아니라 확증**. "설계가 다르면(정적배정+cross-cwd+peer대칭) 기계장치도 달라야 한다."

---

## 4. 한 줄 결론

**my-claude-plugin은 "명시 호출 전용 × 정적 역할 배정 × 경량 × 조건부 안전장치"라는 일관된 설계 극점을 점한다. OMO/OMC/gjc 대비 약점이 아니라 다른 선택이며, 3자 독립 수렴이 정당성을 확증한다. 차용은 반사 채택이 아니라 falsifiable 반증조건으로 거른다.**
