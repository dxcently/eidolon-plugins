# plugin (template)

A skeleton for your own eidolon plugin: one tool, one workflow, the four README
sections. It sits under `templates/` so that `eidolon plugins --dir` and
`plugins install --all` on this repo never see it.

## Make yours

1. Copy the folder into your own git repo, at the top level.
2. Rename three things, all to the same `<name>`:
   - the folder: `plugin/` to `<name>/`
   - `name:` in `plugin.rn`
   - `name:` in `tools/hello.rn` to `<name>_hello` (and `plugin_hello` in `workflows/greet.rn`)

   The folder name is the manifest name is the tool prefix; eidolon registers
   `<folder>_<stem>`. Rename `hello.rn` to your verb the same way.
3. Replace the README's `plugin` with `<name>`, push, and it installs with
   `eidolon plugins install <owner>/<repo> <name>`.

`plugin.rn` also takes an optional `libraries:` list (repo, path, `sha256:` pin)
that eidolon vendors into `lib/` on install. It needs a recent upstream eidolon.
Nothing here uses it.

Before this repo lists your plugin, a human reviews it: see [INDEX.md](../../INDEX.md).

## Prerequisites

```bash
eidolon --version
```

## Install

```bash
eidolon plugins install <owner>/<repo> plugin
eidolon plugins trust plugin
```

## Verify

```bash
eidolon plugins | grep -A6 '^plugin '
eidolon workflow run ~/.config/eidolon/plugins/plugin greet --args '{}' --provider mock
# {"report":"hello, workflow", ... "status":"completed"}
```

## Uninstall

```bash
eidolon plugins uninstall plugin
```
