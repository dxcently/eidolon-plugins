# hyprland

See and drive a Hyprland session: `hyprland_inspect` (monitors, workspaces, windows with
identity and geometry), `hyprland_screenshot` (a monitor, a workspace, or a window, handed
over as a picture), `hyprland_focus`, and the input verbs `hyprland_click`,
`hyprland_scroll`, `hyprland_type` and `hyprland_key`.

The plugin exists because a person driving a session through an agent needs the two halves
to be different kinds of act, and to be checkable: **observation never changes what is on
screen**, and **input is aimed at a window that was inspected a moment ago, re-checked
immediately before it happens, and refused if it is not the same window**. What is not
guaranteed is written in the answer of every call rather than left to be assumed — a
Hyprland input primitive takes no window to bind to, so the re-checks narrow the window of
opportunity and cannot close it.

## What it needs from the session

- Hyprland with a **Lua config provider** (`hyprctl status` prints `configProvider: lua`,
  Hyprland 0.56 here). Focus is the compositor's own dispatcher, called through
  `hyprctl dispatch '<lua>'` with the window re-resolved *inside* that same call. A
  session on the older hyprlang provider answers `configProvider: hyprlang`; the
  observation verbs still work and the focus/screenshot/input verbs say what they need.
- `hyprctl` — part of Hyprland.
- `grim` for the screenshots, `wlrctl` (pointer) and `wtype` (keyboard) for the input
  verbs. `nix build .#hyprland` (or `nix profile install <this repo>#hyprland`) puts all
  three in one profile; any distro package of the same three works just as well. A verb
  whose client is missing refuses by name rather than failing obscurely.
- Nothing else: no service, no port, no token, no daemon. Each input verb runs the client
  for one act and the client exits. A chord's modifiers are released **by name inside that
  same invocation** (`wtype -M ctrl … -m ctrl`), because the client does not reset the seat's
  modifier state on its way out — see the note in Limits.

## Prerequisites

```bash
hyprctl version                       # Hyprland is running in this environment
hyprctl status | grep configProvider  # lua (focus) — observation works either way
nix build .#hyprland                  # builds grim + wlrctl + wtype into ./result
```

To use the built package:

```bash
nix profile install .#hyprland        # or: nix build .#hyprland && export PATH="$PWD/result/bin:$PATH"
command -v grim wlrctl wtype          # all three answer with a path
```

An operator who enforces Hyprland's own permissions (`ecosystem.enforce_permissions = true`
in the config, which is **false** by default and false on the machine this was written for)
must allow the two clients they use, once, then restart Hyprland:

```lua
hl.permission(".*/grim", "screencopy", "allow")
```

## Install

```bash
eidolon plugins install dxcently/eidolon-plugins hyprland
eidolon plugins trust hyprland
```

Installing does not trust. `trust hyprland` is what answers the gate for this plugin's
verbs, and it is written in the permission store — the two commands above are the whole
install, and a person should be able to see them afterwards. The plugin ships no tools
that reach a secret, so there is nothing for `grant` to record. The verbs are:

```
hyprland_inspect      read_only
hyprland_screenshot   read_only
hyprland_focus        mutating
hyprland_click        mutating
hyprland_scroll       mutating
hyprland_type         mutating
hyprland_key          mutating
```

## Verify

The tools are checked against fixed compositor answers, with no session and no input
device involved — fake `hyprctl`, `grim`, `wlrctl` and `wtype` first on `PATH`, with
`WAYLAND_DISPLAY`, `DISPLAY` and `HYPRLAND_INSTANCE_SIGNATURE` removed, so a test cannot
reach a live session. From a checkout of this repo:

```bash
t=$(mktemp -d)
HOME=$t XDG_CONFIG_HOME=$t/cfg XDG_STATE_HOME=$t/state XDG_DATA_HOME=$t/data \
  bash tests/hyprland/run.sh
```

Every case prints `ok <name>` and the last line is `ok   every case`. The cases cover the
refusals as much as the successes: a window that moved, died or had its address reused
between the inspection and the click; a target on a workspace nobody is showing; typing at
a window that is not focused; a missing button; an input client that is not installed; a
pointer that did not arrive; and the one invocation that must never be constructed — a
bare `pointer click`, which `wlrctl`'s own CLI turns into a left click. The fake `wlrctl`
fails the run if it ever sees one.

On a real session, read-only and safe to run:

```bash
eidolon run 'call hyprland_inspect with format json, then screenshot monitor <name> and tell me what is on it' --yolo
```

**Live input is not part of Verify.** The four mutating verbs move the pointer, type and
press keys in the operator's real session; a call is aimed at a window by address, so the
honest smoke test is a window the operator owns for the purpose (a scratch terminal on a
scratch workspace), with the exact commands agreed first. Until then, the mock suite is
what "verified" means here.

## Limits, in the answer of every call

- **No atomic targeting.** The re-checks happen immediately before the act; between the
  last one and the act, a person can move the pointer or a window can move. Hyprland's
  input primitives take no window, so nothing here can bind an injection to one.
- **The pointer is moved by displacement.** `wlrctl pointer move <dx> <dy>` has no
  absolute form, so the cursor position is read, the difference sent, and the position read
  back — a pointer that did not arrive is a refusal, not a click somewhere else.
- **Typing is a check, not a lock.** The focused window is read before and after; a focus
  that moved mid-text is reported as an error, since part of the text may have gone
  elsewhere.
- **A window capture is a crop of the visible desktop.** `grim -T` wants a foreign-toplevel
  identifier and no Hyprland address maps to one, so a window is captured as its rectangle:
  anything overlapping it appears as it does on screen.
- **A hidden workspace cannot be captured at all** — a compositor renders only what is
  showing. The tool refuses and names `hyprland_focus`, which switches to it on purpose and
  says so, instead of switching silently.
- **Coordinates are logical layout coordinates** (the space `hyprctl`, `grim -g` and the
  input clients share). Every rect is reported beside its monitor's `scale` and `transform`,
  because the picture's *pixels* are the rect times the scale, rotated when transform is 1
  or 3.
- **No window management.** No close, no kill, no move, no resize, no layout: this plugin
  observes, focuses, captures, clicks, scrolls, types and presses keys, and nothing else.

## Uninstall

```bash
eidolon plugins uninstall hyprland
```

The directory and its row in the record go; the vouch written by `trust` is left alone
(a reinstall inherits it). Nothing else was installed: no service, no token file, no
`config.toml` change. If the runtime package was installed with `nix profile`, remove it
the same way:

```bash
nix profile remove hyprland
```
