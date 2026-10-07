#!/usr/bin/env bash
# guard.sh: sourced by scripts that install the fake `browser`. Refuses unless XDG_CONFIG_HOME,
# XDG_RUNTIME_DIR (where eidolon registers a session among its peers) and HOME are throwaway
# directories (the jev tools read ~/.config/eidolon/jev.token), and the swarm is off there:
# a temp config with no config.toml gets `[swarm] enabled = false` written to it, one that
# has a config.toml must already say so.
#
#   . "$(dirname "$0")/guard.sh"; require_temp_config
_under_tmp() {
  case $(realpath -m "$1") in
    /tmp/*|/var/tmp/*) return 0 ;;
  esac
  [ -n "${TMPDIR:-}" ] && case $(realpath -m "$1") in "$(realpath -m "$TMPDIR")"/*) return 0 ;; esac
  return 1
}
# The temp config's config.toml, which must turn the swarm off.
_swarm_off() {
  local f=$1
  if [ ! -e "$f" ]; then
    mkdir -p "$(dirname "$f")" && printf '[swarm]\nenabled = false\n' > "$f"
    return
  fi
  if awk '/^\[/ { s = ($0 ~ /^\[swarm\][ \t]*$/) } s && /^[ \t]*enabled[ \t]*=[ \t]*false[ \t]*(#.*)?$/ { ok = 1 } END { exit !ok }' "$f"; then
    return 0
  fi
  echo "refusing: $f does not turn the swarm off; add" >&2
  printf '  [swarm]\n  enabled = false\n' >&2
  return 1
}
require_temp_config() {
  local cfg=${XDG_CONFIG_HOME:-} home=${HOME:-}
  if [ -z "$cfg" ]; then
    echo "refusing: XDG_CONFIG_HOME is not set, so eidolon would use ${home}/.config, your real config." >&2
    echo "  tests/jev/ installs a fake plugin named \`browser\`; set XDG_CONFIG_HOME, XDG_STATE_HOME, XDG_DATA_HOME and HOME to a temp dir." >&2
    return 1
  fi
  if [ "$(realpath -m "$cfg")" = "$(realpath -m "$home/.config")" ]; then
    echo "refusing: XDG_CONFIG_HOME ($cfg) is your real config." >&2
    echo "  tests/jev/ installs a fake plugin named \`browser\`; point it, and HOME, at a temp dir." >&2
    return 1
  fi
  if ! _under_tmp "$cfg"; then
    echo "refusing: XDG_CONFIG_HOME ($cfg) is not under /tmp or \$TMPDIR." >&2
    return 1
  fi
  if ! _under_tmp "$home"; then
    echo "refusing: HOME ($home) is not under /tmp or \$TMPDIR; the jev tools read ~/.config/eidolon/jev.token." >&2
    echo "  run with HOME=<temp dir> as well." >&2
    return 1
  fi
  local run=${XDG_RUNTIME_DIR:-}
  if [ -z "$run" ]; then
    echo "refusing: XDG_RUNTIME_DIR is not set, so eidolon would register this run among your real sessions." >&2
    echo "  run with XDG_RUNTIME_DIR=<temp dir> as well." >&2
    return 1
  fi
  if ! _under_tmp "$run"; then
    echo "refusing: XDG_RUNTIME_DIR ($run) is not under /tmp or \$TMPDIR." >&2
    return 1
  fi
  _swarm_off "$cfg/eidolon/config.toml"
}
