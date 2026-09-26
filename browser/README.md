# browser

A real browser for eidolon: one headless Chromium, shared by every session on
the machine, driven through six tools.

| tool | does |
|---|---|
| `browser_open` | go to a URL; with `confine`, lock the browser to a list of origins |
| `browser_snapshot` | the page as an accessibility tree, each element with a `[ref=eN]` |
| `browser_click` | click a ref from the latest snapshot |
| `browser_type` | type into a ref, optionally pressing Enter |
| `browser_read` | the page's visible text |
| `browser_back` | back one history entry |

```
eidolon ──tools/*.rn──api_request──▶ eidolon-browser (127.0.0.1:8090) ──CDP──▶ Chromium
                                     token: ~/.config/eidolon/browser.token
```

A ref is only good until the page changes: any click, type, open or back
invalidates them, and a stale ref is refused by name. `confine` routes the
browser through a proxy inside the service that refuses any other origin
before a connection is made, and that covers redirects, popups, iframes and
page scripts.

## Prerequisites

- Linux or WSL.
- eidolon with `api_request` (upstream since `a618ef1`, 2026-09-21). An older
  eidolon can't compile the tools, and **Verify** shows fewer than 6.
- One of:
  - **Nix** with flakes, or
  - **Rust** 1.85+ (`cargo`) and a **Chromium** or Chrome binary.

## Install

1. The service, either way:

   ```bash
   # Nix: builds it with Chromium included
   nix profile install github:dxcently/eidolon-extensions#browser
   ```

   ```bash
   # Cargo: from a clone of this repo; Chromium comes from PATH or EIDOLON_BROWSER_CHROME
   cargo install --path browser/service
   ```

2. The tools:

   ```bash
   mkdir -p ~/.config/eidolon/tools
   cp browser/tools/browser_*.rn ~/.config/eidolon/tools/
   ```

   (From a Nix-only install without a clone: `git clone https://github.com/dxcently/eidolon-extensions` first.)

3. Start the service. It makes the token file on first run.

   ```bash
   eidolon-browser
   ```

   Leave it running, or run it as a systemd user service:

   ```bash
   mkdir -p ~/.config/systemd/user
   cat > ~/.config/systemd/user/eidolon-browser.service <<'EOF'
   [Unit]
   Description=eidolon browser service

   [Service]
   ExecStart=%h/.nix-profile/bin/eidolon-browser
   Restart=on-failure

   [Install]
   WantedBy=default.target
   EOF
   systemctl --user daemon-reload && systemctl --user enable --now eidolon-browser
   ```

   With a Cargo install, `ExecStart=%h/.cargo/bin/eidolon-browser`.

## Verify

```bash
curl -s http://127.0.0.1:8090/health
# {"chromium_installed":true,"status":"ok"}
eidolon tools | grep -c '"name": "browser_'
# 6
```

`chromium_installed: false` means no Chromium was found: set
`EIDOLON_BROWSER_CHROME` to its path.

## Uninstall

```bash
systemctl --user disable --now eidolon-browser 2>/dev/null
rm -f ~/.config/systemd/user/eidolon-browser.service
rm -f ~/.config/eidolon/tools/browser_*.rn ~/.config/eidolon/browser.token
nix profile remove browser 2>/dev/null || cargo uninstall eidolon-browser
```

## Settings

All optional, read by the service at start.

| variable | default | |
|---|---|---|
| `EIDOLON_SERVICE_PORT` | `8090` | change `base_url` in every `tools/browser_*.rn` to match |
| `EIDOLON_BROWSER_TOKEN_FILE` | `~/.config/eidolon/browser.token` | change `token_file` in the tools to match |
| `EIDOLON_BROWSER_CHROME` | `chromium`, then `google-chrome` on PATH | the Nix package sets it |
| `EIDOLON_BROWSER_NO_SANDBOX` | unset | set it only if Chromium can't start its sandbox (some containers) |

## How it works

`service/` is the Rust crate. `src/main.rs` is the HTTP side (`/health`,
`/call`, auth). `src/browser.rs` is the browser and the six methods.
`src/snapshot.rs` prints Chrome's accessibility tree, `src/filter.rs` does
`roles`/`within`/`section`, `src/proxy.rs` handles `confine`, and
`src/sweep.rs` cleans up profile directories left by a crash.

Tests: `cargo test` runs the unit tests. With `EIDOLON_BROWSER_CHROME` set
(it is in `nix develop`), it also runs `tests/real_browser.rs`, which drives
real Chromium against two local test sites and checks, among other things,
that a confined page never reaches the other site.
