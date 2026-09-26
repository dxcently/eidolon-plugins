# eidolon-extensions

Extensions for [eidolon](https://github.com/noah427/eidolon). Each folder is
one extension: an `extension.rn` manifest, the Rune tools it registers, and
the service behind them if it needs one.

> **Status:** upstream eidolon has no extension host yet, so these don't load
> on current eidolon. They load on a build that has one.

## The extensions

| extension | tools | service | status |
|---|---|---|---|
| [`browser/`](browser/) | `browser_open`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_read`, `browser_back` | Python + Playwright/Chromium, one shared browser per machine | working |
| [`subagent/`](subagent/) | none yet | none: spawning runs in the harness's own process | stub: the toggle for `/api/subagent*`, and [`brief.md`](subagent/brief.md), the brief's shape |

**Web search** isn't here on purpose. eidolon ships it as the builtin `search`
tool (`crates/rune/builtin/search.rn`), which is tied to the session's own key.
Use that one. To read a result page, use `fetch` or `browser_read`.

## Install

Put the folder where your eidolon build looks for extensions. It reads
`extension.rn` and starts the `service` it declares.

`browser` needs its own venv inside its folder. It runs in WSL/Linux:

```bash
cd browser
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/playwright install chromium
```

Tests (`unittest`, no pytest):

```bash
cd browser
.venv/bin/pip install -r requirements-test.txt
.venv/bin/python -m unittest test_server
```

## Layout

```
<name>/
├── extension.rn    manifest(): name, description, service, tools
├── tools/*.rn      one file per tool, registered as <name>_<file>
└── service.py      the service, if the manifest declares one
```

## License

MIT
