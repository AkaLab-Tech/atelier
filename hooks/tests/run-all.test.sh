#!/usr/bin/env bash
#
# Regression test for #693 — hooks/tests/run-all.sh, the parallel runner for
# the hermetic hooks suite, honours its own contract.
#
# run-all.sh discovers tests from its own directory (HERE), so this test copies
# it into throwaway dirs holding only fake *.test.sh files. The real suite is
# never re-run (no recursion).
#
# Contract invariants asserted:
#   - all-pass: exit 0, "ALL PASS" and the summary line
#   - one failing file: exit non-zero, `::error file=<that file>::regression
#     failed`, FAILED line names it, passing siblings still run
#   - zero discovered tests: exit non-zero
#   - --only with no match: exit non-zero; --only with a match runs just that
#   - --serial and -j 4 give the same pass/fail set
#   - output is printed whole, in discovery (sorted) order, even when a later
#     file finishes first
#   - run-all.sh itself is not matched by the *.test.sh glob
#   - bad -j value / unknown flag exit 2
#   - -j / --only with no value or an empty value, -j abc, -jabc, -j 0: exit 2
#     at once with usage on stderr and no test run (never loops; #717)
#
# Hermetic: temp dirs only, no network, HOME redirected.
#
# Run:  hooks/tests/run-all.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

# shellcheck disable=SC2329  # helpers are invoked indirectly through chk
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$HERE/run-all.sh"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
unset ATELIER_TEST_JOBS

# mkdir_suite <name> -> echoes dir containing a copy of run-all.sh
mkdir_suite() {
  local d="$TMP/$1"
  mkdir -p "$d"
  cp "$RUNNER" "$d/run-all.sh"
  printf '%s' "$d"
}

# fake <dir> <basename> <exit-code> [sleep-seconds]
fake() {
  local d="$1" n="$2" rc="$3" s="${4:-0}"
  printf '#!/usr/bin/env bash\nsleep %s\necho "OUT-%s"\nexit %s\n' "$s" "$n" "$rc" >"$d/$n.test.sh"
}

# run <dir> [args...] -> sets OUTTXT and RC
run() {
  local d="$1"
  shift
  OUTTXT="$(bash "$d/run-all.sh" "$@" 2>&1)"
  RC=$?
}

# run_bounded <dir> [args...] -> sets RC, OUTTXT, ERRTXT. Portable watchdog
# (no timeout/gtimeout on macOS): kills the runner after ~10 s and sets RC=124.
run_bounded() {
  local d="$1" pid i=0
  shift
  bash "$d/run-all.sh" "$@" >"$TMP/rb.out" 2>"$TMP/rb.err" </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    pkill -P "$pid" 2>/dev/null
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    RC=124
  else
    wait "$pid" 2>/dev/null
    RC=$?
  fi
  OUTTXT="$(cat "$TMP/rb.out")"
  ERRTXT="$(cat "$TMP/rb.err")"
}

has() { grep -qF -e "$1" <<<"$OUTTXT"; }

nothas() { ! has "$1"; }

# chk <label> <command...> — passes when the command succeeds.
chk() {
  local label="$1"
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

n_errors() { printf '%s\n' "$OUTTXT" | grep -c '::error'; }
both() { has "$1" && has "$2"; }
ordered() { [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] && [ "$1" -lt "$2" ] && [ "$2" -lt "$3" ]; }
failset_ok() { # <set>
  [ "$(grep -c '^::error' <<<"$1")" -eq 2 ] && grep -qF 'FAILED: b.test.sh d.test.sh' <<<"$1"
}

# Group 1 — all pass
D="$(mkdir_suite allpass)"
fake "$D" a 0; fake "$D" b 0; fake "$D" c 0
run "$D" -j 4
chk "all-pass exits 0 (got $RC)" [ "$RC" -eq 0 ]
chk "all-pass prints ALL PASS" has 'ALL PASS'
chk "all-pass summary counts 3 files, 3 passed, 0 failed" has 'files: 3  passed: 3  failed: 0'
chk "all-pass emits no ::error line" nothas '::error'

# Group 2 — one failing file
D="$(mkdir_suite onefail)"
fake "$D" a 0; fake "$D" b 3; fake "$D" c 0
run "$D" -j 4
chk "one failure exits non-zero (got $RC)" [ "$RC" -ne 0 ]
chk "failure emits ::error naming the failing file" has "::error file=$D/b.test.sh::regression failed"
chk "only one ::error line" [ "$(n_errors)" -eq 1 ]
chk "FAILED line names b.test.sh" has 'FAILED: b.test.sh'
chk "summary counts 2 passed, 1 failed" has 'files: 3  passed: 2  failed: 1'
chk "passing siblings still ran" both 'OUT-a' 'OUT-c'

# Group 3 — zero discovered
D="$(mkdir_suite empty)"
run "$D"
chk "zero tests exits non-zero (got $RC)" [ "$RC" -ne 0 ]
chk "zero tests says no tests discovered" has 'no tests discovered'

# Group 4 — --only
D="$(mkdir_suite only)"
fake "$D" alpha 0; fake "$D" beta 0
run "$D" --only 'nomatch*'
chk "--only with no match exits non-zero (got $RC)" [ "$RC" -ne 0 ]
run "$D" --only 'alp*'
chk "--only with a match exits 0 (got $RC)" [ "$RC" -eq 0 ]
chk "--only runs the matching file" has 'OUT-alpha'
chk "--only skips the non-matching file" nothas 'OUT-beta'

# Group 5 — --serial vs -j 4 same pass/fail set
D="$(mkdir_suite modes)"
fake "$D" a 0; fake "$D" b 1; fake "$D" c 0; fake "$D" d 2
run "$D" --serial
rc_s=$RC
set_s="$(printf '%s\n' "$OUTTXT" | grep -E '^(::error|FAILED:)' | sed "s#$D/##" | sort)"
run "$D" -j 4
rc_p=$RC
set_p="$(printf '%s\n' "$OUTTXT" | grep -E '^(::error|FAILED:)' | sed "s#$D/##" | sort)"
chk "--serial exits non-zero (got $rc_s)" [ "$rc_s" -ne 0 ]
chk "-j 4 exits non-zero (got $rc_p)" [ "$rc_p" -ne 0 ]
chk "--serial and -j 4 report the same failures" [ "$set_s" = "$set_p" ]
chk "failure set is exactly b and d" failset_ok "$set_p"

# Group 6 — discovery order, even when an earlier file finishes last
D="$(mkdir_suite order)"
fake "$D" a 0 1; fake "$D" b 0; fake "$D" c 0
run "$D" -j 4
pos() { printf '%s\n' "$OUTTXT" | grep -nF -e "$1" | head -1 | cut -d: -f1; }
pa="$(pos 'OUT-a')"; pb="$(pos 'OUT-b')"; pc="$(pos 'OUT-c')"
chk "slow a is printed before fast b and c (lines $pa/$pb/$pc)" ordered "$pa" "$pb" "$pc"

# Group 7 — runner is not matched by its own glob; arg validation
runner_name="$(basename "$RUNNER")"
case "$runner_name" in *.test.sh) m=1 ;; *) m=0 ;; esac
chk "run-all.sh does not match *.test.sh" [ "$m" -eq 0 ]
D="$(mkdir_suite args)"
fake "$D" a 0
run_bounded "$D" -j 0
chk "-j 0 exits 2 (got $RC)" [ "$RC" -eq 2 ]
run_bounded "$D" --bogus
chk "unknown flag exits 2 (got $RC)" [ "$RC" -eq 2 ]

# Group 8 — value flags fail fast (#717): never loop, never run, never fall back
errhas() { grep -qF -e "$1" <<<"$ERRTXT"; }
value_flag_rejected() { # <label> <args...>
  local label="$1"
  shift
  run_bounded "$D" "$@"
  chk "$label: no hang (got $RC)" [ "$RC" -ne 124 ]
  chk "$label: exits 2 (got $RC)" [ "$RC" -eq 2 ]
  chk "$label: usage on stderr" errhas "Usage:"
  chk "$label: no test run" nothas "OUT-a"
}
value_flag_rejected "-j (no value)" -j
value_flag_rejected "--only (no value)" --only
value_flag_rejected "-j abc" -j abc
value_flag_rejected "-jabc" -jabc
value_flag_rejected "-j ''" -j ""
value_flag_rejected "-j 0" -j 0
value_flag_rejected "--only ''" --only ""

echo ""
if [ "$fails" -eq 0 ]; then
  echo "run-all (#693): all assertions passed."
  exit 0
else
  echo "run-all (#693): $fails assertion(s) failed."
  exit 1
fi
