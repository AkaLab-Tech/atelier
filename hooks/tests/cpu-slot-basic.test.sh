#!/usr/bin/env bash
#
# Regression test for #490 (#475a) — scripts/atelier-cpu-slot, basic behaviour.
#
#   Group 1 — run mode: runs the command, takes and releases the slot
#   Group 2 — --status: free, then held (pid/label/cmd)
#   Group 3 — exit-code passthrough (0, 7) and usage error (2)
#   Group 4 — nesting via CPU_SLOT_HELD runs directly, no deadlock
#   Group 5 — --wait: exit 0 when free, exit 0 once the holder ends (slot is
#             NOT taken), exit 75 on timeout with holder/load/cores on stderr
#   Group 6 — with the slot as a single seat, two contenders never overlap
#
# Hermetic: every case uses its own temp CPU_SLOT_DIR (never /tmp/cpu-slot.lock),
# short polls and timeouts, and kills every process it starts.
#
# Run:  hooks/tests/cpu-slot-basic.test.sh
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cpu-slot-basic.XXXXXX")"
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && kill -9 "$p" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

new_dir() { local d; d="$(mktemp -d "$TMP/case.XXXXXX")"; echo "$d"; }

# bounded <seconds> cmd... — run with a SIGALRM watchdog so a hang fails, not blocks.
bounded() {
  local s=$1; shift
  perl -e 'alarm shift; exec @ARGV' "$s" "$@"
}

# wait_held <dir> — wait (max ~5 s) until the lock has its cmd file (written last).
wait_held() {
  local i=0
  while [ ! -f "$1/cpu-slot.lock/cmd" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -f "$1/cpu-slot.lock/cmd" ]
}

export CPU_SLOT_POLL=1
export CPU_SLOT_FAKE_LOAD=0   # load is informational only (#524); fake it so output is deterministic
unset CPU_SLOT_HELD

# ---------------------------------------------------------------------------
echo "Group 1 — run mode"
D="$(new_dir)"
out="$(CPU_SLOT_DIR="$D" bounded 10 "$SLOT" echo hello 2>&1)"
check "runs the command and prints its output" "$out" "hello"
[ ! -e "$D/cpu-slot.lock" ] && pass "slot released after the command" || fail "slot still present after run"
out="$(CPU_SLOT_DIR="$D" CPU_SLOT_LABEL=lbl bounded 10 "$SLOT" bash -c 'cat "$CPU_SLOT_DIR/cpu-slot.lock/label"; echo "$CPU_SLOT_HELD"; cat "$CPU_SLOT_DIR/cpu-slot.lock/pid"' 2>&1)"
lbl="$(echo "$out" | sed -n 1p)"; held="$(echo "$out" | sed -n 2p)"; lpid="$(echo "$out" | sed -n 3p)"
check "lock carries the label while held" "$lbl" "lbl"
[ -n "$held" ] && [ "$held" = "$lpid" ] && pass "CPU_SLOT_HELD equals the lock pid" || fail "CPU_SLOT_HELD ('$held') != lock pid ('$lpid')"
[ ! -e "$D/cpu-slot.lock" ] && pass "slot released after second run" || fail "slot still present after second run"
[ -z "$(ls -A "$D/cpu-slot.queue" 2>/dev/null)" ] && pass "no ticket left behind" || fail "ticket left behind"

# ---------------------------------------------------------------------------
echo "Group 2 — --status"
D="$(new_dir)"
out="$(CPU_SLOT_DIR="$D" bounded 10 "$SLOT" --status 2>&1 | head -1)"
check "free when nothing holds the slot" "$out" "free"
CPU_SLOT_DIR="$D" CPU_SLOT_LABEL="status-lbl" "$SLOT" sleep 30 &
hp=$!; PIDS+=("$hp")
if wait_held "$D"; then
  out="$(CPU_SLOT_DIR="$D" bounded 10 "$SLOT" --status 2>&1)"
  contains "status shows holder pid" "$out" "held by pid $hp"
  contains "status shows label" "$out" "[status-lbl]"
  contains "status shows the held command" "$out" "  sleep 30"
else
  fail "holder never took the slot"
fi
kill "$(pgrep -P "$hp" | head -1)" 2>/dev/null
wait "$hp" 2>/dev/null
out="$(CPU_SLOT_DIR="$D" bounded 10 "$SLOT" --status 2>&1 | head -1)"
check "free again after the holder ends" "$out" "free"

# ---------------------------------------------------------------------------
echo "Group 3 — exit codes"
D="$(new_dir)"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" true; check "exit 0 passes through" "$?" "0"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" bash -c 'exit 7'; check "exit 7 passes through" "$?" "7"
[ ! -e "$D/cpu-slot.lock" ] && pass "slot released after a failing command" || fail "slot held after failing command"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" 2>/dev/null; check "no arguments is a usage error (2)" "$?" "2"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" --wait --bogus 2>/dev/null; check "--wait with unknown arg is a usage error (2)" "$?" "2"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" --wait --timeout abc 2>/dev/null; check "--wait with non-numeric timeout is a usage error (2)" "$?" "2"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" acquire 2>/dev/null; check "acquire without --owner is a usage error (2)" "$?" "2"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" release 2>/dev/null; check "release without --owner is a usage error (2)" "$?" "2"

# ---------------------------------------------------------------------------
echo "Group 4 — nesting (CPU_SLOT_HELD)"
D="$(new_dir)"
out="$(CPU_SLOT_DIR="$D" bounded 15 "$SLOT" bash -c "\"$SLOT\" echo inner" 2>&1)"
rc=$?
check "nested call runs the command directly (exit)" "$rc" "0"
check "nested call prints the inner output without waiting" "$out" "inner"
[ ! -e "$D/cpu-slot.lock" ] && pass "slot released after nested run" || fail "slot held after nested run"

# ---------------------------------------------------------------------------
echo "Group 5 — --wait"
D="$(new_dir)"
CPU_SLOT_DIR="$D" bounded 10 "$SLOT" --wait --timeout 2; check "--wait on a free slot exits 0" "$?" "0"
[ ! -e "$D/cpu-slot.lock" ] && pass "--wait does not take the slot" || fail "--wait took the slot"

D="$(new_dir)"
CPU_SLOT_DIR="$D" CPU_SLOT_LABEL="busy" "$SLOT" sleep 30 &
hp=$!; PIDS+=("$hp")
if wait_held "$D"; then
  err="$(CPU_SLOT_DIR="$D" CPU_SLOT_FAKE_LOAD=3.5 CPU_SLOT_FAKE_CORES=12 bounded 15 "$SLOT" --wait --timeout 1 2>&1 >/dev/null)"
  rc=$?
  check "--wait times out with exit 75" "$rc" "75"
  contains "timeout names the holder pid" "$err" "held by pid $hp"
  contains "timeout names the holder label" "$err" "[busy]"
  contains "timeout reports load and cores" "$err" "load 3.5 on 12 cores"
  [ -d "$D/cpu-slot.lock" ] && pass "holder keeps the slot after a --wait timeout" || fail "--wait timeout disturbed the slot"
else
  fail "holder never took the slot"
fi
kill "$(pgrep -P "$hp" | head -1)" 2>/dev/null
wait "$hp" 2>/dev/null

# --wait returns 0 once the holder finishes, without taking the slot.
D="$(new_dir)"
CPU_SLOT_DIR="$D" "$SLOT" sleep 2 &
hp=$!; PIDS+=("$hp")
if wait_held "$D"; then
  CPU_SLOT_DIR="$D" bounded 20 "$SLOT" --wait --timeout 15
  check "--wait exits 0 once the holder ends" "$?" "0"
  [ ! -e "$D/cpu-slot.lock" ] && pass "slot is free after --wait returned (not taken)" || fail "slot present after --wait returned"
else
  fail "holder never took the slot"
fi
wait "$hp" 2>/dev/null

# ---------------------------------------------------------------------------
echo "Group 6 — two contenders never overlap"
D="$(new_dir)"
LOG="$D/log"
JOB="$D/job.sh"
cat > "$JOB" <<'EOF'
#!/usr/bin/env bash
echo "start $1" >> "$LOG"
sleep 0.5
echo "end $1" >> "$LOG"
EOF
chmod +x "$JOB"
export LOG
CPU_SLOT_DIR="$D" bounded 30 "$SLOT" "$JOB" A & pa=$!; PIDS+=("$pa")
CPU_SLOT_DIR="$D" bounded 30 "$SLOT" "$JOB" B & pb=$!; PIDS+=("$pb")
wait "$pa"; ra=$?
wait "$pb"; rb=$?
check "contender A exits 0" "$ra" "0"
check "contender B exits 0" "$rb" "0"
seq="$(awk '{print $1}' "$LOG" | tr '\n' ' ')"
check "log alternates start/end (no overlap)" "$seq" "start end start end "
who="$(awk '{print $2}' "$LOG" | tr '\n' ' ')"
case "$who" in "A A B B "|"B B A A ") pass "each job's start and end are adjacent" ;; *) fail "interleaved jobs: $who" ;; esac
[ ! -e "$D/cpu-slot.lock" ] && pass "slot free at the end" || fail "slot held at the end"
unset LOG

# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "cpu-slot-basic (#490): all assertions passed."
  exit 0
else
  echo "cpu-slot-basic (#490): $fails assertion(s) failed."
  exit 1
fi
