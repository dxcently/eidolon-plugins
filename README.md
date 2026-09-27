# eidolon-extensions

Extensions for [eidolon](https://github.com/noah427/eidolon). Each folder is
one extension, laid out by where its pieces go in eidolon, so it can be
installed by hand or by an agent reading its README.

## The extensions

| extension | gives eidolon | runs alongside | status |
|---|---|---|---|
| [`browser/`](browser/) | `browser_open`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_read`, `browser_back` | `eidolon-browser`, a Rust service driving one headless Chromium | works on upstream eidolon |
| [`subagent/`](subagent/) | `subagent_spawn` | `eidolon run`, a child session in the background | works on upstream eidolon |

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
<name>/
├── README.md       what it is, and Prerequisites / Install / Verify / Uninstall
├── tools/*.rn      → ~/.config/eidolon/tools/     one file per tool, named <name>_<verb>.rn
├── service/        a Rust crate, when the tools need something running beside eidolon
└── package.nix     how the flake builds that service
```

A tool file carries everything it needs, endpoint included (upstream's rule:
a tool is one file you can hand to somebody). There is no manifest or
registry; eidolon reads `~/.config/eidolon/tools/` and that is the whole
contract today. If eidolon grows an extension format, these folders are
already split by destination.

## Building

```bash
nix build .#browser          # the service, with Chromium from nixpkgs
nix develop                  # cargo, clippy, chromium; `cargo test` runs the real-browser tests too
cargo test                   # without Nix: unit tests, plus browser tests if EIDOLON_BROWSER_CHROME is set
```

Linux only (WSL counts), same as upstream eidolon.

## License

MIT
