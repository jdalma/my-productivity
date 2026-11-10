#!/bin/sh
# Runs the test suite on a tmux server of its own. Many tests reach real tmux (send-keys, set-option,
# kill-session on fixed pane ids like %0 and %9); on the user's server they type into and rename
# live panes of running teams. With TMUX unset, tmux takes its socket from TMUX_TMPDIR. Set TMUX
# would win over TMUX_TMPDIR, so both TMUX and TMUX_PANE go. The path stays short: a socket path
# has a limit of about 104 bytes.
dir=$(mktemp -d /tmp/mt.XXXXXX) || exit 1
unset TMUX TMUX_PANE
export TMUX_TMPDIR="$dir"
trap 'tmux kill-server 2>/dev/null; rm -rf "$dir"' EXIT
node --test "$@"
