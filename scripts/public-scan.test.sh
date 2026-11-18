#!/bin/sh
# Tests for public-scan.sh and install-pre-push.sh (T61), on a scratch repository and a local bare remote.
#   sh scripts/public-scan.test.sh
# Patterns here are made up (example.com family); the real list never enters this repository.
set -u
here=$(cd "$(dirname "$0")" && pwd)
scan="$here/public-scan.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
check() {  # check <name> <expected exit> <actual exit>
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected exit $2, got $3"; failed=1; fi
}
contains() {  # contains <name> <file> <text>
    if grep -qF -- "$3" "$2"; then echo "ok   $1"; else echo "FAIL $1: no '$3' in:"; sed 's/^/     /' "$2"; failed=1; fi
}

printf '%s\n' '# fake identifiers for the test' '' 'internal\.example\.com' 'example-secret-team' '예시비밀팀' > "$work/patterns"
export PUBLIC_SCAN_PATTERNS="$work/patterns"

git init -q --bare "$work/remote.git"
git init -q -b main "$work/repo"
cd "$work/repo"
git config user.name t; git config user.email t@t
git remote add origin "$work/remote.git"
commit() { git add -A && git commit -q "$@"; }
printf 'line one\nline two\n' > a.txt; commit -m base
git push -q origin main
base=$(git rev-parse HEAD)

# (f) nothing in the range
sh "$scan" "$base..HEAD" > "$work/out" 2>&1; check "(f) no commits in range" 0 $?
contains "(f) says how much it checked" "$work/out" "0 commit(s)"

# (a) an added line
printf 'line one\nsee internal.example.com/wiki\nline two\n' > a.txt; commit -m "docs: link"
sh "$scan" "$base..HEAD" > "$work/out" 2>&1; check "(a) added line" 1 $?
contains "(a) commit, file and line shown" "$work/out" "$(git rev-parse --short HEAD) a.txt:2: see internal.example.com/wiki"
if grep -q 'internal\\\.example' "$work/out"; then echo "FAIL (a) the pattern itself is printed"; failed=1; else echo "ok   (a) the pattern itself is not printed"; fi

# (b) the same line removed again: only the removing commit is in range
git reset -q --hard "$base"
printf 'see INTERNAL.example.com\n' > b.txt; commit -m "add b"; git push -q origin main; mid=$(git rev-parse HEAD)
rm b.txt; commit -m "drop b"
sh "$scan" "$mid..HEAD" > "$work/out" 2>&1; check "(b) pattern only in a removed line" 0 $?
git reset -q --hard "$mid"

# (c) message body and trailer
git commit -q --allow-empty -m "subject" -m "body mentions example-secret-team"
sh "$scan" "$mid..HEAD" > "$work/out" 2>&1; check "(c) message body" 1 $?
contains "(c) shown as message line 3" "$work/out" "message:3: body mentions example-secret-team"
git reset -q --hard "$mid"
git commit -q --allow-empty -m "subject" -m "Reviewed-by: someone <a@internal.example.com>"
sh "$scan" "$mid..HEAD" > "$work/out" 2>&1; check "(c) trailer" 1 $?
git reset -q --hard "$mid"

# (d) a path added, and a path renamed to
mkdir -p docs/example-secret-team; echo x > docs/example-secret-team/notes.md; commit -m "notes"
sh "$scan" "$mid..HEAD" > "$work/out" 2>&1; check "(d) added path" 1 $?
contains "(d) shown as a path" "$work/out" "path: docs/example-secret-team/notes.md"
git reset -q --hard "$mid"
echo y > plain.md; commit -m plain; p=$(git rev-parse HEAD)
git mv plain.md example-secret-team.md; commit -m "rename"
sh "$scan" "$p..HEAD" > "$work/out" 2>&1; check "(d) renamed-to path" 1 $?
git reset -q --hard "$mid"

# (e) no way to check is no pass
PUBLIC_SCAN_PATTERNS="$work/none" sh "$scan" "$mid..HEAD" > "$work/out" 2>&1; check "(e) no pattern file" 2 $?
: > "$work/empty"; PUBLIC_SCAN_PATTERNS="$work/empty" sh "$scan" "$mid..HEAD" > "$work/out" 2>&1; check "(e) empty pattern file" 2 $?
printf '# only\n\n  # comments\n' > "$work/comments"; PUBLIC_SCAN_PATTERNS="$work/comments" sh "$scan" "$mid..HEAD" > "$work/out" 2>&1; check "(e) comments only" 2 $?
printf 'ok\n(unclosed\n' > "$work/bad"; PUBLIC_SCAN_PATTERNS="$work/bad" sh "$scan" "$mid..HEAD" > "$work/out" 2>&1; check "(e) an invalid pattern" 2 $?
sh "$scan" no-such-ref..HEAD > "$work/out" 2>&1; check "(e) a range git cannot read" 2 $?

# R62 R1: author and committer names and addresses
git -c user.email=dev@internal.example.com commit -q --allow-empty -m "plain subject"
sh "$scan" "$mid..HEAD" > "$work/out" 2>&1; check "(R1) author address" 1 $?
contains "(R1) shown as the author" "$work/out" "author: t <dev@internal.example.com>"
git reset -q --hard "$mid"

# R62 R2: a pattern file with CRLF line ends
printf 'internal\\.example\\.com\r\n' > "$work/crlf"
echo "x internal.example.com" > e.txt; commit -m e
PUBLIC_SCAN_PATTERNS="$work/crlf" sh "$scan" "$mid..HEAD" > "$work/out" 2>&1; check "(R2) CRLF pattern file" 1 $?
git reset -q --hard "$mid"

# R62 R3: a non-ASCII path
mkdir -p "문서/예시비밀팀"; echo x > "문서/예시비밀팀/a.md"; commit -m "korean path"
sh "$scan" "$mid..HEAD" > "$work/out" 2>&1; check "(R3) non-ASCII path" 1 $?
contains "(R3) shown as written" "$work/out" "path: 문서/예시비밀팀/a.md"
git reset -q --hard "$mid"

# R62 L5: rev-list ranges only
sh "$scan" --since=1.day HEAD > "$work/out" 2>&1; check "(L5) an option that is not a range" 2 $?
sh "$scan" HEAD -- a.txt > "$work/out" 2>&1; check "(L5) a pathspec" 2 $?
sh "$scan" "$mid" --not --remotes=origin > "$work/out" 2>&1; check "(L5) --not --remotes is a range" 0 $?

# (g) the hook: a dirty commit is refused and stays off the remote, a clean one goes
sh "$here/install-pre-push.sh" > "$work/out" 2>&1; check "(g) install" 0 $?
echo plain > p.txt; commit -m "plain"
copy=$(git rev-parse --git-path hooks/public-scan.sh)
contains "(R62a R1) the hook has its own copy of the scan, naming its commit" "$copy" "# public-scan from "
git push -q origin main > "$work/out" 2>&1; check "(g) clean push goes through" 0 $?
echo "host: internal.example.com" > c.txt; commit -m "config"; dirty=$(git rev-parse HEAD)
git push -q origin main > "$work/out" 2>&1; check "(g) dirty push refused" 1 $?
if git --git-dir="$work/remote.git" cat-file -e "$dirty" 2>/dev/null; then echo "FAIL (g) the dirty commit reached the remote"; failed=1; else echo "ok   (g) the dirty commit is not on the remote"; fi
git checkout -q -b topic "$dirty"
git push -q origin topic > "$work/out" 2>&1; check "(g) a new branch carrying it is refused too" 1 $?
git checkout -q main; git reset -q --hard HEAD~1; echo "clean" > d.txt; commit -m "clean"
git push -q origin main > "$work/out" 2>&1; check "(g) a clean commit after it goes through" 0 $?

# R62 M1: an annotated tag's message is pushed too
git tag -a v-dirty -m "release notes for example-secret-team"
git push -q origin v-dirty > "$work/out" 2>&1; check "(M1) a tag whose message matches is refused" 1 $?
if git --git-dir="$work/remote.git" rev-parse -q --verify refs/tags/v-dirty >/dev/null; then echo "FAIL (M1) the tag reached the remote"; failed=1; else echo "ok   (M1) the tag is not on the remote"; fi
git -c user.email=rel@internal.example.com tag -a v-tagger -m "clean notes"
git push -q origin v-tagger > "$work/out" 2>&1; check "(M1) a tagger address that matches is refused" 1 $?
git tag -a v-clean -m "clean notes"
git push -q origin v-clean > "$work/out" 2>&1; check "(M1) a clean tag goes through" 0 $?

# R62a L1: a tag pointing at a tag
git tag -a inner -m "notes for example-secret-team"
git tag -a outer inner -m "clean outer notes"
git tag -d inner > /dev/null
git push -q origin outer > "$work/out" 2>&1; check "(R62a L1) the inner tag's message is checked" 1 $?

# R62a L2: the names of what is pushed
git branch example-secret-team-fix
git push -q origin example-secret-team-fix > "$work/out" 2>&1; check "(R62a L2) a branch name that matches is refused" 1 $?
git tag example-secret-team-v1
git push -q origin example-secret-team-v1 > "$work/out" 2>&1; check "(R62a L2) a tag name that matches is refused" 1 $?

# R62a L3: a hit in a tag only still says what it is
git tag -a v-only -m "about internal.example.com" HEAD
sh "$scan" v-only --not --remotes=origin > "$work/out" 2>&1; check "(R62a L3) tag-only hit" 1 $?
contains "(R62a L3) the summary counts tags" "$work/out" "tag(s)"

# R62a R1: a branch without the scan script still has a checking hook
git checkout -q --orphan bare-main; git rm -rq --cached . ; rm -rf -- *; echo bare > only.txt; commit -m "bare main"
git push -q origin bare-main > "$work/out" 2>&1; check "(R62a R1) clean push from a branch without scripts/" 0 $?
echo "x internal.example.com" > leak.txt; commit -m leak
git push -q origin bare-main > "$work/out" 2>&1; check "(R62a R1) dirty push from a branch without scripts/ is refused" 1 $?
git checkout -q main

# reinstalling over our own hook replaces it; someone else's is never replaced
sh "$here/install-pre-push.sh" > "$work/out" 2>&1; check "(R62a R1) reinstall over our own hook" 0 $?

# (h) an existing pre-push hook is never replaced
hook=$(git rev-parse --git-path hooks/pre-push)
printf '#!/bin/sh\necho mine\n' > "$hook"
sh "$here/install-pre-push.sh" > "$work/out" 2>&1; check "(h) install stops" 1 $?
contains "(h) the existing hook is untouched" "$hook" "echo mine"

[ "$failed" = 0 ] && echo "all passed" || { echo "some failed"; exit 1; }
