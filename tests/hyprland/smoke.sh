#!/usr/bin/env bash
# smoke.sh: the hyprland plugin's live smoke — its own scratch sink, a throwaway config, and no
# other window touched. DRY BY DEFAULT; armed by HYPRLAND_SMOKE_GO=1.
#
#   bash tests/hyprland/smoke.sh                 # print the plan; touch nothing
#   HYPRLAND_SMOKE_GO=1 bash tests/hyprland/smoke.sh
#
# It creates the sink itself and closes it itself (by killing the process it spawned, never by
# closing a window it did not create), announces the input with a countdown so hands can clear,
# and aborts on the first sign that the target or the focus is not what it aimed at. The sink is
# an inert reader: it appends what it receives to a log and executes nothing, and no shell
# command is ever sent to it.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
title=hyprland-smoke
text="hyprland smoke ok"
run_dir=${HYPRLAND_SMOKE_DIR:-/tmp/hyprland-smoke}
announce_s=${HYPRLAND_SMOKE_ANNOUNCE_S:-15}
# The plugin's declared runtime package, used ephemerally: a store path's bin directory put in
# front of PATH for this run only — no profile, no system install, and the input clients are never
# executed for help or version (their man pages are what this plugin was written against).
runtime_bin=${HYPRLAND_SMOKE_RUNTIME_BIN:-}
# The real home, before HOME is replaced by the throwaway one: the durable evidence goes there,
# not into a temp directory that is about to be deleted.
real_home=$HOME
say() { printf '%s\n' "$*"; }

# ---- guards ----------------------------------------------------------------------------------
command -v hyprctl >/dev/null || { say "refusing: hyprctl is not on PATH"; exit 2; }
command -v foot >/dev/null || { say "refusing: foot (the sink's terminal) is not on PATH"; exit 2; }
[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || { say "refusing: no Hyprland session in this environment"; exit 2; }
if hyprctl -j clients 2>/dev/null | grep -q "\"title\": \"$title\""; then
    say "refusing: a window titled $title already exists — that is not this script's sink"; exit 2
fi

if [ -n "$runtime_bin" ]; then
    [ -d "$runtime_bin" ] || { say "refusing: HYPRLAND_SMOKE_RUNTIME_BIN is not a directory: $runtime_bin"; exit 2; }
    export PATH="$runtime_bin:$PATH"
fi

say "== hyprland live smoke (own scratch sink) =="
say "runtime: ${runtime_bin:-<ordinary PATH>} — input clients: $(command -v wlrctl 2>/dev/null || echo '<absent: the input steps will refuse by name>') / $(command -v wtype 2>/dev/null || echo '<absent>')"
say "sink title: $title      terminal: foot -e the sink script      evidence: $run_dir/sink.log"
say "steps when armed: create the sink, find it by title, focus it, VERIFY it is focused and its"
say "fingerprint is unchanged, screenshot it, click (button left) at 30,30 inside it, type the"
say "text, press Return, press Escape, scroll; then two refusals that must inject nothing."
say "then: read $run_dir/sink.log (the typed line must be there, once), assert every expected"
say "step is ok and no step erred, kill the sink's own process, delete the throwaway config."
say ""
say "abort rules: sink missing, sink gone, sink moved or changed, sink not focused after the"
say "focus step, any ERR in an expected step, anything in the sink log but the one line."
if [ "${HYPRLAND_SMOKE_GO:-}" != "1" ]; then
    say ""
    say "DRY RUN: nothing was run and nothing on the desktop was touched."
    exit 0
fi

# ---- armed: announce, then act ---------------------------------------------------------------
say ""
say "!! INPUT COMING: the pointer will move inside the sink window and one line will be typed"
say "!! into it. Keep hands off the keyboard and mouse for ${announce_s}s. The sink is the only"
say "!! window this script aims at; anything else it will refuse to touch."
for i in $(seq "$announce_s" -1 1); do printf '   %s...\r' "$i"; sleep 1; done; printf '   go\n'

work=$(mktemp -d)
mkdir -p "$run_dir"
: > "$run_dir/sink.log"
cat > "$run_dir/sink.sh" <<'SINK'
#!/bin/sh
# The sink: an inert reader. It appends what it receives and executes nothing. No prompt, no
# PATH lookup, no command from its input.
printf 'ready\n' >> /tmp/hyprland-smoke/sink.log
while IFS= read -r line; do
    printf 'received: %s\n' "$line" >> /tmp/hyprland-smoke/sink.log
done
SINK
chmod +x "$run_dir/sink.sh"

sink_pid=""
cleanup() {
    # Close the sink by ending the process that owns it — never by closing a window this script
    # did not create.
    if [ -n "$sink_pid" ] && kill -0 "$sink_pid" 2>/dev/null; then kill "$sink_pid" 2>/dev/null || true; fi
    rm -rf "$work"
}
trap cleanup EXIT

hyprctl dispatch "hl.dsp.exec_cmd(\"foot --title $title -a $title -e /bin/sh $run_dir/sink.sh\")" >/dev/null
found=no
for _ in $(seq 1 60); do
    sink_pid=$(hyprctl -j clients 2>/dev/null | python3 -c '
import json,sys
for w in json.load(sys.stdin):
    if "title" in w and "hyprland-smoke" in (w.get("title") or ""):
        print(w.get("pid")); break
' 2>/dev/null || true)
    [ -n "$sink_pid" ] && { found=yes; break; }
    sleep 0.25
done
[ "$found" = yes ] || { say "FAIL: the sink never appeared"; exit 1; }
say "sink: pid $sink_pid (the process this script will end)"

export HOME=$work XDG_CONFIG_HOME=$work/cfg XDG_STATE_HOME=$work/state XDG_DATA_HOME=$work/data
mkdir -p "$XDG_CONFIG_HOME/eidolon/plugins"
plug=$XDG_CONFIG_HOME/eidolon/plugins
cp -r "$repo/hyprland" "$plug/hyprland"
cp "$here/live.rn" "$plug/hyprland/workflows/live.rn"
eidolon=$(command -v eidolon)
"$eidolon" plugins trust hyprland >/dev/null

args=$(python3 -c 'import json,sys; print(json.dumps({"title": sys.argv[1], "text": sys.argv[2]}))' "$title" "$text")
"$eidolon" workflow run "$plug/hyprland" live --provider mock --args "$args" >"$work/live.out" 2>&1 || true

say ""
say "---- the run's whole output ----"
cat "$work/live.out"
say "-------------------------------"
say "---- the sink's own log ----"
cat "$run_dir/sink.log"
say "----------------------------"

python3 - "$work/live.out" "$run_dir/sink.log" "$text" <<'PYASSERT'
import json, sys
# Two paths and a string: the text is the *expected line*, not a file to open.
raw, sink, text = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3]
line = next((l for l in raw.splitlines() if l.startswith("{")), "")
ok, fail = [], []
def want(c, t):
    (ok if c else fail).append(t)
report = ""
if line:
    obj = json.loads(line)
    report = obj.get("report", "") or ""
    want(obj.get("status") == "completed", f"the run completed (status={obj.get('status')})")
else:
    fail.append("no JSON line from the run")
have = "ok   " in report
want(have, "the report carries steps")
for step in ["ok   focus", "ok   screenshot window", "ok   click", "ok   type", "ok   return", "ok   key", "ok   scroll"]:
    want(step in report, f"step present: {step}")
want("verified: the sink is the focused window" in report, "the sink was verified focused before any act")
# The refusals are *expected* to be errors — a refusal is `is_error: true`, which a workflow
# script sees as an `Err`, so `step()` writes `ERR  refuse: …`. Asserting their absence would
# invert the meaning, and (worse) would pass if the refusal had failed to refuse: the tool would
# then answer `ok   refuse: …` and the click's refusal would be invisible to the sink log, which
# only ever sees text. So: both refusals must be present as errors, exactly two, and no other
# step may have erred.
refusals = [l for l in report.splitlines() if l.startswith("ERR  refuse:")]
want(len(refusals) == 2, f"both refusals fired as refusals (found {len(refusals)})")
want(any("stale fingerprint" in l for l in refusals), "the stale-fingerprint click refused rather than clicked")
want(any("contains a newline" in l for l in refusals), "the newline text refused rather than typed")
other = [l for l in report.splitlines() if l.startswith("ERR") and not l.startswith("ERR  refuse:")]
want(not other, f"no step but the two refusals erred: {other}")
lines = [l for l in sink.splitlines() if l.strip()]
want(lines and lines[0] == "ready", f"the sink started and logged it: {lines[:1]}")
want(lines.count(f"received: {text}") == 1, "the typed line reached the sink exactly once")
want(len(lines) == 2, f"nothing else reached the sink: {lines[1:]}")
for l in ok: print("PASS", l)
for l in fail: print("FAIL", l)
sys.exit(1 if fail else 0)
PYASSERT
verdict=$?

python3 - "$work/live.out" "$run_dir/sink.log" "$real_home" <<'PYLOGS'
import pathlib, sys
src, sink, dest = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
durable = dest / ".local/share/eidolon/reports/hyprland-live-smoke"
durable.mkdir(parents=True, exist_ok=True)
for p in (src, sink):
    text = pathlib.Path(p).read_text(errors="replace")
    (durable / pathlib.Path(p).name).write_text(text)
print(durable)
PYLOGS
say ""
say "logs kept: ~/.local/share/eidolon/reports/hyprland-live-smoke/"
say "verdict: $([ $verdict -eq 0 ] && echo "the live smoke passed" || echo "the live smoke FAILED")"
exit $verdict
