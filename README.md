# eidolon-plugins

Plugins for [eidolon](https://github.com/noah427/eidolon). Each folder is
one plugin, installed with `eidolon plugins install dxcently/eidolon-plugins
<name>` or by an agent reading its README. This repo is the curated
collection, not the only source: any git repo with a `plugin.rn` folder
installs the same way.

## The plugins

| plugin | gives eidolon | runs alongside | install | status |
|---|---|---|---|---|
| [`browser/`](browser/) | `browser_open`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_read`, `browser_back` | `eidolon-browser`, a Rust service driving one headless Chromium | by hand — see its README | works on upstream eidolon |
| [`subagent/`](subagent/) | `subagent_spawn`, `subagent_list`, `subagent_trace`, `subagent_steer`, `subagent_cancel` | `eidolon run`, child sessions in the background | `eidolon plugins install dxcently/eidolon-plugins subagent`, then `eidolon plugins trust subagent` | works on upstream eidolon |

**Web search** isn't here on purpose: eidolon ships it as the built-in
`search` tool, tied to the session's own key. To read a result, use `fetch`,
or `browser_open` + `browser_read` for pages that need a real browser.

## Installing one

Tell an agent:

> Install the `<name>` plugin from this repo: read `<name>/README.md` and
> follow it.

Or do it yourself. Every plugin README has the same four sections, run in
order: **Prerequisites**, **Install**, **Verify**, **Uninstall**. See
[AGENTS.md](AGENTS.md) for the rules an agent follows while doing it.

## Layout

```
<name>/
├── README.md       what it is, and Prerequisites / Install / Verify / Uninstall
├── plugin.rn       the manifest: name (the folder's), version, description, claims
├── tools/<verb>.rn → ~/.config/eidolon/plugins/<name>/tools/   one file per verb, declaring "<name>_<verb>"
├── service/        a Rust crate, when the tools need something running beside eidolon
└── package.nix     how the flake builds that service
```

A tool file carries everything it needs, endpoint included (upstream's rule:
a tool is one file you can hand to somebody). The folder *is* the plugin: the
directory's name is the namespace, and `tools/<verb>.rn` is adopted as
`<name>_<verb>` — the stem is the bare verb, the declared `name:` is the
namespaced one, and a plugin cannot shadow a built-in, so a verb file is named
for its verb and nothing else. `eidolon plugins install` copies the tree whole
into `~/.config/eidolon/plugins/`.

`browser/` is still the older hand-installed shape — no `plugin.rn`, its tools
copied into `~/.config/eidolon/tools/` — until its plugin port lands.

## Building

```bash
nix build .#browser          # the service, with Chromium from nixpkgs
nix develop                  # cargo, clippy, chromium; `cargo test` runs the real-browser tests too
cargo test                   # without Nix: unit tests, plus browser tests if EIDOLON_BROWSER_CHROME is set
```

Linux only (WSL counts), same as upstream eidolon.

## License

MIT
