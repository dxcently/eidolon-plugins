# For agents

## Installing an extension

1. Read `<name>/README.md` in full before running anything.
2. Run its sections in order: **Prerequisites**, **Install**, **Verify**.
   Where a section offers a choice (Nix or Cargo), use Nix if `nix` is on
   PATH, otherwise the other route.
3. Stop at the first command that fails. Report the command and its output.
   Don't improvise a workaround.
4. **Verify** passing is the definition of installed. Report its output.

What you may touch: `~/.config/eidolon/plugins/` (add the extension's own
directory), the extension's own token file, and a Nix profile or `~/.cargo/bin`
for its service. Two commands in the Install section change permissions —
`eidolon plugins-trust` vouches the verbs, `eidolon plugins-grant` records the
credential. Run them as written and repeat them in your report: they are the
part of an install a person should be able to see afterwards. Nothing else under
`~/.config/eidolon/` — not `config.toml`, not `policy.rn`.

A tool file can name where it sends requests and which secret it spends.
Read every `tools/*.rn` you're about to install; the endpoint is at the
bottom of each file.

## Adding an extension

- A folder per extension, laid out as in the README's **Layout**. The folder
  *is* the plugin directory: `plugin.rn` at the root, the payload directories
  beside it.
- Tool files are named for the bare verb (`open.rn`, `snapshot.rn`), and the
  tool they declare carries the namespaced name (`name: "browser_open"` in
  `manifest()`): eidolon registers `<folder>_<stem>`, so the stem is the verb
  and the declaration is what a session, a log line and a vouch row all say.
  A contribution that would join to a built-in's name is refused, not applied —
  plugins never shadow anything.
- Every tool file is self-contained: `manifest()`, `call()`, and its endpoint.
  Repeat shared helpers in each file rather than sharing them.
- Anything that has to keep running (a browser, a model) is a service in
  `service/`, in Rust, built by `package.nix` and added to `flake.nix`.
- The README has the four sections, as plain commands an agent can run.
- `cargo clippy --all-targets` is clean and `cargo test` passes.
