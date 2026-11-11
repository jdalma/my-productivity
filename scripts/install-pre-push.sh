#!/bin/sh
# Installs a pre-push hook in this clone (T61, T63f). The hook first runs public-scan on what is being pushed,
# for every ref; then, when the repository names a my-team board (git config my-team.board <team>), the board
# gate: every commit going out needs an approved review on that board, or must lie within my-team.baseline.
# The hook uses its own copies of public-scan.sh and push-gate.sh, kept with the hook in the git folder
# (R62a R1): a branch without scripts/, or one that changes them, checks out the same checks. Each copy names
# the commit it came from (its second line); run this again to update them. Our own hook is replaced; anyone
# else's pre-push hook is left alone and the install stops.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
hook=$(git rev-parse --git-path hooks/pre-push)
mark='# public-scan before push (installed by scripts/install-pre-push.sh)'
if [ -e "$hook" ] && ! grep -qF "$mark" "$hook"; then
    echo "install-pre-push: $hook is someone else's hook; not replacing it. Add these lines to it instead:" >&2
    echo "  sh '$here/public-scan.sh' <range> || exit 1" >&2
    echo "  sh '$here/push-gate.sh' <remote> <local sha> <remote sha> || exit 1" >&2
    exit 1
fi
mkdir -p "$(dirname "$hook")"

# copy <script>: puts scripts/<script> next to the hook, naming the commit it came from on its second line
copy() {
    from=$(git -C "$here" log -1 --format=%H -- "$1" 2>/dev/null || true)
    git -C "$here" diff --quiet HEAD -- "$1" 2>/dev/null || from="${from:-no commit} with uncommitted changes"
    {
        head -n 1 "$here/$1"
        echo "# ${1%.sh} from ${from:-an unknown commit} (copied by install-pre-push.sh; run it again to update)"
        tail -n +2 "$here/$1"
    } > "$(dirname "$hook")/$1"
    echo "$1 from ${from:-an unknown commit}"
}
copies="$(copy public-scan.sh), $(copy push-gate.sh)"

cat > "$hook" <<EOF
#!/bin/sh
$mark
# Reads "<local ref> <local sha> <remote ref> <remote sha>" lines from git; a new branch is checked for every
# commit no ref of the remote has. The names pushed are checked too. The identifier scan runs for every ref
# before the board gate runs for any.
remote=\$1
dir=\$(dirname "\$0")
refs=\$(cat)
echo "\$refs" | while read -r local_ref local_sha remote_ref remote_sha; do
    [ -n "\$local_ref" ] || continue
    case \$local_sha in *[!0]*) ;; *) continue ;; esac          # a deletion pushes no commit
    case \$remote_sha in
        *[!0]*) sh "\$dir/public-scan.sh" --ref "\$local_ref" --ref "\$remote_ref" "\$remote_sha..\$local_sha" ;;
        *) sh "\$dir/public-scan.sh" --ref "\$local_ref" --ref "\$remote_ref" "\$local_sha" --not --remotes="\$remote" ;;
    esac || { echo "pre-push: public-scan refused the push of \$local_ref" >&2; exit 1; }
done || exit 1
echo "\$refs" | while read -r local_ref local_sha remote_ref remote_sha; do
    [ -n "\$local_ref" ] || continue
    case \$local_sha in *[!0]*) ;; *) continue ;; esac
    sh "\$dir/push-gate.sh" "\$remote" "\$local_sha" "\$remote_sha" \\
        || { echo "pre-push: the board gate refused the push of \$local_ref" >&2; exit 1; }
done || exit 1
EOF
chmod +x "$hook"
echo "install-pre-push: installed $hook ($copies)"
