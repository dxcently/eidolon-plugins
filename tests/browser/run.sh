#!/usr/bin/env bash
# run.sh: check the browser tools' answer when the service is not running.
#
#   t=$(mktemp -d)
#   HOME=$t XDG_CONFIG_HOME=$t/cfg XDG_STATE_HOME=$t/state XDG_DATA_HOME=$t/data \
#     bash tests/browser/run.sh
#
# Nothing is started and no page is fetched: the test only runs when nothing answers on
# 127.0.0.1:8090, so the tools cannot reach a browser even if one were up somewhere else.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
. "$here/guard.sh"
require_temp_config || exit 2

: "${XDG_STATE_HOME:?set XDG_STATE_HOME to a temp dir}"
: "${XDG_DATA_HOME:?set XDG_DATA_HOME to a temp dir}"

eidolon=$(command -v eidolon || true)
[ -n "$eidolon" ] || { echo "eidolon is not on PATH" >&2; exit 2; }

# A live service would take these calls — and browser_open would navigate. This test is
# about a service that is not there, so refuse instead of touching a real one.
if timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/8090' 2>/dev/null; then
    echo "refusing: something is answering on 127.0.0.1:8090. Stop the browser service first (eidolon plugins service stop browser); this test must not reach a browser" >&2
    exit 2
fi

plug=$XDG_CONFIG_HOME/eidolon/plugins
mkdir -p "$plug"
rm -rf "$plug/browser"
cp -r "$repo/browser" "$plug/browser"
cp "$here/service-down.rn" "$plug/browser/workflows/service-down.rn"

# The token each verb resolves, and the grant rows the README's install writes, so the
# call gets as far as the dial instead of stopping at a missing credential.
token=$HOME/.config/eidolon/browser.token
mkdir -p "$(dirname "$token")"
(umask 077 && head -c 24 /dev/urandom | base64 > "$token")
run_eidolon() { XDG_CONFIG_HOME=$XDG_CONFIG_HOME "$eidolon" "$@"; }
run_eidolon plugins trust browser >/dev/null
for v in open snapshot click type read back; do
    run_eidolon plugins grant "browser_$v" "file:~/.config/eidolon/browser.token" >/dev/null
done

report=$XDG_STATE_HOME/service-down.txt
mkdir -p "$XDG_STATE_HOME"
run_eidolon workflow run "$plug/browser" service-down --args '{}' --provider mock >"$report" 2>&1 || true

# The report is one JSON line, so its checks are read from the line: a passing run says
# "checks hold", a failing one carries its own FAIL lines and no count.
if grep -q "checks hold" "$report"; then
    cat "$report"
    echo "ok   every verb that reaches the service names the command that starts it"
    exit 0
fi
echo "FAIL service-down" >&2
sed -n 1,40p "$report" >&2
exit 1
