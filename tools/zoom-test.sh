#!/usr/bin/env bash
#
# The zoom's arithmetic (apps/macos/Sources/Keep/Model/TerminalZoom.swift):
# Chrome's steps, a size between two of them, the size written for each, and
# the percentage shown. Built from that file alone (tools/zoom-test/main.swift):
# Foundation, no app. Seconds.
#
#   tools/zoom-test.sh             the check
#   tools/zoom-test.sh --sabotage  and then broken arithmetic, each of which
#                                  it must fail
#
# The buttons and the chords in the app itself: tools/zoom-app-test.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d /tmp/keep-zoom-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
SOURCE=apps/macos/Sources/Keep/Model/TerminalZoom.swift

build() {  # build <TerminalZoom.swift>
    swiftc -O "$1" tools/zoom-test/main.swift -o "$WORK/test" 2>"$WORK/build.log" || {
        grep -E "error" "$WORK/build.log" | head -5; return 1; }
}

build "$SOURCE" || exit 1
"$WORK/test"
status=$?
[ "${1:-}" = "--sabotage" ] || exit $status
[ $status -eq 0 ] || { echo "the arithmetic itself fails; nothing to sabotage"; exit 1; }

echo
echo "sabotage: each of these must fail"
sabotage() {  # sabotage <what> <old|||new>
    python3 - "$SOURCE" "$WORK/Broken.swift" "$2" <<'PY'
import sys
s = open(sys.argv[1]).read()
old, new = sys.argv[3].split("|||")
if s.count(old) != 1:
    sys.exit("sabotage target found %d times: %r" % (s.count(old), old))
open(sys.argv[2], "w").write(s.replace(old, new))
PY
    [ $? -eq 0 ] || { echo "  could not sabotage: $1"; return 1; }
    build "$WORK/Broken.swift" || { echo "  broken arithmetic did not build: $1"; return 1; }
    if "$WORK/test" >"$WORK/out.txt"; then
        echo "  NOT CAUGHT  $1"; return 1
    fi
    echo "  caught      $1: $(grep -m1 FAIL "$WORK/out.txt" | cut -c9-)"
}
ok=0
sabotage "a larger step that stays where it is" \
    'levels.first { $0 > factor + slack }|||levels.first { $0 >= factor - slack }' || ok=1
sabotage "no slack: a size read back is a step of its own" \
    'private static let slack = 0.005|||private static let slack = 0.0' || ok=1
sabotage "100% written down as a size" \
    'guard abs(level - 1) > 0.0001 else { return nil }|||' || ok=1
sabotage "sizes written unrounded" \
    'return (base * level * 100).rounded() / 100|||return base * level' || ok=1
sabotage "percentages cut off instead of rounded" \
    '"\(Int((factor * 100).rounded()))%"|||"\(Int(factor * 100))%"' || ok=1
sabotage "Chrome's 400% and 500% back in" \
    '1.75, 2, 2.5, 3]|||1.75, 2, 2.5, 3, 4, 5]' || ok=1
exit $ok
