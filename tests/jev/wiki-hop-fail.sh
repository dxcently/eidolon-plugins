#!/usr/bin/env bash
# wiki-hop-fail.sh: a tool result the interpreter rejects ends wiki-hop as `failed` and says why,
# not as a refused run ("Cannot read, value is M-000000"). The fake browser declares one
# character more than its snapshot holds (FB_SHORT=1), which reads as truncated in transport
# on the first step; nothing is chosen, so no service is needed. Same temp-config rule as
# wiki-hop.sh (guard.sh refuses otherwise). Prints final_state; exits 1 unless it is failed.
#
#   t=$(mktemp -d); HOME=$t XDG_CONFIG_HOME=$t/cfg XDG_STATE_HOME=$t/state \
#     XDG_DATA_HOME=$t/data XDG_RUNTIME_DIR=$t/run bash tests/jev/wiki-hop-fail.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
. "$here/guard.sh"
require_temp_config || exit 2
: "${XDG_STATE_HOME:?set XDG_STATE_HOME to a temp dir}" "${XDG_DATA_HOME:?set XDG_DATA_HOME to a temp dir}"
plug=$XDG_CONFIG_HOME/eidolon/plugins
mkdir -p "$plug"
rm -rf "$plug/jev" "$plug/browser"
cp -r "$repo/jev" "$plug/jev"
cp -r "$here/fake-browser" "$plug/browser"
eidolon plugins trust jev >/dev/null
eidolon plugins trust browser >/dev/null
export FAKE_BROWSER="$here/fake-browser" FB_STATE=$(mktemp -d) FB_SHORT=1
trap 'rm -rf "$FB_STATE"' EXIT
rc=0
out=$(eidolon workflow run "$plug/jev" wiki-hop --args '{"start":"Cat","goal":"Ancient Egypt"}' --provider mock 2>&1) || rc=$?
echo "$(grep -o 'final_state[^,]*' <<<"$out" || echo "no final_state (exit $rc)")"
if [ $rc -ne 0 ] || ! grep -q 'final_state[^,]*failed' <<<"$out" || ! grep -q 'truncated in transport' <<<"$out"; then
  tail -c 600 <<<"$out" >&2
  exit 1
fi
grep -o 'observation from[^"\\]*truncated in transport[^"\\]*' <<<"$out" | head -n 1
