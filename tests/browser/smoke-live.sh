#!/usr/bin/env bash
# smoke-live.sh: the browser plugin's REAL smoke — a real `eidolon-browser` and a real Chromium,
# isolated from the operator's service: its own port, its own token minted for the run, its own
# disposable profile (the service makes one under TMPDIR and removes it), its own log.
#
# DRY BY DEFAULT; the coordinator owns when it runs. It starts two processes of its own and kills
# them, group and all, on the way out.
#
#   bash tests/browser/smoke-live.sh
#   BROWSER_LIVE_GO=1 bash tests/browser/smoke-live.sh        # BROWSER_LIVE_NO_SANDBOX=1 if Chromium's sandbox cannot start
#
# Never: the operator's token (not read, not copied, not needed), the operator's service on 8090
# (not contacted, not stopped), the operator's config, or a network fetch — the pages are served
# from 127.0.0.1 by tests/browser/fixture.py.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
port=${BROWSER_LIVE_PORT:-8099}
fixture_port=${BROWSER_LIVE_FIXTURE_PORT:-8098}
say() { printf '%s\n' "$*"; }

# ---- the guards, before anything is started --------------------------------------------------
free() { ! timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }
svc_bin=$(command -v eidolon-browser || true)
chrome=${EIDOLON_BROWSER_CHROME:-$(command -v chromium || command -v google-chrome || true)}
eidolon=$(command -v eidolon || true)
for what in svc_bin chrome eidolon; do
    [ -n "${!what}" ] || { say "refusing: $what is not on PATH"; exit 2; }
done
free "$port" || { say "refusing: 127.0.0.1:$port is already occupied — a dedicated port is the point"; exit 2; }
free "$fixture_port" || { say "refusing: 127.0.0.1:$fixture_port is already occupied"; exit 2; }

say "== browser live smoke (real service, real Chromium, isolated) =="
say "service: $svc_bin on 127.0.0.1:$port   chromium: $chrome"
say "pages: tests/browser/fixture.py on 127.0.0.1:$fixture_port (two inert pages, no external assets)"
say "profile: the service makes a disposable one under TMPDIR and removes it (browser.rs:110, sweep.rs)"
say ""
if [ "${BROWSER_LIVE_GO:-}" != "1" ]; then
    say "steps when armed:"
    for s in "start the service on $port with EIDOLON_SERVICE_TOKEN=<minted> and EIDOLON_BROWSER_CHROME" \
        "wait for /health AND for our own service pid to still be alive" \
        "start the fixture on $fixture_port; wait for it to answer" \
        "throwaway config; copy the plugin; retarget the copies at $port and the temp token; trust and grant there" \
        "run the live workflow: open, snapshot, read, find the next link's ref, click it, read again, back" \
        "assert: status completed, every step ok, the second read carries the second page's text, no ERR" \
        "kill our service's process group and the fixture's; keep redacted logs under /tmp/eidolon-browser-smoke-*"; do
        say "  - $s"
    done
    say ""
    say "DRY RUN: nothing was started."
    exit 0
fi

# ---- armed ------------------------------------------------------------------------------------
work=$(mktemp -d)
logs=$(mktemp -d "${TMPDIR:-/tmp}/eidolon-browser-smoke-XXXXXX")
token_file=$work/browser.token
(umask 077 && head -c 24 /dev/urandom | base64 | tr -d '\n' > "$token_file")
token=$(cat "$token_file")
cleanup() {
    for pid in "${svc_pid:-}" "${fix_pid:-}"; do
        [ -n "$pid" ] || continue
        kill -TERM -- "-$pid" 2>/dev/null || true
    done
    sleep 1
    for pid in "${svc_pid:-}" "${fix_pid:-}"; do
        [ -n "$pid" ] || continue
        kill -KILL -- "-$pid" 2>/dev/null || true
    done
    rm -rf "$work"
}
trap cleanup EXIT

setsid env EIDOLON_SERVICE_PORT="$port" EIDOLON_SERVICE_TOKEN="$token" EIDOLON_BROWSER_CHROME="$chrome" \
    ${BROWSER_LIVE_NO_SANDBOX:+EIDOLON_BROWSER_NO_SANDBOX=1} \
    "$svc_bin" >"$work/service.log" 2>&1 &
svc_pid=$!
say "service pid $svc_pid (process group), log $work/service.log"

healthy=no
for _ in $(seq 1 60); do
    if ! kill -0 "$svc_pid" 2>/dev/null; then
        say "FAIL: our service exited before it answered"; sed -n 1,20p "$work/service.log"; exit 1
    fi
    if timeout 1 curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1; then healthy=yes; break; fi
    sleep 0.5
done
[ "$healthy" = yes ] || { say "FAIL: /health did not answer on $port"; sed -n 1,20p "$work/service.log"; exit 1; }
kill -0 "$svc_pid" 2>/dev/null || { say "FAIL: service died right after answering"; exit 1; }
say "health: $(timeout 2 curl -fsS "http://127.0.0.1:$port/health")"

setsid python3 "$here/fixture.py" --port "$fixture_port" >"$work/fixture.log" 2>&1 &
fix_pid=$!
page=no
for _ in $(seq 1 40); do timeout 1 curl -fsS "http://127.0.0.1:$fixture_port/" >/dev/null 2>&1 && { page=yes; break; }; sleep 0.25; done
[ "$page" = yes ] || { say "FAIL: the fixture did not answer"; exit 1; }

export HOME=$work XDG_CONFIG_HOME=$work/cfg XDG_STATE_HOME=$work/state XDG_DATA_HOME=$work/data
mkdir -p "$XDG_CONFIG_HOME/eidolon/plugins"
plug=$XDG_CONFIG_HOME/eidolon/plugins
cp -r "$repo/browser" "$plug/browser"
cp "$here/live.rn" "$plug/browser/workflows/live.rn"
for f in "$plug"/browser/tools/*.rn; do
    sed -i "s|http://127.0.0.1:8090|http://127.0.0.1:$port|; s|token_file: \"~/.config/eidolon/browser.token\"|token_file: \"$token_file\"|" "$f"
done
"$eidolon" plugins trust browser >/dev/null
for v in open snapshot click type read back; do "$eidolon" plugins grant "browser_$v" "file:$token_file" >/dev/null; done

base="http://127.0.0.1:$fixture_port/"
args=$(python3 -c 'import json,sys; print(json.dumps({"base": sys.argv[1]}))' "$base")
"$eidolon" workflow run "$plug/browser" live --provider mock --args "$args" >"$work/workflow.out" 2>&1 || true

say ""
say "---- the run's whole output ----"
cat "$work/workflow.out"
say "-------------------------------"

# The assertions, on the bytes above rather than on faith.
python3 - "$work/workflow.out" <<'PYASSERT'
import json, sys
raw = open(sys.argv[1]).read()
line = next((l for l in raw.splitlines() if l.startswith("{")), "")
ok, fail = [], []
def want(cond, text):
    (ok if cond else fail).append(text)
if not line:
    fail.append("no JSON line from the run"); report = ""
else:
    obj = json.loads(line)
    report = obj.get("report", "") or ""
    want(obj.get("status") == "completed", f"the run completed (status={obj.get('status')})")
for step in ["ok   open:", "ok   snapshot:", "ok   read:", "ok   click", "ok   read after the click:", "ok   back:"]:
    want(step in report, f"step present: {step}")
have_steps = "ok   " in report
want(have_steps, "the report carries steps at all (a refusal has none to be free of errors in)")
want(have_steps and "ERR" not in report, "no step errored")
after = ""
for l in report.splitlines():
    if l.startswith("ok   read after the click:"):
        after = l
want("the second page" in after, "the read after the click is the SECOND page (navigation happened)")
want("smoke home" in report, "the home page was read before the click")
for l in ok: print("PASS", l)
for l in fail: print("FAIL", l)
sys.exit(1 if fail else 0)
PYASSERT
verdict=$?

# Durable, sanitized logs.
python3 - "$token" "$work/service.log" "$work/fixture.log" "$work/workflow.out" "$logs" <<'PYLOGS'
import pathlib, sys
token, *files, dest = sys.argv[1], *sys.argv[2:-1], sys.argv[-1]
for f in files:
    src = pathlib.Path(f)
    if not src.exists():
        continue
    text = src.read_text(errors="replace").replace(token, "<token redacted>")
    (pathlib.Path(dest) / src.name).write_text(text)
print(dest)
PYLOGS
grep -rl "$token" "$logs" 2>/dev/null && say "FAIL: a token survived redaction" || true
say ""
say "logs kept (token redacted): $logs"
say "verdict: $([ $verdict -eq 0 ] && echo "the live smoke passed" || echo "the live smoke FAILED")"
exit $verdict
