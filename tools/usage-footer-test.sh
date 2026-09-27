#!/usr/bin/env bash
#
# The AI usage footer, from outside the app.
#
# The footer reads the accounts this Mac is signed in to — the Claude account
# vault in ~/.claude/contas and Codex's ~/.codex/auth.json — asks each
# service how much of the account's allowance is spent, and draws a bar per
# window at the bottom of the sidebar. What this checks:
#   - every account is there, one line per login (two vault slots holding the
#     same login are one account), under the name the tabs know it by and
#     with its address written out; Codex's single login is its "main";
#   - the bars carry the figures the service answered, for Claude and Codex;
#   - an account whose access has lapsed is not asked at all (nothing here
#     renews a token) and says so, and a "too many requests" answer is said;
#   - the requests carry the account's token and a CLI's user agent, and go
#     nowhere but the stand-in;
#   - the footer sits under the last workspace and stays on the floor when
#     the list outgrows the window.
#
#   tools/usage-footer-test.sh
#
# Nothing real is read or asked: a home of the test's own holds made-up
# logins, and a stand-in on 127.0.0.1 answers in the services' own format —
# the only kind of address the app accepts in place of the real ones. A
# daemon of its own on a scratch socket, KeepDev, read through the
# accessibility tree (tools/axtext.swift). About a minute.
#
# Your app, your daemon and your logins are never touched.

set -uo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tools/scratch.sh
. tools/scratch.sh

APP=$(dev_app)
APP_NAME=$(app_name "$APP")
export KEEP_APP_NAME=$APP_NAME
BIN=$APP/Contents/MacOS/$APP_NAME
SOCKET=/tmp/keep-usage-$$.sock
WORK=$(mktemp -d /tmp/keep-usage-XXXXXX)
AXTEXT=$WORK/axtext
AXPOS=$WORK/axpos
KEEP=$APP/Contents/Resources/keep   # the client and daemon the build put in the bundle
HOME_WS=$(id -un)
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
        say "        wanted: $2"
        say "        got:    $3"
        FAILED=$((FAILED + 1))
    fi
}
has() {  # has <fixed text>: yes if some line of the window's text contains it
    grep -qF -- "$1" "$WORK/ax.txt" && echo yes || echo no
}

if [ -z "${SKIP_BUILD:-}" ]; then
    say "building $APP_NAME, the client, the daemon and the tools (yours is left alone)"
    ./tools/build-dev.sh >/dev/null || { say "could not build $APP_NAME — run tools/build-dev.sh"; exit 1; }
fi
swiftc -O tools/axtext.swift -o "$AXTEXT" 2>/dev/null || { say "could not build axtext"; exit 1; }

# Where on screen a text is: the top of the first element carrying it, and
# the bottom of its window — enough to tell a footer on the floor from one
# that scrolled.
cat >"$WORK/axpos.swift" <<'SWIFT'
import AppKit
import ApplicationServices
let name = CommandLine.arguments[1], wanted = CommandLine.arguments[2]
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name })
else { exit(1) }
func attribute(_ e: AXUIElement, _ k: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil
}
func point(_ e: AXUIElement, _ k: String) -> CGPoint {
    var p = CGPoint.zero
    if let v = attribute(e, k) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    return p
}
func size(_ e: AXUIElement) -> CGSize {
    var s = CGSize.zero
    if let v = attribute(e, "AXSize") { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return s
}
var found: CGFloat?
func walk(_ e: AXUIElement, _ depth: Int) {
    guard found == nil, depth < 60 else { return }
    for k in ["AXValue", "AXTitle", "AXDescription"] {
        if let t = attribute(e, k) as? String, t.hasPrefix(wanted) { found = point(e, "AXPosition").y; return }
    }
    for c in attribute(e, "AXChildren") as? [AXUIElement] ?? [] { walk(c, depth + 1) }
}
let root = AXUIElementCreateApplication(app.processIdentifier)
guard let window = (attribute(root, "AXWindows") as? [AXUIElement])?.first else { exit(1) }
walk(window, 0)
let bottom = point(window, "AXPosition").y + size(window).height
print("\(Int(found ?? -1)) \(Int(bottom))")
SWIFT
swiftc -O "$WORK/axpos.swift" -o "$AXPOS" 2>/dev/null || { say "could not build axpos"; exit 1; }

# ------------------------------------------------------------ made-up logins
FAKE=$WORK/home
VAULT=$FAKE/.claude/contas
mkdir -p "$VAULT" "$FAKE/.codex"
python3 - "$FAKE" <<'PY'
import base64, json, os, sys, time
home = sys.argv[1]
vault = os.path.join(home, ".claude/contas")
now = time.time()
def slot(name, uuid, token, expires_in, email):
    body = {"apelido": name, "email": email, "accountUuid": uuid,
            "credenciais": {"claudeAiOauth": {
                "accessToken": token, "refreshToken": "never-used",
                "expiresAt": int((now + expires_in) * 1000),
                "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"}}}
    json.dump(body, open(os.path.join(vault, name + ".json"), "w"))
slot("main", "U1", "tok-main", 5 * 3600, "one@example.com")
slot("copy", "U1", "tok-main-old", 3600, "one@example.com")        # same login, older copy
slot("spare", "U2", "tok-lapsed", -3600, "two@example.com")        # access lapsed
slot("limited", "U3", "tok-429", 5 * 3600, "three@example.com")    # the service says wait
open(os.path.join(vault, ".ativa"), "w").write("main\n")
open(os.path.join(vault, ".preferida"), "w").write("main\n")
def b64(o):
    return base64.urlsafe_b64encode(json.dumps(o).encode()).decode().rstrip("=")
claims = {"exp": int(now + 86400),
          "https://api.openai.com/profile": {"email": "codex@example.com"},
          "https://api.openai.com/auth": {"chatgpt_plan_type": "pro", "chatgpt_account_id": "ACC"}}
access = "h." + b64(claims) + ".s"
json.dump({"auth_mode": "chatgpt", "OPENAI_API_KEY": None,
           "tokens": {"access_token": access, "account_id": "ACC", "refresh_token": "never-used"}},
          open(os.path.join(home, ".codex/auth.json"), "w"))
open(os.path.join(home, "codex-token"), "w").write(access)
PY

# ----------------------------------------------- the stand-in for both services
cat >"$WORK/standin.py" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
log = open(sys.argv[2], "a", buffering=1)
codex_token = open(sys.argv[3]).read()
reset = time.strftime("%Y-%m-%dT%H:%M:%S.123456+00:00", time.gmtime(time.time() + 4 * 3600 + 600))
week = time.strftime("%Y-%m-%dT%H:%M:%S.654321+00:00", time.gmtime(time.time() + 37 * 3600))
CLAUDE = {"five_hour": {"utilization": 17.0, "resets_at": reset},
          "seven_day": {"utilization": 88.0, "resets_at": week},
          "seven_day_opus": None, "seven_day_sonnet": None,
          "extra_usage": {"is_enabled": False, "utilization": None},
          "limits": [{"kind": "weekly_scoped", "percent": 32, "resets_at": week,
                      "scope": {"model": {"display_name": "Fable"}}}]}
CODEX = {"plan_type": "pro", "rate_limit": {"limit_reached": False,
         "primary_window": {"used_percent": 2, "limit_window_seconds": 604800,
                            "reset_at": int(time.time() + 6 * 86400)},
         "secondary_window": None}}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        token = auth[len("Bearer "):] if auth.startswith("Bearer ") else ""
        who = "codex" if token == codex_token else token
        log.write(json.dumps({"path": self.path, "token": who, "ua": self.headers.get("User-Agent", ""),
                              "account": self.headers.get("ChatGPT-Account-Id")}) + "\n")
        if self.path == "/claude" and token == "tok-main":
            status, body = 200, CLAUDE
        elif self.path == "/claude" and token == "tok-429":
            status, body = 429, {"error": "rate_limited"}
        elif self.path == "/codex" and token == codex_token:
            status, body = 200, CODEX
        else:
            status, body = 401, {"error": "unknown token"}
        data = json.dumps(body).encode()
        self.send_response(status)
        if status == 429: self.send_header("Retry-After", "120")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
server = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(server.server_address[1]))
server.serve_forever()
PY
python3 "$WORK/standin.py" "$WORK/port" "$WORK/requests.jsonl" "$FAKE/codex-token" &
SERVER_PID=$!
waited=0
while [ ! -s "$WORK/port" ] && [ "$waited" -lt 40 ]; do sleep 0.25; waited=$((waited + 1)); done
PORT=$(cat "$WORK/port")

export KEEP_SOCKET=$SOCKET
export KEEP_STATE_DIR=$WORK/state
export KEEP_AI_USAGE_HOME=$FAKE
export KEEP_AI_USAGE_CLAUDE_URL=http://127.0.0.1:$PORT/claude
export KEEP_AI_USAGE_CODEX_URL=http://127.0.0.1:$PORT/codex
mkdir -p "$KEEP_STATE_DIR"
require_scratch_socket
rm -f "$SOCKET"

"$APP/Contents/Resources/keepd" >>"$WORK/daemon.log" 2>&1 &
DAEMON_PID=$!
waited=0
while [ ! -S "$SOCKET" ] && [ "$waited" -lt 20 ]; do sleep 0.25; waited=$((waited + 1)); done

stop_app
: >"$WORK/app.log"
KEEP_TRACE=1 "$BIN" >"$WORK/app.log" 2>&1 &
APP_PID=$!
waited=0
while [ "$(grep -ac '^.*usage ' "$WORK/app.log")" -lt 3 ] && [ "$waited" -lt 120 ]; do
    sleep 0.25; waited=$((waited + 1))
done
place_on_screen
sleep 2
"$AXTEXT" "$APP_NAME" >"$WORK/ax.txt" 2>/dev/null

say ""
say "every account, one line per login"
check "the footer is there" yes "$(has "AI usage")"
check "the active account, by the name the tabs know it by" yes "$(has "Claude · main")"
check "its duplicate slot is not a second account" no "$(has "Claude · copy")"
check "the account whose access lapsed" yes "$(has "Claude · spare")"
check "the account the service is holding back" yes "$(has "Claude · limited")"
check "the Codex login, its only one: main" yes "$(has "GPT · main")"
check "each account's address is written out" yes "$(has "one@example.com")"
check "the lapsed account's address too" yes "$(has "two@example.com")"
check "and the Codex one" yes "$(has "codex@example.com")"

say ""
say "the bars carry what the services answered"
check "Claude's five-hour window" yes "$(has "Claude · main 5h 17% resets in 4h10")"
check "Claude's weekly window" yes "$(has "Claude · main 7d 88% resets in 1d13h")"
check "Claude's weekly window for one model" yes "$(has "Claude · main Fable 32%")"
check "Codex's weekly window" yes "$(has "GPT · main 7d 2% resets in 6d")"
check "a lapsed access says so instead of a figure" yes "$(has "access expired")"
check "a 'too many requests' says so" yes "$(has "too many requests (HTTP 429)")"
check "and neither shows a made-up bar" no "$(has "Claude · spare 5h")"

say ""
say "what was asked, and how"
asked() { python3 -c 'import json,sys; print(" ".join(sorted({json.loads(l)["token"] for l in open(sys.argv[1])})))' "$WORK/requests.jsonl"; }
check "each live login was asked once per round, the lapsed one never" "codex tok-429 tok-main" "$(asked)"
check "with the fresher token of the duplicate pair" no "$(grep -qF tok-main-old "$WORK/requests.jsonl" && echo yes || echo no)"
check "Claude asked with a CLI's user agent" yes "$(grep -F '"token": "tok-main"' "$WORK/requests.jsonl" | grep -qE '"ua": "claude-cli/[0-9.]+ \(external, cli\)"' && echo yes || echo no)"
check "Codex asked for its workspace" yes "$(grep -F '"token": "codex"' "$WORK/requests.jsonl" | grep -qF '"account": "ACC"' && echo yes || echo no)"
check "no token in the trace" no "$(grep -qE 'tok-|Bearer' "$WORK/app.log" && echo yes || echo no)"

say ""
say "under the list, and on the floor"
order=$(awk -v ws="$HOME_WS" '$0 ~ "^" ws && !w { w = NR } /^AI usage/ && !f { f = NR } END { print (w && f && w < f) ? "yes" : "no" }' "$WORK/ax.txt")
check "the footer comes after the workspaces" yes "$order"
read -r before bottom <<<"$("$AXPOS" "$APP_NAME" "AI usage")"
for i in $(seq 1 30); do "$KEEP" new "Space$i" >/dev/null 2>&1; done
sleep 4
read -r after bottom_after <<<"$("$AXPOS" "$APP_NAME" "AI usage")"
check "thirty more workspaces do not move it" "$before" "$after"
check "and it is still in the window" yes "$([ "$after" -gt 0 ] && [ "$after" -lt "$bottom_after" ] && echo yes || echo no)"

say ""
say "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
