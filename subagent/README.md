# subagent

**Not installable.** This is a design brief kept for when it is.

A subagent is a child eidolon session that takes one task, reports back to
its parent once, and stops. [`brief.md`](brief.md) is the brief a child would
be handed: who its parent is, the task, and the exact shape of its one
report (what changed, what was checked, where its journal is so the parent
can `eidolon resume` it).

It was first built into the Minerva fork of eidolon (spawn, trace, steer,
cancel through the web UI). Upstream eidolon has no subagent feature, so
there is nothing here to drop into `~/.config/eidolon/tools/` yet.

Upstream does already have the pieces a Rune version would stand on:
`send` and `peers` (the report channel) and `eidolon resume` (picking the
child up again). A `subagent_spawn.rn` that starts `eidolon run` with this
brief in the background is the likely first tool.

## Prerequisites / Install / Verify / Uninstall

None yet.
