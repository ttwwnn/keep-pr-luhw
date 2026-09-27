#!/usr/bin/env bash
#
# ClaudeActivity — the colour of a Claude Code tab by where its turn stands —
# against made-up screens (tools/claude-activity-test/main.swift). The enum
# is taken out of Model/Snapshots.swift and compiled with the test alone:
# Foundation only, no app. Seconds.
#
#   tools/claude-activity-test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d /tmp/keep-activity-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
python3 - apps/macos/Sources/Keep/Model/Snapshots.swift "$WORK/ClaudeActivity.swift" <<'PY'
import sys
s = open(sys.argv[1]).read()
start = s.index("enum ClaudeActivity: Hashable {")
end = s.index("\n}\n", start) + 3
open(sys.argv[2], "w").write("import Foundation\n\n" + s[start:end])
PY
swiftc -O "$WORK/ClaudeActivity.swift" tools/claude-activity-test/main.swift -o "$WORK/test" 2>&1 \
    | grep -E "error" && exit 1
"$WORK/test"
