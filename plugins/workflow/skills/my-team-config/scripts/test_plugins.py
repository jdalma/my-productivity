"""python3 -I test_plugins.py — catalog 구성, ensure의 받기·갱신·실패 경로 확인 (네트워크 없음, 로컬 git repo 사용)."""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def sh(cwd, *args):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def commit(repo, msg):
    sh(repo, "git", "add", ".")
    sh(repo, "git", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", msg)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def new_repo(path, files):
    for rel, text in files.items():
        write(path / rel, text)
    sh(path.parent, "git", "init", "-q", str(path))
    commit(path, "1")
    return path


with tempfile.TemporaryDirectory() as d:
    d = Path(d)
    os.environ.update(MY_TEAM_STACK_DIR=str(d / "stack"), MY_TEAM_MARKETPLACES_DIR=str(d / "mkts"),
                      MY_TEAM_CLAUDE_SETTINGS=str(d / "settings.json"), MY_TEAM_PLUGIN_STATS=str(d / "stats.json"))
    sys.path.insert(0, str(Path(__file__).parent))
    import plugins

    # 원격 역할의 git repo들
    remote = new_repo(d / "ownerR" / "remote", {"skills/x/SKILL.md": "x",
                                                ".claude-plugin/plugin.json": json.dumps({"name": "rem", "description": "remote one"})})
    skills_a = new_repo(d / "ownerA" / "skills", {"tavily/skills/t/SKILL.md": "t",        # 같은 basename `skills`
        "other/.claude-plugin/plugin.json": json.dumps({"name": "other"}),                   # 승인 안 된 형제 plugin
        "tests/fixtures/bad/.claude-plugin/plugin.json": json.dumps({"name": "loc"})})       # stack plugin과 이름이 같은 fixture
    skills_b = new_repo(d / "ownerB" / "skills", {"skills/cf/SKILL.md": "c"})
    mono = new_repo(d / "ownerM" / "mono", {
        "plugins/p1/.claude-plugin/plugin.json": json.dumps({"name": "p1", "description": "has manifest"}),
        "plugins/p2/skills/s/SKILL.md": "s"})                                              # manifest 없는 하위 경로

    # stack: git clone 1개, 복사본 2개(마켓플레이스 출처 / 자체 파생본)
    stack = d / "stack"
    stack.mkdir()
    sh(stack, "git", "clone", "-q", str(remote), "cloned")
    write(stack / "copied" / ".claude-plugin" / "plugin.json", json.dumps({"name": "loc", "version": "1.0.0", "description": "old copy"}))
    write(stack / "lite" / ".claude-plugin" / "plugin.json", json.dumps({"name": "big", "version": "0-lite", "description": "subset"}))
    write(stack / "lite" / "skills" / "only" / "SKILL.md", "o")
    for n in ("dup1", "dup2"):  # 사용자가 넣은, 이름이 같은 plugin 두 개
        write(stack / n / ".claude-plugin" / "plugin.json", json.dumps({"name": "dupname"}))

    m = d / "mkts" / "m1"
    write(m / "plugins" / "loc" / ".claude-plugin" / "plugin.json", json.dumps({"name": "loc", "version": "2.0.0", "description": "new copy"}))
    write(m / "plugins" / "lsp" / "README.md", "r")
    write(m / "plugins" / "fresh" / "commands" / "c.md", "c")
    entries = [
        {"name": "loc", "source": "./plugins/loc"},
        {"name": "lsp", "description": "lsp", "version": "1.0", "source": "./plugins/lsp", "strict": False, "lspServers": {"ts": {"command": "tsls"}}},
        {"name": "fresh", "description": "fresh local", "category": "development", "source": "./plugins/fresh"},
        {"name": "rem2", "description": "remote", "source": {"source": "url", "url": str(remote), "sha": "ignored"}},
        {"name": "tavily", "description": "a", "source": {"source": "git-subdir", "url": str(skills_a), "path": "tavily"}},
        {"name": "cf", "description": "b", "source": {"source": "url", "url": str(skills_b) + "/"}},
        {"name": "p2", "description": "no manifest", "source": {"source": "git-subdir", "url": str(mono), "path": "plugins/p2"}},
        {"name": "big", "description": "original of lite", "source": {"source": "url", "url": "https://example.invalid/big.git"}},
        {"name": "on", "description": "enabled globally", "source": "./plugins/fresh"},
        {"name": "cmd", "source": {"source": "command", "command": "true"}},
        {"name": "gone", "source": "./plugins/nope"},
        {"name": "dupname", "source": "./plugins/fresh"},
    ]
    write(m / ".claude-plugin" / "marketplace.json", json.dumps({"name": "m1", "plugins": entries}))
    write(d / "settings.json", json.dumps({"enabledPlugins": {"on@m1": True}}))
    write(d / "stats.json", json.dumps({"catalog": {"plugins": {
        "lsp@m1": {"unique_installs": 50, "tokens": {"a": {"always_on": 5}}},
        "fresh@m1": {"unique_installs": 900, "tokens": {"a": {"always_on": 70}, "b": {"always_on": 90}}}}}}))

    def catalog_out():
        out = subprocess.run([sys.executable, "-I", plugins.__file__, "catalog"], capture_output=True, text=True, env=os.environ).stdout
        s, mk = out.split("[marketplace]\n")
        return [l.split("\t") for l in s.splitlines()[1:]], [l.split("\t") for l in mk.splitlines()]

    stack_rows, market = catalog_out()
    assert [r[1] for r in stack_rows] == ["rem", "loc", "dupname", "dupname", "big"], stack_rows
    assert stack_rows[4][4] == "only", stack_rows[4]
    # 설치 수 순, stack에 같은 이름 있는 것(loc·big)·전역 켜짐(on)·command(cmd) 제외
    assert [r[0] for r in market] == ["fresh@m1", "lsp@m1", "cf@m1", "gone@m1", "p2@m1", "rem2@m1", "tavily@m1"], market
    assert market[0][3:5] == ["900", "90"], market[0]

    cat = plugins.load_catalog()
    ok = lambda p, state: f"ok {p.resolve()}\t{state}"

    # 받기: local 출처, strict:false manifest 생성, url 출처 clone(.git 유지)
    assert plugins.ensure_one("fresh@m1", cat) == ok(stack / "fresh", "fetched")
    plugins.ensure_one("lsp@m1", cat)
    assert json.loads((stack / "lsp" / ".claude-plugin" / "plugin.json").read_text()) == \
        {"name": "lsp", "description": "lsp", "version": "1.0", "lspServers": {"ts": {"command": "tsls"}}}
    r = plugins.ensure_one("rem2@m1", cat)
    assert r == ok(stack / "ownerR-remote", "fetched") and (stack / "ownerR-remote" / ".git").exists(), r

    # 같은 basename(`skills`)의 다른 owner repo는 다른 디렉토리로 받는다
    assert plugins.ensure_one("tavily@m1", cat) == ok(stack / "ownerA-skills" / "tavily", "fetched")
    assert plugins.ensure_one("cf@m1", cat) == ok(stack / "ownerB-skills", "fetched")
    assert sh(stack / "ownerB-skills", "git", "remote", "get-url", "origin") == str(skills_b) + "/"
    # 받을 디렉토리에 다른 repo의 clone이 이미 있으면 그 코드를 쓰지 않고 실패한다
    sh(stack, "git", "clone", "-q", str(skills_a), "ownerM-mono")
    r = plugins.ensure_one("p2@m1", cat)
    assert r.startswith("fail p2@m1\t") and "다른 repo" in r, r
    sh(d, "rm", "-rf", str(stack / "ownerM-mono"))

    # 받은 repo에서는 받은 경로만 plugin이다: 같은 repo의 형제 plugin·fixture는 잡히지 않는다
    names = [r[1] for r in catalog_out()[0]]
    assert "other" not in names and names.count("loc") == 1, names
    # stack에 같은 이름이 여럿이면 id로는 고르지 않는다
    r = plugins.ensure_one("dupname@m1", cat)
    assert r.startswith("fail dupname@m1\t") and "dup1" in r and "dup2" in r, r

    # git-subdir 하위 경로: manifest를 만들어 stack 탐색에 잡히고, 다음부터는 받지 않고 갱신한다
    assert plugins.ensure_one("p2@m1", cat) == ok(stack / "ownerM-mono" / "plugins" / "p2", "fetched")
    stack_rows, market = catalog_out()
    assert {"tavily", "cf", "p2"} <= {r[1] for r in stack_rows} and "p2@m1" not in [r[0] for r in market], (stack_rows, market)
    write(mono / "plugins" / "p2" / "skills" / "s2" / "SKILL.md", "s2"); commit(mono, "2")
    r = plugins.ensure_one("p2@m1", cat)
    assert "\tupdated " in r and (stack / "ownerM-mono" / "plugins" / "p2" / "skills" / "s2").exists(), r
    # 경로로 지정할 때 끝의 / 같은 표기 차이는 무시한다
    assert plugins.ensure_one(str(stack / "ownerM-mono" / "plugins" / "p2") + "/", cat).endswith("\tup-to-date")

    # 만들어 둔 manifest를 upstream이 같은 경로에 추가해도 pull이 막히지 않고 upstream 것으로 바뀐다
    write(mono / "plugins" / "p2" / ".claude-plugin" / "plugin.json", json.dumps({"name": "p2", "version": "9"})); commit(mono, "3")
    r = plugins.ensure_one("p2@m1", cat)
    assert "\tupdated " in r, r
    assert json.loads((stack / "ownerM-mono" / "plugins" / "p2" / ".claude-plugin" / "plugin.json").read_text())["version"] == "9"

    # 이미 받은 repo에서 clone 이후 upstream에 생긴 하위 경로를 요청하면 pull한 뒤 받는다
    write(mono / "plugins" / "p3" / "skills" / "s" / "SKILL.md", "s3"); commit(mono, "4")
    entries.append({"name": "p3", "description": "added later", "source": {"source": "git-subdir", "url": str(mono), "path": "plugins/p3"}})
    write(m / ".claude-plugin" / "marketplace.json", json.dumps({"name": "m1", "plugins": entries}))
    cat = plugins.load_catalog()
    assert plugins.ensure_one("p3@m1", cat) == ok(stack / "ownerM-mono" / "plugins" / "p3", "fetched")
    # upstream이 받은 경로를 지우면: 갱신은 fail, catalog는 warn을 낸다
    sh(mono, "git", "rm", "-rqf", "plugins/p3"); commit(mono, "5")
    p3 = stack / "ownerM-mono" / "plugins" / "p3"
    r = plugins.ensure_one(str(p3), cat)
    assert r.startswith(f"fail {p3}\t") and "삭제" in r, r
    err = subprocess.run([sys.executable, "-I", plugins.__file__, "catalog"], capture_output=True, text=True, env=os.environ).stderr
    assert err.startswith(f"warn {p3}\t"), err
    # id로 다시 요청해도 manifest만 남은 껍데기를 주입하지 않는다
    r = plugins.ensure_one("p3@m1", cat)
    assert r.startswith("fail p3@m1\t") and "경로 없음" in r, r

    # 갱신: git clone은 pull, 마켓플레이스 복사본은 version이 다르면 재복사, 파생본은 no-upstream
    write(remote / "skills" / "y" / "SKILL.md", "y"); commit(remote, "2")
    r = plugins.ensure_one(str(stack / "cloned"), cat)
    assert "\tupdated " in r and (stack / "cloned" / "skills" / "y").exists(), r
    assert plugins.ensure_one(str(stack / "cloned"), cat).endswith("\tup-to-date")
    assert plugins.ensure_one("loc@m1", cat) == ok(stack / "copied", "updated 1.0.0→2.0.0")
    assert json.loads((stack / "copied" / ".claude-plugin" / "plugin.json").read_text())["version"] == "2.0.0"
    assert plugins.ensure_one("big@m1", cat).endswith("\tno-upstream")  # 이름이 같은 stack 파생본을 쓰고, 원본을 받지 않는다

    # strict:false 복사본을 재복사해도 manifest가 남는다
    entries[1]["version"] = "2.0"
    write(m / ".claude-plugin" / "marketplace.json", json.dumps({"name": "m1", "plugins": entries}))
    assert plugins.ensure_one("lsp@m1", plugins.load_catalog()) == ok(stack / "lsp", "updated 1.0→2.0")
    assert json.loads((stack / "lsp" / ".claude-plugin" / "plugin.json").read_text())["version"] == "2.0"

    # 갱신 실패는 현재 버전으로 ok: 로컬 변경과 충돌하는 upstream 변경
    write(stack / "cloned" / "skills" / "x" / "SKILL.md", "local edit")
    write(remote / "skills" / "x" / "SKILL.md", "upstream edit"); commit(remote, "3")
    r = plugins.ensure_one(str(stack / "cloned"), cat)
    assert r.startswith(f"ok {(stack / 'cloned').resolve()}\tupdate-failed: "), r

    # 실패: 없는 출처, 모르는 id. 실패 잔여물이 stack에 남지 않는다
    before = sorted(p.name for p in stack.iterdir())
    assert plugins.ensure_one("gone@m1", cat).startswith("fail gone@m1\t")
    assert plugins.ensure_one("nobody", cat).startswith("fail nobody\t")
    assert sorted(p.name for p in stack.iterdir()) == before, list(stack.iterdir())

    # git은 터미널 prompt를 띄우지 않는다 (에이전트 호출이 멈추지 않게)
    assert plugins.GIT_ENV["GIT_TERMINAL_PROMPT"] == "0" and "BatchMode=yes" in plugins.GIT_ENV["GIT_SSH_COMMAND"]

print("ok")
