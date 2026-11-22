---
name: my-team-config
description: my-team 팀을 새로 만들거나, 실행 중인 팀에 워커를 추가하거나, 저장된 팀 config의 워커를 수정할 때 사용한다. 워커의 작업·목적에 맞는 plugin을 stack(로컬)과 Claude 마켓플레이스에서 골라 --plugin-dir로 주입하고 extra_prompt를 조합한다. 사용자가 "/my-team-config", "이 작업할 팀 만들어줘", "my-team config 만들어줘", "워커 추가해줘"라고 하거나, my-team orchestrator 워커가 add-worker를 호출하기 직전에 사용. my-team 부팅·shutdown·메일박스 사용법은 my-team 스킬 소관이다.
---

# my-team-config — 팀 생성·워커 추가·워커 수정 + plugin 주입

| 모드 | 언제 | 결과 |
|---|---|---|
| **생성** | 새 팀 | `~/teams/<team>.json` 저장 + `--dry-run` 검증. 부팅은 하지 않는다 |
| **추가** | 실행 중인 팀에 워커 1명 | `my-team add-worker` 실행 |
| **수정** | 저장된 config의 워커 변경 | `~/teams/<team>.json` 갱신. 다음 `start`부터 적용 |

실행 중인 워커의 plugin·extra_prompt는 바꿀 수 없다 (my-team에 변경 명령이 없고, 워커 CLI는 부팅 때 로드한다). 바꿔야 하면 추가 모드로 새 설정의 후임을 띄우고 my-team 스킬의 "Worker succession" 절차로 교대한다.

경로 표기:
- `$STACK` = `$HOME/IdeaProjects/my-productivity/stack`. config·명령에는 **펼친 절대경로**로 쓴다 (my-team은 `launch_args`를 셸 인용해 넘기므로 `~`·`$HOME`이 확장되지 않고, 틀린 `--plugin-dir`은 에러 없이 무시된다).
- `<skill-dir>` = 이 SKILL.md가 있는 디렉토리.

## 진행 원칙

- 단계별로 진행하며 각 단계 입력을 받기 전에는 다음 단계로 넘어가지 않는다.
- 사용자가 적은 텍스트(팀 목적, 워커 합류 이유)는 **추론으로 살을 붙이지 말고 그대로 옮긴다.** extra_prompt에 덧붙이는 것은 Step 5가 정한 조각뿐이다. 사용자가 명시하지 않은 "먼저 읽어야 할 파일", "첫 산출물", "peer 의존"을 만들어 넣지 않는다.
- 확인 질문은 이 스킬을 실행하는 쪽의 대화 상대(사용자)에게 한다. orchestrator 워커가 사용자 없이 추가 모드를 실행할 때는 확인 단계 대신 선택 근거를 보고에 남긴다. 단, **외부 repo에서 새로 받는 plugin(kind `url`·`git-subdir`)은 사용자 확인 없이는 받지 않는다.**
- 파일 저장은 `Write` 도구로 한다 (Bash heredoc 금지 — JSON 이스케이프 부담).

## Step 0 — 사전 조사 (생성 모드)

1. 대상 레포마다 README·CLAUDE.md, 의존성(package.json/build.gradle 등), 배포·인프라 파일, `git status`(미커밋 변경 = 다른 작업 진행 중), `git log -3`, 가능하면 테스트 실행. 조사 결과(목적·진행도·제약)를 먼저 보여주고 그 근거로 팀을 제안한다.
2. 목표가 모호하면 팀을 짜기 전에 번호 선택지로 하나씩 묻는다. 같은 대상이라도 "마무리/신규 기능/UI 개선/재작성"에 따라 워커와 plugin이 다르다.
3. 단계를 분리한다.
   - 분석·결정 단계 워커는 읽기 전용. 같은 cwd를 공유해도 된다.
   - 구현 워커는 계획이 승인된 뒤 orchestrator가 추가 모드(`add-worker --worktree`)로 띄운다. 처음부터 띄우지 않는다. 선행 산출물이 필요한 워커도 나중에 추가한다.
4. 결정 팀 패턴(산출물이 결정 문서인 팀): orchestrator + 주제별 분석 워커(병렬) + 반박 전담 워커 1명. 반박 워커는 가능하면 다른 모델 계열(codex)로 두어 같은 사각지대를 피한다. 산출물은 결정별 ADR.

사용자가 팀 구성을 이미 구체적으로 적어 왔으면 조사 결과와 어긋나는 점만 짚고 Step 1로 간다.

## Step 1 — 가이드 + 자유서술 입력

사용자는 config 스키마를 모를 수 있다. **먼저 가이드를 보여주고**, 입력 형식은 강제하지 않는다. Step 0에서 제안한 팀을 사용자가 받아들였으면 그 내용을 이 형식으로 채워 보여주고 확인만 받는다.

**워커 수는 따로 묻지 않는다.** 적힌 워커 목록의 개수가 워커 수다. 불렛, 넘버링, "첫 번째 워커:" 같은 자연어 등 **어떤 나열 형식이든 파싱한다.**

가이드 출력 형식 (이걸 그대로 보여준다):

```
my-team config를 함께 만들어 볼게요. 아래 항목을 자유로운 형식으로 적어주세요.
(워커 수는 따로 세지 않습니다. 적어주신 워커 줄 수가 곧 팀 인원이 됩니다.)

━━ 팀 (필수) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  • team_name   팀 이름            소문자·숫자·하이픈 (예: order-cache-poc)
  • team_goal   이 팀이 모인 목적   자유서술 1~3문장

━━ 워커 (필수, 원하는 만큼 줄로 나열) ━━━━━━━━━━━━━━━━━━━
  각 워커 한 줄에 아래를 담아주세요. 불렛/숫자/자연어 무엇이든 OK.
  • name        워커 식별자         [a-zA-Z0-9-]+ (예: alpha)
  • cwd         작업 디렉토리        절대경로 또는 ~/ 로 시작
  • agent_type  에이전트 종류        claude / codex / gemini / cursor
  • 합류 이유    이 워커가 맡을 일      자유서술
  • role (선택) orchestrator / worker  하나라도 쓰면 orchestrator 최소 1명

━━ 자동 처리 (입력 불필요) ━━━━━━━━━━━━━━━━━━━━━━━━━━
  • description  합류 이유에서 한 줄 요약 초안 → 확인받음
  • plugin       claude 워커는 역할에 맞는 plugin 추천 → 확인받고 주입
  • 권한 플래그   주입 여부를 따로 묻습니다
  • 작업판       기본으로 켭니다. 빼려면 "작업판 빼줘"

─ 예시 ─
  팀 이름: order-cache-poc
  목적: 주문 캐시 PoC. Redis를 도입해 응답 지연을 줄인다.
  - pm    @ ~/work/api / claude / orchestrator — 범위 결정, 티켓 분배
  - alpha @ ~/work/api / claude — 백엔드 API 담당, 캐시 키 설계
  - beta  @ ~/work/order / codex — invalidation 로직 책임
```

입력을 받으면 파싱한다. **형식이 달라도 의미가 명확하면 진행한다.** 다음 경우에만 되묻는다.

- 필수 항목이 명백히 누락됐을 때 — 누락된 항목만 짚어서 묻는다.
- 사용자가 인원수를 언급("3명이야")했는데 적힌 워커 줄 수와 다를 때.
- `agent_type` 등을 추측해서 채웠을 때 — 한 번 더 확인한다.

## Step 2 — 검증

파싱 결과를 **표로 한 번 보여준 뒤** 자동 확인한다. 표 하단에 워커 수를 합계로 노출한다.

```
파싱 결과 — order-cache-poc (워커 3명)

  #  name    cwd            agent    role          합류 이유
  ─  ──────  ─────────────  ───────  ────────────  ────────────────────────
  1  pm      ~/work/api     claude   orchestrator  범위 결정, 티켓 분배
  2  alpha   ~/work/api     claude   worker        백엔드 API 담당, 캐시 키 설계
  3  beta    ~/work/order   codex    worker        invalidation 로직 책임

목적: 주문 캐시 PoC. Redis를 도입해 응답 지연을 줄인다.
```

위반이 있으면 **어느 워커(#번호와 name)의 무엇이 문제인지** 짚어서 수정 요청한다.

- `team_name`은 `^[a-z0-9][a-z0-9-]{0,48}[a-z0-9]$`
- 워커 개수 1~10
- `name`은 `[a-zA-Z0-9-]+`, 워커 간 중복 없음
- `agent_type`은 `claude` / `codex` / `gemini` / `cursor` 중 하나
- `role`을 하나라도 썼으면 orchestrator 최소 1명 (role을 안 쓴 워커는 worker로 저장한다)
- `cwd` 디렉토리 존재 — `test -d <path>`
- 같은 cwd를 쓰는 워커가 여럿이면 **코드를 수정하는 워커가 1명 이하인지** 사용자에게 확인한다. `start`는 cwd 공유를 막지 않는다. 수정 워커가 더 필요하면 나중에 추가 모드의 `--worktree`로 띄우도록 안내한다.

**작업판.** 기본으로 켠다(config에 `"board": {"store": "sqlite"}`). 사용자가 빼 달라고 할 때만 뺀다. 누구도 자기가 맡은 작업을 판정하지 못한다. reviewer를 지정하지 않은 작업은 pm이 판정한다(`tools/my-team/docs/board.md`의 `board-verdict` 행과 "Rules that hold on every path"). pm은 orchestrator이고, role을 쓰지 않는 팀이면 워커 전원이다. 리뷰를 누가 할지는 사용자에게 묻지 않는다.
- 워커가 1명뿐이면 작업판을 넣지 않는다. 그 워커의 작업을 판정할 다른 워커가 없기 때문이고, 이 이유를 사용자에게 알린다.
- 리뷰 역할 워커가 목록에 없으면 리뷰어 워커 하나를 추가하자고 제안한다(기본 "예"). 이 워커는 읽기 전용이라 구현 워커와 cwd를 공유해도 된다. 구성은 `$STACK/CATALOG.md`의 reviewer 조합을 따른다. 받아들이면 목록에 넣고 Step 3 이후를 이 워커에도 적용한다.
- 리뷰 역할 워커(사용자가 처음부터 넣은 워커 포함)는 config에 `"deny": ["push", "repo-write"]`를 넣는다. 읽기 전용을 지침만이 아니라 훅으로도 지킨다: Edit·Write 도구로 하는 레포 안 수정, 레포를 바꾸는 git 명령, push를 my-team이 막는다. 셸 명령이 파일을 쓰는 것(리다이렉션, 설치, 빌드)은 막지 못하므로 `## 리뷰 방식`의 사본 규칙이 함께 필요하다. claude 워커에만 적용된다. 다른 agent_type이면 넣지 않고, 그 워커의 읽기 전용은 지침뿐이라고 사용자에게 알린다.
- 추가하지 않으면 리뷰어 없이 진행한다. 이때 orchestrator에게 Step 5의 작업판 줄을 넣는다. role을 쓰지 않는 팀은 워커 전원이 pm이라 reviewer 없는 작업을 land할 수 없다. 이런 팀은 작업마다 다른 워커를 reviewer로 지정한다.
- 어느 경우든 작업판은 켠다.

## Step 3 — description 초안 + 일괄 확인

각 워커의 합류 이유로부터 동료 Roster에 노출될 **한 줄 description**을 초안 생성하고, 모든 워커를 한 표로 보여준다.

```
Roster에 노출될 description 초안입니다. 이대로 좋으면 'ok', 고칠 게 있으면 "2번 ~로" 처럼 알려주세요.

  #  name    description (한 줄, ≤80자)
  ─  ──────  ──────────────────────────────────────────
  1  pm      범위 결정·티켓 분배 (orchestrator)
  2  alpha   주문 API — 캐시 키 설계 담당
  3  beta    주문 도메인 — 캐시 invalidation 책임
```

- 한 문장, 80자 이내. "무엇을 담당하는 워커인지"가 드러나게.
- 합류 이유를 압축하되, 없는 사실을 추가하지 않는다.

## Step 4 — plugin 선택·주입 (claude 워커만)

codex/gemini/cursor 워커는 이 단계를 건너뛴다 (`--plugin-dir`은 claude 전용 플래그). 후보 소스는 **stack과 Claude 마켓플레이스 두 곳뿐**이다.

1. **후보 조회** — `python3 -I <skill-dir>/scripts/plugins.py catalog`
   - `[stack]`: `절대경로 / name / version / description / skills`
   - `[marketplace]`: `id / category / kind / installs / always_on / description` (설치 수 내림차순). stack에 같은 이름이 있는 것, 전역으로 이미 켜진 것은 빠져 있다.
   - 출력은 약 330줄(≈15k token)이다. 한 번만 읽고 워커 전원의 선택에 재사용한다.
   - stderr의 `warn <경로>`는 받아 둔 plugin이 upstream에서 삭제·이동된 것이다. 사용자에게 보여주고 그 plugin은 후보에서 뺀다.
2. **큐레이션 메모** — `$STACK/CATALOG.md`가 있으면 §1(고르는 경우·붙이지 않는 경우), §2(사용 규칙 조각), §4(함정)를 읽는다. 메모가 있는 plugin은 **메모가 자동 설명보다 우선**한다. 메모의 "붙이지 않는 경우"에 해당하면 설명이 맞아도 넣지 않는다.
3. **워커별 선택**
   - 워커의 합류 이유·description과 plugin 설명의 대응을 한 줄로 설명할 수 있는 것만 넣는다. 워커당 0~3개, 0개도 정상이다. 한 워커에 많이 붙이지 않는다 (skill 목록이 커질수록 라우팅이 흐려진다).
   - stack을 우선한다. stack에 맞는 것이 없을 때만 마켓플레이스에서 고른다. 마켓플레이스 후보끼리는 설치 수가 높은 쪽을 우선하고, `always_on`이 1000 이상이면 추천 이유에 그 비용을 적는다.
4. **표로 확인** — 사용자가 일괄 OK 하거나 워커별로 빼거나 더한다 (더할 때는 stack 경로나 catalog id만 받는다).

```
claude 워커별 plugin입니다. 'ok' 또는 "2번 pm-execution 빼줘", "2번에 playwright 추가"처럼 알려주세요.

  #  name    plugin                                  출처          추천 이유
  ─  ──────  ──────────────────────────────────────  ────────────  ─────────────────────────
  1  pm      pm-execution                            stack         티켓·acceptance 작성
  2  alpha   pstack                                  stack         여러 파일 설계·구현
  2  alpha   playwright@claude-plugins-official      마켓(local)   API e2e 확인
  3  beta    (codex — 해당 없음)

새로 받는 외부 repo (훅·MCP 서버를 포함할 수 있고, 워커에서 그대로 실행됩니다):
  - vercel@claude-plugins-official  https://github.com/vercel/vercel-plugin.git
```

   외부 repo 목록의 url은 catalog 원본(`~/.claude/plugins/marketplaces/<marketplace>/.claude-plugin/marketplace.json`의 `source`)에서 옮긴다. 이 확인이 외부 코드를 받는 동의 게이트다 — `ok` 전에는 받지 않는다.
5. **확보** — `python3 -I <skill-dir>/scripts/plugins.py ensure <stack 경로 | id>...`
   - stack에 없으면 받고(외부 repo는 `$STACK/<owner>-<repo>`에 기본 branch를 clone, `.git` 유지. 그 자리에 다른 repo의 clone이 있으면 받지 않고 fail), 있으면 **최신으로 갱신**한다 (git은 `pull --ff-only`, 마켓플레이스 복사본은 version이 다르면 재복사).
   - 출력 줄마다 `ok <절대경로>\t<상태>`. 상태가 `updated`면 표에 버전 변화를 한 줄 보고한다. `update-failed`는 현재 버전으로 주입하고 이유를 사용자에게 보여준다 (로컬 변경이 있는 stack은 강제로 덮지 않는다).
   - `fail <id>\t<이유>`가 있으면 이유를 그대로 보여주고 재시도/제외 중 하나를 묻는다. "갱신 뒤 경로가 없음"은 upstream에서 삭제·이동된 것이므로 재시도하지 말고 다른 plugin을 고른다.
   - stack은 여러 팀이 같이 쓴다. 갱신은 다른 팀이 다음에 띄우는 워커에도 적용된다.
6. `ok` 경로를 그 워커의 plugin 목록으로 기억해 Step 6에서 쓴다. 새로 받은 plugin은 출처 한 줄을 `$STACK/SOURCES.md`에 덧붙인다 (`- <디렉토리>: <kind>, <url 또는 marketplace> (YYYY-MM-DD 배치)`).

## Step 5 — extra_prompt 조립

각 워커의 `extra_prompt`를 다음 템플릿으로 조립한다. `{...}` 외 텍스트는 변형하지 않는다. 내용이 없는 섹션은 제목째 뺀다.

```
## 팀의 작업 목적
{team_goal — 그대로}

## 너의 역할
{이 워커의 합류 이유 — 그대로}

## 확정된 결정 — 다시 묻지 않는다
{이 세션에서 사용자와 이미 정한 범위·기술 선택·형태. 없으면 섹션 생략}

## plugin 사용 규칙
{Step 4에서 주입한 plugin 중 CATALOG.md §2 조각이 있는 것만, 조각 그대로}

## Worker Knowledge
Documents this worker may need. Before work a line below describes, read that document yourself instead of asking a peer:
{Step 6a에서 이 워커용으로 고른 문서마다 한 줄: - `<절대경로>`: <about>}

## 리뷰 방식 — 리뷰 서브에이전트를 지휘한다
- 판정 기준, 작업 간 맥락(진행 중인 다른 작업, 같은 파일을 건드리는 branch, 이전 제출의 지적), 최종 판정과 지적의 심각도, 판정 기록과 리뷰 보고서는 네가 쥔다.
- 제출별 정독(diff, 티켓의 acceptance 대조)과 확인 명령 재실행은 자기 CLI의 리뷰 서브에이전트에게 맡긴다. 대기열에 여러 건이 있으면 제출마다 하나씩 동시에 띄운다.
- 브리프에 넘길 것: 티켓, 제약, 커밋 범위(base와 제출 커밋), 담당 보고서, 이 제출과 관계있는 맥락, 적용할 기준, 보고 형식(지적마다 코드, 심각도 제안, 요약, 재현 명령, file:line). 저장소 수정과 push는 금지하고, 검증은 커밋을 꺼낸 사본에서 하게 한다.
- 브리프에 넘기지 않을 것: 네 결론이나 의심. 볼 곳은 넘기되 답은 넘기지 않는다.
- 서브에이전트 결과를 그대로 믿지 않는다. 판정에 적는 재실행 결과와 필수 지적의 재현은 직접 돌려 확인한 뒤 기록한다. "문제없음"만 오면 무엇을 확인했는지 목록을 받는다. 병렬 branch 사이의 충돌은 서브에이전트가 볼 수 없으니 네가 본다.
- 네 재실행도 제출 커밋을 꺼낸 사본에서 한다(`mktemp -d`, `git archive <커밋> | tar -x -C <그 폴더>`, 필요하면 그 안에서 의존성 설치). 다른 워커와 함께 쓰는 작업 폴더에서 확인 명령, 설치, 빌드를 돌리지 않는다.
- 작은 변경(문서, 한두 줄)은 직접 봐도 된다. 판정은 항상 네 이름으로 남는다.
- 리뷰 보고서에 서브에이전트가 본 것과 네가 직접 확인한 것을 나눠 적고, 올리지 않은 서브에이전트 지적은 이유를 한 줄씩 남긴다.

## 외부 시스템 안전 규칙
- 클라우드 CLI: 읽기 호출(describe/list/get)만. 생성·변경·삭제는 금지, 필요하면 orchestrator에게 제안만. 시크릿 값 조회 금지(키 이름만).
- 운영 DB·결제 API·외부 서비스 쓰기 호출 금지.
- 사용할 계정·프로파일: {사용자가 정한 값}
- 다른 작업의 미커밋 변경이 있는 메인 트리에서는 구현하지 않는다 (worktree).

## 산출물
대상 레포의 기존 문서 컨벤션(docs/plans/, docs/adr/ 등)을 따르고, 없으면 docs/<주제>/. {커밋 줄}

## 협업
{협업 줄}
```

`{커밋 줄}`과 `{협업 줄}`은 팀이 작업판을 쓰는지에 따라 고른다.

| | 작업판 없음 | 작업판 사용 |
|---|---|---|
| 커밋 줄 | `커밋은 사용자 승인 후.` | `커밋은 맡은 작업 안에서 하고, 끝나면 board-land로 리뷰를 받는다. push는 사용자 승인 후.` |
| 협업 줄 | ``팀 동료의 도움이 필요하면 Team Roster를 참고해 `my-team api send-message`로 위임하라.`` | ``질문과 결정 요청은 Team Roster를 참고해 `my-team api send-message`로 한다. 일은 작업판으로 맡기고 받는다.`` |

작업판 사용법은 my-team이 워커 지침의 `## Team Board`에 넣으므로 extra_prompt에 되풀이하지 않는다.

- 리뷰 역할 워커의 `## 산출물`은 위 줄 대신 다음 줄로 쓴다: `리뷰 보고서는 레포 밖 {홈 절대경로}/.my-team/docs/{team_name}/ 아래에 쓴다. 레포 안에는 쓰지 않는다(Edit·Write는 deny 규칙이 막는다). 커밋과 push는 하지 않는다.` 경로는 `~`가 아니라 펼친 절대경로로 적는다(훅은 `~`를 펼치지 않아 레포 안 경로로 본다). 작업판을 쓰지 않는 팀이어도 같다.
- **리뷰 방식**은 리뷰 역할 워커에게만 넣는다. 리뷰 역할 워커는 다른 워커의 작업을 판정하고 지적하는 것이 일의 전부이고, 레포에 남길 산출물이 없는 워커다(이름, 합류 이유, description으로 판단한다). 구현과 리뷰를 함께 맡는 워커, 결정 팀의 반박 전담 워커처럼 레포에 문서를 쓰는 워커는 해당하지 않는다. 애매하면 Step 2 확인 때 `deny`를 넣을지 사용자에게 묻는다. Step 2에서 추가를 제안해 넣은 리뷰어 워커도 여기에 든다. 구현·설계 워커와 orchestrator에는 넣지 않는다.
- **외부 시스템 안전 규칙**은 대상이 클라우드 CLI·운영 DB·결제·외부 서비스에 닿을 때만 넣는다. 계정·프로파일을 사용자가 정하지 않았으면 Step 6 질문 때 함께 묻는다.
- **Worker Knowledge**는 Step 6a의 1~3에서 그 워커용으로 고른 문서다. 6a의 1~3을 이 조립보다 먼저 한다. 고른 문서가 없으면 절을 제목째 넣지 않는다. 팀 전체용 문서는 `## Team Knowledge`로 따로 들어가므로 여기에 다시 적지 않는다.
- **orchestrator**의 `## 협업` 끝에 다음 줄을 덧붙인다: `워커를 추가할 때는 my-team-config 스킬(추가 모드)로 plugin·extra_prompt·권한 플래그를 조합한다.`
- 작업판 팀의 orchestrator에는 그 아래에 다음 두 줄을 더 붙인다.
  - `리뷰가 밀리면 먼저 리뷰어 워커가 리뷰 서브에이전트로 여러 건을 동시에 보게 한다. 그래도 밀리면 리뷰어 워커를 추가 모드로 띄우고, 리뷰할 일이 없으면 추가한 리뷰어 워커를 내린다.`
  - 리뷰어 워커가 없는 팀이면 다음 줄을 붙인다: `reviewer를 지정하지 않은 작업은 pm이 판정한다. 판정 전에 자기 CLI의 서브에이전트에게 검토를 시키고 그 결과로 board-verdict를 기록한다. 담당 워커는 자기 서브에이전트로 자기 작업을 판정할 수 없다.`

## Step 6 — launch_args (권한 플래그 + plugin)

1. **권한 플래그를 먼저 묻는다** (기본값은 넣지 않음).

```
워커를 권한 우회 플래그로 띄울까요? (y/N)
  claude: --dangerously-skip-permissions
  codex:  --dangerously-bypass-approvals-and-sandbox
  (gemini/cursor는 해당 없음)
N이면 워커가 첫 permission prompt에서 멈추고, 그 pane에서 직접 답해야 진행합니다.
```

   대상이 클라우드 CLI·운영 시스템에 닿는 팀이면 질문 아래에 한 줄 덧붙인다: `권한 우회로 띄우면 extra_prompt의 외부 시스템 안전 규칙이 유일한 가드입니다.`
2. `launch_args` = (y면) agent_type별 권한 플래그 + Step 4의 plugin마다 `"--plugin-dir", "<절대경로>"` 쌍.

```json
"launch_args": ["--dangerously-skip-permissions", "--plugin-dir", "/Users/me/IdeaProjects/my-productivity/stack/pstack-claude/plugins/pstack"]
```

## Step 6a — 지식 문서 (`knowledge`·`## Worker Knowledge`, 생성·수정 모드)

지식 문서 모음은 `~/.my-team/knowledge/*.md`이다(레포 밖). 각 문서는 맨 위 frontmatter에 `about: <한 줄>`(무엇에 관한 문서이고 언제 읽는지)을 둔다. 목록 파일은 따로 없다.

1. **목록 조회** — `python3 -I <skill-dir>/scripts/plugins.py knowledge`
   - 줄마다 `절대경로<TAB>about`. 본문은 읽지 않는다(이 단계에서 문서 본문을 열지 않는다).
   - `(설명 없음)`인 문서는 목록에 보여 주기만 하고 추천하지 않는다.
   - 출력이 없으면(폴더 없음·빈 폴더) 2~3을 건너뛰고 4의 질문만 한다.
2. **워커별 선택** — Step 4와 같은 기준이다. 워커의 합류 이유·description과 문서 `about`의 대응을 한 줄로 설명할 수 있는 것만 고른다. 0개도 정상이다.
   - 두 명 이상이 고른 문서는 팀 전체용(config의 `knowledge`)으로 올린다.
   - 한 명만 고른 문서는 그 워커용이다. Step 5의 `## Worker Knowledge`에 넣는다.
3. **표로 확인** — 사용자가 일괄 OK 하거나 빼거나 더한다. orchestrator 워커가 사용자 없이 실행하면 확인 대신 선택 근거를 보고에 남긴다.

```
지식 문서입니다. 'ok' 또는 "db-guide 빼줘", "2번에 cloud-guide 추가"처럼 알려주세요.

  대상        문서                                        추천 이유
  ──────────  ──────────────────────────────────────────  ─────────────────────────
  팀 전체     /Users/me/.my-team/knowledge/cloud-guide.md  alpha·beta 모두 클라우드 조회
  2 alpha     /Users/me/.my-team/knowledge/db-guide.md     캐시 키 설계에 DB 조회 필요
  (설명 없음) /Users/me/.my-team/knowledge/old-notes.md    추천 안 함
```

4. **모음 밖 문서** — 사용자에게 묻는다: "이 밖에 팀의 모든 워커가 알아야 할 공통 문서가 있습니까? (예: 클라우드·DB 조회 절차, 프로필별 용도, 네이밍 규칙, 보호 정책)" 있으면 문서마다 절대경로(또는 `~/`)와 한 줄 `about`을 받는다.

경로는 모음 문서든 직접 받은 문서든 config에 **펼친 절대경로**로 쓴다.

```json
"knowledge": [{"path": "/Users/me/.my-team/knowledge/cloud-guide.md", "about": "클라우드 조회 절차와 보호 정책. 클라우드 CLI를 쓰기 전에 읽는다"}]
```

- my-team은 문서 본문을 복사하지 않고 경로와 about만 모든 워커의 AGENTS.md(`## Team Knowledge`)에 넣는다. 나중에 add-worker로 들어온 워커도 같은 절을 받는다. 워커용 문서도 extra_prompt에 경로와 about만 넣는다.
- my-team CLI에는 워커별 knowledge 필드가 없다. 워커 한 명용은 extra_prompt의 `## Worker Knowledge` 절로만 넣는다.
- 문서에는 접속 **방법**(프로필 이름, 엔드포인트, 조회 절차, 보호 정책)만 둔다. 키·토큰·비밀번호는 넣지 않는다. 변경 권한은 지식과 별개라서 `deny` 규칙이나 extra_prompt의 외부 시스템 안전 규칙으로 따로 제한한다.
- 공통 지식으로 줄지 전용 워커를 둘지: 대부분의 조회는 공통 지식으로 충분하다. 각 워커가 문서를 읽고 직접 조회하므로 묻고 기다리는 일이 없어진다. 전용 워커는 둘 중 하나일 때만 둔다. 하나는 조회 결과가 커서 따로 조사·정리해야 하는 경우이고, 다른 하나는 한 번에 한 명만 해야 하는 변경(배포, 데이터 변경)이다.

## Step 7 — 최종 JSON preview + 저장 + dry-run (생성·수정 모드)

최종 JSON을 코드블록으로 보여준다. 바로 위에 `최종 config — <team_name> (워커 N명)` 헤더를 붙이고, "저장할까요? (y/N)"로 1회 확인한다. 키 순서는 `team_name`, `board`(작업판을 쓸 때), `knowledge`(있을 때), `workers[].{name, cwd, agent_type, role, launch_args, deny, description, extra_prompt}` 고정 (`role`은 팀이 role을 쓸 때만, `deny`는 리뷰 역할 워커만). JSON 바로 아래에 한 줄을 붙인다. 작업판을 켰으면 `작업판: 켜짐 (빼려면 "작업판 빼줘")`, Step 2에서 뺐으면 `작업판: 없음 (<이유>)`이라고 쓴다.

```json
{
  "team_name": "order-cache-poc",
  "board": {"store": "sqlite"},
  "workers": [
    {"name": "pm", "cwd": "/Users/me/work/api", "agent_type": "claude", "role": "orchestrator", "launch_args": [], "description": "범위 결정·티켓 분배 (orchestrator)", "extra_prompt": "…"},
    {"name": "alpha", "cwd": "/Users/me/work/api", "agent_type": "claude", "role": "worker", "launch_args": [], "description": "주문 API — 캐시 키 설계 담당", "extra_prompt": "…"}
  ]
}
```

저장 경로 (`~/teams/`는 레포 밖이다 — 팀 config에는 업무 식별자가 들어가므로 이 레포에 두지 않는다):

1. 생성 모드: `~/teams/<team_name>.json`. 이미 있으면 **확인 없이** `~/teams/<team_name>-YYYYMMDDHHMM.json`로 저장하고 "기존 파일이 있어 새 이름으로 저장했습니다"를 덧붙인다.
2. 수정 모드: 대상 파일을 읽어 바뀌는 워커만 Step 2~6을 거친다. 저장 전 바뀐 필드만 before/after로 보여주고 확인 후 덮어쓴다.
   - 대상 파일에 `board`가 없으면 추가할지 묻는다(기본 "예"). 다음 `start`부터 적용되고, 실행 중인 팀에는 적용되지 않는다는 것을 질문에 적는다. 추가하면 Step 2의 작업판 확인을 하고, 기존 워커 extra_prompt도 Step 5의 작업판 문구(커밋 줄, 협업 줄, orchestrator 줄)로 바꾼다.

저장 후 `my-team start --config <저장 경로> --dry-run`을 실행해 출력을 보여준다. 에러면 원인을 짚어 수정하고 다시 저장한다.

종료 메시지에 부팅 명령을 그대로 안내한다. 부팅 후 pane 점검은 my-team 스킬의 "팀 부팅 후 점검" 절차를 따른다.

```
my-team start --config <저장 경로>
```

## 추가 모드 — 실행 중인 팀에 워커 1명

1. 입력: `team`, `name`, `agent_type`, 합류 이유, `role`(팀이 role을 쓰면), `--cwd`(항상 필수), 필요하면 `--worktree <branch>`. worktree 모드에서는 `--cwd`에 대상 git repo 경로를 주면 `<repo>/.worktrees/<name>`에서 뜬다. 같은 레포에서 코드를 수정할 워커는 `--worktree`로 띄운다 (add-worker는 다른 워커가 쓰는 cwd를 거부한다).
2. Step 3(description), Step 4(plugin), Step 6a의 1~3(지식 문서), Step 5(extra_prompt)를 이 워커 1명에 대해 수행한다. team_goal은 현재 팀 config 또는 호출자 자신의 Role Context에서 옮긴다.
   - 팀의 `knowledge`는 manifest에서 자동으로 들어간다. `$MY_TEAM_STATE_ROOT/manifest.json`(사용자가 호출하면 `~/.my-team/sessions/<team>/manifest.json`, 팀 config에 `state_root`가 있으면 그 아래)의 `knowledge` 경로에 이미 있는 문서는 추천에서 뺀다.
   - 고른 문서는 이 워커의 `## Worker Knowledge`에 넣는다.
   - 리뷰 역할 워커면 Step 5의 `## 리뷰 방식`과 리뷰어용 `## 산출물` 줄을 넣고, claude 워커면 명령에 `--deny push,repo-write`를 붙인다. `deny`는 호출자에게서 물려받지 않으므로 매번 직접 준다.
   - 실행 중인 팀의 작업판 여부는 바꿀 수 없다. 같은 manifest에 `board`가 있으면 작업판 팀이다. Step 5의 커밋 줄과 협업 줄은 그것에 맞춰 고른다.
3. 권한 플래그:
   - orchestrator 워커가 호출할 때: `$MY_TEAM_STATE_ROOT/manifest.json`에서 자기(`$MY_TEAM_WORKER`의 `/` 뒤 이름) 항목의 `launch_args`를 본다. `--dangerously-*` 플래그가 있으면 **새 워커의 agent_type에 맞는 플래그**(Step 6 목록: claude `--dangerously-skip-permissions`, codex `--dangerously-bypass-approvals-and-sandbox`, gemini/cursor 없음)를 넘긴다. 호출자 플래그를 그대로 복사하면 agent_type이 다를 때 새 CLI가 모르는 플래그로 기동에 실패한다. **`--launch-arg`를 하나라도 주면 호출자 인자 상속이 꺼지므로**, plugin만 넘기고 권한 플래그를 빠뜨리면 새 워커가 첫 permission prompt에서 멈춘다.
   - 사용자가 호출할 때: Step 6의 질문을 한다.
4. description과 extra_prompt는 **`Write` 도구로 파일에 쓴 뒤** `"$(cat <파일>)"`로 넘긴다 (세션 scratchpad, 없으면 `$TMPDIR` 아래). 텍스트를 명령줄 큰따옴표 안에 직접 넣으면 템플릿의 backtick(`` `my-team api send-message` ``)이나 사용자 원문의 `$`·`"`를 셸이 해석해 명령이 실행되고 prompt가 손상된다. add-worker에는 파일 입력 옵션이 없다.
5. 명령을 보여주고(사용자가 호출했으면 확인 후) 실행한다.

```
my-team add-worker --team <team> --name <name> --agent-type <type> --cwd <절대경로> \
  [--worktree <branch>] [--role <role>] [--deny push,repo-write] \
  --description "$(cat <description 파일>)" --extra-prompt "$(cat <extra_prompt 파일>)" \
  --launch-arg <권한 플래그> --launch-arg --plugin-dir --launch-arg <plugin 절대경로> ...
```

6. 저장된 팀 config(`~/teams/<team>.json`)에 이 워커를 반영할지 묻는다. `--deny`를 줬으면 `"deny": ["push", "repo-write"]`도 함께 반영한다. 반영하면 다음 `start`에도 같은 워커가 뜬다. 이 워커의 `## Worker Knowledge` 문서도 extra_prompt와 함께 반영된다는 것을 질문에 적는다.
7. 이미 떠 있는 워커에게 문서를 알려야 하면 `my-team api send-message`로 경로와 about 한 줄을 보낸다. 지침(AGENTS.md·extra_prompt)은 워커를 다시 띄워야 바뀐다.

## 중간 분기 — 워커 추가/제거 (생성 모드 도중)

인터뷰 도중 워커를 추가하거나 제거하고 싶다고 하면 Step 1로 돌아가 워커 목록을 다시 받는다. Step 3 이후의 description 초안과 Step 4 plugin 선택은 새 목록 기준으로 다시 한다.
