#!/usr/bin/env bash
#
# Regression test for #491 (#475b) — scripts/atelier-cpu-slot, N slots.
#
#   Group 1 — max 1 (default): two contenders never overlap, status says max 1
#   Group 2 — max 2: two jobs hold slot 0 and slot 1 at once, a third waits
#             and runs as soon as one is released; status shows both slots
#   Group 3 — FIFO: waiters are served by ticket mtime (oldest first)
#   Group 4 — interop: a loose-layout holder on slot 0 coexists with slot 1,
#             and CPU_SLOT_HELD is honoured on any slot
#   Group 5 — acquire/release --owner with max 2
#
# Hermetic: temp CPU_SLOT_DIR per case (never /tmp/cpu-slot.lock), no real
# config (ATELIER_CONFIG_DIR points at an empty dir), fake load and cores so
# load output is deterministic (load never gates, #524), short polls and timeouts.
#
# Run:  hooks/tests/cpu-slot-concurrency.test.sh
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cpu-slot-conc.XXXXXX")"
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

# wait_cmd <file> — wait (max ~5 s) until the file exists.
wait_file() {
  local i=0
  while [ ! -f "$1" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -f "$1" ]
}

live_sleeper() { sleep 60 & SLP=$!; PIDS+=("$SLP"); }

mkdir -p "$TMP/cfg"
export ATELIER_CONFIG_DIR="$TMP/cfg"          # empty: no cpu-slot.json
export CPU_SLOT_POLL=1
export CPU_SLOT_FAKE_LOAD=0 CPU_SLOT_FAKE_CORES=8
unset CPU_SLOT_HELD CPU_SLOT_MAX CPU_SLOT_LOAD_FACTOR CPU_SLOT_CORES CPU_SLOT_LOAD_THRESHOLD CPU_SLOT_FAKE_VITEST

# A job that holds its slot until $GO exists.
HOLD="$TMP/hold.sh"
cat > "$HOLD" <<'EOF'
#!/usr/bin/env bash
while [ ! -e "$GO" ]; do sleep 0.1; done
EOF
chmod +x "$HOLD"

# ---------------------------------------------------------------------------
echo "Group 1 — max 1: contenders serialise"
D="$(new_dir)"
LOG="$D/log"; export LOG
JOB="$D/job.sh"
cat > "$JOB" <<'EOF'
#!/usr/bin/env bash
echo "start $1" >> "$LOG"
sleep 0.5
echo "end $1" >> "$LOG"
EOF
chmod +x "$JOB"
CPU_SLOT_DIR="$D" bounded 30 "$SLOT" "$JOB" A & pa=$!; PIDS+=("$pa")
CPU_SLOT_DIR="$D" bounded 30 "$SLOT" "$JOB" B & pb=$!; PIDS+=("$pb")
wait "$pa"; ra=$?
wait "$pb"; rb=$?
check "A exits 0" "$ra" "0"
check "B exits 0" "$rb" "0"
check "no overlap with max 1" "$(awk '{print $1}' "$LOG" | tr '\n' ' ')" "start end start end "
[ ! -e "$D/cpu-slot.lock.1" ] && pass "slot 1 is never created with max 1" || fail "slot 1 created with max 1"
out="$(CPU_SLOT_DIR="$D" bounded 10 "$SLOT" --status 2>&1)"
contains "status reports max 1 (default)" "$out" "slots: max 1 (default)"
unset LOG

# ---------------------------------------------------------------------------
echo "Group 2 — max 2: two at once, a third waits"
D="$(new_dir)"
GO="$D/go"; export GO
export CPU_SLOT_MAX=2
CPU_SLOT_DIR="$D" CPU_SLOT_LABEL=ja bounded 40 "$SLOT" "$HOLD" & pa=$!; PIDS+=("$pa")
wait_file "$D/cpu-slot.lock/cmd" || fail "first job never took slot 0"
CPU_SLOT_DIR="$D" CPU_SLOT_LABEL=jb bounded 40 "$SLOT" "$HOLD" & pb=$!; PIDS+=("$pb")
wait_file "$D/cpu-slot.lock.1/cmd" || fail "second job never took slot 1"
[ -d "$D/cpu-slot.lock" ] && [ -d "$D/cpu-slot.lock.1" ] && pass "both slots are held at the same time" || fail "two jobs did not run at once"
pid0="$(cat "$D/cpu-slot.lock/pid" 2>/dev/null)"; pid1="$(cat "$D/cpu-slot.lock.1/pid" 2>/dev/null)"
[ -n "$pid0" ] && [ -n "$pid1" ] && [ "$pid0" != "$pid1" ] && pass "slots have different holder pids" || fail "holder pids: '$pid0' / '$pid1'"

MARK="$D/c-ran"
CPU_SLOT_DIR="$D" CPU_SLOT_LABEL=jc bounded 40 "$SLOT" bash -c "echo ran > '$MARK'" & pc=$!; PIDS+=("$pc")
sleep 2
[ ! -e "$MARK" ] && pass "third job waits while both slots are held" || fail "third job ran with both slots held"
out="$(CPU_SLOT_DIR="$D" bounded 10 "$SLOT" --status 2>&1)"
contains "status shows slot 0" "$out" "slot 0: held by pid $pid0 [ja]"
contains "status shows slot 1" "$out" "slot 1: held by pid $pid1 [jb]"
contains "status lists the waiting third job" "$out" "[jc]"
contains "status reports max 2 from the env" "$out" "slots: max 2 (CPU_SLOT_MAX)"
touch "$GO"
wait "$pc"; check "third job exits 0 once a slot frees" "$?" "0"
[ -e "$MARK" ] && pass "third job ran after a release" || fail "third job never ran"
wait "$pa"; wait "$pb"
[ ! -e "$D/cpu-slot.lock" ] && [ ! -e "$D/cpu-slot.lock.1" ] && pass "both slots free at the end" || fail "slots left behind"
check "no tickets left behind" "$(ls -A "$D/cpu-slot.queue" 2>/dev/null | tr -d '\n')" ""
unset CPU_SLOT_MAX GO

# ---------------------------------------------------------------------------
echo "Group 3 — FIFO by ticket mtime"
D="$(new_dir)"
GO="$D/go"; export GO
LOG="$D/order"; export LOG
CPU_SLOT_DIR="$D" CPU_SLOT_LABEL=holder bounded 40 "$SLOT" "$HOLD" & ph=$!; PIDS+=("$ph")
wait_file "$D/cpu-slot.lock/cmd" || fail "holder never took the slot"
for w in w1 w2 w3; do
  CPU_SLOT_DIR="$D" CPU_SLOT_LABEL="$w" bounded 40 "$SLOT" bash -c 'echo "$0" >> "$LOG"' "$w" &
  PIDS+=("$!")
  # wait for this waiter's ticket before starting the next
  i=0
  while ! grep -l "\[$w\]" "$D/cpu-slot.queue"/* >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
done
# Tickets are second-granular: pin distinct mtimes, w3 oldest, w1 newest.
t=1
for w in w3 w2 w1; do
  tk="$(grep -l "\[$w\]" "$D/cpu-slot.queue"/* 2>/dev/null | head -1)"
  [ -n "$tk" ] && touch -t "20000101000$t" "$tk" || fail "no ticket for $w"
  t=$((t + 1))
done
sleep 1.5
[ ! -e "$LOG" ] && pass "no waiter runs while the holder keeps the slot" || fail "a waiter ran early"
touch "$GO"
i=0
while [ ! -f "$LOG" ] || [ "$(wc -l < "$LOG" | tr -d ' ')" != "3" ]; do
  [ $i -ge 150 ] && break
  sleep 0.2; i=$((i + 1))
done
check "waiters run in ticket-mtime order" "$(tr '\n' ' ' < "$LOG" 2>/dev/null)" "w3 w2 w1 "
wait "$ph"
unset GO LOG

# ---------------------------------------------------------------------------
echo "Group 4 — interop with a loose-layout holder on slot 0"
D="$(new_dir)"
live_sleeper; legacy="$SLP"
mkdir -p "$D/cpu-slot.lock"
echo "$legacy" > "$D/cpu-slot.lock/pid"
echo "loose" > "$D/cpu-slot.lock/label"
echo "10:11:12" > "$D/cpu-slot.lock/since"
echo "pnpm test" > "$D/cpu-slot.lock/cmd"

# max 1: the loose holder blocks everyone.
CPU_SLOT_DIR="$D" bounded 15 "$SLOT" --wait --timeout 1 2>/dev/null
check "max 1: a live loose holder on slot 0 blocks --wait (75)" "$?" "75"

# max 2: slot 1 is still usable next to it.
out="$(CPU_SLOT_MAX=2 CPU_SLOT_DIR="$D" bounded 15 "$SLOT" bash -c 'cat "$CPU_SLOT_DIR/cpu-slot.lock.1/pid" | tr -d "\n"; echo " $$"' 2>&1)"
slot1pid="$(echo "$out" | awk '{print $1}')"
case "$slot1pid" in ''|*[!0-9]*) fail "slot 1 pid not numeric: '$slot1pid'" ;; *) [ "$slot1pid" != "$legacy" ] && pass "slot 1 holder is not the loose holder" || fail "slot 1 pid equals the loose holder" ;; esac
check "loose holder's lock is untouched" "$(cat "$D/cpu-slot.lock/pid" 2>/dev/null)" "$legacy"
[ ! -e "$D/cpu-slot.lock.1" ] && pass "slot 1 released after the job" || fail "slot 1 left behind"
out="$(CPU_SLOT_MAX=2 CPU_SLOT_DIR="$D" bounded 10 "$SLOT" --status 2>&1)"
contains "max 2: status shows the loose holder on slot 0" "$out" "slot 0: held by pid $legacy [loose] since 10:11:12"
contains "max 2: status shows slot 1 free" "$out" "slot 1: free"

# CPU_SLOT_HELD matching a holder on slot 1 runs directly, even at max 1.
live_sleeper; s1="$SLP"
mkdir -p "$D/cpu-slot.lock.1"
echo "$s1" > "$D/cpu-slot.lock.1/pid"
out="$(CPU_SLOT_HELD="$s1" CPU_SLOT_DIR="$D" bounded 10 "$SLOT" echo nested-on-1 2>&1)"
check "CPU_SLOT_HELD on slot 1 runs directly" "$out" "nested-on-1"

# ---------------------------------------------------------------------------
echo "Group 5 — acquire / release --owner with max 2"
D="$(new_dir)"
export CPU_SLOT_MAX=2
live_sleeper; o1="$SLP"; live_sleeper; o2="$SLP"; live_sleeper; o3="$SLP"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" acquire --owner "$o1"; check "first acquire exits 0" "$?" "0"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" acquire --owner "$o2"; check "second acquire exits 0" "$?" "0"
check "owner 1 holds slot 0" "$(cat "$D/cpu-slot.lock/pid" 2>/dev/null)" "$o1"
check "owner 2 holds slot 1" "$(cat "$D/cpu-slot.lock.1/pid" 2>/dev/null)" "$o2"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" acquire --owner "$o3" --max-wait 1 2>/dev/null
check "third acquire times out (75)" "$?" "75"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" release --owner "$o1"; check "release of owner 1 exits 0" "$?" "0"
[ ! -e "$D/cpu-slot.lock" ] && [ -d "$D/cpu-slot.lock.1" ] && pass "release frees only the owner's slot" || fail "release touched the wrong slot"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" acquire --owner "$o3" --max-wait 5; check "acquire succeeds after the release" "$?" "0"
check "owner 3 took the freed slot 0" "$(cat "$D/cpu-slot.lock/pid" 2>/dev/null)" "$o3"
unset CPU_SLOT_MAX

# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "cpu-slot-concurrency (#491): all assertions passed."
  exit 0
else
  echo "cpu-slot-concurrency (#491): $fails assertion(s) failed."
  exit 1
fi
