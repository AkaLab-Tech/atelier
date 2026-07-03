#!/usr/bin/env bash
#
# Regression test for #42 — scripts/atelier-set-notification's two NEW
# subcommands (`task-complete on|off [--sound X]` and
# `task-blocked on|off [--sound X]`), added alongside the pre-existing #41
# bare `on`/`off` (input cue).
#
# Coverage:
#   Group A — default off: a fresh operator.json (no notification key at
#     all) reports all three cues as off via --show.
#   Group B — toggles: task-complete/task-blocked `on` sets the flag true,
#     `off` sets it explicitly false (not removed — matches the
#     implementer's actual jq write), `--sound X` records the sound key.
#   Group C — merge-safety: seeding .notification.enabled/.sound and
#     .language up front, toggling either new cue never clobbers them, never
#     clobbers the OTHER new cue, and the bare on/off input cue never
#     clobbers either new cue.
#   Group D — --show lists all three cues' states, with sound annotations
#     when set.
#   Group E — --clear clears all three cues at once but leaves .language
#     untouched.
#   Group F — the bare on/off path (input cue) is unchanged/backward
#     compatible: still controls .notification.enabled/.sound only.
#   Group G — argument errors: missing on/off, an unrecognized state word,
#     and --sound combined with `off` are all rejected (exit 1), matching
#     the bare on/off cue's existing error-handling shape.
#   Group H — the task-complete/task-blocked subcommands do NOT trigger
#     _reconcile (no settings.json Notification-hook write), unlike the bare
#     on/off path which does.
#
# Hermetic: every scenario uses its own temp ATELIER_CONFIG_DIR (and, where
# relevant, HOME) — never the operator's real ~/.claude-work/operator.json.
#
# Run:  hooks/tests/atelier-set-notification-cues.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETTER="$REPO_ROOT/scripts/atelier-set-notification"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# run_setter <cfgdir> [<homedir>] -- <args...> is awkward in bash; instead
# provide two thin wrappers: one that only needs ATELIER_CONFIG_DIR (the
# common case — task-complete/task-blocked never touch HOME/settings.json),
# and one that also sets HOME (for the bare on/off _reconcile-behavior probe
# in Group H).
run_setter() { # run_setter <cfgdir> [args...]
  local cfg="$1"; shift
  ATELIER_CONFIG_DIR="$cfg" bash "$SETTER" "$@"
}
run_setter_home() { # run_setter_home <cfgdir> <homedir> [args...]
  local cfg="$1" home="$2"; shift 2
  ATELIER_CONFIG_DIR="$cfg" HOME="$home" bash "$SETTER" "$@"
}

get_op() { jq -r "$2" "$1/operator.json" 2>/dev/null; } # get_op <cfgdir> <jq-filter>

echo "atelier-set-notification-cues (#42) — hermetic regression"
echo ""

# ---------------------------------------------------------------------------
# Syntax gate
# ---------------------------------------------------------------------------
bash -n "$SETTER" && pass "bash -n atelier-set-notification" || fail "atelier-set-notification has syntax errors"

# ===========================================================================
# Group A — default off on a totally fresh operator.json
# ===========================================================================

A_CFG="$TMP/a_cfg"; mkdir -p "$A_CFG"
out="$(run_setter "$A_CFG" --show)"; rc=$?
[ "$rc" -eq 0 ] && pass "A: --show exits 0 with no operator.json at all" || fail "A: --show exited $rc"
grep -q 'input cue (questions/permission prompts): off (default)' <<<"$out" \
  && pass "A: input cue reported off by default" || fail "A: input cue not reported off: $out"
grep -q 'task-complete cue: off (default)' <<<"$out" \
  && pass "A: task-complete cue reported off by default" || fail "A: task-complete cue not reported off: $out"
grep -q 'task-blocked cue: off (default)' <<<"$out" \
  && pass "A: task-blocked cue reported off by default" || fail "A: task-blocked cue not reported off: $out"

# ===========================================================================
# Group B — toggles: on sets true, off sets explicit false, --sound records
# ===========================================================================

B_CFG="$TMP/b_cfg"; mkdir -p "$B_CFG"

run_setter "$B_CFG" task-complete on >/dev/null; rc=$?
[ "$rc" -eq 0 ] && pass "B: 'task-complete on' exits 0" || fail "B: 'task-complete on' exited $rc"
[ "$(get_op "$B_CFG" '.notification.onTaskComplete')" = "true" ] \
  && pass "B: 'task-complete on' sets onTaskComplete=true" || fail "B: onTaskComplete not true: $(get_op "$B_CFG" '.notification.onTaskComplete')"

run_setter "$B_CFG" task-complete on --sound Hero2 >/dev/null
[ "$(get_op "$B_CFG" '.notification.taskCompleteSound')" = "Hero2" ] \
  && pass "B: 'task-complete on --sound Hero2' records taskCompleteSound" || fail "B: taskCompleteSound not recorded"
[ "$(get_op "$B_CFG" '.notification.onTaskComplete')" = "true" ] \
  && pass "B: onTaskComplete still true after re-toggling on with --sound" || fail "B: onTaskComplete regressed"

run_setter "$B_CFG" task-complete off >/dev/null; rc=$?
[ "$rc" -eq 0 ] && pass "B: 'task-complete off' exits 0" || fail "B: 'task-complete off' exited $rc"
[ "$(get_op "$B_CFG" '.notification.onTaskComplete')" = "false" ] \
  && pass "B: 'task-complete off' sets onTaskComplete=false (explicit, not removed)" \
  || fail "B: onTaskComplete not explicitly false: $(get_op "$B_CFG" '.notification.onTaskComplete')"
[ "$(get_op "$B_CFG" '.notification.taskCompleteSound')" = "Hero2" ] \
  && pass "B: turning off does not clear a previously recorded sound (documents actual behavior)" \
  || fail "B: taskCompleteSound was unexpectedly cleared on off: $(get_op "$B_CFG" '.notification.taskCompleteSound')"

# task-blocked mirrors task-complete.
run_setter "$B_CFG" task-blocked on --sound Basso2 >/dev/null; rc=$?
[ "$rc" -eq 0 ] && pass "B: 'task-blocked on --sound Basso2' exits 0" || fail "B: exited $rc"
[ "$(get_op "$B_CFG" '.notification.onTaskBlocked')" = "true" ] \
  && pass "B: 'task-blocked on' sets onTaskBlocked=true" || fail "B: onTaskBlocked not true"
[ "$(get_op "$B_CFG" '.notification.taskBlockedSound')" = "Basso2" ] \
  && pass "B: 'task-blocked on --sound Basso2' records taskBlockedSound" || fail "B: taskBlockedSound not recorded"

run_setter "$B_CFG" task-blocked off >/dev/null
[ "$(get_op "$B_CFG" '.notification.onTaskBlocked')" = "false" ] \
  && pass "B: 'task-blocked off' sets onTaskBlocked=false (explicit)" || fail "B: onTaskBlocked not explicitly false"

# ===========================================================================
# Group C — merge-safety
# ===========================================================================

C_CFG="$TMP/c_cfg"; mkdir -p "$C_CFG"
jq -n '{language: "French", notification: {enabled: true, sound: "Ping"}}' > "$C_CFG/operator.json"

run_setter "$C_CFG" task-complete on --sound Hero3 >/dev/null
[ "$(get_op "$C_CFG" '.language')" = "French" ] \
  && pass "C: task-complete toggle never clobbers .language" || fail "C: .language clobbered: $(get_op "$C_CFG" '.language')"
[ "$(get_op "$C_CFG" '.notification.enabled')" = "true" ] \
  && pass "C: task-complete toggle never clobbers .notification.enabled" || fail "C: .notification.enabled clobbered"
[ "$(get_op "$C_CFG" '.notification.sound')" = "Ping" ] \
  && pass "C: task-complete toggle never clobbers .notification.sound" || fail "C: .notification.sound clobbered"
[ "$(get_op "$C_CFG" '.notification.onTaskComplete')" = "true" ] \
  && pass "C: onTaskComplete set as expected" || fail "C: onTaskComplete not set"
[ "$(get_op "$C_CFG" '.notification.taskCompleteSound')" = "Hero3" ] \
  && pass "C: taskCompleteSound set as expected" || fail "C: taskCompleteSound not set"
[ "$(get_op "$C_CFG" '.notification.onTaskBlocked // "ABSENT"')" = "ABSENT" ] \
  && pass "C: task-complete toggle does not fabricate onTaskBlocked" || fail "C: onTaskBlocked was fabricated"

run_setter "$C_CFG" task-blocked on --sound Basso3 >/dev/null
[ "$(get_op "$C_CFG" '.language')" = "French" ] \
  && pass "C: task-blocked toggle never clobbers .language" || fail "C: .language clobbered"
[ "$(get_op "$C_CFG" '.notification.enabled')" = "true" ] \
  && pass "C: task-blocked toggle never clobbers .notification.enabled" || fail "C: .notification.enabled clobbered"
[ "$(get_op "$C_CFG" '.notification.sound')" = "Ping" ] \
  && pass "C: task-blocked toggle never clobbers .notification.sound" || fail "C: .notification.sound clobbered"
[ "$(get_op "$C_CFG" '.notification.onTaskComplete')" = "true" ] \
  && pass "C: task-blocked toggle does not clobber the OTHER cue (onTaskComplete)" || fail "C: onTaskComplete clobbered by task-blocked toggle"
[ "$(get_op "$C_CFG" '.notification.taskCompleteSound')" = "Hero3" ] \
  && pass "C: task-blocked toggle does not clobber the OTHER cue's sound (taskCompleteSound)" || fail "C: taskCompleteSound clobbered by task-blocked toggle"
[ "$(get_op "$C_CFG" '.notification.onTaskBlocked')" = "true" ] \
  && pass "C: onTaskBlocked set as expected" || fail "C: onTaskBlocked not set"
[ "$(get_op "$C_CFG" '.notification.taskBlockedSound')" = "Basso3" ] \
  && pass "C: taskBlockedSound set as expected" || fail "C: taskBlockedSound not set"

# Bare "off" (input cue) must not clobber either new cue.
run_setter_home "$C_CFG" "$TMP/c_home_off" off >/dev/null
[ "$(get_op "$C_CFG" '.notification.onTaskComplete')" = "true" ] \
  && pass "C: bare 'off' (input cue) does not clobber onTaskComplete" || fail "C: bare 'off' clobbered onTaskComplete"
[ "$(get_op "$C_CFG" '.notification.onTaskBlocked')" = "true" ] \
  && pass "C: bare 'off' (input cue) does not clobber onTaskBlocked" || fail "C: bare 'off' clobbered onTaskBlocked"
[ "$(get_op "$C_CFG" '.notification.enabled')" = "false" ] \
  && pass "C: bare 'off' still controls its own .notification.enabled" || fail "C: bare 'off' did not set enabled=false"
[ "$(get_op "$C_CFG" '.language')" = "French" ] \
  && pass "C: bare 'off' never clobbers .language" || fail "C: bare 'off' clobbered .language"

# Bare "on" with --sound must not clobber either new cue.
run_setter_home "$C_CFG" "$TMP/c_home_on" on --sound Ping2 >/dev/null
[ "$(get_op "$C_CFG" '.notification.enabled')" = "true" ] \
  && pass "C: bare 'on' sets its own .notification.enabled=true" || fail "C: bare 'on' did not set enabled=true"
[ "$(get_op "$C_CFG" '.notification.sound')" = "Ping2" ] \
  && pass "C: bare 'on --sound' sets its own .notification.sound" || fail "C: bare 'on --sound' did not set sound"
[ "$(get_op "$C_CFG" '.notification.onTaskComplete')" = "true" ] \
  && pass "C: bare 'on' does not clobber onTaskComplete" || fail "C: bare 'on' clobbered onTaskComplete"
[ "$(get_op "$C_CFG" '.notification.onTaskBlocked')" = "true" ] \
  && pass "C: bare 'on' does not clobber onTaskBlocked" || fail "C: bare 'on' clobbered onTaskBlocked"

# ===========================================================================
# Group D — --show lists all three cues, with sound annotations
# ===========================================================================

out="$(run_setter "$C_CFG" --show)"; rc=$?
[ "$rc" -eq 0 ] && pass "D: --show exits 0" || fail "D: --show exited $rc"
grep -q 'input cue (questions/permission prompts): on (sound: Ping2)' <<<"$out" \
  && pass "D: --show reports the input cue on with its sound" || fail "D: input cue line wrong: $out"
grep -q 'task-complete cue: on (sound: Hero3)' <<<"$out" \
  && pass "D: --show reports task-complete on with its sound" || fail "D: task-complete line wrong: $out"
grep -q 'task-blocked cue: on (sound: Basso3)' <<<"$out" \
  && pass "D: --show reports task-blocked on with its sound" || fail "D: task-blocked line wrong: $out"

# ===========================================================================
# Group E — --clear clears all three cues, leaves .language untouched
# ===========================================================================

run_setter "$C_CFG" --clear >/dev/null; rc=$?
[ "$rc" -eq 0 ] && pass "E: --clear exits 0" || fail "E: --clear exited $rc"
[ "$(get_op "$C_CFG" 'has("notification")')" = "false" ] \
  && pass "E: --clear removes the entire .notification object" || fail "E: .notification survives --clear"
[ "$(get_op "$C_CFG" '.language')" = "French" ] \
  && pass "E: --clear leaves .language untouched" || fail "E: .language lost on --clear"

out="$(run_setter "$C_CFG" --show)"
grep -q 'input cue (questions/permission prompts): off (default)' <<<"$out" \
  && pass "E: --show reports input cue off after --clear" || fail "E: input cue not off after --clear"
grep -q 'task-complete cue: off (default)' <<<"$out" \
  && pass "E: --show reports task-complete off after --clear" || fail "E: task-complete not off after --clear"
grep -q 'task-blocked cue: off (default)' <<<"$out" \
  && pass "E: --show reports task-blocked off after --clear" || fail "E: task-blocked not off after --clear"

# ===========================================================================
# Group F — bare on/off (input cue) backward-compatible, unaffected by new cues
# ===========================================================================

F_CFG="$TMP/f_cfg"; mkdir -p "$F_CFG"
run_setter_home "$F_CFG" "$TMP/f_home" on --sound Glass2 >/dev/null; rc=$?
[ "$rc" -eq 0 ] && pass "F: bare 'on --sound' exits 0 on a fresh operator.json" || fail "F: exited $rc"
[ "$(get_op "$F_CFG" '.notification.enabled')" = "true" ] \
  && pass "F: bare 'on' sets .notification.enabled=true" || fail "F: enabled not true"
[ "$(get_op "$F_CFG" '.notification.sound')" = "Glass2" ] \
  && pass "F: bare 'on --sound' sets .notification.sound" || fail "F: sound not set"
[ "$(get_op "$F_CFG" '.notification.onTaskComplete // "ABSENT"')" = "ABSENT" ] \
  && pass "F: bare 'on' never fabricates onTaskComplete" || fail "F: onTaskComplete fabricated by bare 'on'"
[ "$(get_op "$F_CFG" '.notification.onTaskBlocked // "ABSENT"')" = "ABSENT" ] \
  && pass "F: bare 'on' never fabricates onTaskBlocked" || fail "F: onTaskBlocked fabricated by bare 'on'"

run_setter_home "$F_CFG" "$TMP/f_home" off >/dev/null; rc=$?
[ "$rc" -eq 0 ] && pass "F: bare 'off' exits 0" || fail "F: exited $rc"
[ "$(get_op "$F_CFG" '.notification.enabled')" = "false" ] \
  && pass "F: bare 'off' sets .notification.enabled=false" || fail "F: enabled not false"

# ===========================================================================
# Group G — argument errors (exit 1)
# ===========================================================================

G_CFG="$TMP/g_cfg"; mkdir -p "$G_CFG"

run_setter "$G_CFG" task-complete >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "G: 'task-complete' with no on/off errors (exit 1)" || fail "G: expected exit 1, got $rc"

run_setter "$G_CFG" task-complete bogus >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "G: 'task-complete bogus' (unrecognized state) errors (exit 1)" || fail "G: expected exit 1, got $rc"

run_setter "$G_CFG" task-blocked >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "G: 'task-blocked' with no on/off errors (exit 1)" || fail "G: expected exit 1, got $rc"

run_setter "$G_CFG" task-complete off --sound X >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && pass "G: '--sound' combined with 'off' errors (exit 1)" || fail "G: expected exit 1, got $rc"

# ===========================================================================
# Group H — task-complete/task-blocked never trigger _reconcile (no
# settings.json write), unlike bare on/off which does.
# ===========================================================================

H_CFG="$TMP/h_cfg"; H_HOME="$TMP/h_home"; mkdir -p "$H_CFG" "$H_HOME"
[ ! -f "$H_CFG/settings.json" ] || fail "H: setup sanity — settings.json should not pre-exist"

run_setter_home "$H_CFG" "$H_HOME" task-complete on >/dev/null
[ ! -f "$H_CFG/settings.json" ] \
  && pass "H: 'task-complete on' never creates/touches settings.json (no _reconcile)" \
  || fail "H: settings.json was created by 'task-complete on'"

run_setter_home "$H_CFG" "$H_HOME" task-blocked on >/dev/null
[ ! -f "$H_CFG/settings.json" ] \
  && pass "H: 'task-blocked on' never creates/touches settings.json (no _reconcile)" \
  || fail "H: settings.json was created by 'task-blocked on'"

# Contrast: the bare on/off path DOES reconcile — it should materialize (or
# at least attempt to materialize) settings.json in the same config dir.
run_setter_home "$H_CFG" "$H_HOME" on >/dev/null
[ -f "$H_CFG/settings.json" ] \
  && pass "H: bare 'on' (input cue) DOES reconcile — settings.json materialized, contrasting with the task cues above" \
  || fail "H: expected bare 'on' to materialize settings.json via _reconcile"

# ===========================================================================
# Result
# ===========================================================================
echo ""
if [ "$fails" -eq 0 ]; then
  echo "atelier-set-notification-cues (#42): all assertions passed."
  exit 0
else
  echo "atelier-set-notification-cues (#42): $fails assertion(s) failed."
  exit 1
fi
