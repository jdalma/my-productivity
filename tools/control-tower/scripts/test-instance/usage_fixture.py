#!/usr/bin/env python3
"""Claude Code transcripts with token usage for the test instance's dashboard (T177).

usage_fixture.py <T> [normal|sparse|none]

  normal  35 days of sessions in seven invented projects: the last 7 days about 40% above the weeks before,
          cache written again after pauses of over an hour, three sessions compacted 3 times or more
  sparse  two active days: no comparison with a usual level
  none    nothing: the dashboard has no record to show

Every name, title and number is invented. The same T and mode give the same files, apart from their times,
which count back from now.
"""
import datetime
import json
import os
import random
import sys

T = sys.argv[1]
MODE = sys.argv[2] if len(sys.argv) > 2 else "normal"
if MODE not in ("normal", "sparse", "none"):
    sys.exit(f"usage_fixture.py: CT_TEST_USAGE is normal, sparse or none, not '{MODE}'")
HOME = f"{T}/home"
NOW = datetime.datetime.now().astimezone()
rng = random.Random(177)

# name: (share of the output, model)
PROJECTS = {
    "notes-app": (34, "claude-opus-5-5"),
    "cli-tools": (21, "claude-opus-5-5"),
    "blog": (14, "claude-sonnet-5-5"),
    "parser": (9, "claude-sonnet-5-5"),
    "sandbox": (6, "claude-haiku-5-5"),
    "docs-site": (9, "claude-sonnet-5-5"),
    "scratch": (7, "claude-haiku-5-5"),
}
# compactions of the newest session of a project
COMPACTIONS = {"notes-app": 11, "cli-tools": 4, "blog": 3, "parser": 1}


def iso(t):
    return t.astimezone(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def project_dir(cwd):
    # Claude Code's projects/<cwd with every non-alphanumeric as '-'>, as fixture.py
    return f"{HOME}/.claude/projects/" + "".join(c if c.isascii() and c.isalnum() else "-" for c in cwd)


def write(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        # no spaces after separators, as Claude Code writes them: the app looks for "type":"assistant"
        f.writelines(json.dumps(l, ensure_ascii=False, separators=(",", ":")) + "\n" for l in lines)


serial = 0


def response(sid, cwd, model, at, output, cache_creation, sidechain=False):
    """One API response as Claude Code writes it: a line per content block, the last with the whole output."""
    global serial
    serial += 1
    lines = []
    for part, out in enumerate((max(1, output // 3), output)):
        lines.append({
            "type": "assistant", "uuid": f"{sid}-a{serial}-{part}", "timestamp": iso(at), "sessionId": sid, "cwd": cwd,
            "gitBranch": "main", "entrypoint": "cli", "isSidechain": sidechain, "requestId": f"req_example{serial:06d}",
            "message": {"id": f"msg_example{serial:06d}", "role": "assistant", "model": model,
                        "content": [{"type": "text", "text": "Example reply."}],
                        "usage": {"input_tokens": 40 + serial % 60, "output_tokens": out,
                                  "cache_creation_input_tokens": cache_creation,
                                  # a session's own requests write a 1 hour cache, its subagents' a 5 minute one
                                  "cache_creation": {("ephemeral_5m_input_tokens" if sidechain else "ephemeral_1h_input_tokens"): cache_creation},
                                  "cache_read_input_tokens": 180_000 + (serial % 9) * 20_000}}})
    return lines


def session(project, week, days):
    """A session of `project` worked on each day of `days` (days ago, newest last), a file of its own."""
    share, model = PROJECTS[project]
    cwd = f"{T}/work/usage/{project}"
    os.makedirs(cwd, exist_ok=True)
    sid = f"00000000-0000-4000-9000-{week:04d}{list(PROJECTS).index(project):08d}"
    first = NOW - datetime.timedelta(days=days[0])
    lines = [
        {"type": "custom-title", "customTitle": f"Example {project} week {week}", "sessionId": sid},
        {"type": "user", "entrypoint": "cli", "uuid": f"{sid}-u", "timestamp": iso(first.replace(hour=9, minute=0)),
         "sessionId": sid, "cwd": cwd, "gitBranch": "main",
         "message": {"role": "user", "content": f"Example request in {project}."}},
    ]
    sub = []
    # the last 7 days run about 40% above the weeks before
    level = 1.4 if week == 0 else 1.0
    for ago in days:
        day = NOW - datetime.timedelta(days=ago)
        for i in range(12):
            # 40 minutes apart from 09:00: under the cache's hour within a day, hours over it between days
            at = day.replace(hour=9, minute=0, second=0, microsecond=0) + datetime.timedelta(minutes=40 * i)
            if at > NOW:
                break
            output = int(rng.randint(600, 1800) * share * level / 10)
            # the day's first response comes hours after the one before it: the cache is written again
            creation = 150_000 if i == 0 else 20_000
            lines += response(sid, cwd, model, at, output, creation)
            if project == "notes-app" and i % 4 == 3:
                sub += response(sid, cwd, "claude-haiku-5-5", at + datetime.timedelta(seconds=30), output // 8, 5_000,
                                sidechain=True)
    if week == 0:
        last = NOW - datetime.timedelta(days=days[-1])
        for n in range(COMPACTIONS.get(project, 0)):
            lines.append({"type": "system", "subtype": "compact_boundary", "uuid": f"{sid}-c{n}", "sessionId": sid,
                          "timestamp": iso(last.replace(hour=9, minute=n)),
                          "compactMetadata": {"trigger": "auto", "preTokens": 260_000, "postTokens": 28_000, "durationMs": 40_000}})
    write(f"{project_dir(cwd)}/{sid}.jsonl", lines)
    if sub:
        write(f"{project_dir(cwd)}/{sid}/subagents/agent-example.jsonl", sub)


if MODE == "normal":
    for week in range(5):
        # every sixth day off, so the weeks have active and idle days
        days = [d for d in range(week * 7 + 6, week * 7 - 1, -1) if d % 6 != 5]
        for project in PROJECTS:
            session(project, week, days)
elif MODE == "sparse":
    for project in ("notes-app", "cli-tools"):
        session(project, 0, [1, 0])
