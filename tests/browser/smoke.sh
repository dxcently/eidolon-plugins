#!/usr/bin/env bash
# smoke.sh: the operator-gated live smoke for the browser plugin.
#
# DRY BY DEFAULT (no BROWSER_SMOKE_GO=1 prints the plan and touches nothing). It never starts
# the service and never installs anything: the service is the operator's, started by hand —
# `eidolon plugins service start browser` — which is the plugin's semantics, and a smoke that
# started it for you would be exercising a behaviour the plugin does not have.
#
#   bash tests/browser/smoke.sh                     # print the plan, and say whether the service is up
#   BROWSER_SMOKE_GO=1 bash tests/browser/smoke.sh  # run it (needs the service already running)
#
# The armed run navigates to a `data:` URL: no network, no real page, nothing fetched.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
health=http://127.0.0.1:8090/health
say() { printf '%s\n' "$*"; }

up=no
if timeout 3 curl -fsS "$health" >/dev/null 2>&1; then up=yes; fi

say "== browser live smoke =="
say "service $health: ${up} (up = already running, which is what this smoke requires)"
if [ "$up" = no ]; then
    say ""
    say "The service is not answering. Start it yourself — the plugin does not do this for you:"
    say "  eidolon plugins service start browser        # approve-once, then runs it detached"
    say "  eidolon plugins service status browser       # probes the port; never trusts a record"
    say "Until it is up, a tool call answers with that same command rather than a bare refusal."
fi
say ""
say "steps the armed run performs, in a throwaway config (HOME/XDG under mktemp):"
for s in "copy the plugin into the temp config, trust it there, write the token it resolves" \
    "grant file:~/.config/eidolon/browser.token to each verb, in the temp config only" \
    "browser_open a data: URL (no network)" \
    "browser_snapshot, browser_read (the page as text)" \
    "browser_click a ref from that snapshot" \
    "browser_back"; do
    say "  - $s"
done
say ""
say "never: starting the service, installing into ~/.config/eidolon, or navigating to a real page"
say "cleanup: the throwaway config is deleted; nothing under ~/.config/eidolon is written"

if [ "${BROWSER_SMOKE_GO:-}" != "1" ]; then
    say ""
    say "DRY RUN: nothing was run."
    exit 0
fi
[ "$up" = yes ] || { say ""; say "armed but the service is not answering: refusing rather than starting it"; exit 2; }

work=$(mktemp -d)
export HOME=$work XDG_CONFIG_HOME=$work/cfg XDG_STATE_HOME=$work/state XDG_DATA_HOME=$work/data
mkdir -p "$XDG_CONFIG_HOME/eidolon/plugins"
plug=$XDG_CONFIG_HOME/eidolon/plugins
cp -r "$repo/browser" "$plug/browser"
eidolon=$(command -v eidolon)
"$eidolon" plugins trust browser >/dev/null
mkdir -p "$HOME/.config/eidolon"
(umask 077 && head -c 24 /dev/urandom | base64 > "$HOME/.config/eidolon/browser.token")
for v in open snapshot click type read back; do
    "$eidolon" plugins grant "browser_$v" "file:~/.config/eidolon/browser.token" >/dev/null
done
page='data:text/html,<title>smoke</title><h1>smoke</h1><a href="data:text/html,<h1>next</h1>">next</a>'
say ""
say "the plugin is installed and trusted in $XDG_CONFIG_HOME only; the service is $health, untouched"
say "run this by hand in that config (or point a session at it):"
say "  eidolon run --provider mock --yolo 'call browser_open with url \"$page\", then browser_snapshot, then browser_read'"
say ""
say "arm the service first if it is not up; the smoke never starts it."
exit 0
