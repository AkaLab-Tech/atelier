#!/usr/bin/env bash
#
# Tests for task #31 (M7.1.F31) / #45 — doctor check_branch_protection().
#
# #45 rewrote check_branch_protection() to delegate classification AND
# application to the shared external helper scripts/atelier-branch-protection
# (`bash "$helper" --status ... --json` / `--apply ...`) instead of shelling
# out to `gh` and classifying inline. This suite therefore stubs the HELPER
# binary, not `gh` — `gh` is only stubbed for the two calls
# check_branch_protection() still makes directly (nameWithOwner /
# defaultBranchRef repo resolution).
#
# COVERAGE
#   D1  protected-sufficient
#         → OK row mentions "requires approving reviews"; no fix registered
#   D2  protected-noadmin
#         → OK row mentions "is protected"; no fix registered; does NOT
#           report the "no required approving reviews" failure
#   D3  skip:<msg>
#         → SKIP row mentions the message; no fix registered
#   D4  unprotected + admin identity resolves
#         → FAIL row mentions "no required approving reviews"
#         → push_fix_auto (NOT push_fix_manual) registered with the runnable
#           command `... atelier-branch-protection --apply --repo <o/r>
#           --branch <b>` — deliberately WITHOUT --quiet (#45 review, finding
#           4): the doctor's --fix loop now folds the command's stdout into
#           the OK line so the applying identity is surfaced, which needs
#           the command to actually print something.
#   D5  unprotected + NO admin identity resolves
#         → FAIL row
#         → push_fix_manual (NOT push_fix_auto) registered with the
#           instruction text, sourced from the helper's --manual mode (NOT
#           --apply — #45 review, finding 2: a diagnostic-only doctor run
#           must never risk a second, successful admin-identity resolution
#           PUTting a rule); no fix_auto is ever queued (nothing the caller
#           could actually run)
#   D6  protected-insufficient + admin identity resolves
#         → same fix_auto path as D4 (regression: the "insufficient" class
#           must route through the same remediation as "unprotected")
#   D7  no-admin (403-classified)
#         → its OWN $SKIP row (NOT the generic FAIL + push_fix_manual path
#           D5 exercises): a 403 reading the protection detail is evidence
#           of nothing about the required-review count, so asserting FAIL
#           would repeat, for the 403 path, exactly the false-failure #284
#           fixed for the 404 path (#45 review, finding 3) — no fix
#           (auto or manual) is registered
#   D8  atelier-branch-protection helper not found on PATH
#         → SKIP row mentions the helper is missing; no fix registered
#   E1  the top-level `--fix` execution loop (extracted separately, since it
#       is plain script code after all checks run, not a function): a
#       successful fix command's non-empty stdout is folded into the same
#       line as the ✓ OK marker (#45 review, finding 4 — the applying
#       identity must never go silent); a successful command with EMPTY
#       stdout still prints the bare "✓ OK" line unchanged.
#
# Hermetic: gh AND atelier-branch-protection are stubbed on PATH; no network
# calls, no real gh api, no dependency on the operator's ~/.config/gh.
# The git rev-parse check inside check_branch_protection() relies on CWD
# being inside a git repo — this file cd's into $TMP/repo at the start.
# macOS bash 3.2 compatible.
#
# Run:  hooks/tests/doctor-branch-protection.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/atelier-doctor"

command -v jq  >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH";  exit 0; }
command -v git >/dev/null 2>&1 || { echo "  SKIP: git not on PATH"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# =============================================================================
# Setup: temp git repo (needed because check_branch_protection() calls
#   `git rev-parse --is-inside-work-tree` against CWD with no -C flag).
# =============================================================================

mkdir -p "$TMP/repo"
( cd "$TMP/repo" && git init >/dev/null 2>&1 ) || true
cd "$TMP/repo"

# Extract check_branch_protection() from atelier-doctor.
FN_CHECK_BP="$TMP/check_branch_protection.sh"
awk '/^check_branch_protection\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$DOCTOR" > "$FN_CHECK_BP"
if ! grep -q 'no required approving reviews' "$FN_CHECK_BP"; then
  echo "  FAIL: could not extract check_branch_protection() from $DOCTOR"
  exit 1
fi

# Extract the top-level `--fix` execution loop (plain script code, not a
# function — it runs once after every check has populated FIX_AUTO_COMMANDS,
# so there is nothing to `awk`-match by a `name() {` header). Bounded by the
# `APPLIED_OK=0` init line through the column-0 `fi` closing the
# `if [ ${#FIX_AUTO_COMMANDS[@]} -gt 0 ]; then` block — verified stable by
# the grep below, same style as this file's other extraction guards.
FN_FIX_LOOP="$TMP/fix_loop.sh"
awk '/^APPLIED_OK=0$/{f=1} f{print} f&&/^fi$/{exit}' "$DOCTOR" > "$FN_FIX_LOOP"
if ! grep -q 'finding 4' "$FN_FIX_LOOP" || ! grep -q 'APPLIED_OK=\$(( APPLIED_OK + 1 ))' "$FN_FIX_LOOP"; then
  echo "  FAIL: could not extract the --fix execution loop from $DOCTOR"
  exit 1
fi

# =============================================================================
# Stub gh (only the two direct calls check_branch_protection() still makes)
# and atelier-branch-protection (the delegated classify/apply calls).
#
#   gh stub:
#     *"nameWithOwner --jq"*    → "testowner/testrepo"
#     *"defaultBranchRef --jq"* → "main"
#
#   atelier-branch-protection stub, dispatched on $HELPER_CLASS:
#     --status ... --json → {"class": $HELPER_CLASS, "admin_gh_dir": ...}
#       admin_gh_dir is "/tmp/fake-admin" when $HELPER_ADMIN_DIR=1, else null
#     --apply ...          → mimics the real helper's applied path (only
#       reached when check_branch_protection() queues push_fix_auto and the
#       caller — i.e. atelier-doctor --fix's execution loop, not this
#       suite — actually runs the queued command)
#     --manual ...         → mimics the real helper's --manual mode: prints
#       the copy-pasteable manual block on stdout, exits 0 (this is what
#       check_branch_protection() now invokes synchronously to build the
#       push_fix_manual text, per #45 review finding 2 — --apply is never
#       called from the read-only doctor path)
# =============================================================================

mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH"

cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
case "$*" in
  *"nameWithOwner --jq"*)
    printf 'testowner/testrepo\n'
    ;;
  *"defaultBranchRef --jq"*)
    printf 'main\n'
    ;;
  *)
    printf 'gh-stub: unexpected args: %s\n' "$*" >&2
    exit 1
    ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

cat > "$TMP/bin/atelier-branch-protection" << 'SHIMEOF'
#!/usr/bin/env bash
case "$*" in
  *"--status"*)
    admin_gh_dir="null"
    [ "${HELPER_ADMIN_DIR:-0}" = "1" ] && admin_gh_dir='"/tmp/fake-admin"'
    printf '{"repo":"testowner/testrepo","branch":"main","class":"%s","gh_dir":"/tmp/probe","admin_gh_dir":%s}\n' \
      "${HELPER_CLASS:-protected-sufficient}" "$admin_gh_dir"
    exit 0
    ;;
  *"--apply"*)
    if [ "${HELPER_ADMIN_DIR:-0}" = "1" ]; then
      printf 'applied: testowner/testrepo/main now requires >=1 approving review (as fake-admin)\n'
      exit 0
    else
      printf 'No admin identity available to apply branch protection on testowner/testrepo/main.\n'
      printf 'Tried: /tmp/a,/tmp/b,/tmp/c,/tmp/d\n'
      printf 'Apply manually with a repo-admin token:\n'
      printf "  printf '%%s\\\\n' '{\"required_status_checks\":null}' | \\\\\n"
      printf '    gh api -X PUT "repos/testowner/testrepo/branches/main/protection" --input -\n'
      exit 3
    fi
    ;;
  *"--manual"*)
    # The real --manual mode never probes an admin identity — it always
    # prints the same manual block regardless of $HELPER_ADMIN_DIR — and
    # always exits 0 (there is nothing to fail at; it is pure text output).
    printf 'No admin identity available to apply branch protection on testowner/testrepo/main.\n'
    printf 'Tried: /tmp/a,/tmp/b,/tmp/c,/tmp/d\n'
    printf 'Apply manually with a repo-admin token:\n'
    printf "  printf '%%s\\\\n' '{\"required_status_checks\":null}' | \\\\\n"
    printf '    gh api -X PUT "repos/testowner/testrepo/branches/main/protection" --input -\n'
    exit 0
    ;;
  *)
    printf 'atelier-branch-protection-stub: unexpected args: %s\n' "$*" >&2
    exit 1
    ;;
esac
SHIMEOF
chmod +x "$TMP/bin/atelier-branch-protection"

# Provide doctor infrastructure stubs that check_branch_protection() calls.
# Each stub appends its argument to a capture file so assertions can inspect it.
HOST_OUT="$TMP/host_out"
FIX_AUTO_OUT="$TMP/fix_auto_out"
FIX_MANUAL_OUT="$TMP/fix_manual_out"

push_host()       { printf '%s\n' "$*" >> "$HOST_OUT"; }
push_fix_auto()   { printf '%s\n' "$*" >> "$FIX_AUTO_OUT"; }
push_fix_manual() { printf '%s\n' "$*" >> "$FIX_MANUAL_OUT"; }

# Unicode symbols used by the doctor in push_host() calls.
OK="✓"
FAIL="✗"
SKIP="–"

reset_capture() { rm -f "$HOST_OUT" "$FIX_AUTO_OUT" "$FIX_MANUAL_OUT"; unset HELPER_CLASS HELPER_ADMIN_DIR; }

# Run check_branch_protection() in the current shell (CWD is the git repo,
# stubs are on PATH, infrastructure functions are defined above).
run_check() {
  # shellcheck disable=SC1090
  source "$FN_CHECK_BP"
  check_branch_protection
}

echo "Phase D: check_branch_protection() delegates to atelier-branch-protection"

# =============================================================================
# D1 — protected-sufficient: OK row, no fix
# =============================================================================

reset_capture
export HELPER_CLASS="protected-sufficient"
run_check

if [ -f "$HOST_OUT" ] && grep -q "requires approving reviews" "$HOST_OUT"; then
  pass "D1: protected-sufficient → host row mentions 'requires approving reviews'"
else
  fail "D1: protected-sufficient → expected 'requires approving reviews' in host output (got: $(cat "$HOST_OUT" 2>/dev/null || printf '<nothing>'))"
fi

if [ ! -f "$FIX_AUTO_OUT" ] && [ ! -f "$FIX_MANUAL_OUT" ]; then
  pass "D1: protected-sufficient → no fix registered"
else
  fail "D1: protected-sufficient → unexpected fix registered (auto: $(cat "$FIX_AUTO_OUT" 2>/dev/null); manual: $(cat "$FIX_MANUAL_OUT" 2>/dev/null))"
fi

# =============================================================================
# D2 — protected-noadmin: OK row ("is protected"), no fix, no false failure
# =============================================================================

reset_capture
export HELPER_CLASS="protected-noadmin"
run_check

if [ -f "$HOST_OUT" ] && grep -q "is protected" "$HOST_OUT"; then
  pass "D2: protected-noadmin → host row mentions 'is protected'"
else
  fail "D2: protected-noadmin → expected 'is protected' in host output (got: $(cat "$HOST_OUT" 2>/dev/null || printf '<nothing>'))"
fi

if [ -f "$HOST_OUT" ] && grep -q "no required approving reviews" "$HOST_OUT"; then
  fail "D2: protected-noadmin → must NOT report the '✗ no required approving reviews' failure"
else
  pass "D2: protected-noadmin → does not report the false failure row"
fi

if [ ! -f "$FIX_AUTO_OUT" ] && [ ! -f "$FIX_MANUAL_OUT" ]; then
  pass "D2: protected-noadmin → no fix registered (nothing to fix; would be unrunnable)"
else
  fail "D2: protected-noadmin → unexpected fix registered"
fi

# =============================================================================
# D3 — skip:<msg>: SKIP row, no fix
# =============================================================================

reset_capture
export HELPER_CLASS="skip:rate limit exceeded"
run_check

if [ -f "$HOST_OUT" ] && grep -q "rate limit exceeded" "$HOST_OUT"; then
  pass "D3: skip:* → host row mentions the skip message"
else
  fail "D3: skip:* → expected skip message in host output (got: $(cat "$HOST_OUT" 2>/dev/null || printf '<nothing>'))"
fi

if [ ! -f "$FIX_AUTO_OUT" ] && [ ! -f "$FIX_MANUAL_OUT" ]; then
  pass "D3: skip:* → no fix registered"
else
  fail "D3: skip:* → unexpected fix registered"
fi

# =============================================================================
# D4 — unprotected + admin identity resolves: FAIL row + push_fix_auto
#      (THE central assertion: push_fix_auto, NOT push_fix_manual, and the
#      queued command is the runnable atelier-branch-protection --apply
#      invocation.)
# =============================================================================

reset_capture
export HELPER_CLASS="unprotected" HELPER_ADMIN_DIR="1"
run_check

if [ -f "$HOST_OUT" ] && grep -q "no required approving reviews" "$HOST_OUT"; then
  pass "D4: unprotected → host row mentions 'no required approving reviews'"
else
  fail "D4: unprotected → expected 'no required approving reviews' in host output (got: $(cat "$HOST_OUT" 2>/dev/null || printf '<nothing>'))"
fi

if [ -f "$FIX_AUTO_OUT" ]; then
  pass "D4: unprotected + admin resolves → push_fix_auto registered"
else
  fail "D4: unprotected + admin resolves → expected push_fix_auto to be registered but it was not"
fi

if [ ! -f "$FIX_MANUAL_OUT" ]; then
  pass "D4: unprotected + admin resolves → push_fix_manual is NOT registered"
else
  fail "D4: unprotected + admin resolves → unexpected push_fix_manual: $(cat "$FIX_MANUAL_OUT")"
fi

if [ -f "$FIX_AUTO_OUT" ] \
  && grep -q "atelier-branch-protection" "$FIX_AUTO_OUT" \
  && grep -q -- "--apply" "$FIX_AUTO_OUT" \
  && grep -q -- "--repo" "$FIX_AUTO_OUT" \
  && grep -q -- "--branch" "$FIX_AUTO_OUT"; then
  pass "D4: fix_auto command is the runnable 'atelier-branch-protection --apply --repo ... --branch ...'"
else
  fail "D4: fix_auto command missing expected shape (got: $(cat "$FIX_AUTO_OUT" 2>/dev/null || printf '<nothing>'))"
fi

if [ -f "$FIX_AUTO_OUT" ] && ! grep -q -- "--quiet" "$FIX_AUTO_OUT"; then
  pass "D4: fix_auto command deliberately omits --quiet (#45 review finding 4: the --fix loop needs the command's stdout to surface the applying identity)"
else
  fail "D4: fix_auto command unexpectedly contains --quiet (got: $(cat "$FIX_AUTO_OUT" 2>/dev/null || printf '<nothing>'))"
fi

# =============================================================================
# D5 — unprotected + NO admin identity resolves: FAIL row + push_fix_manual
#      (the inverse of D4: no PUT the caller cannot run is ever queued)
# =============================================================================

reset_capture
export HELPER_CLASS="unprotected"
unset HELPER_ADMIN_DIR
run_check

if [ -f "$HOST_OUT" ] && grep -q "no required approving reviews" "$HOST_OUT"; then
  pass "D5: unprotected, no admin → host row mentions 'no required approving reviews'"
else
  fail "D5: unprotected, no admin → expected 'no required approving reviews' in host output (got: $(cat "$HOST_OUT" 2>/dev/null || printf '<nothing>'))"
fi

if [ ! -f "$FIX_AUTO_OUT" ]; then
  pass "D5: unprotected, no admin → push_fix_auto is NOT registered (nothing runnable)"
else
  fail "D5: unprotected, no admin → unexpected push_fix_auto: $(cat "$FIX_AUTO_OUT")"
fi

if [ -f "$FIX_MANUAL_OUT" ] && grep -q "gh api -X PUT" "$FIX_MANUAL_OUT"; then
  pass "D5: unprotected, no admin → push_fix_manual registered with a 'gh api -X PUT' instruction"
else
  fail "D5: unprotected, no admin → expected push_fix_manual with 'gh api -X PUT' (got: $(cat "$FIX_MANUAL_OUT" 2>/dev/null || printf '<nothing>'))"
fi

if [ -f "$FIX_MANUAL_OUT" ] && grep -q "No admin identity available" "$FIX_MANUAL_OUT"; then
  pass "D5: push_fix_manual explains why (no admin identity available)"
else
  fail "D5: push_fix_manual does not explain the no-admin situation (got: $(cat "$FIX_MANUAL_OUT" 2>/dev/null || printf '<nothing>'))"
fi

# =============================================================================
# D6 — protected-insufficient + admin resolves: same fix_auto path as D4
# =============================================================================

reset_capture
export HELPER_CLASS="protected-insufficient" HELPER_ADMIN_DIR="1"
run_check

if [ -f "$FIX_AUTO_OUT" ]; then
  pass "D6: protected-insufficient + admin resolves → push_fix_auto registered"
else
  fail "D6: protected-insufficient + admin resolves → expected push_fix_auto but none registered"
fi

if [ ! -f "$FIX_MANUAL_OUT" ]; then
  pass "D6: protected-insufficient + admin resolves → push_fix_manual is NOT registered"
else
  fail "D6: protected-insufficient + admin resolves → unexpected push_fix_manual"
fi

# =============================================================================
# D7 — no-admin (403-classified): its OWN $SKIP row, no fix registered at all
#      (#45 review, finding 3 — a 403 on the protection read is evidence of
#      NOTHING about the review count; asserting FAIL here would repeat, for
#      the 403 path, the exact false-failure #284 fixed for the 404 path)
# =============================================================================

reset_capture
export HELPER_CLASS="no-admin"
unset HELPER_ADMIN_DIR
run_check

if [ -f "$HOST_OUT" ] && grep -q "lacks permission to read the protection rule" "$HOST_OUT"; then
  pass "D7: no-admin class → SKIP row mentions the token lacks permission to read the rule"
else
  fail "D7: no-admin class → expected a SKIP row about lacking permission (got: $(cat "$HOST_OUT" 2>/dev/null || printf '<nothing>'))"
fi

if [ -f "$HOST_OUT" ] && grep -q "no required approving reviews" "$HOST_OUT"; then
  fail "D7: no-admin class → must NOT report the '✗ no required approving reviews' false failure"
else
  pass "D7: no-admin class → does not report the false failure row"
fi

if [ ! -f "$FIX_AUTO_OUT" ] && [ ! -f "$FIX_MANUAL_OUT" ]; then
  pass "D7: no-admin class → no fix registered (auto or manual) — there is nothing runnable and no evidence to advise on"
else
  fail "D7: no-admin class → unexpected fix registered (auto: $(cat "$FIX_AUTO_OUT" 2>/dev/null); manual: $(cat "$FIX_MANUAL_OUT" 2>/dev/null))"
fi

# =============================================================================
# D8 — atelier-branch-protection helper not found on PATH: SKIP row, no fix
# =============================================================================

reset_capture
rm -f "$TMP/bin/atelier-branch-protection"
unset CLAUDE_PLUGIN_ROOT
run_check

if [ -f "$HOST_OUT" ] && grep -q "helper not found" "$HOST_OUT"; then
  pass "D8: helper missing → host row mentions the helper is missing"
else
  fail "D8: helper missing → expected 'helper not found' in host output (got: $(cat "$HOST_OUT" 2>/dev/null || printf '<nothing>'))"
fi

if [ ! -f "$FIX_AUTO_OUT" ] && [ ! -f "$FIX_MANUAL_OUT" ]; then
  pass "D8: helper missing → no fix registered"
else
  fail "D8: helper missing → unexpected fix registered"
fi

# Restore the helper (Phase E below no longer needs it — it exercises the
# --fix execution loop directly — but keep the fixture tidy).
cat > "$TMP/bin/atelier-branch-protection" << 'SHIMEOF'
#!/usr/bin/env bash
exit 1
SHIMEOF
chmod +x "$TMP/bin/atelier-branch-protection"

# =============================================================================
# Phase E — the top-level `--fix` execution loop: a successful fix command's
# non-empty stdout is folded into the OK line (#45 review, finding 4 — some
# runnables, e.g. atelier-branch-protection --apply, name the identity they
# actually used, and that must never go silent). A silent successful command
# still prints the bare "✓ OK" line unchanged.
# =============================================================================

echo ""
echo "Phase E: --fix execution loop folds a fix command's stdout into the OK line"

run_fix_loop() {
  # shellcheck disable=SC1090,SC2034
  source "$FN_FIX_LOOP"
}

# E1 — a fix command that prints identity text on success: the OK line must
# contain that text verbatim, not just a bare "OK".
FIX_AUTO_COMMANDS=("printf 'applied: testowner/testrepo/main now requires >=1 approving review (as fake-admin)'")
LOOP_OUT="$(run_fix_loop)"

if printf '%s' "$LOOP_OUT" | grep -qF "$OK applied: testowner/testrepo/main now requires >=1 approving review (as fake-admin)"; then
  pass "E1: successful command's non-empty stdout is folded into the OK line"
else
  fail "E1: expected the OK line to include the command's stdout (got: $LOOP_OUT)"
fi

if ! printf '%s' "$LOOP_OUT" | grep -qF "$OK OK"; then
  pass "E1: the bare '✓ OK' line is NOT printed when the command produced output"
else
  fail "E1: unexpectedly printed the bare '✓ OK' line alongside the folded output (got: $LOOP_OUT)"
fi

# E2 — a fix command with EMPTY stdout on success still prints the bare
# "✓ OK" line (regression guard: the fold must not swallow the plain case).
FIX_AUTO_COMMANDS=("true")
LOOP_OUT="$(run_fix_loop)"

if printf '%s' "$LOOP_OUT" | grep -qF "$OK OK"; then
  pass "E2: empty stdout on success still prints the bare '✓ OK' line"
else
  fail "E2: expected the bare '✓ OK' line for a silent successful command (got: $LOOP_OUT)"
fi

# =============================================================================
# Result
# =============================================================================
echo ""
if [ "$fails" -eq 0 ]; then
  echo "doctor-branch-protection (#31/#45): all assertions passed."
  exit 0
else
  echo "doctor-branch-protection (#31/#45): $fails assertion(s) failed."
  exit 1
fi
