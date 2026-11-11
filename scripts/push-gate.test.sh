#!/bin/sh
# Tests for push-gate.sh through the hook install-pre-push.sh writes (T63f): a scratch repository, a local
# bare remote, a scratch my-team board in a temporary state base. Nothing here touches this repository's
# hooks or config, or any running team.
#   sh scripts/push-gate.test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
my_team_dir=$(cd "$here/../tools/my-team" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
check() {  # check <name> <expected exit> <actual exit>
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected exit $2, got $3"; sed 's/^/     /' "$work/out"; failed=1; fi
}
contains() {  # contains <name> <file> <text>
    if grep -qF -- "$3" "$2"; then echo "ok   $1"; else echo "FAIL $1: no '$3' in:"; sed 's/^/     /' "$2"; failed=1; fi
}
absent() {  # absent <name> <file> <text>
    if grep -qF -- "$3" "$2"; then echo "FAIL $1: '$3' in:"; sed 's/^/     /' "$2"; failed=1; else echo "ok   $1"; fi
}
on_remote() { git --git-dir="$work/remote.git" cat-file -e "$1" 2>/dev/null; }

# not a worker of any team here, and this state base only
unset MY_TEAM_WORKER OMC_TEAM_WORKER MY_TEAM_STATE_ROOT TMUX TMUX_PANE
export MY_TEAM_STATE_ROOT_BASE="$work/state"
printf '%s\n' 'internal\.example\.com' > "$work/patterns"
export PUBLIC_SCAN_PATTERNS="$work/patterns"
mkdir -p "$work/bin"
printf '#!/bin/sh\nexec node "%s/bin/my-team" "$@"\n' "$my_team_dir" > "$work/bin/my-team"
chmod +x "$work/bin/my-team"
PATH="$work/bin:$PATH"

git init -q --bare "$work/remote.git"
git init -q -b main "$work/repo"
cd "$work/repo"
git config user.name t; git config user.email t@t
git remote add origin "$work/remote.git"
commit() { echo "$1" > "$1.txt"; git add -A; git commit -q -m "$2"; git rev-parse HEAD; }
base=$(commit base "base commit")
git push -q origin main
sh "$here/install-pre-push.sh" > "$work/out" 2>&1; check "install" 0 $?
contains "the hook has its own copy of the gate, naming its commit" "$(git rev-parse --git-path hooks/push-gate.sh)" "# push-gate from "

# a board team "gt" whose worker core works in this repository; approve <commit> <task id> approves it there
mkdir -p "$work/state/gt"
printf '{"team_name":"gt","state_root":"%s","session_name":"none:0","board":{"store":"sqlite"},"workers":[{"name":"pm","role":"orchestrator","agent_type":"claude","pane_id":"%%999","cwd":"%s"},{"name":"core","role":"worker","agent_type":"claude","pane_id":"%%998","cwd":"%s"},{"name":"rv","role":"worker","agent_type":"claude","pane_id":"%%997","cwd":"%s"}]}' \
    "$work/state/gt" "$work/repo" "$work/repo" "$work/repo" > "$work/state/gt/manifest.json"
approve() {
    node --no-warnings --input-type=module -e '
const [dir, root, repo, commit, base, id] = process.argv.slice(1);
const { createBoard } = await import(`${dir}/src/board/core/service.js`);
const { createSqliteStore } = await import(`${dir}/src/board/store/sqlite/index.js`);
const { gitRange } = await import(`${dir}/src/board/git.js`);
const store = createSqliteStore(`${root}/board.db`);
await store.open();
const roster = [{ name: "pm", role: "orchestrator" }, { name: "core", role: "worker" }, { name: "rv", role: "worker" }];
const as = (actor) => createBoard({ store, roster: () => roster, actor, now: () => new Date().toISOString(), git: gitRange, notify: async () => [] });
await as("pm").add({ id, title: id, assignee: "core", reviewer: "rv", base });
await as("core").take({ id });
await as("core").land({ id, repo, commit, check: { cmd: "c", result: "r" }, focus: ["f"], closes: [], report: "/r" });
await as("rv").verdict({ landing: `${id}#1`, verdict: "approve", verified_commit: commit, report: "/R", rerun: { cmd: "c", result: "r" }, findings: [] });
await store.close();
' "$my_team_dir" "$work/state/gt" "$(git rev-parse --show-toplevel)" "$1" "$2" "$3"
}
# (board-land names the repository by its top level, as the gate does; a mktemp path may be a symlink of it)

# (e) no my-team.board: the gate is off, as before
off=$(commit off "an unreviewed commit, gate off")
git push -q origin main > "$work/out" 2>&1; check "(e) no board configured: the push goes" 0 $?

# (e) board configured, a commit with no review: refused, kept off the remote, named, and told how to go on
git config my-team.board gt
u1=$(commit u1 "docs: a fix nobody reviewed")
git push -q origin main > "$work/out" 2>&1; check "(e) an unreviewed commit is refused" 1 $?
if on_remote "$u1"; then echo "FAIL (e) the unreviewed commit reached the remote"; failed=1; else echo "ok   (e) the unreviewed commit is not on the remote"; fi
contains "(e) the refusal names the commit and its subject" "$work/out" "$(git rev-parse --short=7 "$u1") docs: a fix nobody reviewed"
contains "(e) the refusal says how: a review" "$work/out" "approve verdict"
contains "(e) the refusal says how: the baseline" "$work/out" "git config my-team.baseline <commit>"
contains "(e) the refusal says how: --no-verify" "$work/out" "git push --no-verify"

# (e) once it is approved on the board, it goes
approve "$u1" "$off" T1 > "$work/out" 2>&1; check "approve on the board" 0 $?
git push -q origin main > "$work/out" 2>&1; check "(e) every commit reviewed: the push goes" 0 $?

# (d) the baseline: commits within it pass without a review
b1=$(commit b1 "the user's own commit")
git push -q origin main > "$work/out" 2>&1; check "(d) outside the baseline: refused" 1 $?
git config my-team.baseline "$b1"
git push -q origin main > "$work/out" 2>&1; check "(d) within the baseline: the push goes" 0 $?
git config --unset my-team.baseline

# a new branch: every commit no ref of the remote has is checked
git checkout -q -b topic
t1=$(commit t1 "topic work")
git push -q origin topic > "$work/out" 2>&1; check "a new branch with an unreviewed commit is refused" 1 $?
contains "  and names it" "$work/out" "$(git rev-parse --short=7 "$t1") topic work"
git checkout -q main

# (e) cannot judge: a team that is not there, or no my-team on PATH: refused
git config my-team.board nobody
git push -q origin topic > "$work/out" 2>&1; check "(e) the board's team is not there: refused" 1 $?
contains "  says it cannot judge" "$work/out" "cannot judge"
git config my-team.board gt
# PATH without any folder holding a my-team, not even an installed one
no_my_team=$(echo "$PATH" | tr ':' '\n' | while read -r d; do [ -n "$d" ] && [ ! -x "$d/my-team" ] && printf '%s:' "$d"; done)
PATH="${no_my_team%:}" git push -q origin topic > "$work/out" 2>&1; check "(e) no my-team on PATH: refused" 1 $?
contains "  says my-team is missing" "$work/out" "my-team (or node) is not on PATH"

# (f) the identifier scan refuses first: the gate does not run
git checkout -q main
s1=$(commit s1 "see internal.example.com")
git push -q origin main > "$work/out" 2>&1; check "(f) a commit with an identifier is refused" 1 $?
contains "  by public-scan" "$work/out" "public-scan refused"
absent "  before the gate ran" "$work/out" "push-gate:"

[ "$failed" = 0 ] && echo "all passed" || { echo "some failed"; exit 1; }
