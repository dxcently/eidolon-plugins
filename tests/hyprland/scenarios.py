#!/usr/bin/env python3
"""The worlds the hyprland tools are checked against: one scenario per selftest case.

`run.sh` writes a case's directory and the fake `hyprctl` reads it: `<what>.<n>.json` is
the answer to the n-th call of that command, and the highest file at or below n wins, so a
scenario only spells out the answer a case *changes* (the window that moved between the
inspection and the click) and everything else is the steady world.

The records have the shape Hyprland 0.56 really answers `hyprctl -j ...` with, field for field
(read off a live session: `hyprctl -j clients | workspaces | monitors`):

  * a **workspace** record carries id, name, monitor, monitorID, windows, hasfullscreen,
    lastwindow, lastwindowtitle, ispersistent, tiledLayout — and *no* `visible` and *no*
    `special`. A tool has to work both out from the monitors (active and special workspaces).
  * a **window** record has `visible`, but it is `!hidden && mapped && surface && alpha`
    upstream — about the window's own surface, not about which workspace an output is showing.
    A mapped, unhidden window on a workspace nobody is showing really does answer
    `visible: true`, which is what the off-workspace windows here are for: mapped, unhidden,
    and on screen nowhere.
  * a **monitor** record names its `activeWorkspace` and its `specialWorkspace`; nothing open
    is `{"id": 0, "name": ""}`, and an open one is the workspace's own name, `special:<name>`,
    with an id in the compositor's special range (-99..-2).

Layout: two monitors side by side, DP-1 at 0,0 and DP-2 at 1920,0 with scale 2 and
transform 1 (rotated), a window on DP-2 at 1934,69 (layout coordinates, which is the one
space every tool here uses), a second window behind it, and a third window on workspace 12
which no output is showing.

    python3 tests/hyprland/scenarios.py <case> <outdir>
"""
import json
import os
import sys

FOOT = {
    "address": "0x562e1ac89e30",
    "stableId": "1800000d",
    "mapped": True,
    "hidden": False,
    "visible": True,
    "acceptsInput": True,
    "at": [1934, 69],
    "size": [1892, 997],
    "workspace": {"id": 11, "name": "11"},
    "floating": False,
    "monitor": 1,
    "class": "foot",
    "title": "~/Development/melete> ed",
    "initialClass": "foot",
    "initialTitle": "foot",
    "pid": 133265,
    "xwayland": False,
    "pinned": False,
    "fullscreen": 0,
    "fullscreenClient": 0,
    "grouped": [],
    "tags": [],
    "swallowing": "0x0",
    "focusHistoryID": 0,
    "inhibitingIdle": False,
    "contentType": "none",
}

EDITOR = dict(FOOT, address="0x562e1ac5a280", stableId="1800000e", at=[1934, 69],
              size=[932, 997], title="editor", pid=141994, focusHistoryID=1)

# On workspace 12, which no output is showing: mapped, accepting input, and — as the compositor
# itself answers — `visible: true`, because that field is about the window's own surface. What
# makes it off screen is the workspace, and only the monitors say that.
HIDDEN = dict(FOOT, address="0x562e1abbfd30", stableId="1800000f",
              size=[1892, 997], workspace={"id": 12, "name": "12"},
              title="private notes", pid=555, focusHistoryID=3)
HIDDEN["class"] = "hidden-app"

# The same shape, pinned: on a workspace nobody is showing, and on screen anyway — a pinned
# window is rendered on whatever workspace its output is showing.
PINNED = dict(FOOT, address="0x562e1ac9f010", stableId="18000010", pinned=True,
              workspace={"id": 12, "name": "12"}, title="pinned notes", pid=777,
              focusHistoryID=4)
PINNED["class"] = "pinned-app"

# On a special workspace: off screen while nobody has it open, on screen when a monitor says
# it is the special workspace it is showing.
SPECIAL = dict(FOOT, address="0x562e1ac6b120", stableId="18000011",
               workspace={"id": -99, "name": "special:scratch"}, title="scratch",
               pid=888, focusHistoryID=5)
SPECIAL["class"] = "scratch-app"

# The same address as FOOT, a different process: what a reused address looks like.
REPLACED = dict(FOOT, stableId="18000099", title="something else", pid=999)
REPLACED["class"] = "other"

# The same window, one row lower: what a moved window looks like.
MOVED = dict(FOOT, at=[1934, 169])

MONITORS = [
    {
        "id": 0, "name": "DP-1", "description": "stand-in output", "make": "test", "model": "test",
        "serial": "0", "width": 1920, "height": 1080, "physicalWidth": 480, "physicalHeight": 260,
        "refreshRate": 60.0, "x": 0, "y": 0,
        "activeWorkspace": {"id": 1, "name": "1"}, "specialWorkspace": {"id": 0, "name": ""},
        "reserved": [0, 55, 0, 0], "scale": 1.0, "transform": 0, "focused": False,
        "dpmsStatus": True, "disabled": False, "currentFormat": "XRGB8888", "mirrorOf": "none",
    },
    {
        "id": 1, "name": "DP-2", "description": "stand-in output", "make": "test", "model": "test",
        "serial": "1", "width": 1920, "height": 1080, "physicalWidth": 480, "physicalHeight": 260,
        "refreshRate": 60.0, "x": 1920, "y": 0,
        "activeWorkspace": {"id": 11, "name": "11"}, "specialWorkspace": {"id": 0, "name": ""},
        "reserved": [0, 0, 0, 0], "scale": 2.0, "transform": 1, "focused": True,
        "dpmsStatus": True, "disabled": False, "currentFormat": "XRGB8888", "mirrorOf": "none",
    },
]

# The same two outputs with the scratch workspace open on DP-2.
MONITORS_SPECIAL = [dict(MONITORS[0])] + [
    dict(MONITORS[1], specialWorkspace={"id": -99, "name": "special:scratch"})
]

# The same session with no output showing the workspace FOOT is on any more: an output switched
# what it is showing while the pointer was travelling. Nothing about FOOT itself changes — same
# window, same workspace, same rectangle — which is exactly why a fingerprint cannot catch it.
MONITORS_AWAY = [
    dict(MONITORS[0]),
    dict(MONITORS[1], activeWorkspace={"id": 12, "name": "12"}),
]

# FOOT a moment later, one condition at a time: withdrawn, drawn nowhere, refusing input.
UNMAPPED = dict(FOOT, mapped=False)
HIDDEN_NOW = dict(FOOT, hidden=True)
NO_INPUT = dict(FOOT, acceptsInput=False)

# Where a pointer that arrived and was then moved by something else would be.
CURSOR_ELSEWHERE = {"x": 4000, "y": 500}


WORKSPACES = [
    {"id": 1, "name": "1", "monitor": "DP-1", "monitorID": 0, "windows": 0,
     "hasfullscreen": False, "lastwindow": "0x0", "lastwindowtitle": "",
     "ispersistent": False, "tiledLayout": "dwindle"},
    {"id": 11, "name": "11", "monitor": "DP-2", "monitorID": 1, "windows": 2,
     "hasfullscreen": False, "lastwindow": FOOT["address"], "lastwindowtitle": FOOT["title"],
     "ispersistent": False, "tiledLayout": "dwindle"},
    {"id": 12, "name": "12", "monitor": "DP-2", "monitorID": 1, "windows": 1,
     "hasfullscreen": False, "lastwindow": HIDDEN["address"], "lastwindowtitle": HIDDEN["title"],
     "ispersistent": False, "tiledLayout": "dwindle"},
]

# The same session with the scratch workspace's window the only one on DP-2 besides FOOT: a
# special workspace exists whether or not an output is showing it, and its id is in the
# compositor's own special range (-99..-2).
WORKSPACES_SPECIAL = [
    WORKSPACES[0],
    WORKSPACES[1],
    {"id": -99, "name": "special:scratch", "monitor": "DP-2", "monitorID": 1, "windows": 1,
     "hasfullscreen": False, "lastwindow": SPECIAL["address"], "lastwindowtitle": SPECIAL["title"],
     "ispersistent": False, "tiledLayout": "dwindle"},
]

ACTIVE_WORKSPACE = {"id": 11, "name": "11", "monitor": "DP-2", "monitorID": 1, "windows": 2,
                    "hasfullscreen": False, "lastwindow": FOOT["address"],
                    "lastwindowtitle": FOOT["title"], "ispersistent": False, "tiledLayout": "dwindle"}

CURSOR = {"x": 1148, "y": 362}

BASE = {"clients": [FOOT, EDITOR, HIDDEN], "activewindow": FOOT}

CASES = {
    # observation, and the world itself
    "inspect": {},
    # visibility the way the compositor hands it over, one shape per case: a pinned window on a
    # workspace nobody is showing, a special workspace open, and the same one shut again
    "inspect-pinned": {"clients": [FOOT, EDITOR, PINNED]},
    "inspect-special": {"clients": [FOOT, EDITOR, SPECIAL],
                        "monitors": MONITORS_SPECIAL, "workspaces": WORKSPACES_SPECIAL},
    "inspect-special-closed": {"clients": [FOOT, EDITOR, SPECIAL],
                               "workspaces": WORKSPACES_SPECIAL},
    # the click family: one steady world, one changed world
    "click": {},
    "click-no-button": {},
    "click-stale": {"clients.2": [MOVED, EDITOR, HIDDEN]},
    "click-gone": {"clients.2": [EDITOR, HIDDEN]},
    "click-replaced": {"clients.2": [REPLACED, EDITOR, HIDDEN]},
    "click-pointer-miss": {"flag:pointer_stuck": ""},
    # The guard that runs immediately before an input event, against a world that changed while
    # the pointer was moving. The n in these keys is the call of that command the guard makes
    # (the selftest's own inspect reads the first of each), so `monitors.3` is what the guard
    # before the first press sees.
    "click-monitor-switch": {"monitors.3": MONITORS_AWAY},
    "scroll-monitor-switch": {"monitors.3": MONITORS_AWAY},
    "click-monitor-switch-mid-count": {"monitors.4": MONITORS_AWAY},
    "click-moved-midway": {"clients.3": [MOVED, EDITOR, HIDDEN]},
    "click-hidden-midway": {"clients.3": [HIDDEN_NOW, EDITOR, HIDDEN]},
    "click-unmapped-midway": {"clients.3": [UNMAPPED, EDITOR, HIDDEN]},
    "click-input-refused-midway": {"clients.3": [NO_INPUT, EDITOR, HIDDEN]},
    "click-pointer-drift": {"cursorpos.4": CURSOR_ELSEWHERE},
    "click-hidden": {},
    "click-pinned": {"clients": [FOOT, EDITOR, PINNED]},
    "click-special-closed": {"clients": [FOOT, EDITOR, SPECIAL],
                             "workspaces": WORKSPACES_SPECIAL},
    "scroll": {},
    "scroll-hidden": {},
    # typing and keys: who holds the focus is the whole question
    "type": {},
    "type-control": {},
    "type-not-focused": {"activewindow": EDITOR},
    "type-focus-first": {"activewindow": EDITOR},
    "type-hidden": {},
    "key": {},
    "key-bad-mod": {},
    "key-hidden": {},
    # capture
    "screenshot-monitor": {},
    "screenshot-window": {},
    "screenshot-region": {},
    "screenshot-hidden": {},
    "screenshot-special-closed": {"clients": [FOOT, EDITOR, SPECIAL],
                                  "workspaces": WORKSPACES_SPECIAL},
    # a session without the input clients
    "tools-missing": {},
    # focus
    "focus-window": {},
    "focus-workspace": {},
    "focus-refused": {"flag:dispatch_fail": "the compositor refused this dispatcher"},
    # the derivation checked against the monitors of whatever world is on screen: it reads
    # nothing but hyprland_inspect, so the same case runs against the fakes and against a live
    # session (tests/hyprland/check-live.sh)
    "visibility": {},
}


def write(directory, case):
    spec = CASES[case]
    clients = spec.get("clients", BASE["clients"])
    with open(os.path.join(directory, "clients.1.json"), "w") as f:
        json.dump(clients, f, indent=2)
    with open(os.path.join(directory, "clients.2.json"), "w") as f:
        json.dump(spec.get("clients.2", clients), f, indent=2)
    with open(os.path.join(directory, "monitors.1.json"), "w") as f:
        json.dump(spec.get("monitors", MONITORS), f, indent=2)
    with open(os.path.join(directory, "workspaces.1.json"), "w") as f:
        json.dump(spec.get("workspaces", WORKSPACES), f, indent=2)
    with open(os.path.join(directory, "activewindow.1.json"), "w") as f:
        json.dump(spec.get("activewindow", BASE["activewindow"]), f, indent=2)
    with open(os.path.join(directory, "activeworkspace.1.json"), "w") as f:
        json.dump(ACTIVE_WORKSPACE, f, indent=2)
    with open(os.path.join(directory, "cursor.json"), "w") as f:
        json.dump(CURSOR, f, indent=2)
    for key, text in spec.items():
        if key.startswith("flag:"):
            with open(os.path.join(directory, key[len("flag:"):]), "w") as f:
                f.write(text)
    # And any <name>.<n> key is the answer to the n-th call of that command: the world as the
    # guard before the input event finds it, after the pointer has moved.
    for key, value in spec.items():
        if key.partition(".")[2].isdigit():
            with open(os.path.join(directory, f"{key}.json"), "w") as f:
                json.dump(value, f, indent=2)


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    case, outdir = sys.argv[1], sys.argv[2]
    if case not in CASES:
        print(f"unknown case {case}; known: {', '.join(sorted(CASES))}", file=sys.stderr)
        return 2
    os.makedirs(outdir, exist_ok=True)
    write(outdir, case)
    return 0


if __name__ == "__main__":
    sys.exit(main())
