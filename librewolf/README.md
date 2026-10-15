# librewolf

Read the one tab a person attaches in their **own** LibreWolf session, by
clicking a toolbar button on it. Four verbs, no browser of our own, and no
browsing on the assistant's behalf.

| tool | does |
|---|---|
| `librewolf_status` | report the attached tab, or why there is none |
| `librewolf_read` | the attached tab's visible text |
| `librewolf_structure` | a DOM-derived outline of the attached tab |
| `librewolf_detach` | end the attachment |

```
eidolon ──tools/*.rn──api_request──▶ eidolon-librewolf ──stdio──▶ extension ──▶ the attached tab
   (the endpoint, 127.0.0.1:8091,      (LibreWolf starts this:      (in the operator's
    token: ~/.config/eidolon/          it is the native messaging   real profile)
    librewolf.token)                   host the extension names)
```

This is the other half of what [`browser/`](../browser/) does. That plugin owns
one headless Chromium of its own and never sees the operator's cookies; this one
never owns a browser at all — it reads the operator's, and only the tab they
hand it, for as long as Firefox's temporary `activeTab` grant lasts.

## Prerequisites

- Linux, with **LibreWolf** (a Firefox fork; this was written against LibreWolf
  154). Firefox should work the same way, but nothing here was checked against it.
- eidolon with `api_request` and the **plugin runtime**.
- The host binary, either way:

  ```bash
  nix build .#librewolf          # or: nix profile install github:dxcently/eidolon-plugins#librewolf
  cargo install --path librewolf/service
  ```

- **The extension, loaded in LibreWolf.** This is an operator's act, not a
  plugin's, and there is no tool that can do it. The smallest way, and the one
  these checks were written against:

  > `about:debugging` → **This Firefox** → **Load Temporary Add-on…** →
  > pick `librewolf/extension/manifest.json`

  A temporary add-on is gone when LibreWolf exits; load it again next session. A
  permanent install is the operator's call — the force-install policy pattern is
  already used in `~/.config/nix/detail/librewolf/main.nix` for the charta
  new-tab page, and its comment there warns that a Nix rebuild under a running
  LibreWolf wedges the live instance.

- **The native messaging host manifest**, where LibreWolf looks for it:

  ```bash
  mkdir -p ~/.librewolf/native-messaging-hosts
  eidolon-librewolf --print-host-manifest > ~/.librewolf/native-messaging-hosts/eidolon_librewolf.json
  ```

  On Linux home-manager's `programs.librewolf.nativeMessagingHosts` writes to
  `~/.librewolf/native-messaging-hosts/`; a stock Firefox reads
  `~/.mozilla/native-messaging-hosts/`. The manifest's `path` must be absolute,
  and `--print-host-manifest` prints it that way for the binary that ran.

## Install

1. The host binary — see Prerequisites.

2. The plugin directory:

   ```bash
   eidolon plugins install dxcently/eidolon-plugins librewolf
   eidolon plugins trust librewolf
   for v in status read structure detach; do
     eidolon plugins grant librewolf_$v file:~/.config/eidolon/librewolf.token
   done
   ```

   **There is no `service approve` / `service start` step.** This plugin declares
   no `service:` block: the process that has to be running is the one LibreWolf
   spawns, and eidolon cannot start a browser. Everything else an install does —
   the vouch for the verbs, the grant for the token file — is the same as any
   other plugin.

3. Load the extension and install the host manifest — see Prerequisites.

## Verify

```bash
curl -s http://127.0.0.1:8091/health
# {"attached":false,"browser_connected":true,"status":"ok"}
eidolon tools | grep -c '"name": "librewolf_'
# 4
```

`browser_connected: false` means no browser has the extension loaded and talking
to this host. `attached: false` means nobody has clicked the toolbar button yet.

The extension's own browser path is driven against the shipped `background.js`
with a fake `browser` and a fake DOM, and every defect it pins has the pre-fix logic
beside it as a witness that must still fail:

```bash
bash tests/librewolf/js/run.sh      # 65 checks, no browser, no network
```

The checks that need no browser but do need the real binary — the native framing,
the token file's rules, the launch arguments, and the generation/document binding
including a same-URL reload and a revocation that races a read — are a fake
extension on the other end of a pipe:

```bash
cargo test -p eidolon-librewolf
```

Two harnesses, and what each one is evidence of:

```bash
# no browser: every verb's answer when the bridge is not running
t=$(mktemp -d); HOME=$t XDG_CONFIG_HOME=$t/cfg XDG_STATE_HOME=$t/state XDG_DATA_HOME=$t/data \
  bash tests/librewolf/run.sh

# a disposable headless LibreWolf, its own profile and temp HOME, local pages
t=$(mktemp -d); HOME=$t XDG_CONFIG_HOME=$t/cfg XDG_STATE_HOME=$t/state XDG_DATA_HOME=$t/data \
  bash tests/librewolf/throwaway.sh
```

The second one drives a real browser end to end: the browser spawns this host,
the extension connects, a page's text and outline come back, a new document ends
the attachment, a second attach works, `detach` ends it, and stopping the browser
takes the host with it. **It does not cover the toolbar click.** A headless
browser has no toolbar, so that harness *substitutes* the click with a test-only
trigger and a host permission for the local test origin, in a copy of the
extension. **The real click and the `activeTab` grant it creates are not covered
by any automated check here**; they need a person and a visible browser, and that
acceptance step is separate on purpose.

## The trust boundary, said exactly

There are three different things here and it is easy to let one stand in for
another. Say which is which:

- **The vouch is for the verb, not for the page.** `eidolon plugins trust
  librewolf` records a standing yes for `librewolf_read` on these exact bytes.
  After that, a read runs with no person in the loop — which is the intended
  shape, because the person in the loop is the click, not a prompt. `status`,
  `read` and `structure` are declared `read_only` because they change nothing in
  the browser; `detach` is `mutating` because it ends an attachment. A tool that
  is *sensitive* is not the same as a tool that *mutates*, and labelling a read
  `mutating` would only buy a prompt, not a check. If an operator would rather be
  asked on every read, the class is a one-line change and the gate will ask — but
  that is a choice about prompts, not about exposure.
- **The click is the consent for the content.** `activeTab` is granted when a
  person clicks the extension's toolbar button on the tab, and nothing in this
  plugin can grant, renew, or re-use it. Firefox documents the grant as tied to the
  document it was given for; this plugin does not depend on that — **it ends the
  attachment itself** on every new document in the tab, on the tab's close, on a host
  that goes away, and on any navigation that arrives while a click is still being
  confirmed. There is no verb that attaches a tab: `librewolf_status`
  reports what the click created, and every other verb refuses when there is
  nothing attached.
- **The token is the transport's authentication, and nothing more.** The
  endpoint is loopback-only and wants `Bearer <token>` from
  `~/.config/eidolon/librewolf.token` (mode 0600), exactly as `eidolon-browser`
  does. Any process running as the same user that can read that file can call
  `/call`; `allowed_extensions` in the host manifest is the *browser's*
  enforcement of which add-on may spawn this host, not an authentication of
  whoever is on the other end of stdin. The host checks both the add-on id the
  browser passes and the one the extension's `hello` carries, because a
  page-facing component is not something to take on trust — but neither check
  makes the loopback endpoint safe against a same-user process, and nothing here
  pretends otherwise.

What the assistant can therefore see: exactly what is rendered in the one tab a
person clicked on, including anything that tab displays from an authenticated
session — and only while that document is loaded. It cannot see cookies, other
tabs, history, or a page it was not handed.

## Limits, in the answer of every call

- **The outline carries names, never contents.** A name comes from `aria-label`,
  `alt`, `title`, `placeholder`, an associated `<label>`, the `name` attribute, or
  the element's rendered text — and for a `textarea` or a `select` not even the
  rendered text, because there it *is* the value. Nothing reads `.value`. An element
  that is not rendered is not in the outline and the walk stops at it, so a
  `display:none`, `hidden`, `visibility:hidden` or `opacity:0` subtree keeps its
  contents to itself, and `input[type=hidden]` is skipped by type rather than by
  trusting the stylesheet. The cost of the last rule is over-skipping: content a page
  animates in from `opacity:0` is absent until it is visible.
- **`read` returns rendered text only.** `innerText`, with no `textContent`
  fallback: a page whose visible text is empty reads as empty rather than handing
  back the hidden and `<script>` text a person cannot see. A form control's value is
  not in `innerText` either, a password field's included.
- **The token file is checked, not assumed.** A token is used only if it is a
  regular file, owned by this user, mode 0600, opened without following a symlink;
  otherwise the host refuses and says what to do. A missing one is created with
  `create_new` — never truncating, never clobbering a concurrent start, which is
  re-read instead — and an *empty* file is a refusal, not something to overwrite.
- **The launch arguments are read as positions.** Firefox starts a native host with
  the manifest path and then the add-on id; both are checked as such, so a wrong id
  that happens to lack an `@` is refused rather than waved through.
- **DOM-derived, not an accessibility tree.** WebExtensions have no
  accessibility API, so `librewolf_structure` walks the DOM for headings, links,
  buttons, form controls and landmark elements and reports roles read from tags
  and `role` attributes. It is not the tree `browser_snapshot` prints.
- **No `confine` and no network guarantee.** `browser_open`'s `confine` works
  because the browser is ours and every request leaves through a proxy that
  refuses other origins. There is no such boundary here: the page was loaded by
  the operator's browser, with their cookies, and it goes where it goes. The
  boundary this plugin has is *which document* it will read, not where the
  document may travel.
- **The attachment dies with the next document.** A reload, a same-origin link, a
  redirect, a form post: every one of them loads a new document, and *we* end the
  attachment on each — on the tab's close, on a host that goes away, and on any
  navigation that arrives while a click is still being confirmed. Nothing here waits
  for the browser to end its own `activeTab` grant, and any read that finds the
  document moved is refused rather than answered.
- **A document is named by a nonce, not by its address and not by its clock.** The
  identity is a random value the extension keeps in the content script's **own
  world** — on the sandbox's global, not on the page's window and not in the DOM. It
  is created the first time this extension looks at a document, so a reload at the
  *same URL* gets a fresh one, whether or not any revocation event arrived and
  whatever the clock reads. Both halves compare it for equality, and the host
  refuses an attachment that does not name its document.

  That rests on two things about the platform, and both are **checked on every run**
  of `tests/librewolf/throwaway.sh` rather than assumed: the injected script's
  `globalThis` is not the page's window (`global-distinct`), a value there survives
  between two `executeScript` calls in one document (`fresh: true` then
  `fresh: false`), and the page's own script sees `nothing`. If a future LibreWolf
  changed either, that run fails and says so.

  `performance.timeOrigin` is kept beside the nonce as a second, independent check.
  It is a **discriminator, not an identity document**: nothing promises it is unique,
  and LibreWolf ships `privacy.resistFingerprinting = true`, which is exactly the
  sort of setting that coarsens clocks. Measured here it is not coarsened — three
  documents of one tab reported `…994.752`, `…378.333` and `…428.654` — but that is a
  measurement, not a guarantee, which is why the nonce carries the weight and a
  mismatch on either is a refusal.
- **No refs, and no element handles.** Nothing is written into the page — not
  even a marker attribute — so no element can be addressed across calls, and
  this version has no click or type verb to need one. Reading is the whole of it.
- **One bridge per machine.** The host binds 127.0.0.1:8091; a second LibreWolf
  profile that spawns a second host finds the port taken and **exits** with the
  reason, rather than attaching to the instance that holds it.
- **Page text is untrusted data.** Every answer says so. Nothing in it is
  interpreted, stored, or put back into a page.
- **This host outlives nothing.** It exits when the browser closes the native
  messaging port, or when the extension has said nothing for 30 s
  (`EIDOLON_LIBREWOLF_SILENCE_S` to change it). Both are needed: end of stream is
  *not* a reliable "the browser is gone", because a content process can hold the
  write end of that pipe, and reparenting is not one either — measured on this
  machine, a host whose browser was still running had already been reparented to
  init. A host that outlived its browser would hold :8091 and answer the tools
  about a session that is no longer there. The extension sends a heartbeat; the
  host treats silence as death.
- **No diagnostic may kill the shutdown path.** The browser collects this
  process's stderr into its console, and that pipe breaks the moment the browser
  dies. `eprintln!` panics on a broken pipe — which killed the thread trying to
  end the host, and is how a host came to outlive its browser during this work.
  Nothing here uses it; the rule is pinned by a test in
  `service/tests/fake_extension.rs`.

## Uninstall

```bash
eidolon plugins uninstall librewolf
rm -f ~/.librewolf/native-messaging-hosts/eidolon_librewolf.json
rm -f ~/.config/eidolon/librewolf.token
```

Then remove the extension in LibreWolf (`about:debugging` → This Firefox →
Remove) if it was loaded as a temporary add-on, and stop the browser: the host
process exits with the native messaging port. The vouch rows stay in
`~/.config/eidolon/policy.permits.rn`; `eidolon plugins untrust librewolf` drops
them.

## Settings

| variable | default | |
|---|---|---|
| `EIDOLON_LIBREWOLF_PORT` | `8091` | change `base_url` in every `tools/librewolf_*.rn` to match |
| `EIDOLON_LIBREWOLF_TOKEN_FILE` | `~/.config/eidolon/librewolf.token` | change `token_file` in the tools to match |

## How it works

`service/` is the Rust crate, and one process with two faces. LibreWolf starts it
because the extension's host manifest names it, and it speaks the native
messaging wire on stdio; at the same time it binds 127.0.0.1:8091 and serves the
tools. `src/frame.rs` is the length-prefixed wire, `src/state.rs` is the record of
what the browser told us and the rule that an answer is returned only for the
attachment *and the document* it was asked about, and `src/main.rs` is the
endpoint and the stdio channel. The extension is `extension/`: an MV2
persistent background page with `nativeMessaging` and `activeTab` and nothing
else.

The extension sends a heartbeat every five seconds, and anything at all from it
resets the host's clock (see the last two Limits). `cargo test -p eidolon-librewolf`
runs the unit tests and `tests/fake_extension.rs`, which drives the real binary
over a real pipe and a real socket with a scripted extension on the other end —
including a same-URL reload, a revocation racing a read, a silence that must end
the host, and a broken stderr that must not.
