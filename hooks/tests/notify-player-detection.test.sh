#!/usr/bin/env bash
#
# Regression test for #41 — scripts/atelier-notify (best-effort, cross-platform
# audible cue for the Notification hook).
#
# Coverage:
#   Group A — backend priority per simulated OS (uname stubbed on a fake PATH):
#     Darwin -> afplay; Linux -> paplay -> aplay -> canberra-gtk-play; unknown
#     OS or no backend -> terminal bell. OS gates the choice even when a
#     macOS-only binary happens to be stubbed under a non-matching uname.
#   Group B — --sound hint honored: a `/`-containing path is used verbatim; a
#     bare name resolves against the platform's built-in sound dir (macOS).
#   Group C — an unresolvable --sound hint falls back silently: exit 0, no
#     stderr noise, no hang.
#   Group D — argument-parsing edge cases (missing --sound value, unknown
#     flags) never break the exit-0 contract.
#   Group E — exit 0 in EVERY scenario above (asserted alongside each case).
#
# Hermetic: PATH is reduced to a scratch bin dir per scenario, populated only
# with the exact stub binaries (uname + zero or more players) that scenario
# needs — no dependence on the host's real afplay/paplay/aplay/canberra-gtk-play
# or its uname. Player stubs shebang the REAL bash via an ABSOLUTE path
# (resolved once via `command -v bash`) rather than `#!/usr/bin/env bash`, so
# they still execute correctly under the restricted PATH (env's own PATH
# lookup for "bash" would otherwise fail). No real audio is ever played —
# stub players just log their invocation to a temp file and exit 0.
#
# Run:  hooks/tests/notify-player-detection.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NOTIFY="$REPO_ROOT/scripts/atelier-notify"
REAL_BASH="$(command -v bash)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/bin"; mkdir -p "$STUB"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

BELL="$(printf '\a')"

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

reset_stub() { rm -rf "$STUB"; mkdir -p "$STUB"; }

# mk_uname <os-name> — stub `uname` to report a fixed OS, regardless of host.
mk_uname() {
  local os="$1"
  cat > "$STUB/uname" <<UNAME
#!$REAL_BASH
printf '%s\n' "$os"
UNAME
  chmod +x "$STUB/uname"
}

# mk_player <name> <log-file> — stub a player binary that logs its argv (one
# line per invocation) to <log-file> and exits 0. Shebangs the real bash by
# ABSOLUTE path so it still runs when PATH is restricted to $STUB alone.
mk_player() {
  local name="$1" log="$2"
  cat > "$STUB/$name" <<PLAYER
#!$REAL_BASH
printf '%s\n' "\$*" >> "$log"
exit 0
PLAYER
  chmod +x "$STUB/$name"
}

# wait_for_log <file> — poll briefly for a backgrounded stub player to have
# written its log line (atelier-notify backgrounds playback with `&` and does
# not wait, so the write can lag the parent script's own return by a beat).
wait_for_log() {
  local file="$1" tries=0
  while [ ! -s "$file" ] && [ "$tries" -lt 40 ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
}

# run_notify [args...] — invoke atelier-notify with PATH restricted to $STUB.
run_notify() {
  PATH="$STUB" "$REAL_BASH" "$NOTIFY" "$@"
}

DEFAULT_MAC="/System/Library/Sounds/Glass.aiff"
LINUX_PAPLAY_DEFAULTS=(/usr/share/sounds/freedesktop/stereo/message.oga \
                        /usr/share/sounds/freedesktop/stereo/dialog-information.oga)

linux_paplay_default() {
  local d
  for d in "${LINUX_PAPLAY_DEFAULTS[@]}"; do
    [ -r "$d" ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

echo "notify-player-detection (#41) — hermetic regression"
echo ""

# ---------------------------------------------------------------------------
# Syntax gate
# ---------------------------------------------------------------------------
bash -n "$NOTIFY" && pass "bash -n atelier-notify" || fail "atelier-notify has syntax errors"

# ===========================================================================
# Group A — backend priority per simulated OS
# ===========================================================================

# A1: Darwin + afplay present + --sound <tempfile> -> afplay invoked with the
# exact hint path (a `/`-containing hint is used verbatim, no default lookup).
reset_stub; mk_uname Darwin
LOG_A1="$TMP/log_a1"; mk_player afplay "$LOG_A1"
SOUND_A1="$TMP/sound_a1.aiff"; : > "$SOUND_A1"
out="$(run_notify --sound "$SOUND_A1")"; rc=$?
wait_for_log "$LOG_A1"
[ "$rc" -eq 0 ] && pass "A1: exit 0 (Darwin + afplay)" || fail "A1: exit $rc"
[ -z "$out" ] && pass "A1: no stdout when a player is invoked" || fail "A1: unexpected stdout: $out"
grep -qF "$SOUND_A1" "$LOG_A1" 2>/dev/null \
  && pass "A1: afplay invoked with the --sound path" \
  || fail "A1: afplay not invoked with $SOUND_A1 (log: $(cat "$LOG_A1" 2>/dev/null))"

# A2: Darwin + afplay ABSENT -> terminal bell.
reset_stub; mk_uname Darwin
out="$(run_notify)"; rc=$?
[ "$rc" -eq 0 ] && pass "A2: exit 0 (Darwin, no afplay)" || fail "A2: exit $rc"
[ "$out" = "$BELL" ] && pass "A2: bell fallback when no macOS player present" || fail "A2: expected bell, got: $(printf '%s' "$out" | od -An -tx1 | tr -d '\n')"

# A3: Linux + paplay present + --sound <tempfile> -> paplay invoked with hint.
reset_stub; mk_uname Linux
LOG_A3="$TMP/log_a3"; mk_player paplay "$LOG_A3"
SOUND_A3="$TMP/sound_a3.wav"; : > "$SOUND_A3"
out="$(run_notify --sound "$SOUND_A3")"; rc=$?
wait_for_log "$LOG_A3"
[ "$rc" -eq 0 ] && pass "A3: exit 0 (Linux + paplay)" || fail "A3: exit $rc"
[ -z "$out" ] && pass "A3: no stdout when a player is invoked" || fail "A3: unexpected stdout: $out"
grep -qF "$SOUND_A3" "$LOG_A3" 2>/dev/null \
  && pass "A3: paplay invoked with the --sound path" \
  || fail "A3: paplay not invoked with $SOUND_A3 (log: $(cat "$LOG_A3" 2>/dev/null))"

# A4: Linux + paplay ABSENT + aplay present + --sound <tempfile> -> aplay used
# (priority: paplay > aplay when paplay is not on PATH).
reset_stub; mk_uname Linux
LOG_A4="$TMP/log_a4"; mk_player aplay "$LOG_A4"
out="$(run_notify --sound "$SOUND_A3")"; rc=$?
wait_for_log "$LOG_A4"
[ "$rc" -eq 0 ] && pass "A4: exit 0 (Linux + aplay only)" || fail "A4: exit $rc"
grep -qF "$SOUND_A3" "$LOG_A4" 2>/dev/null \
  && pass "A4: aplay invoked with the --sound path when paplay is absent" \
  || fail "A4: aplay not invoked (log: $(cat "$LOG_A4" 2>/dev/null))"

# A5: Linux + only canberra-gtk-play present -> invoked with `-i message`
# (canberra-gtk-play ignores the --sound hint entirely per the script).
reset_stub; mk_uname Linux
LOG_A5="$TMP/log_a5"; mk_player canberra-gtk-play "$LOG_A5"
out="$(run_notify --sound "$SOUND_A3")"; rc=$?
wait_for_log "$LOG_A5"
[ "$rc" -eq 0 ] && pass "A5: exit 0 (Linux + canberra-gtk-play only)" || fail "A5: exit $rc"
grep -qF -- "-i message" "$LOG_A5" 2>/dev/null \
  && pass "A5: canberra-gtk-play invoked with '-i message'" \
  || fail "A5: canberra-gtk-play not invoked as expected (log: $(cat "$LOG_A5" 2>/dev/null))"

# A6: Linux + no player at all -> terminal bell.
reset_stub; mk_uname Linux
out="$(run_notify)"; rc=$?
[ "$rc" -eq 0 ] && pass "A6: exit 0 (Linux, no player)" || fail "A6: exit $rc"
[ "$out" = "$BELL" ] && pass "A6: bell fallback when no Linux player present" || fail "A6: expected bell, got: $(printf '%s' "$out" | od -An -tx1 | tr -d '\n')"

# A7: unknown OS (e.g. FreeBSD) + afplay present -> STILL bell. Proves the OS
# switch gates the backend choice; a matching binary on PATH is not enough.
reset_stub; mk_uname FreeBSD
LOG_A7="$TMP/log_a7"; mk_player afplay "$LOG_A7"
out="$(run_notify)"; rc=$?
[ "$rc" -eq 0 ] && pass "A7: exit 0 (unknown OS + afplay present)" || fail "A7: exit $rc"
[ "$out" = "$BELL" ] && pass "A7: unknown OS falls back to bell even with afplay on PATH" || fail "A7: expected bell, got: $(printf '%s' "$out" | od -An -tx1 | tr -d '\n')"
[ ! -s "$LOG_A7" ] && pass "A7: afplay never invoked on an unrecognized OS" || fail "A7: afplay was invoked despite unknown OS (log: $(cat "$LOG_A7")))"

# A8: Linux + paplay AND aplay AND canberra-gtk-play all present simultaneously
# -> paplay wins (highest priority); the other two are never invoked.
reset_stub; mk_uname Linux
LOG_A8P="$TMP/log_a8p"; LOG_A8A="$TMP/log_a8a"; LOG_A8C="$TMP/log_a8c"
mk_player paplay "$LOG_A8P"; mk_player aplay "$LOG_A8A"; mk_player canberra-gtk-play "$LOG_A8C"
out="$(run_notify --sound "$SOUND_A3")"; rc=$?
wait_for_log "$LOG_A8P"
[ "$rc" -eq 0 ] && pass "A8: exit 0 (Linux, all three players present)" || fail "A8: exit $rc"
grep -qF "$SOUND_A3" "$LOG_A8P" 2>/dev/null && pass "A8: paplay chosen over aplay/canberra-gtk-play" || fail "A8: paplay not invoked (log: $(cat "$LOG_A8P" 2>/dev/null))"
[ ! -s "$LOG_A8A" ] && pass "A8: aplay not invoked when paplay is present" || fail "A8: aplay was invoked unexpectedly"
[ ! -s "$LOG_A8C" ] && pass "A8: canberra-gtk-play not invoked when paplay is present" || fail "A8: canberra-gtk-play was invoked unexpectedly"

# ===========================================================================
# Group B — --sound hint honored, including bare-name resolution
# ===========================================================================

# B1: macOS bare-name resolution (no `/` in the hint) — the script builds
# /System/Library/Sounds/<name>.aiff. Adaptive: assert whichever real outcome
# the host filesystem actually produces (the default sound file may or may
# not exist on the CI runner), since that hardcoded system path cannot be
# faked from a temp dir.
reset_stub; mk_uname Darwin
LOG_B1="$TMP/log_b1"; mk_player afplay "$LOG_B1"
out="$(run_notify --sound Glass)"; rc=$?
[ "$rc" -eq 0 ] && pass "B1: exit 0 (bare-name --sound on Darwin)" || fail "B1: exit $rc"
if [ -r "$DEFAULT_MAC" ]; then
  wait_for_log "$LOG_B1"
  grep -qF "$DEFAULT_MAC" "$LOG_B1" 2>/dev/null \
    && pass "B1: bare name 'Glass' resolved to $DEFAULT_MAC" \
    || fail "B1: afplay not invoked with resolved bare-name path (log: $(cat "$LOG_B1" 2>/dev/null))"
else
  [ "$out" = "$BELL" ] \
    && pass "B1: bare name resolved to an unreadable path on this host -> bell (no $DEFAULT_MAC here)" \
    || fail "B1: expected bell fallback when $DEFAULT_MAC is unreadable, got: $(printf '%s' "$out" | od -An -tx1 | tr -d '\n')"
fi

# ===========================================================================
# Group C — unresolvable --sound falls back silently (exit 0, no stderr)
# ===========================================================================

# C1: Darwin + afplay present + --sound pointing at a path that does not
# exist. Whichever channel ultimately fires (default sound file or bell) is
# host-dependent, but the contract under test is: no stderr noise, exit 0.
reset_stub; mk_uname Darwin
LOG_C1="$TMP/log_c1"; mk_player afplay "$LOG_C1"
BOGUS_C1="$TMP/does-not-exist-c1.aiff"
ERR_C1="$TMP/err_c1"
out="$(run_notify --sound "$BOGUS_C1" 2>"$ERR_C1")"; rc=$?
[ "$rc" -eq 0 ] && pass "C1: exit 0 (Darwin, unresolvable --sound path)" || fail "C1: exit $rc"
[ ! -s "$ERR_C1" ] && pass "C1: no stderr noise on an unresolvable --sound" || fail "C1: unexpected stderr: $(cat "$ERR_C1")"
if [ -r "$DEFAULT_MAC" ]; then
  wait_for_log "$LOG_C1"
  grep -qF "$DEFAULT_MAC" "$LOG_C1" 2>/dev/null \
    && pass "C1: silently fell back to the platform default sound" \
    || fail "C1: expected fallback to $DEFAULT_MAC (log: $(cat "$LOG_C1" 2>/dev/null))"
else
  [ "$out" = "$BELL" ] && pass "C1: silently fell back to bell (no default sound file on this host)" || fail "C1: expected bell fallback"
fi

# C2: Linux + paplay present + --sound pointing at a path that does not
# exist -> same contract (exit 0, silent, no stderr).
reset_stub; mk_uname Linux
LOG_C2="$TMP/log_c2"; mk_player paplay "$LOG_C2"
BOGUS_C2="$TMP/does-not-exist-c2.wav"
ERR_C2="$TMP/err_c2"
out="$(run_notify --sound "$BOGUS_C2" 2>"$ERR_C2")"; rc=$?
[ "$rc" -eq 0 ] && pass "C2: exit 0 (Linux, unresolvable --sound path)" || fail "C2: exit $rc"
[ ! -s "$ERR_C2" ] && pass "C2: no stderr noise on an unresolvable --sound" || fail "C2: unexpected stderr: $(cat "$ERR_C2")"
if default_path="$(linux_paplay_default)"; then
  wait_for_log "$LOG_C2"
  grep -qF "$default_path" "$LOG_C2" 2>/dev/null \
    && pass "C2: silently fell back to the platform default sound" \
    || fail "C2: expected fallback to $default_path (log: $(cat "$LOG_C2" 2>/dev/null))"
else
  [ "$out" = "$BELL" ] && pass "C2: silently fell back to bell (paplay present but no path resolved; no default sound file on this host)" || fail "C2: expected bell fallback"
fi

# ===========================================================================
# Group D — arg-parsing edge cases never break the exit-0 contract
# ===========================================================================

# D1: --sound given with no following value.
reset_stub; mk_uname Darwin
mk_player afplay "$TMP/log_d1"
out="$(run_notify --sound)"; rc=$?
[ "$rc" -eq 0 ] && pass "D1: exit 0 when --sound has no value" || fail "D1: exit $rc"

# D2: unknown/bogus flags are ignored, not fatal.
reset_stub; mk_uname Linux
mk_player paplay "$TMP/log_d2"
out="$(run_notify --bogus flag1 flag2)"; rc=$?
[ "$rc" -eq 0 ] && pass "D2: exit 0 with unknown flags" || fail "D2: exit $rc"

# ===========================================================================
# Result
# ===========================================================================
echo ""
if [ "$fails" -eq 0 ]; then
  echo "notify-player-detection (#41): all assertions passed."
  exit 0
else
  echo "notify-player-detection (#41): $fails assertion(s) failed."
  exit 1
fi
