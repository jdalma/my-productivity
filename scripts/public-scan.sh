#!/bin/sh
# Checks commits for private identifiers before they reach this public repository (T61):
#   scripts/public-scan.sh [--ref <name>]... <range>...   e.g. origin/feat/x..HEAD, or <sha> --not --remotes=origin
# --ref names a branch or tag being pushed, checked as text (the pre-push hook passes both of each pair).
# A range is revisions (A, ^A, A..B, A...B) and --not, --all, --branches, --tags, --remotes, --glob; any
# other argument (a pathspec, --since, ...) would narrow what is checked and is refused (exit 2).
# Looks at each commit's added lines (with file and line), its whole message (subject, body, trailers), its
# author and committer (name and address), and the paths it adds or renames to; an annotated tag named in
# the range is checked too (message and tagger, and those of a tag it points at). The patterns come from outside the repository, since the
# list itself is private: $PUBLIC_SCAN_PATTERNS, default ~/.config/my-claude-plugin/private-patterns.txt,
# one extended regular expression per line, `#` comments, case ignored, CRLF line ends allowed. Hits are
# printed without the pattern.
# Exit 0: nothing found. 1: something found. 2: could not check (no pattern file, no pattern, bad pattern,
# bad range) — not checking is never passing.
# Not seen: the content of binary files, and of text files a .gitattributes marks binary or -diff (their
# diff is "Binary files differ"); commits outside the range (already pushed); text produced at build time.
set -u

[ $# -gt 0 ] || { echo "usage: public-scan.sh <rev-list arguments>" >&2; exit 2; }
file=${PUBLIC_SCAN_PATTERNS:-$HOME/.config/my-claude-plugin/private-patterns.txt}
[ -f "$file" ] || { echo "public-scan: no pattern file at $file" >&2; exit 2; }

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
tr -d '\r' < "$file" | grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' > "$tmp/patterns"
[ -s "$tmp/patterns" ] || { echo "public-scan: no pattern in $file" >&2; exit 2; }
# a pattern grep cannot compile would make every search "fail" quietly: check them once
printf '' | grep -i -E -f "$tmp/patterns" >/dev/null 2>"$tmp/err"
[ $? -le 1 ] || { echo "public-scan: a pattern in $file is not a valid regular expression" >&2; exit 2; }

# --ref names apart; then only arguments that name revisions: anything else could quietly narrow the check (R62 L5)
: > "$tmp/refs"; : > "$tmp/args"
while [ $# -gt 0 ]; do
    case $1 in
        --ref) [ $# -ge 2 ] || { echo "public-scan: --ref needs a name" >&2; exit 2; }; printf '%s\n' "$2" >> "$tmp/refs"; shift 2 ;;
        *) printf '%s\n' "$1" >> "$tmp/args"; shift ;;
    esac
done
set -f; old=$IFS; IFS='
'
set -- $(cat "$tmp/args")
IFS=$old; set +f
[ $# -gt 0 ] || { echo "public-scan: no range given" >&2; exit 2; }
: > "$tmp/tags"
for a in "$@"; do
    case $a in
        --not | --all | --branches | --branches=* | --tags | --tags=* | --remotes | --remotes=* | --glob=*) continue ;;
        -*) echo "public-scan: '$a' is not a range; give revisions only" >&2; exit 2 ;;
    esac
    for rev in $(printf '%s\n' "${a#^}" | sed 's/\.\.\.*/\n/' ); do
        git rev-parse -q --verify "$rev^{object}" >/dev/null || { echo "public-scan: '$rev' is not a revision" >&2; exit 2; }
        # an annotated tag is pushed with its own message and tagger (R62 M1)
        [ "$(git cat-file -t "$rev")" = tag ] && echo "$rev" >> "$tmp/tags"
    done
done
git rev-list --reverse "$@" > "$tmp/commits" 2>"$tmp/err" || { echo "public-scan: bad range: $(cat "$tmp/err")" >&2; exit 2; }

hits=0 commits=0 lines=0
q="-c core.quotePath=false"   # paths as written (non-ASCII too), not octal escapes (R62 R3)
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

    # who wrote and committed it (R62 R1)
    git log -1 --format='%an <%ae>%n%cn <%ce>' "$sha" > "$tmp/people"
    printf '%s author\n%s committer\n' "$short" "$short" > "$tmp/where"
    lines=$((lines + 2))
    search "$tmp/people" "$tmp/where"

    # paths added or renamed to (a rename's new name is the last field)
    git $q diff-tree -r --root --no-commit-id --name-status -M --diff-filter=AR --diff-merges=first-parent "$sha" \
        | awk -F'\t' '{ print $NF }' > "$tmp/paths"
    lines=$((lines + $(wc -l < "$tmp/paths")))
    awk -v c="$short" '{ print c " path" }' "$tmp/paths" > "$tmp/where"
    search "$tmp/paths" "$tmp/where"

    # added lines, each with its file and its line number in the new version
    git $q diff-tree -p -U0 --root --no-commit-id --no-color --no-ext-diff -M --diff-merges=first-parent "$sha" | awk -v c="$short" -v out="$tmp/added" -v where="$tmp/where" '
        /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); next }
        /^@@ / { split($3, a, ","); n = substr(a[1], 2) + 0; next }
        /^\+/ { print substr($0, 2) > out; print c " " f ":" n > where; n++ }
    '
    : >> "$tmp/added"
    lines=$((lines + $(wc -l < "$tmp/added")))
    search "$tmp/added" "$tmp/where"
    rm -f "$tmp/added" "$tmp/where"
done < "$tmp/commits"

tags=0
while read -r tag; do
    # a tag may point at a tag: each one's message and tagger is pushed (R62a L1)
    while [ "$(git cat-file -t "$tag")" = tag ]; do
        tags=$((tags + 1))
        git cat-file -p "$tag" > "$tmp/tag"
        lines=$((lines + $(wc -l < "$tmp/tag")))
        search "$tmp/tag" "tag $tag"
        tag=$(sed -n 's/^object //p;q' "$tmp/tag")
    done
done < "$tmp/tags"

refs=$(wc -l < "$tmp/refs" | tr -d ' ')
lines=$((lines + refs))
search "$tmp/refs" "ref"

checked="$commits commit(s), $tags tag(s), $refs ref name(s), $lines line(s)"
if [ "$hits" -gt 0 ]; then
    echo "public-scan: $hits hit(s) — $checked checked. Remove them before pushing." >&2
    exit 1
fi
echo "public-scan: clean — $checked checked"
