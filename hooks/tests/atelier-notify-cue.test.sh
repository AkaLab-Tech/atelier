#!/usr/bin/env bash
#
# Regression test for #42 — scripts/atelier-notify-cue (opt-in, best-effort
# audible cue for task-lifecycle events: task-complete / task-blocked).
#
# Coverage:
#   Group A — pref gate OFF/ABSENT: atelier-notify-cue is a silent exit-0
#     no-op and never delegates to atelier-notify, for both cues, whether the
#     flag is explicitly false, the .notification object is absent entirely,
#     or operator.json itself does not exist.
#   Group B — pref gate ON, per-OS default sound: with the flag on and no
#     override, the per-cue default (macOS Hero/Basso, Linux
#     complete.oga/dialog-error.oga, unknown OS -> no --sound at all) is
#     passed to atelier-notify. uname is stubbed so this never depends on the
#     host's real OS.
#   Group C — sound override: a configured taskCompleteSound/taskBlockedSound
#     is passed instead of the per-OS default, even when the override value
#     does not resolve to anything real (delegation, not resolution, is this
#     script's job — resolution failure is atelier-notify's own problem, per
#     #41's notify-player-detection.test.sh Group C).
#   Group D — never hard-fails: missing jq, missing operator.json, malformed
#     operator.json, and a missing atelier-notify binary all still exit 0
#     without ever invoking a player.
#   Group E — invalid/empty cue argument is a silent exit-0 no-op before any
#     config is even read.
#
# Hermetic: every scenario runs a COPY of scripts/atelier-notify-cue in its
# own scratch dir so that _resolve_notify_bin's self-dir lookup finds our
# logging stub (or, for Group D's "missing binary" case, finds nothing) —
# never the real atelier-notify. uname is stubbed on a prepended PATH so
# Group B/C never depend on the host OS. Group D's "missing jq"/"missing
# binary" cases use a curated minimal PATH (real jq/dirname/readlink/uname
# only) so a real, PATH-installed atelier-notify binary on the operator's own
# machine can never leak into the test. No real audio is ever played.
#
# Run:  hooks/tests/atelier-notify-cue.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NOTIFY_CUE_SRC="$REPO_ROOT/scripts/atelier-notify-cue"
REAL_BASH="$(command -v bash)"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# mk_scen <dir> — a fresh scratch dir holding its OWN copy of
# atelier-notify-cue, so _resolve_notify_bin's self-dir check resolves to
# THIS dir (not the real scripts/ dir, which sits right next to the real
# atelier-notify).
mk_scen() {
  local dir="$1"
  mkdir -p "$dir"
  cp "$NOTIFY_CUE_SRC" "$dir/atelier-notify-cue"
  chmod +x "$dir/atelier-notify-cue"
}

# mk_notify_stub <dir> <log-file> — a stub atelier-notify (placed in the
# scenario dir so self-dir resolution finds it first) that logs its argv
# (one line per invocation) and exits 0. Shebangs the real bash by ABSOLUTE
# path so it still runs under a restricted PATH.
mk_notify_stub() {
  local dir="$1" log="$2"
  cat > "$dir/atelier-notify" <<STUB
#!$REAL_BASH
printf '%s\n' "\$*" >> "$log"
exit 0
STUB
  chmod +x "$dir/atelier-notify"
}

# mk_uname_stub <dir> <os-name> — stub uname to report a fixed OS regardless
# of host, placed in a dir meant to be PREPENDED to PATH.
mk_uname_stub() {
  local dir="$1" os="$2"
  mkdir -p "$dir"
  cat > "$dir/uname" <<UNAME
#!$REAL_BASH
printf '%s\n' "$os"
UNAME
  chmod +x "$dir/uname"
}

# wait_for_log <file> — poll briefly for the backgrounded stub player to have
# logged its invocation (atelier-notify-cue backgrounds the delegate with `&`
# and returns immediately, so the write can lag by a beat).
wait_for_log() {
  local file="$1" tries=0
  while [ ! -s "$file" ] && [ "$tries" -lt 40 ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
}

write_op() { # write_op <cfgdir> <raw-content>
  local cfg="$1" content="$2"
  mkdir -p "$cfg"
  printf '%s' "$content" > "$cfg/operator.json"
}

# run_cue <scendir> <cfgdir> <homedir> <cue> [path-prefix]
run_cue() {
  local scen="$1" cfg="$2" home="$3" cue="$4" pathprefix="${5:-}"
  if [ -n "$pathprefix" ]; then
    PATH="$pathprefix:$PATH" ATELIER_CONFIG_DIR="$cfg" HOME="$home" \
      "$REAL_BASH" "$scen/atelier-notify-cue" "$cue"
  else
    ATELIER_CONFIG_DIR="$cfg" HOME="$home" \
      "$REAL_BASH" "$scen/atelier-notify-cue" "$cue"
  fi
}

# A curated minimal PATH containing ONLY real jq/dirname/readlink/uname —
# used for Group D's degraded scenarios so a real atelier-notify binary that
# might legitimately be on the operator's own PATH (managed installs symlink
# it into ~/.local/bin, which shell rc commonly adds to PATH) can never leak
# into a "missing binary" assertion.
SAFE_BIN="$TMP/safe_bin"; mkdir -p "$SAFE_BIN"
for util in jq dirname readlink uname; do
  src="$(command -v "$util" 2>/dev/null || true)"
  [ -n "$src" ] && ln -sf "$src" "$SAFE_BIN/$util"
done

echo "atelier-notify-cue (#42) — hermetic regression"
echo ""

# ---------------------------------------------------------------------------
# Syntax gate
# ---------------------------------------------------------------------------
bash -n "$NOTIFY_CUE_SRC" && pass "bash -n atelier-notify-cue" || fail "atelier-notify-cue has syntax errors"

# ===========================================================================
# Group A — pref gate OFF/ABSENT: silent exit 0, delegate never invoked
# ===========================================================================

# A1: task-complete, onTaskComplete explicitly false.
A1="$TMP/a1"; mk_scen "$A1"; LOG_A1="$TMP/log_a1"; mk_notify_stub "$A1" "$LOG_A1"
CFG_A1="$TMP/a1_cfg"; write_op "$CFG_A1" '{"notification":{"onTaskComplete":false}}'
HOME_A1="$TMP/a1_home"; mkdir -p "$HOME_A1"
out="$(run_cue "$A1" "$CFG_A1" "$HOME_A1" task-complete)"; rc=$?
[ "$rc" -eq 0 ] && pass "A1: exit 0 (task-complete, onTaskComplete=false)" || fail "A1: exit $rc"
[ -z "$out" ] && pass "A1: no stdout" || fail "A1: unexpected stdout: $out"
[ ! -s "$LOG_A1" ] && pass "A1: atelier-notify never invoked (flag off)" || fail "A1: delegate was invoked: $(cat "$LOG_A1")"

# A2: task-blocked, onTaskBlocked explicitly false.
A2="$TMP/a2"; mk_scen "$A2"; LOG_A2="$TMP/log_a2"; mk_notify_stub "$A2" "$LOG_A2"
CFG_A2="$TMP/a2_cfg"; write_op "$CFG_A2" '{"notification":{"onTaskBlocked":false}}'
HOME_A2="$TMP/a2_home"; mkdir -p "$HOME_A2"
out="$(run_cue "$A2" "$CFG_A2" "$HOME_A2" task-blocked)"; rc=$?
[ "$rc" -eq 0 ] && pass "A2: exit 0 (task-blocked, onTaskBlocked=false)" || fail "A2: exit $rc"
[ ! -s "$LOG_A2" ] && pass "A2: atelier-notify never invoked (flag off)" || fail "A2: delegate was invoked: $(cat "$LOG_A2")"

# A3: task-complete, .notification object present but key entirely absent
# (default-off, not fabricated on).
A3="$TMP/a3"; mk_scen "$A3"; LOG_A3="$TMP/log_a3"; mk_notify_stub "$A3" "$LOG_A3"
CFG_A3="$TMP/a3_cfg"; write_op "$CFG_A3" '{"notification":{}}'
HOME_A3="$TMP/a3_home"; mkdir -p "$HOME_A3"
out="$(run_cue "$A3" "$CFG_A3" "$HOME_A3" task-complete)"; rc=$?
[ "$rc" -eq 0 ] && pass "A3: exit 0 (task-complete key absent -> default off)" || fail "A3: exit $rc"
[ ! -s "$LOG_A3" ] && pass "A3: atelier-notify never invoked (default off)" || fail "A3: delegate was invoked: $(cat "$LOG_A3")"

# A4: task-blocked, operator.json present but empty object entirely.
A4="$TMP/a4"; mk_scen "$A4"; LOG_A4="$TMP/log_a4"; mk_notify_stub "$A4" "$LOG_A4"
CFG_A4="$TMP/a4_cfg"; write_op "$CFG_A4" '{}'
HOME_A4="$TMP/a4_home"; mkdir -p "$HOME_A4"
out="$(run_cue "$A4" "$CFG_A4" "$HOME_A4" task-blocked)"; rc=$?
[ "$rc" -eq 0 ] && pass "A4: exit 0 (task-blocked, empty operator.json object -> default off)" || fail "A4: exit $rc"
[ ! -s "$LOG_A4" ] && pass "A4: atelier-notify never invoked (default off)" || fail "A4: delegate was invoked: $(cat "$LOG_A4")"

# A5: operator.json file does not exist at all.
A5="$TMP/a5"; mk_scen "$A5"; LOG_A5="$TMP/log_a5"; mk_notify_stub "$A5" "$LOG_A5"
CFG_A5="$TMP/a5_cfg"; mkdir -p "$CFG_A5"   # deliberately no operator.json
HOME_A5="$TMP/a5_home"; mkdir -p "$HOME_A5"
out="$(run_cue "$A5" "$CFG_A5" "$HOME_A5" task-complete)"; rc=$?
[ "$rc" -eq 0 ] && pass "A5: exit 0 (operator.json absent entirely)" || fail "A5: exit $rc"
[ ! -s "$LOG_A5" ] && pass "A5: atelier-notify never invoked (no operator.json)" || fail "A5: delegate was invoked: $(cat "$LOG_A5")"

# ===========================================================================
# Group B — pref gate ON, per-OS default sound (uname stubbed, host-independent)
# ===========================================================================

# B1: Darwin + task-complete on, no override -> default "Hero".
B1="$TMP/b1"; mk_scen "$B1"; LOG_B1="$TMP/log_b1"; mk_notify_stub "$B1" "$LOG_B1"
UN_B1="$TMP/b1_uname"; mk_uname_stub "$UN_B1" Darwin
CFG_B1="$TMP/b1_cfg"; write_op "$CFG_B1" '{"notification":{"onTaskComplete":true}}'
HOME_B1="$TMP/b1_home"; mkdir -p "$HOME_B1"
out="$(run_cue "$B1" "$CFG_B1" "$HOME_B1" task-complete "$UN_B1")"; rc=$?
wait_for_log "$LOG_B1"
[ "$rc" -eq 0 ] && pass "B1: exit 0 (Darwin, task-complete on, no override)" || fail "B1: exit $rc"
[ "$(cat "$LOG_B1" 2>/dev/null)" = "--sound Hero" ] \
  && pass "B1: delegate invoked with the macOS task-complete default (Hero)" \
  || fail "B1: expected '--sound Hero', got: $(cat "$LOG_B1" 2>/dev/null)"

# B2: Darwin + task-blocked on, no override -> default "Basso".
B2="$TMP/b2"; mk_scen "$B2"; LOG_B2="$TMP/log_b2"; mk_notify_stub "$B2" "$LOG_B2"
UN_B2="$TMP/b2_uname"; mk_uname_stub "$UN_B2" Darwin
CFG_B2="$TMP/b2_cfg"; write_op "$CFG_B2" '{"notification":{"onTaskBlocked":true}}'
HOME_B2="$TMP/b2_home"; mkdir -p "$HOME_B2"
out="$(run_cue "$B2" "$CFG_B2" "$HOME_B2" task-blocked "$UN_B2")"; rc=$?
wait_for_log "$LOG_B2"
[ "$rc" -eq 0 ] && pass "B2: exit 0 (Darwin, task-blocked on, no override)" || fail "B2: exit $rc"
[ "$(cat "$LOG_B2" 2>/dev/null)" = "--sound Basso" ] \
  && pass "B2: delegate invoked with the macOS task-blocked default (Basso)" \
  || fail "B2: expected '--sound Basso', got: $(cat "$LOG_B2" 2>/dev/null)"

# B3: Linux + task-complete on, no override -> default complete.oga path.
B3="$TMP/b3"; mk_scen "$B3"; LOG_B3="$TMP/log_b3"; mk_notify_stub "$B3" "$LOG_B3"
UN_B3="$TMP/b3_uname"; mk_uname_stub "$UN_B3" Linux
CFG_B3="$TMP/b3_cfg"; write_op "$CFG_B3" '{"notification":{"onTaskComplete":true}}'
HOME_B3="$TMP/b3_home"; mkdir -p "$HOME_B3"
out="$(run_cue "$B3" "$CFG_B3" "$HOME_B3" task-complete "$UN_B3")"; rc=$?
wait_for_log "$LOG_B3"
[ "$rc" -eq 0 ] && pass "B3: exit 0 (Linux, task-complete on, no override)" || fail "B3: exit $rc"
[ "$(cat "$LOG_B3" 2>/dev/null)" = "--sound /usr/share/sounds/freedesktop/stereo/complete.oga" ] \
  && pass "B3: delegate invoked with the Linux task-complete default (complete.oga)" \
  || fail "B3: expected complete.oga default, got: $(cat "$LOG_B3" 2>/dev/null)"

# B4: Linux + task-blocked on, no override -> default dialog-error.oga path.
B4="$TMP/b4"; mk_scen "$B4"; LOG_B4="$TMP/log_b4"; mk_notify_stub "$B4" "$LOG_B4"
UN_B4="$TMP/b4_uname"; mk_uname_stub "$UN_B4" Linux
CFG_B4="$TMP/b4_cfg"; write_op "$CFG_B4" '{"notification":{"onTaskBlocked":true}}'
HOME_B4="$TMP/b4_home"; mkdir -p "$HOME_B4"
out="$(run_cue "$B4" "$CFG_B4" "$HOME_B4" task-blocked "$UN_B4")"; rc=$?
wait_for_log "$LOG_B4"
[ "$rc" -eq 0 ] && pass "B4: exit 0 (Linux, task-blocked on, no override)" || fail "B4: exit $rc"
[ "$(cat "$LOG_B4" 2>/dev/null)" = "--sound /usr/share/sounds/freedesktop/stereo/dialog-error.oga" ] \
  && pass "B4: delegate invoked with the Linux task-blocked default (dialog-error.oga)" \
  || fail "B4: expected dialog-error.oga default, got: $(cat "$LOG_B4" 2>/dev/null)"

# B5: unrecognized OS (e.g. FreeBSD) + task-complete on, no override -> no
# per-OS default resolves (SOUND stays empty); delegate is still invoked, but
# with NO --sound argument at all (proves the OS-gated default lookup, not a
# hardcoded fallback string).
B5="$TMP/b5"; mk_scen "$B5"; LOG_B5="$TMP/log_b5"; mk_notify_stub "$B5" "$LOG_B5"
UN_B5="$TMP/b5_uname"; mk_uname_stub "$UN_B5" FreeBSD
CFG_B5="$TMP/b5_cfg"; write_op "$CFG_B5" '{"notification":{"onTaskComplete":true}}'
HOME_B5="$TMP/b5_home"; mkdir -p "$HOME_B5"
out="$(run_cue "$B5" "$CFG_B5" "$HOME_B5" task-complete "$UN_B5")"; rc=$?
wait_for_log "$LOG_B5"
[ "$rc" -eq 0 ] && pass "B5: exit 0 (unrecognized OS, task-complete on)" || fail "B5: exit $rc"
[ -s "$LOG_B5" ] && [ -z "$(cat "$LOG_B5")" ] \
  && pass "B5: delegate invoked with NO --sound arg on an unrecognized OS (no default resolves)" \
  || fail "B5: expected an empty-arg invocation, got: $(cat "$LOG_B5" 2>/dev/null || echo '<no invocation>')"

# ===========================================================================
# Group C — sound override honored over the per-OS default
# ===========================================================================

# C1: Darwin + task-complete on + taskCompleteSound override -> override used,
# NOT the "Hero" default.
C1="$TMP/c1"; mk_scen "$C1"; LOG_C1="$TMP/log_c1"; mk_notify_stub "$C1" "$LOG_C1"
UN_C1="$TMP/c1_uname"; mk_uname_stub "$UN_C1" Darwin
CFG_C1="$TMP/c1_cfg"; write_op "$CFG_C1" '{"notification":{"onTaskComplete":true,"taskCompleteSound":"CustomA"}}'
HOME_C1="$TMP/c1_home"; mkdir -p "$HOME_C1"
out="$(run_cue "$C1" "$CFG_C1" "$HOME_C1" task-complete "$UN_C1")"; rc=$?
wait_for_log "$LOG_C1"
[ "$rc" -eq 0 ] && pass "C1: exit 0 (Darwin, task-complete override)" || fail "C1: exit $rc"
[ "$(cat "$LOG_C1" 2>/dev/null)" = "--sound CustomA" ] \
  && pass "C1: delegate invoked with the override (CustomA), not the Hero default" \
  || fail "C1: expected '--sound CustomA', got: $(cat "$LOG_C1" 2>/dev/null)"

# C2: Linux + task-blocked on + taskBlockedSound override -> override used,
# NOT the dialog-error.oga default.
C2="$TMP/c2"; mk_scen "$C2"; LOG_C2="$TMP/log_c2"; mk_notify_stub "$C2" "$LOG_C2"
UN_C2="$TMP/c2_uname"; mk_uname_stub "$UN_C2" Linux
CFG_C2="$TMP/c2_cfg"; write_op "$CFG_C2" '{"notification":{"onTaskBlocked":true,"taskBlockedSound":"CustomB"}}'
HOME_C2="$TMP/c2_home"; mkdir -p "$HOME_C2"
out="$(run_cue "$C2" "$CFG_C2" "$HOME_C2" task-blocked "$UN_C2")"; rc=$?
wait_for_log "$LOG_C2"
[ "$rc" -eq 0 ] && pass "C2: exit 0 (Linux, task-blocked override)" || fail "C2: exit $rc"
[ "$(cat "$LOG_C2" 2>/dev/null)" = "--sound CustomB" ] \
  && pass "C2: delegate invoked with the override (CustomB), not the dialog-error.oga default" \
  || fail "C2: expected '--sound CustomB', got: $(cat "$LOG_C2" 2>/dev/null)"

# C3: an override that will never resolve to anything real is still passed
# through verbatim and the cue still exits 0 — resolution failure belongs to
# atelier-notify (#41), not this delegator.
C3="$TMP/c3"; mk_scen "$C3"; LOG_C3="$TMP/log_c3"; mk_notify_stub "$C3" "$LOG_C3"
UN_C3="$TMP/c3_uname"; mk_uname_stub "$UN_C3" Darwin
CFG_C3="$TMP/c3_cfg"; write_op "$CFG_C3" '{"notification":{"onTaskComplete":true,"taskCompleteSound":"totally-bogus-nonexistent-xyz"}}'
HOME_C3="$TMP/c3_home"; mkdir -p "$HOME_C3"
out="$(run_cue "$C3" "$CFG_C3" "$HOME_C3" task-complete "$UN_C3")"; rc=$?
wait_for_log "$LOG_C3"
[ "$rc" -eq 0 ] && pass "C3: exit 0 even with an unresolvable sound override" || fail "C3: exit $rc"
[ "$(cat "$LOG_C3" 2>/dev/null)" = "--sound totally-bogus-nonexistent-xyz" ] \
  && pass "C3: unresolvable override still delegated verbatim (resolution is atelier-notify's job)" \
  || fail "C3: expected the bogus override to be passed through, got: $(cat "$LOG_C3" 2>/dev/null)"

# ===========================================================================
# Group D — never hard-fails: exit 0 in every degraded scenario, no delegate
# call in any of them
# ===========================================================================

# D1: jq missing from PATH -> silent exit 0, delegate never invoked (the
# script bails before even resolving atelier-notify).
D1="$TMP/d1"; mk_scen "$D1"; LOG_D1="$TMP/log_d1"; mk_notify_stub "$D1" "$LOG_D1"
CFG_D1="$TMP/d1_cfg"; write_op "$CFG_D1" '{"notification":{"onTaskComplete":true}}'
HOME_D1="$TMP/d1_home"; mkdir -p "$HOME_D1"
NOJQ_BIN="$TMP/d1_nojq"; mkdir -p "$NOJQ_BIN"   # empty: no jq reachable
out="$(PATH="$NOJQ_BIN" ATELIER_CONFIG_DIR="$CFG_D1" HOME="$HOME_D1" "$REAL_BASH" "$D1/atelier-notify-cue" task-complete 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "D1: exit 0 (jq missing from PATH)" || fail "D1: exit $rc"
[ ! -s "$LOG_D1" ] && pass "D1: atelier-notify never invoked (jq missing)" || fail "D1: delegate was invoked: $(cat "$LOG_D1")"

# D2: operator.json absent (also exercised in A5, repeated here under the
# explicit "never hard-fails" framing requested by the plan).
D2="$TMP/d2"; mk_scen "$D2"; LOG_D2="$TMP/log_d2"; mk_notify_stub "$D2" "$LOG_D2"
CFG_D2="$TMP/d2_cfg"; mkdir -p "$CFG_D2"
HOME_D2="$TMP/d2_home"; mkdir -p "$HOME_D2"
out="$(run_cue "$D2" "$CFG_D2" "$HOME_D2" task-blocked)"; rc=$?
[ "$rc" -eq 0 ] && pass "D2: exit 0 (operator.json missing)" || fail "D2: exit $rc"
[ ! -s "$LOG_D2" ] && pass "D2: atelier-notify never invoked (no operator.json)" || fail "D2: delegate was invoked: $(cat "$LOG_D2")"

# D3: operator.json exists but is malformed JSON -> jq read fails, treated as
# not-enabled, exit 0, delegate never invoked.
D3="$TMP/d3"; mk_scen "$D3"; LOG_D3="$TMP/log_d3"; mk_notify_stub "$D3" "$LOG_D3"
CFG_D3="$TMP/d3_cfg"; write_op "$CFG_D3" '{ this is not valid json'
HOME_D3="$TMP/d3_home"; mkdir -p "$HOME_D3"
out="$(run_cue "$D3" "$CFG_D3" "$HOME_D3" task-complete)"; rc=$?
[ "$rc" -eq 0 ] && pass "D3: exit 0 (malformed operator.json)" || fail "D3: exit $rc"
[ ! -s "$LOG_D3" ] && pass "D3: atelier-notify never invoked (malformed operator.json)" || fail "D3: delegate was invoked: $(cat "$LOG_D3")"
MALFORMED_BEFORE_D3='{ this is not valid json'
MALFORMED_AFTER_D3="$(cat "$CFG_D3/operator.json")"
[ "$MALFORMED_BEFORE_D3" = "$MALFORMED_AFTER_D3" ] \
  && pass "D3: malformed operator.json is left byte-for-byte untouched" \
  || fail "D3: malformed operator.json was modified"

# D4: flag on, sound override set (skips the uname branch entirely), but NO
# atelier-notify binary resolves anywhere (no self-dir stub, fresh temp HOME,
# and a curated PATH containing only real jq/dirname/readlink/uname — never
# a real, PATH-installed atelier-notify that might legitimately exist on the
# operator's own machine) -> silent exit 0.
D4="$TMP/d4"; mk_scen "$D4"   # NOTE: no atelier-notify placed in this scen dir
CFG_D4="$TMP/d4_cfg"; write_op "$CFG_D4" '{"notification":{"onTaskComplete":true,"taskCompleteSound":"WhateverSound"}}'
HOME_D4="$TMP/d4_home"; mkdir -p "$HOME_D4"   # fresh HOME: no ~/.local/bin/atelier-notify
out="$(PATH="$SAFE_BIN" ATELIER_CONFIG_DIR="$CFG_D4" HOME="$HOME_D4" "$REAL_BASH" "$D4/atelier-notify-cue" task-complete 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "D4: exit 0 (no atelier-notify binary resolvable anywhere)" || fail "D4: exit $rc"
[ -z "$out" ] && pass "D4: no stdout/stderr noise when the delegate binary can't be found" || fail "D4: unexpected output: $out"

# ===========================================================================
# Group E — invalid/empty cue argument: silent exit-0 no-op before any config
# is read at all
# ===========================================================================

E1="$TMP/e1"; mk_scen "$E1"; LOG_E1="$TMP/log_e1"; mk_notify_stub "$E1" "$LOG_E1"
CFG_E1="$TMP/e1_cfg"; write_op "$CFG_E1" '{"notification":{"onTaskComplete":true,"onTaskBlocked":true}}'
HOME_E1="$TMP/e1_home"; mkdir -p "$HOME_E1"
out="$(run_cue "$E1" "$CFG_E1" "$HOME_E1" bogus-cue)"; rc=$?
[ "$rc" -eq 0 ] && pass "E1: exit 0 (unrecognized cue argument 'bogus-cue')" || fail "E1: exit $rc"
[ ! -s "$LOG_E1" ] && pass "E1: atelier-notify never invoked for an unrecognized cue" || fail "E1: delegate was invoked: $(cat "$LOG_E1")"

E2="$TMP/e2"; mk_scen "$E2"; LOG_E2="$TMP/log_e2"; mk_notify_stub "$E2" "$LOG_E2"
CFG_E2="$TMP/e2_cfg"; write_op "$CFG_E2" '{"notification":{"onTaskComplete":true,"onTaskBlocked":true}}'
HOME_E2="$TMP/e2_home"; mkdir -p "$HOME_E2"
out="$(ATELIER_CONFIG_DIR="$CFG_E2" HOME="$HOME_E2" "$REAL_BASH" "$E2/atelier-notify-cue" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "E2: exit 0 (no cue argument at all)" || fail "E2: exit $rc"
[ ! -s "$LOG_E2" ] && pass "E2: atelier-notify never invoked with no cue argument" || fail "E2: delegate was invoked: $(cat "$LOG_E2")"

# ===========================================================================
# Result
# ===========================================================================
echo ""
if [ "$fails" -eq 0 ]; then
  echo "atelier-notify-cue (#42): all assertions passed."
  exit 0
else
  echo "atelier-notify-cue (#42): $fails assertion(s) failed."
  exit 1
fi
