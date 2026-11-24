#!/usr/bin/env python3
"""The test instance's fixture (T98): everything under $T that the test app reads.

Usage: fixture.py <T> <panes.tsv>
  panes.tsv: one pane per line, `name<TAB>session<TAB>window_id<TAB>pane_id<TAB>pane_pid`, from the test tmux server.

Writes, all under <T> and nowhere else:
  home/.claude/sessions/<pid>.json and transcripts   live sessions, an ended session and an ended team's worker
  my-team/sessions/example-team/                     a team with a window per worker: manifest (with a task board),
                                                     worker status, spool
  my-team/sessions/example-panes/                    a team with its workers as panes of one window, no task board
  work/<name>/                                       worker folders; work/alpha and work/beta are git repositories
                                                     with changes
  board.json, bin/my-team                            the task board fixture and the fake my-team that answers it
Names are example ones only: this file is in a public repository.
"""
import json
import os
import shutil
import subprocess
import sys
import time

T, PANES = sys.argv[1], sys.argv[2]
HOME = f"{T}/home"
TEAM = "example-team"
ROOT = f"{T}/my-team/sessions/{TEAM}"
# the other team: its panes share one tmux window (the first has one window per worker, T109)
PANES_TEAM = "example-panes"
NOW = time.time()


def iso(minutes_ago=0.0):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(NOW - minutes_ago * 60))


def ms(minutes_ago=0.0):
    return int((NOW - minutes_ago * 60) * 1000)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def write_json(path, value):
    write(path, json.dumps(value, ensure_ascii=False, indent=1) + "\n")


def project_dir(cwd):
    # Claude Code's projects/<cwd with every non-alphanumeric as '-'>
    return f"{HOME}/.claude/projects/" + "".join(c if c.isascii() and c.isalnum() else "-" for c in cwd)


def transcript(sid, cwd, first_prompt, reply, minutes_ago, title=None):
    lines = []
    if title:
        lines.append({"type": "custom-title", "customTitle": title, "sessionId": sid})
    lines.append({"type": "user", "entrypoint": "cli", "uuid": f"{sid}-u", "timestamp": iso(minutes_ago + 1),
                  "sessionId": sid, "cwd": cwd, "gitBranch": "main", "message": {"role": "user", "content": first_prompt}})
    lines.append({"parentUuid": f"{sid}-u", "type": "assistant", "uuid": f"{sid}-a", "timestamp": iso(minutes_ago),
                  "sessionId": sid, "cwd": cwd, "message": {"role": "assistant", "content": [{"type": "text", "text": reply}]}})
    write(f"{project_dir(cwd)}/{sid}.jsonl", "".join(json.dumps(l, ensure_ascii=False) + "\n" for l in lines))


# ---------------------------------------------------------------- sessions and the team

# name: (Claude status, my-team state, spool files, minutes since the status, reply): the five worker states
WORKERS = {
    "alpha": ("wait", "idle", 0, 2, "Example change is ready for a look."),          # 답 기다림
    "beta": ("busy", "working", 0, 1, "Running the example build."),                  # 작업 중
    "gamma": ("wait", "working", 0, 3, "Asking to run an example command."),          # 권한 요청 (the pane shows the prompt)
    "delta": ("wait", "done", 0, 7, "Example task finished and reported."),           # N분 전 완료
    "epsilon": ("wait", "idle", 1, 12, "Waiting on a message in the spool."),          # 쉬는 중 (unread spool)
    "eta": ("wait", "idle", 0, 5, "Example panes team: ready for a look."),
    "theta": ("busy", "working", 0, 1, "Example panes team: building."),
    "iota": ("wait", "done", 0, 9, "Example panes team: finished."),
}

panes = [l.rstrip("\n").split("\t") for l in open(PANES) if l.strip()]
manifest_workers = {TEAM: [], PANES_TEAM: []}
for n, (name, session, window, pane, pid) in enumerate(panes):
    cwd = f"{T}/work/{name}"
    os.makedirs(cwd, exist_ok=True)
    sid = f"00000000-0000-4000-8000-{n + 1:012d}"
    if name == "solo":
        status, minutes, reply = "wait", 4, "Example loose session waiting."
        prompt = "Example request outside any team."
    else:
        status, state, spool, minutes, reply = WORKERS[name]
        root = f"{T}/my-team/sessions/{session}"
        prompt = f"Team is live. Follow {root}/workers/{name}/AGENTS.md for the peer protocol."
        write_json(f"{root}/workers/{name}/status.json", {"state": state, "updated_at": iso(minutes)})
        for i in range(spool):
            write_json(f"{root}/incoming-spool/{name}/{i}.json", {"from": "pm", "body": "example spool message"})
        manifest_workers[session].append({"name": name, "pane_id": pane, "cwd": cwd, "agent_type": "claude",
                                 "role": "example worker", "description": f"example {name}"})
    write_json(f"{HOME}/.claude/sessions/{pid}.json", {
        "pid": int(pid), "sessionId": sid, "cwd": cwd, "startedAt": ms(60), "status": status,
        "statusUpdatedAt": ms(minutes), "updatedAt": ms(minutes), "entrypoint": "cli", "tmux": f"{session}:{window}.{pane}"})
    transcript(sid, cwd, prompt, reply, minutes)

write_json(f"{ROOT}/manifest.json", {
    "team_name": TEAM, "state_root": ROOT, "session_name": TEAM, "started_at": iso(90),
    # its presence gives the team a task board; the app reads it through bin/my-team
    "board": {"path": f"{ROOT}/board.db"},
    "workers": manifest_workers[TEAM]})
if manifest_workers[PANES_TEAM]:
    panes_root = f"{T}/my-team/sessions/{PANES_TEAM}"
    write_json(f"{panes_root}/manifest.json", {
        "team_name": PANES_TEAM, "state_root": panes_root, "session_name": PANES_TEAM, "started_at": iso(45),
        "workers": manifest_workers[PANES_TEAM]})

# history: an ended session, and a worker of a team that has stopped (no session file for either)
transcript("00000000-0000-4000-8000-0000000000e1", f"{T}/work/solo", "Example request from yesterday.",
           "Example answer, session ended.", 26 * 60, title="example: ended session")
old_root = f"{T}/my-team/sessions/old-example-team"
transcript("00000000-0000-4000-8000-0000000000e2", f"{T}/work/alpha",
           f"Team is live. Follow {old_root}/workers/zeta/AGENTS.md for the peer protocol.", "Example team work done.", 30 * 60)
os.makedirs(f"{HOME}/.codex", exist_ok=True)

# ---------------------------------------------------------------- git repositories with changes (work/alpha, work/beta)

repo = f"{T}/work/alpha"
git_env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": HOME,
           "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "LC_ALL": "C"}


def git(*args):
    return subprocess.run(["git", "-C", repo, *args], env=git_env, check=True, capture_output=True, text=True).stdout.strip()


def init():
    os.makedirs(repo, exist_ok=True)
    git("init", "-q", "-b", "main")
    for k, v in [("user.name", "Example Author"), ("user.email", "example@example.invalid"),
                 ("commit.gpgsign", "false"), ("tag.gpgsign", "false")]:
        git("config", k, v)


init()
base_files = {
    "README.md": "# Example project\n\nA fixture repository for the test instance.\n",
    "LICENSE": "Example license text.\n",
    "src/app/main.swift": "".join(f"let line{i} = {i}\n" for i in range(1, 41)),
    "src/app/util/strings.swift": "func greet(_ name: String) -> String {\n    \"Hello, \\(name)\"\n}\n",
    "src/lib/keep.swift": "// unchanged in every section\nstruct Keep {}\n",
    "src/lib/deep/nested/more/value.swift": "let value = 1\n",
    "docs/guide.md": "# Guide\n\nUnchanged guide.\n",
    "docs/old.md": "# Old\n\nRemoved on the branch.\n",
    "config/legacy.json": "{\"legacy\": true}\n",
    "tests/keep_test.swift": "// unchanged test\n",
}
for path, text in base_files.items():
    write(f"{repo}/{path}", text)
git("add", "-A")
git("commit", "-q", "-m", "example: base")
git("switch", "-q", "-c", "example/feature")
# committed on the branch: a modification in a long file, a new file deep down, a deletion
main = base_files["src/app/main.swift"].splitlines(keepends=True)
main[9] = "let line10 = 10 * 2  // changed on the branch\n"
main[30:32] = ["let line31 = \"thirty-one\"\n"]
write(f"{repo}/src/app/main.swift", "".join(main))
write(f"{repo}/src/app/feature/views/new_view.swift", "struct NewView {\n    let title = \"example\"\n}\n")
os.remove(f"{repo}/docs/old.md")
git("add", "-A")
git("commit", "-q", "-m", "example: feature work")
# not committed: a staged change, an unstaged change, a new untracked file, an unstaged deletion
write(f"{repo}/src/app/util/strings.swift", "func greet(_ name: String) -> String {\n    \"Hi, \\(name)!\"\n}\n")
git("add", "src/app/util/strings.swift")
write(f"{repo}/README.md", base_files["README.md"] + "\nA line not yet committed.\n")
write(f"{repo}/notes/todo/example.md", "- an untracked example note\n")
os.remove(f"{repo}/config/legacy.json")

# work/beta: another worker's repository, with other files, so switching workers changes the diff window
repo = f"{T}/work/beta"
init()
write(f"{repo}/README.md", "# Second example project\n")
write(f"{repo}/lib/shapes.swift", "struct Circle {\n    let radius = 1.0\n}\n")
git("add", "-A")
git("commit", "-q", "-m", "example: second base")
git("switch", "-q", "-c", "example/shapes")
write(f"{repo}/lib/shapes.swift", "struct Circle {\n    let radius = 2.0\n}\n\nstruct Square {\n    let side = 1.0\n}\n")
git("add", "-A")
git("commit", "-q", "-m", "example: shapes work")
# T5's commits since its start commit (T128): the task's base is this repository's main
write(f"{repo}/lib/area.swift", "func area(_ c: Circle) -> Double {\n    3.14 * c.radius * c.radius\n}\n")
git("add", "-A")
git("commit", "-q", "-m", "example: area of each shape")
write(f"{repo}/tests/shapes_test.swift", "// example test\n")
write(f"{repo}/tests/area_test.swift", "// example test\n")
git("add", "-A")
git("commit", "-q", "-m", "example: tests for the shapes")
beta_base = git("rev-parse", "main")
beta_head = git("rev-parse", "HEAD")
write(f"{repo}/README.md", "# Second example project\n\nA beta line not yet committed.\n")

# ---------------------------------------------------------------- task board

def task(id, title, state, minutes_ago, assignee="alpha", parent=None, priority=100, ticket=True, constraints=True):
    if ticket:
        write(f"{T}/docs/tickets/{id}.md", f"# {id} {title}\n\nExample ticket.\n")
    return {"id": id, "parent_id": parent, "title": f"{TEAM}: {title}",
            "ticket_path": f"{T}/docs/tickets/{id}.md" if ticket else None, "state": state,
            "assignee": assignee, "reviewer": "reviewer" if assignee else None, "priority": priority,
            "base_commit": "0123456789abcdef0123456789abcdef01234567",
            "constraints": "example constraints: no push" if constraints else None,
            "created_at": iso(minutes_ago + 130), "created_by": "pm", "updated_at": iso(minutes_ago),
            "assigned_at": iso(minutes_ago + 125) if assignee else None, "updated_by": assignee or "pm", "waiting": None,
            "progress_summary": None}


def brief(question, context, options, recommendation, impact, ref, minutes_ago, by, resume=None):
    """A decision brief (T116) as `board-wait` keeps it: what a user decides from without reading anything else.
    `options` is (label, detail, pros, cons) each. With `resume`, the waiting task's brief; without, the one an
    answer keeps (`board-answer` drops resume_state, my-team service.js answer)."""
    b = {"question": question, "context": context,
         "options": [{"label": l, "detail": d, "pros": p, "cons": c} for l, d, p, c in options],
         "recommendation": recommendation, "impact": impact, "refs": [f"{T}/docs/tickets/{ref}.md"],
         "asked_by": by, "asked_at": iso(minutes_ago)}
    if resume:
        b["resume_state"] = resume
    return b


tasks = [
    task("T1", "example held for a decision", "held", 40),
    task("T2", "example done with a must finding open", "done", 50, assignee="beta"),
    task("T3", "example submitted three times", "review", 6, assignee="gamma"),
    task("T4", "example ready to start", "ready", 15, assignee="delta"),
    task("T5", "example in progress", "doing", 9, assignee="beta"),
    task("T6", "example sent back for changes", "changes", 11, assignee="epsilon"),
    task("T7", "example done, a low finding to tidy", "done", 70, assignee="alpha"),
    task("T8", "example done and clean", "done", 120, assignee="delta"),
    task("T9", "example cancelled", "cancelled", 200, assignee=None),
    task("T10", "example not assigned yet", "new", 3, assignee=None),
    task("T11", "example subtask of T5", "doing", 8, assignee="beta", parent="T5"),
    task("T12", "example waiting on the user", "waiting", 25, assignee="beta"),
]
# T5 in progress (T128): a ticket with a goal and a numbered to-do list, the assignee's progress on it, and commits
# in beta's folder since its start commit
t5 = next(t for t in tasks if t["id"] == "T5")
t5["base_commit"] = beta_base
# T2 done (G4 I6): its landing is beta's work at a real commit, which the task board's tree and editor read
next(t for t in tasks if t["id"] == "T2")["base_commit"] = beta_base
write(t5["ticket_path"], """# T5 — example-team: example shapes report

담당: beta · 리뷰: reviewer · base main

**사용자 목표:** Each example shape shows its area in the report, so a reader can compare them at a glance.

**What:**
1. **Area function.** One function per shape.
   - circles first
2. **Tests.** A test for each area.
3. **Report line.** One line per shape with its area.
4. **Sort.** Largest first.

**Acceptance:**
1. swift test passes.

## Notes

> [!NOTE]
> The report is read in a **terminal**, 80 columns wide.

> [!WARNING]
> `area()` rounds to two places; do not compare with `==`.

Before the review:

- [x] every shape has a test
- [ ] the report sorts largest first

| shape | area | checked |
|---|---|---|
| circle | `pi * r * r` | yes |
| square | `side * side` | not yet |

```swift
func area(_ s: Shape) -> Double { s.width * s.height }
```

---

An example line after the rule.
""")
progress = {"T5": [
    {"item": 0, "note": "Read the shapes code; the radius was a constant.", "done": False, "by": "beta", "at": iso(30)},
    {"item": 1, "note": "Area for circles and squares is in lib/area.swift.", "done": True, "by": "beta", "at": iso(20)},
    {"item": 2, "note": "Two tests written; the **square** one still fails on rounding in `area()`.", "done": False, "by": "beta", "at": iso(9)},
]}
t5["progress_summary"] = {"done_items": [1], "last_note": progress["T5"][-1]["note"], "last_at": progress["T5"][-1]["at"]}
tasks[-1]["waiting"] = brief(
    "Should the example list keep going past the first error, or stop there?",
    "The example list **stops** at the first error. Two callers need the rest of the lines too:\n"
    "- the `main.txt` reader\n"
    "- the example report\n\n"
    "Checked: `work/alpha/src/main.txt:12` reads one line at a time.\n\n"
    "> [!WARNING]\n> The example callers time out after 30 lines.",
    [("Keep going", "Show **every** line and mark the bad ones with `!`.", ["nothing is hidden"],
      ["a long list on a bad file", "one more state to test"]),
     ("Stop at the first", "Show the lines up to the error, as now.", ["no change"], ["the callers read the file twice"])],
    {"option": "Keep going", "reason": "Both callers want every line."},
    "**beta waits** on this.\n- either way is a small change to undo\n- `T5` is not stopped", "T12", 25, "beta", resume="doing")
# T5 asked the user once and was answered (T116): its family keeps the answer, an option of its own brief, and that
# brief as it was asked
answers = {"T5": [{"task_id": "T5", "question": "Which example format first, text or table?", "chosen": "Text",
                   "answer": "Text first; the table can wait.", "answered_by": "pm", "answered_at": iso(20),
                   "brief": brief(
                       "Which example format first, text or table?",
                       "The example report has one reader today, who reads it in a terminal. A table needs a width "
                       "the terminal does not always have.",
                       [("Text", "One line per item, as the log shows it.", ["reads in any terminal"],
                         ["harder to compare items"]),
                        ("Table", "Columns per field.", ["easy to compare"], ["breaks in a narrow terminal"])],
                       {"option": "Text", "reason": "The one reader uses a terminal."},
                       "beta waits on this before writing the report; the other format can follow.",
                       "T5", 35, "beta")}]}


def landing(id, task_id, minutes_ago, by, closes=(), superseded=None, report=True):
    return {"id": id, "task_id": task_id, "commit": "abcdef0123456789abcdef0123456789abcdef01",
            "check_cmd": "swift test", "check_result": "example: all passed", "focus": ["example focus"],
            "closes": list(closes), "report_path": f"{T}/docs/reports/{task_id}-report.md" if report else None,
            "review_report_path": None, "deployed": None, "superseded_by": superseded, "left_out": [],
            "created_at": iso(minutes_ago), "created_by": by}


def verdict(id, landing_id, kind, minutes_ago):
    return {"id": id, "landing_id": landing_id, "verdict": kind, "report_path": f"{T}/docs/reports/{id}-review.md",
            "rerun_cmd": "swift test", "rerun_result": "example rerun", "side_notes": None,
            "created_at": iso(minutes_ago), "created_by": "reviewer"}


def finding(id, verdict_id, task_id, severity, state, summary, fixed_in=None):
    return {"id": id, "verdict_id": verdict_id, "task_id": task_id, "severity": severity, "summary": summary,
            "repro": "example repro", "state": state, "fixed_in": fixed_in}


landings = [
    landing("T1#1", "T1", 45, "alpha"),                       # held by the review of it (R7)
    landing("T2#1", "T2", 55, "beta"),
    landing("T3#1", "T3", 40, "gamma", superseded="T3#2"),
    landing("T3#2", "T3", 38, "gamma"),
    landing("T3#3", "T3", 6, "gamma", closes=["R3 S1"]),
    landing("T6#1", "T6", 20, "epsilon"),
    landing("T7#1", "T7", 75, "alpha"),
    landing("T8#1", "T8", 125, "delta", closes=["R5 L1"]),
]
next(l for l in landings if l["id"] == "T2#1").update(repo=f"{T}/work/beta", commit=beta_head, base_commit=beta_base, commits=[beta_head])
verdicts = [
    verdict("R1", "T2#1", "approve", 52),
    verdict("R2", "T3#1", "changes", 39),
    verdict("R3", "T3#2", "changes", 30),
    verdict("R4", "T6#1", "changes", 12),
    verdict("R5", "T7#1", "approve", 72),
    verdict("R6", "T8#1", "approve", 122),
    verdict("R7", "T1#1", "hold", 40),
]
findings = [
    finding("R1 M1", "R1", "T2", "must", "open", "example must finding left open on a done task"),
    finding("R3 S1", "R3", "T3", "should", "fixed", "example fixed in the third submission, review pending", "T3#3"),
    finding("R3 L1", "R3", "T3", "low", "open", "example low finding on the review"),
    finding("R4 M1", "R4", "T6", "must", "open", "example must finding to fix"),
    finding("R4 S1", "R4", "T6", "should", "open", "example should finding to fix"),
    finding("R5 L1", "R5", "T7", "low", "fixed", "example fixed by another task", "T8#1"),
    finding("R5 L2", "R5", "T7", "low", "open", "example low finding left to tidy"),
    finding("R6 L1", "R6", "T8", "low", "backlog", "example tidied: later"),
    finding("R6 L2", "R6", "T8", "low", "accepted-limit", "example tidied: accepted limit"),
    finding("R6 L3", "R6", "T8", "low", "rejected", "example tidied: not a finding"),
]
notes = [{"seq": 1, "task_id": "T1", "body": "example note: waiting on the **user's** decision, see `T12`", "to": ["pm"],
          "created_at": iso(41), "created_by": "pm"}]
announcements = [
    {"seq": 1, "body": "example announcement: the board reads only", "created_at": iso(300), "created_by": "pm"},
    {"seq": 2, "body": "example announcement: **done** tasks with `low` findings wait to be tidied", "created_at": iso(100), "created_by": "pm"},
]
recent = []


def event(minutes_ago, actor, action, ref=None, state_from=None, state_to=None, detail=None):
    recent.append({"seq": len(recent) + 1, "at": iso(minutes_ago), "actor": actor, "action": action, "ref": ref,
                   "state_from": state_from, "state_to": state_to, "detail": detail})


event(60, "pm", "add", "T10")
event(35, "beta", "wait", "T5", "doing", "waiting", {"task": "T5"})
event(25, "beta", "wait", "T12", "doing", "waiting", {"task": "T12"})
event(20, "pm", "answer", "T5", "waiting", "doing", {"task": "T5"})
event(45, "pm", "assign", "T6", detail="epsilon")
event(40, "gamma", "land", "T3#1", "doing", "review", {"task": "T3"})
event(30, "reviewer", "verdict", "R3", "review", "changes", {"verdict": "changes", "landing": "T3#2"})
event(12, "reviewer", "verdict", "R4", "review", "changes", {"verdict": "changes", "landing": "T6#1"})
for n, (ref, to) in enumerate([("R6 L1", "backlog"), ("R6 L2", "accepted-limit"), ("R6 L3", "rejected")]):
    event(10, "pm", "finding", ref, "open", to)  # three tidy-ups in one minute
event(6, "gamma", "land", "T3#3", "changes", "review", {"task": "T3"})
event(8, "beta", "take", "T11", "ready", "doing")
recent.sort(key=lambda e: e["at"])
for i, e in enumerate(recent):
    e["seq"] = i + 1
recent.reverse()

approved = {v["landing_id"] for v in verdicts if v["verdict"] == "approve"}
# open on the board: open findings, and fixed ones no approve covers yet
open_findings = [f for f in findings if f["state"] == "open" or (f["state"] == "fixed" and f["fixed_in"] not in approved)]
names = sorted({t["assignee"] for t in tasks if t["assignee"]})
workers = [{"name": n, "role": "example worker", "assigned": sum(t["assignee"] == n for t in tasks), "reviewing": 0}
           for n in names] + [{"name": "reviewer", "role": "example reviewer", "assigned": 0,
                               "reviewing": sum(t["state"] == "review" for t in tasks)}]


def decision(id, b, task_id=None, tasks=(), answer=None):
    """A decision as `board-status` lists it (my-team T146): the brief's fields at the top, the answer's once answered."""
    d = {"id": id, "task_id": task_id, "tasks": list(tasks), "state": "answered" if answer else "open",
         **{k: v for k, v in b.items() if k != "resume_state"}}
    return {**d, **(answer or {})}


# the board's decisions (T147): T12's wait open, T5's wait answered, and three of board-ask, one tied to T5, one to
# no task, one withdrawn
decisions = [
    decision("T5:1", answers["T5"][0]["brief"], "T5", ["T5"],
             {k: answers["T5"][0][k] for k in ("chosen", "answer", "answered_by", "answered_at")}),
    decision("T12:1", tasks[-1]["waiting"], "T12", ["T12"]),
    decision("D#1", brief(
        "Should the example report name every input file, or only the ones that failed?",
        "T5 writes the report next. A run reads up to 40 files; most pass.",
        [("Every file", "One line per input file.", ["nothing to guess"], ["40 lines for a run that passed"]),
         ("Failed only", "Only the files that failed, and a count of the rest.", ["short"], ["a passed file is not named"])],
        {"option": "Failed only", "reason": "Readers look for what failed."},
        "T5 can go on; the report's last part waits on this.", "T5", 12, "beta"), tasks=["T5"]),
    decision("D#2", brief(
        "Keep the example team running over the weekend?",
        "No task needs it yet; the next work starts Monday.",
        [("Keep it", "Leave the panes as they are.", ["Monday starts at once"], ["the machine stays busy"]),
         ("Stop it", "Shut the team down on Friday.", ["nothing runs unwatched"], ["a restart on Monday"])],
        {"option": None, "reason": "Either is fine for the work; it is the user's machine."},
        "Nothing waits on it this week.", "T1", 4, "pm")),
    decision("D#3", brief(
        "Rename the example module before the release?",
        "Asked before the release was moved.",
        [("Rename", "New name now.", ["clearer"], ["callers change"]),
         ("Keep", "Old name.", ["no change"], ["a confusing name"])],
        {"option": "Keep", "reason": "No release this month."},
        "None now.", "T1", 90, "pm"),
        answer={"chosen": "철회", "answer": "The release moved; no longer needed.", "answered_by": "pm", "answered_at": iso(60)}),
]

status = {"tasks": tasks, "workers": workers, "open_findings": open_findings, "recent": recent,
          "announcements": announcements, "decisions": decisions}

by_id = {t["id"]: t for t in tasks}
landing_task = {l["id"]: l["task_id"] for l in landings}

# how each task has gone (my-team T156 `history`, T157): the counts of its landings and verdicts, its last event,
# when it entered its state, who wrote the last progress record, and where a cancelled one stopped
# The event's time is the task's own for what the task keeps a time of (R18 L5): made at `created_at`, assigned at
# `assigned_at`; for the rest it is the landing's, the verdict's or the answer's, given as minutes ago.
def history(id, action, by, minutes_ago, state_from, verdict=None, cancelled_from=None):
    t = by_id[id]
    at = {"add": t["created_at"], "assign": t["assigned_at"]}.get(action) or iso(minutes_ago)
    mine = [l for l in landings if l["task_id"] == id]
    kinds = [v["verdict"] for v in verdicts if landing_task[v["landing_id"]] == id]
    t["history"] = {
        "landings": len(mine), "verdicts": {k: kinds.count(k) for k in ("approve", "changes", "hold")},
        "last_event": {"action": action, "verdict": verdict, "by": by, "at": at,
                       "state_from": state_from, "state_to": t["state"]},
        "state_since": at,
        "last_progress_by": progress[id][-1]["by"] if id in progress else None, "cancelled_from": cancelled_from}


history("T1", "verdict", "reviewer", 40, "review", verdict="hold")   # R7 on T1#1
history("T2", "verdict", "reviewer", 52, "review", verdict="approve")
history("T3", "land", "gamma", 6, "doing")                    # the third submission, after two requests for changes
history("T4", "assign", "pm", None, "new")
history("T5", "answer", "pm", 20, "waiting")                  # its progress record (9 minutes ago) is later
history("T6", "verdict", "reviewer", 12, "review", verdict="changes")
history("T7", "verdict", "reviewer", 72, "review", verdict="approve")
history("T8", "verdict", "reviewer", 122, "review", verdict="approve")
history("T9", "cancel", "pm", 200, "new", cancelled_from="new")      # nobody held it: it never left the first step
history("T10", "add", "pm", None, None)
history("T11", "take", "beta", 8, "ready")
history("T12", "wait", "beta", 25, "doing")


def root_of(id):
    while by_id[id]["parent_id"]:
        id = by_id[id]["parent_id"]
    return id


families = {}
for t in tasks:
    root = root_of(t["id"])
    ids = {x["id"] for x in tasks if root_of(x["id"]) == root}
    fam_findings = [f for f in findings if f["task_id"] in ids]
    families[t["id"]] = {
        "root": by_id[root],
        "tasks": [x for x in tasks if x["id"] in ids],
        "landings": [l for l in landings if l["task_id"] in ids],
        "verdicts": [v for v in verdicts if landing_task[v["landing_id"]] in ids],
        "findings": fam_findings,
        "notes": [n for n in notes if n["task_id"] in ids],
        "fixed_elsewhere": [{"landing": f["fixed_in"], "task_id": landing_task[f["fixed_in"]], "approved": f["fixed_in"] in approved}
                            for f in fam_findings if f["fixed_in"] and landing_task[f["fixed_in"]] not in ids],
        "answers": [a for i in sorted(ids) for a in answers.get(i, [])],
        "progress": progress.get(t["id"], []),
    }
# reports a detail previews (T155): every block the app draws, so a capture shows them
def report(title):
    return f"""# {title}

## Summary

An example report with **bold**, `code` and a [link](https://example.com).

> [!TIP]
> Run `swift test` before reading on.

> [!IMPORTANT]
> The example change touches one file.

> [!CAUTION]
> Do not run the example on real data.

- [x] built without warnings
- [x] tests pass
- [ ] a person looked at the screen

| check | result |
|---|---|
| build | passed |
| tests | 12 of 12 |

```sh
swift build --build-tests
```

---

> A plain quote stays a quote.
"""


for l in landings:
    write(f"{T}/docs/reports/{l['task_id']}-report.md", report(f"{l['task_id']} example report"))
for v in verdicts:
    write(f"{T}/docs/reports/{v['id']}-review.md", report(f"{v['id']} example review"))

write_json(f"{T}/board.json", {"team": TEAM, "status": status, "families": families})
os.makedirs(f"{T}/bin", exist_ok=True)
shutil.copy(os.path.join(os.path.dirname(os.path.abspath(__file__)), "fake-my-team.py"), f"{T}/bin/my-team")
os.chmod(f"{T}/bin/my-team", 0o755)
