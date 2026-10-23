#!/usr/bin/env bash
#
# Regression test for #587 — scripts/atelier-cpu-slot is a no-lock pass-through.
# Pins: exit status / args / stdout pass through; --status text; --wait,
# acquire and release return immediately; no lock or queue file is created
# (sandbox dirs and the real /tmp/cpu-slot.* listing are both checked); a nested
# call works; two concurrent runs overlap in time (deterministic rendezvous, no
# timing guess).
#
# Hermetic: every state/temp dir points at a mktemp sandbox; every wait is bounded.
# Portable to GNU/Linux and macOS/BSD.
#
# Run:  hooks/tests/cpu-slot-passthrough.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

# shellcheck disable=SC2015,SC2329 # `A && pass || fail` idiom
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SLOT="$REPO_ROOT/scripts/atelier-cpu-slot"

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

export TMPDIR="$TMP" CPU_SLOT_DIR="$TMP/state" CPU_SLOT_MAX=1 CPU_SLOT_LOCK="$TMP/state/lock"
mkdir -p "$TMP/state"

real_before="$(find /tmp -maxdepth 1 -name 'cpu-slot.*' 2>/dev/null | sort | tr '\n' ' ')"

# --- exit status, args, stdout -------------------------------------------------
"$SLOT" bash -c 'exit 7'; rc=$?
[ "$rc" -eq 7 ] && pass "exit status 7 passes through" || fail "exit status was $rc, expected 7"

out="$("$SLOT" printf '%s|' a 'b c' d)"
[ "$out" = "a|b c|d|" ] && pass "args and stdout pass through" || fail "got '$out'"

# --- --status ------------------------------------------------------------------
out="$("$SLOT" --status)"; rc=$?
{ [ "$out" = "free (no CPU limit)" ] && [ "$rc" -eq 0 ]; } && pass "--status prints 'free (no CPU limit)', exit 0" || fail "--status: '$out' rc=$rc"

# --- --wait / acquire / release return immediately -----------------------------
for args in "--wait" "--wait --timeout 30" "acquire" "release"; do
  start=$SECONDS
  # shellcheck disable=SC2086
  "$SLOT" $args; rc=$?
  el=$((SECONDS - start))
  { [ "$rc" -eq 0 ] && [ "$el" -lt 2 ]; } && pass "'$args' exit 0 in <2s" || fail "'$args' rc=$rc after ${el}s"
done

# --- no arguments / help -------------------------------------------------------
err="$("$SLOT" 2>&1 >/dev/null)"; rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q '^usage:'; } && pass "no args: usage on stderr, exit 2" || fail "no args rc=$rc err='$err'"
"$SLOT" --help | grep -q 'pass-through' && pass "--help prints description" || fail "--help missing description"

# --- nested call ---------------------------------------------------------------
out="$("$SLOT" "$SLOT" "$SLOT" echo nested)"
[ "$out" = "nested" ] && pass "nested call works" || fail "nested got '$out'"

# --- concurrent runs overlap (each waits, bounded, for the other's marker) -----
cat > "$TMP/rendezvous.sh" <<'EOS'
#!/usr/bin/env bash
me="$1"; other="$2"
: > "$me"
i=0
while [ ! -e "$other" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ -e "$other" ]
EOS
"$SLOT" bash "$TMP/rendezvous.sh" "$TMP/a" "$TMP/b" & p1=$!
"$SLOT" bash "$TMP/rendezvous.sh" "$TMP/b" "$TMP/a" & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
{ [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ]; } && pass "two concurrent runs overlap (no serialisation)" || fail "concurrent rc=$r1/$r2"

# --- no lock / queue files -----------------------------------------------------
leftover="$(find "$TMP/state" "$TMP" -maxdepth 2 \( -name 'cpu-slot*' -o -name 'lock*' -o -name '*.queue' \) 2>/dev/null)"
[ -z "$leftover" ] && pass "no lock/queue file in the sandbox" || fail "found: $leftover"
real_after="$(find /tmp -maxdepth 1 -name 'cpu-slot.*' 2>/dev/null | sort | tr '\n' ' ')"
[ "$real_before" = "$real_after" ] && pass "no new /tmp/cpu-slot.* path created" || fail "/tmp/cpu-slot.* changed: '$real_before' -> '$real_after'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
