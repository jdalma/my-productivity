# The team board

A board team keeps its work on a board: tasks, review requests (landings), verdicts and findings, notes and
announcements. The mailbox still carries notices and questions, but no work state. The design, with the
reasons for each rule, is in the control-tower team's `rfc/board-design.md`.

## Turning it on

Add a `board` item to the team config. A team without it has no board, and every `board-*` command fails
with `board-unavailable` before any file is made.

```json
{ "team_name": "demo", "board": { "store": "sqlite" }, "workers": [ … ] }
```

- `store` is `sqlite` (the default) or `memory`. The memory store keeps nothing between calls and is for
  tests only.
- The board file is `<state_root>/board.db`. A new team starts with an empty board (the old one moves to
  `.bak` with the rest of the state). `--continue` keeps it.
- The board needs Node 22.13 or later (23.4 on the 23 line) for `node:sqlite`. On an older Node, only the
  board commands fail (`board-unavailable`), and the rest of my-team runs as before.
- Workers of a board team find a `## Team Board` section in their AGENTS.md. It tells them which commands
  to use.

## Commands

Every command is `my-team api board-<name> --input '<json>' [--json]`, and every input has `team_name`.

**Who acts.** The acting worker is the one `MY_TEAM_WORKER` names, in its own team only. From the user's
shell (no `MY_TEAM_WORKER`), a write command names its worker in `by` and a read command in `worker`.

| Command | Who | Input (required **bold**) | Output |
|---|---|---|---|
| `board-add` | pm | **`title`**; `id`, `parent`, `ticket`, `assignee`, `reviewer`, `priority`, `base`, `constraints` | `task` |
| `board-assign` | pm | **`id`**; `assignee` (reassign → ready); `reviewer` (change it); neither, on a held task → review again | `task` |
| `board-take` | assignee | **`id`** | `task` |
| `board-land` | assignee | **`id`**, **`commit`**, **`check`** `{cmd, result}`, **`focus`**, **`closes`**, **`report`**, **`review_report`**; `base`, `commits`, `deployed` | `task`, `landing`, `fixed` |
| `board-verdict` | the task's reviewer (pm without one) | **`landing`**, **`verdict`** (`approve`, `changes` or `hold`), **`verified_commit`**, **`report`**, **`rerun`** `{cmd, result}`, **`findings`**; `reopen`, `side_notes` | `verdict`, `task`, `findings`, `reopened` |
| `board-finding` | pm settles, reviewer reopens | **`id`**, **`state`** | `finding` |
| `board-cancel` | pm | **`id`**; `findings` (where its unsettled findings go), `reason` | `task`, `findings` |
| `board-note` | anyone | **`body`**; `id` (task), `to` (workers to tell) | `note` |
| `board-announce` | pm | **`body`** | `announcement` |
| `board-inbox` | anyone, for themselves | `since` (the last `cursor`) | `tasks`, `review_queue`, `incomplete`, `notes`, `announcements`, `cursor` |
| `board-review-queue` | anyone, for themselves | | `queue`, `incomplete` |
| `board-status` | anyone | `task` (one family in full) | `store`, `tasks`, `workers`, `open_findings`, `recent`, `announcements` |

Notes on the inputs:

- `board-land` reads its repository from the acting worker's cwd, so `repo` is never an input.
- `commits` defaults to `git rev-list base..commit`. Give a subset of that list to leave out other work.
- `base` defaults to the family's last approved commit, then to the task's `base`.

**Notices.** A write that concerns other workers sends each of them one mailbox line,
`[board] <ref> <action>`. The line carries no state: the reader runs `board-inbox`. Every write also adds a
`board` line to `events.jsonl` (see `events-format.md`).

**Errors.** An error is a stderr line `[my-team] error: <code>: <message>` and exit 1. With `--json`, it is
also printed on stdout as `{"ok": false, "code", "message"}`.

| Code | Meaning |
|---|---|
| `invalid` | an input is missing or wrong, or the rule forbids the result (e.g. approving with an open must finding) |
| `forbidden` | the acting worker may not do this (not pm, not the assignee, judging its own work, another team) |
| `not-found` | no such team, task, landing or finding |
| `invalid-transition` | the task or finding is not in a state this command moves from |
| `stale-landing` | the landing was superseded, or `verified_commit` is not its commit |
| `conflict` | someone changed the same task three times while this command ran; run it again |
| `board-unavailable` | the team has no board, or this Node has no `node:sqlite` |
| `busy` | the board file stayed locked for 5 seconds |
| `schema-too-new` | a newer my-team wrote this board |
| `invalid-row`, `invalid-query`, `store` | a bug in my-team; report it |

## States

| Task state | Means | Leaves by |
|---|---|---|
| `new` | no assignee | `board-assign` → ready, `board-cancel` |
| `ready` | assigned, not started | `board-take` → doing |
| `doing` | being worked on | `board-land` → review |
| `review` | a landing waits for its verdict | `board-verdict` → done, changes or held; `board-land` again (supersedes) |
| `changes` | the verdict asked for fixes | `board-take` → doing (no pm step) |
| `held` | the reviewer could not verify | `board-assign` → review again, or → ready with a new assignee |
| `done`, `cancelled` | finished | nothing; further work is a derived task (`parent`) |

Any state that is not `done` or `cancelled` can also be cancelled by pm.

| Finding state | Set by |
|---|---|
| `open` | the reviewer's verdict; the reviewer reopens a fixed one; pm reopens a settled one |
| `fixed` | the assignee's `board-land` with the finding in `closes` |
| `backlog`, `accepted-limit`, `rejected` | pm, with `board-finding` or `board-cancel` |

**Rules that hold on every path:**

- Nobody judges a task they are assigned. Nobody approves a commit they landed in the same family.
- `approve` is refused while the family has an open `must` finding.
- Reopening a finding needs an unfinished task in its family.

## One cycle

pm adds T1 for dev, reviewed by rv. dev lands commit `$C1`, and rv asks for a fix. dev lands `$C2` closing
the finding, and rv approves. `$BASE`, `$C1` and `$C2` stand for full commit hashes in dev's repository.
`test/board/docs.test.js` runs these lines as written.

<!-- example:start -->
```sh
MY_TEAM_WORKER=demo/pm my-team api board-add --input '{"team_name":"demo","id":"T1","title":"Add the parser","assignee":"dev","reviewer":"rv","ticket":"docs/tickets/T1.md","constraints":"없음","base":"$BASE"}' --json
MY_TEAM_WORKER=demo/dev my-team api board-take --input '{"team_name":"demo","id":"T1"}' --json
MY_TEAM_WORKER=demo/dev my-team api board-land --input '{"team_name":"demo","id":"T1","commit":"$C1","check":{"cmd":"npm test","result":"12/12"},"focus":["the parser"],"closes":[],"report":"docs/reports/T1.md","review_report":"docs/reports/R1-review.md"}' --json
MY_TEAM_WORKER=demo/rv my-team api board-review-queue --input '{"team_name":"demo"}' --json
MY_TEAM_WORKER=demo/rv my-team api board-verdict --input '{"team_name":"demo","landing":"T1#1","verdict":"changes","verified_commit":"$C1","report":"docs/reports/R1-review.md","rerun":{"cmd":"npm test","result":"12/12"},"findings":[{"code":"M1","severity":"must","summary":"empty input crashes","repro":"node parse.js --empty"}]}' --json
MY_TEAM_WORKER=demo/dev my-team api board-inbox --input '{"team_name":"demo"}' --json
MY_TEAM_WORKER=demo/dev my-team api board-take --input '{"team_name":"demo","id":"T1"}' --json
MY_TEAM_WORKER=demo/dev my-team api board-land --input '{"team_name":"demo","id":"T1","commit":"$C2","base":"$C1","check":{"cmd":"npm test","result":"13/13"},"focus":["M1"],"closes":["R1 M1"],"report":"docs/reports/T1.md","review_report":"docs/reports/R1-review.md"}' --json
MY_TEAM_WORKER=demo/rv my-team api board-verdict --input '{"team_name":"demo","landing":"T1#2","verdict":"approve","verified_commit":"$C2","report":"docs/reports/R1-review.md","rerun":{"cmd":"npm test","result":"13/13"},"findings":[]}' --json
MY_TEAM_WORKER=demo/pm my-team api board-status --input '{"team_name":"demo","task":"T1"}' --json
```
<!-- example:end -->

After the last line, T1 is `done`. Its family shows landings `T1#1` and `T1#2`, verdicts `R1` and `R1a`,
and finding `R1 M1` fixed in `T1#2`. Across the cycle the mailbox carried 9 notices: pm 4, dev 3, rv 2.
