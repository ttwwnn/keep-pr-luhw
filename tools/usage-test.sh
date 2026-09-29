#!/usr/bin/env bash
#
# The usage footer's facts (apps/macos/Sources/Keep/Model/AIUsage.swift):
# both services' answers in their real shape, the logins found in a made-up
# home, the stand-in address refused unless it is on this machine, and the
# strings the footer prints. And what the AI accounts rest on: the order of
# priority and the extra GPT logins (AIUsage.swift), and asking `keep-ia`,
# the helper outside the app (Daemon/ExternalHelper.swift) — played by a
# stand-in that logs what it is asked. No app, no network, no real login, no
# real helper. Seconds.
#
#   tools/usage-test.sh              the check
#   tools/usage-test.sh --sabotage   and then each rule broken in turn, which
#                                    it must fail on
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d /tmp/keep-usage-model-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
USAGE=apps/macos/Sources/Keep/Model/AIUsage.swift
HELPER=apps/macos/Sources/Keep/Daemon/ExternalHelper.swift

build() {  # build <AIUsage.swift> <ExternalHelper.swift>
    swiftc -O "$1" "$2" tools/usage-test/main.swift -o "$WORK/test" 2>"$WORK/build.log" || {
        grep -E "error" "$WORK/build.log" | head -5; return 1; }
}
# keep-ia, played by the stand-in the app's own tests use: it logs what it
# was asked, and answers out of the test's made-up home.
cp tools/ai-accounts-test/fake-keep-ia.py "$WORK/fake-keep-ia.py"
chmod +x "$WORK/fake-keep-ia.py"
# The installed helper is never within reach, whatever the code under test
# does — the sabotages below break exactly the rules that keep it out. The
# test runs under a made-up HOME, where the app looks for the installed
# helper, and what it finds there is a canary: it does nothing, and leaves a
# mark the test fails on. And it runs as an app that reads a made-up home,
# which never asks the installed helper at all.
mkdir -p "$WORK/home/.local/bin"
cat >"$WORK/home/.local/bin/keep-ia" <<EOF
#!/bin/sh
echo "\$*" >>"$WORK/installed-helper-called"
exit 1
EOF
chmod +x "$WORK/home/.local/bin/keep-ia"
run() {
    HOME=$WORK/home KEEP_AI_USAGE_HOME=$WORK/home KIT_KEEP_ESTADO=/var/empty KEEP_IA_BIN=/var/empty \
        FAKE_IA=$WORK/fake-keep-ia.py FAKE_IA_DIR=$WORK "$WORK/test"
}

build "$USAGE" "$HELPER" || exit 1
run
status=$?
[ "${1:-}" = "--sabotage" ] || exit $status
[ $status -eq 0 ] || { echo "the check itself fails; nothing to sabotage"; exit 1; }

echo
echo "sabotage: each of these must fail"
sabotage() {  # sabotage <file> <what> <old|||new>
    python3 - "$1" "$WORK/Broken.swift" "$3" <<'PY'
import sys
s = open(sys.argv[1]).read()
old, new = sys.argv[3].split("|||")
if s.count(old) != 1:
    sys.exit("sabotage target found %d times: %r" % (s.count(old), old))
open(sys.argv[2], "w").write(s.replace(old, new))
PY
    [ $? -eq 0 ] || { echo "  could not sabotage: $2"; return 1; }
    local usage=$USAGE helper=$HELPER
    case "$1" in
        "$USAGE") usage=$WORK/Broken.swift ;;
        "$HELPER") helper=$WORK/Broken.swift ;;
    esac
    build "$usage" "$helper" || { echo "  broken code did not build: $2"; return 1; }
    if run >"$WORK/out.txt" 2>&1; then
        echo "  NOT CAUGHT  $2"; return 1
    fi
    echo "  caught      $2: $(grep -m1 FAIL "$WORK/out.txt" | cut -c7-)"
}
ok=0
sabotage "$USAGE" "a merged account at the later of its places" \
    'if let first = listed.min(by: { $0.place < $1.place }) {|||if let first = listed.max(by: { $0.place < $1.place }) {' || ok=1
sabotage "$USAGE" "accounts the order does not name put first" \
    'return ordered + rest|||return rest + ordered' || ok=1
sabotage "$USAGE" "an extra GPT login that is the main one's shown twice" \
    'if let account = codex(auth: auth, slot: name) { found.append(account) }
        }
        return merge(found)|||if let account = codex(auth: auth, slot: name) { found.append(account) }
        }
        return found' || ok=1
sabotage "$USAGE" "Codex's own login known to the helper by the name it is shown under" \
    'slots: own ? [codexOwnSlot] : nil)|||slots: nil)' || ok=1
sabotage "$USAGE" "an account at 95% still taking work" \
    '$0.percent >= 95 }|||$0.percent >= 96 }' || ok=1
sabotage "$USAGE" "the watcher blind to the order" \
    '[".ativa", ".preferida", ".ordem"]|||[".ativa", ".preferida"]' || ok=1
sabotage "$HELPER" "KEEP_IA_BIN pointing at nothing falling through to the installed one" \
    'if let named = environment["KEEP_IA_BIN"] { return isRunnable(named) ? named : nil }|||if let named = environment["KEEP_IA_BIN"], isRunnable(named) { return named }' || ok=1
sabotage "$HELPER" "an app reading a made-up home asking the installed helper" \
    '        if environment["KEEP_AI_USAGE_HOME"] != nil { return nil }
|||' || ok=1
sabotage "$HELPER" "the installed helper looked for in the real home, whatever HOME says" \
    'let home = environment["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? NSHomeDirectory()|||let home = NSHomeDirectory()' || ok=1
sabotage "$HELPER" "both rules gone: what answers is the made-up HOME's canary, and the test says so" \
    'if let named = environment["KEEP_IA_BIN"] { return isRunnable(named) ? named : nil }
        if environment["KEEP_AI_USAGE_HOME"] != nil { return nil }|||if let named = environment["KEEP_IA_BIN"], isRunnable(named) { return named }' || ok=1
sabotage "$HELPER" "a directory taken for the helper" \
    '&& !directory.boolValue|||' || ok=1
sabotage "$HELPER" "a key with a colon in its name let through" \
    '#"^(claude|gpt):[^\s/:]+$"#|||#"^(claude|gpt):[^\s/]+$"#' || ok=1
sabotage "$HELPER" "a workspace passed as a word of its own" \
    'var arguments = ["trocar", "--ws=\(workspace)",|||var arguments = ["trocar", "--ws", workspace,' || ok=1
sabotage "$HELPER" "a key refused by nobody before the helper" \
    '        guard isValidKey(key) else { return .failure(invalid(key)) }
        var arguments|||        var arguments' || ok=1
sabotage "$HELPER" "no deadline" \
    'guard finished.wait(timeout: .now() + seconds) == .success else {|||guard finished.wait(timeout: .distantFuture) == .success else {' || ok=1
exit $ok
