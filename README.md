# my-productivity

개인 Claude Code 워크플로우 하네스. 여러 PC에서 동일한 스킬·도구 환경을 쓰기 위한 public 레포다. 마켓플레이스 이름은 `my-claude-plugin`이다.

## 구성

| 영역 | 위치 | 내용 |
|---|---|---|
| 플러그인 | `plugins/workflow/` | 개인 워크플로우 스킬 모음 (마켓플레이스로 설치) |
| 도구 | `tools/my-team/` | tmux 멀티프로젝트 워커 오케스트레이션 Node CLI. `README.md` 참조 |
| 도구 | `tools/control-tower/` | my-team 워커와 Claude Code/Codex 세션을 보는 macOS 메뉴바 앱 (Swift). `README.md` 참조 |
| 스크립트 | `scripts/` | pre-push 검사(`public-scan.sh`, `push-gate.sh`)와 상태 라인 설치(`statusline/`) |

## 셋업 체크리스트

새 PC에서 위에서 아래로 따른다. 도구(my-team, control-tower)는 플러그인으로 설치되지 않으므로 5~8번이 별도로 필요하다.

1. clone
   ```
   git clone https://github.com/jdalma/my-productivity ~/IdeaProjects/my-productivity
   ```
2. Claude Code에서 마켓플레이스 등록
   ```
   /plugin marketplace add https://github.com/jdalma/my-productivity
   ```
3. 플러그인 설치
   ```
   /plugin install workflow@my-claude-plugin
   ```
4. private-patterns 파일과 pre-push 훅. 패턴 파일은 회사·팀·고객 식별자를 한 줄에 정규식 하나로 적는 레포 밖 파일이며(`#` 주석 가능) 커밋하지 않는다.
   ```
   mkdir -p ~/.config/my-claude-plugin
   $EDITOR ~/.config/my-claude-plugin/private-patterns.txt
   cd ~/IdeaProjects/my-productivity && sh scripts/install-pre-push.sh
   ```
5. my-team CLI 설치. Node 22.13+, tmux 필요. Claude Code에서 `/my-team-install`을 호출하거나 직접 실행한다.
   ```
   sh tools/my-team/scripts/deploy.sh
   ```
6. 상태 라인 설치 (`jq` 필요, `~/.claude/settings.json`의 `statusLine` 키만 백업 후 머지)
   ```
   bash scripts/statusline/install.sh --yes
   ```
7. control-tower 빌드 (macOS 14+, Swift). `~/Applications/ControlTower.app`에 설치한다.
   ```
   cd tools/control-tower && scripts/bundle-app.sh
   ```
8. 로컬 동기화 훅. 레포의 스킬 변경을 새 세션에서 캐시에 반영하려면 `~/.claude/settings.json`에 SessionStart 훅을 등록한다. 내용은 `CLAUDE.md`의 "로컬 변경사항 테스트" 참조.

## 테스트

```
cd tools/my-team && npm ci && npm test
cd tools/control-tower && swift test
sh scripts/public-scan.test.sh && sh scripts/push-gate.test.sh
cd plugins/workflow/skills/my-team-config/scripts && python3 test_plugins.py
cd plugins/workflow/skills/session-resume/scripts && python3 test_sessions.py
```

GitHub Actions(`.github/workflows/ci.yml`)가 같은 명령을 PR마다 돌린다. 실제 private-patterns 파일은 CI에 없다.

## 운영 원칙

- **도메인 정보 금지**: 회사·팀·고객·내부 시스템 식별자가 들어간 자산은 커밋하지 않는다. 한 번 push되면 회수가 어렵다.
- **플러그인 자산만**: `~/.claude/settings.json`, 글로벌 `CLAUDE.md` 같은 dotfiles는 별도 트랙으로 관리한다.
- **스킬 작성 규칙**: 커맨드는 쓰지 않는다. 사용자만 호출할 것도 스킬로 만들고 `disable-model-invocation: true`를 붙인다. 스킬은 `plugins/workflow/skills/<name>/SKILL.md`에 두고, `description`의 트리거 문구가 자동 매칭에 쓰인다.

## CLI-중립 스킬 (codex/gemini 공유, 선택)

CLI-중립인 스킬(A등급)은 `plugins/workflow/skills/<name>/SKILL.md`를 변환 없이 그대로 복사하면 codex/gemini에서도 동작한다. 적격 여부는 `/portability-check`로 먼저 확인한다(A=적격, C=부적격). 적격 디렉토리를 외부 sync 도구에 넘기는 등록 예시(prefix 권장값 `my`):

```
# sync 도구 설정에 한 줄 (로컬에서만, git 비추적)
<repo>/plugins/workflow/skills | my | cli-neutral
```

실제 복사·prefix 부여·codex 배치는 sync 도구의 책임이며 이 레포는 깨끗한 SSOT 디렉토리만 제공한다.
