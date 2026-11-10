# my-claude-plugin

개인 Claude Code 워크플로우 하네스. 여러 PC에서 동일한 스킬·커맨드 환경을 쓰기 위한 마켓플레이스.

## 등록된 플러그인

- **workflow** — 개인 워크플로우 스킬/커맨드 모음

## 설치

```
/plugin marketplace add https://github.com/jdalma/my-claude-plugin
/plugin install workflow@my-claude-plugin
```

## 운영 원칙

- **도메인 정보 금지** — 회사·팀·고객·내부 시스템 식별자가 들어간 자산은 커밋하지 않는다. public 레포이므로 한 번 push되면 회수가 어렵다.
- **플러그인 자산만** — `~/.claude/settings.json`, `CLAUDE.md` 같은 dotfiles는 별도 트랙으로 관리한다.

## 작성 규칙

- 커맨드는 쓰지 않는다. 사용자만 호출할 것도 스킬로 만들고 `disable-model-invocation: true`를 붙인다
- 스킬: `plugins/workflow/skills/<name>/SKILL.md` — `description` 필드의 트리거 문구가 자동 매칭에 사용됨

## 로컬 동기화

레포 변경 후 로컬 캐시(`~/.claude/plugins/cache/.../workflow/<hash>/`)에 반영하려면 새 Claude Code 세션을 열거나 SessionStart 훅으로 rsync한다. 자세한 동기화 패턴은 `CLAUDE.md` 참조.

## 상태 라인 (다른 PC 세팅)

Claude Code 하단 상태 라인을 설치한다. cwd · git 브랜치(+dirty) · 모델명 · 세션 비용 · 컨텍스트 사용률을 한 줄로 표시한다.

```
bash scripts/statusline/install.sh        # 대화형 (확인 후 settings.json 머지)
bash scripts/statusline/install.sh --yes   # 무인 설치 (다른 PC 부트스트랩)
```

`jq`만 있으면 되고, `~/.claude/settings.json`의 `statusLine` 키만 백업 후 머지한다. 자세한 내용은 `scripts/statusline/README.md` 참조.

## CLI-중립 스킬 (codex/gemini 공유, 선택)

CLI-중립인 스킬(A등급)은 `plugins/workflow/skills/<name>/SKILL.md`를 변환 없이 그대로 복사하면 codex/gemini에서도 동작한다. 적격 여부는 `/portability-check`로 먼저 확인한다(A=적격, C=부적격). 적격 디렉토리를 외부 sync 도구에 넘기는 등록 예시(prefix 권장값 `my`):

```
# sync 도구 설정에 한 줄 (로컬에서만, git 비추적)
<repo>/plugins/workflow/skills | my | cli-neutral
```

실제 복사·prefix 부여·codex 배치는 sync 도구의 책임이며 이 레포는 깨끗한 SSOT 디렉토리만 제공한다.
