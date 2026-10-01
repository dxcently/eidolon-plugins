#!/usr/bin/env bash
# no-browser-names.sh: jev must never register a `browser_*` tool; those names
# belong to the real `browser` plugin (the one in this repo, port 8090,
# browser.token). Two checks:
#   1. static: no jev/tools/*.rn declares a name starting with `browser_`, and
#      plugin.rn claims no verb that would join to one;
#   2. if XDG_CONFIG_HOME is a temp dir with jev installed, `eidolon plugins`
#      lists no `browser_` verb under jev.
# Exit 1 if either finds one.
set -euo pipefail
here=$(cd "$(dirname "$0")/../.." && pwd)
bad=0
for f in "$here"/jev/tools/*.rn; do
  n=$(sed -n 's/^ *name: "\([^"]*\)",$/\1/p' "$f" | head -n 1)
  case $n in browser_*) echo "BAD    $f declares $n" >&2; bad=1 ;; esac
done
if grep -n '"browser"\|"browser_' "$here/jev/plugin.rn" | grep -v '^[0-9]*: *//' >/dev/null; then
  echo "BAD    jev/plugin.rn mentions browser" >&2; bad=1
fi
[ $bad -eq 0 ] && echo "ok     static: jev/tools declares no browser_* name ($(ls "$here"/jev/tools/*.rn | wc -l) tools)"
. "$(dirname "$0")/guard.sh"
if require_temp_config 2>/dev/null && [ -d "${XDG_CONFIG_HOME}/eidolon/plugins/jev" ]; then
  listed=$(eidolon plugins | awk '/^jev /{f=1; next} /^[a-z]/{f=0} f' | grep -c 'browser_' || true)
  if [ "$listed" != 0 ]; then echo "BAD    installed jev registers $listed browser_* verb(s)" >&2; bad=1
  else echo "ok     installed: jev registers no browser_* verb"; fi
fi
exit $bad
