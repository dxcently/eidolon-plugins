# libsfixture

Not a curated plugin — the fixture that proves the libraries system. Its
manifest declares [`libs/regex/regex.rn`](../../libs/regex/regex.rn) by
content pin; installing this plugin vendors the library into its own
`lib/`, and its one workflow calls the engine it does not carry. It
dispatches no tools and holds no secrets, so installing it is safe and
mostly useful as a demonstration.

## Prerequisites

Eidolon with the plugin runtime (upstream `master`) and workflows. No
services, no credentials, nothing to trust — the plugin ships no tools.

## Install

```
eidolon plugins install dxcently/eidolon-plugins libsfixture
```

The install line names the vendoring:

```
    vendored lib/regex.rn ← dxcently/eidolon-plugins/libs/regex/regex.rn (sha256:5b1e…)
```

A copy of the regex engine now sits in the plugin's own `lib/`,
pin-verified. If the install refuses instead, naming two hashes, the bytes
at the source are not the bytes the manifest pinned — see
[`libs/README.md`](../../libs/README.md) for the re-pin discipline.

## Verify

```
eidolon workflow run ~/.config/eidolon/plugins/libsfixture scan \
    --args '{"line": "COMMAND   PID  USER"}' --provider mock
```

Exit 0, one JSON line, and the run's `report` says `"matched": true`. The
run is a session; `eidolon log <the session the line names>` shows the pin
over the compiled sources — the vendored bytes included.

## Uninstall

```
eidolon plugins uninstall libsfixture
```

The tree — vendored copy included — goes, and the record is forgotten.
