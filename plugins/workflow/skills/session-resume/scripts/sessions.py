#!/usr/bin/env python3
"""sessions.py — 최근 Claude 트랜스크립트 목록 + resume.

  sessions.py list [--days N]
      ~/.claude/projects/*/*.jsonl 중 최근 N일(기본 7) 세션을 최신순으로 나열.
      my-team 워커 세션은 팀으로 묶는다(키 team:<name>), 나머지는 단일(키 = sessionId).
  sessions.py resume <key>... [--days N]
      team:<name>  → manifest.json으로 config를 재구성, 각 워커에 --resume <sid>를 붙여
                     my-team start 후 Ghostty 새 탭에서 tmux attach.
      <sessionId>  → Ghostty 새 탭을 cwd에서 열고 `claude-yolo --resume <sid>` 입력.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

PROJECTS = Path.home() / ".claude" / "projects"
CLAUDE_CMD = "claude-yolo"  # ponytail: 개인 alias(claude --dangerously-skip-permissions). 다른 PC면 여기만 바꾼다
# start.js / add-worker.js 의 부팅 notice, my-team-resume 스킬의 echo 출력
NOTICE_RE = re.compile(r"^(?:Team is live\. Follow|You just joined team '[^']+'\. First action: read) (\S+)/workers/([^/\s]+)/AGENTS\.md")
RESUME_ECHO_RE = re.compile(r"^worker=[^/\s]+/([^\s]+) state_root=(\S+)")


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(c.get("text", "") if c.get("type") == "text" else "" for c in content if isinstance(c, dict))
    return ""


def parse(path):
    s = {"id": path.stem, "mtime": path.stat().st_mtime, "cwd": None, "title": None,
         "first_prompt": None, "last_prompt": None, "prompts": 0, "worker": None, "state_root": None}
    with path.open(encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            t = r.get("type")
            if t in ("ai-title", "custom-title"):
                s["title"] = r.get("customTitle") or r.get("aiTitle") or s["title"]
                continue
            if t != "user" or r.get("isSidechain"):
                continue
            s["cwd"] = s["cwd"] or r.get("cwd")
            content = r.get("message", {}).get("content")
            if isinstance(content, list) and s["worker"] is None:
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "tool_result":
                        m = RESUME_ECHO_RE.match(text_of(c.get("content")))
                        if m:
                            s["worker"], s["state_root"] = m.group(1), m.group(2)
            if r.get("origin", {}).get("kind") != "human" and r.get("promptSource") != "typed":
                continue
            txt = text_of(content).strip()
            if not txt:
                continue
            s["prompts"] += 1
            m = NOTICE_RE.match(txt)
            if m and s["worker"] is None:
                s["state_root"], s["worker"] = m.group(1), m.group(2)
            elif not m and not txt.startswith(("new-message:", "<")):  # mailbox 주입·로컬 커맨드 래퍼 제외
                s["last_prompt"] = txt.splitlines()[0][:80]
                s["first_prompt"] = s["first_prompt"] or s["last_prompt"]
    return s


def collect(days):
    cutoff = time.time() - days * 86400
    sessions = [parse(p) for p in PROJECTS.glob("*/*.jsonl") if p.stat().st_mtime >= cutoff]
    sessions = [s for s in sessions if s["prompts"] > 0]
    sessions.sort(key=lambda s: s["mtime"], reverse=True)

    groups, teams = [], {}
    for s in sessions:
        if not s["state_root"]:
            groups.append({"key": s["id"], "kind": "single", "mtime": s["mtime"], "sessions": [s]})
            continue
        root = s["state_root"]
        if root not in teams:
            # my-team shutdown은 state_root를 <root>.bak으로 rename한다(1세대). <root>가 남아 있으면
            # 그쪽이 최신 세대라 .bak은 보지 않는다
            from_bak = not Path(root).exists()
            try:
                manifest = json.loads((Path(root + ".bak" if from_bak else root) / "manifest.json").read_text())
            except (OSError, ValueError):
                manifest, from_bak = None, False
            name = manifest["team_name"] if manifest else Path(root).name
            # 같은 team_name이 다른 state_root에 있으면(trailing slash, custom state_root) 최신 쪽만 team:<name>
            key = f"team:{name}" if all(t["team"] != name for t in teams.values()) else f"team:{name}@{root}"
            teams[root] = {"key": key, "kind": "team", "team": name, "state_root": root,
                           "mtime": s["mtime"], "workers": {}, "manifest": manifest, "from_bak": from_bak,
                           "running": bool(manifest) and tmux_has(manifest["session_name"])}
            groups.append(teams[root])
        # 워커별 최신 세션 1개 (sessions가 최신순이라 첫 번째가 최신)
        teams[root]["workers"].setdefault(s["worker"], s)
    return groups


def tmux_has(session_name):
    return subprocess.run(["tmux", "has-session", "-t", session_name.split(":")[0]],
                          capture_output=True).returncode == 0


def fmt_time(ts):
    return time.strftime("%m-%d %H:%M", time.localtime(ts))


def label(s):
    return s["title"] or s["first_prompt"] or "(제목 없음)"


def cmd_list(days):
    groups = collect(days)
    home = str(Path.home())
    for i, g in enumerate(groups, 1):
        if g["kind"] == "single":
            s = g["sessions"][0]
            print(f"{i:>3}. [단일] {fmt_time(s['mtime'])}  {label(s)}")
            print(f"       key={s['id']}  cwd={(s['cwd'] or '?').replace(home, '~')}")
        else:
            state = ("manifest 없음, resume 불가" if not g["manifest"] else "실행 중" if g["running"]
                     else "shutdown됨, .bak 복원 후 resume" if g["from_bak"] else "중지")
            print(f"{i:>3}. [팀 {g['team']}] {fmt_time(g['mtime'])}  워커 {len(g['workers'])}명  ({state})  key={g['key']}")
            alive = {w["name"] for w in g["manifest"]["workers"]} if g["manifest"] else set()
            for w, s in g["workers"].items():
                gone = "" if w in alive or not g["manifest"] else "  (manifest에서 제거됨)"
                print(f"       - {w:<18} {fmt_time(s['mtime'])}  {s['last_prompt'] or label(s)}  ({s['id'][:8]}){gone}")


def ghostty_tab(cwd, text):
    def q(v):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    script = f'''tell application "Ghostty"
  set cfg to {{initial working directory:{q(cwd)}, initial input:{q(text)} & linefeed}}
  if (count of windows) is 0 then
    new window with configuration cfg
  else
    new tab in front window with configuration cfg
  end if
  activate
end tell'''
    subprocess.run(["osascript", "-e", script], check=True)


def role_context(overlay_path):
    # start.js 템플릿의 마지막 섹션 = config extra_prompt 원문
    try:
        text = Path(overlay_path).read_text(encoding="utf-8")
    except OSError:
        return None
    _, sep, rest = text.partition("\n## Role Context\n")
    return rest.rstrip("\n") if sep else None


def resume_team(g):
    root, manifest = Path(g["state_root"]), g["manifest"]
    if not manifest:
        print(f"  건너뜀: {root}/manifest.json 없음", file=sys.stderr)
        return
    if g["running"]:
        print(f"  건너뜀: 이미 실행 중 — tmux attach -t {manifest['session_name'].split(':')[0]}", file=sys.stderr)
        return
    if g["from_bak"]:
        # mailbox·archive까지 그대로 되살린다. manifest의 overlay_path는 원래 root 기준이라 rename 후 유효
        os.rename(f"{root}.bak", root)
        print(f"  복원: {root}.bak → {root}")
    workers = []
    for w in manifest["workers"]:
        args = list(w.get("launch_args", []))
        s = g["workers"].get(w["name"])
        if s and w["agent_type"] == "claude":
            args += ["--resume", s["id"]]
        cfg = {"name": w["name"], "cwd": w["cwd"], "agent_type": w["agent_type"], "launch_args": args}
        extra = role_context(w.get("overlay_path") or root / "workers" / w["name"] / "AGENTS.md")
        if extra:
            cfg["extra_prompt"] = extra
        if w.get("role"):
            cfg["role"] = w["role"]
        # description이 없던 config면 start.js가 extra_prompt 첫 줄을 저장해 둔다. 되돌려 넘기면
        # roster가 extra_prompt 전문 → 첫 줄로 줄어드니 그 경우는 생략한다
        if w.get("description") and w["description"] != (extra or "").split("\n")[0].strip():
            cfg["description"] = w["description"]
        workers.append(cfg)
        print(f"  {w['name']:<16} {'resume ' + s['id'] if s and '--resume' in args else '새 세션 (최근 트랜스크립트 없음)'}")
    config = {"team_name": manifest["team_name"], "state_root": str(root), "detached": True, "workers": workers}
    # ponytail: 원 config의 env는 manifest에 없어 복원 불가. 필요해지면 start.js가 manifest에 env를 저장하게 한다
    with tempfile.NamedTemporaryFile("w", suffix=".json", prefix=f"resume-{manifest['team_name']}-", delete=False) as f:
        json.dump(config, f, ensure_ascii=False, indent=2)
    try:
        # --continue: 메일박스·work를 이어받는다. 없으면 start가 새 팀으로 보고 이전 state를 .bak으로 옮긴다
        subprocess.run(["my-team", "start", "--config", f.name, "--detached", "--continue"], check=True)
    finally:
        os.unlink(f.name)
    session = json.loads((root / "manifest.json").read_text())["session_name"].split(":")[0]
    ghostty_tab(str(Path.home()), f"tmux attach -t {session}")


def resume_single(s):
    if not s["cwd"] or not Path(s["cwd"]).is_dir():
        print(f"건너뜀 {s['id']}: cwd 없음 ({s['cwd']})", file=sys.stderr)
        return
    ghostty_tab(s["cwd"], f"{CLAUDE_CMD} --resume {s['id']}")


def cmd_resume(keys, days):
    groups = {g["key"]: g for g in collect(days)}
    missing = [k for k in keys if k not in groups]
    if missing:
        sys.exit(f"최근 {days}일 목록에 없는 key: {', '.join(missing)}")
    for k in keys:
        g = groups[k]
        print(f"[resume] {k}")
        resume_team(g) if g["kind"] == "team" else resume_single(g["sessions"][0])


def main(argv):
    days = 7
    if "--days" in argv:
        i = argv.index("--days")
        days = int(argv[i + 1])
        del argv[i:i + 2]
    if argv[:1] == ["list"]:
        cmd_list(days)
    elif argv[:1] == ["resume"] and len(argv) > 1:
        cmd_resume(argv[1:], days)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
