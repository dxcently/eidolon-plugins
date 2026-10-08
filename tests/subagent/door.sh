#!/usr/bin/env bash
# door.sh: the subagent door (workflows/door.rn) run by real eidolon, under temp HOME and XDG
# dirs, with swarm off and no model: `--provider mock`, and EIDOLON_BIN at fake-eidolon.sh, so each
# eidolon call the tools make is recorded and none is run for real.
#
# list, trace and plan run against the plugin as it is. spawn cannot: its peer roster needs swarm
# on, and the operator keeps swarm off. So spawn runs against a copy of the plugin whose roster
# call (`eidolon::peers()`) is replaced by a fixed parent id. Nothing else in the copy changes,
# and the child is the fake, so the spawn that is tested is the real one up to that line.
#
#   EIDOLON=$(command -v eidolon) bash tests/subagent/door.sh
#   SUBAGENT=/path/to/subagent bash tests/subagent/door.sh    # another checkout's plugin
set -euo pipefail
shopt -s inherit_errexit
here=$(cd "$(dirname "$0")" && pwd)
sub=${SUBAGENT:-$here/../../subagent}
E=${EIDOLON:-$(command -v eidolon || true)}
if [ -z "$E" ] || [ ! -x "$E" ]; then
  echo "door.sh: needs eidolon with the plugin runtime: set EIDOLON to its path" >&2
  exit 2
fi

roots=()
cleanup() {
  rm -rf "${roots[@]}"
}
trap cleanup EXIT
unset EIDOLON_CONFIG EIDOLON_SUBAGENT EIDOLON_BIN

pass=0
bad=0
ok() { pass=$((pass + 1)); echo "ok     $1"; }
no() { bad=$((bad + 1)); echo "BAD    $1" >&2; }

# new_env SUBAGENT_DIR: a fresh temp HOME and XDG dirs, swarm off, the plugin from SUBAGENT_DIR
# installed and trusted, the fake as EIDOLON_BIN, an empty calls log. Sets root, plug and P (a
# parent config, with a top-level max_iterations that a budget copy drops).
new_env() {
  root=$(mktemp -d)
  roots+=("$root")
  export HOME=$root/home XDG_CONFIG_HOME=$root/cfg XDG_STATE_HOME=$root/state \
    XDG_DATA_HOME=$root/data XDG_CACHE_HOME=$root/cache XDG_RUNTIME_DIR=$root/run
  mkdir -p "$HOME" "$XDG_CONFIG_HOME/eidolon/plugins" "$XDG_STATE_HOME" "$XDG_DATA_HOME" \
    "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
  printf '[swarm]\nenabled = false\n' > "$XDG_CONFIG_HOME/eidolon/config.toml"
  plug=$XDG_CONFIG_HOME/eidolon/plugins/subagent
  cp -r "$1" "$plug"
  "$E" plugins trust subagent > /dev/null
  cp "$here/fake-eidolon.sh" "$root/eidolon"
  chmod +x "$root/eidolon"
  export EIDOLON_BIN=$root/eidolon FAKE_EID_LOG=$root/calls.log
  : > "$FAKE_EID_LOG"
  unset EIDOLON_CONFIG
  P=$root/parent.toml
  printf 'model = "parent"\nmax_iterations = 3\n\n[providers.q]\nmax_iterations = 9\n' > "$P"
}

# fixture: one child with a log that names a journal, so list and trace each read the journal.
fixture() {
  J=$root/journal.eid
  : > "$J"
  sa=sa-1700000000-ab12
  mkdir -p "$XDG_STATE_HOME/eidolon/subagents/$sa"
  CHILDLOG=$root/child.log
  printf 'session: %s\n' "$J" > "$CHILDLOG"
  printf 'id=%s\nkind=research\nmodel=fake:cheap\nmodel_from=global pick\nbudget_calls=\nbudget_usd_max=\nbudget_usd_min=\npid=4000000\nlog=%s\nstatus=%s\nstarted=1700000000\ndeadline_min=15\n' \
    "$sa" "$CHILDLOG" "$root/status.json" > "$XDG_STATE_HOME/eidolon/subagents/$sa/meta"
}

# with_cfg VALUE: EIDOLON_CONFIG for the next door call; "<unset>" leaves it out.
with_cfg() {
  if [ "$1" = "<unset>" ]; then
    unset EIDOLON_CONFIG
  else
    export EIDOLON_CONFIG=$1
  fi
}

# door JSON: run the door on JSON, with the calls log emptied first. Sets rc (the door's exit
# code), status and reason (fields of its report line), and calls (what the fake recorded).
door() {
  : > "$FAKE_EID_LOG"
  rc=0
  "$E" workflow run "$plug" door --args "$1" --provider mock > "$root/door.out" 2>&1 || rc=$?
  line=$(grep '^{' "$root/door.out" | tail -n 1 || true)
  status=$(field status)
  reason=$(field reason)
  calls=$(cat "$FAKE_EID_LOG")
}

# field NAME: one string field of the door's JSON line, empty when it is absent.
field() {
  printf '%s' "$line" | python3 -c 'import json, sys; v = json.load(sys.stdin).get(sys.argv[1], ""); sys.stdout.write(v if isinstance(v, str) else json.dumps(v))' "$1"
}

# sentence VALUE WHY: the refusal, as the prelude prints it (no trailing newline).
sentence() {
  printf 'subagent: EIDOLON_CONFIG names %s, which is %s: it must name an absolute path to a readable regular file, so fix it or unset it.' "$1" "$2"
}

# ---------------------------------------------------------------------------------------------
echo "# list, trace and plan through the door (the plugin as it is)"

new_env "$sub"
fixture
list_json='{"tool":"list"}'
trace_json="{\"tool\":\"trace\",\"input\":{\"id\":\"$sa\"}}"
plan_json='{"tool":"plan","input":{"formation":"solo","task":"count the files"}}'

with_cfg '<unset>'; door "$list_json"
if [ "$rc" = 0 ] && [ "$status" = completed ] && [ "$calls" = "$(printf '%s\n%s' '[models] cfg=unset' "[log][--json][$J] cfg=unset")" ]; then
  ok "list, unset: completed, models and the log with no --config"
else
  no "list, unset: rc $rc status $status calls [$calls]"
fi

with_cfg "$P"; door "$list_json"
if [ "$rc" = 0 ] && [ "$status" = completed ] && [ "$calls" = "$(printf '%s\n%s' "[--config][$P][models] cfg=$P" "[--config][$P][log][--json][$J] cfg=$P")" ]; then
  ok "list, set: completed, models and the log both with --config"
else
  no "list, set: rc $rc status $status calls [$calls]"
fi

with_cfg ''; door "$list_json"
if [ "$rc" = 0 ] && [ "$status" = completed ] && [ "$calls" = "$(printf '%s\n%s' '[models] cfg=' "[log][--json][$J] cfg=")" ]; then
  ok "list, empty: the same calls as unset"
else
  no "list, empty: rc $rc status $status calls [$calls]"
fi

with_cfg 'rel.toml'; door "$list_json"
if [ "$rc" = 2 ] && [ "$status" = failed ] && [[ "$reason" == *"$(sentence rel.toml 'a relative path')"* ]] && [ -z "$calls" ]; then
  ok "list, relative: exit 2, failed with the sentence, and no eidolon call"
else
  no "list, relative: rc $rc status $status reason [$reason] calls [$calls]"
fi

with_cfg "$P"; door "$trace_json"
if [ "$rc" = 0 ] && [ "$status" = completed ] && [ "$calls" = "$(printf '%s\n%s' "[--config][$P][models] cfg=$P" "[--config][$P][log][--json][$J] cfg=$P")" ]; then
  ok "trace, set: completed, models and the log both with --config"
else
  no "trace, set: rc $rc status $status calls [$calls]"
fi

with_cfg '<unset>'; door "$trace_json"
if [ "$rc" = 0 ] && [ "$status" = completed ] && [ "$calls" = "$(printf '%s\n%s' '[models] cfg=unset' "[log][--json][$J] cfg=unset")" ]; then
  ok "trace, unset: completed, models and the log with no --config"
else
  no "trace, unset: rc $rc status $status calls [$calls]"
fi

with_cfg 'rel.toml'; door "$trace_json"
if [ "$rc" = 2 ] && [ "$status" = failed ] && [[ "$reason" == *"$(sentence rel.toml 'a relative path')"* ]] && [ -z "$calls" ]; then
  ok "trace, relative: exit 2, failed with the sentence, and no eidolon call"
else
  no "trace, relative: rc $rc status $status reason [$reason] calls [$calls]"
fi

with_cfg "$P"; door "$plan_json"
if [ "$rc" = 0 ] && [ "$status" = completed ] && [ "$calls" = "[--config][$P][models] cfg=$P" ]; then
  ok "plan, set: completed, the catalog with --config"
else
  no "plan, set: rc $rc status $status calls [$calls]"
fi

with_cfg '<unset>'; door "$plan_json"
if [ "$rc" = 0 ] && [ "$status" = completed ] && [ "$calls" = "[models] cfg=unset" ]; then
  ok "plan, unset: completed, the catalog with no --config"
else
  no "plan, unset: rc $rc status $status calls [$calls]"
fi

# ---------------------------------------------------------------------------------------------
echo "# pick, through the door: a bad EIDOLON_CONFIG refuses before anything is written"

# pick_is KIND MODEL: the global picks file holds KIND -> MODEL.
pick_is() {
  python3 -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1])).get(sys.argv[2]) == sys.argv[3] else 1)' "$picks" "$1" "$2" 2>/dev/null
}

new_env "$sub"
picks=$XDG_STATE_HOME/eidolon/subagents/picks.json
pick_save='{"tool":"pick","input":{"kind":"research","model":"fake:cheap"}}'
pick_clear='{"tool":"pick","input":{"kind":"research","clear":true}}'

with_cfg '<unset>'; door "$pick_save"
if [ "$rc" = 0 ] && [ "$status" = completed ] && pick_is research fake:cheap && [ "$calls" = "[models] cfg=unset" ]; then
  ok "pick, unset: saved, and the catalog with no --config"
else
  no "pick, unset: rc $rc status $status calls [$calls]"
fi

with_cfg "$P"; door '{"tool":"pick","input":{"kind":"review","model":"fake:dear"}}'
if [ "$rc" = 0 ] && [ "$status" = completed ] && pick_is review fake:dear && [ "$calls" = "[--config][$P][models] cfg=$P" ]; then
  ok "pick, set: saved, and the catalog with --config"
else
  no "pick, set: rc $rc status $status calls [$calls]"
fi

before=$(cat "$picks")
with_cfg 'rel.toml'; door '{"tool":"pick","input":{"kind":"research","model":"fake:dear"}}'
if [ "$rc" = 2 ] && [ "$status" = failed ] && [[ "$reason" == *"$(sentence rel.toml 'a relative path')"* ]] \
  && [ -z "$calls" ] && [ "$(cat "$picks")" = "$before" ] && pick_is research fake:cheap; then
  ok "pick, relative: exit 2, failed with the sentence, no eidolon call, and the picks file unchanged"
else
  no "pick, relative: rc $rc status $status reason [$reason] calls [$calls]"
fi

with_cfg 'rel.toml'; door "$pick_clear"
if [ "$rc" = 2 ] && [ "$status" = failed ] && [[ "$reason" == *"$(sentence rel.toml 'a relative path')"* ]] \
  && [ "$(cat "$picks")" = "$before" ]; then
  ok "pick, clear, relative: refused, and the picks file still holds the pick"
else
  no "pick, clear, relative: rc $rc status $status reason [$reason]"
fi

new_env "$sub"
picks=$XDG_STATE_HOME/eidolon/subagents/picks.json
with_cfg 'rel.toml'; door "$pick_save"
if [ "$rc" = 2 ] && [ "$status" = failed ] && [[ "$reason" == *"$(sentence rel.toml 'a relative path')"* ]] \
  && [ -z "$calls" ] && [ ! -e "$picks" ]; then
  ok "pick, relative, no picks file yet: refused, and no picks file is written"
else
  no "pick, relative, no picks file yet: rc $rc status $status reason [$reason] calls [$calls]"
fi

# ---------------------------------------------------------------------------------------------
echo "# plan's confirm text, once a default pick exists"

new_env "$sub"
with_cfg '<unset>'; door '{"tool":"pick","input":{"kind":"default","model":"fake:cheap"}}'
door '{"tool":"plan","input":{"formation":"solo","task":"t"}}'
confirm=$(field report | python3 -c 'import json, sys; sys.stdout.write(json.loads(sys.stdin.read()).get("confirm", ""))' 2>/dev/null || true)
if [ "$rc" = 0 ] && [[ "$confirm" == *'put --config "$EIDOLON_CONFIG" before workflow'* ]]; then
  ok "plan, confirm: the fan-out run is told to pass --config when EIDOLON_CONFIG is set"
else
  no "plan, confirm: rc $rc, confirm [$confirm]"
fi

echo "# spawn, with the roster stubbed in a copy"

stubroot=$(mktemp -d)
roots+=("$stubroot")
cp -r "$sub" "$stubroot/subagent"
sed -i 's/let roster = eidolon::peers().await?;/let roster = "You are `sa-parent-test`.";/' \
  "$stubroot/subagent/tools/spawn.rn"
if ! grep -q 'sa-parent-test' "$stubroot/subagent/tools/spawn.rn"; then
  echo "door.sh: could not stub the roster call in spawn.rn" >&2
  exit 2
fi

# spawn_in BUDGET: the door's input for one spawn; a non-empty BUDGET adds calls: 5.
spawn_in() {
  if [ -n "$1" ]; then
    printf '%s' '{"tool":"spawn","input":{"task":"say hi","kind":"research","model":"fake:cheap","budget":{"calls":5}}}'
  else
    printf '%s' '{"tool":"spawn","input":{"task":"say hi","kind":"research","model":"fake:cheap"}}'
  fi
}

# spawned: wait for the child to log its call, then set head (the child's first argv prefix),
# cfg (the EIDOLON_CONFIG it ran under) and meta (the config= the state directory records).
spawned() {
  local i
  for i in $(seq 1 100); do
    if grep -q '\] cfg=' "$FAKE_EID_LOG" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  head=$(head -n 1 "$FAKE_EID_LOG")
  cfg=$(tail -n 1 "$FAKE_EID_LOG" | sed 's/.*\] cfg=//')
  meta=$(sed -n 's/^config=//p' "$XDG_STATE_HOME"/eidolon/subagents/sa-*/meta 2>/dev/null || true)
  copy=$(ls -d "$XDG_STATE_HOME"/eidolon/subagents/sa-*/config.toml 2>/dev/null | head -n 1 || true)
}

new_env "$stubroot/subagent"
with_cfg '<unset>'; door "$(spawn_in '')"; spawned
if [ "$rc" = 0 ] && [ "$status" = completed ] && [[ "$head" == "[run][--model][fake:cheap][You are subagent "* ]] \
  && [ "$cfg" = unset ] && [ -z "$meta" ]; then
  ok "spawn, unset, no budget: no --config, the child's EIDOLON_CONFIG unset, meta config empty"
else
  no "spawn, unset, no budget: rc $rc status $status head [$head] cfg [$cfg] meta [$meta]"
fi

new_env "$stubroot/subagent"
with_cfg "$P"; door "$(spawn_in '')"; spawned
if [ "$rc" = 0 ] && [ "$status" = completed ] && [[ "$head" == "[run][--config][$P][--model][fake:cheap][You are subagent "* ]] \
  && [ "$cfg" = "$P" ] && [ "$meta" = "$P" ]; then
  ok "spawn, set, no budget: --config and EIDOLON_CONFIG are the parent's file, meta config too"
else
  no "spawn, set, no budget: rc $rc status $status head [$head] cfg [$cfg] meta [$meta]"
fi

new_env "$stubroot/subagent"
with_cfg "$P"; door "$(spawn_in 1)"; spawned
want_copy=$(printf 'max_iterations = 5\nmodel = "parent"\n\n[providers.q]\nmax_iterations = 9\n')
if [ "$rc" = 0 ] && [ "$status" = completed ] && [ -n "$copy" ] \
  && [[ "$head" == "[run][--config][$copy][--model][fake:cheap][You are subagent "* ]] \
  && [ "$cfg" = "$copy" ] && [ "$meta" = "$copy" ] && [ "$(cat "$copy")" = "$want_copy" ]; then
  ok "spawn, set, budget: the child runs under the copy of the parent's file, minus its top-level max_iterations"
else
  no "spawn, set, budget: rc $rc status $status head [$head] cfg [$cfg] meta [$meta] copy [$(cat "$copy" 2>/dev/null)]"
fi

new_env "$stubroot/subagent"
with_cfg '<unset>'; door "$(spawn_in 1)"; spawned
want_xdg=$(printf 'max_iterations = 5\n[swarm]\nenabled = false\n')
if [ "$rc" = 0 ] && [ "$status" = completed ] && [ -n "$copy" ] \
  && [[ "$head" == "[run][--config][$copy][--model][fake:cheap][You are subagent "* ]] \
  && [ "$cfg" = "$copy" ] && [ "$meta" = "$copy" ] && [ "$(cat "$copy")" = "$want_xdg" ]; then
  ok "spawn, unset, budget: the copy of the default config, and the child runs under it"
else
  no "spawn, unset, budget: rc $rc status $status head [$head] cfg [$cfg] meta [$meta]"
fi

new_env "$stubroot/subagent"
with_cfg 'rel.toml'; door "$(spawn_in 1)"
if [ "$rc" = 2 ] && [ "$status" = failed ] && [[ "$reason" == *"$(sentence rel.toml 'a relative path')"* ]] \
  && [ -z "$calls" ] && [ ! -e "$XDG_STATE_HOME/eidolon/subagents" ]; then
  ok "spawn, relative: exit 2, failed with the sentence, nothing started and nothing written"
else
  no "spawn, relative: rc $rc status $status reason [$reason] calls [$calls]"
fi

new_env "$stubroot/subagent"
with_cfg "$root"; door "$(spawn_in '')"
if [ "$rc" = 2 ] && [ "$status" = failed ] && [[ "$reason" == *"$(sentence "$root" 'a directory')"* ]] \
  && [ -z "$calls" ] && [ ! -e "$XDG_STATE_HOME/eidolon/subagents" ]; then
  ok "spawn, a directory: exit 2, failed with the sentence, nothing started and nothing written"
else
  no "spawn, a directory: rc $rc status $status reason [$reason] calls [$calls]"
fi

echo
echo "door.sh: $pass ok, $bad bad"
[ "$bad" = 0 ]
