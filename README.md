# eidolon-plugins

Extensions for [eidolon](https://github.com/noah427/eidolon). Each folder is
one extension, laid out by where its pieces go in eidolon, so it can be
installed by hand or by an agent reading its README.

## The extensions

| extension | gives eidolon | runs alongside | status |
|---|---|---|---|
| [`browser/`](browser/) | `browser_open`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_read`, `browser_back` | `eidolon-browser`, a Rust service driving one headless Chromium | needs eidolon with the plugin runtime |
| [`subagent/`](subagent/) | nothing yet | — | a design brief, not installable |

**Web search** isn't here on purpose: eidolon ships it as the built-in
`search` tool, tied to the session's own key. To read a result, use `fetch`,
or `browser_open` + `browser_read` for pages that need a real browser.

## Installing one

Tell an agent:

> Install the `<name>` extension from this repo: read `<name>/README.md` and
> follow it.

Or do it yourself. Every extension README has the same four sections, run in
order: **Prerequisites**, **Install**, **Verify**, **Uninstall**. See
[AGENTS.md](AGENTS.md) for the rules an agent follows while doing it.

## Layout

```
<name>/                        → ~/.config/eidolon/plugins/<name>/
├── plugin.rn      the manifest: name, version, description, claims
├── README.md      what it is, and Prerequisites / Install / Verify / Uninstall
├── tools/*.rn     one file per tool: the stem is the bare verb, registration is <name>_<verb>
├── service/       a Rust crate, when the tools need something running beside eidolon
└── package.nix    how the flake builds that service
```

The extension *is* the plugin directory: install it by putting the folder where
eidolon looks, and every `tools/*.rn` is adopted as `<name>_<verb>`, attributed
to the plugin in the gate's question and the log's audit lines. A tool file
carries everything it needs, endpoint included (upstream's rule: a tool is one
file you can hand to somebody). `plugin.rn` declares only what the plugin says
about itself — the layout is what names the verbs.

Upstream eidolon without the plugin runtime wants the flat install instead:
`tools/*.rn` copied into `~/.config/eidolon/tools/` under their own names
(`browser_open.rn`, …). That layout is the commit before the plugin one on this
branch; the two do not share tool filenames.

## Building

```bash
nix build .#browser          # the service, with Chromium from nixpkgs
nix develop                  # cargo, clippy, chromium; `cargo test` runs the real-browser tests too
cargo test                   # without Nix: unit tests, plus browser tests if EIDOLON_BROWSER_CHROME is set
```

Linux only (WSL counts), same as upstream eidolon.

## License

MIT
