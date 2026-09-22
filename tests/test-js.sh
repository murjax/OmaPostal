#!/usr/bin/env bash
# Unit tests for the QML-side JS libraries (lib/*.js), run under node.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
command -v node >/dev/null || { echo "skip - node not installed"; exit 0; }
rc=0
for t in "$HERE"/*.test.js; do
  node "$t" || { printf 'FAIL - %s\n' "$(basename "$t")"; rc=1; }
done
exit $rc
