#!/usr/bin/env bash
# smoke-live.sh: the browser plugin's REAL smoke — a real `eidolon-browser` and a real Chromium,
# isolated from the operator's service: its own port, its own token minted for the run, its own
# log. Chromium renders a `data:` page and navigates it, so nothing is fetched.
#
# DRY BY DEFAULT, and it is the coordinator's to arm: it starts a service process.
#
#   bash tests/browser/smoke-live.sh                 # print the plan and the exact commands
#   BROWSER_LIVE_GO=1 bash tests/browser/smoke-live.sh
#
# It never reads, copies or needs the operator's token, never contacts or disturbs the service on
# 8090, and never installs or trusts anything in the operator's config. The isolated service is
# configured entirely by environment (`EIDOLON_SERVICE_PORT`, `EIDOLON_SERVICE_TOKEN`,
# `EIDOLON_BROWSER_CHROME`), which is why no throwaway HOME is needed for it at all; the temp
# *tool copies* are retargeted at that port and that token.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
port=${BROWSER_LIVE_PORT:-8099}
say() { printf '%s\n' "$*"; }

say "== browser live smoke (real service, real Chromium, isolated) =="
say "port for this run: $port   (the operator's 8090 is not used or probed beyond /health)"
say "service binary: $(command -v eidolon-browser || echo '<not on PATH>')"
say "chromium: ${EIDOLON_BROWSER_CHROME:-$(command -v chromium || command -v google-chrome || echo '<none>')}"
say ""
say "the exact environment the isolated service is started with:"
say "  EIDOLON_SERVICE_PORT=$port"
say "  EIDOLON_SERVICE_TOKEN=<minted for this run, written to a temp file for the tools>"
say "  EIDOLON_BROWSER_CHROME=<the chromium above>"
say ""
say "steps:"
for s in "mktemp a run directory; mint a token (never the operator's)" \
    "start eidolon-browser with the environment above, logging to <run>/service.log; wait for /health" \
    "throwaway config (HOME/XDG under <run>); copy the plugin in; trust it THERE" \
    "retarget the temp copies: base_url -> 127.0.0.1:$port, token_file -> <run>/browser.token" \
    "grant file:<run>/browser.token to each verb, in the temp config only" \
    "run the live workflow with --provider mock: open a data: page, snapshot, read, click the link's ref, read again, back" \
    "kill the service this script started; keep <run>/service.log and the run's output; delete the config"; do
    say "  - $s"
done
say ""
say "never: reading or copying the operator's token, contacting or stopping the service on 8090,"
say "installing into ~/.config/eidolon, or fetching anything from a network (the page is a data: URL)"
say ""
say "what this needs from whoever owns the decision: a service process on this machine, started by"
say "this script and killed by it. Nothing else — no operator config, no credential of theirs."

if [ "${BROWSER_LIVE_GO:-}" != "1" ]; then
    say ""
    say "DRY RUN: nothing was started and nothing was run."
    exit 0
fi

work=$(mktemp -d)
cleanup() { [ -n "${svc_pid:-}" ] && kill "$svc_pid" 2>/dev/null || true; }
trap cleanup EXIT
token=$work/browser.token
(umask 077 && head -c 24 /dev/urandom | base64 | tr -d '\n' > "$token")

EIDOLON_SERVICE_PORT=$port \
EIDOLON_SERVICE_TOKEN=$(cat "$token") \
EIDOLON_BROWSER_CHROME="${EIDOLON_BROWSER_CHROME:-$(command -v chromium || command -v google-chrome)}" \
    "$(command -v eidolon-browser)" >"$work/service.log" 2>&1 &
svc_pid=$!
say "service pid $svc_pid, log $work/service.log"
for _ in $(seq 1 60); do
    if timeout 1 curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1; then break; fi
    sleep 0.5
done
say "health: $(timeout 2 curl -fsS "http://127.0.0.1:$port/health" 2>&1)"
[ -s "$work/service.log" ] && say "service log head: $(head -2 "$work/service.log" | tr '\n' ' ')"

export HOME=$work XDG_CONFIG_HOME=$work/cfg XDG_STATE_HOME=$work/state XDG_DATA_HOME=$work/data
mkdir -p "$XDG_CONFIG_HOME/eidolon/plugins"
plug=$XDG_CONFIG_HOME/eidolon/plugins
cp -r "$repo/browser" "$plug/browser"
cp "$here/live.rn" "$plug/browser/workflows/live.rn"
for f in "$plug"/browser/tools/*.rn; do
    sed -i "s|http://127.0.0.1:8090|http://127.0.0.1:$port|; s|token_file: \"~/.config/eidolon/browser.token\"|token_file: \"$token\"|" "$f"
done
say "retargeted $(grep -l "127.0.0.1:$port" "$plug"/browser/tools/*.rn | wc -l) tool file(s) at $port"
eidolon=$(command -v eidolon)
"$eidolon" plugins trust browser >/dev/null
for v in open snapshot click type read back; do
    "$eidolon" plugins grant "browser_$v" "file:$token" >/dev/null
done

page='data:text/html,<html><head><title>live smoke</title></head><body><h1>live smoke</h1><a href="data:text/html,<title>next</title><h1>next page</h1>">the next link</a></body></html>'
say ""
"$eidolon" workflow run "$plug/browser" live --provider mock \
    --args "$(python3 -c 'import json,sys; print(json.dumps({"page": sys.argv[1]}))' "$page")" 2>&1 | tail -3
say ""
say "the run's line above is the evidence: a real Chromium rendered the data: page, the click"
say "navigated it, and back returned. Service log kept at $work/service.log."
