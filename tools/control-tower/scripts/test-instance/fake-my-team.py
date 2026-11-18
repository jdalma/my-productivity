#!/usr/bin/env python3
"""The test instance's `my-team` (T98): first on the test app's PATH, so the real CLI and the real task board are
never reached. It answers `my-team api board-status --input <json> --json` from ../board.json (written by
fixture.py): the board without "task", one task's family with it. Every call is a line in ../actions.log; any
other command fails.
"""
import json
import os
import shlex
import sys

T = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
args = sys.argv[1:]
with open(f"{T}/actions.log", "a") as log:
    log.write("fake-my-team " + " ".join(shlex.quote(a) for a in args) + "\n")


def answer(value, code=0):
    print(json.dumps(value, ensure_ascii=False))
    sys.exit(code)


if args[:2] != ["api", "board-status"] or "--input" not in args:
    answer({"ok": False, "code": "test_instance", "message": "the test instance's my-team answers board-status only"}, 1)
request = json.loads(args[args.index("--input") + 1])
with open(f"{T}/board.json") as f:
    board = json.load(f)
if request.get("team_name") != board["team"]:
    answer({"ok": False, "code": "not_found", "message": f"no board for team {request.get('team_name')}"}, 1)
task = request.get("task")
if task is None:
    answer({"ok": True, **board["status"]})
if task not in board["families"]:
    answer({"ok": False, "code": "not_found", "message": f"no task {task}"}, 1)
answer({"ok": True, **board["families"][task]})
