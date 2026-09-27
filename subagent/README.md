# subagent

Child eidolon sessions for one bounded task each: one tool starts `eidolon run`
in the background with a brief, four more follow, steer and stop it, and the
child reports back to the session that started it with `send`.

| tool | does |
|---|---|
| `subagent_spawn` | start a child `eidolon run` with a brief; returns at once with its id, pid and log |
| `subagent_list` | every child this machine spawned: alive or not, how it ended, its journal and its peer id |
| `subagent_trace` | the tail of one child's log, with whether it is alive and how it ended |
| `subagent_steer` | one message into a running child, read at its next step |
| `subagent_cancel` | SIGTERM to the child's whole process group, SIGKILL if it will not go |

```
eidolon ──tools/subagent_spawn.rn──shell_background──▶ bash ──▶ eidolon run (the child)
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
- eidolon with `shell_background` and the swarm's `send` (any upstream with the
  swarm built-ins).
- The swarm **not disabled**: `[swarm] enabled = true` in
  `~/.config/eidolon/config.toml`, which is the default. `subagent_spawn`
  refuses when `peers` names no id, and `subagent_steer` cannot deliver: a
  session that is not registered among its peers has nobody to report to and
  nothing to send from.
- A model the child can run. The config's default model is the child's model
  unless `role` or `model` says otherwise — and if that default is not a
  tool-calling model (eidolon's `mock` is not), pass `model` to `subagent_spawn`
  or the child will not do anything.

## Install

```bash
mkdir -p ~/.config/eidolon/tools
cp subagent/tools/*.rn ~/.config/eidolon/tools/
```

## Verify

All five compile, and `eidolon tools` prints each manifest; a file that does
not compile is a `[tool] … failed to compile` note instead.

```bash
eidolon tools 2>&1 | grep -i subagent
# "name": "subagent_spawn",
# "name": "subagent_list",
# "name": "subagent_trace",
# "name": "subagent_steer",
# "name": "subagent_cancel",
```

A subagent cannot spawn a subagent — the guard line as `subagent_spawn.rn`
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
rm -f ~/.config/eidolon/tools/subagent_spawn.rn \
      ~/.config/eidolon/tools/subagent_list.rn \
      ~/.config/eidolon/tools/subagent_trace.rn \
      ~/.config/eidolon/tools/subagent_steer.rn \
      ~/.config/eidolon/tools/subagent_cancel.rn
```

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
| role tiers, "the parent's own model by default" | the `TIERS` table at the top of `subagent_spawn.rn`, empty by default; with nothing named the child runs the config's default model, which is **not** the parent's |
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
