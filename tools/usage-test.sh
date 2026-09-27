#!/usr/bin/env bash
#
# The usage footer's facts (apps/macos/Sources/Keep/Model/AIUsage.swift):
# both services' answers in their real shape, the logins found in a made-up
# home, the stand-in address refused unless it is on this machine, and the
# strings the footer prints. No app, no network, no real login. Seconds.
#
#   tools/usage-test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d /tmp/keep-usage-model-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
swiftc -O apps/macos/Sources/Keep/Model/AIUsage.swift tools/usage-test/main.swift \
    -o "$WORK/test" 2>&1 | grep -E "error" && exit 1
"$WORK/test"
