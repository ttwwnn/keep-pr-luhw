# Kills that cannot reach past the test that made them.
#
# Sourced by the test scripts. Every one of these exists because the blunt
# version of it went wrong: `pkill -x cat` took every cat on the machine,
# including one in a shell of the person's own; `pkill -f "keep keys --tab"`
# took their attached sessions; `pkill -f keepd` took the daemon holding all
# of their work, which is the one process here that is meant to outlive
# everything else.
#
# The rule these follow: a test may kill what a test started, found by walking
# down from a pid it holds — never by matching a name against the whole
# machine.

# Every process descended from one, depth first.
descendants() {
    local pid=$1 kid
    for kid in $(pgrep -P "$pid" 2>/dev/null); do
        printf '%s\n' "$kid"
        descendants "$kid"
    done
}

# Kill descendants of $1 whose command line matches $2. Nothing outside that
# tree is a candidate, whatever it is called.
kill_descendants_matching() {
    local root=$1 pattern=$2 pid command
    for pid in $(descendants "$root"); do
        command=$(ps -o command= -p "$pid" 2>/dev/null) || continue
        case "$command" in
            *"$pattern"*) kill "$pid" 2>/dev/null ;;
        esac
    done
}

# Refuse to run against the daemon the person is actually using.
#
# Every one of these tests stands up a daemon of its own on a scratch socket,
# and each does it by exporting KEEP_SOCKET before starting anything. If that
# export were ever missed, the test would quietly drive the real daemon and
# then kill it on the way out.
require_scratch_socket() {
    local real
    real="${TMPDIR:-/tmp}/keep-${USER:-default}.sock"
    real=${real//\/\//\/}
    if [ -z "${KEEP_SOCKET:-}" ]; then
        printf '%s\n' "refusing to run: KEEP_SOCKET is not set, so this would use the real daemon"
        exit 1
    fi
    if [ "$KEEP_SOCKET" = "$real" ]; then
        printf '%s\n' "refusing to run: KEEP_SOCKET is the real daemon's socket"
        exit 1
    fi
}

# Kept for the tools that still drive the real app: give it back, pointed at
# the person's own daemon. The test suites no longer need it — they drive a
# build of their own and never take the person's away in the first place.
restore_app() {
    local bundle=$1
    ( unset KEEP_SOCKET KEEP_TRACE KEEP_STATE_DIR KEEP_APP_NAME \
        KEEP_AI_USAGE_HOME KEEP_AI_USAGE_CLAUDE_URL KEEP_AI_USAGE_CODEX_URL
      open "$bundle" >/dev/null 2>&1 ) &
}

# A test build reads no logins. The sidebar's usage footer asks the real AI
# services with the real tokens it finds in this home, and every suite that
# opens KeepDev would otherwise do that on each launch. An empty place to look
# in; the footer's own test points it at a made-up home instead.
export KEEP_AI_USAGE_HOME="${KEEP_AI_USAGE_HOME:-/var/empty}"

# Put the client and daemon that were just built inside the app bundle.
#
# The app runs `Contents/Resources/keep`, not the one in `target/`, and
# nothing in the Xcode build copies it there. So a test that carefully builds
# the client and then starts the app is testing whichever client was last
# copied in by hand — which, when this was written, was three days old and had
# none of the behaviour under test. The copy invalidates the bundle's
# signature, hence the re-sign.
bundle_binaries() {
    local bundle=$1
    # A freshly built bundle has no Resources at all — the directory exists in
    # the one people have been using only because somebody made it by hand.
    mkdir -p "$bundle/Contents/Resources" || return 1
    cp target/release/keep target/release/keepd "$bundle/Contents/Resources/" || return 1
    # The binaries first, then the bundle. Signing only the bundle leaves the
    # nested executables carrying whatever signature they were built with,
    # and macOS answers a mismatch with SIGKILL on exec — which surfaces as
    # "Ghostty failed to launch the requested command" the first time a new
    # tab spawns a client from the freshly copied file.
    codesign --force --sign - "$bundle/Contents/Resources/keep" >/dev/null 2>&1
    codesign --force --sign - "$bundle/Contents/Resources/keepd" >/dev/null 2>&1
    codesign --force --deep --sign - "$bundle" >/dev/null 2>&1
}

# The app a test drives, and its name to the window server.
#
# Not the one somebody is working in. The suites take the app away, kill it,
# drag its windows about and quit it — all of which is fine done to a build of
# their own, and none of which is fine done to the app holding somebody's
# afternoon. The two are told apart by name: this build is KeepDev, theirs is
# Keep, and every kill, every `frontmost`, and every window the mouse tool
# counts goes by the name exported here.
dev_app() { printf '%s\n' "apps/macos/build-dev/Build/Products/Debug/KeepDev.app"; }
app_name() { basename "${1:-$(dev_app)}" .app; }

# Take the test build away, and be sure it is actually gone.
#
# `pkill` returns before the app has finished dying, and an app that is still
# on screen when the next one starts takes the focus with it — so the
# keystrokes a test believes it is sending to its own window go to the one
# that is on its way out. What that looks like from outside is a check
# failing for no reason, which is how it was found.
stop_app() {
    local name=${KEEP_APP_NAME:-KeepDev}
    pkill -x "$name" 2>/dev/null
    local waited=0
    while pgrep -x "$name" >/dev/null 2>&1 && [ "$waited" -lt 20 ]; do
        sleep 0.5
        waited=$((waited + 1))
        pkill -x "$name" 2>/dev/null
    done
    # A late `open` from the test before this one still has a moment to fire.
    sleep 2
    pkill -x "$name" 2>/dev/null
    sleep 1
}

# Put the test's window somewhere a pointer can reach it.
#
# A tiling window manager keeps the windows of workspaces you are not looking
# at parked off the edge of the display. They are still listed by the window
# server and still have a position, so a test finds one, does its arithmetic
# and clicks the desktop — reporting, quite reasonably, that the row is not
# where it said it would be. Under AeroSpace a new app lands wherever its
# rules put it, and a build named for testing is in nobody's rules.
#
# So the test asks the window manager, in its own language, to bring its
# window to whichever workspace is being looked at. Nothing else is moved.
place_on_screen() {
    command -v aerospace >/dev/null 2>&1 || return 0
    local name=${KEEP_APP_NAME:-KeepDev} focused id
    focused=$(aerospace list-workspaces --focused 2>/dev/null) || return 0
    id=$(aerospace list-windows --all --format '%{window-id} %{app-name}' 2>/dev/null \
        | awk -v n="$name" '$2 == n { print $1; exit }')
    [ -n "$id" ] || return 0
    aerospace move-node-to-workspace --window-id "$id" "$focused" >/dev/null 2>&1
    sleep 1
}

# Whether somebody else is deciding where windows go.
#
# Under a tiling window manager a window that is dragged is put straight back,
# and often cannot be moved at all — so "did the window move" stops being a
# question about the app. Checks that turn on it say so and ask a narrower
# one instead of failing for a reason that is nobody's defect.
tiling_manager() { pgrep -x AeroSpace >/dev/null 2>&1 || pgrep -x yabai >/dev/null 2>&1; }
