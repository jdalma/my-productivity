#!/bin/bash
# A test Control Tower beside the one in use (T96, T98): its own home, my-team state, tmux server, task board and
# settings, and a dry run of everything it would do outward. Ctrl-C (or the app quitting) cleans up the app, the test
# tmux server and $T. One test instance at a time with the same bundle id.
#
# Build the test bundle first, from a copy of the commit under test (README.md, "E2E"):
#   scripts/bundle-app.sh .build/ControlTowerTest.app local.control-tower.test   # both arguments: without them it
#                                                                                 # overwrites the installed app
#   Run by a my-team worker (OMC_TEAM_WORKER), bundle-app.sh makes that id local.control-tower.test-<worker>, so the
#   test instances of two workers keep their settings apart (T173).
# Usage: [CT_TEST_SIZE=1920x1080] [CT_TEST_ORIGIN=40,40] [CT_TEST_FONT_SCALE=1.1] [CT_TEST_APPEARANCE=dark] [CT_TEST_VISIBLE=1] scripts/test-instance.sh [test.app] > out.txt 2>&1 &
#   (default .build/ControlTowerTest.app). out.txt names $T and the app's pid; stop with `kill -TERM <this script's pid>`
#   (a bash started with `&` from a shell that is not interactive ignores INT).
#   Drive the app with scripts/ax.swift <app pid> …, which refuses any other app. Compile it once and each call
#   takes milliseconds: swiftc -O scripts/ax.swift -o .build/ax, then .build/ax <app pid> … Compile it again when the
#   test bundle is built again: an ax from before the windows were hidden (T187) does not list them.
#
# What the app sees, all under $T:
# - sessions: team example-team with workers in each state (alpha 답 기다림, beta 작업 중, gamma 권한 요청,
#   delta 완료, epsilon 쉬는 중, on a 220-column pane), mostly a tmux window each; team example-panes (eta, theta,
#   iota) with its workers as panes of one window, as my-team lays a team out; a loose session (solo); and history:
#   an ended session and a worker of an ended team. work/alpha and work/beta are git repositories with committed
#   and uncommitted changes (diff window).
# - usage (T177): transcripts with token usage for the dashboard, from scripts/test-instance/usage_fixture.py.
#   CT_TEST_USAGE=normal (35 days in seven invented projects, the default), sparse (two active days) or none.
# - task board: $T/bin/my-team is first on the app's PATH and answers board-status from $T/board.json; every call
#   is a line in $T/actions.log. The real my-team CLI and task board are never run.
# - settings: the test bundle's defaults domain is emptied at each start (the installed app's is never touched; the
#   script stops first if an app with that bundle id is running, whose settings these are), so
#   the board opens as a window, not full screen. CT_TEST_SIZE sets its size, CT_TEST_FONT_SCALE the text scale
#   (0.8 to 2.0 in 0.1 steps), CT_TEST_APPEARANCE light or dark whatever the system is in (for captures). macOS shrinks a window larger than the screen to fit it: the script says so and names
#   a size and scale with the same ratio of window to text that do fit.
# - windows (T103): under TOWER_DRY_RUN every window of the app is on every Space, another app's full screen
#   included, so accessibility and screencapture -l reach it wherever the user is. The app stays an accessory (no
#   Dock icon) and never activates itself: the user's front app keeps the keyboard. Each window opens with its top left corner at CT_TEST_ORIGIN
#   (x,y from the main screen's top left), by default in the screen's bottom right corner.
# - not on the user's screen (T187): the windows are stacked under the desktop picture, where nothing shows them and
#   screencapture -l<number> and ax.swift work as on a window in view. The pointer does not reach them: to hover, drag
#   or look, start with CT_TEST_VISIBLE=1, which puts the windows in view at CT_TEST_ORIGIN as before.
#
# Rules:
# - tmux: every command here names the test server by its socket ($T/tmux.sock, -S). TMUX_TMPDIR is never used to
#   pick a server: with a missing directory tmux goes to the default server, and a kill-server there ends the user's.
# - The app sees the same server through TOWER_TMUX_SOCKET and writes its actions to $T/actions.log (TOWER_DRY_RUN).
# - Clipboard: the app's copy, paste and pane copy use its own pasteboard (T97); selectable text and the search field
#   still use the system clipboard, so a test does not copy or paste there.
set -euo pipefail
# one block: bash reads it whole before running, so editing this file while an instance runs cannot break it
{
cd "$(dirname "$0")/.."

app="${1-.build/ControlTowerTest.app}"
exe="$app/Contents/MacOS/TowerApp"
[ -x "$exe" ] || { echo "test-instance.sh: no $exe; build it with scripts/bundle-app.sh $app local.control-tower.test" >&2; exit 1; }
bundle_id=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")
# the installed app's id would share its settings and its single running instance; its domain is never emptied
case "$bundle_id" in
    local.control-tower) echo "test-instance.sh: $app has the installed app's bundle id" >&2; exit 1 ;;
    local.control-tower.*) ;;
    *) echo "test-instance.sh: $app's bundle id '$bundle_id' is not a local.control-tower.* test id" >&2; exit 1 ;;
esac
size="${CT_TEST_SIZE-}"
if [ -n "$size" ] && ! [[ $size =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]]; then echo "test-instance.sh: CT_TEST_SIZE is WIDTHxHEIGHT, e.g. 1920x1080" >&2; exit 1; fi
scale="${CT_TEST_FONT_SCALE-}"
# the app's own range (FontScale): 0.8 to 2.0 in 0.1 steps
if [ -n "$scale" ] && ! [[ $scale =~ ^(0\.[89]|1(\.[0-9])?|2(\.0)?)$ ]]; then echo "test-instance.sh: CT_TEST_FONT_SCALE is 0.8 to 2.0 in 0.1 steps, e.g. 1.1" >&2; exit 1; fi
appearance="${CT_TEST_APPEARANCE-}"
case "$appearance" in ''|light|dark) ;; *) echo "test-instance.sh: CT_TEST_APPEARANCE is light or dark" >&2; exit 1 ;; esac
case "${CT_TEST_VISIBLE-}" in ''|1) ;; *) echo "test-instance.sh: CT_TEST_VISIBLE is 1 or not set" >&2; exit 1 ;; esac
origin="${CT_TEST_ORIGIN-}"
case "$origin" in ''|[0-9]*,[0-9]*) ;; *) echo "test-instance.sh: CT_TEST_ORIGIN is X,Y, e.g. 40,40" >&2; exit 1 ;; esac
tmux_bin=$(command -v tmux) || { echo "test-instance.sh: no tmux" >&2; exit 1; }

running=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); function run(argv) { return ObjC.deepUnwrap($.NSRunningApplication.runningApplicationsWithBundleIdentifier(argv[0]).valueForKey("processIdentifier")).join(" ") }' "$bundle_id")
if [ -n "$running" ]; then
    echo "test-instance.sh: an app with bundle id $bundle_id is running (pid $running); its settings are left alone. Stop it, or build this bundle with another local.control-tower.* id" >&2
    exit 1
fi
# The file itself stays, since removing it would let a script that already opened it lock a file nobody else sees.
# For the same reason nobody else removes it while this script lives: no cleanup deletes $TMPDIR/ct-test* wholesale.
lock="${TMPDIR:-/tmp}/ct-test-lock.$bundle_id"
exec 9>>"$lock"
if ! python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)' 2>/dev/null; then
    echo "test-instance.sh: another test-instance.sh has bundle id $bundle_id (pid $(cat "$lock")); its settings are left alone. Stop it, or build this bundle with another local.control-tower.* id" >&2
    exit 1
fi
echo $$ > "$lock"

T=$(mktemp -d "${TMPDIR:-/tmp}/ct-test.XXXXXX")
T=$(cd "$T" && pwd -P)
sock="$T/tmux.sock"
app_pid=""

# 9>&-: the test tmux server and the app outlive a killed script, and must not keep its lock
t() { "$tmux_bin" -S "$sock" "$@" 9>&-; }

cleanup() {
    trap - EXIT INT TERM
    if [ -n "$app_pid" ] && kill -0 "$app_pid" 2>/dev/null; then
        kill "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    # only the test server: its socket, under $T, there now
    case "$sock" in
        "$T"/*) if [ -S "$sock" ]; then t kill-server 2>/dev/null || true; fi ;;
    esac
    case "$T" in
        # a child the app started (the fake my-team's python) can still be writing under $T/home: try once more
        */ct-test.*) rm -rf "$T" 2>/dev/null || { sleep 1; rm -rf "$T"; } ;;
    esac
    echo "test-instance.sh: cleaned up $T"
}
trap cleanup EXIT INT TERM

team=example-team
panes_team=example-panes
mkdir -p "$T/work"
for w in alpha beta gamma delta epsilon eta theta iota solo; do mkdir -p "$T/work/$w"; done

# The test server. Each pane runs `sleep` (exec'd, so the pane's pid is the session's pid and stays alive); gamma's
# shows a permission prompt and epsilon's, 220 columns wide, a line longer than the detail's terminal.
prompt='printf "%s\n" "Do you want to run an example command?" "> 1. Yes" "  2. No" "" "Esc to cancel"; exec sleep 86400'
wide='printf "%s\n" "$(printf "example-%03d " $(seq 1 18))"; exec sleep 86400'
t -f /dev/null new-session -d -s "$team" -x 220 -y 50 -n pair -c "$T/work/alpha" "exec sleep 86400"
t split-window -d -t "$team:pair" -c "$T/work/beta" "exec sleep 86400"
t new-window -d -t "$team:" -n gamma -c "$T/work/gamma" "$prompt"
t new-window -d -t "$team:" -n delta -c "$T/work/delta" "exec sleep 86400"
t new-window -d -t "$team:" -n epsilon -c "$T/work/epsilon" "$wide"
t new-session -d -s "$panes_team" -x 200 -y 50 -n team -c "$T/work/eta" "exec sleep 86400"
t split-window -d -t "$panes_team:team" -c "$T/work/theta" "exec sleep 86400"
t split-window -d -t "$panes_team:team" -c "$T/work/iota" "exec sleep 86400"
t new-session -d -s solo -x 160 -y 40 -c "$T/work/solo" "exec sleep 86400"

# name, session, window, pane, pid for fixture.py; the pane's @worker_name ties it to the manifest's worker
: > "$T/panes.tsv"
# name_panes <session> <worker name per pane, in list-panes order>
name_panes() {
    local session=$1 pane window pid
    shift
    while IFS=$'\t' read -r pane window pid; do
        t set-option -p -t "$pane" @worker_name "$1"
        printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$session" "$window" "$pane" "$pid" >> "$T/panes.tsv"
        shift
    done < <(t list-panes -s -t "$session:" -F $'#{pane_id}\t#{window_id}\t#{pane_pid}')
}
name_panes "$team" alpha beta gamma delta epsilon
name_panes "$panes_team" eta theta iota
IFS=$'\t' read -r pane window pid < <(t list-panes -t "solo:" -F $'#{pane_id}\t#{window_id}\t#{pane_pid}')
printf 'solo\tsolo\t%s\t%s\t%s\n' "$window" "$pane" "$pid" >> "$T/panes.tsv"

python3 scripts/test-instance/fixture.py "$T" "$T/panes.tsv"
python3 scripts/test-instance/docs-fixture.py "$T"
python3 scripts/test-instance/usage_fixture.py "$T" "${CT_TEST_USAGE-normal}"

# the test bundle's settings, from empty: a window, not the full screen a previous run may have left
defaults delete "$bundle_id" 2>/dev/null || true
if [ -n "$size" ]; then
    w=${size%x*} h=${size#*x}
    defaults write "$bundle_id" "NSWindow Frame board" "0 0 $w $h 0 0 $w $h"
    # the screen's visible size, read in this process: no event goes to any app
    visible=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); var f = $.NSScreen.mainScreen.visibleFrame; Math.floor(f.size.width) + "x" + Math.floor(f.size.height)' 2>/dev/null || true)
    python3 scripts/test-instance/fit.py "$size" "${scale:-1.0}" "$visible" >&2
fi
if [ -n "$scale" ]; then defaults write "$bundle_id" boardFontScale -float "$scale"; fi
if [ -n "$appearance" ]; then defaults write "$bundle_id" appearance "$appearance"; fi

echo "test-instance.sh: \$T=$T"
echo "  actions: $T/actions.log    tmux: $tmux_bin -S $sock ls"
echo "  clipboard: the app's copy, paste and pane copy use its own pasteboard; selectable text and the search field still copy and paste with the system clipboard"
env -u TMUX -u TMUX_PANE -u MY_TEAM_STATE_ROOT -u MY_TEAM_WORKER -u OMC_TEAM_WORKER \
    PATH="$T/bin:$PATH" \
    HOME="$T/home" \
    MY_TEAM_STATE_ROOT_BASE="$T/my-team/sessions" \
    CLAUDE_CONFIG_DIR="$T/home/.claude" \
    CODEX_HOME="$T/home/.codex" \
    TOWER_TMUX_SOCKET="$sock" \
    TOWER_DRY_RUN="$T/actions.log" \
    "$exe" > "$T/app.log" 2>&1 9>&- &
app_pid=$!
echo "  app pid $app_pid ($bundle_id); Ctrl-C to stop"
wait "$app_pid" || true
exit 0
}
