#!/usr/bin/env bash
#
# What closing a tab does with the worktrees its conversation made, from the
# app's side (apps/macos/Sources/Keep/Daemon/Worktrees.swift).
#
# The helper that decides which worktrees those are lives outside the app;
# here a fake one (tools/worktrees-test/fake-helper.py) answers from files
# the test writes, so what is checked is the app's half: the arguments and
# the socket it hands the helper, the question's wording, the deadline,
# waiting for the tab's processes before anything moves, a folder retried
# while something still runs in it and left with a reason when refused, and
# the move itself — into the real Trash, under names no one else uses, taken
# back out at the end.
#
#   tools/worktrees-test.sh
#
# No app, no daemon, no repository of yours. About twenty seconds.
set -uo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d /tmp/keep-worktrees-XXXXXX)
trap 'rm -rf "$WORK"' EXIT
cp tools/worktrees-test/fake-helper.py "$WORK/"
swiftc -O apps/macos/Sources/Keep/Daemon/Worktrees.swift apps/macos/Sources/Keep/Daemon/ExternalHelper.swift \
    tools/worktrees-test/main.swift -o "$WORK/test" 2>&1 | grep -E "error" && exit 1
FAKE_DIR=$WORK "$WORK/test"
