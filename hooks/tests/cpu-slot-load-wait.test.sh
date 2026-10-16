#!/usr/bin/env bash
#
# Regression test for #491 (#475b) — scripts/atelier-cpu-slot, load gate and
# configuration.
#
#   Group 1 — threshold = cores x factor (fake cores), default factor 1.0,
#             detected cores when nothing overrides them
#   Group 2 — precedence: env over config, loadThreshold over the derived value
#   Group 3 — high load means waiting, not aborting (--wait, acquire, run mode)
#   Group 4 — the gate is strict (load == threshold waits) and open below it
#   Group 5 — missing file = defaults; invalid JSON / invalid values fall back
#             to defaults with a stderr warning
#   Group 6 — --status reports unslotted vitest and the queue
#
# Hermetic: temp CPU_SLOT_DIR and ATELIER_CONFIG_DIR per case, fake load and
# cores, short polls and timeouts, every child is killed.
#
# Run:  hooks/tests/cpu-slot-load-wait.test.sh
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
echo "Group 1 — threshold from cores x factor"
D="$(new_dir)"; C="$(new_dir)"
out="$(CPU_SLOT_FAKE_CORES=6 status "$D" "$C")"
contains "default factor 1.0: threshold equals the cores" "$out" "load: 1 vs threshold 6, 6 cores (CPU_SLOT_FAKE_CORES) x factor 1.0"
out="$(CPU_SLOT_FAKE_CORES=8 CPU_SLOT_LOAD_FACTOR=0.5 status "$D" "$C")"
contains "factor 0.5 on 8 cores: threshold 4" "$out" "vs threshold 4, 8 cores (CPU_SLOT_FAKE_CORES) x factor 0.5"
out="$(CPU_SLOT_CORES=4 CPU_SLOT_LOAD_FACTOR=1.5 status "$D" "$C")"
contains "CPU_SLOT_CORES 4 x factor 1.5: threshold 6" "$out" "vs threshold 6, 4 cores (CPU_SLOT_CORES) x factor 1.5"
# Detected: no hard-coded count, the value comes from the machine.
real="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
out="$(status "$D" "$C")"
contains "detected cores are used when nothing overrides them" "$out" "vs threshold $real, $real cores (detected) x factor 1.0"

# ---------------------------------------------------------------------------
echo "Group 2 — override precedence"
if [ "$HAVE_JQ" -eq 1 ]; then
  D="$(new_dir)"; C="$(new_dir)"
  write_cfg "$C" '{"max":1,"loadFactor":0.5}'
  out="$(CPU_SLOT_FAKE_CORES=8 status "$D" "$C")"
  contains "config loadFactor 0.5 gives threshold 4" "$out" "vs threshold 4, 8 cores (CPU_SLOT_FAKE_CORES) x factor 0.5"
  out="$(CPU_SLOT_FAKE_CORES=4 CPU_SLOT_LOAD_FACTOR=2 status "$D" "$C")"
  contains "env loadFactor beats config loadFactor" "$out" "vs threshold 8, 4 cores (CPU_SLOT_FAKE_CORES) x factor 2"

  write_cfg "$C" '{"cores":16,"loadFactor":0.5}'
  out="$(status "$D" "$C")"
  contains "config cores are used" "$out" "vs threshold 8, 16 cores (cpu-slot.json cores) x factor 0.5"
  out="$(CPU_SLOT_CORES=4 status "$D" "$C")"
  contains "env cores beat config cores" "$out" "vs threshold 2, 4 cores (CPU_SLOT_CORES) x factor 0.5"

  write_cfg "$C" '{"loadThreshold":2.5}'
  out="$(CPU_SLOT_FAKE_CORES=8 status "$D" "$C")"
  contains "config loadThreshold beats cores x factor" "$out" "vs threshold 2.5, override (cpu-slot.json loadThreshold)"
  out="$(CPU_SLOT_FAKE_CORES=8 CPU_SLOT_LOAD_THRESHOLD=7 status "$D" "$C")"
  contains "env loadThreshold beats config loadThreshold" "$out" "vs threshold 7, override (CPU_SLOT_LOAD_THRESHOLD)"

  write_cfg "$C" '{"max":2}'
  out="$(status "$D" "$C")"
  contains "config max is read" "$out" "slots: max 2 (cpu-slot.json max)"
  out="$(CPU_SLOT_MAX=3 status "$D" "$C")"
  contains "env max beats config max" "$out" "slots: max 3 (CPU_SLOT_MAX)"
else
  echo "  SKIP: jq not installed, config-file precedence not checked"
fi
D="$(new_dir)"; C="$(new_dir)"
out="$(CPU_SLOT_FAKE_CORES=8 CPU_SLOT_LOAD_THRESHOLD=7 status "$D" "$C")"
contains "env loadThreshold beats cores x factor" "$out" "vs threshold 7, override (CPU_SLOT_LOAD_THRESHOLD)"

# ---------------------------------------------------------------------------
echo "Group 3 — high load waits, it does not abort"
D="$(new_dir)"; C="$(new_dir)"
export CPU_SLOT_FAKE_CORES=4 CPU_SLOT_FAKE_LOAD=9   # threshold 4, load 9
t0=$(date +%s)
err="$(CPU_SLOT_DIR="$D" ATELIER_CONFIG_DIR="$C" bounded 15 "$SLOT" --wait --timeout 2 2>&1 >/dev/null)"
rc=$?
t1=$(date +%s)
check "--wait under high load exits 75 at its timeout" "$rc" "75"
[ $((t1 - t0)) -ge 1 ] && pass "--wait kept waiting instead of failing at once" || fail "--wait returned after $((t1 - t0)) s"
contains "timeout says the load is above the threshold" "$err" "load above threshold"
contains "timeout reports load, cores and threshold" "$err" "load 9 on 4 cores (threshold 4)"
[ ! -e "$D/cpu-slot.lock" ] && pass "--wait took no slot" || fail "--wait took a slot under high load"

t0=$(date +%s)
err="$(CPU_SLOT_DIR="$D" ATELIER_CONFIG_DIR="$C" bounded 15 "$SLOT" acquire --owner 999999 --max-wait 2 2>&1)"
rc=$?
t1=$(date +%s)
check "acquire under high load exits 75 at its max-wait" "$rc" "75"
[ $((t1 - t0)) -ge 1 ] && pass "acquire kept waiting instead of failing at once" || fail "acquire returned after $((t1 - t0)) s"
contains "acquire announces it waits for the load" "$err" "waiting for load to drop (load 9, threshold 4)"
[ ! -e "$D/cpu-slot.lock" ] && pass "acquire took no slot" || fail "acquire took a slot under high load"
check "acquire left no ticket" "$(ls -A "$D/cpu-slot.queue" 2>/dev/null | tr -d '\n')" ""

# Run mode: waits (command does not run), keeps its ticket, then is stopped.
MARK="$D/ran"
CPU_SLOT_DIR="$D" ATELIER_CONFIG_DIR="$C" "$SLOT" bash -c "echo ran > '$MARK'" 2>"$D/err" &
wp=$!; PIDS+=("$wp")
sleep 2
[ ! -e "$MARK" ] && pass "run mode does not run the command under high load" || fail "command ran under high load"
[ ! -e "$D/cpu-slot.lock" ] && pass "run mode holds no slot while waiting for the load" || fail "slot taken under high load"
[ -e "$D/cpu-slot.queue/$wp" ] && pass "waiting run mode keeps its ticket" || fail "no ticket for the waiting run"
contains "run mode announces it waits for the load" "$(cat "$D/err")" "waiting for load to drop"
kill "$wp" 2>/dev/null
wait "$wp" 2>/dev/null
[ ! -e "$D/cpu-slot.queue/$wp" ] && pass "ticket removed when the waiter is stopped" || fail "ticket left after the waiter was stopped"

# ---------------------------------------------------------------------------
echo "Group 4 — the gate is strict and opens below the threshold"
D="$(new_dir)"; C="$(new_dir)"
export CPU_SLOT_FAKE_CORES=4
CPU_SLOT_FAKE_LOAD=4 CPU_SLOT_DIR="$D" ATELIER_CONFIG_DIR="$C" bounded 15 "$SLOT" --wait --timeout 1 2>/dev/null
check "load equal to the threshold waits (75)" "$?" "75"
CPU_SLOT_FAKE_LOAD=3.99 CPU_SLOT_DIR="$D" ATELIER_CONFIG_DIR="$C" bounded 15 "$SLOT" --wait --timeout 1
check "load just below the threshold passes (0)" "$?" "0"
out="$(CPU_SLOT_FAKE_LOAD=0.5 CPU_SLOT_DIR="$D" ATELIER_CONFIG_DIR="$C" bounded 15 "$SLOT" echo through 2>&1)"
check "run mode runs at low load" "$out" "through"
[ ! -e "$D/cpu-slot.lock" ] && pass "slot released after the run" || fail "slot left behind"
export CPU_SLOT_FAKE_LOAD=1; unset CPU_SLOT_FAKE_CORES

# ---------------------------------------------------------------------------
echo "Group 5 — configuration fallbacks"
D="$(new_dir)"; C="$(new_dir)"
out="$(CPU_SLOT_FAKE_CORES=8 status "$D" "$C")"
contains "missing config: max 1 (default)" "$out" "slots: max 1 (default)"
contains "missing config: threshold is cores x 1.0" "$out" "vs threshold 8,"
lacks "missing config: no warning" "$out" "warning"

if [ "$HAVE_JQ" -eq 1 ]; then
  write_cfg "$C" '{ this is not json'
  out="$(CPU_SLOT_FAKE_CORES=8 status "$D" "$C")"
  contains "invalid JSON: warning on stderr" "$out" "atelier-cpu-slot: warning: $C/cpu-slot.json is not valid JSON, using defaults"
  contains "invalid JSON: max falls back to 1" "$out" "slots: max 1 (default)"
  contains "invalid JSON: threshold falls back to cores x 1.0" "$out" "vs threshold 8, 8 cores (CPU_SLOT_FAKE_CORES) x factor 1.0"
  err="$(CPU_SLOT_FAKE_CORES=8 CPU_SLOT_DIR="$D" ATELIER_CONFIG_DIR="$C" bounded 10 "$SLOT" --wait --timeout 1 2>&1 >/dev/null)"
  rc=$?
  check "invalid JSON: --wait still works on defaults (0)" "$rc" "0"
  contains "invalid JSON: --wait warns on stderr" "$err" "is not valid JSON"
  out="$(CPU_SLOT_FAKE_CORES=8 CPU_SLOT_DIR="$D" ATELIER_CONFIG_DIR="$C" bounded 10 "$SLOT" echo still-runs 2>/dev/null)"
  check "invalid JSON: run mode still runs the command" "$out" "still-runs"

  write_cfg "$C" '{"max":"abc","loadFactor":-1,"loadThreshold":"x"}'
  out="$(CPU_SLOT_FAKE_CORES=8 status "$D" "$C")"
  contains "invalid max value: warning" "$out" "ignoring invalid cpu-slot.json max 'abc'"
  contains "invalid loadFactor value: warning" "$out" "ignoring invalid cpu-slot.json loadFactor '-1'"
  contains "invalid loadThreshold value: warning" "$out" "ignoring invalid cpu-slot.json loadThreshold 'x'"
  contains "invalid values: defaults apply" "$out" "slots: max 1 (default)"
  contains "invalid values: threshold derived from cores" "$out" "vs threshold 8, 8 cores (CPU_SLOT_FAKE_CORES) x factor 1.0"
fi
D="$(new_dir)"; C="$(new_dir)"
out="$(CPU_SLOT_FAKE_CORES=8 CPU_SLOT_LOAD_FACTOR=abc CPU_SLOT_MAX=0 status "$D" "$C")"
contains "invalid env factor: warning" "$out" "ignoring invalid CPU_SLOT_LOAD_FACTOR 'abc'"
contains "invalid env max: warning" "$out" "ignoring invalid CPU_SLOT_MAX '0'"
contains "invalid env values: defaults apply" "$out" "slots: max 1 (default)"
contains "invalid env factor: factor 1.0" "$out" "vs threshold 8, 8 cores (CPU_SLOT_FAKE_CORES) x factor 1.0"

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
contains "status has the load line with its source" "$out" "load: 1 vs threshold"

# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "cpu-slot-load-wait (#491): all assertions passed."
  exit 0
else
  echo "cpu-slot-load-wait (#491): $fails assertion(s) failed."
  exit 1
fi
