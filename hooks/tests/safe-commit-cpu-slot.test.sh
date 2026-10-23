#!/usr/bin/env bash
#
# Regression test for #492 — hooks/safe-commit.sh runs the commit-time suite
# (lint + typecheck + test) inside ONE turn of the machine-wide CPU slot
# (scripts/atelier-cpu-slot acquire/release --owner <hook pid>):
#   - the slot is held while the steps run and released on green, red and
#     TERM;
#   - machine load never blocks: load 50 on 4 cores with a free slot runs the
#     gate (#524);
#   - a busy slot (live unrelated holder) blocks with exit 2, a BLOCKED
#     message and a `cpu-slot-busy` log entry once safeCommit.slotMaxWait
#     elapses;
#   - N/A paths (skip env, non-commit, docs-only, no package.json, no
#     lint/typecheck/test script) never touch the slot;
#   - a missing helper logs `cpu-slot-na` and the gate still runs;
#   - a project script that wraps itself in the helper does not deadlock
#     (CPU_SLOT_HELD is exported into the steps);
#   - ANCESTOR-HOLDER: when the slot is already held by an ancestor of the
#     hook (the whole commit wrapped in cpu-slot) the hook logs
#     `cpu-slot-nested`, does not wait, and leaves the outer lock in place;
#   - slotMaxWait is clamped (default 240, > 400 -> 400, 0/garbage -> 240);
#   - the #277 bypass refusals are unchanged.
#
# Hermetic: throwaway git repos under a temp dir, a shimmed `pnpm` on PATH,
# and a temp CPU_SLOT_DIR (never /tmp/cpu-slot.lock). Every wait on the hook
# is bounded so a regression fails instead of hanging; background processes
# the test starts are killed on exit. Portable to GNU/Linux and macOS/BSD.
#
# Run:  hooks/tests/safe-commit-cpu-slot.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

# shellcheck disable=SC2015,SC2016,SC2329 # `A && pass || fail` idiom; literal $ in fixture scripts; trap-invoked cleanup
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/safe-commit.sh"
REAL_HELPER="$REPO_ROOT/scripts/atelier-cpu-slot"

TMP="$(mktemp -d)"
BG_PIDS=""
cleanup() {
  local p
  for p in $BG_PIDS; do
    pkill -P "$p" 2>/dev/null
    kill "$p" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# A slot lent by the surrounding session (full-suite run under cpu-slot) must
# not leak into the cases below.
unset CPU_SLOT_HELD CPU_SLOT_LABEL

# --- shims and plugin roots -------------------------------------------------
SHIM_BIN="$TMP/bin"
mkdir -p "$SHIM_BIN"
cat > "$SHIM_BIN/pnpm" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "run" ]; then
  script="$(jq -r --arg s "$2" '.scripts[$s] // empty' package.json 2>/dev/null)"
  [ -z "$script" ] && { echo "no script: $2" >&2; exit 1; }
  exec sh -c "$script"
fi
exit 0
SHIM
chmod +x "$SHIM_BIN/pnpm"
export PATH="$SHIM_BIN:$PATH"

CPU_SLOT_DIR="$TMP/cpu-slot"; mkdir -p "$CPU_SLOT_DIR"; export CPU_SLOT_DIR
# Load never gates a slot (#524); fake it anyway so the message is deterministic.
# Per-call env (group 4 sets CPU_SLOT_FAKE_LOAD=7.5) overrides this export.
export CPU_SLOT_FAKE_LOAD=0
LOCK="$CPU_SLOT_DIR/cpu-slot.lock"

# Plugin roots the hook is pointed at. The hook only needs hooks/lib (log
# helper) and scripts/atelier-cpu-slot from CLAUDE_PLUGIN_ROOT.
#   ROOT_SHIM    — helper is a recorder: logs its args to $SHIM_CALLS, exit 0
#   ROOT_NOHELP  — no helper at all
SHIM_CALLS="$TMP/shim.calls"
ROOT_SHIM="$TMP/root-shim"; mkdir -p "$ROOT_SHIM/hooks" "$ROOT_SHIM/scripts"
ln -s "$REPO_ROOT/hooks/lib" "$ROOT_SHIM/hooks/lib"
cat > "$ROOT_SHIM/scripts/atelier-cpu-slot" <<SHIM
#!/usr/bin/env bash
echo "\$*" >> "$SHIM_CALLS"
exit 0
SHIM
chmod +x "$ROOT_SHIM/scripts/atelier-cpu-slot"
ROOT_NOHELP="$TMP/root-nohelp"; mkdir -p "$ROOT_NOHELP/hooks"
ln -s "$REPO_ROOT/hooks/lib" "$ROOT_NOHELP/hooks/lib"

# --- helpers ----------------------------------------------------------------
LOG_ROOT="$TMP/logs"
LOG_FILE="$LOG_ROOT/.task-log/hook-decisions.jsonl"
OUT="$TMP/hook.out"
ERR="$TMP/hook.err"
PAYLOAD="$TMP/payload.json"

HOOK_PID=""
RC=""

# start_hook <cwd> <command> [VAR=val ...] — run the hook in the background,
# exec'd so $! IS the hook pid (what the slot records as owner).
# PLUGIN_ROOT (default: the real repo) selects CLAUDE_PLUGIN_ROOT.
start_hook() {
  local pwd_dir="$1" command_str="$2"
  shift 2
  rm -rf "$LOG_ROOT"; rm -f "$OUT" "$ERR" "$SHIM_CALLS"
  jq -cn --arg c "$command_str" '{tool_name:"Bash", tool_input:{command:$c}}' > "$PAYLOAD"
  (
    cd "$pwd_dir" || exit 99
    exec env CLAUDE_PLUGIN_ROOT="${PLUGIN_ROOT:-$REPO_ROOT}" \
      CLAUDE_PROJECT_DIR="$LOG_ROOT" "$@" \
      bash "$HOOK" < "$PAYLOAD" > "$OUT" 2> "$ERR"
  ) &
  HOOK_PID=$!
  BG_PIDS="$BG_PIDS $HOOK_PID"
}

# finish_hook <seconds> — wait for the hook, at most <seconds>; on timeout
# kill it and set RC=124 so the assertion fails instead of hanging.
finish_hook() {
  local secs="$1" i=0 max
  max=$((secs * 5))
  while kill -0 "$HOOK_PID" 2>/dev/null && [ "$i" -lt "$max" ]; do
    sleep 0.2
    i=$((i + 1))
  done
  if kill -0 "$HOOK_PID" 2>/dev/null; then
    pkill -P "$HOOK_PID" 2>/dev/null
    kill -9 "$HOOK_PID" 2>/dev/null
    wait "$HOOK_PID" 2>/dev/null
    RC=124
  else
    wait "$HOOK_PID" 2>/dev/null
    RC=$?
  fi
}

# run_hook <cwd> <command> [VAR=val ...] — start + finish (20 s bound).
run_hook() {
  start_hook "$@"
  finish_hook 20
}

# wait_for_file <path> <seconds> — bounded wait for a file to appear.
wait_for_file() {
  local i=0 max=$(($2 * 5))
  while [ ! -e "$1" ] && [ "$i" -lt "$max" ]; do sleep 0.2; i=$((i + 1)); done
  [ -e "$1" ]
}

# make_project <dir> <package.json body> — committed fixture repo; the lock
# file makes the hook pick pnpm.
make_project() {
  local dir="$1" body="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
  printf '%s\n' "$body" > "$dir/package.json"
  : > "$dir/pnpm-lock.yaml"
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
}

stage_feature() {
  printf 'console.log(1)\n' > "$1/feature.js"
  git -C "$1" add -A
}

log_has() { grep -q "\"pattern\":\"$1\"" "$LOG_FILE" 2>/dev/null; }
lock_pid() { cat "$LOCK/pid" 2>/dev/null; }

# A project whose three steps each record whether the slot was held by the
# hook pid (slotpid.txt) and what CPU_SLOT_HELD the step saw (held.txt).
REC_PKG='{ "name": "fixture", "version": "0.0.0", "scripts": {
  "lint": "cat $CPU_SLOT_DIR/cpu-slot.lock/pid >> slotpid.txt; echo $CPU_SLOT_HELD >> held.txt",
  "typecheck": "cat $CPU_SLOT_DIR/cpu-slot.lock/pid >> slotpid.txt; echo $CPU_SLOT_HELD >> held.txt",
  "test": "cat $CPU_SLOT_DIR/cpu-slot.lock/pid >> slotpid.txt; echo $CPU_SLOT_HELD >> held.txt; echo ran >> ran.txt" } }'

echo "#492 regression — safe-commit runs the suite inside the CPU slot"

# === 1: slot held during the steps, released on green ========================
P1="$TMP/p1"; make_project "$P1" "$REC_PKG"; stage_feature "$P1"
run_hook "$P1" "git commit -m x"
[ "$RC" = "0" ] && pass "green gate → exit 0" || fail "green gate: expected exit 0, got $RC ($(cat "$ERR"))"
exp="$(printf '%s\n%s\n%s' "$HOOK_PID" "$HOOK_PID" "$HOOK_PID")"
[ "$(cat "$P1/slotpid.txt" 2>/dev/null)" = "$exp" ] \
  && pass "slot lock pid == hook pid during lint, typecheck and test (one turn)" \
  || fail "slot pid seen by the steps: '$(tr '\n' ' ' < "$P1/slotpid.txt" 2>/dev/null)' expected 3x $HOOK_PID"
[ "$(cat "$P1/held.txt" 2>/dev/null)" = "$exp" ] \
  && pass "CPU_SLOT_HELD=<hook pid> exported into the project scripts" \
  || fail "CPU_SLOT_HELD seen by the steps: '$(tr '\n' ' ' < "$P1/held.txt" 2>/dev/null)'"
[ ! -e "$LOCK" ] && pass "slot released after green" || fail "slot lock still present after green"
log_has "push-gate-green" && pass "green logged push-gate-green" || fail "no push-gate-green log"

# === 2: released on red ======================================================
P2="$TMP/p2"
make_project "$P2" '{ "name": "f", "version": "0.0.0", "scripts": { "test": "exit 1" } }'
stage_feature "$P2"
run_hook "$P2" "git commit -m x"
[ "$RC" = "2" ] && pass "red gate → exit 2" || fail "red gate: expected exit 2, got $RC"
[ ! -e "$LOCK" ] && pass "slot released after red" || fail "slot lock still present after red"

# === 3: released on TERM ======================================================
P3="$TMP/p3"
make_project "$P3" '{ "name": "f", "version": "0.0.0", "scripts": { "test": "touch started.txt; sleep 3" } }'
stage_feature "$P3"
start_hook "$P3" "git commit -m x"
if wait_for_file "$P3/started.txt" 10; then
  [ "$(lock_pid)" = "$HOOK_PID" ] && pass "slot held by the hook while the step runs" \
    || fail "slot pid '$(lock_pid)' != hook pid $HOOK_PID while step runs"
  kill -TERM "$HOOK_PID" 2>/dev/null
else
  fail "step never started (cannot signal the hook)"
fi
finish_hook 15
[ "$RC" = "130" ] && pass "TERM → hook exits 130" || fail "TERM: expected exit 130, got $RC"
[ ! -e "$LOCK" ] && pass "slot released after TERM" || fail "slot lock still present after TERM"

# === 4: busy slot → BLOCKED, exit 2, cpu-slot-busy ============================
P4="$TMP/p4"
make_project "$P4" '{ "name": "f", "version": "0.0.0", "scripts": { "test": "echo ran >> ran.txt" } }'
printf '{ "safeCommit": { "slotMaxWait": 1 } }\n' > "$P4/.atelier.json"
stage_feature "$P4"
sleep 120 & HOLDER=$!; BG_PIDS="$BG_PIDS $HOLDER"
mkdir "$LOCK"; echo "$HOLDER" > "$LOCK/pid"; echo "holder-x" > "$LOCK/label"; date '+%H:%M:%S' > "$LOCK/since"
run_hook "$P4" "git commit -m x" CPU_SLOT_POLL=1 CPU_SLOT_FAKE_LOAD=7.5 CPU_SLOT_FAKE_CORES=12
[ "$RC" = "2" ] && pass "busy slot → exit 2 (not 124/hang)" || fail "busy slot: expected exit 2, got $RC"
grep -q 'BLOCKED — CPU slot busy' "$ERR" \
  && pass "stderr carries 'BLOCKED — CPU slot busy'" || fail "no BLOCKED message: $(cat "$ERR")"
grep -q 'held by holder-x' "$ERR" && grep -q 'load 7.5/12' "$ERR" \
  && pass "message names the holder label and load 7.5/12" || fail "message lacks holder/load: $(cat "$ERR")"
log_has "cpu-slot-busy" && pass "logged cpu-slot-busy" || fail "no cpu-slot-busy log"
# #570: the message reports the MEASURED wait, never the configured one verbatim
# and never 0 when the hook really waited. slotMaxWait is 1 (the clamp's floor)
# and CPU_SLOT_POLL=1, so the helper waits at least the full 1 s.
waited_n="$(sed -nE 's/.*BLOCKED — CPU slot busy after ([0-9]+)s.*/\1/p' "$ERR" | head -n 1)"
[ -n "$waited_n" ] && [ "$waited_n" -ge 1 ] && [ "$waited_n" -le 10 ] \
  && pass "stderr reports the measured wait: 'after ${waited_n}s' (>= clamped slotMaxWait 1)" \
  || fail "stderr lacks 'after <N>s' with N >= 1: $(cat "$ERR")"
grep -q 'returned early' "$ERR" && fail "full-length wait wrongly flagged 'returned early': $(cat "$ERR")" \
  || pass "full-length wait carries no early-return reason"
busy_msg="$(jq -r 'select(.pattern=="cpu-slot-busy") | .reason // .message // .detail // tostring' "$LOG_FILE" 2>/dev/null | head -n 1)"
case "$busy_msg" in
  *"CPU slot busy: waited ${waited_n}s of 1s max (held by holder-x, load 7.5/12) worktree="*"p4"*)
    pass "log entry records the measured wait, the max and the worktree" ;;
  *) fail "cpu-slot-busy log entry malformed: '$busy_msg' (raw: $(grep cpu-slot-busy "$LOG_FILE" 2>/dev/null | head -n 1))" ;;
esac
[ ! -e "$P4/ran.txt" ] && pass "no step ran while blocked" || fail "a step ran despite the busy slot"
[ "$(lock_pid)" = "$HOLDER" ] && pass "foreign holder's lock left untouched" || fail "foreign lock changed: '$(lock_pid)'"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
rm -rf "$LOCK"

# === 4b: high load + free slot → the gate runs, nothing blocks (#524) ========
P4B="$TMP/p4b"
make_project "$P4B" '{ "name": "f", "version": "0.0.0", "scripts": { "test": "echo ran >> ran.txt" } }'
printf '{ "safeCommit": { "slotMaxWait": 1 } }\n' > "$P4B/.atelier.json"
stage_feature "$P4B"
run_hook "$P4B" "git commit -m x" CPU_SLOT_POLL=1 CPU_SLOT_FAKE_LOAD=50 CPU_SLOT_FAKE_CORES=4
[ "$RC" = "0" ] && pass "load 50 on 4 cores with a free slot → exit 0 (not blocked)" || fail "high load: expected exit 0, got $RC ($(cat "$ERR"))"
[ "$(cat "$P4B/ran.txt" 2>/dev/null)" = "ran" ] && pass "load 50: the gate steps ran" || fail "load 50: steps did not run"
grep -q 'BLOCKED' "$ERR" && fail "load 50: stderr carries BLOCKED: $(cat "$ERR")" || pass "load 50: no BLOCKED message"
log_has "cpu-slot-busy" && fail "load 50: wrongly logged cpu-slot-busy" || pass "load 50: no cpu-slot-busy log"
[ ! -e "$LOCK" ] && pass "load 50: slot released after the run" || fail "load 50: lock left behind"

# === 5: N/A paths never touch the slot ========================================
# Control: the recorder helper IS called for a real gate (acquire + release).
PLUGIN_ROOT="$ROOT_SHIM"
P5="$TMP/p5"; make_project "$P5" "$REC_PKG"; stage_feature "$P5"
run_hook "$P5" "git commit -m x"
grep -q "^acquire --owner $HOOK_PID --max-wait 240 --seniority-key wt-[0-9][0-9]*\$" "$SHIM_CALLS" 2>/dev/null \
  && grep -q "^release --owner $HOOK_PID\$" "$SHIM_CALLS" 2>/dev/null \
  && pass "control: real gate → helper acquire + release with --owner <hook pid>" \
  || fail "control: helper calls were: $(tr '\n' '|' < "$SHIM_CALLS" 2>/dev/null)"

no_slot() {
  if [ ! -e "$SHIM_CALLS" ]; then pass "$1 → helper never called"; else
    fail "$1 → helper was called: $(tr '\n' '|' < "$SHIM_CALLS")"; fi
}
run_hook "$P5" "git commit -m x" ATELIER_SKIP_SAFE_COMMIT=1
[ "$RC" = "0" ] && no_slot "skip env" || fail "skip env: exit $RC"
run_hook "$P5" "git status"
[ "$RC" = "0" ] && no_slot "non-commit command" || fail "non-commit: exit $RC"

P5D="$TMP/p5d"; make_project "$P5D" "$REC_PKG"
printf '# docs\n' > "$P5D/README.md"; git -C "$P5D" add -A
run_hook "$P5D" "git commit -m x"
[ "$RC" = "0" ] && log_has "docs-only" && no_slot "docs-only commit" || fail "docs-only: exit $RC / no docs-only log"

P5N="$TMP/p5n"; mkdir -p "$P5N"
git -C "$P5N" init -q -b main; git -C "$P5N" config user.email t@t.t; git -C "$P5N" config user.name t
printf 'x\n' > "$P5N/a.js"; git -C "$P5N" add -A
run_hook "$P5N" "git commit -m x"
[ "$RC" = "0" ] && log_has "no-package-json" && no_slot "no package.json" || fail "no package.json: exit $RC"

P5S="$TMP/p5s"
make_project "$P5S" '{ "name": "f", "version": "0.0.0", "scripts": { "build": "echo b" } }'
stage_feature "$P5S"
run_hook "$P5S" "git commit -m x"
[ "$RC" = "0" ] && no_slot "package.json without lint/typecheck/test" || fail "no steps: exit $RC"

# bypass refusal unchanged (#277), and never reaches the slot
run_hook "$P5" "ATELIER_SKIP_SAFE_COMMIT=1 git commit -m x"
[ "$RC" = "2" ] && log_has "bypass-attempt" && no_slot "inline bypass (refused, exit 2)" \
  || fail "inline bypass: expected exit 2 + bypass-attempt log, got $RC"
unset PLUGIN_ROOT

# === 6: helper missing → cpu-slot-na, gate still runs =========================
P6="$TMP/p6"; make_project "$P6" "$REC_PKG"; stage_feature "$P6"
PLUGIN_ROOT="$ROOT_NOHELP" run_hook "$P6" "git commit -m x"
[ "$RC" = "0" ] && [ "$(cat "$P6/ran.txt" 2>/dev/null)" = "ran" ] \
  && pass "helper missing → gate still ran (exit 0)" || fail "helper missing: exit $RC ran='$(cat "$P6/ran.txt" 2>/dev/null)'"
log_has "cpu-slot-na" && pass "helper missing → logged cpu-slot-na" || fail "no cpu-slot-na log"
[ ! -e "$LOCK" ] && pass "helper missing → no lock created" || fail "lock created without helper"

# === 7: nested wrap — project script calls the helper itself ==================
P7="$TMP/p7"
make_project "$P7" "{ \"name\": \"f\", \"version\": \"0.0.0\", \"scripts\": { \"test\": \"$REAL_HELPER sh -c 'echo inner >> ran.txt'\" } }"
stage_feature "$P7"
run_hook "$P7" "git commit -m x" CPU_SLOT_POLL=1
[ "$RC" = "0" ] && [ "$(cat "$P7/ran.txt" 2>/dev/null)" = "inner" ] \
  && pass "script wrapped in the helper ran under the hook's turn (no deadlock)" \
  || fail "nested wrap: exit $RC (124 = deadlock) ran='$(cat "$P7/ran.txt" 2>/dev/null)'"
[ ! -e "$LOCK" ] && pass "nested wrap → slot released" || fail "nested wrap: lock left behind"

# === 8: ANCESTOR-HOLDER — hook runs as a descendant of the slot holder ========
# The whole commit is wrapped in the real helper (as an operator running
# `cpu-slot git commit` would): the lock pid is an ANCESTOR of the hook, so
# acquiring would wait on our own parent. The hook must log cpu-slot-nested,
# not wait, exit 0 and leave the outer lock in place.
P8="$TMP/p8"; make_project "$P8" "$REC_PKG"; stage_feature "$P8"
printf '{ "safeCommit": { "slotMaxWait": 60 } }\n' > "$P8/.atelier.json"
A_AFTER="$TMP/ancestor.after"; A_OUT="$TMP/ancestor.out"; A_ERR="$TMP/ancestor.err"
rm -f "$A_AFTER"
jq -cn --arg c "git commit -m x" '{tool_name:"Bash", tool_input:{command:$c}}' > "$PAYLOAD"
rm -rf "$LOG_ROOT"
WRAP="$TMP/ancestor-wrap.sh"
cat > "$WRAP" <<WRAPPER
#!/usr/bin/env bash
cd "$P8" || exit 99
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$LOG_ROOT" bash "$HOOK" < "$PAYLOAD" > "$A_OUT" 2> "$A_ERR"
echo "rc=\$?" > "$A_AFTER"
if [ -d "$LOCK" ]; then echo "lock=present pid=\$(cat "$LOCK/pid")" >> "$A_AFTER"; else echo "lock=absent" >> "$A_AFTER"; fi
WRAPPER
chmod +x "$WRAP"
HOOK_PID=""
SECONDS=0
( CPU_SLOT_POLL=1 exec "$REAL_HELPER" "$WRAP" > /dev/null 2>&1 ) &
OUTER=$!; BG_PIDS="$BG_PIDS $OUTER"
i=0
while kill -0 "$OUTER" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
elapsed=$SECONDS
if kill -0 "$OUTER" 2>/dev/null; then
  pkill -P "$OUTER" 2>/dev/null; kill -9 "$OUTER" 2>/dev/null
  fail "ancestor-holder: hook did not finish within 20 s (waited on its own ancestor?)"
else
  wait "$OUTER" 2>/dev/null
  [ "$(sed -n 1p "$A_AFTER" 2>/dev/null)" = "rc=0" ] \
    && pass "ancestor-holder: hook exits 0 without waiting (elapsed ${elapsed}s)" \
    || fail "ancestor-holder: $(tr '\n' ' ' < "$A_AFTER" 2>/dev/null) err=$(cat "$A_ERR" 2>/dev/null)"
  [ "$elapsed" -lt 15 ] && pass "ancestor-holder: finished in ${elapsed}s (< 15 s, slotMaxWait was 60)" \
    || fail "ancestor-holder: took ${elapsed}s"
  log_has "cpu-slot-nested" && pass "ancestor-holder: logged cpu-slot-nested" || fail "no cpu-slot-nested log"
  log_has "cpu-slot-busy" && fail "ancestor-holder: wrongly logged cpu-slot-busy" || pass "ancestor-holder: no cpu-slot-busy"
  sed -n 2p "$A_AFTER" 2>/dev/null | grep -q '^lock=present pid=[0-9][0-9]*$' \
    && pass "ancestor-holder: outer lock still present after the hook ($(sed -n 2p "$A_AFTER"))" \
    || fail "ancestor-holder: outer lock not preserved: $(sed -n 2p "$A_AFTER" 2>/dev/null)"
  [ "$(cat "$P8/ran.txt" 2>/dev/null)" = "ran" ] && pass "ancestor-holder: the gate steps still ran" \
    || fail "ancestor-holder: steps did not run"
fi
[ ! -e "$LOCK" ] && pass "ancestor-holder: outer helper released its lock at the end" || fail "outer lock leaked"

# === 9: slotMaxWait clamping (observed via the recorder helper's args) ========
PLUGIN_ROOT="$ROOT_SHIM"
wait_for_cfg() { # <label> <expected> <config-json or ''>
  local d="$TMP/clamp-$1" got
  make_project "$d" '{ "name": "f", "version": "0.0.0", "scripts": { "test": "true" } }'
  [ -n "$3" ] && printf '%s\n' "$3" > "$d/.atelier.json"
  stage_feature "$d"
  run_hook "$d" "git commit -m x"
  got="$(sed -nE 's/^acquire --owner [0-9]+ --max-wait ([^ ]*)( --seniority-key [^ ]*)?$/\1/p' "$SHIM_CALLS" 2>/dev/null | head -n 1)"
  [ "$got" = "$2" ] && pass "slotMaxWait $1 → --max-wait $2" || fail "slotMaxWait $1: expected $2, got '$got'"
}
wait_for_cfg default 240 ''
wait_for_cfg 100 100 '{ "safeCommit": { "slotMaxWait": 100 } }'
wait_for_cfg 400 400 '{ "safeCommit": { "slotMaxWait": 400 } }'
wait_for_cfg 9999 400 '{ "safeCommit": { "slotMaxWait": 9999 } }'
wait_for_cfg zero 240 '{ "safeCommit": { "slotMaxWait": 0 } }'
wait_for_cfg garbage 240 '{ "safeCommit": { "slotMaxWait": "abc" } }'
wait_for_cfg negative 240 '{ "safeCommit": { "slotMaxWait": -5 } }'
unset PLUGIN_ROOT

# === 10: --seniority-key is passed, stable per worktree (#570) ================
PLUGIN_ROOT="$ROOT_SHIM"
key_of() { sed -nE 's/^acquire .* --seniority-key (wt-[0-9]+)$/\1/p' "$SHIM_CALLS" 2>/dev/null | head -n 1; }
P10A="$TMP/p10a"; make_project "$P10A" '{ "name": "f", "version": "0.0.0", "scripts": { "test": "true" } }'; stage_feature "$P10A"
P10B="$TMP/p10b"; make_project "$P10B" '{ "name": "f", "version": "0.0.0", "scripts": { "test": "true" } }'; stage_feature "$P10B"
run_hook "$P10A" "git commit -m x"; KEY_A1="$(key_of)"
run_hook "$P10A" "git commit -m x"; KEY_A2="$(key_of)"
run_hook "$P10B" "git commit -m x"; KEY_B="$(key_of)"
[ -n "$KEY_A1" ] && pass "hook passes --seniority-key wt-<cksum> ($KEY_A1)" || fail "no --seniority-key in: $(tr '\n' '|' < "$SHIM_CALLS")"
[ "$KEY_A1" = "$KEY_A2" ] && pass "same worktree → same key across re-runs" || fail "key changed between runs: $KEY_A1 vs $KEY_A2"
[ -n "$KEY_B" ] && [ "$KEY_A1" != "$KEY_B" ] && pass "different worktree → different key" || fail "keys collide: A=$KEY_A1 B=$KEY_B"
unset PLUGIN_ROOT

# === 11: early return — helper exits 75 well before the deadline (#570) =======
ROOT_EARLY="$TMP/root-early"; mkdir -p "$ROOT_EARLY/hooks" "$ROOT_EARLY/scripts"
ln -s "$REPO_ROOT/hooks/lib" "$ROOT_EARLY/hooks/lib"
cat > "$ROOT_EARLY/scripts/atelier-cpu-slot" <<'EARLY'
#!/usr/bin/env bash
[ "$1" = "acquire" ] && { echo "atelier-cpu-slot: helper bailed out (fixture)" >&2; exit 75; }
exit 0
EARLY
chmod +x "$ROOT_EARLY/scripts/atelier-cpu-slot"
P11="$TMP/p11"; make_project "$P11" '{ "name": "f", "version": "0.0.0", "scripts": { "test": "echo ran >> ran.txt" } }'
stage_feature "$P11"
PLUGIN_ROOT="$ROOT_EARLY" run_hook "$P11" "git commit -m x" CPU_SLOT_POLL=1
[ "$RC" = "2" ] && pass "early 75 → exit 2" || fail "early 75: expected exit 2, got $RC"
grep -q 'BLOCKED — CPU slot busy after 0s' "$ERR" && pass "early return reports the measured 0s" || fail "no 'after 0s': $(cat "$ERR")"
grep -q 'returned early after 0s (helper: atelier-cpu-slot: helper bailed out (fixture));' "$ERR" \
  && pass "early-return reason line quotes the helper's first stderr line" || fail "no early-return reason: $(cat "$ERR")"
grep -q 're-run the same commit, it waits again' "$ERR" && pass "early return still tells the agent to re-run" || fail "re-run hint missing"
log_has "cpu-slot-busy" && pass "early return logged cpu-slot-busy" || fail "no cpu-slot-busy log on early return"
[ ! -e "$P11/ran.txt" ] && pass "early return: no step ran" || fail "step ran despite the 75"

echo
if [ "$fails" -eq 0 ]; then
  echo "safe-commit-cpu-slot: all assertions passed"
  exit 0
fi
echo "safe-commit-cpu-slot: $fails assertion(s) failed"
exit 1
