#!/usr/bin/env bash
#
# Files dragged onto a terminal type their paths, from outside the app.
#
# A drag is started by a real press in another app's window and let go over
# KeepDev's terminal, with the pointer moved by the window server
# (tools/mousedrag.swift) — so what is under test includes AppKit handing the
# drop to the terminal, not only what the terminal does with it. The tab runs
# a recorder in place of a shell: it asks for bracketed paste, as Claude Code
# and zsh do, and writes down every byte that reaches it.
#
#   tools/drop-test.sh
#
# Checked:
#   - files that exist: their paths, escaped, one bracketed paste with a space
#     at its end;
#   - text, which is what the sidebar drags its rows as: refused, nothing typed;
#   - a file an app promises (Mail's attachments): written to a folder of its
#     own, then its path typed;
#   - the escaping itself, on names with every character a shell reads.
#
# It takes the pointer for a few seconds, three times. Your app and your
# daemon are never touched.

set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/scratch.sh
. tools/scratch.sh

APP=$(dev_app)
APP_NAME=$(app_name "$APP")
export KEEP_APP_NAME=$APP_NAME
BIN=$APP/Contents/MacOS/$APP_NAME
SOCKET=/tmp/keep-drop-$$.sock
WORK=$(mktemp -d /tmp/keep-drop-XXXXXX)
MOUSE=$WORK/mousedrag
SOURCE=$WORK/dragsource
RECORDED=$WORK/recorded
PASSED=0
FAILED=0

cleanup() {
    [ -n "${SOURCE_PID:-}" ] && kill "$SOURCE_PID" 2>/dev/null
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
swiftc -O tools/mousedrag.swift -o "$MOUSE" 2>/dev/null || { say "could not build mousedrag"; exit 1; }
swiftc -O tools/dragsource.swift -o "$SOURCE" 2>/dev/null || { say "could not build dragsource"; exit 1; }

# ------------------------------------------------------------ the escaping
say ""
say "the escaping, on its own"
cat >"$WORK/main.swift" <<'SWIFT'
for path in CommandLine.arguments.dropFirst() { print(DroppedFiles.escape(path)) }
print(DroppedFiles.text(for: ["/a b", "/c"]))
SWIFT
swiftc apps/macos/Sources/Keep/Display/DroppedFiles.swift "$WORK/main.swift" -o "$WORK/escape" 2>/dev/null \
    || { say "could not build the escaping"; exit 1; }
ESCAPED=$("$WORK/escape" '/plain/path.png' "/it's (a) [b] {c} <d> \"e\" \`f\` !g #h \$i &j ;k |l *m ?n ^o" \
    '/back\slash' $'/tab\there' '/ação é.png')
check "every character a shell reads is escaped, nothing else is" \
    "/plain/path.png
/it\\'s\\ \\(a\\)\\ \\[b\\]\\ \\{c\\}\\ \\<d\\>\\ \\\"e\\\"\\ \\\`f\\\`\\ \\!g\\ \\#h\\ \\\$i\\ \\&j\\ \\;k\\ \\|l\\ \\*m\\ \\?n\\ \\^o
/back\\\\slash
/tab\\$(printf '\t')here
/ação\\ é.png
/a\\ b /c" "$ESCAPED"

# ------------------------------------------------------------ the app
export KEEP_SOCKET=$SOCKET
export KEEP_STATE_DIR=$WORK/state
mkdir -p "$KEEP_STATE_DIR"
require_scratch_socket
rm -f "$SOCKET"

# The tab's program: asks for bracketed paste and keeps every byte it is sent.
cat >"$WORK/recorder" <<PY
#!/usr/bin/env python3
import os, select, sys, time, tty
sys.stdout.write("recorder ready\r\n\x1b[?2004h")
sys.stdout.flush()
fd = sys.stdin.fileno()
tty.setraw(fd)
open("$RECORDED.ready", "w").close()
end = time.time() + 300
with open("$RECORDED", "ab", buffering=0) as out:
    while time.time() < end:
        if select.select([fd], [], [], 1)[0]:
            data = os.read(fd, 4096)
            if not data:
                break
            out.write(data)
PY
chmod +x "$WORK/recorder"
: >"$RECORDED"

SHELL="$WORK/recorder" ./target/release/keepd >"$WORK/daemon.log" 2>&1 &
DAEMON_PID=$!
sleep 1
./target/release/keep new drop >/dev/null 2>&1 || { say "could not make a workspace"; exit 1; }
cat >"$KEEP_STATE_DIR/windows.json" <<'JSON'
{"0":{"x":360,"y":160,"width":900,"height":560,"workspaces":["drop"],"tab":{"workspace":"drop","root":1}}}
JSON

stop_app
KEEP_TRACE=1 "$BIN" >"$WORK/app.log" 2>&1 &
APP_PID=$!
waited=0
while [ ! -e "$RECORDED.ready" ] && [ "$waited" -lt 60 ]; do sleep 0.25; waited=$((waited + 1)); done
sleep 3
place_on_screen
osascript -e "tell application \"System Events\" to set frontmost of process \"$APP_NAME\" to true" \
    >/dev/null 2>&1
sleep 1

read -r FX FY FW FH <<<"$("$MOUSE" frame)"
[ -n "${FH:-}" ] || { say "could not find $APP_NAME's window"; exit 1; }
# The terminal's middle, clear of the sidebar; the source to the left of it.
TX=$(( ${FX%.*} + ${FW%.*} * 2 / 3 ))
TY=$(( ${FY%.*} + ${FH%.*} / 2 ))
SX=$(( ${FX%.*} - 90 ))
[ "$SX" -gt 70 ] || SX=$(( ${FX%.*} + 70 ))
SY=$(( ${FY%.*} + 100 ))

# drop <kind> <args...>: drag from a fresh source onto the terminal; prints how it ended.
drop() {
    : >"$RECORDED"
    "$SOURCE" "$SX" "$SY" "$@" >"$WORK/source.out" 2>&1 &
    SOURCE_PID=$!
    local waited=0
    while ! grep -q ready "$WORK/source.out" && [ "$waited" -lt 40 ]; do sleep 0.25; waited=$((waited + 1)); done
    "$MOUSE" drag "$SX" "$SY" "$TX" "$TY" 30 15
    waited=0
    while ! grep -q ended "$WORK/source.out" && [ "$waited" -lt 40 ]; do sleep 0.25; waited=$((waited + 1)); done
    sleep 2
    grep -o 'ended [a-z]*' "$WORK/source.out"
}
recorded() { python3 -c 'import sys; print(repr(open(sys.argv[1], "rb").read()))' "$RECORDED"; }

# ------------------------------------------------------------ files
say ""
say "files that exist"
mkdir -p "$WORK/files"
A="$WORK/files/a b.txt"
C="$WORK/files/c(1)'x.png"
: >"$A"
: >"$C"
check "the drop is taken" "ended copy" "$(drop files "$A" "$C")"
# Written out, not asked of the escaping under test: $WORK is letters and
# digits, so only the names need it.
WANT=$(python3 -c 'import sys; w = sys.argv[1]; print(repr(("\x1b[200~" + w + "/files/a\\ b.txt " + w
    + "/files/c\\(1\\)\\\x27x.png \x1b[201~").encode()))' "$WORK")
check "their paths arrive escaped, as one bracketed paste ending in a space" "$WANT" "$(recorded)"

# ------------------------------------------------------------ text
say ""
say "text, as the sidebar drags its rows"
check "the drop is refused" "ended none" "$(drop text 'tab:drop:1')"
check "nothing is typed" "b''" "$(recorded)"

# ------------------------------------------------------------ a promise
say ""
say "a file an app promises to write"
check "the drop is taken" "ended copy" "$(drop promise 'prometido.txt' 'conteúdo')"
GOT=$(python3 -c 'import sys; print(open(sys.argv[1], "rb").read().decode())' "$RECORDED")
PROMISED=$(printf '%s' "$GOT" | sed -E $'s/^\x1b\\[200~//; s/ \x1b\\[201~$//')
check "a path in a folder of its own for the drop arrives, bracketed, ending in a space" "yes" \
    "$(printf '%s' "$GOT" | grep -qE $'^\x1b\\[200~/.*/keep-drops/[0-9A-F-]+/prometido\\.txt \x1b\\[201~$' && echo yes || echo no)"
check "and the file is there, with what was promised" "conteúdo" "$(cat "$PROMISED" 2>/dev/null)"

stop_app
say ""
say "passed $PASSED, failed $FAILED"
[ "$FAILED" -eq 0 ]
