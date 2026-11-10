---
name: session-resume
description: 최근 일주일 Claude 트랜스크립트를 최신순으로 나열하고(my-team 워커 세션은 팀으로 묶음), 사용자가 고른 세션을 다시 띄운다. 단일 세션은 Ghostty 새 탭에서 `claude-yolo --resume`, 팀은 manifest로 my-team을 재기동하며 각 워커를 직전 세션으로 resume한다.
disable-model-invocation: true
---

# session-resume — 최근 세션 목록 · 재실행

스크립트 하나가 전부 처리한다. 이 스킬은 목록을 보여주고, 고른 번호를 key로 바꿔 넘기는 일만 한다.

```bash
python3 <skill-dir>/scripts/sessions.py list [--days N]       # 기본 7일
python3 <skill-dir>/scripts/sessions.py resume <key>... [--days N]
```

## 1. 목록

`list`를 실행하고 출력을 **가공하지 않고 그대로** 보여준다. 인자로 기간(예: `3일`)이 넘어오면 `--days`로 전달한다.

- `[단일]` — key는 sessionId
- `[팀 <name>]` — key는 `team:<name>` (같은 이름이 다른 state_root에도 있으면 오래된 쪽은 `team:<name>@<state_root>`). 워커별 최신 세션 1개와 마지막 사용자 프롬프트를 표시
  - 워커 식별은 부팅 notice(`Team is live` / `You just joined team`)와 `/my-team-resume` 출력으로만 한다. `/clear` 후 `/my-team-resume`을 하지 않은 워커 세션은 `[단일]`로 보이고, 팀 resume은 `/clear` 이전 세션을 연다. 그 `[단일]`을 따로 resume하면 MY_TEAM env 없는 claude가 뜬다
  - `(실행 중)` 팀은 resume 대상이 아니다 (`tmux attach`만 안내)
  - `(shutdown됨, .bak 복원 후 resume)` — 예전 `my-team shutdown`(T51 이전)이나 새 팀 start가 state_root를 `<root>.bak`으로 옮긴 팀. resume 시 `.bak`을 원래 경로로 rename해 mailbox·archive까지 되살린다. `<root>`가 따로 있으면 그쪽이 최신 세대라 `.bak`은 건드리지 않는다
  - `(manifest 없음, resume 불가)` 팀은 대상이 아니다
  - `(manifest에서 제거됨)` 워커는 팀 resume에 포함되지 않는다 (remove-worker된 워커)

## 2. 선택

어느 번호를 다시 띄울지 묻는다. 여러 개 선택 가능. 사용자가 이미 번호를 인자로 줬으면 묻지 않는다.

## 3. resume

고른 번호를 목록의 key로 바꿔 한 번에 실행한다:

```bash
python3 <skill-dir>/scripts/sessions.py resume team:run-mate 0b1c...-sessionId
```

- 단일: Ghostty 새 탭을 세션 cwd에서 열고 `claude-yolo --resume <sid>` 입력
- 팀: `~/.my-team/sessions/<team>/manifest.json` + 각 워커 `AGENTS.md`의 `## Role Context`로 config를 재구성 → claude 워커에 `--resume <sid>` 추가 → `my-team start --detached --continue` → Ghostty 새 탭에서 `tmux attach`. 같은 state_root(shutdown된 팀은 복원한 `.bak`)를 쓰므로 mailbox는 유지된다.
  - 최근 N일 안에 트랜스크립트가 없는 워커는 새 세션으로 뜬다 (출력에 표시됨)
  - 원 config의 `env`는 manifest에 없어 복원되지 않는다

출력의 `건너뜀:` 줄과 실패를 그대로 보고한다.
