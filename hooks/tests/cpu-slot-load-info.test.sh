#!/usr/bin/env bash
#
# Regression test for #524 (supersedes the #491 load-wait test) —
# scripts/atelier-cpu-slot no longer gates on machine load.
#
#   Group 1 — high load with a free slot never waits: --wait rc 0, run mode
#             runs the command, acquire --max-wait 1 succeeds
#   Group 2 — --status shows load as informational and never as a threshold
#   Group 3 — max precedence (env over config) is unchanged
#   Group 4 — legacy loadFactor / loadThreshold keys: one warning, no gating
#   Group 5 — configuration fallbacks: missing file, invalid JSON, invalid values
#   Group 6 — status: unslotted vitest and the queue
#   Group 7 — a timeout caused by queue position alone names the oldest ticket
#
# Hermetic: temp CPU_SLOT_DIR and ATELIER_CONFIG_DIR per case, fake load and
# cores, short polls and timeouts, every child is killed.
#
# Run:  hooks/tests/cpu-slot-load-info.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

# shellcheck disable=SC2015,SC2329 # `A && pass || fail` idiom; trap-invoked cleanup
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
lacks() { # lacks <label> <haystack> <needle>
  case "$2" in *"$3"*) fail "$1 (unexpected '$3' in: $2)" ;; *) pass "$1" ;; esac
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cpu-slot-load.XXXXXX")"
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

# status <slot-dir> <config-dir> — merged stdout+stderr of --status.
status() {
  CPU_SLOT_DIR="$1" ATELIER_CONFIG_DIR="$2" bounded 10 "$SLOT" --status 2>&1
}
# write_cfg <config-dir> <json> — write cpu-slot.json.
write_cfg() { mkdir -p "$1"; printf '%s\n' "$2" > "$1/cpu-slot.json"; }

export CPU_SLOT_POLL=1
unset CPU_SLOT_HELD CPU_SLOT_MAX CPU_SLOT_LOAD_FACTOR CPU_SLOT_CORES CPU_SLOT_LOAD_THRESHOLD CPU_SLOT_FAKE_CORES CPU_SLOT_FAKE_VITEST
export CPU_SLOT_FAKE_LOAD=1

HAVE_JQ=1
command -v jq >/dev/null 2>&1 || HAVE_JQ=0

# ---------------------------------------------------------------------------
echo "Group 1 — high load with a free slot never waits"
D="$(new_dir)"; C="$(new_dir)"
export CPU_SLOT_FAKE_CORES=4 CPU_SLOT_FAKE_LOAD=99   # load 99 on 4 cores
t0=$(date +%s)
CPU_SLOT_DIR="$D" ATELIER_CONFIG_DIR="$C" bounded 15 "$SLOT" --wait --timeout 5 >/dev/null 2>&1
rc=$?
t1=$(date +%s)
check "--wait at load 99 with a free slot exits 0" "$rc" "0"
[ $((t1 - t0)) -lt 3 ] && pass "--wait returned at once (no polling for load)" || fail "--wait took $((t1 - t0)) s"
[ ! -e "$D/cpu-slot.lock" ] && pass "--wait took no slot" || fail "--wait took a slot"

out="$(CPU_SLOT_DIR="$D" ATELIER_CONFIG_DIR="$C" bounded 15 "$SLOT" echo ran-under-load 2>&1)"
check "run mode at load 99 runs the command" "$out" "ran-under-load"
[ ! -e "$D/cpu-slot.lock" ] && pass "slot released after the run" || fail "slot left behind"

err="$(CPU_SLOT_DIR="$D" ATELIER_CONFIG_DIR="$C" bounded 15 "$SLOT" acquire --owner "$$" --max-wait 1 2>&1)"
rc=$?
check "acquire --max-wait 1 at load 99 succeeds" "$rc" "0"
lacks "acquire does not announce waiting for load" "$err" "waiting for load"
[ -e "$D/cpu-slot.lock" ] && pass "acquire took the slot" || fail "acquire did not take the slot"
CPU_SLOT_DIR="$D" ATELIER_CONFIG_DIR="$C" bounded 10 "$SLOT" release --owner "$$" >/dev/null 2>&1
[ ! -e "$D/cpu-slot.lock" ] && pass "release freed the slot" || fail "slot left after release"
unset CPU_SLOT_FAKE_CORES; export CPU_SLOT_FAKE_LOAD=1

# ---------------------------------------------------------------------------
echo "Group 2 — --status: load is informational"
D="$(new_dir)"; C="$(new_dir)"
out="$(CPU_SLOT_FAKE_CORES=6 CPU_SLOT_FAKE_LOAD=3 status "$D" "$C")"
contains "status load line is marked informational" "$out" "load: 3 on 6 cores (CPU_SLOT_FAKE_CORES) - informational, not a gate"
lacks "status never mentions a threshold" "$out" "threshold"
real="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
out="$(status "$D" "$C")"
contains "detected cores are shown when nothing overrides them" "$out" "load: 1 on $real cores (detected) - informational, not a gate"
out="$(CPU_SLOT_CORES=4 status "$D" "$C")"
contains "CPU_SLOT_CORES is shown with its source" "$out" "on 4 cores (CPU_SLOT_CORES)"

# ---------------------------------------------------------------------------
echo "Group 3 — max precedence"
if [ "$HAVE_JQ" -eq 1 ]; then
  D="$(new_dir)"; C="$(new_dir)"
  write_cfg "$C" '{"max":2}'
  out="$(status "$D" "$C")"
  contains "config max is read" "$out" "slots: max 2 (cpu-slot.json max)"
  out="$(CPU_SLOT_MAX=3 status "$D" "$C")"
  contains "env max beats config max" "$out" "slots: max 3 (CPU_SLOT_MAX)"
  write_cfg "$C" '{"cores":16}'
  out="$(status "$D" "$C")"
  contains "config cores are used" "$out" "on 16 cores (cpu-slot.json cores)"
  out="$(CPU_SLOT_CORES=4 status "$D" "$C")"
  contains "env cores beat config cores" "$out" "on 4 cores (CPU_SLOT_CORES)"
else
  echo "  SKIP: jq not installed, config-file precedence not checked"
fi

# ---------------------------------------------------------------------------
echo "Group 4 — legacy loadFactor / loadThreshold keys are ignored with one warning"
if [ "$HAVE_JQ" -eq 1 ]; then
  D="$(new_dir)"; C="$(new_dir)"
  write_cfg "$C" '{"max":1,"loadFactor":0.5,"loadThreshold":2}'
  out="$(CPU_SLOT_FAKE_CORES=8 CPU_SLOT_FAKE_LOAD=99 status "$D" "$C")"
  contains "both legacy keys: one combined warning" "$out" "atelier-cpu-slot: warning: ignoring cpu-slot.json loadFactor,loadThreshold: cpu-slot no longer gates on load (#524)"
  check "both legacy keys: exactly one warning line" "$(printf '%s\n' "$out" | grep -c 'no longer gates on load')" "1"
  lacks "legacy keys: status shows no threshold" "$out" "threshold"
  contains "legacy keys: max still read" "$out" "slots: max 1 (cpu-slot.json max)"
  err="$(CPU_SLOT_FAKE_CORES=8 CPU_SLOT_FAKE_LOAD=99 CPU_SLOT_DIR="$D" ATELIER_CONFIG_DIR="$C" bounded 10 "$SLOT" --wait --timeout 1 2>&1 >/dev/null)"
  rc=$?
  check "legacy keys: --wait at load 99 still exits 0 (no gating)" "$rc" "0"
  contains "legacy keys: --wait warns on stderr" "$err" "no longer gates on load"
  out="$(CPU_SLOT_FAKE_CORES=8 CPU_SLOT_FAKE_LOAD=99 CPU_SLOT_DIR="$D" ATELIER_CONFIG_DIR="$C" bounded 10 "$SLOT" echo still-runs 2>/dev/null)"
  check "legacy keys: run mode runs the command at load 99" "$out" "still-runs"

  write_cfg "$C" '{"loadFactor":0.5}'
  out="$(status "$D" "$C")"
  contains "only loadFactor: warning names just that key" "$out" "ignoring cpu-slot.json loadFactor: cpu-slot no longer gates on load (#524)"
  write_cfg "$C" '{"loadThreshold":2}'
  out="$(status "$D" "$C")"
  contains "only loadThreshold: warning names just that key" "$out" "ignoring cpu-slot.json loadThreshold: cpu-slot no longer gates on load (#524)"
  write_cfg "$C" '{"max":2}'
  out="$(status "$D" "$C")"
  lacks "no legacy keys: no legacy warning" "$out" "no longer gates on load"
else
  echo "  SKIP: jq not installed, legacy keys not checked"
fi

# ---------------------------------------------------------------------------
echo "Group 5 — configuration fallbacks"
D="$(new_dir)"; C="$(new_dir)"
out="$(CPU_SLOT_FAKE_CORES=8 status "$D" "$C")"
contains "missing config: max 1 (default)" "$out" "slots: max 1 (default)"
lacks "missing config: no warning" "$out" "warning"

if [ "$HAVE_JQ" -eq 1 ]; then
  write_cfg "$C" '{ this is not json'
  out="$(CPU_SLOT_FAKE_CORES=8 status "$D" "$C")"
  contains "invalid JSON: warning on stderr" "$out" "atelier-cpu-slot: warning: $C/cpu-slot.json is not valid JSON, using defaults"
  contains "invalid JSON: max falls back to 1" "$out" "slots: max 1 (default)"
  err="$(CPU_SLOT_FAKE_CORES=8 CPU_SLOT_DIR="$D" ATELIER_CONFIG_DIR="$C" bounded 10 "$SLOT" --wait --timeout 1 2>&1 >/dev/null)"
  rc=$?
  check "invalid JSON: --wait still works on defaults (0)" "$rc" "0"
  contains "invalid JSON: --wait warns on stderr" "$err" "is not valid JSON"
  out="$(CPU_SLOT_FAKE_CORES=8 CPU_SLOT_DIR="$D" ATELIER_CONFIG_DIR="$C" bounded 10 "$SLOT" echo still-runs 2>/dev/null)"
  check "invalid JSON: run mode still runs the command" "$out" "still-runs"

  write_cfg "$C" '{"max":"abc"}'
  out="$(CPU_SLOT_FAKE_CORES=8 status "$D" "$C")"
  contains "invalid max value: warning" "$out" "ignoring invalid cpu-slot.json max 'abc'"
  contains "invalid max value: default applies" "$out" "slots: max 1 (default)"
fi
D="$(new_dir)"; C="$(new_dir)"
out="$(CPU_SLOT_FAKE_CORES=8 CPU_SLOT_MAX=0 status "$D" "$C")"
contains "invalid env max: warning" "$out" "ignoring invalid CPU_SLOT_MAX '0'"
contains "invalid env max: default applies" "$out" "slots: max 1 (default)"

# ---------------------------------------------------------------------------
echo "Group 6 — status: unslotted vitest and the queue"
D="$(new_dir)"; C="$(new_dir)"
out="$(CPU_SLOT_FAKE_VITEST=3 status "$D" "$C")"
contains "status reports the unslotted vitest count" "$out" "vitest outside the slot: 3"
out="$(CPU_SLOT_FAKE_VITEST=0 status "$D" "$C")"
contains "status reports zero vitest" "$out" "vitest outside the slot: 0"
sleep 60 & SLP=$!; PIDS+=("$SLP")
mkdir -p "$D/cpu-slot.queue"
echo "pid $SLP [queued] make build" > "$D/cpu-slot.queue/$SLP"
out="$(status "$D" "$C")"
contains "status lists the queue" "$out" "waiting: pid $SLP [queued] make build"
contains "status has the load line" "$out" "load: 1 on "

# ---------------------------------------------------------------------------
echo "Group 7 — a queue-position timeout names the oldest ticket"
D="$(new_dir)"; C="$(new_dir)"
export CPU_SLOT_FAKE_CORES=4 CPU_SLOT_FAKE_LOAD=99
sleep 60 & AHEAD=$!; PIDS+=("$AHEAD")
mkdir -p "$D/cpu-slot.queue"
echo "pid $AHEAD [older-waiter] make build" > "$D/cpu-slot.queue/$AHEAD"
touch -t 202001010000 "$D/cpu-slot.queue/$AHEAD"
err="$(CPU_SLOT_DIR="$D" ATELIER_CONFIG_DIR="$C" bounded 15 "$SLOT" acquire --owner 999999 --max-wait 2 2>&1)"
rc=$?
check "slot free but a live older ticket: acquire exits 75 at its max-wait" "$rc" "75"
contains "timeout names the queue position and the oldest label" "$err" "1 ahead in the queue (oldest: pid $AHEAD [older-waiter])"
lacks "timeout does not blame the load" "$err" "load above"
lacks "timeout reports no threshold" "$err" "threshold"
contains "timeout line 2 shows load as informational" "$err" "load 99 on 4 cores (informational)"
[ ! -e "$D/cpu-slot.lock" ] && pass "no slot was taken behind the older ticket" || fail "slot taken out of order"
unset CPU_SLOT_FAKE_CORES; export CPU_SLOT_FAKE_LOAD=1

# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "cpu-slot-load-info (#524): all assertions passed."
  exit 0
else
  echo "cpu-slot-load-info (#524): $fails assertion(s) failed."
  exit 1
fi
