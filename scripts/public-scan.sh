#!/bin/sh
# Checks commits for private identifiers before they reach this public repository (T61):
#   scripts/public-scan.sh <rev-list arguments>      e.g. origin/feat/x..HEAD, or <sha> --not --remotes=origin
# Looks at each commit's added lines (with file and line), its whole message (subject, body, trailers) and
# the paths it adds or renames to. The patterns come from outside the repository, since the list itself is
# private: $PUBLIC_SCAN_PATTERNS, default ~/.config/my-claude-plugin/private-patterns.txt, one extended
# regular expression per line, `#` comments, case ignored. Hits are printed without the pattern.
# Exit 0: nothing found. 1: something found. 2: could not check (no pattern file, no pattern, bad pattern,
# bad range) — not checking is never passing.
# Not seen: binary files, commits outside the range (already pushed), text produced at build time.
set -u

[ $# -gt 0 ] || { echo "usage: public-scan.sh <rev-list arguments>" >&2; exit 2; }
file=${PUBLIC_SCAN_PATTERNS:-$HOME/.config/my-claude-plugin/private-patterns.txt}
[ -f "$file" ] || { echo "public-scan: no pattern file at $file" >&2; exit 2; }

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$file" > "$tmp/patterns"
[ -s "$tmp/patterns" ] || { echo "public-scan: no pattern in $file" >&2; exit 2; }
# a pattern grep cannot compile would make every search "fail" quietly: check them once
printf '' | grep -i -E -f "$tmp/patterns" >/dev/null 2>"$tmp/err"
[ $? -le 1 ] || { echo "public-scan: a pattern in $file is not a valid regular expression" >&2; exit 2; }

git rev-list --reverse "$@" > "$tmp/commits" 2>"$tmp/err" || { echo "public-scan: bad range: $(cat "$tmp/err")" >&2; exit 2; }

hits=0 commits=0 lines=0
# `grep -n` over $1, each hit printed as "<prefix>: <line>" where prefix comes from line N of $2 (or $2 itself)
search() {
    grep -n -i -E -f "$tmp/patterns" "$1" > "$tmp/found"
    [ -s "$tmp/found" ] || return 0
    if [ -f "$2" ]; then
        awk -F: 'NR == FNR { where[NR] = $0; next } { n = $1; sub(/^[0-9]+:/, ""); print where[n] ": " $0 }' "$2" "$tmp/found"
    else
        sed "s|^\([0-9]*\):|$2:\1: |" "$tmp/found"
    fi
    hits=$((hits + $(wc -l < "$tmp/found")))
}

while read -r sha; do
    commits=$((commits + 1))
    short=$(git rev-parse --short "$sha")

    git log -1 --format=%B "$sha" > "$tmp/message"
    lines=$((lines + $(wc -l < "$tmp/message")))
    search "$tmp/message" "$short message"

    # paths added or renamed to (a rename's new name is the last field)
    git diff-tree -r --root --no-commit-id --name-status -M --diff-filter=AR --diff-merges=first-parent "$sha" \
        | awk -F'\t' '{ print $NF }' > "$tmp/paths"
    lines=$((lines + $(wc -l < "$tmp/paths")))
    awk -v c="$short" '{ print c " path" }' "$tmp/paths" > "$tmp/where"
    search "$tmp/paths" "$tmp/where"

    # added lines, each with its file and its line number in the new version
    git diff-tree -p -U0 --root --no-commit-id --no-color --no-ext-diff -M --diff-merges=first-parent "$sha" | awk -v c="$short" -v out="$tmp/added" -v where="$tmp/where" '
        /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); next }
        /^@@ / { split($3, a, ","); n = substr(a[1], 2) + 0; next }
        /^\+/ { print substr($0, 2) > out; print c " " f ":" n > where; n++ }
    '
    : >> "$tmp/added"
    lines=$((lines + $(wc -l < "$tmp/added")))
    search "$tmp/added" "$tmp/where"
    rm -f "$tmp/added" "$tmp/where"
done < "$tmp/commits"

if [ "$hits" -gt 0 ]; then
    echo "public-scan: $hits hit(s) in $commits commit(s). Remove them before pushing." >&2
    exit 1
fi
echo "public-scan: clean — $commits commit(s), $lines line(s) checked"
