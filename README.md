# eidolon-plugins

Plugins for [eidolon](https://github.com/noah427/eidolon). Each folder is
one plugin, installed with `eidolon plugins install dxcently/eidolon-plugins
<name>` or by an agent reading its README. This repo is the curated
collection, not the only source: any git repo with a `plugin.rn` folder
installs the same way.

## The plugins

| plugin | gives eidolon | runs alongside | install |
|---|---|---|---|
| [`browser/`](browser/) | `browser_open`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_read`, `browser_back`, `browser_state`; workflows `page_walk`, `page_watch` | `eidolon-browser`, a Rust service driving one headless Chromium | `eidolon plugins install dxcently/eidolon-plugins browser` — see its README for the service |
| [`subagent/`](subagent/) | `subagent_spawn`, `subagent_list`, `subagent_trace`, `subagent_steer`, `subagent_cancel` | `eidolon run`, child sessions in the background | `eidolon plugins install dxcently/eidolon-plugins subagent`, then `eidolon plugins trust subagent` |

Both need eidolon with the plugin runtime (upstream `master`).

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
<name>/                        → ~/.config/eidolon/plugins/<name>/
├── plugin.rn      the manifest: name, version, description, claims
├── README.md      what it is, and Prerequisites / Install / Verify / Uninstall
├── tools/*.rn     one file per tool: the stem is the bare verb, registration is <name>_<verb>
├── workflows/*.rn programs that drive the plugin's tools (optional)
├── service/       a Rust crate, when the tools need something running beside eidolon
└── package.nix    how the flake builds that service
```

The folder *is* the plugin directory: install it by putting the folder where
eidolon looks, and every `tools/*.rn` is adopted as `<name>_<verb>`, attributed
to the plugin in the gate's question and the log's audit lines. A tool file
carries everything it needs, endpoint included (upstream's rule: a tool is one
file you can hand to somebody). `plugin.rn` declares only what the plugin says
about itself — the layout is what names the verbs. A plugin cannot shadow a
built-in.

Upstream eidolon without the plugin runtime wants the flat install instead:
`tools/*.rn` copied into `~/.config/eidolon/tools/` under their own names
(`browser_open.rn`, …). That layout is in this repo's history before the plugin
port; the two do not share tool filenames.

## Building

```bash
nix build .#browser          # the service, with Chromium from nixpkgs
nix develop                  # cargo, clippy, chromium; `cargo test` runs the real-browser tests too
cargo test                   # without Nix: unit tests, plus browser tests if EIDOLON_BROWSER_CHROME is set
```

Linux only (WSL counts), same as upstream eidolon.

## License

MIT
