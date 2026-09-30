#!/usr/bin/env bash
# Persistence and socket isolation against disposable files, never the real app.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d /tmp/keep-state-test-XXXXXX)
trap 'rm -rf "$work"' EXIT
python3 - "$work/State.swift" <<'PY'
import sys
from pathlib import Path
s=Path('apps/macos/Sources/Keep/Model/SidebarStateStore.swift').read_text()
parts=['import Foundation\nimport CryptoKit\nimport Darwin\n',
       'struct TabID: Equatable { let workspace: String; let root: UInt32 }',
       'enum Daemon { static let socketPath = "/tmp/keep-state-test.sock" }']
for head in ['enum KeepStateFile {','func stateDirectory() -> URL {','struct FileStamp: Equatable {',
             'final class NameStore {','final class TabOrderStore {']:
    start=s.index(head);end=s.index('\n}\n',start)+3
    parts.append(('@MainActor\n' if head.startswith('final class') else '')+s[start:end])
Path(sys.argv[1]).write_text('\n'.join(parts))
PY
swiftc "$work/State.swift" tools/state-test/main.swift -o "$work/test"
"$work/test" "$work/files"
