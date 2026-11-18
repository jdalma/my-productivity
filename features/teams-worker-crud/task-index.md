---
feature_name: teams-worker-crud
created_by: handoff
created_at: 2026-05-14
plan_status: not_run
---

# teams-worker-crud

워커 CRUD 명령(`my-team remove`, `my-team add`)을 my-team CLI에 추가한다. 사용자가 부팅 시점에 잘못 박은 cwd·agent_type 등을 정정하기 위해 팀 전체를 shutdown·재부팅하지 않고도 일부 워커만 교체 가능하게 한다.

## Slices

> /plan 미실행. 슬라이스로 분해하려면 다음 세션에서 `/plan`을 호출하라 (4번째 옵션 `fill`로 Slices·Decisions 채움).

## TODO

- [ ] 다음 세션에서 `/takeover`로 인계 검증 후 `/plan fill`로 slice 채우기
- [ ] §결정 필요 사항 4건(섹션 아래)에 대한 사용자 결정 받기
- [ ] `commands/remove.js` 신규 (~80줄): manifest 항목 제거 + tmux kill-pane + 파일 정리(정책 결정 필요) + tiled 재적용
- [ ] `commands/add.js` 신규 (~120줄): start.js의 단일-워커 spawn 로직 재사용해 새 워커 추가 + manifest 갱신
- [ ] `commands/start.js` 리팩토링 (~30줄): 단일 워커 spawn 로직을 add.js와 공유 가능한 함수로 추출
- [ ] `cli.js` 라우팅 추가 (~10줄): remove / add 두 명령 등록
- [ ] README.md 갱신: remove/add 명령 사용법 + 결정 사항 명시
- [ ] `tools/my-team/docs/architecture.md` 갱신: 통신 5종 매트릭스에 워커 교체가 미치는 영향 (mailbox/tasks orphan 처리 등)
- [x] **`worker-bootstrap.js`에서 leader-fixed 의존 표현 7곳 제거 (peer-to-peer 모델로 정합화)** — 옵션 (i) 완전 제거로 진행. AGENTS.md 생성 결과 검증 완료 (leader-fixed 등장 0, peer-to-peer 정체성 박힘)
- [x] **leader-fixed 진짜 제거 (코드·문서 전수)** — critic 리뷰가 짚은 잔재 3곳 정리: send-message.js 분기 제거 + 명시적 에러 반환, state-paths.js의 leaderInbox 엔트리 삭제, architecture.md 채널 매트릭스 5종 → 4종 + 다이어그램·예시·부록 정리. 채널 카운트와 코드 정합 회복.

## Decisions / Traps (수명 긴 메모)

### 결정 필요 — 4건 (다음 세션 진입 시 사용자에게 확인)

- [pending][plan] **(a) remove 시 mailbox/tasks 처리 정책** — 세 옵션 중 하나 결정:
  - α: 함께 삭제 (깨끗한 제거)
  - β: 보존 기본, `--purge` 줘야 삭제
  - γ: 항상 보존, `--purge` 줘야 삭제
  - 영향: 같은 이름 재사용 시 새 워커 LLM이 옛 메시지를 보게 되는 위험 vs 데이터 보존 가치

- [pending][plan] **(b) 같은 이름 재사용 허용 여부** — 새 워커가 옛 워커 이름을 재사용하면 mailbox/inbox에 옛 메시지가 그대로 보임. 경고 + y/n 확인 vs 즉시 거부 vs 무조건 허용.

- [pending][plan] **(c) Orphan task 처리** — 워커 A가 워커 B에 task 위임한 상태에서 B remove. `tasks/N.json`의 `owner: B`는 어떻게? 세 옵션:
  - (i) 그대로 둠 (owner: B 유지, 처리할 워커 없음)
  - (ii) 자동 `failed` 상태 전이
  - (iii) 사용자에게 새 owner 묻기

- [pending][plan] **(d) 워커 수 제한** — 현재 1~10. add로 11번째 시도 시 거부 vs 한도 늘리기.

- [resolved][plan] **(e) worker-bootstrap.js의 leader-fixed 의존 제거 정책** — 옵션 (i) 완전 제거 채택. 7곳 모두 peer-to-peer 모델로 재작성:
  - agentTypeGuidance 4분기: leader-fixed 표현을 "사용자가 이 페인을 직접 관찰" 표현으로 교체
  - 본문 헤더: "team worker, not the team leader" → "one of N workers collaborating peer-to-peer"
  - MANDATORY WORKFLOW: 4단계(claim/work/ACK/transition) → 3단계(claim/work/transition). Step 3 'Send ACK to the leader' 완전 제거. Step 2에 "사용자 페인 prompt로 권한 받기" 명시
  - sendAckCommand 변수와 'Startup Handshake' 섹션 완전 제거
  - Message Protocol: "To leader: leader-fixed로 보내기" 제거 + "사용자한테는 stdout, 다른 워커는 peer mailbox" 안내
  - Rules: "You are NOT the leader. Never run leader orchestration workflows" 제거
  - 검증: AGENTS.md 생성 결과 leader-fixed 등장 0, peer-to-peer 정체성 박힘 확인

### leader-fixed 자취 — worker-bootstrap.js 7곳 위치 (다음 세션 작업용)

- `worker-bootstrap.js:66` "If a command fails, report the exact stderr to leader-fixed before retrying."
- `worker-bootstrap.js:72` "Execute task work in small, verifiable increments and report each milestone to leader-fixed."
- `worker-bootstrap.js:87` "Keep reasoning focused on assigned task IDs and send concise progress acks to leader-fixed."
- `worker-bootstrap.js:88` "Before any risky command, send a blocker/proposal message to leader-fixed and wait for updated inbox instructions."
- `worker-bootstrap.js:110` startup ACK 명령 자동 주입 (`team api send-message --to leader-fixed --body "ACK: ${workerName} initialized"`)
- `worker-bootstrap.js:125, 181, 193` 워커 정체성 강제 ("You are NOT the leader", "Send ACK to the leader")
- `worker-bootstrap.js:176` leader 보내는 명령 템플릿 자동 노출

### 사실 (이번 세션에서 확정)

- [resolved][plan] 워커 CRUD 인터페이스는 `update` 단일 명령이 아닌 `remove` + `add` 두 명령 (사용자 결정). 더 명시적·유연.
- [resolved][plan] 추정 구현 비용 ~270줄 (remove 80 + add 120 + start 리팩토링 30 + cli 10 + docs 30)
- [resolved][plan] 기존 manifest.json은 부팅 시점 고정 모델 → CRUD 명령이 manifest.json을 직접 수정해야 함

### 사용자 시나리오의 본질 (배경)

사용자가 my-team start로 4개 워커 부팅했는데 한 워커(예: `api-server`)에 잘못된 cwd 또는 잘못된 launch_args를 박았다. 팀 전체 shutdown+start로 재부팅하면 살아있던 다른 3개 워커의 LLM 컨텍스트가 모두 사라진다. CRUD 명령은 잘못된 워커 하나만 교체해 나머지 워커의 컨텍스트를 보존한다.

### 트랩 / 주의

- [trap][plan] **tmux는 페인 생성 후 cwd 변경 불가.** "cwd만 살짝 수정"은 불가능 — 반드시 페인 kill + 새 페인 생성. 사용자가 페인 안에서 `cd /new/path` 해도 manifest.cwd는 옛 값 유지, AGENTS.md도 옛 cwd 기준.

- [trap][plan] **새 페인 = 새 LLM 프로세스 = 컨텍스트 0.** remove + add는 새 워커의 in-memory 대화 히스토리를 보존하지 않는다. 보존되는 건 mailbox/tasks/events.jsonl 같은 디스크 자산.

- [trap][plan] **tiled 레이아웃은 워커 수가 바뀌면 자동 재배치되지만, 페인 위치가 사용자 기억과 달라질 수 있다.** add/remove 후 사용자가 어느 페인이 어느 워커인지 헷갈리지 않도록 pane-border-status에 워커 이름 박혀있는 게 중요 (이미 적용됨, c4c7126).

---

## 워커 간 파일 공유 (옵션 B+C 재설계)

워커끼리 큰 내용을 텍스트로 보내면 토큰 비용 큼. 큰 내용은 파일로
작성하고 그 경로를 mailbox로 전달하는 패턴 도입. 단 critic 리뷰
(verdict: REVISE)가 원안에 13건 MAJOR 지적 → 재설계 필요.

### 원안 (보류)

- 옵션 B: AGENTS.md에 다른 워커들의 cwd 목록을 박아 "이 경로들 자유롭게 읽어도 된다"
- 옵션 C: `~/.my-team/sessions/<team>/shared/` 공유 디렉터리 신설

### critic 리뷰 결과 (요약)

핵심 충돌 5건:
1. **codex `-s workspace-write` 모드에서 shared/ 침묵 차단** — shared/가 워커 cwd 밖이라 sandbox에 막힘
2. **AGENTS.md "자유롭게 읽어라"가 권한 정책 가정** — claude 기본 모드 prompt 폭주
3. ~~leader-fixed 잔존이 채널 매트릭스와 불일치~~ → **f5806d0에서 해결됨**
4. **수신 LLM이 mailbox body의 경로를 follow할 보장 없음** — 자유 텍스트 안 경로는 신뢰성 낮음
5. **worker-CRUD와 비호환** — AGENTS.md hot-reload 불가, 워커 add/remove 시 peer paths stale

### 결정 필요 — critic 권장 5건 (한 번에 받아야 재설계 진입 가능)

- [pending][plan] **(f) codex sandbox 처리** — shared/를 (i) 워커 cwd 내부로 옮김, (ii) codex의 additional-writable-roots 옵션 검증 후 launch_args에 자동 주입, (iii) codex 워커는 옵션 C 미지원 — 어느 쪽?

- [pending][plan] **(g) shared/ 정식 채널 vs mailbox attachment** — (i) shared/를 새 5번째 채널로 정식화 (architecture.md 매트릭스에 행 추가), (ii) send-message API에 `attachment_paths: string[]` 필드 추가해 mailbox attachment로 흡수 — critic은 (ii) 강력 권장 (채널 수 안정성·구조화·신뢰성). 어느 쪽?

- [pending][plan] **(h) architecture.md 갱신 범위 정량화** — 현재 ~30줄 추정은 매트릭스/§3 2단계 패턴/§4 메시지 스펙/§10 체크리스트 갱신을 포함하지 않은 underestimate. 정확한 갱신 범위 합의 후 진입.

- [pending][plan] **(i) shared/ 4규칙 명시 문자열** — AGENTS.md에 박을 정확한 문자열로:
  - **동시성**: shared 파일은 `mv tmp final` atomic 패턴, 절반 쓰기 노출 금지
  - **시크릿**: API 키·DB 패스워드·토큰 등 비밀 작성 금지
  - **정리**: shutdown 시 처리 정책 (보존 vs --purge vs 자동 백업+클리어)
  - **파일명**: `<from-worker>-<topic>-<timestamp>.<ext>` 또는 `shared/<worker>/...` 격리

- [pending][plan] **(j) worker-CRUD 호환성** — peer paths를 (i) 정적 AGENTS.md 박기 (CRUD 시 워커 재시작 필요로 표시) 또는 (ii) 동적 lookup API `my-team api list-peers --json` 도입 — 어느 쪽? 후자는 옵션 B의 구현이 ~25줄에서 다른 형태로 바뀜.

### 추가 결정 사항 (사용자가 이미 결정한 권한 모델 보강)

- [pending][plan] **(k) 권한 모드 × 워커 타입 매트릭스** — claude/codex/gemini/cursor × (peer-cwd-read / shared-write / mailbox-path-follow) 셀별 "지원/제한적/미지원" 표 design에 명시. cursor는 reviewer/critic 역할 불가하므로(worker-bootstrap.js:81) shared/ 패턴이 동작할지 별도 검증 필요.

### 13건 MAJOR 전체 (critic 보고 — 우선순위 매기기 위함)

(상세는 git log에서 critic 리뷰 출력 검색. 5건이 결정 사항 (f)-(j)로 추출됨. 나머지 8건은 결정 후 자동으로 처리되거나 구현 단계에서 다룸:)

- shared/ 정리 정책 부재 → (i) 4규칙 중 하나
- shared/ 파일명 컨벤션 부재 → (i) 4규칙 중 하나
- shared/ 재부팅 잔존 충돌 → (i) 4규칙 중 하나
- 자기 자신 필터링 누락 위험 → 구현 단계 (start.js에 헬퍼)
- shared/ 동시 쓰기 race → (i) 4규칙 중 하나
- shared/ 시크릿 유입 → (i) 4규칙 중 하나
- architecture.md 매트릭스 갱신 누락 → (h)
- 워커→사용자 보고와 shared/ 산출물 연결 부재 → (g)가 attachment 채택이면 mailbox 알림으로 자연 해결, shared 채널 채택이면 `my-team monitor`가 shared/ watch 추가 필요

### 진행 순서 (제안)

1. 다음 세션 takeover 시 사용자에게 결정 (f)-(k) 6건 받기
2. 결정 받으면 `/plan` 호출 (4번째 옵션 `fill`로 Slices 채움)
3. 구현 진입
4. 옵션 B+C 1차 PR → critic 재리뷰 → 머지

### 진행 의존성

- (g) 결정이 다른 모든 결정의 형태를 바꿈. attachment 채택이면 (h)·(j)의 범위가 작아짐. shared 채널 채택이면 (i)·(k) 범위가 커짐. → **(g)부터 받기.**
- 워커 CRUD 본 작업(remove/add)도 (j) 결정에 의존. peer paths가 동적 lookup이면 worker CRUD가 peer paths 자동 갱신 효과 봄. → CRUD와 옵션 B+C 묶어서 진행 권장.
