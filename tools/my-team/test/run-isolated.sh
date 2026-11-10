#!/bin/sh
# Runs the test suite on a tmux server of its own. Many tests reach real tmux (send-keys, set-option,
# kill-session on fixed pane ids like %0 and %9); on the user's server they type into and rename
# live panes of running teams. The server is named with -L by a `tmux` wrapper first on PATH: a named
# socket that is gone is "no server", never the default one. TMUX_TMPDIR is not used because tmux
# falls back to the default socket when that directory is missing, and a kill-server then lands on
# the user's server. Set TMUX would win over -L's lookup of the current server, so TMUX and TMUX_PANE go.
real=$(command -v tmux) || { echo "tmux not found" >&2; exit 1; }
dir=$(mktemp -d /tmp/mt.XXXXXX) || exit 1
sock="my-team-test-$$"
# TMUX_TMPDIR goes too: -L names a socket in it, and a missing one is the fallback trap above
unset TMUX TMUX_PANE TMUX_TMPDIR
printf '#!/bin/sh\nexec "%s" -L "%s" "$@"\n' "$real" "$sock" > "$dir/tmux" && chmod +x "$dir/tmux" || exit 1
export PATH="$dir:$PATH"
# tmux-utils refuses to call tmux under a test runner without this mark
export MY_TEAM_TEST_TMUX="$sock"
trap '"$real" -L "$sock" kill-server 2>/dev/null; rm -f "/tmp/tmux-$(id -u)/$sock"; rm -rf "$dir"' EXIT
node --test "$@"
