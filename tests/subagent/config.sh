#!/usr/bin/env bash
# config.sh: EIDOLON_CONFIG in the subagent plugin, with no eidolon, no model and no network.
# Each shell here is read out of its tool's .rn file by rn.py, so the test runs the text that
# ships: the prelude every eidolon call goes through (CFG_SH), the budget copy (PREP_SH), the
# child (CHILD_SH, its {placeholders} filled the way spawn.rn fills them), and the eidolon calls
# of list, trace, pick, plan and spawn, which run against fake-eidolon.sh (it records each call).
# Every case runs under a temp HOME and temp XDG_* directories.
#
#   bash tests/subagent/config.sh
#   SUBAGENT=/path/to/subagent bash tests/subagent/config.sh    # another checkout's plugin
#
# spawn.rn's own Rune (its flags, its meta line) is not run here: a real spawn needs swarm on,
# and the operator keeps it off. door.sh runs list, trace and plan through real eidolon.
set -euo pipefail
shopt -s inherit_errexit
here=$(cd "$(dirname "$0")" && pwd)
sub=${SUBAGENT:-$here/../../subagent}
rn=$here/rn.py

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
unset EIDOLON_CONFIG EIDOLON_SUBAGENT
export HOME=$root/home XDG_CONFIG_HOME=$root/cfg XDG_STATE_HOME=$root/state \
  XDG_DATA_HOME=$root/data XDG_CACHE_HOME=$root/cache XDG_RUNTIME_DIR=$root/run
mkdir -p "$HOME" "$XDG_CONFIG_HOME/eidolon" "$XDG_STATE_HOME" "$XDG_DATA_HOME" \
  "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR"
fake=$root/eidolon
cp "$here/fake-eidolon.sh" "$fake"
chmod +x "$fake"
export EIDOLON_BIN=$fake FAKE_EID_LOG=$root/calls.log

pass=0
bad=0
ok() { pass=$((pass + 1)); echo "ok     $1"; }
no() { bad=$((bad + 1)); echo "BAD    $1" >&2; }

# rnc TOOL CONST: one string constant of one tool file, as Rune holds it.
rnc() { python3 "$rn" "$sub/tools/$1.rn" "$2"; }

# shfile NAME TOOL CONST...: those constants of TOOL, in order, as one shell script in $root/NAME.
shfile() {
  local name=$1 tool=$2
  shift 2
  : > "$root/$name"
  local c
  for c in "$@"; do
    rnc "$tool" "$c" >> "$root/$name"
  done
  printf '%s\n' "$root/$name"
}

# attempt FILE ARGS...: run the script as sh -c does (after $0 "sa"), with the environment as
# it is now. Sets rc, out (stdout) and err (stderr).
attempt() {
  local f=$1
  shift
  rc=0
  out=$(sh -c "$(cat "$f")" sa "$@" 2>"$root/err") || rc=$?
  err=$(cat "$root/err")
}

# with_cfg VALUE: EIDOLON_CONFIG for the next run; "<unset>" leaves it out.
with_cfg() {
  if [ "$1" = "<unset>" ]; then
    unset EIDOLON_CONFIG
  else
    export EIDOLON_CONFIG=$1
  fi
}

# expect LABEL RC OUT ERR: the last attempt's status, stdout and stderr, all three exact.
expect() {
  if [ "$rc" = "$2" ] && [ "$out" = "$3" ] && [ "$err" = "$4" ]; then
    ok "$1"
  else
    no "$1: rc $rc (want $2), out [$out] (want [$3]), err [$err] (want [$4])"
  fi
}

# sentence VALUE WHY: the refusal, as the prelude prints it (no trailing newline).
sentence() {
  printf 'subagent: EIDOLON_CONFIG names %s, which is %s: it must name an absolute path to a readable regular file, so fix it or unset it.' "$1" "$2"
}

# ---------------------------------------------------------------------------------------------
# The fixtures: one parent config, a journal and a child with a log and a meta file.

P=$root/parent.toml
printf 'model = "parent"\nmax_iterations = 3\n\n[providers.q]\nmax_iterations = 9\n' > "$P"
spdir="$root/with space"
mkdir -p "$spdir"
P2=$spdir/parent.toml
cp "$P" "$P2"

J=$root/journal.eid
: > "$J"
sa=sa-1700000000-ab12
state=$XDG_STATE_HOME/eidolon/subagents/$sa
mkdir -p "$state"
CHILDLOG=$root/child.log
printf 'session: %s\n' "$J" > "$CHILDLOG"
printf 'id=%s\nkind=research\nmodel=fake:cheap\nmodel_from=global pick\nbudget_calls=\nbudget_usd_max=\nbudget_usd_min=\npid=4000000\nlog=%s\nstatus=%s\nstarted=1700000000\ndeadline_min=15\n' \
  "$sa" "$CHILDLOG" "$root/status.json" > "$state/meta"

# ---------------------------------------------------------------------------------------------
echo "# the prelude"

for t in list trace pick plan; do
  if [ "$(rnc "$t" CFG_SH)" = "$(rnc spawn CFG_SH)" ]; then
    ok "CFG_SH in $t.rn is the text in spawn.rn"
  else
    no "CFG_SH in $t.rn differs from spawn.rn"
  fi
done

probe=$(shfile probe spawn EID_SH CFG_SH)
printf '%s\n' 'printf "cfg=%s" "$cfg"' >> "$probe"

with_cfg '<unset>'; attempt "$probe"
expect "unset: no refusal, and the answer is cfg= with nothing after it" 0 "cfg=" ""

with_cfg ''; attempt "$probe"
expect "empty: the same as unset" 0 "cfg=" ""

with_cfg "$P"; attempt "$probe"
expect "an absolute regular file is accepted, and passed on as it is" 0 "cfg=$P" ""

with_cfg "$P2"; attempt "$probe"
expect "an absolute path with a space is accepted" 0 "cfg=$P2" ""

ln -s "$P" "$root/link.toml"
with_cfg "$root/link.toml"; attempt "$probe"
expect "a symlink to a regular file is accepted (links followed)" 0 "cfg=$root/link.toml" ""

with_cfg 'rel.toml'; attempt "$probe"
expect "a relative path is refused with the sentence" 2 "" "$(sentence rel.toml 'a relative path')"

with_cfg "$root"; attempt "$probe"
expect "a directory is refused with the sentence" 2 "" "$(sentence "$root" 'a directory')"

with_cfg "$root/missing.toml"; attempt "$probe"
expect "a missing file is refused with the sentence" 2 "" "$(sentence "$root/missing.toml" missing)"

ln -s "$root/gone.toml" "$root/dangling.toml"
with_cfg "$root/dangling.toml"; attempt "$probe"
expect "a dangling link is refused with the sentence" 2 "" "$(sentence "$root/dangling.toml" 'a dangling link')"

mkfifo "$root/pipe.toml"
with_cfg "$root/pipe.toml"; attempt "$probe"
expect "a file that is not a regular file is refused with the sentence" 2 "" \
  "$(sentence "$root/pipe.toml" 'not a regular file')"

cp "$P" "$root/unreadable.toml"
chmod 000 "$root/unreadable.toml"
if [ "$(id -u)" = 0 ]; then
  echo "skip   unreadable: root reads any file"
else
  with_cfg "$root/unreadable.toml"; attempt "$probe"
  expect "an unreadable file is refused with the sentence" 2 "" \
    "$(sentence "$root/unreadable.toml" unreadable)"
fi
chmod 644 "$root/unreadable.toml"

# ---------------------------------------------------------------------------------------------
echo "# the eidolon calls: argv and the EIDOLON_CONFIG each call saw"

# expect_calls LABEL WANT: the calls the fake recorded, exactly, after the last attempt.
expect_calls() {
  local got
  got=$(cat "$FAKE_EID_LOG" 2>/dev/null || true)
  if [ "$got" = "$2" ]; then ok "$1"; else no "$1: calls [$got] (want [$2])"; fi
}

catalog_spawn=$(shfile cat_spawn spawn EID_SH CFG_SH CATALOG_SH)
catalog_pick=$(shfile cat_pick pick EID_SH CFG_SH CATALOG_SH)
catalog_plan=$(shfile cat_plan plan EID_SH CFG_SH CATALOG_SH)
list_sh=$(shfile list_sh list EID_SH CFG_SH LIST_SH)
trace_sh=$(shfile trace_sh trace EID_SH CFG_SH TRACE_SH)

for pair in "spawn:$catalog_spawn" "pick:$catalog_pick" "plan:$catalog_plan"; do
  name=${pair%%:*}
  f=${pair#*:}
  : > "$FAKE_EID_LOG"; with_cfg '<unset>'; attempt "$f"
  expect_calls "$name catalog, unset: models with no --config" "[models] cfg=unset"
  : > "$FAKE_EID_LOG"; with_cfg "$P"; attempt "$f"
  expect_calls "$name catalog, set: models with --config" "[--config][$P][models] cfg=$P"
done

: > "$FAKE_EID_LOG"; with_cfg '<unset>'; attempt "$list_sh" "" 0
expect_calls "list, unset: models and the journal's log, no --config" \
  "$(printf '%s\n%s' '[models] cfg=unset' "[log][--json][$J] cfg=unset")"
: > "$FAKE_EID_LOG"; with_cfg "$P"; attempt "$list_sh" "" 0
expect_calls "list, set: models and the journal's log, both with --config" \
  "$(printf '%s\n%s' "[--config][$P][models] cfg=$P" "[--config][$P][log][--json][$J] cfg=$P")"
: > "$FAKE_EID_LOG"; with_cfg ''; attempt "$list_sh" "" 0
expect_calls "list, empty: the same calls as unset" \
  "$(printf '%s\n%s' '[models] cfg=' "[log][--json][$J] cfg=")"

: > "$FAKE_EID_LOG"; with_cfg '<unset>'; attempt "$trace_sh" "$sa" 40
expect_calls "trace, unset: models and the log, no --config" \
  "$(printf '%s\n%s' '[models] cfg=unset' "[log][--json][$J] cfg=unset")"
: > "$FAKE_EID_LOG"; with_cfg "$P"; attempt "$trace_sh" "$sa" 40
expect_calls "trace, set: models and the log, both with --config" \
  "$(printf '%s\n%s' "[--config][$P][models] cfg=$P" "[--config][$P][log][--json][$J] cfg=$P")"

: > "$FAKE_EID_LOG"; with_cfg 'rel.toml'; attempt "$list_sh" "" 0
expect "list, relative: refused before any eidolon call" 2 "" "$(sentence rel.toml 'a relative path')"
expect_calls "list, relative: no eidolon call was made" ""
: > "$FAKE_EID_LOG"; with_cfg 'rel.toml'; attempt "$trace_sh" "$sa" 40
expect "trace, relative: refused with the sentence" 2 "" "$(sentence rel.toml 'a relative path')"
expect_calls "trace, relative: no eidolon call was made" ""
: > "$FAKE_EID_LOG"; with_cfg 'rel.toml'; attempt "$catalog_pick"
expect "pick catalog, relative: refused with the sentence" 2 "" "$(sentence rel.toml 'a relative path')"
expect_calls "pick catalog, relative: no eidolon call was made" ""

# ---------------------------------------------------------------------------------------------
echo "# the budget copy (PREP_SH)"

X=$XDG_CONFIG_HOME/eidolon/config.toml
printf 'max_iterations = 99\nmodel = "xdg"\n\n[providers.p]\nmax_iterations = 5\n' > "$X"
prepf=$(shfile prep spawn CFG_SH PREP_SH)
sid=sa-1700000001-cd34
sdirs=$XDG_STATE_HOME/eidolon/subagents
pdir=$sdirs/$sid

want_xdg=$root/want_xdg.toml
printf 'max_iterations = 7\nmodel = "xdg"\n\n[providers.p]\nmax_iterations = 5\n' > "$want_xdg"
want_parent=$root/want_parent.toml
printf 'max_iterations = 7\nmodel = "parent"\n\n[providers.q]\nmax_iterations = 9\n' > "$want_parent"

# copy_case LABEL CFG CALLS WANT: a fresh state root, one PREP run, then the copy against WANT.
copy_case() {
  rm -rf "$sdirs"
  with_cfg "$2"; attempt "$prepf" "$sid" "$3"
  if [ "$rc" = 0 ] && [ "$out" = "$pdir" ] && cmp -s "$pdir/config.toml" "$4"; then
    ok "$1"
  else
    no "$1: rc $rc, out [$out], copy differs from $4 or is missing"
  fi
}

copy_case "budget, unset: the copy is max_iterations, then the XDG config without its top-level one" \
  '<unset>' 7 "$want_xdg"
copy_case "budget, set: the copy is max_iterations, then the parent's file without its top-level one" \
  "$P" 7 "$want_parent"
copy_case "budget, set, a path with a space: the same copy" "$P2" 7 "$want_parent"
copy_case "budget, empty: the same copy as unset" '' 7 "$want_xdg"

rm -rf "$sdirs"
with_cfg "$P"; attempt "$prepf" "$sid" ""
if [ "$rc" = 0 ] && [ "$out" = "$pdir" ] && [ ! -e "$pdir/config.toml" ]; then
  ok "no budget, set: no config.toml is written"
else
  no "no budget, set: rc $rc, out [$out], or a config.toml was written"
fi

rm -rf "$sdirs"
with_cfg 'rel.toml'; attempt "$prepf" "$sid" 7
expect "budget, relative: refused with the sentence" 2 "" "$(sentence rel.toml 'a relative path')"
if [ ! -e "$sdirs/$sid" ]; then
  ok "budget, relative: nothing written, not even the state directory"
else
  no "budget, relative: the state directory was made"
fi

rm -rf "$sdirs"
cp "$P" "$root/unreadable2.toml"
chmod 000 "$root/unreadable2.toml"
if [ "$(id -u)" = 0 ]; then
  echo "skip   budget, unreadable: root reads any file"
else
  with_cfg "$root/unreadable2.toml"; attempt "$prepf" "$sid" 7
  expect "budget, unreadable: refused with the sentence" 2 "" \
    "$(sentence "$root/unreadable2.toml" unreadable)"
  if [ ! -e "$sdirs/$sid" ]; then
    ok "budget, unreadable: nothing written"
  else
    no "budget, unreadable: the state directory was made"
  fi
fi
chmod 644 "$root/unreadable2.toml"

# ---------------------------------------------------------------------------------------------
echo "# the child (CHILD_SH, placeholders filled as spawn.rn fills them)"

child_tpl=$root/child_tpl.sh
rnc spawn CHILD_SH > "$child_tpl"

# child_run CFGENV FLAGS: fill CHILD_SH and run it under setsid, so its process group is its own
# (the script's `kill -TERM 0` at a deadline must reach only the child). The fake is the binary.
child_run() {
  local text eidq
  text=$(cat "$child_tpl")
  eidq=$(printf "'%s'" "$fake")
  text=${text//'{seconds}'/600}
  text=${text//'{eid}'/$eidq}
  text=${text//'{cfgenv}'/$1}
  text=${text//'{flags}'/$2}
  text=${text//'{brief}'/"'the brief'"}
  printf '%s\n' "$text" > "$root/child_run.sh"
  : > "$FAKE_EID_LOG"
  setsid -w sh "$root/child_run.sh" > "$root/child.out" 2>&1 || true
}

with_cfg '<unset>'
child_run 'unset EIDOLON_CONFIG' "--model 'fake:cheap' "
expect_calls "child, no config, parent unset: no --config, EIDOLON_CONFIG unset" \
  "[run][--model][fake:cheap][the brief] cfg=unset"

with_cfg "$P"
child_run 'unset EIDOLON_CONFIG' "--model 'fake:cheap' "
expect_calls "child, no config, parent set: the child gets none, and EIDOLON_CONFIG is unset" \
  "[run][--model][fake:cheap][the brief] cfg=unset"

with_cfg "$P"
child_run "export EIDOLON_CONFIG='$P'" "--config '$P' --model 'fake:cheap' "
expect_calls "child, parent's file, no budget: --config and EIDOLON_CONFIG are the parent's file" \
  "[run][--config][$P][--model][fake:cheap][the brief] cfg=$P"

with_cfg "$P"
child_run "export EIDOLON_CONFIG='$pdir/config.toml'" "--config '$pdir/config.toml' --model 'fake:cheap' "
expect_calls "child, budget copy: --config and EIDOLON_CONFIG are the copy" \
  "[run][--config][$pdir/config.toml][--model][fake:cheap][the brief] cfg=$pdir/config.toml"

with_cfg '<unset>'
child_run "export EIDOLON_CONFIG='$pdir/config.toml'" "--config '$pdir/config.toml' --model 'fake:cheap' "
expect_calls "child, budget copy, parent unset: the copy is what the child runs under" \
  "[run][--config][$pdir/config.toml][--model][fake:cheap][the brief] cfg=$pdir/config.toml"

echo
echo "config.sh: $pass ok, $bad bad"
[ "$bad" = 0 ]
