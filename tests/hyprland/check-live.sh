#!/usr/bin/env bash
# check-live.sh: the `visibility` case against the session that is really running — the one piece
# of the plugin's behaviour a fixture cannot stand in for, because it is about what the compositor
# itself answers.
#
#   bash tests/hyprland/check-live.sh
#
# READ-ONLY, and that is the whole of it: the case calls `hyprland_inspect` and nothing else — no
# input client runs, nothing is captured, no window is focused, moved or closed, and no `hyprctl`
# dispatcher is called. It reads `hyprctl -j monitors|workspaces|clients|activewindow|cursorpos`
# and compares the visibility it reports with the rule re-derived from the monitors it reported.
#
# The plugin is copied into a throwaway config and vouched for there; the operator's own
# ~/.config/eidolon is neither read nor written, and the installed plugin is left alone. What the
# case cannot check is the installed copy: `eidolon plugins update hyprland` is what puts a fixed
# tree there.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

# A throwaway home and config, made here so this runs as one command.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME=$work XDG_CONFIG_HOME=$work/cfg XDG_STATE_HOME=$work/state XDG_DATA_HOME=$work/data
. "$here/guard.sh"
require_temp_config || exit 2

command -v hyprctl >/dev/null || { echo "refusing: hyprctl is not on PATH"; exit 2; }
hyprctl version >/dev/null 2>&1 || { echo "refusing: hyprctl cannot reach a running compositor"; exit 2; }
eidolon=$(command -v eidolon || true)
[ -n "$eidolon" ] || { echo "refusing: eidolon is not on PATH"; exit 2; }

plug=$XDG_CONFIG_HOME/eidolon/plugins
mkdir -p "$plug"
rm -rf "$plug/hyprland"
cp -r "$repo/hyprland" "$plug/hyprland"
"$eidolon" plugins trust hyprland >/dev/null

hyprctl -j monitors >"$work/monitors.json" 2>/dev/null || true
python3 - "$work/monitors.json" <<'PY' || echo "session: unknown"
import json, sys
try:
    monitors = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
shown = []
for m in monitors:
    line = f"{m['name']} -> workspace {m['activeWorkspace']['id']}"
    if m.get("specialWorkspace", {}).get("name"):
        line += f" (special {m['specialWorkspace']['name']})"
    shown.append(line)
print("session: " + ", ".join(shown))
PY

# WAYLAND_DISPLAY and HYPRLAND_INSTANCE_SIGNATURE stay: this is a live check, and hyprland_inspect
# is the thing under test. Nothing fake goes on PATH, so no injection is possible from here.
"$eidolon" workflow run "$plug/hyprland" selftest --args '{"case":"visibility"}' --provider mock \
    >"$work/out" 2>&1 || true

python3 - "$work/out" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
line = next((l for l in raw.splitlines() if l.startswith("{")), "")
if not line:
    print(raw.rstrip())
    print("FAIL the run printed no JSON line")
    sys.exit(1)
obj = json.loads(line)
report = obj.get("report", "") or ""
failed = []
for l in report.splitlines():
    if l.startswith("ok   "):
        print("PASS", l[5:])
    elif l.startswith("note:"):
        print("NOTE", l[5:].strip())
    elif l.startswith("FAIL"):
        failed.append(l)
        print("FAIL", l[5:])
print(f"status: {obj.get('status')}")
if "is_error" in raw or failed or "checks hold" not in report:
    print("verdict: the live visibility check FAILED")
    sys.exit(1)
print("verdict: the live visibility check passed")
PY
