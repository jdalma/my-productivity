#!/bin/sh
# Runs the test suite on a tmux server of its own. Many tests reach real tmux (send-keys, set-option,
# kill-session on fixed pane ids like %0 and %9); on the user's server they type into and rename
# live panes of running teams. MY_TEAM_TEST_TMUX names a server of the run's own: tmux-utils adds
# `-L <it>` to every tmux call, so even a test that outlives this shell finds that server or none,
# never the default one. TMUX_TMPDIR is not used: tmux falls back to the default socket when that
# directory is missing, and a kill-server then lands on the user's server. TMUX, TMUX_PANE and
# TMUX_TMPDIR are cleared so that -L resolves to /tmp/tmux-<uid>/<name>.
unset TMUX TMUX_PANE TMUX_TMPDIR
sock="my-team-test-$$"
export MY_TEAM_TEST_TMUX="$sock"
trap 'tmux -L "$sock" kill-server 2>/dev/null; rm -f "/tmp/tmux-$(id -u)/$sock"' EXIT
node --test "$@"
