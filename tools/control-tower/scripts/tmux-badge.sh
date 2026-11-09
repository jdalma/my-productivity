#!/bin/sh
# Print "my turn N" for tmux status-right; prints nothing when N is 0 or tower-cli is missing or fails.
# Needs a release build: swift build -c release --product tower-cli
# Usage in ~/.tmux.conf:  set -g status-right '#(~/path/to/tmux-badge.sh) %H:%M'
cli="$(dirname "$0")/../.build/release/tower-cli"
n=$("$cli" --count 2>/dev/null)
[ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null && printf 'my turn %s' "$n"
exit 0
