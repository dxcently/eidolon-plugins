#!/usr/bin/env bash
# smoke.sh: a CONTRACT TEST for the browser tools, through a stand-in service — no Chromium, no
# page, no network, and no real token. It is not the browser plugin's live smoke: nothing here
# renders or navigates, and canned answers are not evidence about Chromium or about the real
# service. The real smoke is tests/browser/smoke-live.sh (a real isolated eidolon-browser and a
# real Chromium); this one is what runs anywhere, any time, and it is what a tool-contract change
# should be checked against. DRY BY DEFAULT.
#
#   bash tests/browser/smoke.sh            # print the plan and whether a service is up (read-only)
#   BROWSER_SMOKE_GO=1 bash tests/browser/smoke.sh   # run the mock path end to end
#
# The mock path is the whole smoke: tests/browser/stub.py speaks the same wire as the service
# (health + `{method, args}` with a bearer token), the temp plugin copy is pointed at it, and a
# token is minted *in the throwaway config* for it. Nothing reads, copies or needs the operator's
# real token, and no service is started or contacted.
#
# The real service is deliberately not part of this smoke. A throwaway HOME gets a *new* token
# and a new base_url can only be had by editing the tool files, so a temp-config run can never
# authenticate an already-running service that holds the real token — the honest way to exercise
# that pairing is the operator's own session, not a smoke that copies a credential about. What
# the dry run does do is probe `/health` (read-only) and print the manual start command if it is
# down, because a tool call with the service down answers with that command.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
port=8099
health=http://127.0.0.1:8090/health
say() { printf '%s\n' "$*"; }

real=no
if timeout 3 curl -fsS "$health" >/dev/null 2>&1; then real=yes; fi

say "== browser smoke: contract test through a stand-in (NOT the live smoke) =="
say "the operator's service on 8090: ${real} (probed read-only; this smoke does not use it either way)"
if [ "$real" = no ]; then
    say "  if a session wants it up: eidolon plugins service start browser   (manual, by the operator)"
    say "  a tool call while it is down answers with that command, not a bare refusal"
fi
say ""
say "steps:"
for s in "throwaway config (mktemp HOME/XDG_*); copy the plugin in; trust it THERE"     "point the temp copy's tools at the stand-in: base_url http://127.0.0.1:$port, token_file in the temp dir"     "mint a token in the temp dir and grant file:<temp token> to each verb (temp config only)"     "start tests/browser/stub.py on $port with that token; wait for /health"     "run the smoke workflow with --provider mock: open, snapshot, read, click e1, open again, click a stale ref (must be refused), back"     "stop the stand-in; delete the throwaway config"; do
    say "  - $s"
done
say ""
say "never: reading or copying the operator's token, contacting or starting a real service, or"
say "navigating to a real page (the only URL is a .invalid host the stand-in answers itself)"

if [ "${BROWSER_SMOKE_GO:-}" != "1" ]; then
    say ""
    say "DRY RUN: nothing was run."
    exit 0
fi

work=$(mktemp -d)
cleanup() { [ -n "${stub_pid:-}" ] && kill "$stub_pid" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
export HOME=$work XDG_CONFIG_HOME=$work/cfg XDG_STATE_HOME=$work/state XDG_DATA_HOME=$work/data
mkdir -p "$XDG_CONFIG_HOME/eidolon/plugins"
plug=$XDG_CONFIG_HOME/eidolon/plugins
cp -r "$repo/browser" "$plug/browser"
cp "$here/smoke.rn" "$plug/browser/workflows/smoke.rn"
token=$work/browser.token
(umask 077 && head -c 24 /dev/urandom | base64 > "$token")

# The temp copy is pointed at the stand-in. This edits *the copy*; the repo's bytes are untouched.
for f in "$plug"/browser/tools/*.rn; do
    sed -i "s|http://127.0.0.1:8090|http://127.0.0.1:$port|; s|token_file: \"~/.config/eidolon/browser.token\"|token_file: \"$token\"|" "$f"
done
say "retargeted $(grep -l "127.0.0.1:$port" "$plug"/browser/tools/*.rn | wc -l) tool file(s) at $port"

eidolon=$(command -v eidolon)
"$eidolon" plugins trust browser >/dev/null
for v in open snapshot click type read back; do
    "$eidolon" plugins grant "browser_$v" "file:$token" >/dev/null
done

python3 "$here/stub.py" --port "$port" --token-file "$token" >"$work/stub.log" 2>&1 &
stub_pid=$!
for _ in $(seq 1 40); do
    if timeout 1 curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1; then break; fi
    sleep 0.25
done
say ""
say "stand-in: $(timeout 2 curl -fsS "http://127.0.0.1:$port/health" 2>&1)"
say ""
"$eidolon" workflow run "$plug/browser" smoke --provider mock 2>&1 | grep -E "^\{|ok |ERR " | head -20 || true
say ""
say "the run's own line above is the evidence; the stale-ref step must read ERR (the service"
say "refuses a ref whose page moved), and every other step ok. Nothing else was contacted."
