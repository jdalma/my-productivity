# The team board

A board team keeps its work on a board: tasks, review requests (landings), verdicts and findings, notes and
announcements. The mailbox still carries notices and questions, but no work state.

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
- Reading a board never changes its file. `board-status`, `board-inbox`, `board-review-queue`,
  `board-pushable` and `goal-order` on a board file of an older schema read it as the migration would leave it, and leave it as
  it is; on a team that has no board file yet they read an empty board and make none. Only a write command
  migrates the file, and first leaves a copy of it beside it: `board.db.v<n>.bak`, n the schema before. A copy
  already there is kept.
- A board file a newer my-team migrated is refused by an older one (`schema-too-new`), for every team that
  uses it. So a write that would migrate the board of a running team (one of its worker panes is alive) is
  refused (`migration-refused`), and the file is left as it is. `start --continue` migrates it while the team
  is down, so a team restarted on a newer my-team writes at once; a write while the team is down migrates it too.
  A my-team of another version than the installed one (a branch under work or review) is tried on a copy in
  a temporary folder, with `MY_TEAM_STATE_ROOT_BASE` set to that folder, the copied manifest's `state_root`
  changed to the copy's own folder and its `session_name` to one no tmux session has. `state_root` is an
  absolute path, so a copied manifest still names the running team's board; and a copy that names the
  running team's session reads as running too.
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
| `board-add` | pm | **`title`**; with no `parent`, exactly one of **`goal`** (`G<n>`, with `id`) or **`single`** (`true`); `id`, `parent`, `ticket`, `assignee`, `reviewer`, `priority`, `base`, `constraints`, `deliverable` (`document` for a document task) | `task` |
| `board-edit` | pm | **`id`**, and one or more of `title`, `ticket`, `constraints`, `base`, `priority`, `deliverable` (`commits` or `document`) | `task` |
| `board-assign` | pm | **`id`**; `assignee` (reassign → ready); `reviewer` (change it); neither, on a held task → review again | `task` |
| `board-take` | assignee | **`id`** | `task` |
| `board-land` | assignee | **`id`**, **`commit`** (none on a document task), **`check`** `{cmd, result}`, **`focus`**, **`report`**; `closes` (none when left out), `base`, `commits`, `review_report` (a suggestion), `deployed` | `task`, `landing`, `fixed` |
| `board-verdict` | the task's reviewer (pm without one) | **`landing`**, **`verdict`** (`approve`, `changes` or `hold`), **`verified_commit`** (left out for a document task's landing), **`rerun`** `{cmd, result}`; `findings` (none when left out), `report` (required unless the landing suggests one), `reopen`, `side_notes` | `verdict`, `task`, `findings`, `reopened`, `fixed` (the backlog findings an approve fixed); `reopened` lists what the verdict moved to open |
| `board-finding` | pm settles or records a fix, reviewer reopens | **`id`**, **`state`**; `landing` (with `state` `fixed`: the approved landing that fixed it) | `finding` |
| `board-cancel` | pm | **`id`**; `findings` (where its unsettled findings go), `reason` | `task`, `findings` |
| `board-note` | anyone | **`body`**; `id` (task), `to` (workers to tell) | `note` |
| `board-announce` | pm | **`body`** | `announcement` |
| `board-wait` | pm or the task's assignee | **`id`**, **`question`**, **`context`**, **`options`** (two or more, each **`label`**, **`pros`**, **`cons`**; `detail`), **`recommendation`** `{option (a label or null), reason}`, **`impact`**; `refs` | `task` |
| `board-answer` | pm | **`id`** (a waiting task, or a decision `D#…`), **`chosen`** (an option's `label`, or `기타`; on a decision also `철회`; spaces around it ignored), **`answer`** | `task` and `decision` for a task; `decision` for a `D#…` |
| `board-ask` | anyone; with `answered`, pm | **`question`**, **`context`**, **`options`** (two or more, or one with `answered`; each **`label`**, **`pros`**, **`cons`**; `detail`), **`recommendation`**, **`impact`**; `refs`, `tasks` (the tasks it serves), `answered` `{chosen, answer}` | `decision` |
| `board-decision-edit` | pm or the worker who asked | **`id`** (an open decision `D#…`, or a waiting task), and one or more of `question`, `context`, `options`, `recommendation`, `impact`, `refs`; `tasks` (a `D#…` only) | `decision` for a `D#…`, `task` for a waiting task; `changed` (the fields that changed) |
| `board-progress` | the task's assignee, in `doing` or `changes` | **`id`**, **`item`** (the ticket's numbered item, 1 up; 0 for work outside them), **`note`**, **`done`** (true or false) | `progress` |
| `board-inbox` | anyone, for themselves | `since` (the last `cursor`) | `tasks`, `review_queue`, `review_hint` (with 2 or more requests), `incomplete`, `notes`, `announcements`, `decisions` `{open, answered}`, `cursor` |
| `board-review-queue` | anyone, for themselves | | `queue`, `incomplete`, `hint` (with 2 or more requests) |
| `board-status` | anyone | `task` (one family in full, with its `answers` and the task's `progress`); `open` (`true`: only tasks not done or cancelled and decisions not answered, what a worker in a new conversation of a continued team reads) | `store`, `tasks` (each with `progress_summary` and `history`), `workers` (`name`, `role`, `assigned`, `in_hand`, `reviewing`), `open_findings`, `recent`, `announcements`, `decisions` |
| `board-pushable` | anyone | **`commit`**, **`upstream`** (the remote's commit) or **`remote`** (its name, for a new branch); `repo` (default: the current folder), `baseline` | `ok`, `repo`, `covered`, `uncovered` (`commit`, `short`, `subject`) |

Notes on the inputs:

- `board-land` reads its repository from the acting worker's cwd, so `repo` is never an input.
- `commits` defaults to `git rev-list base..commit`. Give a subset of that list to leave out other work.
- `base` defaults to the family's last approved commit, then to the task's `base`.
- The review report path is the reviewer's to choose. A landing may suggest one with `review_report`.
- A task with no constraints says `없음`. A missing or blank `constraints` or `ticket` leaves the task's review
  request under `incomplete` instead of in the queue.
- A lost `cursor` is no loss: call `board-inbox` without `since`, and you see some items twice.
- A `board-review-queue` row carries the task and its parent, the landing (with `commits` and `left_out`),
  `previous_commit` (the commit of the landing it superseded), open and settled findings, notes, the
  family's earlier verdicts, and `next_verdict` (the id this verdict will take).
- With 2 or more rows in the queue, `board-review-queue` adds a `hint` and `board-inbox` a `review_hint`: give
  each request to its own sub-agent and start them together. Neither is there for one request.

**The user's decision.** A task that cannot go on until the user decides goes to `waiting` with `board-wait`.
Its `waiting` field holds a decision brief, written so the user can decide from it alone:

```json
{ "question": "A or B?", "context": "why now, what is stuck, what was checked (paths, file:line)",
  "options": [ { "label": "A", "detail": "…", "pros": ["…"], "cons": ["…"] }, { "label": "B", … } ],
  "recommendation": { "option": "A", "reason": "…" }, "impact": "what stays stuck, the cost of a wrong pick",
  "refs": ["path"], "asked_by": "dev", "asked_at": "…", "resume_state": "doing" }
```

- `board-wait` refuses a brief without `question`, `context`, `impact`, `recommendation`, or two options each
  with `label`, `pros` and `cons` (`invalid`). With no option to recommend, `recommendation` is
  `{"option": null, "reason": "why none"}`. Labels are compared without the spaces around them: they are
  distinct, and `기타` (an answer outside the options) and `철회` (a decision withdrawn) are kept, no option's label. `refs` may be left out (`[]`); a left-out
  `detail` is `""`.
- `waiting` is `null` on a task in any other state.
- pm records the user's answer with `board-answer`. The task goes back to `resume_state`, and its family's
  `answers` (`board-status` with `task`) gains `{task_id, question, chosen, answer, answered_by, answered_at,
  brief}`, oldest first. `brief` is the `waiting` object as it was when answered.
- A waiting task cannot be taken, landed or judged: a review request waits with it and is judged once answered.
  A note and a cancel still go.
- `board-inbox` lists the worker's waiting tasks with its others.
- A waiting task is not in its assignee's hands (`in_hand`, the load warning): the assignee has put it down.

**Decisions that stop no task.** `board-ask` puts a decision on the board without stopping anything: a task that
can go on while the user decides, a task with several questions queued, or (the exception) a decision no task
serves. It takes the same brief as `board-wait`, plus `tasks`, the tasks it serves; their states do not change.
Anyone in the team asks; the decision takes the next id `D#1`, `D#2`, … and pm is told. pm records the answer with
`board-answer` and the decision's id, and the asker is told. `철회` as `chosen` closes a decision nobody needs any
more, with the reason in `answer`; it is no option's label. A decision the user already made (unasked, or answered
in a pane) is recorded by pm in one call: `board-ask` with `answered` `{chosen, answer}`, one option or more.

**Editing an open decision.** Talk about a decision changes its question, its options or what is recommended.
`board-decision-edit` changes the decision in place, so its one entry says what is asked now:

- `id` is a decision `D#…`, or the task whose wait it is.
- Only the fields given change: `question`, `context`, `options`, `recommendation`, `impact`, `refs`, and for a
  `D#…` the `tasks` it serves. A field is given whole (`options` is every option). The brief the edit leaves is
  checked as `board-ask` checks one, so options that no longer hold the recommendation kept are refused.
- pm and the worker who asked edit it (`forbidden` for anyone else). The other of the two is told with a
  `[board] <ref> edit` notice (the same `ref`).
- Only an open decision is edited: an answered or a withdrawn one, and a task that is not `waiting`, are refused
  (`invalid-transition`). An edit that changes nothing, or names another field, is `invalid`.
- Who asked and when stay. A waiting task's state and `updated_at` stay too.
- Each edit adds a log entry with `kind` `decision`, `action` `edit`, the decision's id in the list as `ref`
  (`D#2`, or `T5:2` for a wait), and `detail.changed`:
  for each field that changed, `{from, to}`. The schema does not change.

**The decision list.** `board-status` without `task` gives `decisions`, every decision asked of the user, by
`asked_at` (then id):

```json
{ "id": "D#2", "task_id": null, "tasks": ["T7"], "state": "open",
  "question": "…", "context": "…", "options": [ … ], "recommendation": { "option": "A", "reason": "…" },
  "impact": "…", "refs": [], "asked_by": "core", "asked_at": "…",
  "edits": 2, "edited_by": "pm", "edited_at": "…" }
```

- `edits` is how many times `board-decision-edit` changed it, `edited_by` and `edited_at` who did last and when
  (`0`, null and null when never). The fields above them are the decision as it stands now.
- A decision of `board-ask` has the id `D#…`, `task_id` null and the `tasks` it was asked with.
- A task's waits come from the board's log: the id is the task and the number of the wait on it (`T5:2` is T5's
  second), the same on every call; `task_id` and `tasks` name the task. An open one reads its brief from the
  task's `waiting`. A wait the task was cancelled out of is answered with `chosen` `철회` and the reason.
- `state` is `open` or `answered`; an answered one adds `chosen`, `answer`, `answered_by`, `answered_at`.
  A wait answered before its brief was kept (before T117) has `context`, `recommendation` and `impact` null and
  no `options`.
- `board-inbox` gives `decisions.open` (all of them for pm, the worker's own for the others) and
  `decisions.answered`, the answers to the worker's questions after `since.decision`.

**Progress.** The assignee says where a task is with `board-progress`: which of the ticket's numbered items
(the What list, in order; 0 for work outside it), a sentence or two on what was done and what is left, and
whether that item is done. It is a `progress` line of the board's log and tells nobody. A progress report
changes neither the task's state nor its `updated_at`; only the task's `version` goes up.

- `board-status` with `task` lists that task's reports as `progress`, oldest first: `{item, note, done, by,
  at}`; `[]` with none. They are not in `recent`, which lists the board's changes.
- Every task in `board-status`, the list and a family's `root` and `tasks`, carries `progress_summary`:
  `{done_items, last_note, last_at}`, or `null` with no report. `done_items` are the items whose latest report
  says done, in order; item 0 is never one. `last_note` is the latest report's, item 0 included.

**History.** Every task in `board-status`, the list and a family's `root` and `tasks`, carries `history`, read
from the board's log: how the task has gone so far.

```json
{ "landings": 3, "verdicts": { "approve": 0, "changes": 2, "hold": 0 },
  "last_event": { "action": "land", "verdict": null, "by": "core", "at": "…", "state_from": "doing", "state_to": "review" },
  "state_since": "…", "last_progress_by": "core", "cancelled_from": null }
```

- `landings` counts the task's `board-land`s, a landing again while in review included: the open landing is
  the `landings`th. `verdicts` counts the verdicts on those landings by kind, so `changes` is how often the
  task came back.
- `last_event` is the last thing that happened to the task: `action` is `add`, `assign`, `take`, `land`,
  `verdict`, `wait`, `answer` or `cancel`, `by` who did it, `at` when. `verdict` is `approve`, `changes` or
  `hold` on a verdict and null otherwise. `state_from` and `state_to` are the task's state before and after;
  `state_from` is null on `add`. A progress report, a note and a finding are no event: compare `at` with
  `progress_summary.last_at` to tell which is later.
- `state_since` is when the task entered the state it is in. An event that leaves the state as it is (a
  landing again in review, a change of reviewer) does not move it, and neither does a progress report, so it
  says how long the task has been there where `updated_at` does not.
- `last_progress_by` is who wrote the latest progress report, null with none.
- `cancelled_from` is the state a cancelled task was in, null for any other task. For a task cancelled while
  `waiting` it is the state the task waited in.

**Correcting a task.** pm corrects what an unfinished task says with `board-edit`: its title, ticket path,
constraints, base commit, priority, or what it delivers. Who works on it and who judges it are `board-assign`'s.

- A task that is `done` or `cancelled` is not edited (`invalid-transition`). An input that changes nothing, or
  names anything else, is `invalid`.
- The task's state and its `updated_at` stay; only its `version` goes up. The edit is an `edit` line of the
  board's log, with what changed in `detail.changed`: `{"constraints": {"from": null, "to": "없음"}}`. It shows in
  `recent`, and is no event of the task's `history`.
- The assignee is told, and the reviewer too while the task is in review.
- A task in review whose ticket or constraints were missing leaves `incomplete` and enters the review queue once
  they are filled in.

**Document tasks.** A task whose result is a report and no commit (advice, a design, a review of a plan) is a
document task: `board-add` with `deliverable` `document`, or `board-edit` on a task already on the board. Its
row says `"deliverable": "document"`; any other task says null and delivers commits.

- A document task lands with `id`, `check` (what was checked, and the result), `focus` and `report`,
  and no `commit`, `base` or `commits` (`invalid` with one). Its worker need not be in a git repository.
- A task that delivers commits cannot land without one, as before. pm may mark or unmark a task while it is
  `new`, `ready`, `doing` or `changes`, so nothing of it waits for a verdict. A task that has landed commits
  cannot become a document task.
- The landing has every field a landing has: `commit`, `base_commit` and `repo` are `""`, `commits` and
  `left_out` are `[]`. What reads a landing of commits reads this one.
- It is judged like any landing, by the task's reviewer (pm without one), never by its assignee, and never by
  anyone who landed a report of the task, whoever has the task now. The verdict leaves `verified_commit` out,
  or gives `""`; the verdict row keeps `""`. `approve` makes the task `done`.
- Its `closes` names findings of document tasks only, its own or another's, and so does `board-finding`
  `fixed` with a landing that has no commit: a finding of a task that delivers commits is fixed by commits.
- It makes no commit pushable: the push gate reads approved commits, and it has none.

**Goal of a task (T221).** A task with no `parent` says which request it serves. With `goal` `G<n>`, the
team's goals folder (`docs/<team>/goals` next to the state base, `~/.my-team/docs/<team>/goals` by default) holds
exactly one `G<n>-<slug>.md`, and its `## 순서` section names the task's `id` (`T7`, or by items `T7:2-3`), on an
order line or a list line. With
`single` `true`, the request is this one task. Neither, both, no such file, two files of one number or an order
that does not name the task: `invalid`, and the message gives the folder and the line format. So a request of
two or more tasks gets its goal file and order before its tasks. `goal` and `single` are checked, not stored. A
derived task (`parent`) needs neither: it serves its parent's request.

**Load warning.** `board-add` with an `assignee`, and `board-assign` that moves a task to another assignee or
releases a `held` one to the same assignee, add a `warning` to their result when work piles up on that worker. The task is added or moved all the same.

- A task is in a worker's hands while it is `ready`, `doing` or `changes`. A task in `review` waits on its
  reviewer and a `held` one on pm, so neither counts. `board-status` gives this number as
  `workers[].in_hand`; `assigned` counts every unfinished task of the worker.
- The warning comes when the assignee then has 2 or more tasks in hand. It names an idle worker when another
  worker in the roster who is the assignee of a task on this board (finished ones count) has none.
- A worker who is the assignee of no task, such as a reviewer, is never named as idle.
- The line reads `dev now has 3 tasks in hand (ready, doing or changes) while app has none: split the task or
  give it to app`. With a notice warning it shares the `warning` field, joined by `; `.
- When the assignee then has 2 or more tasks in hand and no such worker is free, the line asks pm to judge
  instead: `dev now has 3 tasks in hand (ready, doing or changes) and no other worker who has taken a task is
  free: if this task can run in parallel with the work in hand, add a worker for it; if not, leave it queued`.
  The board cannot tell whether a task can run in parallel; pm decides by the rule in its worker instructions.
- A worker who is no pm and has been neither the assignee nor the reviewer of a task may be there to
  take tasks, which the board cannot tell. That line then names it in place of `add a worker for it`: `give it
  to app (no task yet) if that worker is there to take tasks, or add a worker for it`.

**Input warnings.** Some commands judge the input and let it through. The result then carries `warnings`, a
list of lines (left out when empty); without `--json` each line is also printed on stderr as
`[my-team] warning: <line>`. `warning` (singular, above) stays what went wrong after the write: load, notices and
the event log. None of these refuses a command; a relative path is a warning too, because the board checks no
other input for its form and many boards already hold relative paths.

| Command | Warns when |
|---|---|
| `board-add`, `board-assign` that changes the reviewer | `reviewer` is missing, so pm judges, or is a pm. A team that declares no roles is exempt: every worker is pm there |
| `board-ask`, `board-wait` | `question` is over 120 characters, `context` is over 1000, or the asker then has more than 3 open decisions (its `board-ask` decisions in `open`, plus its `board-wait` tasks in `waiting`). The line tells the asker to keep them all on the board, and when raising them with the user to lead with the one that blocks work and present them one at a time, as the worker protocol says |
| `board-add`, `board-edit` (with `ticket`) | the `ticket` path is not absolute, or the file does not exist |
| `board-land` | the `report` path is not absolute, or the file does not exist |

- The bounds come from the boards of 6 teams (87 briefs): the question's p95 is 120 characters and its maximum 139;
  the context's median is 207, its p95 about 1000 and its maximum 2988. Askers held 1 open decision at most,
  except three who put 4, 8 and 13 on the board at once. Change the bounds in `core/rules.js`.
- Keep documents in `~/.my-team/docs/<team>/`: tickets, reports and review reports, by their absolute path.
  `~` is no part of a path the board reads, so write it out (`/Users/<you>/.my-team/docs/<team>/T1.md`).
- `review_report` is a suggestion for a file the reviewer writes later, so it is not checked.

**Notices.** A write that concerns other workers sends each of them one mailbox line,
`[board] <ref> <action>`. The line carries no state: the reader runs `board-inbox`. The pane trigger is typed
only while the recipient's pane in the manifest is still that worker's pane in the team's session; otherwise
the notice waits in the mailbox and the result carries a `warning`. Every write also adds a
`board` line to `events.jsonl` (see `events-format.md`); `board-wait`, `board-answer` and `board-progress` add
one with `action` `wait`, `answer` and `progress`. A wait tells pm, the assignee and the reviewer; an answer, the assignee and the
reviewer; an edit, the assignee, and the reviewer while the task is in review; an edit of a decision, pm and the
worker who asked.

**Errors.** An error is a stderr line `[my-team] error: <code>: <message>` and exit 1. With `--json`, it is
also printed on stdout as `{"ok": false, "code", "message"}`.

| Code | Meaning |
|---|---|
| `invalid` | an input is missing or wrong, or the rule forbids the result (e.g. approving with an open must finding) |
| `forbidden` | the acting worker may not do this (not pm, not the assignee, judging its own work, another team) |
| `not-found` | no such team, task, landing or finding |
| `invalid-transition` | the task or finding is not in a state this command moves from |
| `stale-landing` | the landing was superseded, or `verified_commit` is not its commit (a commit given for a document task's landing) |
| `conflict` | someone changed the same task three times while this command ran; run it again |
| `board-unavailable` | the team has no board, or this Node has no `node:sqlite` |
| `busy` | the board file stayed locked for 5 seconds |
| `migration-refused` | a write would migrate the board of a running team: run it on a copy of the team's state, or restart the team with `start --continue` |
| `schema-too-new` | a newer my-team wrote this board: install a newer my-team, or put back the copy its migration left (`board.db.v<n>.bak`) |
| `invalid-row`, `invalid-query`, `store` | a bug in my-team; report it |
| `error` | any other failure (a Node error, an unreadable manifest); the message says what |

## Goal order

A request that splits into several tasks gets a goal file, and `my-team api goal-order` turns its order into
waves against the board. It reads only: the goal files and the board, like `board-status`.

**The goal file.** `~/.my-team/docs/<team>/goals/G<n>-<slug>.md` (the `docs` folder sits beside the sessions
folder, so `MY_TEAM_STATE_ROOT_BASE` moves it too). Its first `# ` heading is the title, the goal id in front
of it left out. The rest of the file is free text for people; the command reads only the `## 순서` section:

```markdown
## 순서
- T178 -> T179, T180
- T179, T180 -> T181, T177
- T181:1 -> T177:4-7
- T177, T181 -> T192
```

- Every non-blank line of the section is `- <before> -> <after>`, each side a comma list, or a list line
  `- T201, T202`: tasks of the goal with no order among them (T222). A listed task with no order line is in the
  first wave; one an order line names too keeps that order. Any other line is an error with its line number. The section ends at the next `#` or `##` heading; a `## 순서` inside a code fence
  does not count.
- A reference is a whole task (`T177`) or numbered items of its ticket (`T181:1`, `T177:4-7`, items 1 to 1000).
- A goal file without the section is listed with no waves.
- Only regular files count (a link to one too): a directory named `G<n>-x.md` is skipped.
- One G number in two or more files is one entry: `path` the first by name, `title` null, no waves, and in
  `errors` one `{line: null, text: <path>, reason}` per file. Which file is meant is for a person to fix; the
  command reads no order from any of them, as board-add refuses that goal.

**What starts when.** Every task is one start unit; an item range on the after side is a unit of its own,
waiting on what its task waits on as well. A whole task before waits for the task and all its ranges. Items
before wait where the ranges covering them are, or the task where no range covers them; so items waiting on
each other are a cycle. A whole task before is complete when it is `done` (approved). Items before are complete
when they are all in the task's `progress_summary.done_items` (`board-progress` with `done`), or the task is
`done`. A `cancelled` task completes nothing.

| Command | Who | Input (required **bold**) | Output |
|---|---|---|---|
| `goal-order` | anyone | **`team_name`**; `goal` (`G3`: that goal only, `not-found` if there is none) | `goals`, by number: `{id, title, path, waves, ready_now, unregistered, cycle, errors}` |

- `waves` is a list of waves, each a list of units: `{ref, task, items, after, title, state, status,
  blocked_by}`. `items` is null for a whole task, else the item numbers; `after` the references it waits on,
  each `{ref, task, items}`; `title` and `state` the task's on the board (null when it is not there).
- `status` is `done`, `ready_now` (everything before is complete), `waiting`, `cancelled` (its own task) or
  `unregistered` (not on the board, which is not an error: a planned task may not be added yet).
- `blocked_by` lists what before is not complete, each `{ref, state}`: the task's state, or `unregistered`.
- `ready_now` lists the refs (strings) of the units whose predecessors are all complete and that are not done
  yet: those that can start now, and those already under way (read `state` to tell them apart). `unregistered`
  lists the tasks the board does not have.
- A cycle gives `cycle` (`["A","B","A"]`) and no waves. Errors in the section give `errors` (`{line, text,
  reason}`) and no waves, since a half-read order could show a task as ready that is not. `line` is null for an
  error of the file itself (one G number in two files, `text` the file's path), so a reader takes it as optional.
- A team whose config has no board gets every unit `unregistered`.

## States

| Task state | Means | Leaves by |
|---|---|---|
| `new` | no assignee | `board-assign` → ready, `board-cancel`, `board-wait` |
| `ready` | assigned, not started | `board-take` → doing |
| `doing` | being worked on | `board-land` → review |
| `review` | a landing waits for its verdict | `board-verdict` → done, changes or held; `board-land` again (supersedes) |
| `changes` | the verdict asked for fixes | `board-take` → doing (no pm step) |
| `held` | the reviewer could not verify | `board-assign` → review again, or → ready with a new assignee |
| `waiting` | the user has to decide (the task's `waiting` brief) | `board-answer` → the state it came from; `board-cancel` |
| `done`, `cancelled` | finished | nothing; further work is a derived task (`parent`) |

Any state that is not `done` or `cancelled` can also be cancelled by pm, and corrected with `board-edit`, which moves nothing. `board-wait` moves `new`, `ready`,
`doing`, `review`, `changes` and `held` to `waiting`.

| Finding state | Set by |
|---|---|
| `open` | the reviewer's verdict; the reviewer reopens a fixed one; pm reopens a settled one |
| `fixed` | the assignee's `board-land` with the finding in `closes`, any open finding of the board, its family's or another's; the approve of a landing that names a `backlog` finding in its `closes`; pm, with `board-finding` `fixed` and an approved `landing`, for an open or `backlog` finding fixed where no `closes` named it |
| `backlog`, `accepted-limit`, `rejected` | pm, with `board-finding` or `board-cancel` |

**Rules that hold on every path:**

- Nobody judges a task they are assigned. Nobody approves a commit they landed in the same family, nor a report of a document task they landed a report of.
- `approve` is refused while the family has an open `must` finding. A `must` finding fixed in another family's landing stays open for this until that landing is approved.
- A finding fixed in another family's landing is that landing's to review: its review request lists it under `closes_outside`, and its verdict may reopen it. A `changes` or `hold` leaves the fix pending, a resubmit moves it to the new landing, and cancelling the landing's task reopens it, as in the family.
- A `backlog` finding in `closes` stays `backlog` while the task is in review: the landing keeps the claim, and its
  approve makes the finding fixed in it. Only the approved landing's own `closes` count, so a resubmit names the
  finding again (an open finding's fix moves to the new landing by itself; a backlog one has not moved). A
  `changes`, a `hold` or a cancel leaves it `backlog`. An approve that lists it in `reopen` leaves it `backlog` too. One of
  another family is in the review request's `closes_outside`, still `backlog`. `accepted-limit` and `rejected`
  findings are not fixed this way: pm reopens one first.
- Reopening a finding needs an unfinished task in its family.

## Push gate

`board-pushable` answers whether every commit going out is covered. A commit is covered when it is in the
`commits` of a landing that an approve verdict covers, in the same repository, or when it is the repository's
baseline or one of its ancestors. The same repository is any working tree of one git common directory: the main
folder and its worktrees (`git worktree list`). A landing records the top level it was landed from, so a commit
approved in a worktree is covered from the main folder too. Another clone is another repository. Anything else
is uncovered: a commit in review, one after the approval, a commit off the board, a merge, or a rebased copy of
an approved commit.

The repository's pre-push hook (`scripts/install-pre-push.sh` in this repository) runs the identifier scan
for every ref first. Then, when the repository names a board team, it runs the gate for every ref:

```sh
git config my-team.board <team>          # turns the gate on; without it the hook only scans
git config my-team.baseline <commit>     # its ancestors count as reviewed: work from before the board, your own
```

- Only pm or the user sets these two values. They live in the repository's git config and not on the board,
  because the board moves to `.bak` when a new team starts.
- The hook refuses a push it cannot judge: no `my-team` or `node` on PATH, a team that is not there, or an
  installed `my-team` too old to have `board-pushable`.
- A refusal lists each uncovered commit with its subject, and says how to go on:
  - get it reviewed on the board;
  - for your own commits, move the baseline;
  - or skip both checks once with `git push --no-verify`.
- A remote that moved on to a commit not here yet is refused before either check, with
  `git fetch <remote>` to run first.
- An approval counts in every working tree of the repository it was landed in. A working tree counts while it
  is there and on the repository's git common directory: once the worktree it was landed from is removed,
  pruned or not, its approvals no longer count. Push before removing it. One exception: a worktree that sat
  inside the main working tree, removed and replaced by a plain folder at the same path, still counts. git
  reads that folder as part of the main working tree, on the same common directory, so its approvals are the
  same repository's.
- A landing records a path, not a repository. Another clone made at the very path a worktree was removed from
  and asked from that path still counts that worktree's approvals, as the board did before worktrees counted.
- From the pane of another team's worker, `board-pushable` refuses to read the board, so the gate refuses
  the push. This is meant: push from your own team's pane, or from the user's shell.
- A worker with a `push` or `repo-write` deny rule cannot turn the gate off. Its guard refuses any
  `git config` write of a `my-team.*`, `core.hooksPath`, `include.path` or `includeIf.*` key that reaches
  the repository: in its config, in the user's or the system's. It also refuses direct edits of those
  config files, of the repository's hooks folder and of its git folder itself, by a tool, a shell redirect
  or a command such as `rm`, `mv` or `chmod`. With
  `repo-write`, it refuses every write to the repository's config.

## One cycle

pm adds T1 for dev, reviewed by rv. dev lands commit `$C1`, and rv asks for a fix. dev lands `$C2` closing
the finding, and rv approves. `$BASE`, `$C1` and `$C2` stand for full commit hashes in dev's repository.
`test/board/docs.test.js` runs these lines as written.

<!-- example:start -->
```sh
MY_TEAM_WORKER=demo/pm my-team api board-add --input '{"team_name":"demo","id":"T1","title":"Add the parser","single":true,"assignee":"dev","reviewer":"rv","ticket":"docs/tickets/T1.md","constraints":"없음","base":"$BASE"}' --json
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
and finding `R1 M1` fixed in `T1#2`. Across the cycle the mailbox carried 7 notices: pm 2, dev 3, rv 2. A land on a task with a reviewer goes to
the reviewer only; pm hears at the verdict. A land whose `closes` names another family's open finding also goes to
that finding's task's assignee and reviewer.
