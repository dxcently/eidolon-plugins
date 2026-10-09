#!/usr/bin/env bash
# guard.sh: sourced by run.sh before it installs anything. Refuses unless HOME and
# XDG_CONFIG_HOME are throwaway directories, because this harness copies the plugin into
# the config it is given, trusts it there, and puts fake compositor clients on PATH.
#
#   . "$(dirname "$0")/guard.sh"; require_temp_config
_under_tmp() {
    case $(realpath -m "$1") in
    /tmp/* | /var/tmp/*) return 0 ;;
    esac
    [ -n "${TMPDIR:-}" ] && case $(realpath -m "$1") in "$(realpath -m "$TMPDIR")"/*) return 0 ;; esac
    return 1
}

require_temp_config() {
    local cfg=${XDG_CONFIG_HOME:-} home=${HOME:-}
    if [ -z "$cfg" ]; then
        echo "refusing: XDG_CONFIG_HOME is not set, so eidolon would use ${home}/.config, your real config." >&2
        echo "  run: t=\$(mktemp -d); HOME=\$t XDG_CONFIG_HOME=\$t/cfg XDG_STATE_HOME=\$t/state XDG_DATA_HOME=\$t/data bash tests/hyprland/run.sh" >&2
        return 1
    fi
    if [ "$(realpath -m "$cfg")" = "$(realpath -m "$home/.config")" ]; then
        echo "refusing: XDG_CONFIG_HOME ($cfg) is your real config." >&2
        return 1
    fi
    if ! _under_tmp "$cfg"; then
        echo "refusing: XDG_CONFIG_HOME ($cfg) is not under /tmp or \$TMPDIR." >&2
        return 1
    fi
    if ! _under_tmp "$home"; then
        echo "refusing: HOME ($home) is not under /tmp or \$TMPDIR." >&2
        return 1
    fi
    return 0
}
