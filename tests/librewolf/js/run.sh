#!/usr/bin/env bash
# run.sh: the extension's browser path, against the shipped background.js.
#
#   bash tests/librewolf/js/run.sh
#
# No browser and no network: the shipped extension is loaded into a Node context with
# a fake `browser` and a fake DOM, and the code strings it injects are actually run
# against that DOM. Every fixed defect has a witness beside it — the pre-fix logic,
# run against the same fixture and asserted to fail — so the bug is reproduced in the
# same run that shows the fix closing it.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
command -v node >/dev/null || { echo "node is not on PATH" >&2; exit 2; }
exec node "$here/test.js"
