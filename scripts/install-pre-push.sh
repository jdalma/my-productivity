#!/bin/sh
# Installs a pre-push hook in this clone that runs scripts/public-scan.sh on what is being pushed (T61).
# An existing pre-push hook is left alone: the install stops instead of replacing it.
set -eu

hook=$(git rev-parse --git-path hooks/pre-push)
if [ -e "$hook" ]; then
    echo "install-pre-push: $hook already exists; not replacing it. Add this line to it instead:" >&2
    echo '  sh "$(git rev-parse --show-toplevel)/scripts/public-scan.sh" <range> || exit 1' >&2
    exit 1
fi
mkdir -p "$(dirname "$hook")"
cat > "$hook" <<'EOF'
#!/bin/sh
# public-scan before push (installed by scripts/install-pre-push.sh). Reads "<local ref> <local sha>
# <remote ref> <remote sha>" lines from git; a new branch is checked for every commit no ref of the remote has.
remote=$1
scan="$(git rev-parse --show-toplevel)/scripts/public-scan.sh"
while read -r local_ref local_sha remote_ref remote_sha; do
    case $local_sha in *[!0]*) ;; *) continue ;; esac          # a deletion pushes no commit
    case $remote_sha in
        *[!0]*) sh "$scan" "$remote_sha..$local_sha" ;;
        *) sh "$scan" "$local_sha" --not --remotes="$remote" ;;
    esac || { echo "pre-push: public-scan refused the push of $local_ref" >&2; exit 1; }
done
EOF
chmod +x "$hook"
echo "install-pre-push: installed $hook"
