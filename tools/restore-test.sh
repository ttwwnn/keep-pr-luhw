#!/usr/bin/env bash
#
# What a reboot does to the sidebar, from outside the app.
#
# After a reboot the daemon starts empty. The app comes up first, puts up its
# default workspace, and only then does whatever puts the old tabs back — a
# login script, the command-line client — make them again, a workspace at a
# time. Every one of those used to land in no window's list: running, a ⌘P
# away, and missing from the sidebar, which from the chair is the same as
# lost. That happened, with ten conversations in it.
#
# The rule that answers it: every running workspace is in some window's
# sidebar, unless somebody put it out of sight (removed it from the last window
# showing it, or closed the window it was in) — or it is the quick terminal's.
#
# Three more things that went with it, checked here too:
#   - tab names and tab order are kept by tab id, and a daemon started afresh
#     counts ids from one again: what was kept for the last one must not
#     rename or reorder the new one's tabs;
#   - a script restoring tabs can name them only by writing names.json after
#     the app is already up, so the app has to notice the file changed;
#   - what a window carries was written down only when a window closed or the
#     app quit, so a crash — or the power cut that is a reboot — lost it.
#
#   tools/restore-test.sh
#
# Nothing is mocked: a daemon of its own on a scratch socket, KeepDev, real
# shells. No mouse and no keys: what the window shows is read through the
# accessibility tree (tools/axtext.swift). About two minutes.
#
# Your app and your daemon are never touched.

set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/scratch.sh
. tools/scratch.sh

APP=$(dev_app)
APP_NAME=$(app_name "$APP")
export KEEP_APP_NAME=$APP_NAME
BIN=$APP/Contents/MacOS/$APP_NAME
SOCKET=/tmp/keep-restore-$$.sock
WORK=$(mktemp -d /tmp/keep-restore-XXXXXX)
AXTEXT=$WORK/axtext
KEEP=./target/release/keep
HOME_WS=$(id -un)   # the default workspace a fresh daemon gets is named after the user
PASSED=0
FAILED=0

cleanup() {
    [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null
    [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null
    [ -n "${KEEP_WORK:-}" ] && say "kept: $WORK" || rm -rf "$WORK"
    rm -f "$SOCKET"
}
trap cleanup EXIT INT TERM

say() { printf '%s\n' "$*"; }
check() {  # check <what> <wanted> <got>
    if [ "$3" = "$2" ]; then
        say "  ok    $1"
        PASSED=$((PASSED + 1))
    else
        say "  FAIL  $1"
        say "        wanted: $2"
        say "        got:    $3"
        FAILED=$((FAILED + 1))
    fi
}

say "building $APP_NAME, the client, the daemon and the tools (yours is left alone)"
./tools/build-dev.sh >/dev/null || { say "could not build $APP_NAME — run tools/build-dev.sh"; exit 1; }
swiftc -O tools/axtext.swift -o "$AXTEXT" 2>/dev/null || { say "could not build axtext"; exit 1; }

export KEEP_SOCKET=$SOCKET
export KEEP_STATE_DIR=$WORK/state
mkdir -p "$KEEP_STATE_DIR"
require_scratch_socket
rm -f "$SOCKET"

# A daemon of our own, as a reboot leaves it: running, and holding nothing.
start_daemon() {
    [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null && sleep 1
    rm -f "$SOCKET"
    ./target/release/keepd >>"$WORK/daemon.log" 2>&1 &
    DAEMON_PID=$!
    local waited=0
    while [ ! -S "$SOCKET" ] && [ "$waited" -lt 20 ]; do sleep 0.25; waited=$((waited + 1)); done
    sleep 0.5
}

start_app() {
    : >"$WORK/app.log"
    KEEP_TRACE=1 "$BIN" >"$WORK/app.log" 2>&1 &
    APP_PID=$!
    wait_for "sidebar +order" 30 || say "  (the app traced no sidebar within 30 s)"
    place_on_screen
    sleep 1
}

# Not `stop_app`: that quits politely, and the point of one of these is the
# app dying with nothing written on the way out.
kill_app() {
    kill -9 "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
    APP_PID=
    sleep 1
}

wait_for() {  # wait_for <extended regex over the trace> <seconds>
    local waited=0
    while ! grep -aqE -- "$1" "$WORK/app.log" && [ "$waited" -lt $(($2 * 4)) ]; do
        sleep 0.25
        waited=$((waited + 1))
    done
    grep -aqE -- "$1" "$WORK/app.log"
}

# The workspaces the sidebar lists, top to bottom: header lines are the name
# alone or the name and its dot, which no tab row starts with.
sidebar() {
    local names="$1"
    "$AXTEXT" "$APP_NAME" 2>/dev/null | awk -v names="$names" '
        BEGIN { n = split(names, list, " "); for (i = 1; i <= n; i++) known[list[i]] = 1 }
        { head = $0; sub(/, .*/, "", head); if (head in known && !(head in seen)) { seen[head] = 1; out = out (out ? " " : "") head } }
        END { print out }'
}
# Which of two tab names the sidebar shows first.
first_of() {  # first_of <a> <b>
    "$AXTEXT" "$APP_NAME" 2>/dev/null | awk -v a="$1" -v b="$2" '
        { n = split($0, part, ", "); for (i = 1; i <= n; i++) if (part[i] == a || part[i] == b) { print part[i]; exit } }'
}
shows() {  # shows <tab name>: yes if some sidebar row is titled that
    "$AXTEXT" "$APP_NAME" 2>/dev/null | awk -v t="$1" '
        { n = split($0, part, ", "); for (i = 1; i <= n; i++) if (part[i] == t) found = 1 }
        END { print found ? "yes" : "no" }'
}
carried() {  # what windows.json says window 0 carries
    python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["0"]["workspaces"]))' \
        "$KEEP_STATE_DIR/windows.json" 2>/dev/null
}
socket_birth() { python3 -c 'import os,sys; print(repr(os.stat(sys.argv[1]).st_birthtime))' "$SOCKET"; }

# ------------------------------------------------ a reboot, nothing remembered
say ""
say "a reboot with no window remembered: the tabs come back after the app is up"
stop_app
start_daemon
start_app
check "the app put up its default workspace" "$HOME_WS" "$(sidebar "$HOME_WS Alpha Bravo")"
"$KEEP" new Alpha >/dev/null 2>&1
sleep 3
"$KEEP" new Bravo >/dev/null 2>&1
wait_for "takes Bravo" 10
sleep 1
check "workspaces made after the app came up are in its sidebar, in the order they came" \
    "$HOME_WS Alpha Bravo" "$(sidebar "$HOME_WS Alpha Bravo")"
sleep 2
check "and windows.json has them before anybody quits" "$HOME_WS Alpha Bravo" "$(carried)"
kill_app

# ----------------------------- the app dies while the tabs are being put back
say ""
say "the app dies while the tabs are being put back, and they are made while it is down"
start_daemon
rm -f "$KEEP_STATE_DIR"/*.json
cat >"$KEEP_STATE_DIR/windows.json" <<'JSON'
{"0":{"x":200,"y":200,"width":1000,"height":640,"workspaces":["Delta","Echo"]}}
JSON
# An order in the format from before the daemon was named beside it, written
# under the last daemon: its ids are other tabs now.
printf '{"Delta":[2,1]}' >"$KEEP_STATE_DIR/tab-order.json"
touch -t 202001010000 "$KEEP_STATE_DIR/tab-order.json"
start_app
sleep 2
check "what the window carried and has not come back yet is still written down" \
    "Delta Echo $HOME_WS" "$(carried)"
kill_app
"$KEEP" new Echo >/dev/null 2>&1
"$KEEP" new Delta >/dev/null 2>&1
"$KEEP" new Delta >/dev/null 2>&1
start_app
check "made while the app was down, they are in its sidebar where they were" \
    "Delta Echo $HOME_WS" "$(sidebar "$HOME_WS Delta Echo")"
BIRTH=$(socket_birth)
printf '{"daemonStart":%s,"tabs":{"Delta\\u001f1":"d-um","Delta\\u001f2":"d-dois"},"workspaces":{}}' \
    "$BIRTH" >"$KEEP_STATE_DIR/names.json.tmp"
mv "$KEEP_STATE_DIR/names.json.tmp" "$KEEP_STATE_DIR/names.json"
sleep 4
check "an order in the old format from the last daemon did not put tab 2 first" "d-um" \
    "$(first_of d-um d-dois)"
kill_app

# --------------------------- a reboot, with the arrangement from before it
say ""
say "a reboot with a window remembered, workspaces put away, and names from the last daemon"
start_daemon
rm -f "$KEEP_STATE_DIR"/*.json
# Kept is where the window was left. Hidden was put away and must stay away,
# and so must Hidden2 when the restore makes it again. Stray is in no window
# and was put away by nobody: made by some script while the app was down.
"$KEEP" new Kept >/dev/null 2>&1
"$KEEP" new Hidden >/dev/null 2>&1
"$KEEP" new Stray >/dev/null 2>&1
cat >"$KEEP_STATE_DIR/windows.json" <<'JSON'
{"0":{"x":200,"y":200,"width":1000,"height":640,"workspaces":["Bravo","Kept","Alpha"],"tab":{"workspace":"Kept","root":1}}}
JSON
printf '["Hidden","Hidden2"]' >"$KEEP_STATE_DIR/put-away.json"
# Kept for a daemon that started at 1000: its ids are other tabs now.
printf '{"daemonStart":1000,"tabs":{"Alpha\\u001f1":"stale"},"workspaces":{}}' >"$KEEP_STATE_DIR/names.json"
printf '{"daemonStart":1000,"order":{"Alpha":[2,1]}}' >"$KEEP_STATE_DIR/tab-order.json"
ALL="Kept Hidden Hidden2 Stray Alpha Bravo Charlie quick"
start_app
check "the remembered workspace and the stray one are shown, the put-away one is not" \
    "Kept Stray" "$(sidebar "$ALL")"
"$KEEP" new Alpha >/dev/null 2>&1
"$KEEP" new Alpha >/dev/null 2>&1
sleep 3
"$KEEP" new Bravo >/dev/null 2>&1
"$KEEP" new Hidden2 >/dev/null 2>&1
"$KEEP" new quick >/dev/null 2>&1
sleep 3
"$KEEP" new Charlie >/dev/null 2>&1
wait_for "takes Charlie" 10
sleep 1
check "late workspaces land where the window had them, an unknown one at the end" \
    "Bravo Kept Alpha Stray Charlie" "$(sidebar "$ALL")"
check "nothing brought a put-away workspace back, nor the quick terminal's" "no no no" \
    "$(for w in Hidden Hidden2 quick; do grep -aq "takes $w," "$WORK/app.log" && printf 'yes ' || printf 'no '; done | sed 's/ $//')"

# Named from outside, the way the restore script names the tabs it puts back.
BIRTH=$(socket_birth)
printf '{"daemonStart":%s,"tabs":{"Alpha\\u001f1":"primeira","Alpha\\u001f2":"segunda"},"workspaces":{}}' \
    "$BIRTH" >"$KEEP_STATE_DIR/names.json.tmp"
mv "$KEEP_STATE_DIR/names.json.tmp" "$KEEP_STATE_DIR/names.json"
sleep 4
check "names written by somebody else show up without a relaunch" "yes yes" \
    "$(shows primeira) $(shows segunda)"
check "the tab order kept for the last daemon did not put tab 2 first" "primeira" \
    "$(first_of primeira segunda)"
check "the name kept for the last daemon never reached this one's tab" "no" "$(shows stale)"

# A writer that got the daemon wrong: refused whole, and the names given here
# are written back over it rather than forgotten.
printf '{"daemonStart":1000,"tabs":{"Alpha\\u001f1":"intrusa"},"workspaces":{}}' \
    >"$KEEP_STATE_DIR/names.json.tmp"
mv "$KEEP_STATE_DIR/names.json.tmp" "$KEEP_STATE_DIR/names.json"
sleep 4
check "names written for another daemon are refused, and ours stay" "no yes yes" \
    "$(shows intrusa) $(shows primeira) $(shows segunda)"
check "and ours are back on disk" "primeira" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tabs"].get("Alpha\u001f1", ""))' \
        "$KEEP_STATE_DIR/names.json" 2>/dev/null)"

# ---------------------------------------------------- the power goes out
say ""
say "the app dies with nothing written on the way out, and comes back"
sleep 2
kill_app
start_app
check "the arrangement survived the crash" "Bravo Kept Alpha Stray Charlie" "$(sidebar "$ALL")"
check "and so did the names" "yes yes" "$(shows primeira) $(shows segunda)"

stop_app
say ""
say "passed $PASSED, failed $FAILED"
[ "$FAILED" -eq 0 ]
