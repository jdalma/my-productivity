#!/bin/sh
# The board gate of the pre-push hook (T63f): every commit going out must have an approved review on the
# my-team board, or be an ancestor of the repository's baseline. Off unless the repository names a board team:
#   git config my-team.board <team>          turns the gate on (pm or the user)
#   git config my-team.baseline <commit>     its ancestors count as reviewed (pm or the user)
#   sh push-gate.sh <remote name> <local sha> <remote sha>     (once per ref, from the hook)
# When it cannot judge (no my-team, no board, an error), it refuses: a gate that passes on failure is no gate.
set -u
board=$(git config --get my-team.board) || exit 0
baseline=$(git config --get my-team.baseline || true)
remote=$1 local_sha=$2 remote_sha=$3

if ! command -v my-team >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
    echo "push-gate: my-team (or node) is not on PATH, so whether these commits were reviewed on board '$board' cannot be told; refusing." >&2
    echo "  Install my-team, or skip the pre-push checks once with: git push --no-verify" >&2
    exit 1
fi

input=$(node -e '
const [team, remote, local, remoteSha, baseline, repo] = process.argv.slice(1);
const range = /[^0]/.test(remoteSha) ? { upstream: remoteSha } : { remote };
console.log(JSON.stringify({ team_name: team, repo, commit: local, ...range, ...(baseline ? { baseline } : {}) }));
' "$board" "$remote" "$local_sha" "$remote_sha" "$baseline" "$(git rev-parse --show-toplevel)")
out=$(my-team api board-pushable --input "$input" --json 2>/dev/null)

printf '%s' "$out" | node -e '
const [board] = process.argv.slice(1);
let raw = "";
process.stdin.on("data", (d) => { raw += d; }).on("end", () => {
    let r;
    try { r = JSON.parse(raw); } catch { r = { ok: false, code: "error", message: "no answer from my-team api board-pushable" }; }
    if (r.ok === true) process.exit(0);
    const say = (s) => process.stderr.write(s + "\n");
    if (!Array.isArray(r.uncovered)) {
        say(`push-gate: cannot judge this push on board ${board} (${r.code}: ${r.message}); refusing.`);
        say("  Fix that, or skip the pre-push checks once with: git push --no-verify");
        process.exit(1);
    }
    say(`push-gate: these commits have no approved review on board ${board}:`);
    for (const u of r.uncovered) say(`  ${u.short} ${u.subject}`);
    say("They can go out when one of these holds:");
    say("  - each is in a landing a reviewer approved on the board (board-land, then an approve verdict);");
    say("  - they are your own commits outside the board: move the baseline to the last of them,");
    say("      git config my-team.baseline <commit>   (pm or the user)");
    say("  - or skip the pre-push checks once (the identifier scan too): git push --no-verify");
    process.exit(1);
});
' "$board"
