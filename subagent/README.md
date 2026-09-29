# subagent

Child eidolon sessions for one bounded task each: one tool starts `eidolon run`
in the background with a brief, four more follow, steer and stop it, and the
child reports back to the session that started it with `send`.

| tool | file | does |
|---|---|---|
| `subagent_spawn` | `tools/spawn.rn` | start a child `eidolon run` with a brief; returns at once with its id, pid and log |
| `subagent_list` | `tools/list.rn` | every child this machine spawned: alive or not, how it ended, its journal and its peer id |
| `subagent_trace` | `tools/trace.rn` | the tail of one child's log, with whether it is alive and how it ended |
| `subagent_steer` | `tools/steer.rn` | one message into a running child, read at its next step |
| `subagent_cancel` | `tools/cancel.rn` | SIGTERM to the child's whole process group, SIGKILL if it will not go |

A tool file's **stem is the bare verb** and its declared `name:` is the
**namespaced** one: `tools/spawn.rn` is adopted as `subagent_spawn`, because
the plugin's directory name is the namespace. That is why these files are not
called `subagent_spawn.rn`.

```
eidolon ──plugin subagent/tools/spawn.rn──shell_background──▶ bash ──▶ eidolon run (the child)
     │                        pid, log under ~/.cache/eidolon/background/
     │
     └── writes a brief and a meta file per child, under
         ${XDG_STATE_HOME:-$HOME/.local/state}/eidolon/subagents/<id>/
         and reads them back: subagent_list, subagent_trace, subagent_steer, subagent_cancel
```

No service and no shared registry: the child is an ordinary session, its state
directory is what the parent wrote down, and its own registration among its
peers is what a steer is addressed to. The child's journal is what
`eidolon resume <journal>` picks up again; the path is in the child's log, and
`subagent_list` prints it. [`brief.md`](brief.md) is the brief the child is
handed, and each tool file carries what it needs whole.

## Prerequisites

- Any Unix eidolon runs on — Linux, WSL, macOS. Every command in the tool files
  is POSIX sh: no `timeout` (GNU coreutils, absent on macOS), no `setsid`
  binary, no `/proc`, no `sed -i`, and no `readlink -f`.
- eidolon **with the plugin system** — `eidolon plugins --help` is the proof;
  the `eidolon` on an old `PATH` has none, and the install below fails there.
  Plus `shell_background` and the swarm's `send` (any upstream with the swarm
  built-ins).
- The swarm **not disabled**: `[swarm] enabled = true` in
  `~/.config/eidolon/config.toml`, which is the default. `subagent_spawn`
  refuses when `peers` names no id, and `subagent_steer` cannot deliver: a
  session that is not registered among its peers has nobody to report to and
  nothing to send from.
- A model the child can run: a tool-calling `default_model` in
  `~/.config/eidolon/config.toml`, or a row in the `TIERS` table at the top of
  [`tools/spawn.rn`](tools/spawn.rn) passed as `role`. The config default is
  the child's model unless `role` or `model` says otherwise — and the default
  on a stock install is `mock`, which is **not** tool-calling: pass `model` to
  `subagent_spawn`, or fill in `TIERS`, or the child does nothing.

## Install

```bash
eidolon plugins install dxcently/eidolon-plugins subagent
eidolon plugins trust subagent
```

`plugins install` fetches the repo, validates `subagent/plugin.rn`, copies the
folder into `~/.config/eidolon/plugins/subagent/` and records what it fetched.
**Installing does not trust**: the five verbs land on the gate like any other
caller's, so `plugins trust subagent` is the second, separate act — it vouches
every verb the plugin ships (`spawn`, `list`, `trace`, `steer`, `cancel`). Add
`--ref <branch|tag|commit>` to pin the install; the default is the repo's HEAD.

A local checkout works the same way, and is the way to install a branch before
it is pushed:

```bash
eidolon plugins install file:///path/to/eidolon-plugins subagent --ref main
```

## Verify

The listing reads the plugin directory and compiles `plugin.rn`; the tools are
adopted at session build, so `eidolon tools` prints each manifest. A file that
does not compile is a note instead (`[tool] … failed to compile`, or
`not adopted — …`), not a silent absence.

```bash
eidolon plugins --dir ~/.config/eidolon/plugins
# subagent 0.1.0
#     child eidolon sessions for a bounded task: spawn, list, trace, steer, cancel
#     payloads tools
#     claims   tools: spawn, list, trace, steer, cancel
#     subagent_cancel              vouched by …
#     subagent_list                vouched by …
#     subagent_spawn               vouched by …
#     subagent_steer               vouched by …
#     subagent_trace               vouched by …

eidolon tools 2>&1 | grep -i subagent
# "name": "subagent_spawn",
# "name": "subagent_list",
# "name": "subagent_trace",
# "name": "subagent_steer",
# "name": "subagent_cancel",
```

A subagent cannot spawn a subagent — the guard line as `tools/spawn.rn`
writes it, run with the variable set:

```bash
EIDOLON_SUBAGENT=1 sh -c '[ -n "$EIDOLON_SUBAGENT" ] && exit 3'
echo $?
# 3
```

A spawn, end to end — this needs a model that calls tools and takes a while:

```bash
eidolon run --yolo --model ollama:deepseek-v4.1-flash \
  "Call subagent_spawn with task 'Count slowly: run the bash command sleep 20 three times, then reply done.', deadline_min 3, yolo true, model ollama:deepseek-v4.1-flash. Then call subagent_list. Then run bash 'sleep 15'. Then call subagent_steer with that id and text 'Stop counting and reply steered.'. Then bash 'sleep 20'. Then call subagent_trace with that id. Then call subagent_cancel with that id. Then subagent_list again. Print each tool result verbatim."
# subagent sa-<seconds>-<4 hex>
# pid: <pid>
# log: ~/.cache/eidolon/background/<n>.log
# ...
# sa-<seconds>-<4 hex>  alive  nothing recorded yet (still running, or nobody reaped it)
#   peer: <cwd basename>-<4 hex>
# ...
```

## Uninstall

```bash
eidolon plugins uninstall subagent
```

That removes the directory and the plugin's row in the record. It is the one
act that shrinks the record, and the vouch rows are **left alone** — they
answer nothing while no verb of that name is loaded, and a reinstall inherits
the earlier yes. A service still running refuses; this plugin declares none.

The children already spawned are untouched, and so are their state directories
and journals: `kill` them, or `eidolon resume` them, by hand.

## What the old fork had, and what is here

The Minerva fork's subagent feature was `Shim::summon` inside the harness — a
subagent there was a chat in the harness's own process, watched through
`/api/subagent*` routes. This is the same lifecycle as Rune tools on upstream
eidolon, where a subagent is a process of its own.

| old fork | here |
|---|---|
| spawn (`Shim::summon`) | `subagent_spawn`: a child `eidolon run`, under `shell_background`, with a brief |
| trace (live turns of the child) | `subagent_trace`: the tail of the child's log — the child's output, not its transcript |
| steer (a message mid-turn) | `subagent_steer`: `send` with wake, read by the child at its next step |
| cancel | `subagent_cancel`: SIGTERM to the child's process group, SIGKILL after 5 s |
| list | `subagent_list` |
| role tiers, "the parent's own model by default" | the `TIERS` table at the top of `tools/spawn.rn`, empty by default; with nothing named the child runs the config's default model, which is **not** the parent's |
| the web UI's subagent routes | not in this repo: no service, no routes, nothing to declare. The reading surface is these five tools, `eidolon peers`, and the child's own session (`eidolon logs`, `eidolon resume`) |

## Limits

- **A steer lands at the child's next step, not mid-token.** The message wakes
  the child and it reads it before it settles, so it changes the plan; it does
  not interrupt the call already in flight. A child inside a 20-minute `bash`
  reads the steer when that call returns.
- **The default model is the config's, not the parent's.** `subagent_spawn`
  passes `--model` only when `role` or `model` names one, and a bare `eidolon
  run` takes the config default — which on a stock install is `mock`. Pass a
  model, or fill in `TIERS`.
- **A child without `yolo` stalls on its first flagged tool call** (`bash`,
  `write`): nobody is at its end to answer the gate. Pass `yolo: true` for any
  child meant to act.
- **No nesting.** `subagent_spawn` refuses before it starts anything when
  `EIDOLON_SUBAGENT` is set in its own environment, and the child's command line
  carries the same guard, so a child that calls the tool gets a refusal rather
  than a grandchild.
- **Cancel is a signal, not a checkpoint.** SIGTERM to the process group
  (`shell_background` starts the child under `setsid`, so the group is the
  child's whole tree), SIGKILL after 5 s. The state directory and the journal
  stay: the record and the thing `eidolon resume` reads.
- **One report, once, and only if the child starts.** A model that does not
  resolve, or a provider with no credential, never reports; its log says why,
  and `subagent_trace` shows it.
- **The peer id is matched on the journal, not on the title.** `eidolon run`
  registers before it is asked anything, so a headless child's title in `peers`
  is empty; its journal path is exact. The brief's first line still says which
  child it is for anyone reading a roster by eye.
- **The child inherits the parent's directory, config and secrets**, and the
  parent sees its pid, its log and its journal — nothing of its turns.
