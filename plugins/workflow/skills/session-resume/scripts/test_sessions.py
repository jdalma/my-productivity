"""python3 -I test_sessions.py — 팀/단일 분류와 Role Context 복원 확인."""
import json
import os
import sys
import time
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import sessions


def user(text):
    return {"type": "user", "cwd": "/w", "origin": {"kind": "human"}, "message": {"content": text}}


with tempfile.TemporaryDirectory() as d:
    d = Path(d)
    root = d / "state" / "t1"
    (root / "workers" / "pm").mkdir(parents=True)
    (root / "workers" / "pm" / "AGENTS.md").write_text("# P\nsee `## Role Context`\n\n## Role Context\n## 역할\nPM\n")
    (root / "manifest.json").write_text(json.dumps({"team_name": "t1", "session_name": "my-team-t1-x:0",
                                                    "workers": [{"name": "pm"}]}))
    proj = d / "projects" / "p"
    proj.mkdir(parents=True)
    rows = {
        "a": [user(f"Team is live. Follow {root}/workers/pm/AGENTS.md for the peer protocol"), user("new-message:qa"), user("작업 정리해줘")],
        "b": [user(f"You just joined team 't1'. First action: read {root}/workers/qa/AGENTS.md for the roster")],
        "c": [user("그냥 질문"), {"type": "ai-title", "aiTitle": "단일 세션"}],
        "empty": [{"type": "mode"}],
    }
    for sid, rs in rows.items():
        (proj / f"{sid}.jsonl").write_text("\n".join(json.dumps(r) for r in rs))
    sessions.PROJECTS = d / "projects"

    groups = {g["key"]: g for g in sessions.collect(7)}
    assert set(groups) == {"team:t1", "c"}, groups.keys()
    team = groups["team:t1"]
    assert set(team["workers"]) == {"pm", "qa"}
    assert team["workers"]["pm"]["last_prompt"] == "작업 정리해줘"
    assert sessions.label(groups["c"]["sessions"][0]) == "단일 세션"
    assert sessions.role_context(root / "workers" / "pm" / "AGENTS.md") == "## 역할\nPM"
    assert team["manifest"] and not team["from_bak"]

    # shutdown된 팀: <root>.bak만 남음 → 복원 후 --resume 붙여 start
    root2 = d / "state" / "t2"
    bak = Path(f"{root2}.bak")
    (bak / "workers" / "pm").mkdir(parents=True)
    (bak / "workers" / "pm" / "AGENTS.md").write_text("x\n## Role Context\nPM 브리프\n")
    (bak / "manifest.json").write_text(json.dumps({"team_name": "t2", "session_name": "my-team-t2-y:0", "workers": [
        {"name": "pm", "cwd": "/w", "agent_type": "claude", "role": "orchestrator", "description": "PM 브리프",
         "launch_args": ["--dangerously-skip-permissions"], "overlay_path": f"{root2}/workers/pm/AGENTS.md"}]}))
    (proj / "e.jsonl").write_text(json.dumps(user(f"Team is live. Follow {root2}/workers/pm/AGENTS.md for the peer protocol")))
    g2 = {g["key"]: g for g in sessions.collect(7)}["team:t2"]
    assert g2["from_bak"] and g2["manifest"]["team_name"] == "t2"

    started = {}
    def fake_run(cmd, **kw):
        if cmd[0] == "my-team":
            started.update(json.load(open(cmd[3])), path=cmd[3], continues="--continue" in cmd)
        raise SystemExit  # osascript 직전에 멈춘다
    real_run, sessions.subprocess.run = sessions.subprocess.run, fake_run
    try:
        sessions.resume_team(g2)
    except SystemExit:
        pass
    sessions.subprocess.run = real_run
    assert root2.is_dir() and not bak.exists(), ".bak이 원래 root로 복원돼야 한다"
    w = started["workers"][0]
    assert w["launch_args"] == ["--dangerously-skip-permissions", "--resume", "e"]
    assert w["extra_prompt"] == "PM 브리프" and w["role"] == "orchestrator"
    assert started["state_root"] == str(root2)
    assert started["continues"], "이어 띄우기는 --continue: 없으면 start가 state를 .bak으로 옮긴다"
    assert "description" not in w, "start.js가 extra_prompt 첫 줄로 채운 description은 되돌려 넘기지 않는다"
    assert not Path(started["path"]).exists(), "임시 config는 start 후 지운다"

    # 같은 team_name, 다른 state_root → key가 겹치지 않는다 (최신 쪽이 team:<name>)
    root3 = d / "other" / "t2"
    (root3 / "workers" / "pm").mkdir(parents=True)
    (root3 / "manifest.json").write_text(json.dumps({"team_name": "t2", "session_name": "my-team-t2-z:0", "workers": []}))
    (proj / "f.jsonl").write_text(json.dumps(user(f"Team is live. Follow {root3}/workers/pm/AGENTS.md for the peer protocol")))
    os.utime(proj / "f.jsonl", (time.time() - 60,) * 2)
    keys = [g["key"] for g in sessions.collect(7) if g["kind"] == "team"]
    assert len(keys) == len(set(keys)) and "team:t2" in keys, keys
print("ok")
