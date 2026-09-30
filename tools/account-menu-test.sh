#!/usr/bin/env bash
#
# The menu of a tab's AI and account, from outside the app.
#
# A chevron beside a tab's title — in the strip and on the tab's row in the
# sidebar — opens one menu: follow the order of priority, or one account of
# it. `keep-ia`, the helper outside the app, does the switching (`keep-ia
# trocar`); the app offers, asks and shows. What this checks:
#   - the strip's menu and the sidebar's are the same menu, in the order's
#     order, ✓ on the account the helper says the tab is on, "at the limit"
#     on the one that is, and the sidebar saying "— claude · <slot>" for a
#     tab kept on one;
#   - following the order asks the helper for the first account that can
#     take work; an account asks for that account, as `trocar --ws=…
#     --aba=… --para=…`;
#   - a tab the helper says is busy puts a question up, and "Interrupt and
#     Switch Now" asks again with --interromper; "Cancel" asks nothing;
#   - an account the helper has to open a login of its own for first: the
#     tab that login is in is the one shown, under a note saying so;
#   - a tab running some other program says so and offers nothing;
#   - a cell of the strip reused for another tab — one before it closed —
#     acts on the tab it shows now;
#   - a real click on the chevron of the tab you are in opens the menu, and
#     does not start naming the tab;
#   - without the helper there is no chevron at all.
#
#   tools/account-menu-test.sh          (SKIP_BUILD=1 to use the KeepDev built last)
#
# A daemon of its own on a scratch socket, whose tabs run a plain shell, a
# stand-in for Claude Code (tools/ai-accounts-test/fake-claude.c) and `sleep`
# (tools/ai-accounts-test/tab-shell.sh is its $SHELL). The helper is the
# stand-in tools/ai-accounts-test/fake-keep-ia.py, its retrato.json one this
# writes, the logins made up, and the usage services a stand-in on
# 127.0.0.1. Driven through the accessibility tree (tools/axpress.swift), and
# one real click (tools/mousedrag.swift) — which moves the pointer. About two
# minutes.
#
# Your app, your daemon, your logins and your helper are never touched.

set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/scratch.sh
. tools/scratch.sh

APP=$(dev_app)
APP_NAME=$(app_name "$APP")
export KEEP_APP_NAME=$APP_NAME
BIN=$APP/Contents/MacOS/$APP_NAME
KEEP=$APP/Contents/Resources/keep
SOCKET=/tmp/keep-menu-$$.sock
WORK=$(mktemp -d /tmp/keep-menu-XXXXXX)
AXTEXT=$WORK/axtext
AXPRESS=$WORK/axpress
MOUSE=$WORK/mousedrag
WS=menu
PASSED=0
FAILED=0

cleanup() {
    [ -n "${APP_PID:-}" ] && kill "$APP_PID" 2>/dev/null
    [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
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
        say "        wanted: $(printf '%s' "$2" | tr '\n\t' '|>')"
        say "        got:    $(printf '%s' "$3" | tr '\n\t' '|>')"
        FAILED=$((FAILED + 1))
    fi
}
ax() { "$AXTEXT" "$APP_NAME" 2>/dev/null >"$WORK/ax.txt"; }
# Whether an element with this identifier is in the window.
present() { "$AXPRESS" "$APP_NAME" frame "$1" >/dev/null 2>&1 && echo yes || echo no; }
has() { grep -qF -- "$1" "$WORK/ax.txt" && echo yes || echo no; }
# Wait until the window's text has (or, with "no", has not) a line.
until_text() {  # until_text <text> [yes|no] [tenths]
    local want=${2:-yes} tries=${3:-60}
    while [ "$tries" -gt 0 ]; do
        ax
        [ "$(has "$1")" = "$want" ] && { echo "$want"; return; }
        sleep 0.1
        tries=$((tries - 1))
    done
    has "$1"
}
trace() { grep -a "$1" "$WORK/app.log"; }
calls() { python3 -c 'import json,sys
try:
    for l in open(sys.argv[1]): print(" ".join(json.loads(l)["argv"]))
except FileNotFoundError: pass' "$WORK/ia/calls.jsonl"; }
last_call() { calls | tail -1; }
count_calls() { calls | grep -c "^$1" ; }
# The helper's last call, once it has one more than `before`.
next_call() {  # next_call <count before> [tenths]
    local before=$1 tries=${2:-60}
    while [ "$(calls | wc -l | tr -d ' ')" -le "$before" ] && [ "$tries" -gt 0 ]; do
        sleep 0.1
        tries=$((tries - 1))
    done
    last_call
}
ncalls() { calls | wc -l | tr -d ' '; }
show_tab() { "$AXPRESS" "$APP_NAME" menu Window "Show Tab $1"; sleep 1; }
# A menu's items, as axpress prints them: "mark<TAB>enabled<TAB>title".
menu_of() {  # menu_of <identifier> -> the items, the menu put away again
    "$AXPRESS" "$APP_NAME" open "$1" || { echo "(no menu opened for $1)"; return; }
    "$AXPRESS" "$APP_NAME" items
    "$AXPRESS" "$APP_NAME" cancel
    sleep 0.3
}
choose() {  # choose <identifier> <item title, or its start>
    "$AXPRESS" "$APP_NAME" open "$1" || { say "        (no menu opened for $1)"; return 1; }
    "$AXPRESS" "$APP_NAME" pick "$2" || { say "        (no item '$2')"; "$AXPRESS" "$APP_NAME" cancel; return 1; }
}

if [ -z "${SKIP_BUILD:-}" ]; then
    say "building $APP_NAME, the client, the daemon and the tools (yours is left alone)"
    ./tools/build-dev.sh >/dev/null || { say "could not build $APP_NAME — run tools/build-dev.sh"; exit 1; }
fi
swiftc -O tools/axtext.swift -o "$AXTEXT" 2>/dev/null || { say "could not build axtext"; exit 1; }
swiftc -O tools/axpress.swift -o "$AXPRESS" 2>/dev/null || { say "could not build axpress"; exit 1; }
swiftc -O tools/mousedrag.swift -o "$MOUSE" 2>/dev/null || { say "could not build mousedrag"; exit 1; }
mkdir -p "$WORK/bin" "$WORK/ia" "$WORK/helper-state" "$WORK/state"
cc -O -o "$WORK/bin/claude" tools/ai-accounts-test/fake-claude.c 2>/dev/null || { say "could not build the stand-in claude"; exit 1; }
cp tools/ai-accounts-test/tab-shell.sh tools/ai-accounts-test/fake-keep-ia.py "$WORK/"
chmod +x "$WORK/tab-shell.sh" "$WORK/fake-keep-ia.py"

# ------------------------------------------------------------ made-up logins
# Three Claude logins and Codex's, in an order where the first is at its
# limit — so following the order means the GPT one.
FAKE=$WORK/home
mkdir -p "$FAKE/.claude/contas" "$FAKE/.codex"
python3 - "$FAKE" <<'PY'
import base64, json, os, sys, time
home = sys.argv[1]
vault = os.path.join(home, ".claude/contas")
now = time.time()
def slot(name, uuid, token, email):
    json.dump({"apelido": name, "email": email, "accountUuid": uuid,
               "credenciais": {"claudeAiOauth": {
                   "accessToken": token, "refreshToken": "never-used",
                   "expiresAt": int((now + 5 * 3600) * 1000),
                   "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"}}},
              open(os.path.join(vault, name + ".json"), "w"))
slot("main", "U1", "tok-main", "one@example.com")
slot("spare", "U2", "tok-spare", "two@example.com")
slot("full", "U3", "tok-full", "three@example.com")
open(os.path.join(vault, ".ativa"), "w").write("main\n")
open(os.path.join(vault, ".preferida"), "w").write("main\n")
open(os.path.join(vault, ".ordem"), "w").write(
    "claude:full\ngpt:principal\nclaude:main\nclaude:spare\n")
def b64(o):
    return base64.urlsafe_b64encode(json.dumps(o).encode()).decode().rstrip("=")
access = "h." + b64({"exp": int(now + 86400),
                     "https://api.openai.com/profile": {"email": "codex@example.com"},
                     "https://api.openai.com/auth": {"chatgpt_plan_type": "pro",
                                                     "chatgpt_account_id": "ACC"}}) + ".s"
json.dump({"auth_mode": "chatgpt",
           "tokens": {"access_token": access, "account_id": "ACC", "refresh_token": "never-used"}},
          open(os.path.join(home, ".codex/auth.json"), "w"))
open(os.path.join(home, "codex-token"), "w").write(access)
PY

# ----------------------------------------------- the stand-in for both services
cat >"$WORK/standin.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
codex = open(sys.argv[2]).read()
def claude(five, week):
    return {"five_hour": {"utilization": five, "resets_at": None},
            "seven_day": {"utilization": week, "resets_at": None}}
# "full" at its limit: 100%, where the service refuses; an account at 95-99% still takes work and is not marked
CLAUDE = {"tok-main": claude(10, 20), "tok-spare": claude(30, 40), "tok-full": claude(100, 50)}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        token = self.headers.get("Authorization", "")[len("Bearer "):]
        if self.path == "/claude" and token in CLAUDE:
            status, body = 200, CLAUDE[token]
        elif self.path == "/codex" and token == codex:
            status, body = 200, {"rate_limit": {"limit_reached": False, "primary_window": {
                "used_percent": 3, "limit_window_seconds": 604800}}}
        else:
            status, body = 401, {}
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
server = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(server.server_address[1]))
server.serve_forever()
PY
python3 "$WORK/standin.py" "$WORK/port" "$FAKE/codex-token" >"$WORK/standin.log" 2>&1 &
SERVER_PID=$!
waited=0
while [ ! -s "$WORK/port" ] && [ "$waited" -lt 40 ]; do sleep 0.25; waited=$((waited + 1)); done
PORT=$(cat "$WORK/port")

export KEEP_SOCKET=$SOCKET
export KEEP_STATE_DIR=$WORK/state
export KEEP_AI_USAGE_HOME=$FAKE
export KEEP_AI_USAGE_CLAUDE_URL=http://127.0.0.1:$PORT/claude
export KEEP_AI_USAGE_CODEX_URL=http://127.0.0.1:$PORT/codex
export KEEP_IA_BIN=$WORK/fake-keep-ia.py
export KIT_KEEP_ESTADO=$WORK/helper-state
export FAKE_IA_DIR=$WORK/ia
export FAKE_IA_KEEP=$KEEP
require_scratch_socket
rm -f "$SOCKET"

# ------------------------------------------------ a daemon and its four tabs
# Its $SHELL hands each new tab the next program in the queue.
SHELL=$WORK/tab-shell.sh AI_TEST_QUEUE=$WORK/queue AI_TEST_BIN=$WORK/bin \
    "$APP/Contents/Resources/keepd" >"$WORK/daemon.log" 2>&1 &
DAEMON_PID=$!
waited=0
while [ ! -S "$SOCKET" ] && [ "$waited" -lt 40 ]; do sleep 0.25; waited=$((waited + 1)); done
for program in zsh claude sleep zsh; do
    echo "$program" >>"$WORK/queue"
    "$KEEP" new "$WS" >/dev/null 2>&1 || { say "could not open a tab"; exit 1; }
    waited=0
    while [ -s "$WORK/queue" ] && [ "$waited" -lt 20 ]; do sleep 0.1; waited=$((waited + 1)); done
done
sleep 1

# The names the tabs are shown under, and what the helper wrote down about
# their accounts: both for this daemon, which is known by the birth of its
# socket.
BIRTH=$(python3 -c 'import os, sys; print(repr(os.stat(sys.argv[1]).st_birthtime))' "$SOCKET")
python3 - "$WORK" "$WS" "$BIRTH" <<'PY'
import json, sys, time
work, ws, birth = sys.argv[1], sys.argv[2], float(sys.argv[3])
names = {"1": "shell", "2": "fake-claude", "3": "sleeper", "4": "shell-2"}
json.dump({"daemonStart": birth, "workspaces": {},
           "tabs": {ws + "\u001f" + tab: name for tab, name in names.items()}},
          open(work + "/state/names.json", "w"))
json.dump({"versao": 1, "gravado_em_ms": int(time.time() * 1000),
           "keepd": {"pid": 0, "inicio": birth, "socket": ""}, "abas": [],
           "ia": [{"workspace": ws, "aba": 2, "agente": "claude", "conta": "claude:spare",
                   "vinculo": "exato"}]},
          open(work + "/helper-state/retrato.json", "w"))
PY

launch() {  # launch [log]: the app, its trace into $WORK/<log> (app.log)
    LOG=$WORK/${1:-app.log}
    stop_app
    : >"$LOG"
    KEEP_TRACE=1 "$BIN" >"$LOG" 2>&1 &
    APP_PID=$!
    local waited=0
    while ! grep -aqE "sidebar +order" "$LOG" && [ "$waited" -lt 120 ]; do
        sleep 0.25
        waited=$((waited + 1))
    done
    place_on_screen
    sleep 2
}
say "starting $APP_NAME on its own daemon, with the stand-in helper"
launch
# Every account measured, so that the one at its limit says so.
waited=0
while [ "$(grep -ac 'usage .* status=200' "$WORK/app.log")" -lt 4 ] && [ "$waited" -lt 60 ]; do
    sleep 0.25; waited=$((waited + 1))
done

say ""
say "the same menu in the strip and in the sidebar"
show_tab 2
ax
check "the sidebar says the account a tab is kept on" yes "$(has "— claude · spare")"
check "a chevron beside the tab's title in the strip" yes "$(present "strip-ai-$WS/2")"
check "and on its row in the sidebar" yes "$(present "sidebar-ai-$WS/2")"
check "named for the tab it opens the menu of" yes "$(has "Choose the AI for fake-claude")"
MARK=$'✓'
WANTED=$(printf '\t1\tFollow the order of priority\n---\n\t1\tClaude · full · three@example.com — at the limit\n\t1\tGPT · main · codex@example.com\n\t1\tClaude · main · one@example.com\n%s\t1\tClaude · spare · two@example.com' "$MARK")
STRIP=$(menu_of "strip-ai-$WS/2")
check "the strip's menu: the order, ✓ on the tab's account, 'at the limit' on the full one" "$WANTED" "$STRIP"
SIDEBAR=$(menu_of "sidebar-ai-$WS/2")
check "the sidebar's menu is the same menu" "$STRIP" "$SIDEBAR"
check "opening them asked the helper nothing" 0 "$(ncalls)"

say ""
say "choosing"
before=$(ncalls)
choose "strip-ai-$WS/2" "Follow the order of priority"
check "following the order asks for the first account that can take work" \
    "trocar --ws=$WS --aba=2 --para=gpt:principal --json" "$(next_call "$before")"
before=$(ncalls)
choose "sidebar-ai-$WS/2" "Claude · main"
check "an account asks for that account, from the sidebar too" \
    "trocar --ws=$WS --aba=2 --para=claude:main --json" "$(next_call "$before")"
check "and the sidebar says so" yes "$(until_text "— claude · main")"
before=$(ncalls)
choose "strip-ai-$WS/2" "Claude · main"
sleep 1.5
check "choosing the account it is on asks nothing" "$before" "$(ncalls)"

say ""
say "a tab at work"
touch "$WORK/ia/busy"
before=$(ncalls)
choose "strip-ai-$WS/2" "Claude · spare"
next_call "$before" >/dev/null
check "the helper says it is busy: a question goes up" yes "$(until_text "Interrupt and Switch Now")"
check "which says what switching now does" yes "$(has "Switching it to Claude · spare now interrupts what it is doing.")"
before=$(ncalls)
"$AXPRESS" "$APP_NAME" button "Interrupt and Switch Now"
check "and a yes asks again, allowed to interrupt" \
    "trocar --ws=$WS --aba=2 --para=claude:spare --interromper --json" "$(next_call "$before")"
check "the question has gone" no "$(until_text "Interrupt and Switch Now" no)"
before=$(ncalls)
choose "strip-ai-$WS/2" "Claude · full"
next_call "$before" >/dev/null
until_text "Interrupt and Switch Now" >/dev/null
before=$(ncalls)
"$AXPRESS" "$APP_NAME" button Cancel
check "Cancel dismisses the question" no "$(until_text "Interrupt and Switch Now" no)"
check "Cancel asks nothing more" "$before" "$(ncalls)"
rm -f "$WORK/ia/busy"

say ""
say "a tab running some other program"
show_tab 3
OTHER=$(menu_of "strip-ai-$WS/3")
check "it says what is running there" "	0	This tab is running sleep" "$(printf '%s\n' "$OTHER" | head -1)"
check "and nothing in it can be chosen" 0 "$(printf '%s\n' "$OTHER" | grep -c "	1	")"

say ""
say "a cell of the strip given to another tab"
show_tab 4
before=$(ncalls)
choose "strip-ai-$WS/4" "Claude · full"
check "the last tab's menu acts on the last tab" \
    "trocar --ws=$WS --aba=4 --para=claude:full --json" "$(next_call "$before")"
# The first tab closes: every tab after it moves one cell left, and the cell
# that was showing "sleeper" (sleep) now shows "shell-2" (a shell).
python3 - "$SOCKET" "$WS" <<'PY'
import socket, struct, sys
def s(v): b = v.encode(); return struct.pack(">I", len(b)) + b
payload = s(sys.argv[2]) + struct.pack(">I", 1)
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
c.connect(sys.argv[1])
c.sendall(bytes([0x07]) + struct.pack(">I", len(payload)) + payload)
c.recv(64)
PY
waited=0
while ! trace "row .*tabs=3" >/dev/null && [ "$waited" -lt 40 ]; do sleep 0.25; waited=$((waited + 1)); done
REUSED=$(menu_of "strip-ai-$WS/4")
check "its menu now is a shell's: everything can be chosen" 0 "$(printf '%s\n' "$REUSED" | grep -c "	0	")"
before=$(ncalls)
choose "strip-ai-$WS/4" "Claude · spare"
check "and choosing in it acts on the tab it shows now" \
    "trocar --ws=$WS --aba=4 --para=claude:spare --json" "$(next_call "$before")"

say ""
say "a real click on the chevron of the tab you are in"
osascript -e "tell application \"System Events\" to set frontmost of process \"$APP_NAME\" to true" \
    >/dev/null 2>&1
sleep 1
read -r CX CY CW CH < <("$AXPRESS" "$APP_NAME" frame "strip-ai-$WS/4")
opened_before=$(trace "menu open strip-ai-$WS/4" | wc -l | tr -d ' ')
"$MOUSE" click $((CX + CW / 2)) $((CY + CH / 2))
sleep 1
check "opens the menu" yes "$([ "$(trace "menu open strip-ai-$WS/4" | wc -l | tr -d ' ')" -gt "$opened_before" ] && echo yes || echo no)"
"$AXPRESS" "$APP_NAME" cancel
# Past the pause a single click on a name waits out before naming it.
sleep 1.5
check "and does not start naming the tab" no \
    "$(grep -aqE "strip +renaming 4$" "$WORK/app.log" && echo yes || echo no)"
check "nor is it a press on the tab, which selects or carries it" no \
    "$(grep -aqE "strip +press on 4 " "$WORK/app.log" && echo yes || echo no)"

say ""
say "an account with no login of its own for tabs yet"
touch "$WORK/ia/needs-login"
before=$(ncalls)
choose "strip-ai-$WS/4" "Claude · main"
check "the helper is asked for it all the same" \
    "trocar --ws=$WS --aba=4 --para=claude:main --json" "$(next_call "$before")"
check "a note says the login waits in the browser" yes "$(until_text "Approve Claude · main in the browser")"
login_tab=$(trace "waits for a login to claude:main in $WS/" | grep -aoE "in $WS/[0-9]+" | tail -1 | sed 's#.*/##')
check "the tab the helper opened the login in is the one shown" yes \
    "$([ -n "$login_tab" ] && grep -aqE "switch +→ $WS/$login_tab " "$WORK/app.log" && echo yes || echo no)"
check "and not the failure's words" no "$(has "Could not switch the tab's AI")"
"$AXPRESS" "$APP_NAME" button OK >/dev/null 2>&1
check "the note goes when read" no "$(until_text "Approve Claude · main in the browser" no)"
rm -f "$WORK/ia/needs-login"

say ""
say "without the helper"
export KEEP_IA_BIN=/var/empty
launch app-without-helper.log
ax
check "no chevron in the strip" no "$(present "strip-ai-$WS/4")"
check "none in the sidebar" no "$(present "sidebar-ai-$WS/4")"
check "none anywhere" no "$(has "Choose the AI for")"
check "no way to sign in from the footer" no "$(has "Sign in to another account")"
check "and no arrows" no "$(has "Move Claude")"

say ""
say "Codex questions and the selected tab's account"
cc -O -o "$WORK/bin/codex" tools/ai-accounts-test/fake-codex.c || exit 1
printf 'Choose an option\n» 1. Continue\n  2. Stop\nenter to submit · esc to interrupt\n' >"$WORK/bin/codex.screen"
for n in 1 2; do
    echo codex >>"$WORK/queue"
    "$KEEP" new "$WS" >/dev/null || exit 1
    sleep 1
done
python3 - "$WORK/daemon.log" "$WORK/helper-state/retrato.json" "$WORK/codex-tabs" "$WS" "$SOCKET" <<'PYFIX'
import json,os,sys,time
# Tab ids are allocated monotonically; the existing test has exactly two new Codex tabs.
# Read them from the daemon's own List2 protocol (0x0d).
import socket,struct
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);s.connect(sys.argv[5]);s.sendall(bytes([0x0d])+struct.pack('>I',0))
def take(n):
    b=b''
    while len(b)<n:
        c=s.recv(n-len(b))
        if not c:raise RuntimeError('short list')
        b+=c
    return b
header=take(5);data=take(struct.unpack('>I',header[1:])[0]);s.close()
pos=0
def integer(n):
    global pos
    v=int.from_bytes(data[pos:pos+n],'big');pos+=n;return v
def string():
    global pos
    n=integer(4);v=data[pos:pos+n].decode();pos+=n;return v
ids=[]
for _ in range(integer(4)):
    ws=string()
    for _ in range(integer(4)):
        tab=integer(4);integer(2);integer(2);integer(4);integer(1);string();integer(1);integer(4);integer(1)
        string();integer(8);command=string()
        if ws==sys.argv[4] and command=='codex':ids.append(tab)
assert len(ids)==2,ids
p=sys.argv[2];d=json.load(open(p));d['gravado_em_ms']=int(time.time()*1000)
d['ia'] = [e for e in d['ia'] if not (e['workspace']==sys.argv[4] and e['aba']==2)]
d['ia'].append({'workspace':sys.argv[4],'aba':2,'agente':'claude','conta':'claude:spare','vinculo':'exato'})
d['ia'] += [{'workspace':sys.argv[4],'aba':tab,'agente':'codex','conta':'gpt:principal','vinculo':'exato'} for tab in ids]
with open(p+'.tmp','w') as f:json.dump(d,f)
os.replace(p+'.tmp',p)
with open(sys.argv[3],'w') as f:f.write(' '.join(map(str,ids)))
PYFIX
read -r codex_one codex_two <"$WORK/codex-tabs"
sleep 3
"$AXPRESS" "$APP_NAME" press "strip-tab-$WS/$codex_one"
sleep 2
check "Codex question is announced as waiting" yes "$(until_text 'Codex is waiting for you')"
check "first waiting tab is selected" selected "$("$AXPRESS" "$APP_NAME" value "strip-tab-$WS/$codex_one")"
check "second waiting tab is not selected" "not selected" "$("$AXPRESS" "$APP_NAME" value "strip-tab-$WS/$codex_two")"
check "selected Codex marks the GPT account" yes "$(present 'usage-active-gpt:principal')"
check "Claude does not keep the green mark" no "$(present 'usage-active-claude:spare')"
"$AXPRESS" "$APP_NAME" press "strip-tab-$WS/$codex_two"
sleep 1
check "another waiting Codex tab can be selected" selected "$("$AXPRESS" "$APP_NAME" value "strip-tab-$WS/$codex_two")"
check "previous waiting tab loses its selection" "not selected" "$("$AXPRESS" "$APP_NAME" value "strip-tab-$WS/$codex_one")"
window_id=$("$MOUSE" windows | awk 'NR==1 {print $1}')
if [ -n "$window_id" ]; then
    /usr/sbin/screencapture -x -l "$window_id" "$WORK/codex-questions.png" 2>/dev/null || true
fi
printf '• Working (12s)\n» \n' >"$WORK/bin/codex.screen"
sleep 3
check "answered questions no longer ask for the user" no "$(until_text 'Codex is waiting for you' no)"
"$AXPRESS" "$APP_NAME" press "strip-tab-$WS/2"
sleep 2
check "selecting Claude moves the mark back" yes "$(present 'usage-active-claude:spare')"
check "unselected Codex loses the mark" no "$(present 'usage-active-gpt:principal')"

say "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
