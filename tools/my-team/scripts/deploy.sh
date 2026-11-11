#!/bin/sh
# Installs my-team from a commit of this repo, not from the working tree (T57):
#   scripts/deploy.sh [<commit>] [--prefix <dir>]
# <commit> defaults to HEAD. Without --prefix it installs into npm's global prefix, replacing what is there
# (an `npm link` symlink included). The installed copy names its commit in COMMIT and `my-team --version`.
set -eu

commit=HEAD
prefix=
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) mkdir -p "$2"; prefix=$(cd "$2" && pwd); shift 2 ;;
        -*) echo "usage: deploy.sh [<commit>] [--prefix <dir>]" >&2; exit 2 ;;
        *) commit=$1; shift ;;
    esac
done

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
sha=$(git -C "$repo" rev-parse --verify "$commit^{commit}")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git -C "$repo" archive "$sha" tools/my-team | tar -x -C "$tmp"
tgz=$(cd "$tmp/tools/my-team" && npm pack --silent --pack-destination "$tmp")
npm install -g --no-fund --no-audit ${prefix:+--prefix "$prefix"} "$tmp/$tgz"
# written after install, so any commit (older ones too) gets it, whatever its package.json "files" lists
# (npm prints paths with secret-looking segments as ***: the prefix's root is built here, not asked of npm)
root=${prefix:+$prefix/lib/node_modules}
installed="${root:-$(npm root -g)}/my-team"
[ -d "$installed" ] || { echo "deploy.sh: no install at $installed" >&2; exit 1; }
echo "$sha" > "$installed/COMMIT"
echo "my-team $(git -C "$repo" rev-parse --short "$sha") installed${prefix:+ under $prefix}"
