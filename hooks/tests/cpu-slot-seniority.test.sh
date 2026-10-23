#!/usr/bin/env bash
#
# Regression test for #570 — scripts/atelier-cpu-slot acquire --seniority-key.
#
# A timed-out acquire deletes its ticket, so the re-issued acquire (the
# safe-commit hook is re-run after every BLOCKED) used to go to the back of the
# queue. With --seniority-key the first timeout records the enqueue time in
# $ROOT/cpu-slot.seniority/K (mtime) plus K.last, and a later acquire with the
# same key gives its new ticket that mtime.
#
#   Group 1 — retention: A (keyed) times out, B (run mode) queues, A re-acquires
#             with the same key: A's ticket carries the original time, ranks
#             ahead of B and wins the slot when the holder goes away; the
#             seniority files are removed on acquire
#   Group 2 — stale expiry: a key whose K.last is older than max-wait + 120 s
#             is ignored and pruned
#   Group 3 — no key: nothing is written to the seniority dir, the ticket gets
#             a fresh mtime and an existing entry is left alone
#   Group 4 — key sanitizing to [A-Za-z0-9._-]
#
# Hermetic: temp CPU_SLOT_DIR (never /tmp/cpu-slot.lock), empty config dir,
# fake load, CPU_SLOT_POLL=1, small max-waits, every wait bounded.
#
# Run:  hooks/tests/cpu-slot-seniority.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

# shellcheck disable=SC2015 # `A && pass || fail` idiom
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SLOT="$REPO_ROOT/scripts/atelier-cpu-slot"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cpu-slot-sen.XXXXXX")"
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && { pkill -P "$p" 2>/dev/null; kill -9 "$p" 2>/dev/null; }
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/cfg"
export ATELIER_CONFIG_DIR="$TMP/cfg"
export CPU_SLOT_FAKE_LOAD=0 CPU_SLOT_FAKE_CORES=4 CPU_SLOT_POLL=1
unset CPU_SLOT_HELD CPU_SLOT_LABEL

mt() { perl -e 'print((stat shift)[9])' "$1" 2>/dev/null; }
wait_for() { # wait_for <seconds> <test-command...> — bounded poll
  local s=$1 i=0; shift
  while ! "$@" && [ "$i" -lt $((s * 5)) ]; do sleep 0.2; i=$((i + 1)); done
  "$@"
}
bounded() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }

# new_env — fresh CPU_SLOT_DIR with a live foreign holder on slot 0.
new_env() {
  CPU_SLOT_DIR="$(mktemp -d "$TMP/case.XXXXXX")"; export CPU_SLOT_DIR
  Q="$CPU_SLOT_DIR/cpu-slot.queue"; S="$CPU_SLOT_DIR/cpu-slot.seniority"
  LOCK="$CPU_SLOT_DIR/cpu-slot.lock"
  sleep 300 >/dev/null 2>&1 & HOLDER=$!; disown "$HOLDER"; PIDS+=("$HOLDER")
  mkdir "$LOCK"; echo "$HOLDER" > "$LOCK/pid"; echo "holder-x" > "$LOCK/label"
  date '+%H:%M:%S' > "$LOCK/since"
}
ticket_of() { # ticket_of <label> — path of the queue ticket whose label matches
  grep -l "\[$1\]" "$Q"/* 2>/dev/null | head -n 1
}
has_ticket() { [ -n "$(ticket_of "$1")" ]; }
stamp() { # stamp <epoch-seconds-ago> <file> — set mtime N seconds in the past
  local ts
  ts="$(perl -e '@t=localtime(time-shift); printf "%04d%02d%02d%02d%02d.%02d",$t[5]+1900,$t[4]+1,$t[3],$t[2],$t[1],$t[0]' "$1")"
  touch -t "$ts" "$2"
}

echo "#570 — atelier-cpu-slot acquire --seniority-key"

# === 1: retention across a timeout ============================================
echo "group 1 — retention"
new_env
SLP_A=$(sleep 300 >/dev/null 2>&1 & echo $!); PIDS+=("$SLP_A")
CPU_SLOT_LABEL=waiter-A bounded 20 "$SLOT" acquire --owner "$SLP_A" --max-wait 1 --seniority-key k1 >/dev/null 2>&1
check "A (keyed) times out against the live holder → exit 75" "$?" "75"
[ -f "$S/k1" ] && [ -f "$S/k1.last" ] && pass "first timeout recorded K and K.last" || fail "seniority files missing: $(ls "$S" 2>&1)"
[ ! -e "$Q/$$" ] && ! has_ticket waiter-A && pass "A's ticket was removed on timeout" || fail "A's ticket leaked"
T_ORIG="$(mt "$S/k1")"
now="$(date +%s)"
[ -n "$T_ORIG" ] && [ "$T_ORIG" -le "$now" ] && [ "$T_ORIG" -ge $((now - 15)) ] \
  && pass "K mtime is the original enqueue time (recent, <= now)" || fail "K mtime '$T_ORIG' vs now $now"

sleep 2   # B must queue strictly later than A's original ticket (1 s mtime resolution)
CPU_SLOT_LABEL=waiter-B bounded 60 "$SLOT" sleep 0 >"$TMP/B.out" 2>&1 &
B=$!; PIDS+=("$B")
wait_for 10 has_ticket waiter-B && pass "B queued behind the holder" || fail "B never queued"
B_MT="$(mt "$(ticket_of waiter-B)")"
[ "$B_MT" -gt "$T_ORIG" ] && pass "B's ticket mtime ($B_MT) is later than A's original ($T_ORIG)" || fail "B mtime $B_MT not > $T_ORIG"

CPU_SLOT_LABEL=waiter-A bounded 60 "$SLOT" acquire --owner "$SLP_A" --max-wait 30 --seniority-key k1 >"$TMP/A2.out" 2>&1 &
A2=$!; PIDS+=("$A2")
wait_for 10 has_ticket waiter-A && pass "A's re-issued acquire queued" || fail "A re-acquire never queued"
A_MT="$(mt "$(ticket_of waiter-A)")"
check "A's new ticket carries the ORIGINAL enqueue time" "$A_MT" "$T_ORIG"
[ "$A_MT" -lt "$B_MT" ] && pass "A ranks ahead of B (ticket $A_MT < $B_MT)" || fail "A $A_MT not older than B $B_MT"
[ -f "$S/k1" ] && [ "$(mt "$S/k1")" = "$T_ORIG" ] && pass "existing K never rewritten (mtime unchanged)" || fail "K rewritten or gone"

# Release the foreign holder: A (older ticket) must win, B must keep waiting.
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
lock_is_A() { [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$SLP_A" ]; }
wait_for 15 lock_is_A \
  && pass "A acquired the slot first (lock pid == A's owner)" || fail "lock pid is '$(cat "$LOCK/pid" 2>/dev/null)', expected A ($SLP_A); B.out=$(cat "$TMP/B.out")"
kill -0 "$B" 2>/dev/null && pass "B is still waiting behind A" || fail "B finished before A released"
wait "$A2" 2>/dev/null
check "A's re-acquire exits 0" "$?" "0"
[ ! -e "$S/k1" ] && [ ! -e "$S/k1.last" ] && pass "seniority files removed once the slot was acquired" \
  || fail "seniority files left behind: $(ls "$S" 2>&1)"
"$SLOT" release --owner "$SLP_A"
wait "$B" 2>/dev/null
check "after A releases, B runs and exits 0" "$?" "0"
kill "$SLP_A" 2>/dev/null

# === 2: stale expiry ==========================================================
echo "group 2 — stale expiry"
new_env
mkdir -p "$S"
# same key, ancient: must be ignored (not applied) and re-recorded fresh
: > "$S/stale"; : > "$S/stale.last"; stamp 100000 "$S/stale"; stamp 100000 "$S/stale.last"
# other key, ancient: must be pruned by any keyed acquire
: > "$S/other"; : > "$S/other.last"; stamp 100000 "$S/other"; stamp 100000 "$S/other.last"
# other key, fresh: must survive
: > "$S/fresh"; : > "$S/fresh.last"
SLP_S=$(sleep 300 >/dev/null 2>&1 & echo $!); PIDS+=("$SLP_S")
CPU_SLOT_LABEL=waiter-S bounded 60 "$SLOT" acquire --owner "$SLP_S" --max-wait 3 --seniority-key stale >/dev/null 2>&1 &
S1=$!; PIDS+=("$S1")
wait_for 10 has_ticket waiter-S && pass "stale-key acquire queued" || fail "stale-key acquire never queued"
S_MT="$(mt "$(ticket_of waiter-S)")"
now="$(date +%s)"
[ "$S_MT" -ge $((now - 15)) ] && pass "stale K ignored: ticket mtime is fresh ($S_MT), not the ancient one" || fail "ticket mtime $S_MT looks inherited from the stale key (now $now)"
[ ! -e "$S/other" ] && [ ! -e "$S/other.last" ] && pass "other stale pair pruned" || fail "stale pair 'other' not pruned"
[ -e "$S/fresh" ] && [ -e "$S/fresh.last" ] && pass "fresh pair left alone" || fail "fresh pair pruned"
wait "$S1" 2>/dev/null
check "stale-key acquire times out → 75" "$?" "75"
[ "$(mt "$S/stale")" -ge $((now - 15)) ] && pass "stale key re-recorded with a fresh enqueue time" || fail "stale K mtime still ancient: $(mt "$S/stale")"
kill "$HOLDER" "$SLP_S" 2>/dev/null

# === 3: no key = old behaviour ================================================
echo "group 3 — no key"
new_env
mkdir -p "$S"
: > "$S/k"; : > "$S/k.last"; stamp 600 "$S/k"   # an entry that a keyless acquire must not use
K_MT="$(mt "$S/k")"
SLP_N=$(sleep 300 >/dev/null 2>&1 & echo $!); PIDS+=("$SLP_N")
CPU_SLOT_LABEL=waiter-N bounded 60 "$SLOT" acquire --owner "$SLP_N" --max-wait 3 >/dev/null 2>&1 &
N1=$!; PIDS+=("$N1")
wait_for 10 has_ticket waiter-N && pass "keyless acquire queued" || fail "keyless acquire never queued"
N_MT="$(mt "$(ticket_of waiter-N)")"
now="$(date +%s)"
[ "$N_MT" -ge $((now - 15)) ] && pass "keyless ticket has a fresh mtime ($N_MT)" || fail "keyless ticket mtime $N_MT (now $now)"
wait "$N1" 2>/dev/null
check "keyless acquire times out → 75" "$?" "75"
check "existing seniority entry untouched by a keyless acquire" "$(mt "$S/k")" "$K_MT"
check "seniority dir holds only the pre-existing pair" "$(ls "$S" | tr '\n' ' ')" "k k.last "
kill "$HOLDER" "$SLP_N" 2>/dev/null

new_env
SLP_M=$(sleep 300 >/dev/null 2>&1 & echo $!); PIDS+=("$SLP_M")
CPU_SLOT_LABEL=waiter-M bounded 20 "$SLOT" acquire --owner "$SLP_M" --max-wait 1 >/dev/null 2>&1
check "keyless timeout → 75" "$?" "75"
[ ! -e "$S" ] && pass "keyless timeout creates no seniority dir" || fail "seniority dir created: $(ls "$S")"
kill "$HOLDER" "$SLP_M" 2>/dev/null

# === 4: key sanitizing ========================================================
echo "group 4 — key sanitizing"
new_env
SLP_Z=$(sleep 300 >/dev/null 2>&1 & echo $!); PIDS+=("$SLP_Z")
CPU_SLOT_LABEL=waiter-Z bounded 20 "$SLOT" acquire --owner "$SLP_Z" --max-wait 1 --seniority-key 'a/b c*d.e-f_g' >/dev/null 2>&1
check "sanitized-key acquire times out → 75" "$?" "75"
check "key chars outside [A-Za-z0-9._-] become '_'" "$(ls "$S" | tr '\n' ' ')" "a_b_c_d.e-f_g a_b_c_d.e-f_g.last "
kill "$HOLDER" "$SLP_Z" 2>/dev/null

echo
if [ "$fails" -eq 0 ]; then
  echo "cpu-slot-seniority: all assertions passed"
  exit 0
fi
echo "cpu-slot-seniority: $fails assertion(s) failed"
exit 1
