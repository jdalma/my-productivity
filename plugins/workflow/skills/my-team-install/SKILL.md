---
name: my-team-install
description: Install or update the my-team CLI binary from this repo's tools/my-team package so the my-team skill can actually invoke commands. First install and update are the same command, tools/my-team/scripts/deploy.sh, which installs a commit of the repo (not the working tree) into npm's global prefix; an update first runs git pull --ff-only. Use when the user explicitly invokes /my-team-install, or when the my-team skill fails because `command -v my-team` is missing. Never run automatically — wait for explicit user invocation.
aliases: []
---

# my-team-install — CLI 도구 설치

`my-team` 슬래시 커맨드가 실제로 동작하려면 `my-team` CLI 바이너리가 PATH에 있어야 한다. 이 스킬은 `tools/my-team` npm 패키지의 **커밋 하나**를 사용자 시스템에 설치한다.

설치된 사본은 그 커밋의 스냅숏이다. 레포를 고치거나 커밋해도, 다시 배포하기 전까지 실행 중인 팀에는 적용되지 않는다. `npm link`는 쓰지 않는다. 저장한 수정이 바로 모든 팀에 적용되기 때문이다.

## ⛔ 호출 규칙

- ✅ 사용자가 명시적으로 `/my-team-install` 호출
- ✅ `my-team` 스킬이 첫 실행에서 `command -v my-team` 실패를 발견하고 사용자에게 "/my-team-install 먼저 호출하세요" 안내한 후, 사용자가 그걸 받아 호출
- ❌ 자동 호출 금지 (전역 npm 설치를 바꾸는 변경이라 사용자 명시 동의 필요)

## 실행 흐름

### Step 1: 현재 설치 확인

```bash
command -v my-team && my-team --version 2>/dev/null || echo "not installed"
```

- 출력 예: `0.1.0 (1a94352c0d3e)`. 괄호 안은 설치된 커밋이다.
- `0.1.0 (working tree)`는 레포 작업 트리를 직접 쓰는 상태다(예전 `npm link` 설치). 이번 배포가 그것을 사본으로 바꾼다는 점을 사용자에게 알린다.
- 배포 전 점검: tmux shim을 PATH에 가진 실행 중 워커 수를 센다. 0이 아니면 사용자에게 알린다(Step 5의 재기동 안내 대상).
  ```bash
  ps eww -axo pid,command | grep "my-team/shim" | grep -vc grep
  ```
- 괄호가 없는 `0.1.0`은 이 스킬 이전의 설치다. 역시 이번 배포가 덮어쓴다.

설치돼 있든 아니든 다음 단계는 같다.

### Step 2: my-claude-plugin 레포 위치 확인

```bash
for candidate in \
    ~/IdeaProjects/my-claude-plugin \
    ~/Projects/my-claude-plugin \
    ~/code/my-claude-plugin \
    ~/src/my-claude-plugin; do
  if [ -f "$candidate/tools/my-team/scripts/deploy.sh" ]; then
    echo "found: $candidate"
    break
  fi
done
```

- 발견되면 그 경로를 쓴다.
- 없으면 사용자에게 묻는다:
  ```
  my-claude-plugin 레포를 어디에 clone할까요?
  기본: ~/IdeaProjects/my-claude-plugin

  답변 후:
    git clone https://github.com/jdalma/my-claude-plugin.git <path>
  ```

### Step 3: 최신화 후 배포

```bash
cd <repo>
git pull --ff-only          # 새로 clone한 경우는 생략
sh tools/my-team/scripts/deploy.sh
```

- `deploy.sh [<commit>] [--prefix <dir>]`: 커밋을 생략하면 HEAD다.
- 동작: `git archive <commit> tools/my-team` → `npm pack` → `npm install -g <tgz>` 순서로 설치하고, 설치 폴더에 `COMMIT` 파일(커밋 해시)을 쓴다.
- 작업 트리의 커밋하지 않은 변경은 설치되지 않는다. 그 변경을 설치하려면 먼저 커밋한다.
- 처음 설치든 업데이트든 같은 명령이다. 다시 실행해도 같은 커밋이면 결과가 같다.

처리할 경우:
- `git pull --ff-only` 실패(로컬 커밋 있음): `git status`를 보여 주고 "수동 해결 권장"이라고 안내한 뒤 중단한다. 강제 reset은 하지 않는다.
- `npm install -g` 권한 거부: `npm config set prefix ~/.npm-global`과 `export PATH=~/.npm-global/bin:$PATH`를 안내한다.
- `npm install -g` 실패: stderr를 그대로 보여 주고 네트워크를 확인하라고 안내한다(의존성 commander를 받는다).

### Step 4: 검증

```bash
command -v my-team
my-team --version        # 0.1.0 (<배포한 커밋 앞 12자리>)
my-team --help | head -5
```

- `my-team: command not found`: npm 글로벌 bin 디렉토리가 PATH에 없다. `npm config get prefix`로 확인한 뒤 PATH 추가를 안내한다.
- `--version`의 커밋이 `git -C <repo> rev-parse HEAD`와 다르면 배포가 반영되지 않은 것이다. Step 3의 출력을 확인한다.

### Step 5: 사용자에게 완료 보고

```
my-team CLI 설치 완료
   위치: <bin path>
   버전: <my-team --version 출력>

이미 실행 중인 팀의 워커도 다음 my-team 호출부터 새 사본을 쓴다.
단, 워커 PATH의 tmux shim은 그 워커를 띄울 때의 사본 그대로다. 배포 전 점검에서 센
워커는 재기동해야 새 사본의 shim을 쓴다.
```

배포 전 점검의 수가 0이 아니었으면 위 마지막 두 문장을 빼지 말고 보고한다.

## Done When

- `command -v my-team` 출력이 있다.
- `my-team --version`이 `<버전> (<커밋>)` 형식이고, 커밋이 배포한 커밋과 같다.
- `my-team --help`가 사용자용 명령(start/status/shutdown/monitor)과 `api` 서브명령을 표시한다.
- 수행한 단계(pull 여부, 배포한 커밋)가 사용자에게 한 줄로 보고됐다.

## Edge Cases

| 상황 | 대응 |
|---|---|
| `npm`이 PATH에 없음 | "Node.js 20+ 설치 필요. https://nodejs.org" 안내 후 중단 |
| `git`이 PATH에 없음 | "git 설치 필요" 안내 후 중단 |
| 예전 `npm link` 설치 (`(working tree)`) | 배포가 symlink를 사본으로 바꾼다고 알리고 진행 |
| `git pull --ff-only` 실패 | `git status` 출력 + "수동 해결 권장" 안내 후 중단. 강제 reset 금지 |
| 작업 트리에 미커밋 변경 | 설치되지 않는다고 알린다. 설치하려면 사용자가 먼저 커밋 |
| 전역 설치 권한 거부 | `npm config set prefix ~/.npm-global` + PATH 추가 안내 |
| 사용자가 레포 위치 입력을 거부 | 설치 중단, "README 참조" 출력 |
| Windows | 미지원(tmux가 unix 도구). 안내 후 중단 |

## 참고

- 이 CLI는 npm registry에 publish되지 않은 로컬 패키지다. `npm install -g my-team`으로는 받을 수 없다.
- 시험 설치는 `deploy.sh --prefix <임시 폴더>`로 한다. 전역 설치는 바뀌지 않는다.
- my-team 본 스킬(`/my-team`) 호출 시 CLI가 없으면, my-team SKILL.md가 사용자에게 "/my-team-install 먼저 호출하세요"라고 안내한다.
