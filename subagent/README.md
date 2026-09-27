# subagent

A child eidolon session for one bounded task: one tool starts `eidolon run` in
the background with a brief, the child reports back to the session that started
it once with `send`, and stops.

| tool | does |
|---|---|
| `subagent_spawn` | start a child `eidolon run` with a brief; returns at once with its pid and log |

```
eidolon ──tools/subagent_spawn.rn──shell_background──▶ bash ──▶ eidolon run (the child)
                                             log: ~/.cache/eidolon/background/<n>.log
```

No service and no shared state: the child is an ordinary session, and all a
parent holds of it is its pid, its log and — when it reports — its message.
The report is addressed to the parent's roster id, so a direct `send` wakes an
idle parent; [`brief.md`](brief.md) is the brief the child is handed, and
[`tools/subagent_spawn.rn`](tools/subagent_spawn.rn) carries it whole. The
child's journal is what `eidolon resume <journal>` picks up again, and the path
is in the child's log.

## Prerequisites

- Linux or WSL, with `timeout` (GNU coreutils).
- eidolon with `shell_background` and the swarm's `peers`/`send` (any upstream
  with the swarm built-ins).
- The swarm **not disabled**: `[swarm] enabled = true` in
  `~/.config/eidolon/config.toml`, which is the default. The tool refuses when
  `peers` names no id — a session that is not registered among its peers has
  nobody for a child to report to.
- A model the child can run: the config's default, or one the call names.

## Install

```bash
mkdir -p ~/.config/eidolon/tools
cp subagent/tools/subagent_spawn.rn ~/.config/eidolon/tools/
```

## Verify

The tool compiles, and `eidolon tools` prints its manifest; a file that does
not compile is a `[tool] … failed to compile` note instead.

```bash
eidolon tools 2>&1 | grep -i subagent
# "name": "subagent_spawn",
```

A child cannot spawn a child:

```bash
EIDOLON_SUBAGENT=1 bash -c '[ -n "$EIDOLON_SUBAGENT" ] && { echo "refused: a subagent may not spawn subagents" >&2; exit 3; }'
echo $?
# 3
```

A spawn, end to end — needs a model that calls tools, and the `model` argument
if the config's default is not one:

```bash
eidolon run --yolo "Call subagent_spawn with task 'Reply with the single word pong.' and deadline_min 2. Then print the tool result verbatim and stop."
# parent: <id>, deadline: 2 min
# [running in the background]
# pid: <pid>
# log: ~/.cache/eidolon/background/<n>.log
```

## Limits

- No live trace and no steer. The log is the only window on a child; nothing
  reaches into it mid-turn.
- Cancel is `kill <pid>`. There is no cancel and no stop: `timeout`, the pid
  and the log are the whole handle.
- No nesting. A child carries `EIDOLON_SUBAGENT`, the guard refuses the tool
  (exit 3), and the brief says not to call it.
- A child without `yolo` stalls on its first flagged tool call (`bash`,
  `write`): nobody is at its end to answer the gate.
- One report, once, and only if the child starts. A model that does not
  resolve or a provider with no credential never reports; its log says why.
- The child runs where the parent does, with the parent's config and secrets,
  and the parent sees its pid and the journal path — nothing of its turns.

## Uninstall

```bash
rm -f ~/.config/eidolon/tools/subagent_spawn.rn
```
