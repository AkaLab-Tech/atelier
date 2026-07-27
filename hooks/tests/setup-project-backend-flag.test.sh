#!/usr/bin/env bash
#
# Regression test for task #36 — /setup-project --backend flag parsing.
#
# BUG: commands/setup-project.md frontmatter advertises
#   [--backend <files|linear|github-project>]
# and Phase 1 passes the operator's $ARGUMENTS through verbatim to
# scripts/atelier-setup-project. The helper's arg-parse loop had no case
# for --backend, so it fell through to the catch-all
#   -*) die "unknown option: $1 (try --help)"
# aborting the whole command before Phase 4a's backend selection could
# ever run.
#
# FIX (scripts/atelier-setup-project, +32 lines):
#   - BACKEND_FLAG="" declaration
#   - --backend <value> (two-arg, shift 2, dies on missing value) and
#     --backend=<value> (shift) parse cases, mirroring --mode
#   - a post-loop validation block accepting files|linear|github-project,
#     dying with the exact Step 4a wording on anything else
#   - a --backend entry in the --help OPTIONS block
#
# Test strategy: invoke the real script binary (not an extracted function —
# the bug lives in the top-level arg-parse loop) with argument combinations
# that short-circuit BEFORE any project work:
#   - "--backend <value> --help" hits the --help case (usage; exit 0)
#     immediately after the --backend case consumes its value, proving the
#     flag is accepted with zero side effects.
#   - invalid / missing value cases die() during parse/validation, also
#     before any project path is required or any file is touched.
# Hermetic: no network, no writes outside $TMP, ATELIER_CONFIG_DIR and HOME
# are isolated to $TMP so nothing touches the operator's real registry even
# if a future change moves this validation later in the script.
#
# Run:  hooks/tests/setup-project-backend-flag.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-setup-project"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# Isolate the environment: no real project registry or $HOME is ever touched,
# even though every case here is expected to exit before project work starts.
FAKE_HOME="$TMP/home"
FAKE_CFG="$TMP/atelier-config"
mkdir -p "$FAKE_HOME" "$FAKE_CFG"
export HOME="$FAKE_HOME"
export ATELIER_CONFIG_DIR="$FAKE_CFG"
unset ATELIER_AUTO 2>/dev/null || true

run_script() {
  # run_script <out-file> <err-file> <args...>  -> sets $rc
  local out="$1" err="$2"
  shift 2
  bash "$SCRIPT" "$@" >"$out" 2>"$err"
  rc=$?
}

# ============================================================
# Case 1 (THE REGRESSION): --backend github-project is accepted, not
# rejected as "unknown option". This is the assertion that fails against
# the pre-fix script.
# ============================================================

OUT1="$TMP/out1"; ERR1="$TMP/err1"
run_script "$OUT1" "$ERR1" --backend github-project --help

if [ "$rc" -eq 0 ]; then
  pass "case1: '--backend github-project --help' exits 0"
else
  fail "case1: '--backend github-project --help' exited $rc, expected 0"
fi

if grep -q 'unknown option' "$ERR1"; then
  fail "case1: stderr contains 'unknown option' — --backend is not recognised (the bug)"
else
  pass "case1: stderr does not contain 'unknown option'"
fi

if grep -q 'atelier-setup-project' "$OUT1"; then
  pass "case1: stdout is the usage banner (proves the --help short-circuit ran)"
else
  fail "case1: stdout does not look like the usage banner: $(cat "$OUT1")"
fi

# ============================================================
# Case 2: equals-form --backend=linear is accepted.
# ============================================================

OUT2="$TMP/out2"; ERR2="$TMP/err2"
run_script "$OUT2" "$ERR2" --backend=linear --help

if [ "$rc" -eq 0 ]; then
  pass "case2: '--backend=linear --help' exits 0"
else
  fail "case2: '--backend=linear --help' exited $rc, expected 0 (stderr: $(cat "$ERR2"))"
fi

if grep -q 'unknown option' "$ERR2"; then
  fail "case2: stderr contains 'unknown option' for --backend=linear"
else
  pass "case2: stderr does not contain 'unknown option' for --backend=linear"
fi

# ============================================================
# Case 3: --backend files is accepted (third of the three valid values).
# ============================================================

OUT3="$TMP/out3"; ERR3="$TMP/err3"
run_script "$OUT3" "$ERR3" --backend files --help

if [ "$rc" -eq 0 ]; then
  pass "case3: '--backend files --help' exits 0"
else
  fail "case3: '--backend files --help' exited $rc, expected 0 (stderr: $(cat "$ERR3"))"
fi

if grep -q 'unknown option' "$ERR3"; then
  fail "case3: stderr contains 'unknown option' for --backend files"
else
  pass "case3: stderr does not contain 'unknown option' for --backend files"
fi

# ============================================================
# Case 4: invalid value is rejected with the exact Step 4a wording.
# ============================================================

OUT4="$TMP/out4"; ERR4="$TMP/err4"
run_script "$OUT4" "$ERR4" --backend bogus

if [ "$rc" -ne 0 ]; then
  pass "case4: '--backend bogus' exits non-zero (got $rc)"
else
  fail "case4: '--backend bogus' exited 0, expected non-zero"
fi

EXPECTED4="Unknown --backend value: 'bogus'. Valid options: files | linear | github-project"
if grep -qF "$EXPECTED4" "$ERR4"; then
  pass "case4: stderr contains the exact Step 4a message"
else
  fail "case4: stderr missing exact message. Expected substring: \"$EXPECTED4\", got: $(cat "$ERR4")"
fi

# ============================================================
# Case 5: --backend as the very last argument (no value) is rejected
# non-zero rather than silently consuming nothing / crashing under set -u.
# ============================================================

OUT5="$TMP/out5"; ERR5="$TMP/err5"
run_script "$OUT5" "$ERR5" --backend

if [ "$rc" -ne 0 ]; then
  pass "case5: trailing '--backend' with no value exits non-zero (got $rc)"
else
  fail "case5: trailing '--backend' with no value exited 0, expected non-zero"
fi

if grep -q 'unbound variable' "$ERR5"; then
  fail "case5: stderr contains 'unbound variable' — the \${2:-} guard is missing"
else
  pass "case5: no 'unbound variable' on stderr (the \${2:-} guard held under set -u)"
fi

EXPECTED5="--backend requires a value: files, linear, or github-project"
if grep -qF -- "$EXPECTED5" "$ERR5"; then
  pass "case5: stderr contains the missing-value message"
else
  fail "case5: stderr missing the expected message. Expected substring: \"$EXPECTED5\", got: $(cat "$ERR5")"
fi

# ============================================================
# Case 6: --help documents --backend (guards help/parser drift — this bug
# was exactly the frontmatter/help advertising a flag the parser rejected).
# ============================================================

OUT6="$TMP/out6"; ERR6="$TMP/err6"
run_script "$OUT6" "$ERR6" --help

if [ "$rc" -eq 0 ]; then
  pass "case6: '--help' alone exits 0"
else
  fail "case6: '--help' alone exited $rc, expected 0"
fi

# Anchor on the OPTIONS-block entry itself (leading whitespace then
# "--backend", the same shape as sibling entries like "  --mode <new|
# existing>" and "  --scaffold-ci"). A bare substring grep for '--backend'
# or 'files|linear|github-project' also matches the pre-existing STDOUT
# MARKERS prose ("atelier-backend=<files|linear|github-project|...>" and
# "delegate to /create-roadmap --backend <choice>"), so this must not be a
# bare substring grep — it has to isolate the OPTIONS row before asserting
# on its contents.
OPTIONS_LINE6="$(grep -E '^[[:space:]]+--backend[[:space:]]' "$OUT6" || true)"

if [ -n "$OPTIONS_LINE6" ]; then
  pass "case6: --help OPTIONS block has a '--backend' entry"
else
  fail "case6: --help OPTIONS block has no '--backend' entry (found: $(grep -- '--backend' "$OUT6" || echo '<nothing>'))"
fi

if printf '%s\n' "$OPTIONS_LINE6" | grep -qF '<files|linear|github-project>'; then
  pass "case6: the --backend OPTIONS entry documents the three accepted values"
else
  fail "case6: the --backend OPTIONS entry does not document '<files|linear|github-project>', got: \"$OPTIONS_LINE6\""
fi

# ============================================================
# Result
# ============================================================
echo ""
if [ "$fails" -eq 0 ]; then
  echo "setup-project --backend flag (#36): all assertions passed."
  exit 0
else
  echo "setup-project --backend flag (#36): $fails assertion(s) failed."
  exit 1
fi
