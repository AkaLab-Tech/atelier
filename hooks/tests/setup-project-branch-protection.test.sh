#!/usr/bin/env bash
#
# Tests for task #31 (M7.1.F31) / #45 — setup-project branch protection step.
#
# #45 extracted classify_branch_protection() (and the inline payload/PUT/
# verify block) out of atelier-setup-project entirely; it now lives only in
# the shared helper scripts/atelier-branch-protection, and
# step_branch_protection() delegates to it as an external binary via
# resolve_branch_protection_helper(). #45 also promoted the step to
# default-on: the old flag -> policy -> TTY-prompt ladder is gone, and
# --apply-branch-protection is now a deprecated no-op (accepted, ignored);
# only --no-branch-protection opts out.
#
# COVERAGE
#   Phase A — classify_branch_protection() : all classification states,
#     now extracted from scripts/atelier-branch-protection (the new single
#     source of truth), not scripts/atelier-setup-project (deleted there).
#
#   Phase B — step_branch_protection() delegation to the external helper:
#     B1  default-on: applies WITHOUT any flag being set (no
#         APPLY_BRANCH_PROTECTION_FLAG needed any more)
#     B2  --no-branch-protection: step is skipped, the helper is never
#         invoked, BRANCH_PROTECTION_STATUS = "declined (--no-branch-protection)"
#     B3  helper-not-found path: when atelier-branch-protection is on none
#         of PATH / $PLUGIN_ROOT/scripts / script-relative dir,
#         BRANCH_PROTECTION_STATUS = "skipped (atelier-branch-protection
#         helper not found)" and the step still returns 0 — silently
#         skipping protection on every fresh install would be the worst
#         failure of this task, so this path is explicitly asserted.
#     B4  no admin identity resolves (helper exits 3): the step still
#         returns 0 (advisory-never-fails), BRANCH_PROTECTION_STATUS is the
#         reason-agnostic "unprotected (could not apply automatically — see
#         warning for manual fix)" — rc 3 now covers both "no admin
#         identity resolved" AND "an admin identity resolved but the
#         existing rule uses a field the helper won't guess at" (#45
#         review), so the wording no longer names "no admin identity"
#         specifically — and the warning relayed to the operator contains a
#         complete copy-pasteable `printf ... | gh api -X PUT ...` block.
#
#   Phase C — CLI arg-parse acceptance (real script binary, --help
#     short-circuit so no project work runs, mirrors
#     setup-project-backend-flag.test.sh's strategy):
#     C1  --apply-branch-protection is still accepted (deprecated no-op)
#     C2  --no-branch-protection is accepted
#
#   Phase D — #45 REVIEW CYCLE-3: step_branch_protection()'s catch-all `*)`
#     case arm (any helper exit code other than 0/3/4 — in practice always 2)
#     was previously untested entirely; before this cycle's fix it also
#     discarded the helper's stderr (2>/dev/null) and ignored $out, collapsing
#     BOTH of the helper's distinct rc-2 reasons into a bare "skipped (branch
#     protection helper exited 2)". D1: the classifier's skip:<msg> shape
#     (e.g. a transient gh 5xx during the initial classify). D2: the new
#     read-failed shape (an unusable admin re-read). Both must fold $out's
#     .message into BRANCH_PROTECTION_STATUS and warn() it, mirroring the
#     0/3/4 arms. D3 (negative companion): when $out carries no parseable
#     .message at all, the bare "helper exited $rc" fallback text is used.
#
# Hermetic: gh and atelier-branch-protection are stubbed on PATH throughout;
# no network calls, no real gh api. macOS bash 3.2 compatible.
#
# Run:  hooks/tests/setup-project-branch-protection.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-setup-project"
HELPER_SCRIPT="$REPO_ROOT/scripts/atelier-branch-protection"

command -v jq  >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH";  exit 0; }
command -v git >/dev/null 2>&1 || { echo "  SKIP: git not on PATH"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH"

AUTH_DIR="$TMP/auth"
mkdir -p "$AUTH_DIR"
OWNER_REPO="testowner/testrepo"
BRANCH="main"

# =============================================================================
# Phase A — classify_branch_protection() unit tests, extracted from the new
# single source of truth: scripts/atelier-branch-protection.
# =============================================================================

echo "Phase A: classify_branch_protection() classification states (scripts/atelier-branch-protection)"

FN_CLASSIFY="$TMP/classify.sh"
awk '/^classify_branch_protection\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$HELPER_SCRIPT" > "$FN_CLASSIFY"
if ! grep -q 'protected-sufficient' "$FN_CLASSIFY"; then
  echo "  FAIL: could not extract classify_branch_protection() from $HELPER_SCRIPT"
  exit 1
fi
# shellcheck disable=SC1090
source "$FN_CLASSIFY"

# --- A1: 200 with count=2 → protected-sufficient ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
printf '{"required_pull_request_reviews":{"required_approving_review_count":2}}\n'
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
if [ "$got" = "protected-sufficient" ]; then
  pass "A1: 200 count=2 → protected-sufficient"
else
  fail "A1: expected 'protected-sufficient', got '$got'"
fi

# --- A2: 200 with count=0 → protected-insufficient ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
printf '{"required_pull_request_reviews":{"required_approving_review_count":0}}\n'
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
if [ "$got" = "protected-insufficient" ]; then
  pass "A2: 200 count=0 → protected-insufficient"
else
  fail "A2: expected 'protected-insufficient', got '$got'"
fi

# --- A3: 200 with count=1 (boundary, the minimum threshold) → protected-sufficient ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
printf '{"required_pull_request_reviews":{"required_approving_review_count":1}}\n'
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
if [ "$got" = "protected-sufficient" ]; then
  pass "A3: 200 count=1 (boundary) → protected-sufficient"
else
  fail "A3: expected 'protected-sufficient', got '$got'"
fi

# --- A4: 200 with null required_pull_request_reviews (missing field) → protected-insufficient ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
printf '{"required_pull_request_reviews":null}\n'
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
if [ "$got" = "protected-insufficient" ]; then
  pass "A4: 200 null reviews block → protected-insufficient"
else
  fail "A4: expected 'protected-insufficient', got '$got'"
fi

# --- A5: exit 1 + "Branch not protected" stderr, branch endpoint says
#     .protected == false → unprotected ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
case "$*" in
  *".protected"*) printf 'false\n' ;;
  *) printf 'Branch not protected\n' >&2; exit 1 ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
if [ "$got" = "unprotected" ]; then
  pass "A5: 'Branch not protected' stderr + .protected=false → unprotected"
else
  fail "A5: expected 'unprotected', got '$got'"
fi

# --- A6: exit 1 + "HTTP 404" stderr, branch endpoint says .protected == false
#     → unprotected ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
case "$*" in
  *".protected"*) printf 'false\n' ;;
  *) printf 'HTTP 404: Not Found\n' >&2; exit 1 ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
if [ "$got" = "unprotected" ]; then
  pass "A6: 'HTTP 404' stderr + .protected=false → unprotected"
else
  fail "A6: expected 'unprotected', got '$got'"
fi

# --- A6b (THE PR #284 twin-fix gap): exit 1 "HTTP 404" from the protection
#     endpoint, but the no-admin-safe branch endpoint reports .protected ==
#     true → protected-noadmin, NOT unprotected. A non-admin token gets a
#     404 (not 403) from GitHub's protection endpoint even when the branch
#     IS protected; classifying that as "unprotected" would make setup
#     propose an overwrite of a rule that already exists. ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
case "$*" in
  *".protected"*) printf 'true\n' ;;
  *) printf 'HTTP 404: Not Found\n' >&2; exit 1 ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
if [ "$got" = "protected-noadmin" ]; then
  pass "A6b: 404 from protection endpoint + .protected=true → protected-noadmin (not unprotected)"
else
  fail "A6b: expected 'protected-noadmin', got '$got'"
fi

# --- A7: exit 1 + "Must have admin" stderr → no-admin ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
printf 'Must have admin rights to Repository.\n' >&2
exit 1
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
if [ "$got" = "no-admin" ]; then
  pass "A7: 'Must have admin' stderr → no-admin"
else
  fail "A7: expected 'no-admin', got '$got'"
fi

# --- A8: exit 1 + "HTTP 403" stderr → no-admin ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
printf 'HTTP 403: Forbidden\n' >&2
exit 1
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
if [ "$got" = "no-admin" ]; then
  pass "A8: 'HTTP 403' stderr → no-admin"
else
  fail "A8: expected 'no-admin', got '$got'"
fi

# --- A9: exit 1 + unexpected message → skip:<msg> ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
printf 'rate limit exceeded\n' >&2
exit 1
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
case "$got" in
  skip:*)
    pass "A9: unexpected error → skip:* (got '$got')"
    ;;
  *)
    fail "A9: expected 'skip:...', got '$got'"
    ;;
esac

# =============================================================================
# Phase B — step_branch_protection() delegation to the external helper
# =============================================================================

echo ""
echo "Phase B: step_branch_protection() delegates to the atelier-branch-protection binary"

# Extract script_dir(), resolve_branch_protection_helper(), and
# step_branch_protection() from atelier-setup-project.
FN_STEP="$TMP/step_functions.sh"
awk '/^script_dir\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SCRIPT" > "$FN_STEP"
awk '/^resolve_branch_protection_helper\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SCRIPT" >> "$FN_STEP"
awk '/^step_branch_protection\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SCRIPT" >> "$FN_STEP"

if ! grep -q 'step_branch_protection' "$FN_STEP"; then
  echo "  FAIL: could not extract step_branch_protection() from $SCRIPT"
  exit 1
fi
if ! grep -q 'resolve_branch_protection_helper' "$FN_STEP"; then
  echo "  FAIL: could not extract resolve_branch_protection_helper() from $SCRIPT"
  exit 1
fi

# Stub dependencies that step_branch_protection() references but are not in
# the extracted fragment (logging helpers from the script's global scope).
WARN_OUT="$TMP/warn_out"
warn()   { printf '%s\n' "$*" >> "$WARN_OUT"; printf '!!  %s\n' "$*" >&2; }
sublog() { printf '    %s\n' "$*" >&2; }

# Set up a real git repo so `git -C "$PROJECT" rev-parse --is-inside-work-tree` passes.
PROJ_DIR="$TMP/step_project"
mkdir -p "$PROJ_DIR"
( cd "$PROJ_DIR" && git init >/dev/null 2>&1 ) || true

# Set required globals.
PROJECT="$PROJ_DIR"
NO_BRANCH_PROTECTION_FLAG=false
BRANCH_PROTECTION_STATUS=""
PLUGIN_ROOT="$TMP/no-such-plugin-root"  # only consulted when PATH lookup fails

# Source extracted functions.
# shellcheck disable=SC1090
source "$FN_STEP"

# gh stub for the repo-resolution call step_branch_protection() makes
# directly: `(cd "$PROJECT" && gh repo view --json nameWithOwner,defaultBranchRef)`.
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
case "$*" in
  *"nameWithOwner,defaultBranchRef"*)
    printf '{"nameWithOwner":"testowner/testrepo","defaultBranchRef":{"name":"main"}}\n'
    ;;
  *)
    printf 'gh-stub: unexpected args: %s\n' "$*" >&2
    exit 1
    ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

# Fake atelier-branch-protection binary, dispatched on $HELPER_MODE.
# Writes a marker file recording the exact invocation so B1 can assert the
# runnable shape of the delegated command.
HELPER_INVOKED="$TMP/helper_invoked"
cat > "$TMP/bin/atelier-branch-protection" << SHIMEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${HELPER_INVOKED}"
case "\${HELPER_MODE:-applied}" in
  applied)
    printf '{"status":"applied","repo":"testowner/testrepo","branch":"main","class":"protected-sufficient","identity":"fake-admin","gh_dir":"/tmp/fake-admin"}\n'
    exit 0
    ;;
  no-admin)
    printf 'No admin identity available to apply branch protection on testowner/testrepo/main.\n'
    printf 'Tried: /tmp/a,/tmp/b,/tmp/c,/tmp/d\n'
    printf 'Apply manually with a repo-admin token:\n'
    printf '  printf %%s '"'"'{"required_status_checks":null,"enforce_admins":false}'"'"' | \\\n'
    printf '    gh api -X PUT "repos/testowner/testrepo/branches/main/protection" --input -\n'
    exit 3
    ;;
  skip-message)
    # The classifier's rc-2 shape (#45): an unexpected error during the
    # initial classify (e.g. a transient gh 5xx), --json still emitted.
    printf '{"status":"skip","repo":"testowner/testrepo","branch":"main","message":"rate limit exceeded"}\n'
    exit 2
    ;;
  read-failed-message)
    # The apply_protection() rc-2 shape (#45 review cycle 3): an unusable
    # admin re-read of the existing rule (empty/unparseable/non-404-error).
    printf '{"status":"read-failed","repo":"testowner/testrepo","branch":"main","class":"protected-insufficient","message":"could not verify the existing rule under the admin identity; refusing to apply without reading it first"}\n'
    exit 2
    ;;
  rc2-no-message)
    # Negative companion: an rc-2 outcome whose stdout carries no parseable
    # .message at all (e.g. jq itself failed) — the bare "helper exited \$rc"
    # fallback text must still be used, not a blank/empty status string.
    printf 'not valid json at all\n'
    exit 2
    ;;
esac
SHIMEOF
chmod +x "$TMP/bin/atelier-branch-protection"

# --- B1: default-on — applies WITHOUT APPLY_BRANCH_PROTECTION_FLAG ever
#     being set (that global does not exist in this extracted fragment at
#     all, proving step_branch_protection() no longer reads it). ---
rm -f "$HELPER_INVOKED"
NO_BRANCH_PROTECTION_FLAG=false
export HELPER_MODE="applied"
step_branch_protection
step_rc=$?

if [ "$step_rc" -eq 0 ]; then
  pass "B1: step_branch_protection() returns 0 on the default-on apply path"
else
  fail "B1: step_branch_protection() returned $step_rc, expected 0"
fi

if [ -f "$HELPER_INVOKED" ] \
  && grep -q -- "--apply" "$HELPER_INVOKED" \
  && grep -q -- "--repo testowner/testrepo" "$HELPER_INVOKED" \
  && grep -q -- "--branch main" "$HELPER_INVOKED"; then
  pass "B1: default-on (no flag set) still invokes the helper with --apply --repo --branch"
else
  fail "B1: helper was not invoked with the expected args (got: $(cat "$HELPER_INVOKED" 2>/dev/null || printf '<not invoked>'))"
fi

case "$BRANCH_PROTECTION_STATUS" in
  applied*)
    pass "B1: BRANCH_PROTECTION_STATUS = '$BRANCH_PROTECTION_STATUS' (contains 'applied')"
    ;;
  *)
    fail "B1: BRANCH_PROTECTION_STATUS: expected 'applied ...', got '$BRANCH_PROTECTION_STATUS'"
    ;;
esac

# --- B2: --no-branch-protection skips the step entirely; the helper is
#     never invoked. ---
rm -f "$HELPER_INVOKED"
NO_BRANCH_PROTECTION_FLAG=true
BRANCH_PROTECTION_STATUS=""
step_branch_protection
step_rc=$?
NO_BRANCH_PROTECTION_FLAG=false

if [ "$step_rc" -eq 0 ]; then
  pass "B2: step_branch_protection() returns 0 under --no-branch-protection"
else
  fail "B2: step_branch_protection() returned $step_rc, expected 0"
fi

if [ "$BRANCH_PROTECTION_STATUS" = "declined (--no-branch-protection)" ]; then
  pass "B2: BRANCH_PROTECTION_STATUS = 'declined (--no-branch-protection)'"
else
  fail "B2: BRANCH_PROTECTION_STATUS: expected 'declined (--no-branch-protection)', got '$BRANCH_PROTECTION_STATUS'"
fi

if [ ! -f "$HELPER_INVOKED" ]; then
  pass "B2: the atelier-branch-protection helper was never invoked"
else
  fail "B2: helper was unexpectedly invoked: $(cat "$HELPER_INVOKED")"
fi

# --- B3: helper-not-found path — with atelier-branch-protection removed
#     from PATH and PLUGIN_ROOT/script_dir() pointing nowhere useful,
#     step_branch_protection() must set the explicit "skipped (helper not
#     found)" status and still return 0. This is the "silently skipping
#     protection on every fresh install" failure the task calls out. ---
rm -f "$HELPER_INVOKED"
mv "$TMP/bin/atelier-branch-protection" "$TMP/bin/atelier-branch-protection.disabled"
NO_BRANCH_PROTECTION_FLAG=false
BRANCH_PROTECTION_STATUS=""
step_branch_protection
step_rc=$?

if [ "$step_rc" -eq 0 ]; then
  pass "B3: step_branch_protection() returns 0 when the helper cannot be found"
else
  fail "B3: step_branch_protection() returned $step_rc, expected 0"
fi

if [ "$BRANCH_PROTECTION_STATUS" = "skipped (atelier-branch-protection helper not found)" ]; then
  pass "B3: BRANCH_PROTECTION_STATUS = 'skipped (atelier-branch-protection helper not found)'"
else
  fail "B3: BRANCH_PROTECTION_STATUS: expected the explicit helper-not-found skip message, got '$BRANCH_PROTECTION_STATUS'"
fi

mv "$TMP/bin/atelier-branch-protection.disabled" "$TMP/bin/atelier-branch-protection"

# --- B4: no admin identity resolves (helper exits 3) — advisory-never-
#     fails: the step still returns 0, BRANCH_PROTECTION_STATUS uses the
#     reason-agnostic "could not apply automatically" wording (rc 3 now also
#     covers the unmergeable-fields refusal, not just no-admin — #45
#     review), and the operator-facing warning contains a COMPLETE
#     copy-pasteable `printf ... | gh api -X PUT ...` block, not just a bare
#     "no admin" message. ---
rm -f "$HELPER_INVOKED" "$WARN_OUT"
export HELPER_MODE="no-admin"
NO_BRANCH_PROTECTION_FLAG=false
BRANCH_PROTECTION_STATUS=""
step_branch_protection
step_rc=$?

if [ "$step_rc" -eq 0 ]; then
  pass "B4: step_branch_protection() returns 0 when no admin identity resolves (advisory, never fails)"
else
  fail "B4: step_branch_protection() returned $step_rc, expected 0"
fi

if [ "$BRANCH_PROTECTION_STATUS" = "unprotected (could not apply automatically — see warning for manual fix)" ]; then
  pass "B4: BRANCH_PROTECTION_STATUS reflects the no-admin outcome"
else
  fail "B4: BRANCH_PROTECTION_STATUS: got '$BRANCH_PROTECTION_STATUS'"
fi

if [ -f "$WARN_OUT" ] \
  && grep -q "printf" "$WARN_OUT" \
  && grep -q -- "--input -" "$WARN_OUT" \
  && grep -q "gh api -X PUT" "$WARN_OUT" \
  && grep -q "branches/main/protection" "$WARN_OUT"; then
  pass "B4: warning contains a complete copy-pasteable 'printf ... | gh api -X PUT ...' block"
else
  fail "B4: warning missing the complete manual block (got: $(cat "$WARN_OUT" 2>/dev/null || printf '<nothing>'))"
fi

unset HELPER_MODE

# =============================================================================
# Phase D — #45 REVIEW CYCLE-3: step_branch_protection()'s catch-all `*)` arm
# (any helper exit code other than 0/3/4) was previously untested entirely.
# Before this cycle's fix it also discarded stderr (2>/dev/null) and ignored
# $out, collapsing BOTH of the helper's distinct rc-2 reasons into a bare
# "skipped (branch protection helper exited 2)" — losing the operator-facing
# reason in both cases.
# =============================================================================

echo ""
echo "Phase D: step_branch_protection()'s catch-all *) arm reads \$out's .message on rc 2"

# --- D1: the classifier's skip:<msg> shape (rc 2) ---
rm -f "$HELPER_INVOKED" "$WARN_OUT"
export HELPER_MODE="skip-message"
NO_BRANCH_PROTECTION_FLAG=false
BRANCH_PROTECTION_STATUS=""
step_branch_protection
step_rc=$?

if [ "$step_rc" -eq 0 ]; then
  pass "D1: step_branch_protection() returns 0 on the classifier's skip:<msg> rc-2 shape (advisory, never fails)"
else
  fail "D1: step_branch_protection() returned $step_rc, expected 0"
fi

if [ "$BRANCH_PROTECTION_STATUS" = "skipped (rate limit exceeded)" ]; then
  pass "D1: BRANCH_PROTECTION_STATUS folds \$out's .message into the skipped(...) text"
else
  fail "D1: BRANCH_PROTECTION_STATUS: expected 'skipped (rate limit exceeded)', got '$BRANCH_PROTECTION_STATUS'"
fi

if [ -f "$WARN_OUT" ] && grep -q "rate limit exceeded" "$WARN_OUT"; then
  pass "D1: warn() fired with the classifier's message"
else
  fail "D1: expected warn() to fire with 'rate limit exceeded' (got: $(cat "$WARN_OUT" 2>/dev/null || printf '<nothing>'))"
fi

# --- D2: the apply_protection() read-failed shape (rc 2) — the specific
#     regression this task's fix cycle targeted: previously this and D1
#     collapsed to the SAME bare "helper exited 2" text, discarding which of
#     the two distinct reasons actually happened. ---
rm -f "$HELPER_INVOKED" "$WARN_OUT"
export HELPER_MODE="read-failed-message"
NO_BRANCH_PROTECTION_FLAG=false
BRANCH_PROTECTION_STATUS=""
step_branch_protection
step_rc=$?

if [ "$step_rc" -eq 0 ]; then
  pass "D2: step_branch_protection() returns 0 on the read-failed rc-2 shape (advisory, never fails)"
else
  fail "D2: step_branch_protection() returned $step_rc, expected 0"
fi

if [ "$BRANCH_PROTECTION_STATUS" = "skipped (could not verify the existing rule under the admin identity; refusing to apply without reading it first)" ]; then
  pass "D2: BRANCH_PROTECTION_STATUS folds the read-failed .message into the skipped(...) text (distinct from D1's classifier message)"
else
  fail "D2: BRANCH_PROTECTION_STATUS: got '$BRANCH_PROTECTION_STATUS'"
fi

if [ -f "$WARN_OUT" ] && grep -q "could not verify the existing rule under the admin identity" "$WARN_OUT"; then
  pass "D2: warn() fired with the read-failed message"
else
  fail "D2: expected warn() to fire with the read-failed message (got: $(cat "$WARN_OUT" 2>/dev/null || printf '<nothing>'))"
fi

# --- D3 (negative companion): rc 2 with no parseable .message at all -> the
#     bare "helper exited $rc" fallback text is used, not an empty status. ---
rm -f "$HELPER_INVOKED" "$WARN_OUT"
export HELPER_MODE="rc2-no-message"
NO_BRANCH_PROTECTION_FLAG=false
BRANCH_PROTECTION_STATUS=""
step_branch_protection
step_rc=$?

if [ "$step_rc" -eq 0 ]; then
  pass "D3: step_branch_protection() returns 0 on an rc-2 outcome with no parseable message"
else
  fail "D3: step_branch_protection() returned $step_rc, expected 0"
fi

if [ "$BRANCH_PROTECTION_STATUS" = "skipped (branch protection helper exited 2)" ]; then
  pass "D3: BRANCH_PROTECTION_STATUS falls back to the bare 'helper exited 2' text when \$out has no .message"
else
  fail "D3: BRANCH_PROTECTION_STATUS: expected 'skipped (branch protection helper exited 2)', got '$BRANCH_PROTECTION_STATUS'"
fi

unset HELPER_MODE

# =============================================================================
# Phase C — CLI arg-parse acceptance (real script binary via --help
# short-circuit, mirrors setup-project-backend-flag.test.sh)
# =============================================================================

echo ""
echo "Phase C: CLI flags are accepted without tripping 'unknown option'"

run_help() {
  # run_help <out-file> <err-file> <args...> -> sets $rc
  local out="$1" err="$2"
  shift 2
  bash "$SCRIPT" "$@" --help >"$out" 2>"$err"
  rc=$?
}

OUT_C1="$TMP/out_c1"; ERR_C1="$TMP/err_c1"
run_help "$OUT_C1" "$ERR_C1" --apply-branch-protection

if [ "$rc" -eq 0 ] && ! grep -q "unknown option" "$ERR_C1"; then
  pass "C1: --apply-branch-protection is still accepted (deprecated no-op)"
else
  fail "C1: --apply-branch-protection rejected (rc=$rc, stderr: $(cat "$ERR_C1" 2>/dev/null))"
fi

OUT_C2="$TMP/out_c2"; ERR_C2="$TMP/err_c2"
run_help "$OUT_C2" "$ERR_C2" --no-branch-protection

if [ "$rc" -eq 0 ] && ! grep -q "unknown option" "$ERR_C2"; then
  pass "C2: --no-branch-protection is accepted"
else
  fail "C2: --no-branch-protection rejected (rc=$rc, stderr: $(cat "$ERR_C2" 2>/dev/null))"
fi

# =============================================================================
# Result
# =============================================================================
echo ""
if [ "$fails" -eq 0 ]; then
  echo "setup-project-branch-protection (#31/#45): all assertions passed."
  exit 0
else
  echo "setup-project-branch-protection (#31/#45): $fails assertion(s) failed."
  exit 1
fi
