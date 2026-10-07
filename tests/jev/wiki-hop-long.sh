#!/usr/bin/env bash
# wiki-hop-long.sh: wiki-hop on an article whose link snapshot is longer than eidolon's
# 8,000-character inline limit and holds more links than the graph's `max`. Without `max`
# eidolon spills the tool's text, only the head arrives, and the run fails with "truncated
# in transport". With one (any positive max exempts a call from the spill) the fake browser
# keeps the first 100 links, as the real one does, and the snapshot arrives whole.
# The rig is wiki-hop.sh's: jev and the fake `browser` in the temp config XDG_CONFIG_HOME
# names (guard.sh refuses otherwise), and the stub service.
# Prints final_state; exits 1 unless the run arrived with nothing truncated.
#
#   t=$(mktemp -d); HOME=$t XDG_CONFIG_HOME=$t/cfg XDG_STATE_HOME=$t/state \
#     XDG_DATA_HOME=$t/data XDG_RUNTIME_DIR=$t/run bash tests/jev/wiki-hop-long.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
. "$here/guard.sh"
require_temp_config || exit 2
: "${XDG_STATE_HOME:?set XDG_STATE_HOME to a temp dir}" "${XDG_DATA_HOME:?set XDG_DATA_HOME to a temp dir}"
article=$here/fake-browser/site/List_of_cat_breeds.txt
if [ "$(wc -c < "$article")" -le 8000 ] || [ "$(grep -c '^ *- link ' "$article")" -le 100 ]; then
  echo "bad fixture: ${article##*/} needs over 8000 characters and over 100 links" >&2
  exit 2
fi
if (exec 3<>/dev/tcp/127.0.0.1/8091) 2>/dev/null; then
  echo "refusing: something already listens on 127.0.0.1:8091, the port jev's tools use." >&2
  exit 2
fi
plug=$XDG_CONFIG_HOME/eidolon/plugins
mkdir -p "$plug"
rm -rf "$plug/jev" "$plug/browser"
cp -r "$repo/jev" "$plug/jev"
cp -r "$here/fake-browser" "$plug/browser"
eidolon plugins trust jev >/dev/null
eidolon plugins trust browser >/dev/null
umask 077
tok=$HOME/.config/eidolon/jev.token; mkdir -p "$(dirname "$tok")"
head -c 24 /dev/urandom | base64 > "$tok"
for v in jev_choose jev_entail; do eidolon plugins grant $v "file:~/.config/eidolon/jev.token" >/dev/null; done
python3 "$here/stub_service.py" --port 8091 --token-file "$tok" >/dev/null 2>&1 &
svc=$!
export FAKE_BROWSER="$here/fake-browser" FB_STATE=$(mktemp -d)
trap 'kill $svc 2>/dev/null || true; rm -rf "$FB_STATE"' EXIT
for _ in $(seq 50); do
  (exec 3<>/dev/tcp/127.0.0.1/8091) 2>/dev/null && break
  sleep 0.1
done
rc=0
out=$(eidolon workflow run "$plug/jev" wiki-hop --args '{"start":"List_of_cat_breeds","goal":"Ancient Egypt"}' --provider mock 2>&1) || rc=$?
state=$(grep -o 'final_state[^,]*' <<<"$out" || true)
echo "${state:-no final_state (exit $rc)}"
if grep -q 'truncated in transport' <<<"$out"; then
  grep -o 'observation from[^"\\]*truncated in transport[^"\\]*' <<<"$out" | head -n 1 >&2
  exit 1
fi
if [ $rc -ne 0 ] || ! grep -q 'final_state[^,]*arrived' <<<"$out"; then
  tail -c 600 <<<"$out" >&2
  exit 1
fi
