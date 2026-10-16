#!/usr/bin/env bash
# guard.sh: sourced by run.sh before it copies anything. Refuses unless HOME and
# XDG_CONFIG_HOME are throwaway directories under /tmp, because this harness copies the
# websearch plugin into the config it is given and vouches for it there.
_under_tmp() {
    case $(realpath -m "$1") in
    /tmp/* | /var/tmp/*) return 0 ;;
    esac
    [ -n "${TMPDIR:-}" ] && case $(realpath -m "$1") in "$(realpath -m "$TMPDIR")"/*) return 0 ;; esac
    return 1
}

require_temp_config() {
    local cfg=${XDG_CONFIG_HOME:-} home=${HOME:-}
    if [ -z "$cfg" ] || [ "$(realpath -m "$cfg")" = "$(realpath -m "$home/.config")" ] || ! _under_tmp "$cfg"; then
        echo "refusing: XDG_CONFIG_HOME must be a temp directory, not ${cfg:-unset} (> $home/.config)" >&2
        echo "  run: t=\$(mktemp -d); HOME=\$t XDG_CONFIG_HOME=\$t/cfg XDG_STATE_HOME=\$t/state XDG_DATA_HOME=\$t/data bash tests/websearch/run.sh" >&2
        return 1
    fi
    if ! _under_tmp "$home"; then
        echo "refusing: HOME ($home) is not under /tmp or \$TMPDIR" >&2
        return 1
    fi
    return 0
}
