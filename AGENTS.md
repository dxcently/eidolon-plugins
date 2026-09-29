# For agents

## Installing an extension

1. Read `<name>/README.md` in full before running anything.
2. Run its sections in order: **Prerequisites**, **Install**, **Verify**.
   Where a section offers a choice (Nix or Cargo), use Nix if `nix` is on
   PATH, otherwise the other route.
3. Stop at the first command that fails. Report the command and its output.
   Don't improvise a workaround.
4. **Verify** passing is the definition of installed. Report its output.

What you may touch: `~/.config/eidolon/plugins/` and its `plugins.toml`
(which `eidolon plugins install` writes), `policy.permits.rn` (which
`eidolon plugins trust` writes), `~/.config/eidolon/tools/` (the files of an
extension still installed by hand), the extension's own token file, and a Nix
profile or `~/.cargo/bin` for its service. Nothing else under
`~/.config/eidolon/` — not `config.toml`, not `policy.rn`, not other tools.

A tool file can name where it sends requests and which secret it spends.
Read every `tools/*.rn` you're about to install; the endpoint is at the
bottom of each file.

## Adding an extension

- A folder per extension, laid out as in the README's **Layout**.
- A plugin is a folder with `plugin.rn` at its root — `manifest()` returning
  `name` (equal to the folder's name), `version`, `description`, `claims`.
  `tools/<verb>.rn` is adopted as `<plugin>_<verb>`: **the file's stem is the
  bare verb, the declared `name:` is the namespaced one.** So subagent's
  spawn tool is `subagent/tools/spawn.rn` declaring `name: "subagent_spawn"`.
- **A plugin cannot shadow a built-in.** Adoption refuses `<plugin>_<verb>`
  when that is a built-in's name, and the operator's own tools win over a
  plugin's, so no prefix is needed to stay out of the way — the namespace is
  the directory's name, and the directory's name is the plugin's.
- Installing is `eidolon plugins install <owner>/<repo> <folder>`, then
  `eidolon plugins trust <plugin>` (installing does not trust); the listing is
  `eidolon plugins --dir <dir>`, and uninstalling is
  `eidolon plugins uninstall <plugin>`.
- Every tool file is self-contained: `manifest()`, `call()`, and its endpoint.
  Repeat shared helpers in each file rather than sharing them.
- Anything that has to keep running (a browser, a model) is a service in
  `service/`, in Rust, built by `package.nix` and added to `flake.nix`.
- The README has the four sections, as plain commands an agent can run.
- `cargo clippy --all-targets` is clean and `cargo test` passes.
