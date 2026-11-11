# events.jsonl line format

`<state_root>/events.jsonl` is a team's timeline. It holds one JSON object per line. Lines are only ever
appended, and existing lines are never rewritten. The format is defined in one place,
`EVENT_TYPES` in `src/lib/events.js`.

- Writers call `appendEvent` or `appendMessageEvent`. A key that the type does not list, or a missing
  required key, throws an error.
- Readers call `readEvent(line, team)`. It returns old lines in the same shape as new ones.
- `api send-message` logs its line after the message is delivered. If the line cannot be made or written,
  the message stays delivered: the result is still `ok: true`, with a `warning` field
  (`"delivered, but not logged in <state_root>/events.jsonl"`) and a line on stderr. Sending again would
  deliver it twice.

## Keys on every line written now

| key | meaning |
|---|---|
| `ts` | ISO 8601 time of writing |
| `type` | `message`, `tmux-denied` or `tool-denied` |
| `team` | the team of the actor |
| `worker` | the actor: the sender of a message, or the worker that was refused |

## Types

| type | written by | required keys | optional keys |
|---|---|---|---|
| `message` | `api send-message` | `from`, `to`, `body`, `message_id`, `reply_to`, `expects_reply` | `from_team`, `to_team` |
| `tmux-denied` | the tmux shim on a worker's PATH | `args` | |
| `tool-denied` | the worker guard hook (`deny` rules) | `tool`, `rule`, `target` | |

- `message` keeps `from` and `to` for existing readers. Its `worker` always equals `from`.
- A cross-team send writes two lines:
  - the sender's log gets `to_team`;
  - the recipient's log gets a mirror line with `from_team` and `to_team`. In both lines, `team` is the
    sender's team.
- Free text in refusals is cut at 500 characters (UTF-16 units), ending with `…[+N chars]`:
  - each string in `args`;
  - `target`.
  When character 500 is the first half of a surrogate pair (an emoji), the cut is at 499 so the pair is not
  split; N counts what was cut, the pair included.
- `args` keeps at most 20 items. When it holds more, its last item is `…[+N args]`.
- A message `body` is never cut.

## Example lines

```json
{"ts":"2026-11-11T05:52:08.453Z","type":"message","team":"control-tower","worker":"pm","from":"pm","to":"core","body":"[T60 발행] …","message_id":"1794376634669-3t3ebo","reply_to":null,"expects_reply":false}
{"ts":"2026-11-11T05:52:09.000Z","type":"message","team":"team-a","worker":"alice","from":"alice","to":"bob","body":"hi","message_id":"…","reply_to":null,"expects_reply":false,"from_team":"team-a","to_team":"team-b"}
{"ts":"2026-11-11T04:55:21.414Z","type":"tmux-denied","team":"t56probe","worker":"w","args":["kill-session","-t","nothing"]}
{"ts":"2026-11-11T05:52:11.148Z","type":"tool-denied","team":"t59probe","worker":"w","tool":"Write","rule":"repo-write","target":"/…/repo/inside.txt"}
```

## Reading older lines

`readEvent(line, team)` takes the team whose log the line was read from. It applies these rules.

| older line | read as |
|---|---|
| no `type` (v1: `ts`, `from`, `to`, `body`) | `type: "message"`, `message_id: null`, `reply_to: null`, `expects_reply: false` |
| no `team` | `from_team` when present (a mirrored message), otherwise the log's team |
| no `worker` on a message | `from` |
| `from_session` / `to_session` (sends addressed by tmux session) | kept as they are, as optional keys no longer written |

On this machine, all 3084 lines in 34 events.jsonl files (2026-11-11) read back with every common key and
every required key of their type present.
