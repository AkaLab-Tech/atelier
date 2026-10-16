#!/usr/bin/env bash
#
# Regression test for #490 (#475a) — scripts/atelier-cpu-slot, crash recovery
# and interop with the loose ~/.local/bin/cpu-slot layout.
#
#   Group 1 — kill -9 of a run-mode holder: the next waiter reclaims the slot
#   Group 2 — kill -9 of an `acquire --owner` owner: reclaimed by the next
#             acquire and by --wait; `release --owner` only removes its own
#   Group 3 — a young pid-less lock counts as held; an old one is abandoned
#   Group 4 — dead tickets are pruned by --status, --wait and acquire loops
#   Group 5 — a stale lock has a single winner among concurrent reclaimers
#   Group 6 — legacy layout (bare-pid tickets + pid/label/since/cmd files,
#             as the loose script writes them) is honoured, and our own lock
#             uses the same layout
#
# Hermetic: temp CPU_SLOT_DIR per case (never /tmp/cpu-slot.lock), the loose
# script is never executed, short polls/timeouts, every child is killed.
#
# Run:  hooks/tests/cpu-slot-crash-recovery.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SLOT="$REPO_ROOT/scripts/atelier-cpu-slot"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}
contains() { # contains <label> <haystack> <needle>
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cpu-slot-crash.XXXXXX")"
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

new_dir() { mktemp -d "$TMP/case.XXXXXX"; }

bounded() { # bounded <seconds> cmd... — SIGALRM watchdog so a hang fails, not blocks
  local s=$1; shift
  perl -e 'alarm shift; exec @ARGV' "$s" "$@"
}

wait_held() { # wait (max ~5 s) until the lock has its cmd file (written last)
  local i=0
  while [ ! -f "$1/cpu-slot.lock/cmd" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -f "$1/cpu-slot.lock/cmd" ]
}

# live_sleeper — start a long sleep, record it for cleanup, set SLP to its pid.
live_sleeper() { sleep 60 & SLP=$!; PIDS+=("$SLP"); }

# dead_pid — set DEAD to a pid that has exited and been reaped.
dead_pid() { sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null; }

export CPU_SLOT_POLL=1
export CPU_SLOT_FAKE_LOAD=0   # the load gate never depends on this machine's real load
unset CPU_SLOT_HELD

# ---------------------------------------------------------------------------
echo "Group 1 — kill -9 of a run-mode holder"
D="$(new_dir)"
CPU_SLOT_DIR="$D" "$SLOT" sleep 60 &
hp=$!; PIDS+=("$hp")
if wait_held "$D"; then
  child="$(pgrep -P "$hp" | head -1)"
  kill -9 "$hp" 2>/dev/null
  [ -n "$child" ] && kill -9 "$child" 2>/dev/null
  wait "$hp" 2>/dev/null
  [ -d "$D/cpu-slot.lock" ] && pass "killed holder left its lock behind" || fail "lock vanished by itself"
  out="$(CPU_SLOT_DIR="$D" bounded 15 "$SLOT" echo reclaimed 2>&1)"
  check "next waiter reclaims and runs" "$out" "reclaimed"
  [ ! -e "$D/cpu-slot.lock" ] && pass "slot free after the reclaiming run" || fail "slot still held"
else
  fail "holder never took the slot"
fi

# ---------------------------------------------------------------------------
echo "Group 2 — kill -9 of an acquire --owner owner"
D="$(new_dir)"
live_sleeper; owner="$SLP"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" acquire --owner "$owner"; check "acquire --owner exits 0" "$?" "0"
check "lock pid is the owner" "$(cat "$D/cpu-slot.lock/pid" 2>/dev/null)" "$owner"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" acquire --owner 999999 --max-wait 1 2>/dev/null
check "second acquire times out (75) while owner is alive" "$?" "75"
check "timed-out acquire left no ticket" "$(ls -A "$D/cpu-slot.queue" 2>/dev/null | tr -d '\n')" ""
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" release --owner 999999; check "release by a non-owner exits 0" "$?" "0"
[ -d "$D/cpu-slot.lock" ] && pass "release by a non-owner leaves the lock" || fail "non-owner release removed the lock"
kill -9 "$owner" 2>/dev/null; wait "$owner" 2>/dev/null
live_sleeper; owner2="$SLP"
CPU_SLOT_DIR="$D" bounded 15 "$SLOT" acquire --owner "$owner2" --max-wait 10
check "next acquire reclaims from the dead owner" "$?" "0"
check "lock pid is now the new owner" "$(cat "$D/cpu-slot.lock/pid" 2>/dev/null)" "$owner2"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" release --owner "$owner2"; check "release by the owner exits 0" "$?" "0"
[ ! -e "$D/cpu-slot.lock" ] && pass "release by the owner removes the lock" || fail "owner release left the lock"

# --wait also treats a dead owner as free.
D="$(new_dir)"
live_sleeper; owner="$SLP"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" acquire --owner "$owner"
kill -9 "$owner" 2>/dev/null; wait "$owner" 2>/dev/null
CPU_SLOT_DIR="$D" bounded 15 "$SLOT" --wait --timeout 5; check "--wait exits 0 when the owner is dead" "$?" "0"
[ ! -e "$D/cpu-slot.lock" ] && pass "--wait reclaimed the stale lock" || fail "stale lock still present after --wait"

# ---------------------------------------------------------------------------
echo "Group 3 — pid-less lock"
D="$(new_dir)"
mkdir "$D/cpu-slot.lock"
CPU_SLOT_DIR="$D" bounded 15 "$SLOT" --wait --timeout 1 2>/dev/null
check "young pid-less lock counts as held (--wait 75)" "$?" "75"
[ -d "$D/cpu-slot.lock" ] && pass "young pid-less lock is not reclaimed" || fail "young pid-less lock was reclaimed"
out="$(CPU_SLOT_DIR="$D" bounded 10 "$SLOT" --status 2>&1 | head -1)"
contains "status reports a young pid-less lock as held" "$out" "held by pid"
touch -t 200001010000 "$D/cpu-slot.lock"
CPU_SLOT_DIR="$D" bounded 15 "$SLOT" --wait --timeout 5; check "old pid-less lock is abandoned (--wait 0)" "$?" "0"
[ ! -e "$D/cpu-slot.lock" ] && pass "old pid-less lock reclaimed" || fail "old pid-less lock still present"

# GNU-shaped stat: `stat -f` succeeds and prints filesystem text (as on GNU
# coreutils), `stat -c %Y` prints the epoch mtime. Computed with perl so the
# stub behaves the same on macOS and Linux.
GNUBIN="$TMP/gnubin"
mkdir -p "$GNUBIN"
cat > "$GNUBIN/stat" <<'STUB'
#!/bin/sh
if [ "$1" = "-c" ] && [ "$2" = "%Y" ]; then
  perl -e 'my @s = stat($ARGV[0]) or exit 1; print $s[9], "\n"' "$3"
  exit $?
fi
if [ "$1" = "-f" ]; then
  printf '  File: "%s"\n    ID: 0 Namelen: 255 Type: ext2/ext3\n' "$3"
  exit 0
fi
exit 1
STUB
chmod +x "$GNUBIN/stat"

echo "Group 3b — pid-less lock with a GNU-shaped stat on PATH"
D="$(new_dir)"
mkdir "$D/cpu-slot.lock"
PATH="$GNUBIN:$PATH" CPU_SLOT_DIR="$D" bounded 15 "$SLOT" --wait --timeout 1 2>/dev/null
check "GNU stat: young pid-less lock counts as held (--wait 75)" "$?" "75"
[ -d "$D/cpu-slot.lock" ] && pass "GNU stat: young pid-less lock is not reclaimed" || fail "GNU stat: young pid-less lock was reclaimed"
out="$(PATH="$GNUBIN:$PATH" CPU_SLOT_DIR="$D" bounded 10 "$SLOT" --status 2>&1 | head -1)"
contains "GNU stat: status reports a young pid-less lock as held" "$out" "held by pid"
touch -t 200001010000 "$D/cpu-slot.lock"
PATH="$GNUBIN:$PATH" CPU_SLOT_DIR="$D" bounded 15 "$SLOT" --wait --timeout 5
check "GNU stat: old pid-less lock is abandoned (--wait 0)" "$?" "0"
[ ! -e "$D/cpu-slot.lock" ] && pass "GNU stat: old pid-less lock reclaimed" || fail "GNU stat: old pid-less lock still present"

# ---------------------------------------------------------------------------
echo "Group 4 — dead ticket pruning"
D="$(new_dir)"
mkdir -p "$D/cpu-slot.queue"
dead_pid; echo "pid $DEAD [gone] make test" > "$D/cpu-slot.queue/$DEAD"; deadA="$DEAD"
live_sleeper; echo "pid $SLP [alive] make build" > "$D/cpu-slot.queue/$SLP"; liveT="$SLP"
out="$(CPU_SLOT_DIR="$D" bounded 10 "$SLOT" --status 2>&1)"
[ ! -e "$D/cpu-slot.queue/$deadA" ] && pass "--status removes the dead ticket" || fail "--status kept the dead ticket"
[ -e "$D/cpu-slot.queue/$liveT" ] && pass "--status keeps the live ticket" || fail "--status removed the live ticket"
contains "--status lists the live waiter" "$out" "waiting: pid $liveT [alive] make build"
case "$out" in *"[gone]"*) fail "--status listed the dead waiter" ;; *) pass "--status does not list the dead waiter" ;; esac

# prune inside --wait and acquire loops while a live holder keeps the slot
D="$(new_dir)"
live_sleeper; holder="$SLP"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" acquire --owner "$holder"
mkdir -p "$D/cpu-slot.queue"
dead_pid; echo "pid $DEAD [gone] x" > "$D/cpu-slot.queue/$DEAD"; deadB="$DEAD"
CPU_SLOT_DIR="$D" bounded 15 "$SLOT" --wait --timeout 1 2>/dev/null
[ ! -e "$D/cpu-slot.queue/$deadB" ] && pass "--wait loop prunes the dead ticket" || fail "--wait loop kept the dead ticket"
dead_pid; echo "pid $DEAD [gone] y" > "$D/cpu-slot.queue/$DEAD"; deadC="$DEAD"
CPU_SLOT_DIR="$D" bounded 15 "$SLOT" acquire --owner 999999 --max-wait 1 2>/dev/null
[ ! -e "$D/cpu-slot.queue/$deadC" ] && pass "acquire loop prunes the dead ticket" || fail "acquire loop kept the dead ticket"

# ---------------------------------------------------------------------------
echo "Group 5 — single winner on a stale reclaim"
D="$(new_dir)"
dead_pid
mkdir "$D/cpu-slot.lock"
echo "$DEAD" > "$D/cpu-slot.lock/pid"
echo "dead" > "$D/cpu-slot.lock/label"
N=4
owners=(); rcs=()
for i in $(seq 1 $N); do live_sleeper; owners+=("$SLP"); done
cpids=()
for i in $(seq 0 $((N - 1))); do
  (CPU_SLOT_DIR="$D" bounded 20 "$SLOT" acquire --owner "${owners[$i]}" --max-wait 2 2>/dev/null) &
  cpids+=("$!"); PIDS+=("$!")
done
for p in "${cpids[@]}"; do wait "$p"; rcs+=("$?"); done
wins=0; timeouts=0
for r in "${rcs[@]}"; do
  [ "$r" = 0 ] && wins=$((wins + 1))
  [ "$r" = 75 ] && timeouts=$((timeouts + 1))
done
check "exactly one contender wins the stale lock" "$wins" "1"
check "the other contenders time out with 75" "$timeouts" "$((N - 1))"
winner_pid="$(cat "$D/cpu-slot.lock/pid" 2>/dev/null)"
found=0
for o in "${owners[@]}"; do [ "$o" = "$winner_pid" ] && found=1; done
check "lock pid is one of the contenders' owners" "$found" "1"
stale_left=0
for f in "$D"/*stale*; do [ -e "$f" ] && stale_left=1; done
check "no .stale leftovers" "$stale_left" "0"

# Two run-mode reclaimers race for one stale lock: their critical sections
# (enter/exit markers around a short sleep) must never overlap, and both run.
echo "Group 5b — reclaimers' critical sections never overlap"
for round in 1 2 3; do
  D="$(new_dir)"
  dead_pid
  mkdir "$D/cpu-slot.lock"
  echo "$DEAD" > "$D/cpu-slot.lock/pid"
  LOG="$D/log"; : > "$LOG"
  body='echo "enter $$" >> "$LOG_FILE"; sleep 0.4; echo "exit $$" >> "$LOG_FILE"'
  rp=()
  for i in 1 2; do
    (LOG_FILE="$LOG" CPU_SLOT_DIR="$D" bounded 30 "$SLOT" bash -c "$body" 2>/dev/null) &
    rp+=("$!"); PIDS+=("$!")
  done
  rc_all=0
  for p in "${rp[@]}"; do wait "$p" || rc_all=1; done
  check "round $round: both contenders exit 0" "$rc_all" "0"
  # Well-formed iff lines alternate enter X / exit X with the same pid.
  verdict="$(awk '
    { if ($1 == "enter") { if (open != "") bad = 1; open = $2; n++ }
      else if ($1 == "exit") { if (open != $2) bad = 1; open = "" } }
    END { print (bad || open != "" || n != 2) ? "overlap-or-missing(n=" n ")" : "serial" }' "$LOG")"
  check "round $round: critical sections are serial and both ran" "$verdict" "serial"
  [ ! -e "$D/cpu-slot.lock" ] && pass "round $round: slot free afterwards" || fail "round $round: slot still held"
  [ ! -e "$D/cpu-slot.lock.reclaim" ] && pass "round $round: no reclaim guard left" || fail "round $round: reclaim guard left behind"
done

# A guard left by a dead reclaimer: dropped once 30 s old, honoured while young.
echo "Group 5c — stale reclaim guard"
D="$(new_dir)"
dead_pid
mkdir "$D/cpu-slot.lock" "$D/cpu-slot.lock.reclaim"
echo "$DEAD" > "$D/cpu-slot.lock/pid"
touch -t 200001010000 "$D/cpu-slot.lock.reclaim"
CPU_SLOT_DIR="$D" bounded 15 "$SLOT" --wait --timeout 5 2>/dev/null
check "old reclaim guard is cleared and reclaim proceeds (--wait 0)" "$?" "0"
[ ! -e "$D/cpu-slot.lock" ] && pass "stale lock reclaimed past an old guard" || fail "stale lock still present"
[ ! -e "$D/cpu-slot.lock.reclaim" ] && pass "old reclaim guard removed" || fail "old reclaim guard still present"

D="$(new_dir)"
dead_pid
mkdir "$D/cpu-slot.lock" "$D/cpu-slot.lock.reclaim"
echo "$DEAD" > "$D/cpu-slot.lock/pid"
CPU_SLOT_DIR="$D" bounded 8 "$SLOT" --wait --timeout 1 2>/dev/null
rc=$?
[ -d "$D/cpu-slot.lock" ] && pass "young reclaim guard blocks the reclaim" || fail "lock removed despite a young guard"
check "young guard: --wait still honours its timeout (75)" "$rc" "75"

# ---------------------------------------------------------------------------
echo "Group 6 — legacy layout interop"
D="$(new_dir)"
live_sleeper; legacy_holder="$SLP"
live_sleeper; legacy_waiter="$SLP"
mkdir -p "$D/cpu-slot.lock" "$D/cpu-slot.queue"
echo "$legacy_holder" > "$D/cpu-slot.lock/pid"
echo "legacy-proj" > "$D/cpu-slot.lock/label"
echo "10:11:12" > "$D/cpu-slot.lock/since"
echo "pnpm test" > "$D/cpu-slot.lock/cmd"
echo "pid $legacy_waiter [legacy-wait] pnpm build" > "$D/cpu-slot.queue/$legacy_waiter"
touch -t 203001010000 "$D/cpu-slot.queue/$legacy_waiter"  # newer than any real waiter: ticket order is not what this group checks

out="$(CPU_SLOT_DIR="$D" bounded 10 "$SLOT" --status 2>&1)"
contains "status reads the legacy holder" "$out" "held by pid $legacy_holder [legacy-proj] since 10:11:12"
contains "status reads the legacy command" "$out" "  pnpm test"
contains "status lists the legacy bare-pid ticket" "$out" "waiting: pid $legacy_waiter [legacy-wait] pnpm build"

CPU_SLOT_DIR="$D" bounded 15 "$SLOT" --wait --timeout 1 2>/dev/null
check "--wait honours a live legacy holder (75)" "$?" "75"

MARK="$D/ran"
(CPU_SLOT_DIR="$D" bounded 40 "$SLOT" bash -c "echo ran > '$MARK'") &
wp=$!; PIDS+=("$wp")
sleep 2
[ ! -e "$MARK" ] && pass "run mode waits behind a live legacy holder" || fail "run mode ran despite a live legacy holder"
check "waiter queued next to the legacy ticket" "$(ls "$D/cpu-slot.queue" | wc -l | tr -d ' ')" "2"
kill -9 "$legacy_holder" 2>/dev/null
wait "$wp"; check "waiter proceeds after the legacy holder dies (exit 0)" "$?" "0"
[ -e "$MARK" ] && pass "command ran after reclaiming the legacy lock" || fail "command never ran"

# Nested call under a legacy-layout lock: CPU_SLOT_HELD matching its pid runs directly.
D="$(new_dir)"
live_sleeper
mkdir -p "$D/cpu-slot.lock"
echo "$SLP" > "$D/cpu-slot.lock/pid"
out="$(CPU_SLOT_DIR="$D" CPU_SLOT_HELD="$SLP" bounded 10 "$SLOT" echo nested-ok 2>&1)"
check "CPU_SLOT_HELD matching a legacy lock runs directly" "$out" "nested-ok"

# Our own lock uses the legacy file set.
D="$(new_dir)"
out="$(CPU_SLOT_DIR="$D" CPU_SLOT_LABEL=ours bounded 10 "$SLOT" bash -c 'ls "$CPU_SLOT_DIR/cpu-slot.lock" | tr "\n" " "; ls "$CPU_SLOT_DIR/cpu-slot.queue" | wc -l' 2>&1)"
contains "own lock has cmd label pid since files" "$out" "cmd label pid since"
contains "own ticket is removed while holding" "$out" " 0"

# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "cpu-slot-crash-recovery (#490): all assertions passed."
  exit 0
else
  echo "cpu-slot-crash-recovery (#490): $fails assertion(s) failed."
  exit 1
fi
