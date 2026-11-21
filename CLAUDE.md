# CLAUDE.md

## 프로젝트 개요

개인 Claude Code 워크플로우 하네스. 여러 PC에서 동일한 스킬 환경을 쓰기 위한 public 마켓플레이스이면서, 그 스킬이 쓰는 도구와 부트스트랩 스크립트를 함께 둔 레포다. GitHub 이름과 clone 기본 디렉토리는 `my-productivity`이고, 마켓플레이스 이름(플러그인 id, 캐시 경로)은 `my-claude-plugin`이다.

| 영역 | 위치 | 내용 |
|---|---|---|
| 플러그인 | `plugins/workflow/` | 개인 워크플로우 스킬 (도메인 정보 미포함) |
| 도구 | `tools/my-team/` | tmux 멀티프로젝트 워커 오케스트레이션 Node CLI (`npm test`) |
| 도구 | `tools/control-tower/` | my-team 워커와 Claude Code/Codex 세션을 한 화면에 보는 macOS 메뉴바 앱 (Swift, `swift test`) |
| 스크립트 | `scripts/` | public-scan·push-gate(pre-push 검사), `statusline/`(상태 라인 설치) |

플러그인 밖의 도구와 스크립트는 마켓플레이스로 배포되지 않는다. 설치 절차는 `README.md`의 셋업 체크리스트 하나만 따른다.

## 운영 원칙

- **public 레포**: 한 번 push되면 회수가 어렵다. 회사·팀·고객·내부 시스템 식별자가 들어가는 자산은 절대 커밋하지 않는다. pre-push 훅이 `scripts/public-scan.sh`로 검사하며, 패턴 파일은 레포 밖(`~/.config/my-claude-plugin/private-patterns.txt`)에 둔다. CI에도 넣지 않는다.
- **플러그인 자산만**: `~/.claude/settings.json`, 글로벌 `CLAUDE.md` 같은 dotfiles는 별도 트랙으로 관리한다.

## 로컬 개발 워크플로우

### 플러그인 캐시 구조

Claude Code는 플러그인을 **커밋 해시 기반 디렉토리**에 캐싱한다:
```
~/.claude/plugins/cache/my-claude-plugin/<module>/{commit-hash}/
```

`.orphaned_at` 파일이 없는 디렉토리가 **active** 버전이다.

### 로컬 변경사항 테스트

SessionStart 훅이 `plugins/` 아래 각 모듈을 active 캐시 디렉토리로 rsync한다 (`~/.claude/settings.json`). 훅은 다음 동작을 하는 한 줄 `bash -c` 명령이다.

```bash
bash -c 'shopt -s nullglob; root="$HOME/IdeaProjects/my-productivity/plugins"; [ -d "$root" ] || exit 0; for module_dir in "$root"/*/; do mod=$(basename "$module_dir"); for d in "$HOME/.claude/plugins/cache/my-claude-plugin/$mod"/*/; do [ -f "$d/.orphaned_at" ] && continue; rsync -a --delete "$module_dir" "$d" 2>/dev/null; done; done' || true
```

가드:
- `shopt -s nullglob` — 캐시 디렉토리가 아직 없을 때 리터럴 글롭으로 인한 오작동 차단
- `[ -d "$root" ]` — 레포가 아직 clone되지 않은 PC에서도 안전

**IMPORTANT**: 스킬을 추가하거나 수정한 후 **새 세션을 열어야** 반영된다.

### 다른 PC 셋업

`README.md`의 "셋업 체크리스트"를 따른다.

## 자산 표현 계층 우선순위

새 기능을 어떤 형태로 표현할지 고를 때, **위로 갈수록 우선**한다:

1. **Skill / Command** (markdown) — 정적 지식·워크플로우. 런타임 비용 0, 새 세션 rsync로 즉시 반영. 1순위.
2. **CLI 도구** (`tools/`의 my-team Node CLI, control-tower Swift 앱) — markdown으로 표현 못 하는 1급 런타임 능력이 필요할 때만 (예: my-team의 tmux 오케스트레이션).
3. **훅** (SessionStart 등) — 에이전트 루프·세션 경계에 자동 개입이 *반드시* 필요할 때만. 자동 발동은 디버깅 비용과 오발동 위험을 동반하므로 최후 수단.

> 같은 일을 markdown 스킬로 표현할 수 있으면 CLI 도구나 훅으로 올리지 않는다. (출처: oh-my-openagent의 Skill>MCP>Tool>Hook 원칙 — "런타임 비용 0인 정적 지식 최우선". 본 레포의 경량·명시호출 정체성과 정합.)

## 스킬 작성 규칙

커맨드(`commands/`)는 쓰지 않는다. 사용자만 호출하는 것도 스킬로 만들고 `disable-model-invocation: true`를 붙인다.

- **위치**: `plugins/workflow/skills/{name}/SKILL.md`
- **자동 트리거**: `description` 필드의 텍스트로 매칭 (충분히 구체적으로 작성)
- **수동 전용**: `disable-model-invocation: true` 추가
