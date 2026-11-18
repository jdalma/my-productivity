# statusline

Claude Code 하단 상태 라인 + 설치 부트스트랩.

```
~/IdeaProjects/my-claude-plugin  feat/cli-neutral ✱  Opus 4.8  $0.42  8%
```

세그먼트는 데이터가 있을 때만 표시된다:

| 세그먼트 | 출처 (stdin JSON) | 비고 |
|----------|-------------------|------|
| cwd | `workspace.current_dir` | `$HOME`은 `~`로 축약 |
| git | `git -C <cwd>` | 현재 브랜치 + dirty면 `✱`. git 레포 아니면 생략 |
| 모델 | `model.display_name` | |
| 비용 | `cost.total_cost_usd` | `$X.XX`. 0이거나 없으면 생략 |
| 컨텍스트 | `context_window.used_percentage` | `N%`. 필드 있으면 0%도 표시 (세션 시작 직후 의미 있음) |

## 설치

```bash
bash scripts/statusline/install.sh        # 대화형
bash scripts/statusline/install.sh --yes   # 무인 (확인 프롬프트 생략)
```

설치 과정:

1. `jq` 존재 확인 (없으면 설치 안내 후 중단)
2. `statusline.sh` → `~/.claude/statusline.sh` 복사 (+ 실행 권한)
3. `~/.claude/settings.json` 백업 (`settings.json.bak.<timestamp>`)
4. 주입할 `statusLine` 값을 보여주고 확인(`--yes`면 생략)
5. `jq`로 `statusLine` 키만 머지 (다른 키는 불변). settings.json 없으면 새로 생성

주입되는 설정:

```json
{ "statusLine": { "type": "command", "command": "bash ~/.claude/statusline.sh", "padding": 0 } }
```

설치 후 **새 Claude Code 세션**을 열면 반영된다.

## 설계 메모

- 상태 라인은 매 렌더마다 실행되므로 콜드스타트가 없는 **Bash + jq**로 작성했다 (Node/Python 회피).
- `statusline.sh`는 **절대 실패하지 않도록** 방어적이다: 모든 필드는 옵셔널(`// empty`), git 호출 실패는 무시, `jq`가 없으면 cwd만이라도 출력한다.
- 이 자산은 플러그인이 아니라 **머신 부트스트랩**이므로 `plugins/`(rsync 대상)가 아닌 `scripts/`에 둔다. `~/.claude/statusline.sh`의 고정 경로에서 실행되며 플러그인 캐시와 무관하다.

## 제거

`settings.json`에서 `statusLine` 키를 지우거나, Claude Code에서 `/statusline delete`.
