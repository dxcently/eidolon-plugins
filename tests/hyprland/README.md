# tests/hyprland

The hyprland plugin checked against fixed compositor answers instead of a session.

```bash
t=$(mktemp -d)
HOME=$t XDG_CONFIG_HOME=$t/cfg XDG_STATE_HOME=$t/state XDG_DATA_HOME=$t/data \
  bash tests/hyprland/run.sh [case ...]
```

No argument runs every case; a case name runs one. Each case prints `ok <name>`, and a
failure prints what was expected, what the tool answered, and the run's report.

- `run.sh` — the harness. Refuses unless HOME and XDG_CONFIG_HOME are throwaway
  (`guard.sh`), copies the plugin into that config, vouches for it there, and runs one
  case of the plugin's `selftest` workflow with the fakes first on PATH.
- `stubs/` — `hyprctl`, `grim`, `wlrctl` and `wtype`. They answer from the scenario
  directory and record what they were asked for; they talk to no compositor and no device.
  The fake `wlrctl` refuses a `pointer click` with no explicit button and writes `BAD` to
  the log, because that is the invocation the plugin must never build.
- `scenarios.py` — the worlds: two monitors side by side (the second at scale 2, rotated),
  a window at layout `1934,69`, a second window behind it, and a third on a workspace no
  output is showing. `<what>.<n>.json` is the answer to the n-th call of that command, so a
  case spells out only what changes (the window that moved between the inspection and the
  click).

The environment is the point of the harness: `WAYLAND_DISPLAY`, `DISPLAY`,
`HYPRLAND_INSTANCE_SIGNATURE` and `XDG_SESSION_TYPE` are removed and PATH is stubs-first
with no directory holding the real `hyprctl`, `grim`, `wlrctl` or `wtype`, so a test —
or a bug in one — cannot move a real pointer.
