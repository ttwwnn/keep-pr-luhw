#!/usr/bin/env bash
#
# The colours of a tab's title and of the badge a tab waiting on you wears
# (UI/Glass.swift), on Keep's dark and light grounds
# (tools/tab-colours-test/main.swift). Glass.swift is compiled with the two
# enums it colours by, taken out of Model/Snapshots.swift: AppKit, no app.
# Seconds.
#
#   tools/tab-colours-test.sh             the check
#   tools/tab-colours-test.sh --sabotage  and then three broken palettes,
#                                         each of which it must fail
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d /tmp/keep-colours-XXXXXX)
trap 'rm -rf "$WORK"' EXIT

build() {  # build <glass.swift>
    python3 - apps/macos/Sources/Keep/Model/Snapshots.swift "$WORK/Enums.swift" <<'PY'
import sys
s = open(sys.argv[1]).read()
out = ["import Foundation\n"]
for head in ("enum ClaudeMode: Hashable {", "enum ClaudeActivity: Hashable {"):
    start = s.index(head)
    end = s.index("\n}\n", start) + 3
    out.append(s[start:end])
# The modes, all of them, for the test to walk through.
out.append("extension ClaudeMode: CaseIterable {}\n")
open(sys.argv[2], "w").write("\n".join(out))
PY
    swiftc -O "$1" "$WORK/Enums.swift" tools/tab-colours-test/main.swift -o "$WORK/test" 2>"$WORK/build.log" || {
        grep -E "error" "$WORK/build.log" | head -5; return 1; }
}

build apps/macos/Sources/Keep/UI/Glass.swift || exit 1
"$WORK/test"
status=$?
[ "${1:-}" = "--sabotage" ] || exit $status
[ $status -eq 0 ] || { echo "the palette itself fails; nothing to sabotage"; exit 1; }

echo
echo "sabotage: each of these must fail"
sabotage() {  # sabotage <what> <python replacement: old|||new>
    python3 - apps/macos/Sources/Keep/UI/Glass.swift "$WORK/Broken.swift" "$2" <<'PY'
import sys
s = open(sys.argv[1]).read()
old, new = sys.argv[3].split("|||")
if s.count(old) != 1:
    sys.exit("sabotage target found %d times: %r" % (s.count(old), old))
open(sys.argv[2], "w").write(s.replace(old, new))
PY
    [ $? -eq 0 ] || { echo "  could not sabotage: $1"; return 1; }
    build "$WORK/Broken.swift" || { echo "  broken palette did not build: $1"; return 1; }
    if "$WORK/test" >"$WORK/out.txt"; then
        echo "  NOT CAUGHT  $1"; return 1
    fi
    echo "  caught      $1: $(grep -m1 FAIL "$WORK/out.txt" | cut -c7-)"
}
ok=0
sabotage "white ink on the badge" \
    'static let ink = srgb(33, 22, 12)|||static let ink = srgb(255, 255, 255)' || ok=1
sabotage "background work in the accept-edits violet" \
    'case (.waitingForWorkflow, true): return srgb(122, 180, 232)|||case (.waitingForWorkflow, true): return srgb(175, 135, 255)' || ok=1
sabotage "a pale badge on the light ground" \
    'dark ? srgb(255, 120, 20) : srgb(255, 106, 0)|||dark ? srgb(255, 120, 20) : srgb(255, 236, 214)' || ok=1
sabotage "a breath that stops halfway" \
    'return Date(timeIntervalSinceReferenceDate: (end / period).rounded(.up) * period)|||return Date(timeIntervalSinceReferenceDate: end)' || ok=1
exit $ok
