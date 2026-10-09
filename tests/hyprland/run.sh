#!/usr/bin/env bash
# run.sh: check the hyprland plugin against fake compositor clients, one selftest case at a
# time (or every case with no argument).
#
#   bash tests/hyprland/run.sh              # every case
#   bash tests/hyprland/run.sh click-stale  # one case
#
# What it guarantees about the environment, because these tools can move a real pointer:
#   * HOME, XDG_CONFIG_HOME, XDG_STATE_HOME and XDG_DATA_HOME must be throwaway — the
#     guard refuses otherwise (this harness installs fake clients and trusts a plugin).
#   * WAYLAND_DISPLAY, DISPLAY, HYPRLAND_INSTANCE_SIGNATURE and XDG_SESSION_TYPE are
#     removed, and PATH is stubs-first with no directory that holds the real hyprctl,
#     grim, wlrctl or wtype — so neither the tools nor a fake can reach a live session.
#   * the fake wlrctl fails the run if a `pointer click` ever arrives without an explicit
#     button (wlrctl's own CLI would click the left one), and the harness asserts no such
#     line is in the log.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
. "$here/guard.sh"
require_temp_config || exit 2

: "${XDG_STATE_HOME:?set XDG_STATE_HOME to a temp dir}"
: "${XDG_DATA_HOME:?set XDG_DATA_HOME to a temp dir}"

eidolon=$(command -v eidolon || true)
python3=$(command -v python3 || true)
[ -n "$eidolon" ] || { echo "eidolon is not on PATH" >&2; exit 2; }
[ -n "$python3" ] || { echo "python3 is not on PATH" >&2; exit 2; }

cases=${*:-$("$python3" -c 'import runpy, sys; print(" ".join(sorted(runpy.run_path(sys.argv[1])["CASES"])))' "$here/scenarios.py")}

# The stubs, the plugin under test, and a small real PNG for grim to "capture".
work=$(mktemp -d)
bin=$work/bin
mkdir -p "$bin"
cp "$here"/stubs/* "$bin/"
chmod +x "$bin"/*
plug=$XDG_CONFIG_HOME/eidolon/plugins
mkdir -p "$plug"
rm -rf "$plug/hyprland"
cp -r "$repo/hyprland" "$plug/hyprland"

png=$work/tiny.png
"$python3" - "$png" <<'PY'
import base64, sys
# A 1x1 PNG: the smallest thing image_read will accept as a picture.
open(sys.argv[1], "wb").write(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
PY

# Trust in the throwaway config: the tools are mutating, so without a vouch every call
# would sit at the gate waiting for a person. This is a temp config; nothing here is the
# operator's.
XDG_CONFIG_HOME=$XDG_CONFIG_HOME "$eidolon" plugins trust hyprland >/dev/null

fail=0
for case in $cases; do
    fixture=$work/fixture-$case
    state=$work/state-$case
    mkdir -p "$fixture" "$state"
    "$python3" "$here/scenarios.py" "$case" "$fixture"
    "$python3" - "$fixture/cursor.json" "$state/cursor" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
open(sys.argv[2], "w").write(f"{c['x']} {c['y']}\n")
PY
    args='{"case":"'"$case"'"}'
    case "$case" in
    click-hidden | screenshot-hidden | scroll-hidden | type-hidden | key-hidden)
        args='{"case":"'"$case"'","class":"hidden-app"}' ;;
    click-pinned) args='{"case":"'"$case"'","class":"pinned-app"}' ;;
    click-special-closed | screenshot-special-closed)
        args='{"case":"'"$case"'","class":"scratch-app"}' ;;
    esac

    if [ "$case" = "tools-missing" ]; then
        # A session that has no input client on PATH at all.
        rm -f "$bin/wlrctl" "$bin/wtype"
    else
        cp "$here"/stubs/* "$bin/"
        chmod +x "$bin"/*
    fi

    # Only the stubs and a system set that holds none of the real clients.
    env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u XDG_SESSION_TYPE \
        PATH="$bin:/run/current-system/sw/bin:/usr/bin:/bin" \
        HOME=$HOME XDG_CONFIG_HOME=$XDG_CONFIG_HOME XDG_STATE_HOME=$XDG_STATE_HOME XDG_DATA_HOME=$XDG_DATA_HOME \
        HYPRLAND_FIXTURE=$fixture HYPRLAND_STATE=$state HYPRLAND_FIXTURE_PNG=$png \
        "$eidolon" workflow run "$plug/hyprland" selftest --args "$args" --provider mock \
        >"$state/report.txt" 2>&1 || true

    problems=()
    grep -q "checks hold" "$state/report.txt" || problems+=("the report did not say every check holds")
    if grep -q "^FAIL" "$state/report.txt"; then
        problems+=("a check failed: $(grep -m1 '^FAIL' "$state/report.txt")")
    fi
    if grep -q "is_error" "$state/report.txt"; then
        problems+=("the run reported an error")
    fi
    # No fake client may have seen a bare click, whatever else happened.
    if [ -f "$state/input.log" ] && grep -q "^BAD" "$state/input.log"; then
        problems+=("a bare \`pointer click\` reached the input client: $(grep -m1 '^BAD' "$state/input.log")")
    fi

    expect_input() {
        if [ "$(cat "$state/input.log" 2>/dev/null || true)" != "$1" ]; then
            problems+=("input log is $(printf '%q' "$(cat "$state/input.log" 2>/dev/null || true)"), want $(printf '%q' "$1")")
        fi
    }
    expect_no_input() {
        if [ -s "$state/input.log" ]; then
            problems+=("something was injected: $(tr '\n' ';' <"$state/input.log")")
        fi
    }
    expect_grim() {
        if [ "$(cat "$state/grim.log" 2>/dev/null || true)" != "$1" ]; then
            problems+=("grim log is $(printf '%q' "$(cat "$state/grim.log" 2>/dev/null || true)"), want $(printf '%q' "$1")")
        fi
    }
    expect_no_grim() {
        if [ -s "$state/grim.log" ]; then
            problems+=("the screen was captured: $(cat "$state/grim.log")")
        fi
    }
    expect_no_dispatch() {
        if [ -s "$state/dispatch.log" ]; then
            problems+=("the compositor was dispatched to: $(tr '\n' ';' <"$state/dispatch.log")")
        fi
    }
    expect_dispatch_contains() {
        grep -qF "$1" "$state/dispatch.log" 2>/dev/null || problems+=("dispatch log does not mention $1")
    }

    shot=/tmp/eidolon-hyprland
    case "$case" in
    inspect | inspect-pinned | inspect-special | inspect-special-closed | visibility)
        expect_no_input
        expect_no_grim
        expect_no_dispatch
        ;;
    click)
        expect_input "wlrctl pointer move 886 -243
wlrctl pointer click left"
        expect_no_grim
        expect_no_dispatch
        ;;
    click-pinned)
        expect_input "wlrctl pointer move 886 -243
wlrctl pointer click left"
        expect_no_grim
        expect_no_dispatch
        ;;
    click-no-button | click-stale | click-gone | click-replaced | click-hidden | click-special-closed)
        expect_no_input
        expect_no_dispatch
        ;;
    scroll-hidden | type-hidden | key-hidden)
        expect_no_input
        expect_no_dispatch
        ;;
    click-pointer-miss)
        expect_input "wlrctl pointer move 886 -243"
        ;;
    # The guard before the press: the pointer moved and nothing else did. A world that changed in
    # between must leave the pointer move alone in the log and no button pressed.
    click-monitor-switch | click-moved-midway | click-hidden-midway | click-unmapped-midway | click-input-refused-midway | click-pointer-drift)
        expect_input "wlrctl pointer move 886 -243"
        expect_no_grim
        expect_no_dispatch
        ;;
    scroll-monitor-switch)
        expect_input "wlrctl pointer move 1732 205"
        expect_no_grim
        expect_no_dispatch
        ;;
    # A multi-click stops at the press whose guard refuses: the presses that went in are in the
    # log, and no more.
    click-monitor-switch-mid-count)
        expect_input "wlrctl pointer move 886 -243
wlrctl pointer click left"
        expect_no_grim
        expect_no_dispatch
        ;;
    scroll)
        expect_input "wlrctl pointer move 1732 205
wlrctl pointer scroll 3 0"
        ;;
    type)
        expect_input "wtype -- hello from the selftest"
        expect_no_dispatch
        ;;
    type-not-focused | type-control | key-bad-mod)
        expect_no_input
        ;;
    type-focus-first)
        expect_dispatch_contains 'hl.dsp.focus({ window = w })'
        expect_input "wtype -- hello from the selftest"
        ;;
    key)
        expect_input "wtype -M ctrl -k Escape -m ctrl"
        ;;
    screenshot-monitor)
        expect_grim "grim -o DP-2 $shot/monitor-DP-2.png"
        expect_no_input
        expect_no_dispatch
        ;;
    screenshot-window)
        expect_grim "grim -g 1934,69 1892x997 $shot/window-0x562e1ac89e30.png"
        ;;
    screenshot-region)
        expect_grim "grim -g 2034,119 100x50 $shot/window-0x562e1ac89e30.png"
        ;;
    screenshot-hidden | screenshot-special-closed)
        expect_no_grim
        expect_no_dispatch
        ;;
    tools-missing)
        expect_no_input
        ;;
    focus-window)
        expect_dispatch_contains 'hl.get_window("address:0x562e1ac89e30")'
        expect_no_input
        ;;
    focus-workspace)
        expect_dispatch_contains 'hl.dsp.focus({ workspace = 11 })'
        ;;
    focus-refused)
        if [ ! -s "$state/dispatch.log" ]; then
            problems+=("the dispatcher was never called")
        fi
        expect_no_input
        ;;
    esac

    if [ ${#problems[@]} -eq 0 ]; then
        echo "ok   $case"
    else
        fail=1
        echo "FAIL $case" >&2
        for p in "${problems[@]}"; do
            echo "       $p" >&2
        done
        sed -n 1,40p "$state/report.txt" >&2
    fi
done

# The capture path is the one thing every run leaves behind (a 1x1 fixture, not a screen).
rm -rf "${shot:-/tmp/eidolon-hyprland}"
if [ $fail -eq 0 ] && [ $# -eq 0 ]; then echo "ok   every case"; fi
exit $fail
