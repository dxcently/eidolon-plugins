#!/usr/bin/env bash
# smoke.sh: the operator-gated live smoke for the hyprland plugin.
#
# DRY BY DEFAULT. With no HYPRLAND_SMOKE_GO=1 this prints the exact sequence and touches
# nothing: no compositor call, no window, no key. Armed, it runs the same sequence through the
# plugin's own verbs against the operator's compositor, aimed at one sink window the operator
# names — and it installs nothing, trusts nothing outside its throwaway config, and never
# starts a service (the plugin has none).
#
#   bash tests/hyprland/smoke.sh                 # print the plan (safe, any time)
#   HYPRLAND_SMOKE_GO=1 bash tests/hyprland/smoke.sh --sink-class hyprland-smoke --monitor DP-1
#
# The sink is the operator's to create and to close; the plugin has no close verb by design:
#   hyprctl dispatch 'hl.dsp.exec_cmd("foot --title hyprland-smoke -e sh -c '\''printf \"hyprland smoke sink ready\n\"; while IFS= read -r line; do printf \"received: %s\n\" \"$line\"; done'\''")'
# It reads lines and prints them. Nothing typed into it is executed: there is no prompt, no
# PATH lookup, and no command is run from its input.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
sink_class=hyprland-smoke
monitor=""
text="hyprland smoke ok"
while [ $# -gt 0 ]; do
    case "$1" in
    --sink-class) sink_class=${2:?}; shift 2 ;;
    --monitor) monitor=${2:?}; shift 2 ;;
    --text) text=${2:?}; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

armed=${HYPRLAND_SMOKE_GO:-}
work=$(mktemp -d)
say() { printf '%s\n' "$*"; }

say "== hyprland live smoke =="
say "throwaway config: $work/cfg   (HOME, XDG_CONFIG_HOME, XDG_STATE_HOME, XDG_DATA_HOME)"
say "sink class: $sink_class   monitor: ${monitor:-<from inspect>}"
say ""
say "steps, in order, every one a plugin verb:"
for s in "hyprland_inspect (read-only)" \
    "hyprland_screenshot monitor" \
    "hyprland_screenshot window (the sink, by address + fingerprint)" \
    "hyprland_focus the sink" \
    "hyprland_click (button left) at 40,40 inside the sink" \
    "hyprland_type the text into the sink" \
    "hyprland_key Escape" \
    "hyprland_scroll dy=3 at the sink" \
    "refusal: click with a deliberately stale fingerprint -> must inject nothing" \
    "refusal: text containing a newline -> must be refused, nothing typed" \
    "read the sink afterwards: its lines are the evidence"; do
    say "  - $s"
done
say ""
say "cleanup: delete $work and the PNGs under /tmp/eidolon-hyprland; the operator closes the sink"
say "(no close verb exists in this plugin, on purpose)"

if [ -z "$armed" ]; then
    say ""
    say "DRY RUN: nothing was run and nothing on the desktop was touched."
    say "To arm it: start the sink yourself (command above), then:"
    say "  HYPRLAND_SMOKE_GO=1 bash tests/hyprland/smoke.sh --sink-class $sink_class${monitor:+ --monitor $monitor}"
    say "This refuses to arm without that variable on purpose: a live run moves the pointer,"
    say "types, and presses keys in the operator's real session."
    rm -rf "$work"
    exit 0
fi

# ---- armed ----------------------------------------------------------------------------------
export HOME=$work XDG_CONFIG_HOME=$work/cfg XDG_STATE_HOME=$work/state XDG_DATA_HOME=$work/data
mkdir -p "$XDG_CONFIG_HOME/eidolon/plugins"
plug=$XDG_CONFIG_HOME/eidolon/plugins
cp -r "$repo/hyprland" "$plug/hyprland"
cp "$here/smoke.rn" "$plug/hyprland/workflows/smoke.rn"
eidolon=$(command -v eidolon)
"$eidolon" plugins trust hyprland >/dev/null

# Armed and prepared, but the workflow itself is the operator's to fire: it needs the sink's
# address and fingerprint from a real inspection *in this config*, and starting it is the act
# that moves the pointer. So the script stops here and prints both commands.
say ""
say "prepared: the plugin is trusted in $XDG_CONFIG_HOME, and smoke.rn is in its workflows/."
say "Two commands to run, in this environment (the config is kept for them):"
say ""
say "  export HOME=$HOME XDG_CONFIG_HOME=$XDG_CONFIG_HOME XDG_STATE_HOME=$XDG_STATE_HOME XDG_DATA_HOME=$XDG_DATA_HOME"
say "  eidolon run --provider mock --yolo 'call hyprland_inspect with format json and report the \"$sink_class\" window'"
say "  # take that window's address and fingerprint, then:"
say "  eidolon workflow run $plug/hyprland smoke --provider mock \\"
say "      --args '{\"address\":\"<address>\",\"expect\":\"<fingerprint>\",\"text\":\"$text\"${monitor:+,\"monitor\":\"$monitor\"}}'"
say ""
say "Every step above is a dispatched call, so the run's journal is the evidence. The three"
say "refusals are in the same run deliberately: they are the part that must inject nothing."
exit 0
