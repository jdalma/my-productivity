# workflow plugin

개인 Claude Code 워크플로우 스킬 모음. 여러 PC에서 동일 환경을 쓰기 위한 모듈.

## 설치

```
/plugin marketplace add https://github.com/jdalma/my-productivity
/plugin install workflow@my-claude-plugin
```

## 작성 규칙

- 커맨드(`commands/`)는 쓰지 않는다. 사용자만 호출할 것도 스킬로 만들고 `disable-model-invocation: true`를 붙인다
- 스킬: `skills/<name>/SKILL.md` — `description` 필드 트리거 문구가 자동 매칭에 사용됨

## 금지

도메인 정보(회사·팀·고객·내부 시스템 식별자)를 포함한 자산은 절대 커밋하지 않는다. public 레포이므로 한 번 push되면 회수가 어렵다.
