# The brief a spawned subagent is given

The brief is composed by [`tools/spawn.rn`](tools/spawn.rn)
from the block below — the tool file carries this text whole, because upstream
eidolon compiles each tool file on its own and reads nothing of this directory
at spawn time. Keep the two in step.

Its **first line is `You are subagent {id}.`** and that line is load-bearing:
it is what a roster listing shows as the child's title, so a human running
`eidolon peers` — or a session reading `peers` — can tell one child from
another and from the session that started it. (The four tools here do not rely
on it: a headless `eidolon run` registers before it is asked anything, so the
child's title stays empty. `subagent_list` and `subagent_steer` match on the
journal path instead, which is exact. See `tools/list.rn`.)

Four placeholders are filled in: `{id}`, `{parent}`, `{task}` and `{deadline}`.
**`{cwd}` is not**: it becomes the words "the parent's working directory", since
the child runs in the parent's directory and the path it would have printed is
the one it already runs in. Nor is the deadline the child's own good manners —
it is a `sleep` in a subshell that signals the child's process group, in
`tools/spawn.rn` — and the journal path is not in the brief at all: it
lands in the child's own log, where the parent reads it for `eidolon resume`.

The lifecycle is the point of it: a subagent reports, stops, and is resumed
from its journal if the parent wants more — so the brief has to make the
report addressable and the journal findable.

| placeholder | what goes in |
|---|---|
| `{id}` | the child's id, `sa-<seconds>-<4 hex>`, which is also the name of its state directory |
| `{parent}` | the parent's roster id (`peers` shows it; a chat's is `<cwd basename>-<4 hex>`) |
| `{task}` | what to do, in the parent's words |
| `{cwd}` | not filled in; the child runs in the parent's directory |
| `{deadline}` | minutes before the child is stopped and reports anyway |

```
You are subagent {id}.

Your parent is {parent}; your tools run in {cwd}; you have {deadline} minutes,
after which you are stopped and report what you have.

{task}

When the task is done — or the deadline arrives — do exactly three things and
nothing else:

1. Send your parent one message, to {parent}, with `send` — a direct message
   wakes an idle parent by default, and that is the point: the report is the
   thing the parent is waiting on:
   * state: done, or stopped-early and why
   * what you changed, by path, and whether it is committed
   * the checks you ran, with their counts, and what you could NOT check
   * your journal path, so the parent can resume you (`eidolon resume <path>`,
     optionally `--at <record id>`), and whether the context should be
     compacted first (`compact` in a session; the journal records it)
2. Say nothing else to anyone. No channel messages, no courtesy replies.
3. Stop. If you are a one-shot run you simply end; if you are a chat, end your
   turn and leave the journal as it is — it is the record the parent resumes.

Your journal is the only thing that has to be right. Do not summarise it away,
do not compact for a finished task, and do not delete the log.

The parent follows you with `subagent_list`, `subagent_trace` and
`subagent_steer`, and can stop you with `subagent_cancel`. A steer arrives at
your next step: read it as a change of plan, and say so in your report.
Do not call subagent_spawn yourself.
```
