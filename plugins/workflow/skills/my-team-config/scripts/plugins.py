#!/usr/bin/env python3
"""plugins.py — my-team 워커에 주입할 plugin 후보 조회 + stack 확보(받기·갱신).

  plugins.py catalog
      [stack]        stack 폴더의 plugin. TSV: 절대경로 / name / version / description / skills
      [marketplace]  stack에 없는 Claude 마켓플레이스 plugin, 설치 수 내림차순.
                     TSV: name@marketplace / category / kind / installs / always_on_tokens / description
                     전역 enabledPlugins에서 켜진 것(모든 워커에 이미 로드됨)과 command 출처는 뺀다.
      stderr         warn <절대경로>\t<이유>  받아 둔 plugin 경로가 upstream 갱신으로 사라진 경우
  plugins.py ensure <stack 절대경로 | name@marketplace>...
      stack에 없으면 받고, 있으면 최신으로 갱신한 뒤 주입할 절대경로를 출력한다.
        ok <절대경로>\t<fetched | updated <old>→<new> | up-to-date | no-upstream | update-failed: <이유>>
        fail <id>\t<이유>
      하나라도 fail이면 exit 1. update-failed는 현재 버전 그대로 ok다.

받기 규칙: local 출처는 stack/<name>에 복사, url·git-subdir 출처는 stack/<owner>-<repo>에 기본 branch를 clone(.git 유지).
plugin.json이 없으면 catalog 항목으로 만들어 둔다(stack 탐색·Claude 로드 모두 이 파일을 본다).
갱신 규칙: git clone은 `git pull --ff-only`(로컬 변경·분기 시 실패로 두고 강제하지 않음).
이미 받은 repo에서 없는 하위 경로를 요청하면 먼저 pull한다. 갱신 뒤 경로가 사라졌으면 fail.
마켓플레이스 local 출처 복사본은 마켓플레이스 쪽 version이 다르면 다시 복사. 그 외 복사본은 no-upstream.

환경변수(테스트용): MY_TEAM_STACK_DIR, MY_TEAM_MARKETPLACES_DIR, MY_TEAM_CLAUDE_SETTINGS, MY_TEAM_PLUGIN_STATS
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HOME = Path.home()
STACK = Path(os.environ.get("MY_TEAM_STACK_DIR", HOME / "IdeaProjects" / "my-claude-plugin" / "stack"))
MARKETPLACES = Path(os.environ.get("MY_TEAM_MARKETPLACES_DIR", HOME / ".claude" / "plugins" / "marketplaces"))
SETTINGS = Path(os.environ.get("MY_TEAM_CLAUDE_SETTINGS", HOME / ".claude" / "settings.json"))
# Claude Code가 받아두는 공식 마켓플레이스 통계(설치 수·상주 토큰). 없으면 0으로 둔다.
STATS = Path(os.environ.get("MY_TEAM_PLUGIN_STATS", HOME / ".claude" / "plugins" / "plugin-catalog-cache.json"))
# strict:false 항목은 manifest가 catalog 쪽에 있다. 받을 때 이 키들을 빼고 plugin.json으로 쓴다.
CATALOG_ONLY_KEYS = {"source", "category", "strict", "homepage", "tags", "keywords"}


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def one_line(text, n):
    return " ".join((text or "").split())[:n]


# ── stack ────────────────────────────────────────────────────────────────

def provenance_file(top):
    """이 스크립트가 받은 git repo에서 plugin으로 쓰는 경로 목록 (repo 상대, 줄 단위).
    .git 안에 두어 작업 트리를 건드리지 않는다 — pull과 충돌하지 않는다."""
    return top / ".git" / "info" / "my-team-plugins"


def present(d):
    """받아 둔 plugin 경로가 아직 있는지. upstream이 경로를 지워도 만들어 둔 manifest(ignored)는 남으므로,
    그것만 남은 디렉토리는 없는 것으로 본다.
    ponytail: manifest 하나뿐인 upstream plugin도 없는 것으로 보인다. 그런 plugin이 생기면 git ls-files로 판정할 것."""
    own = d / ".claude-plugin" / "plugin.json"
    return d.is_dir() and any(f != own for f in d.rglob("*") if f.is_file())


def plugin_dirs(top):
    """top 하나에서 plugin 디렉토리를 찾는다.
    - 이 스크립트가 받은 repo: 받은 경로만 (같은 repo의 승인 안 된 형제 plugin·fixture를 잡지 않는다)
    - 사용자가 넣은 디렉토리: marketplace.json의 로컬 source들, 최상위 plugin.json, 없으면 skills/만 있는 최상위"""
    prov = provenance_file(top)
    if prov.is_file():
        return [top / rel for rel in dict.fromkeys(prov.read_text(encoding="utf-8").split()) if present(top / rel)]
    found = []
    mk = read_json(top / ".claude-plugin" / "marketplace.json", {})
    for e in mk.get("plugins", []):
        if isinstance(e.get("source"), str) and (top / e["source"]).is_dir():
            found.append(top / e["source"])
    if (top / ".claude-plugin" / "plugin.json").is_file() or (not found and (top / "skills").is_dir()):
        found.append(top)
    return list({p.resolve(): p for p in found}.values())


def stack_plugins():
    """[(plugin_path, top_dir, name, version, description)]"""
    out = []
    if not STACK.is_dir():
        return out
    for top in sorted(p for p in STACK.iterdir() if p.is_dir() and not p.name.startswith(".")):
        for path in plugin_dirs(top):
            pj = read_json(path / ".claude-plugin" / "plugin.json", {})
            out.append((path.resolve(), top, pj.get("name") or path.name, pj.get("version") or "-", pj.get("description") or ""))
    return out


def skill_names(path, limit=8):
    names = sorted(p.parent.name for p in (path / "skills").glob("*/SKILL.md"))
    return ",".join(names[:limit]) + (f",+{len(names) - limit}" if len(names) > limit else "")


# ── marketplace ──────────────────────────────────────────────────────────

def load_catalog():
    """{name@marketplace: (marketplace_dir, entry)}"""
    out = {}
    for f in sorted(MARKETPLACES.glob("*/.claude-plugin/marketplace.json")):
        data = read_json(f)
        if not data:
            continue
        mdir = f.parent.parent
        for e in data.get("plugins", []):
            out[f"{e['name']}@{data.get('name', mdir.name)}"] = (mdir, e)
    return out


def kind_of(entry):
    src = entry.get("source")
    return "local" if isinstance(src, str) else (src or {}).get("source", "?")


def stats():
    plugins = (read_json(STATS, {}).get("catalog") or {}).get("plugins") or {}
    out = {}
    for pid, v in plugins.items():
        always_on = max((t.get("always_on") or 0 for t in (v.get("tokens") or {}).values()), default=0)
        out[pid] = (v.get("unique_installs") or 0, always_on)
    return out


def marketplace_version(mdir, entry):
    if kind_of(entry) != "local":
        return None
    pj = read_json(mdir / entry["source"] / ".claude-plugin" / "plugin.json", {})
    return pj.get("version") or entry.get("version")


# ── commands ─────────────────────────────────────────────────────────────

def cmd_catalog():
    stack = stack_plugins()
    print("[stack]")
    for path, _, name, version, desc in stack:
        print(f"{path}\t{name}\t{version}\t{one_line(desc, 160)}\t{skill_names(path)}")
    for prov in sorted(STACK.glob("*/.git/info/my-team-plugins")):
        top = prov.parents[2]
        for rel in dict.fromkeys(prov.read_text(encoding="utf-8").split()):
            if not present(top / rel):
                print(f"warn {top / rel}\t받아 둔 plugin 경로가 없음 (upstream에서 삭제·이동됐을 수 있음)", file=sys.stderr)
    in_stack = {name for _, _, name, _, _ in stack}
    enabled = {k for k, v in (read_json(SETTINGS, {}).get("enabledPlugins") or {}).items() if v}
    st = stats()
    rows = []
    for pid, (_, e) in load_catalog().items():
        kind = kind_of(e)
        if pid in enabled or e["name"] in in_stack or kind not in ("local", "git-subdir", "url"):
            continue
        installs, always_on = st.get(pid, (0, 0))
        rows.append((-installs, pid, f"{pid}\t{e.get('category') or '-'}\t{kind}\t{installs}\t{always_on}\t{one_line(e.get('description'), 110)}"))
    print("[marketplace]")
    for _, _, line in sorted(rows):
        print(line)
    return 0


# 에이전트의 Bash 호출 안에서 돈다: 자격증명·host key prompt가 뜨면 멈추므로 막고, 시간도 제한한다.
def ssh_command():
    """사용자 ssh 설정(GIT_SSH_COMMAND, core.sshCommand)을 유지하고 BatchMode만 덧붙인다."""
    base = os.environ.get("GIT_SSH_COMMAND") or subprocess.run(
        ["git", "config", "--get", "core.sshCommand"], capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout.strip()
    return (base or "ssh") + " -oBatchMode=yes"


GIT_ENV = {**os.environ, "GIT_TERMINAL_PROMPT": "0", "GIT_SSH_COMMAND": ssh_command()}
GIT_TIMEOUT = 120


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True,
                          stdin=subprocess.DEVNULL, env=GIT_ENV, timeout=GIT_TIMEOUT).stdout.strip()


def err_text(ex):
    if isinstance(ex, subprocess.TimeoutExpired):
        return f"git {GIT_TIMEOUT}초 timeout"
    if isinstance(ex, subprocess.CalledProcessError):
        return f"git 실패: {one_line(ex.stderr, 160)}"
    return f"{type(ex).__name__}: {one_line(str(ex), 160)}"


def norm_url(url):
    return url.strip().rstrip("/").removesuffix(".git")


def clone_dir(url):
    """https://github.com/<owner>/<repo>(.git) · git@github.com:<owner>/<repo>.git → stack/<owner>-<repo>.
    repo 이름만 쓰면 서로 다른 owner의 `skills` 같은 repo가 같은 디렉토리로 겹친다."""
    return STACK / "-".join(re.split(r"[/:]", norm_url(url))[-2:])


def write_manifest(path, entry):
    """plugin.json이 없으면 catalog 항목으로 만든다 (strict:false, 또는 manifest 없는 하위 경로).
    있어야 Claude가 이름·설정을 읽고 stack 탐색에도 잡힌다."""
    manifest = path / ".claude-plugin" / "plugin.json"
    if manifest.exists():
        return False
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps({k: v for k, v in entry.items() if k not in CATALOG_ONLY_KEYS},
                                   ensure_ascii=False, indent=2), encoding="utf-8")
    return True


def append_line(file, line):
    existing = file.read_text(encoding="utf-8").split("\n") if file.exists() else []
    if line not in existing:
        with file.open("a", encoding="utf-8") as f:
            f.write(line + "\n")


def copy_local(src, entry):
    def build(dest):
        shutil.copytree(src, dest)
        write_manifest(dest, entry)
    return build


def update(path, top, name, version, catalog):
    try:
        if (top / ".git").exists():
            old = git("-C", str(top), "rev-parse", "--short", "HEAD")
            git("-C", str(top), "pull", "--ff-only", "-q")
            new = git("-C", str(top), "rev-parse", "--short", "HEAD")
            return "up-to-date" if old == new else f"updated {old}→{new}"
        for mdir, e in catalog.values():
            if e["name"] != name or kind_of(e) != "local":
                continue
            latest = marketplace_version(mdir, e)
            if not latest or latest == version:
                return "up-to-date"
            replace_dir(path, copy_local(mdir / e["source"], e))
            return f"updated {version}→{latest}"
        return "no-upstream"
    except (subprocess.SubprocessError, OSError) as ex:
        return f"update-failed: {err_text(ex)}"


def replace_dir(path, build):
    """build(dest)로 새 내용을 만든 뒤 path와 맞바꾼다. 실패하면 기존 path는 그대로다."""
    with tempfile.TemporaryDirectory(dir=STACK) as tmp:
        staged, old = Path(tmp) / "new", Path(tmp) / "old"
        build(staged)
        if path.exists():
            path.rename(old)
        staged.rename(path)


def fetch(pid, catalog):
    """stack에 새로 받는다. 반환: (plugin_path, None) 또는 (None, 실패 이유)"""
    mdir, e = catalog[pid]
    kind = kind_of(e)
    STACK.mkdir(parents=True, exist_ok=True)
    try:
        if kind == "local":
            src = (mdir / e["source"]).resolve()
            if not src.is_dir():
                return None, f"로컬 출처 디렉토리 없음: {src}"
            path = STACK / e["name"]
            if path.exists():
                return None, f"stack에 같은 이름의 디렉토리가 있음: {path}"
            replace_dir(path, copy_local(src, e))
        elif kind in ("url", "git-subdir"):
            s = e["source"]
            top = clone_dir(s["url"])
            existed = (top / ".git").exists()
            if existed:
                origin = git("-C", str(top), "remote", "get-url", "origin")
                if norm_url(origin) != norm_url(s["url"]):
                    return None, f"{top}는 다른 repo의 clone이다 (origin {origin}, 요청 {s['url']})"
            elif top.exists():
                return None, f"stack에 같은 이름의 git이 아닌 디렉토리가 있음: {top}"
            else:
                branch = ["--branch", s["ref"]] if s.get("ref") else []
                replace_dir(top, lambda dest: git("clone", "-q", "--depth", "1", *branch, s["url"], str(dest)))
            path = top / s["path"] if kind == "git-subdir" else top
            if existed and not present(path):
                # clone 이후 upstream에 생긴 하위 경로일 수 있다
                git("-C", str(top), "pull", "--ff-only", "-q")
            if not present(path):
                return None, f"repo에 경로 없음: {s.get('path')}"
            rel = path.relative_to(top).as_posix() if path != top else "."
            prov = provenance_file(top)
            if existed and not prov.exists():
                # 사용자가 직접 clone해 둔 repo에 처음 받는 경우: 지금 보이던 plugin들을 먼저 기록해 둔다
                # (기록이 생기면 탐색이 기록된 경로만 보므로, 안 그러면 기존 plugin이 사라진다)
                for p in plugin_dirs(top):
                    append_line(prov, p.relative_to(top).as_posix() if p != top else ".")
            if write_manifest(path, e):
                # 만든 manifest는 untracked다. upstream이 같은 파일을 추가하면 pull이 거부되므로 ignore해 둔다
                # (git은 ignored 파일을 merge 때 덮어쓴다 → upstream manifest로 바뀐다)
                manifest_rel = ".claude-plugin/plugin.json" if rel == "." else f"{rel}/.claude-plugin/plugin.json"
                append_line(top / ".git" / "info" / "exclude", "/" + manifest_rel)
            append_line(prov, rel)
        else:
            return None, f"지원하지 않는 출처: {kind}"
    except (subprocess.SubprocessError, OSError) as ex:
        return None, err_text(ex)
    return path.resolve(), None


def ensure_one(target, catalog):
    stack = stack_plugins()
    by_path = {str(row[0]): row for row in stack}
    by_name = {}
    for row in stack:
        by_name.setdefault(row[2], []).append(row)
    as_path = str(Path(target).expanduser().resolve()) if target.startswith(("/", "~")) else None
    if as_path in by_path:
        row = by_path[as_path]
    elif target in catalog and catalog[target][1]["name"] in by_name:
        rows = by_name[catalog[target][1]["name"]]
        if len(rows) > 1:
            return f"fail {target}\tstack에 같은 이름의 plugin이 여럿이다. 경로로 지정할 것: {', '.join(str(r[0]) for r in rows)}"
        row = rows[0]
    elif target in catalog:
        path, err = fetch(target, catalog)
        return f"ok {path}\tfetched" if path else f"fail {target}\t{err}"
    else:
        return f"fail {target}\tstack 경로도 마켓플레이스 id도 아님"
    path, top, name, version, _ = row
    state = update(path, top, name, version, catalog)
    if provenance_file(top).is_file() and not present(path):
        return f"fail {target}\t갱신 뒤 경로가 없음 (upstream에서 삭제·이동됨): {path}"
    return f"ok {path}\t{state}"


def cmd_ensure(targets):
    catalog = load_catalog()
    failed = False
    for t in targets:
        line = ensure_one(t, catalog)
        print(line, flush=True)  # 줄마다 바로 낸다: 뒤 target에서 죽어도 앞 결과는 남는다
        failed |= line.startswith("fail")
    return 1 if failed else 0


def main(argv):
    if argv[:1] == ["catalog"]:
        return cmd_catalog()
    if argv[:1] == ["ensure"] and len(argv) > 1:
        return cmd_ensure(argv[1:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
