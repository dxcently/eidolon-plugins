#!/usr/bin/env bash
# pin.sh [--check] [JEV_DIR]: write each graph's sha256 into the workflow that runs it.
#
# A workflow pins the graph it was reviewed with: `graphs/<id>.json` must hash to
# the `const PIN` in `workflows/<id>.rn`, or the run refuses. After editing a
# graph, run this (with no argument) and commit both files. With --check it
# changes nothing and exits 1 if any pin is stale. JEV_DIR is the plugin
# directory to work on: this checkout's `jev/` by default, or an installed copy
# (`~/.config/eidolon/plugins/jev`) to check what is installed.
set -euo pipefail
check=0
if [ "${1:-}" = "--check" ]; then check=1; shift; fi
here=$(cd "${1:-$(dirname "$0")/../../jev}" && pwd)
stale=0
for g in "$here"/graphs/*.json; do
  id=$(basename "$g" .json)
  wf="$here/workflows/$id.rn"
  [ -f "$wf" ] || { echo "no workflow for graph $id" >&2; stale=1; continue; }
  want="sha256:$(sha256sum "$g" | cut -d' ' -f1)"
  have=$(sed -n 's/^const PIN = "\(sha256:[0-9a-f]*\)";$/\1/p' "$wf")
  if [ "$have" = "$want" ]; then
    echo "ok     $id $want"
  elif [ $check -eq 1 ]; then
    echo "STALE  $id pinned ${have:-nothing}, graph is $want" >&2
    stale=1
  else
    sed -i "s|^const PIN = \"sha256:[0-9a-f]*\";\$|const PIN = \"$want\";|" "$wf"
    echo "pinned $id $want"
  fi
done
exit $stale
