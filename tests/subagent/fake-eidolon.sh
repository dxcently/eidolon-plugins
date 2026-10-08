#!/bin/sh
# fake-eidolon.sh: a stand-in for eidolon in the subagent tests. `--version` succeeds (the tools
# look for a binary that answers it). Every other call is recorded, one line per call: each
# argument in brackets, then the EIDOLON_CONFIG the call saw (`unset` when it is not set), to
# $FAKE_EID_LOG. `models` prints a three-model catalog in the shape `eidolon models` prints, so
# the tools' catalog parsing runs. Nothing is run: no model, no provider, no network.
if [ "$1" = "--version" ]; then
  echo "fake-eidolon 0.0.0"
  exit 0
fi
if [ -n "${FAKE_EID_LOG:-}" ]; then
  for a in "$@"; do
    printf '[%s]' "$a"
  done >> "$FAKE_EID_LOG"
  printf ' cfg=%s\n' "${EIDOLON_CONFIG-unset}" >> "$FAKE_EID_LOG"
fi
for a in "$@"; do
  if [ "$a" = models ]; then
    printf '%s\n' "[system] fake catalog" \
      "fake:cheap  Cheap  fake · 8k ctx · \$0.1/0.2 per M" \
      "fake:dear   Dear   fake · 128k ctx · \$3/9 per M" \
      "fake:free   Free   fake · 4k ctx"
    exit 0
  fi
done
exit 0
