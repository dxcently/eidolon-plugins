#!/bin/sh
# The fixture's pin guard, in the shape of tests/jev/pin.sh: recompute the
# library's sha256 and compare it against the pin the fixture's manifest
# declares. A library that moved without a re-pin refuses here instead of
# at someone's install.
set -eu
cd "$(dirname "$0")/../.."

LIB=libs/regex/regex.rn
MANIFEST=tests/libsfixture/plugin.rn
GOT="sha256:$(sha256sum "$LIB" | cut -d' ' -f1)"

if [ "${1:-}" = "--rewrite" ]; then
    sed -i "s/sha256:[0-9a-f]\{64\}/$GOT/" "$MANIFEST"
    echo "re-pinned $MANIFEST to $GOT"
    exit 0
fi

if grep -q "$GOT" "$MANIFEST"; then
    echo "pin ok: $GOT"
else
    echo "pin drifted: $LIB is $GOT, which $MANIFEST does not pin" >&2
    echo "if the change is intended: $0 --rewrite" >&2
    exit 1
fi
