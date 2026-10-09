# The browser service, built from the workspace, with Chromium from nixpkgs.
# `nix run .#browser` starts it.
{
  lib,
  rustPlatform,
  makeWrapper,
  chromium,
}:

rustPlatform.buildRustPackage {
  pname = "eidolon-browser";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ./service
      # The workspace has more than one member; cargo loads every member's
      # manifest, so each package's source has to carry all of them.
      ../librewolf/service
    ];
  };
  cargoLock.lockFile = ../Cargo.lock;

  # The workspace has more than one member. Without this, `cargo build` builds every
  # member and `$out/bin` ships both binaries: `nix build .#librewolf` would carry
  # eidolon-browser, and `.#browser` would carry this one. One package, one program.
  cargoBuildFlags = [ "-p" "eidolon-browser" ];

  nativeBuildInputs = [ makeWrapper ];

  # The real-browser tests skip themselves without EIDOLON_BROWSER_CHROME,
  # so this runs the unit tests only.
  postInstall = ''
    wrapProgram $out/bin/eidolon-browser \
      --set-default EIDOLON_BROWSER_CHROME ${lib.getExe chromium}
  '';

  meta = {
    description = "One shared headless Chromium behind eidolon's browser_* tools";
    license = lib.licenses.mit;
    mainProgram = "eidolon-browser";
    platforms = lib.platforms.linux;
  };
}
