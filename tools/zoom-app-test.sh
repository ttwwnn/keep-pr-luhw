#!/usr/bin/env bash
#
# The zoom above the sidebar (UI/ZoomControl.swift), in the app: its buttons,
# its chords and its menu items change the size of every tab's text, step by
# Chrome's steps; it stops at 50% and at 300%, the View menu greyed there and
# the chord going no further than the terminal; it tells no program the
# colours changed; it goes with a shut sidebar, loses its percentage in a
# narrow one, opens next time at the size it was left at, and takes for 100%
# the size the person's own config gives, from whichever file.
#
# What is measured is what the zoom is for: the size the app writes down
# (terminal.json, in a state directory of the test's own) and the columns and
# rows the daemon was given for the tab — a larger text is a smaller grid —
# and a tab off screen keeps the grid its program draws for until it is
# shown. The visible title frames in both tab lists must grow and shrink
# too, and the row of tabs with them.
#
#   tools/zoom-app-test.sh            (SKIP_BUILD=1 to use the KeepDev built last;
#                                      KEEP_TEST_APP=<path to an .app> to drive another build)
#
# No mouse: the buttons and menu items are pressed through the accessibility
# tree (tools/axpress.swift), the chords posted to the app's pid alone
# (tools/sendkey.swift) — which reach its terminal as well as its menu, in
# front or not — and the front is handed back to whatever had it at each
# launch, so the test runs behind the app you are working in. Your app, its
# daemon and its settings are never touched.

set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/scratch.sh
. tools/scratch.sh

APP=${KEEP_TEST_APP:-$(dev_app)}
APP_NAME=$(app_name "$APP")
export KEEP_APP_NAME=$APP_NAME
BIN=$APP/Contents/MacOS/$APP_NAME
SOCKET=/tmp/keep-zoom-$$.sock
WORK=$(mktemp -d /tmp/keep-zoom-app-XXXXXX)
AXPRESS=$WORK/axpress
SENDKEY=$WORK/sendkey
STATE=$WORK/state
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

if [ -z "${KEEP_TEST_APP:-}" ] && [ -z "${SKIP_BUILD:-}" ]; then
    say "building $APP_NAME (yours is left alone)"
    ./tools/build-dev.sh >/dev/null || { say "could not build $APP_NAME — run tools/build-dev.sh"; exit 1; }
fi
swiftc -O tools/axpress.swift -o "$AXPRESS" 2>/dev/null || { say "could not build axpress"; exit 1; }
swiftc -O tools/sendkey.swift -o "$SENDKEY" 2>/dev/null || { say "could not build sendkey"; exit 1; }

export KEEP_SOCKET=$SOCKET
export KEEP_STATE_DIR=$STATE
export KEEP_WORKTREES_BIN=/var/empty
mkdir -p "$STATE"
require_scratch_socket
rm -f "$SOCKET"
"$APP/Contents/Resources/keepd" >"$WORK/daemon.log" 2>&1 &
DAEMON_PID=$!
waited=0
while [ ! -S "$SOCKET" ] && [ "$waited" -lt 40 ]; do sleep 0.25; waited=$((waited + 1)); done

# Started, waited for, and put behind whatever was in front before it.
FRONT=
launch() {
    FRONT=$(osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null)
    : >"$WORK/app.log"
    KEEP_TRACE=1 "$BIN" >"$WORK/app.log" 2>&1 &
    APP_PID=$!
    local waited=0
    while ! grep -aqE "sidebar +order" "$WORK/app.log" && [ "$waited" -lt 120 ]; do
        sleep 0.25; waited=$((waited + 1))
    done
    sleep 1.5
    give_back
}
give_back() {
    if [ -n "$FRONT" ] && [ "$FRONT" != "missing value" ]; then
        osascript -e "tell application id \"$FRONT\" to activate" >/dev/null 2>&1
    fi
}
quit_app() {
    kill "$APP_PID" 2>/dev/null
    local waited=0
    while kill -0 "$APP_PID" 2>/dev/null && [ "$waited" -lt 40 ]; do sleep 0.25; waited=$((waited + 1)); done
    APP_PID=
}

stop_app
launch

# Asked of the accessibility tree, which gives the app a second to answer
# (tools/axpress.swift): under load an answer can be late, so a read that
# came back with nothing is asked again before it is believed.
ask() {  # ask <axpress arguments...>: its answer, or "(none)" after eight tries
    local tries=0 got
    while [ "$tries" -lt 8 ]; do
        got=$("$AXPRESS" "$APP_NAME" "$@" 2>/dev/null) && { printf '%s\n' "$got"; return; }
        tries=$((tries + 1)); sleep 0.5
    done
    echo "(none)"
}
level() { ask title keep.zoom.reset; }
enabled() { ask enabled "$1"; }
item() { "$AXPRESS" "$APP_NAME" menuenabled View "$1" 2>/dev/null || echo "(none)"; }
# Whether an item of the View menu can be chosen, once AppKit has caught up:
# it works the menu out again a moment after a change (within a second,
# measured), not at the change. Opened by hand, a menu is worked out as it
# opens; read or pressed through the accessibility tree, it is whatever it
# was last — Actual Size, greyed at 100%, was still greyed just after 110%.
item_is() {  # item_is <item> <0|1>: what it says, waiting up to 3 s for <0|1>
    local waited=0 got
    while got=$(item "$1"); [ "$got" != "$2" ] && [ "$waited" -lt 12 ]; do
        sleep 0.25; waited=$((waited + 1))
    done
    printf '%s\n' "$got"
}
choose() { item_is "$1" 1 >/dev/null; menu_until View "$1" "$2" level; }  # choose <item> <percentage it gives>
# Whether something is on screen: yes, no — or "(silent)" when the tree did
# not answer at all, which is not a no.
present() {
    "$AXPRESS" "$APP_NAME" frame "$1" >/dev/null 2>&1 && { echo yes; return; }
    [ "$(ask frame "Toggle Sidebar")" = "(none)" ] && { echo "(silent)"; return; }
    "$AXPRESS" "$APP_NAME" frame "$1" >/dev/null 2>&1 && echo yes || echo no
}
# Where an element begins and ends across, from "x y w h"; nothing when the
# tree did not say, so that no comparison is made with an empty number.
left_of() { local x y w h; read -r x y w h <<<"$(ask frame "$1")"; [ -n "$h" ] && echo "$x"; }
right_of() { local x y w h; read -r x y w h <<<"$(ask frame "$1")"; [ -n "$h" ] && echo $((x + w)); }
title_heights() {
    local id="$TITLE_WORKSPACE/${1:-1}" x y w h
    read -r x y w h <<<"$(ask frame "sidebar-title-$id")"
    printf '%s ' "${h:-0}"
    read -r x y w h <<<"$(ask frame "strip-title-$id")"
    printf '%s\n' "${h:-0}"
}
titles_resized() {  # titles_resized <old heights> <-gt|-lt> [tab]
    local old_side old_strip side strip
    read -r old_side old_strip <<<"$1"
    read -r side strip <<<"$(title_heights "${3:-1}")"
    [ "$old_side" -gt 0 ] && [ "$old_strip" -gt 0 ] \
        && [ "$side" -gt 0 ] && [ "$strip" -gt 0 ] \
        && [ "$side" "$2" "$old_side" ] && [ "$strip" "$2" "$old_strip" ] \
        && echo yes || echo no
}
title_fits_strip() {
    local x y w h tx ty tw th
    read -r x y w h <<<"$(ask frame "strip-tab-$TITLE_WORKSPACE/1")"
    read -r tx ty tw th <<<"$(ask frame "strip-title-$TITLE_WORKSPACE/1")"
    [ "${th:-0}" -gt 0 ] && [ "${tw:-0}" -gt 0 ] \
        && [ "$ty" -ge "$y" ] && [ $((ty + th)) -le $((y + h)) ] \
        && echo yes || echo no
}
row_height() { local x y w h; read -r x y w h <<<"$(ask frame "strip-tab-$TITLE_WORKSPACE/1")"; echo "${h:-0}"; }
# The grid the surface of a tab off screen shows, read off the terminal its
# client runs in: the one client whose `showing` file says 0. What the daemon
# gave the tab is `grid`. The two part when a hidden tab's text takes a step
# of the zoom its program was never told of — the program goes on drawing
# for the old grid, into the new one, and the tab is garbage when it is
# shown again.
hidden_grid() {
    local pid dir tty
    for pid in $(descendants "$APP_PID"); do
        case "$(ps -o command= -p "$pid" 2>/dev/null)" in -*/keep) ;; *) continue ;; esac
        dir=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
        [ "$(cat "$dir/showing" 2>/dev/null)" = 0 ] || continue
        tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        python3 -c 'import fcntl, os, struct, sys, termios
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
rows, cols = struct.unpack("HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, bytes(8)))[:2]
print("%dx%d" % (cols, rows))' "/dev/$tty"
        return
    done
    echo "(none)"
}
before() {  # before <a> <b>: yes when a ends at or before b begins
    local a b
    a=$(right_of "$1"); b=$(left_of "$2")
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -le "$b" ] && echo yes || echo no
}
written() {  # the size the app wrote down, or "none"
    python3 -c 'import json, sys
try: print(json.load(open(sys.argv[1])).get("fontSize", "none"))
except FileNotFoundError: print("none")' "$STATE/terminal.json"
}
grid() {  # grid <tab>: "colsxrows" the daemon was given for it
    "$APP/Contents/Resources/keep" ls 2>/dev/null \
        | sed -nE "s/^ +tab $1 .* ([0-9]+x[0-9]+) .*/\\1/p" | head -1
}
cols() { grid "$1" | cut -dx -f1; }
screen() {  # screen <tab>: what the daemon holds on that tab's screen
    python3 tools/screen.py "$("$APP/Contents/Resources/keep" ls 2>/dev/null | awk 'NR == 1 { print $1 }')" "$1" 2>/dev/null
}
# A change reaches the daemon a moment after the app makes it: wait for the
# tab's grid to stop being $2, a few seconds at most.
grid_leaves() {  # grid_leaves <tab> <grid>
    local waited=0
    while [ "$(grid "$1")" = "$2" ] && [ "$waited" -lt 20 ]; do sleep 0.25; waited=$((waited + 1)); done
    sleep 0.3
}
grid_is() {  # grid_is <tab> <grid>
    local waited=0
    while [ "$(grid "$1")" != "$2" ] && [ "$waited" -lt 20 ]; do sleep 0.25; waited=$((waited + 1)); done
}
grid_settles() {  # grid_settles <tab>: the grid, once two reads half a second apart agree
    local now then waited=0
    then=$(grid "$1")
    while :; do
        sleep 0.5; now=$(grid "$1")
        [ "$now" = "$then" ] || [ "$waited" -ge 20 ] && break
        then=$now; waited=$((waited + 1))
    done
    printf '%s\n' "$now"
}
# A press waited on until what it does shows (until <command> prints <value>),
# and made again if it never does — a press can be dropped as a read can. Not
# twice for one: the second only once the first has had five seconds to show.
press_until() {  # press_until <label> <value> <command...>
    local label=$1 want=$2 tries=0 waited
    shift 2
    while [ "$tries" -lt 3 ]; do
        "$AXPRESS" "$APP_NAME" press "$label" >/dev/null 2>&1
        waited=0
        while [ "$("$@")" != "$want" ] && [ "$waited" -lt 20 ]; do sleep 0.25; waited=$((waited + 1)); done
        [ "$("$@")" = "$want" ] && { sleep 0.3; return 0; }
        tries=$((tries + 1))
    done
    return 1
}
# One step of the zoom by its button, to the percentage it should give.
step() { press_until "$1" "$2" level; }
menu_until() {  # menu_until <menu> <item> <value> <command...>
    local menu=$1 entry=$2 want=$3 tries=0 waited
    shift 3
    while [ "$tries" -lt 3 ]; do
        "$AXPRESS" "$APP_NAME" menu "$menu" "$entry" >/dev/null 2>&1
        waited=0
        while [ "$("$@")" != "$want" ] && [ "$waited" -lt 20 ]; do sleep 0.25; waited=$((waited + 1)); done
        [ "$("$@")" = "$want" ] && { sleep 0.3; return 0; }
        tries=$((tries + 1))
    done
    return 1
}
tabs() { "$APP/Contents/Resources/keep" ls 2>/dev/null | grep -cE '^ +tab [0-9]+'; }
chord() { "$SENDKEY" "$APP_PID" key "$@"; sleep 0.6; }
palette() {  # palette <filter>: run the palette's first command for it
    "$SENDKEY" "$APP_PID" key 35 shift cmd; sleep 0.8   # ⌘⇧P
    "$SENDKEY" "$APP_PID" text "$1"; sleep 0.6
    "$SENDKEY" "$APP_PID" key 36; sleep 0.8              # return
}

say ""
say "the zoom, above the sidebar"
check "it says 100%" "100%" "$(level)"
check "larger can be pressed" 1 "$(enabled keep.zoom.in)"
check "smaller can be pressed" 1 "$(enabled keep.zoom.out)"
check "View: Zoom In and Zoom Out can be chosen, Actual Size is greyed" "1 1 0" \
    "$(item_is "Zoom In" 1) $(item_is "Zoom Out" 1) $(item_is "Actual Size" 0)"
check "it ends before the toggle" yes "$(before keep.zoom.in "Toggle Sidebar")"
BASE=$(grid 1)
TITLE_WORKSPACE=$("$APP/Contents/Resources/keep" ls 2>/dev/null | awk 'NR == 1 { print $1 }')
TITLES100=$(title_heights)
ROW100=$(row_height)
say "        (tab 1 at 100%: $BASE)"
say "        (sidebar and strip title heights: $TITLES100)"
check "the title fits its tab at 100%" yes "$(title_fits_strip)"

say ""
say "the buttons"
step keep.zoom.in 110%; grid_leaves 1 "$BASE"
check "+ says 110%" "110%" "$(level)"
check "+ writes 110% of 13 points" 14.3 "$(written)"
AT110=$(grid 1)
check "+ gives the tab fewer columns" yes "$([ "$(cols 1)" -lt "${BASE%x*}" ] && echo yes || echo no)"
check "+ enlarges both tab titles" yes "$(titles_resized "$TITLES100" -gt)"
TITLES110=$(title_heights)
step keep.zoom.out 100%; grid_is 1 "$BASE"; step keep.zoom.out 90%; grid_leaves 1 "$BASE"
check "- twice says 90%" "90%" "$(level)"
check "- twice writes 11.7" 11.7 "$(written)"
check "- gives it more columns than at 100%" yes "$([ "$(cols 1)" -gt "${BASE%x*}" ] && echo yes || echo no)"
# SwiftUI reports the sidebar's title with its row's frame, and the row keeps
# a floor below 100% (the close button's room, the marks beside the title):
# so 90% is compared with 110%, in both lists.
check "- reduces both tab titles from 110%" yes "$(titles_resized "$TITLES110" -lt)"
AT90=$(grid 1)
step keep.zoom.reset 100%; grid_leaves 1 "$AT90"
check "the percentage goes back to 100%" "100%" "$(level)"
check "and writes nothing down" none "$(written)"
check "and the tab is as it was" "$BASE" "$(grid 1)"
check "and both titles return to their original height" "$TITLES100" "$(title_heights)"

say ""
say "the chords, posted to the app alone"
chord 24 cmd; grid_leaves 1 "$BASE"
check "⌘= zooms in" "110% $AT110" "$(level) $(grid 1)"
chord 27 cmd; grid_leaves 1 "$AT110"
check "⌘- zooms out" "100% $BASE" "$(level) $(grid 1)"
chord 24 shift cmd; grid_leaves 1 "$BASE"
check "⌘+ zooms in" "110% $AT110" "$(level) $(grid 1)"
chord 29 cmd; grid_leaves 1 "$AT110"
check "⌘0 goes back to 100%" "100% $BASE" "$(level) $(grid 1)"

say ""
say "the View menu"
choose "Zoom In" 110%; grid_leaves 1 "$BASE"
check "Zoom In" "110% $AT110" "$(level) $(grid 1)"
choose "Actual Size" 100%; grid_leaves 1 "$AT110"
check "Actual Size" "100% $BASE" "$(level) $(grid 1)"

say ""
say "every tab, not the one on screen"
menu_until File "New Tab" 2 tabs; sleep 1.5
check "a second tab opens at 100%" "$BASE" "$(grid 2)"
step keep.zoom.in 110%; grid_leaves 2 "$BASE"
check "+ on the second tab" "$AT110" "$(grid 2)"
check "both titles of the second tab enlarge" yes "$(titles_resized "$TITLES100" -gt 2)"
check "the first, off screen, keeps the grid its program draws for" "$BASE $BASE" \
    "$(grid 1) $(hidden_grid)"
menu_until Window "Show Tab 1" "$AT110" grid 1
check "the first tab is at 110% when it is shown" "$AT110" "$(grid 1)"
step keep.zoom.reset 100%; grid_leaves 1 "$AT110"
check "and the second, off screen now, keeps its own" "$AT110 $AT110" "$(grid 2) $(hidden_grid)"

say ""
say "the ends: 300% and 50%"
walked=yes
for to in 110% 125% 150% 175% 200% 250% 300%; do
    step keep.zoom.in "$to" || walked="no: stopped short of $to"
done
check "each press of + is the next step" yes "$walked"
grid_leaves 1 "$BASE"
check "seven steps up is 300%" "300%" "$(level)"
check "39 points written" 39 "$(written)"
check "300% enlarges both titles beyond 110%" yes "$(titles_resized "$TITLES110" -gt)"
check "the enlarged title fits its tab at 300%" yes "$(title_fits_strip)"
check "and the row grows to hold it" yes "$([ "$(row_height)" -gt "$ROW100" ] && echo yes || echo no)"
check "larger cannot be pressed" 0 "$(enabled keep.zoom.in)"
check "View: Zoom In is greyed, Actual Size can be chosen" "0 1" \
    "$(item_is "Zoom In" 0) $(item_is "Actual Size" 1)"
AT300=$(grid_settles 1)
# A greyed item hands its chord on to the terminal, where libghostty binds it
# to the size of the pane alone — and a pane sized so stops following the
# zoom — unless the terminal's view keeps it back (`isZoomChord`). First that
# what is posted here reaches the terminal at all, or the checks after it
# test nothing: typed text does, to the shell's command line.
"$SENDKEY" "$APP_PID" text "zoomprobe"; sleep 1
check "what is typed reaches the terminal" yes "$(screen 1 | grep -q zoomprobe && echo yes || echo no)"
chord 32 ctrl   # ⌃U: the probe off the command line
# And the shell asks to be told when the ground goes light or dark, as
# Claude Code does (mode 2031): see "no step of the zoom" below.
"$SENDKEY" "$APP_PID" text "printf '\\033[?2031h'"; "$SENDKEY" "$APP_PID" key 36; sleep 1.5
TOLD_FROM=$(wc -l <"$WORK/app.log")
chord 24 cmd; sleep 1
check "⌘= at 300% does not reach the pane" "300% $AT300" "$(level) $(grid 1)"
# libghostty binds nothing to ⌘⇧= of its own, so this one is the menu's
# end alone; the config.ghostty section below gives the pane a binding for it.
chord 24 shift cmd; sleep 1
check "⌘+ at 300% goes no further" "300% $AT300" "$(level) $(grid 1)"
walked=yes
for to in 250% 200% 175% 150% 125% 110% 100% 90% 80% 75% 67% 50%; do
    step keep.zoom.out "$to" || walked="no: stopped short of $to"
done
check "each press of - is the next step" yes "$walked"
grid_leaves 1 "$AT300"
check "twelve steps down is 50%" "50%" "$(level)"
check "50% reduces both titles below 110%" yes "$(titles_resized "$TITLES110" -lt)"
check "smaller cannot be pressed" 0 "$(enabled keep.zoom.out)"
check "View: Zoom Out is greyed" 0 "$(item_is "Zoom Out" 0)"
AT50=$(grid_settles 1)
chord 27 cmd; sleep 1
check "⌘- at 50% does not reach the pane" "50% $AT50" "$(level) $(grid 1)"
chord 29 cmd; grid_leaves 1 "$AT50"
check "⌘0 from 50%" "100% $BASE" "$(level) $(grid 1)"
check "View: Actual Size is greyed again" 0 "$(item_is "Actual Size" 0)"
chord 29 cmd; sleep 1
check "⌘0 at 100% does not reach the pane" "100% $BASE" "$(level) $(grid 1)"

say ""
say "the palette's Bigger and Smaller text take the same steps"
palette "bigger text"; grid_leaves 1 "$BASE"
check "Bigger text" "110% 14.3" "$(level) $(written)"
palette "smaller text"; grid_leaves 1 "$AT110"
check "Smaller text" "100% none" "$(level) $(written)"

say ""
say "no step of the zoom tells a program the ground changed"
# A ground said to have changed is told to every program that asked
# (`tellScheme`, a second after). Fifteen steps since the shell asked — the
# buttons, ⌘0, the palette — and not one of them a change of colour.
sleep 2
check "the shell that asked was told nothing" 0 \
    "$(tail -n +"$((TOLD_FROM + 1))" "$WORK/app.log" | grep -ac 'scheme .* told')"

say ""
say "a shut sidebar takes the zoom with it"
press_until "Toggle Sidebar" no present keep.zoom.out
check "shut: no zoom" "no no no" "$(present keep.zoom.out) $(present keep.zoom.reset) $(present keep.zoom.in)"
# Where the toggle sits with nothing to ride: hard against the traffic
# lights. The zoom may never come nearer them than this.
home=$(left_of "Toggle Sidebar")
press_until "Toggle Sidebar" yes present keep.zoom.out
check "open again: the zoom is back" "yes yes yes" "$(present keep.zoom.out) $(present keep.zoom.reset) $(present keep.zoom.in)"

say ""
say "the next launch opens at the size it was left at"
step keep.zoom.in 110%; grid_leaves 1 "$BASE"
quit_app
launch
grid_is 1 "$AT110"
check "it says 110%" "110%" "$(level)"
check "both titles keep their zoom after relaunch" "$TITLES110" "$(title_heights)"
check "and the tab has 110%'s grid" "$AT110" "$(grid 1)"

say ""
say "a narrow sidebar keeps the buttons and drops the percentage"
quit_app
python3 - "$STATE/sidebar-state.json" <<'PY'
import json, os, sys
state = (json.load(open(sys.argv[1])) if os.path.exists(sys.argv[1])
         else {"0": {"folded": [], "isCollapsed": False, "verticalTabs": False}})
for window in state.values():
    window["width"] = 200
    window["isCollapsed"] = False
json.dump(state, open(sys.argv[1], "w"))
PY
launch
check "200 points wide: smaller, larger, no percentage" "yes yes no" \
    "$(present keep.zoom.out) $(present keep.zoom.in) $(present keep.zoom.reset)"
nx=$(left_of keep.zoom.out)
check "no nearer the traffic lights than the toggle's home" yes \
    "$([ -n "$nx" ] && [ -n "$home" ] && [ "$nx" -ge "$home" ] && echo yes || echo no)"
check "and still clear of the toggle" yes "$(before keep.zoom.in "Toggle Sidebar")"
# No percentage to watch here: what the press writes down is watched instead.
press_until keep.zoom.out none written
check "and they still zoom: smaller from 110% is 100%" none "$(written)"

say ""
say "100% is the size the person's config gives, in whichever file libghostty finds it"
quit_app
# A font-size in config.ghostty under XDG_CONFIG_HOME: one of the four files
# libghostty reads, and one a reading of ~/.config/ghostty/config alone never
# saw. Application Support is read after it and would win, so the section
# stands aside when that sets a size of its own.
SUPPORT="$HOME/Library/Application Support/com.mitchellh.ghostty"
if grep -qsE '^[[:space:]]*font-size[[:space:]]*=' "$SUPPORT/config" "$SUPPORT/config.ghostty"; then
    say "  skip  your Application Support config sets a font-size, which would win"
else
    mkdir -p "$WORK/xdg/ghostty"
    # And bindings of the person's own on every chord, on the keys rather
    # than the characters — which libghostty looks up first — and ten points
    # at a time, so no grid can hide them.
    printf '%s\n' "font-size = 16" \
        "keybind = super+equal=increase_font_size:10" \
        "keybind = super+shift+equal=increase_font_size:10" \
        "keybind = super+minus=decrease_font_size:10" \
        "keybind = super+digit_0=increase_font_size:10" \
        >"$WORK/xdg/ghostty/config.ghostty"
    rm -f "$STATE/terminal.json"
    python3 - "$STATE/sidebar-state.json" <<'INNER'
import json, os, sys
state = (json.load(open(sys.argv[1])) if os.path.exists(sys.argv[1])
         else {"0": {"folded": [], "isCollapsed": False, "verticalTabs": False}})
for window in state.values():
    window["width"] = 250
json.dump(state, open(sys.argv[1], "w"))
INNER
    export XDG_CONFIG_HOME=$WORK/xdg
    launch
    unset XDG_CONFIG_HOME
    check "16 points says 100%" "100%" "$(level)"
    check "and the app took 16 points for its own" yes \
        "$(grep -aqE 'terminal font: .*@16\.0pt \(own 16\.0pt\)' "$WORK/app.log" && echo yes || echo no)"
    AT16=$(grid 1)
    step keep.zoom.in 110%; grid_leaves 1 "$AT16"
    check "+ is 110% of 16" "110% 17.6" "$(level) $(written)"
    check "and the text grew: fewer columns" yes "$([ "$(cols 1)" -lt "${AT16%x*}" ] && echo yes || echo no)"
    walked=yes
    for to in 125% 150% 175% 200% 250% 300%; do
        step keep.zoom.in "$to" || walked="no: stopped short of $to"
    done
    check "up to 300% a step at a time" yes "$walked"
    AT300=$(grid_settles 1)
    chord 24 cmd; sleep 1
    check "their own ⌘= does not size the pane at 300%" "300% $AT300" "$(level) $(grid 1)"
    chord 24 shift cmd; sleep 1
    check "nor their own ⌘+" "300% $AT300" "$(level) $(grid 1)"
    walked=yes
    for to in 250% 200% 175% 150% 125% 110% 100% 90% 80% 75% 67% 50%; do
        step keep.zoom.out "$to" || walked="no: stopped short of $to"
    done
    check "down to 50% a step at a time" yes "$walked"
    AT50=$(grid_settles 1)
    chord 27 cmd; sleep 1
    check "nor their own ⌘- at 50%" "50% $AT50" "$(level) $(grid 1)"
    chord 29 cmd; grid_leaves 1 "$AT50"
    AT100=$(grid_settles 1)
    check "⌘0 is still the zoom's" "100% $AT16" "$(level) $AT100"
    chord 29 cmd; sleep 1
    check "nor their own ⌘0 at 100%" "100% $AT16" "$(level) $(grid 1)"
fi

say ""
say "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
