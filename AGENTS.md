# For agents

## Installing an extension

1. Read `<name>/README.md` in full before running anything.
2. Run its sections in order: **Prerequisites**, **Install**, **Verify**.
   Where a section offers a choice (Nix or Cargo), use Nix if `nix` is on
   PATH, otherwise the other route.
3. Stop at the first command that fails. Report the command and its output.
   Don't improvise a workaround.
4. **Verify** passing is the definition of installed. Report its output.

What you may touch: `~/.config/eidolon/tools/` (add the extension's files),
the extension's own token file, and a Nix profile or `~/.cargo/bin` for its
service. Nothing else under `~/.config/eidolon/` — not `config.toml`, not
`policy.rn`, not other tools.

A tool file can name where it sends requests and which secret it spends.
Read every `tools/*.rn` you're about to install; the endpoint is at the
bottom of each file.

## Adding an extension

- A folder per extension, laid out as in the README's **Layout**.
- Tool files are named `<extension>_<verb>.rn`, and so are the tools
  (`name:` in `manifest()`). A file named like a built-in (`read.rn`,
  `fetch.rn`, ...) **replaces that built-in**; the prefix is what prevents it.
- Every tool file is self-contained: `manifest()`, `call()`, and its endpoint.
  Repeat shared helpers in each file rather than sharing them.
- Anything that has to keep running (a browser, a model) is a service in
  `service/`, in Rust, built by `package.nix` and added to `flake.nix`.
- The README has the four sections, as plain commands an agent can run.
- `cargo clippy --all-targets` is clean and `cargo test` passes.
