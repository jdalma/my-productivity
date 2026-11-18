---
name: my-team-resume
description: my-team 워커가 /clear 이후 자신의 팀 프로토콜과 역할 브리프(AGENTS.md 오버레이)를 다시 읽어 복구할 때 사용. 컨텍스트가 가득 차 세션을 비운 워커가 "다시 붙어", "프롬프트 재주입", "/my-team-resume" 같이 요청할 때 호출한다.
disable-model-invocation: true
---

# my-team 워커 복구

`/clear` 이후 이 pane이 어느 팀의 어느 워커였는지 되찾는다. 그것만 한다 —
handoff 작성도, 컨텍스트 정리도 하지 않는다.

## 1. 정체 확인

```bash
echo "worker=$MY_TEAM_WORKER state_root=$MY_TEAM_STATE_ROOT"
```

`MY_TEAM_WORKER`가 비어 있으면 이 pane은 my-team 워커가 아니다. 그 사실만
알리고 중단한다.

## 2. 오버레이 읽기

`MY_TEAM_WORKER`는 `<team>/<worker>` 형식이다. 워커 이름을 떼어내 오버레이를
읽는다:

```bash
cat "$MY_TEAM_STATE_ROOT/workers/${MY_TEAM_WORKER#*/}/AGENTS.md"
```

이 파일 하나에 팀 프로토콜 · 로스터 · 메시지 규칙 · 역할 브리프(`## Role
Context`)가 모두 들어 있다. 읽은 내용을 이번 세션의 행동 규범으로 삼는다.

## 3. 밀린 메일 확인

`/clear` 동안 도착한 메시지가 남아 있을 수 있다. 오버레이의 Message Protocol
섹션에 적힌 `mailbox-list` 명령을 그대로 실행해 미읽음을 확인한다.

## 4. handoff 존재 여부만 확인

이 pane의 cwd는 `/clear` 전과 동일한 프로젝트다. 직전 세션이 `/handoff`를
남겼다면 여기에 있다:

```bash
ls -t docs/handoffs/*.md 2>/dev/null | head -3
```

**경로만 보고한다.** 읽지 않고, `/takeover`를 실행하지도, 권유하지도 않는다.
resume은 "나는 누구인가"(팀·역할·mailbox)만 복구한다. "무엇을 하던
중이었나"는 `/takeover`의 몫이고, 그 호출 여부는 전적으로 사용자가 정한다.

## 5. 복귀 보고

pane에 한 줄로 알린다: 팀·워커 이름, 역할 요약, 미읽음 메시지 수, 그리고
handoff 파일이 있었다면 그 경로.

사용자가 handoff 파일 경로를 이번 호출 인자로 직접 넘겼다면 그것을 쓴다.
넘어오지 않았고 위 `ls`도 비었다면 없는 것이다 — 더 찾지 않는다.
