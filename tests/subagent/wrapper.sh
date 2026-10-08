#!/bin/sh
# wrapper.sh: subagent/bin/subagent-door and EIDOLON_CONFIG. The wrapper execs the door session; with
# EIDOLON_CONFIG set it must pass `--config <it>` before `workflow`, refuse a bad value with exit 2 before
# anything runs, and change nothing when the variable is unset or empty. eidolon is the fake
# (tests/subagent/fake-eidolon.sh): it records argv and nothing runs. Every case gets a fresh temp HOME with
# all five XDG_* dirs inside it, so the operator's ~/.config/eidolon is never read.
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
door=$repo/subagent/bin/subagent-door
fake=$here/fake-eidolon.sh
ok=0 bad=0

check() {  # check <name> <condition result 0|1> <detail>
  if [ "$2" -eq 0 ]; then ok=$((ok + 1)); echo "ok   $1"; else bad=$((bad + 1)); echo "BAD  $1: $3"; fi
}

fresh() {  # a temp HOME with the plugin dir the wrapper looks for; prints its path
  t=$(mktemp -d "${TMPDIR:-/tmp}/subagent-wrapper.XXXXXX")
  mkdir -p "$t/config/eidolon/plugins/subagent" "$t/state" "$t/data" "$t/cache" "$t/run"
  : > "$t/config/eidolon/plugins/subagent/plugin.rn"
  chmod 700 "$t/run"
  printf '%s' "$t"
}

run() {  # run <home> <EIDOLON_CONFIG value or -unset->; stdout is the fake's log, the exit code is the wrapper's
  t=$1
  if [ "$2" = "-unset-" ]; then
    env -i PATH=/usr/bin:/bin HOME="$t" XDG_CONFIG_HOME="$t/config" XDG_STATE_HOME="$t/state" XDG_DATA_HOME="$t/data" \
      XDG_CACHE_HOME="$t/cache" XDG_RUNTIME_DIR="$t/run" EIDOLON_BIN="$fake" FAKE_EID_LOG="$t/log" \
      sh "$door" '{"tool":"schema"}' >/dev/null 2>"$t/err"
  else
    env -i PATH=/usr/bin:/bin HOME="$t" XDG_CONFIG_HOME="$t/config" XDG_STATE_HOME="$t/state" XDG_DATA_HOME="$t/data" \
      XDG_CACHE_HOME="$t/cache" XDG_RUNTIME_DIR="$t/run" EIDOLON_BIN="$fake" FAKE_EID_LOG="$t/log" EIDOLON_CONFIG="$2" \
      sh "$door" '{"tool":"schema"}' >/dev/null 2>"$t/err"
  fi
}

# Unset and empty: today's argv, no --config.
for v in -unset- ""; do
  t=$(fresh); run "$t" "$v"; rc=$?
  line=$(cat "$t/log" 2>/dev/null)
  case $line in "[workflow][run][$t/config/eidolon/plugins/subagent][door][--args]"*) r=0 ;; *) r=1 ;; esac
  check "EIDOLON_CONFIG '${v}': no --config (rc $rc)" "$r" "$line"
  rm -rf "$t"
done

# Set to an absolute regular file: --config <it> comes first, and the session sees the same value.
t=$(fresh); printf 'model = "mock"\n' > "$t/parent.toml"; run "$t" "$t/parent.toml"; rc=$?
line=$(cat "$t/log" 2>/dev/null)
case $line in "[--config][$t/parent.toml][workflow][run]"*"cfg=$t/parent.toml") r=0 ;; *) r=1 ;; esac
check "an absolute file: --config before workflow (rc $rc)" "$r" "$line"
rm -rf "$t"

# Each bad value: exit 2, the sentence on stderr, and eidolon never ran.
for kind in relative directory missing dangling; do
  t=$(fresh)
  case $kind in
    relative) v=parent.toml; : > "$t/parent.toml" ;;
    directory) v=$t/adir; mkdir "$v" ;;
    missing) v=$t/nope.toml ;;
    dangling) v=$t/link.toml; ln -s "$t/gone.toml" "$v" ;;
  esac
  run "$t" "$v"; rc=$?
  r=1
  if [ "$rc" -eq 2 ] && [ ! -e "$t/log" ] && grep -q 'subagent-door: EIDOLON_CONFIG names' "$t/err"; then r=0; fi
  check "a $kind value is refused before eidolon runs (rc $rc)" "$r" "$(cat "$t/err" "$t/log" 2>/dev/null)"
  rm -rf "$t"
done

echo "wrapper.sh: $ok ok, $bad bad"
[ "$bad" -eq 0 ]
