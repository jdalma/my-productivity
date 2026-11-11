#!/bin/sh
# Installs a pre-push hook in this clone that runs public-scan on what is being pushed (T61).
# The hook uses its own copy of public-scan.sh, kept with the hook in the git folder (R62a R1): a branch
# without scripts/, or one that changes the scan, checks out the same check. The copy names the commit it
# came from (its second line); run this again to update it. Our own hook is replaced; anyone else's pre-push
# hook is left alone and the install stops.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
hook=$(git rev-parse --git-path hooks/pre-push)
mark='# public-scan before push (installed by scripts/install-pre-push.sh)'
if [ -e "$hook" ] && ! grep -qF "$mark" "$hook"; then
    echo "install-pre-push: $hook is someone else's hook; not replacing it. Add this line to it instead:" >&2
    echo "  sh '$here/public-scan.sh' <range> || exit 1" >&2
    exit 1
fi
mkdir -p "$(dirname "$hook")"

from=$(git -C "$here" log -1 --format=%H -- public-scan.sh 2>/dev/null || true)
git -C "$here" diff --quiet HEAD -- public-scan.sh 2>/dev/null || from="${from:-no commit} with uncommitted changes"
{
    head -n 1 "$here/public-scan.sh"
    echo "# public-scan from ${from:-an unknown commit} (copied by install-pre-push.sh; run it again to update)"
    tail -n +2 "$here/public-scan.sh"
} > "$(dirname "$hook")/public-scan.sh"

cat > "$hook" <<EOF
#!/bin/sh
$mark
# Reads "<local ref> <local sha> <remote ref> <remote sha>" lines from git; a new branch is checked for every
# commit no ref of the remote has. The names pushed are checked too.
remote=\$1
scan="\$(dirname "\$0")/public-scan.sh"
while read -r local_ref local_sha remote_ref remote_sha; do
    case \$local_sha in *[!0]*) ;; *) continue ;; esac          # a deletion pushes no commit
    case \$remote_sha in
        *[!0]*) sh "\$scan" --ref "\$local_ref" --ref "\$remote_ref" "\$remote_sha..\$local_sha" ;;
        *) sh "\$scan" --ref "\$local_ref" --ref "\$remote_ref" "\$local_sha" --not --remotes="\$remote" ;;
    esac || { echo "pre-push: public-scan refused the push of \$local_ref" >&2; exit 1; }
done
EOF
chmod +x "$hook"
echo "install-pre-push: installed $hook (public-scan from ${from:-an unknown commit})"
