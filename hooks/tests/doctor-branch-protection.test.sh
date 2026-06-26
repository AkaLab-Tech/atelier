#!/usr/bin/env bash
#
# Tests for task #31 (M7.1.F31) — doctor check_branch_protection().
#
# COVERAGE
#   C1  protected-sufficient (200, count=1)
#         → push_host receives OK row mentioning "requires approving reviews"
#         → no fix block registered
#   C2  unprotected (404 "Branch not protected")
#         → push_host receives FAIL row mentioning "no required approving reviews"
#         → push_fix_auto registered (perm=ADMIN path)
#   C3  no-admin (403 "Must have admin")
#         → push_host receives SKIP row
#         → no fix block registered
#   C4  protected-insufficient (200, count=0)
#         → push_host receives FAIL row mentioning "no required approving reviews"
#         → push_fix_auto registered (perm=ADMIN path)
#
# Hermetic: gh is stubbed on PATH; no network calls.
# The git rev-parse check inside check_branch_protection() relies on CWD being
# inside a git repo — this file cd's into $TMP/repo at the start of the test.
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

# =============================================================================
# Stub the gh binary and doctor infrastructure.
#
# The stub dispatches on $* (all args as a string):
#   *"nameWithOwner --jq"*    → output "testowner/testrepo"
#   *"defaultBranchRef --jq"* → output "main"
#   *"viewerPermission"*      → output "ADMIN"
#   *"protection"*            → behaviour controlled by $PROTECT_RESPONSE env var
#     "200-sufficient"        → exit 0, JSON with count=1
#     "200-insufficient"      → exit 0, JSON with count=0
#     "404"                   → exit 1, "Branch not protected" on stderr
#     "403"                   → exit 1, "Must have admin" on stderr
#
# The PROTECT_RESPONSE env var must be exported before each test run.
# =============================================================================

mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH"

cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
PROTECT_RESPONSE="${PROTECT_RESPONSE:-404}"
case "$*" in
  *"nameWithOwner --jq"*)
    printf 'testowner/testrepo\n'
    ;;
  *"defaultBranchRef --jq"*)
    printf 'main\n'
    ;;
  *"viewerPermission"*)
    printf 'ADMIN\n'
    ;;
  *"protection"*)
    case "$PROTECT_RESPONSE" in
      200-sufficient)
        printf '{"required_pull_request_reviews":{"required_approving_review_count":1}}\n'
        ;;
      200-insufficient)
        printf '{"required_pull_request_reviews":{"required_approving_review_count":0}}\n'
        ;;
      404)
        printf 'Branch not protected\n' >&2
        exit 1
        ;;
      403)
        printf 'Must have admin rights to Repository.\n' >&2
        exit 1
        ;;
      *)
        printf 'gh-stub: unknown PROTECT_RESPONSE: %s\n' "$PROTECT_RESPONSE" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    printf 'gh-stub: unexpected args: %s\n' "$*" >&2
    exit 1
    ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

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

# Set ATELIER_CONFIG_DIR so check_branch_protection() resolves author_dir.
ATELIER_CONFIG_DIR="$TMP/atelier"
mkdir -p "$ATELIER_CONFIG_DIR/gh/author"

reset_capture() { rm -f "$HOST_OUT" "$FIX_AUTO_OUT" "$FIX_MANUAL_OUT"; }

# Run check_branch_protection() in the current shell (CWD is the git repo,
# stubs are on PATH, infrastructure functions are defined above).
run_check() {
  # shellcheck disable=SC1090
  source "$FN_CHECK_BP"
  check_branch_protection
}

# =============================================================================
# C1 — protected-sufficient: OK row, no fix
# =============================================================================

echo "Phase C: check_branch_protection() output scenarios"

reset_capture
export PROTECT_RESPONSE="200-sufficient"
run_check

if [ -f "$HOST_OUT" ] && grep -q "requires approving reviews" "$HOST_OUT"; then
  pass "C1: protected-sufficient → host row mentions 'requires approving reviews'"
else
  fail "C1: protected-sufficient → expected 'requires approving reviews' in host output (got: $(cat "$HOST_OUT" 2>/dev/null || printf '<nothing>'))"
fi

if [ ! -f "$FIX_AUTO_OUT" ]; then
  pass "C1: protected-sufficient → no fix_auto registered"
else
  fail "C1: protected-sufficient → unexpected fix_auto: $(cat "$FIX_AUTO_OUT")"
fi

if [ ! -f "$FIX_MANUAL_OUT" ]; then
  pass "C1: protected-sufficient → no fix_manual registered"
else
  fail "C1: protected-sufficient → unexpected fix_manual: $(cat "$FIX_MANUAL_OUT")"
fi

# =============================================================================
# C2 — unprotected (404): FAIL row + fix_auto registered (admin path)
# =============================================================================

reset_capture
export PROTECT_RESPONSE="404"
run_check

if [ -f "$HOST_OUT" ] && grep -q "no required approving reviews" "$HOST_OUT"; then
  pass "C2: unprotected → host row mentions 'no required approving reviews'"
else
  fail "C2: unprotected → expected 'no required approving reviews' in host output (got: $(cat "$HOST_OUT" 2>/dev/null || printf '<nothing>'))"
fi

if [ -f "$FIX_AUTO_OUT" ]; then
  pass "C2: unprotected → fix_auto registered (admin path)"
else
  fail "C2: unprotected → expected fix_auto to be registered but it was not"
fi

# The registered fix_auto command must include the correct PUT endpoint.
if [ -f "$FIX_AUTO_OUT" ] && grep -q "gh api -X PUT" "$FIX_AUTO_OUT"; then
  pass "C2: fix_auto contains 'gh api -X PUT'"
else
  fail "C2: fix_auto does not contain 'gh api -X PUT' (got: $(cat "$FIX_AUTO_OUT" 2>/dev/null || printf '<nothing>'))"
fi

# =============================================================================
# C3 — no-admin (403): SKIP row, no fix
# =============================================================================

reset_capture
export PROTECT_RESPONSE="403"
run_check

if [ -f "$HOST_OUT" ] && grep -q "token lacks repo-admin" "$HOST_OUT"; then
  pass "C3: no-admin → host row mentions 'token lacks repo-admin'"
else
  fail "C3: no-admin → expected 'token lacks repo-admin' in host output (got: $(cat "$HOST_OUT" 2>/dev/null || printf '<nothing>'))"
fi

if [ ! -f "$FIX_AUTO_OUT" ]; then
  pass "C3: no-admin → no fix_auto registered (cannot apply without admin)"
else
  fail "C3: no-admin → unexpected fix_auto: $(cat "$FIX_AUTO_OUT")"
fi

# =============================================================================
# C4 — protected-insufficient (200, count=0): FAIL row + fix_auto (admin path)
# =============================================================================

reset_capture
export PROTECT_RESPONSE="200-insufficient"
run_check

if [ -f "$HOST_OUT" ] && grep -q "no required approving reviews" "$HOST_OUT"; then
  pass "C4: protected-insufficient → host row mentions 'no required approving reviews'"
else
  fail "C4: protected-insufficient → expected 'no required approving reviews' in host output (got: $(cat "$HOST_OUT" 2>/dev/null || printf '<nothing>'))"
fi

if [ -f "$FIX_AUTO_OUT" ]; then
  pass "C4: protected-insufficient → fix_auto registered (admin path)"
else
  fail "C4: protected-insufficient → expected fix_auto to be registered but it was not"
fi

# =============================================================================
# Result
# =============================================================================
echo ""
if [ "$fails" -eq 0 ]; then
  echo "doctor-branch-protection (#31): all assertions passed."
  exit 0
else
  echo "doctor-branch-protection (#31): $fails assertion(s) failed."
  exit 1
fi
