#!/usr/bin/env python3
"""The worlds the hyprland tools are checked against: one scenario per selftest case.

`run.sh` writes a case's directory and the fake `hyprctl` reads it: `<what>.<n>.json` is
the answer to the n-th call of that command, and the highest file at or below n wins, so a
scenario only spells out the answer a case *changes* (the window that moved between the
inspection and the click) and everything else is the steady world.

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

# On workspace 12, which no output is showing: mapped and accepting input, not visible.
HIDDEN = dict(FOOT, address="0x562e1abbfd30", stableId="1800000f", visible=False,
              size=[1892, 997], workspace={"id": 12, "name": "12"},
              title="private notes", pid=555, focusHistoryID=3)
HIDDEN["class"] = "hidden-app"

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

WORKSPACES = [
    {"id": 1, "name": "1", "monitor": "DP-1", "monitorID": 0, "windows": 0,
     "hasfullscreen": False, "lastwindow": "0x0", "lastwindowtitle": "",
     "ispersistent": False, "tiledLayout": "dwindle", "visible": True},
    {"id": 11, "name": "11", "monitor": "DP-2", "monitorID": 1, "windows": 2,
     "hasfullscreen": False, "lastwindow": FOOT["address"], "lastwindowtitle": FOOT["title"],
     "ispersistent": False, "tiledLayout": "dwindle", "visible": True},
    {"id": 12, "name": "12", "monitor": "DP-2", "monitorID": 1, "windows": 1,
     "hasfullscreen": False, "lastwindow": HIDDEN["address"], "lastwindowtitle": HIDDEN["title"],
     "ispersistent": False, "tiledLayout": "dwindle", "visible": False},
]

ACTIVE_WORKSPACE = {"id": 11, "name": "11", "monitor": "DP-2", "monitorID": 1, "windows": 2,
                    "hasfullscreen": False, "lastwindow": FOOT["address"],
                    "lastwindowtitle": FOOT["title"], "ispersistent": False, "tiledLayout": "dwindle"}

CURSOR = {"x": 1148, "y": 362}

BASE = {"clients": [FOOT, EDITOR, HIDDEN], "activewindow": FOOT}

CASES = {
    # observation, and the world itself
    "inspect": {},
    # the click family: one steady world, one changed world
    "click": {},
    "click-no-button": {},
    "click-stale": {"clients.2": [MOVED, EDITOR, HIDDEN]},
    "click-gone": {"clients.2": [EDITOR, HIDDEN]},
    "click-replaced": {"clients.2": [REPLACED, EDITOR, HIDDEN]},
    "click-pointer-miss": {"flag:pointer_stuck": ""},
    "click-hidden": {},
    "scroll": {},
    # typing and keys: who holds the focus is the whole question
    "type": {},
    "type-control": {},
    "type-not-focused": {"activewindow": EDITOR},
    "type-focus-first": {"activewindow": EDITOR},
    "key": {},
    "key-bad-mod": {},
    # capture
    "screenshot-monitor": {},
    "screenshot-window": {},
    "screenshot-region": {},
    "screenshot-hidden": {},
    # a session without the input clients
    "tools-missing": {},
    # focus
    "focus-window": {},
    "focus-workspace": {},
    "focus-refused": {"flag:dispatch_fail": "the compositor refused this dispatcher"},
}


def write(directory, case):
    spec = CASES[case]
    with open(os.path.join(directory, "clients.1.json"), "w") as f:
        json.dump(spec.get("clients", BASE["clients"]), f, indent=2)
    with open(os.path.join(directory, "clients.2.json"), "w") as f:
        json.dump(spec.get("clients.2", spec.get("clients", BASE["clients"])), f, indent=2)
    with open(os.path.join(directory, "monitors.1.json"), "w") as f:
        json.dump(MONITORS, f, indent=2)
    with open(os.path.join(directory, "workspaces.1.json"), "w") as f:
        json.dump(WORKSPACES, f, indent=2)
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
