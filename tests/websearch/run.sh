#!/usr/bin/env bash
# run.sh: the websearch plugin with no grant, no network, and canned replies.
#
#   t=$(mktemp -d)
#   HOME=$t XDG_CONFIG_HOME=$t/cfg XDG_STATE_HOME=$t/state XDG_DATA_HOME=$t/data \
#     bash tests/websearch/run.sh
#
# Two checks, both offline. The plugin is copied unchanged into a throwaway config and
# vouched for there. (1) No `secret:ollama` grant is written, so the call stops at the
# grant check before any connection opens. (2) The parsing functions, cut from the shipped
# tools/search.rn, are run over canned replies (parse-cases.rn).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
. "$here/guard.sh"
require_temp_config || exit 2

: "${XDG_STATE_HOME:?set XDG_STATE_HOME to a temp dir}"
: "${XDG_DATA_HOME:?set XDG_DATA_HOME to a temp dir}"

eidolon=$(command -v eidolon || true)
[ -n "$eidolon" ] || { echo "eidolon is not on PATH" >&2; exit 2; }

plug=$XDG_CONFIG_HOME/eidolon/plugins
mkdir -p "$plug"
rm -rf "$plug/websearch"
cp -r "$repo/websearch" "$plug/websearch"
mkdir -p "$plug/websearch/workflows"
cp "$here/no-grant.rn" "$plug/websearch/workflows/no-grant.rn"

# The parse workflow is the canned cases followed by the parsing functions of the shipped
# tool, cut between its markers. One source of truth: the tool file.
cat "$here/parse-cases.rn" > "$plug/websearch/workflows/parse.rn"
echo >> "$plug/websearch/workflows/parse.rn"
search="$plug/websearch/tools/search.rn"
[ "$(grep -c '^// parse:begin$' "$search")" = 1 ] && [ "$(grep -c '^// parse:end$' "$search")" = 1 ] || {
    echo "FAIL parse: $search must hold exactly one '// parse:begin' and one '// parse:end' line" >&2
    exit 1
}
sed -n '/^\/\/ parse:begin/,/^\/\/ parse:end/p' "$search" >> "$plug/websearch/workflows/parse.rn"

"$eidolon" plugins trust websearch >/dev/null

mkdir -p "$XDG_STATE_HOME"
fail=0
for wf in no-grant parse; do
    report=$XDG_STATE_HOME/$wf.txt
    "$eidolon" workflow run "$plug/websearch" "$wf" --args '{}' --provider mock >"$report" 2>&1 || true
    if grep -q "checks hold" "$report"; then
        grep -o '"report":"[^}]*' "$report" | sed 's/^"report":"//; s/","run".*//; s/\\n/\n/g' || true
        echo "ok   $wf"
    else
        echo "FAIL $wf" >&2
        sed -n 1,60p "$report" >&2
        fail=1
    fi
done
exit "$fail"
