#!/usr/bin/env bash
#
# Closing a tab whose conversation made a worktree, clicked through in the app.
#
# tools/worktrees-test.sh proves Worktrees.swift on its own; this drives the
# whole of it in KeepDev: File > Close Tab, the question the app puts up with
# the worktree listed in it, and the two answers — Cancel, after which
# nothing may have moved and the helper may not have been asked to prepare
# anything, and Close Tab, after which the worktree is in the Trash and the
# helper was asked to prepare it before and to conclude after.
#
# The helper is the fake one (tools/worktrees-test/fake-helper.py): which
# worktrees a conversation made is the helper's to decide, and its own tests
# prove it. The worktree is a real one, in a repository made for the test,
# and goes to the real Trash under a name no one else uses; it is taken back
# out at the end.
#
#   tools/close-trash-test.sh          (SKIP_BUILD=1 to use the KeepDev built last)
#
# No mouse and no keys: the menu item and the buttons are pressed through the
# accessibility tree (tools/axpress.swift), the question read the same way
# (tools/axtext.swift). Your app and your daemon are never touched.

set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/scratch.sh
. tools/scratch.sh

APP=$(dev_app)
APP_NAME=$(app_name "$APP")
export KEEP_APP_NAME=$APP_NAME
BIN=$APP/Contents/MacOS/$APP_NAME
SOCKET=/tmp/keep-closetrash-$$.sock
WORK=$(mktemp -d /tmp/keep-closetrash-XXXXXX)
AXTEXT=$WORK/axtext
AXPRESS=$WORK/axpress
PASSED=0
FAILED=0
WT_NAME=keep-closetrash-wt-$$
WT=$WORK/$WT_NAME

cleanup() {
    [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null
    [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null
    rm -rf "$HOME/.Trash/$WT_NAME"
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

if [ -z "${SKIP_BUILD:-}" ]; then
    say "building $APP_NAME (yours is left alone)"
    ./tools/build-dev.sh >/dev/null || { say "could not build $APP_NAME — run tools/build-dev.sh"; exit 1; }
fi
swiftc -O tools/axtext.swift -o "$AXTEXT" 2>/dev/null || { say "could not build axtext"; exit 1; }
swiftc -O tools/axpress.swift -o "$AXPRESS" 2>/dev/null || { say "could not build axpress"; exit 1; }

# A repository of the test's own, and a worktree of it on a branch.
git init -q "$WORK/repo" && git -C "$WORK/repo" commit -q --allow-empty -m base \
    && git -C "$WORK/repo" worktree add -q -b test-branch "$WT" \
    || { say "could not make the test repository"; exit 1; }
echo "work" >"$WT/file.txt"

# The fake helper answers `listar` with that worktree.
cp tools/worktrees-test/fake-helper.py "$WORK/"
chmod +x "$WORK/fake-helper.py"
export KEEP_WORKTREES_BIN=$WORK/fake-helper.py
export FAKE_DIR=$WORK
python3 - "$WORK/listar.json" "$WT" <<'PY'
import json, sys
json.dump({"versao": 1, "abas": [{"alvo": "w:1", "pids": []}],
           "lixeira": [{"caminho": sys.argv[2], "ramo": "test-branch", "head": "abc1234",
                        "alteracoes": 1, "commits_so_aqui": 0, "processos": []}],
           "mantidas": [], "avisos": []}, open(sys.argv[1], "w"))
PY

export KEEP_SOCKET=$SOCKET
export KEEP_STATE_DIR=$WORK/state
mkdir -p "$KEEP_STATE_DIR"
require_scratch_socket
rm -f "$SOCKET"
"$APP/Contents/Resources/keepd" >"$WORK/daemon.log" 2>&1 &
DAEMON_PID=$!
waited=0
while [ ! -S "$SOCKET" ] && [ "$waited" -lt 40 ]; do sleep 0.25; waited=$((waited + 1)); done

stop_app
KEEP_TRACE=1 "$BIN" >"$WORK/app.log" 2>&1 &
APP_PID=$!
waited=0
while ! grep -aqE "sidebar +order" "$WORK/app.log" && [ "$waited" -lt 120 ]; do sleep 0.25; waited=$((waited + 1)); done
place_on_screen
sleep 2

asked() {  # the helper's calls, by their first word
    python3 -c 'import json,sys
try: print(" ".join(json.loads(l)["argv"][0] for l in open(sys.argv[1])))
except FileNotFoundError: print("")' "$WORK/calls.log"
}
question_up() {  # wait for the question naming the worktree
    local waited=0
    while [ "$waited" -lt 40 ]; do
        "$AXTEXT" "$APP_NAME" 2>/dev/null >"$WORK/ax.txt"
        grep -qF "goes to the Trash" "$WORK/ax.txt" && return 0
        sleep 0.25
        waited=$((waited + 1))
    done
    return 1
}

say ""
say "the question, and Cancel"
"$AXPRESS" "$APP_NAME" menu File "Close Tab"
check "File > Close Tab puts up a question naming the worktree" yes "$(question_up && echo yes || echo no)"
check "it says where the worktree is" yes "$(grep -qF "$WT_NAME (branch test-branch; 1 file changed)" "$WORK/ax.txt" && echo yes || echo no)"
check "and how to get it back" yes "$(grep -qF "Put Back" "$WORK/ax.txt" && echo yes || echo no)"
check "the helper was asked which worktrees, and nothing else" "listar" "$(asked)"
"$AXPRESS" "$APP_NAME" button Cancel
sleep 3
check "Cancel: the worktree stays" yes "$([ -f "$WT/file.txt" ] && echo yes || echo no)"
check "Cancel: nothing prepared or concluded" "listar" "$(asked)"
check "Cancel: nothing in the Trash" no "$([ -e "$HOME/.Trash/$WT_NAME" ] && echo yes || echo no)"

say ""
say "the question, and Close Tab"
rm -f "$WORK/calls.log"
tabs() { "$APP/Contents/Resources/keep" ls 2>/dev/null | grep -cE '^ +tab [0-9]+'; }
check "before: the daemon has the tab" 1 "$(tabs)"
"$AXPRESS" "$APP_NAME" menu File "Close Tab"
check "asked again, the question is up again" yes "$(question_up && echo yes || echo no)"
"$AXPRESS" "$APP_NAME" button "Close Tab"
waited=0
while [ -e "$WT" ] && [ "$waited" -lt 60 ]; do sleep 0.25; waited=$((waited + 1)); done
check "Close Tab: the worktree left its place" no "$([ -e "$WT" ] && echo yes || echo no)"
check "and is in the Trash with what was in it" yes "$([ -f "$HOME/.Trash/$WT_NAME/file.txt" ] && echo yes || echo no)"
sleep 1
check "the helper listed, prepared, then concluded" "listar preparar concluir" "$(asked)"
concluded=$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    a = json.loads(l)["argv"]
    if a[0] == "concluir": print(a[2])' "$WORK/calls.log")
check "conclude was told where the Trash put it" "$HOME/.Trash/$WT_NAME" "$concluded"
check "after: the tab is gone from the daemon" 0 "$(tabs)"

say ""
say "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
