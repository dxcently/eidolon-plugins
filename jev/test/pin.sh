#!/usr/bin/env bash
# pin.sh [--check]: write each graph's sha256 into the workflow that runs it.
#
# A workflow pins the graph it was reviewed with: `graphs/<id>.json` must hash to
# the `const PIN` in `workflows/<id>.rn`, or the run refuses. After editing a
# graph, run this (with no argument) and commit both files. With --check it
# changes nothing and exits 1 if any pin is stale.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
check=0
[ "${1:-}" = "--check" ] && check=1
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
