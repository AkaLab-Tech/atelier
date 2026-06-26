#!/usr/bin/env bash
#
# Tests for task #31 (M7.1.F31) — setup-project detect-and-offer branch protection.
#
# COVERAGE
#   Phase A — classify_branch_protection() : all five output states
#     A1  200 with required_approving_review_count=2   → protected-sufficient
#     A2  200 with required_approving_review_count=0   → protected-insufficient
#     A3  200 with count=1 (boundary)                  → protected-sufficient
#     A4  200 with null required_pull_request_reviews  → protected-insufficient
#     A5  exit 1 + "Branch not protected" stderr       → unprotected
#     A6  exit 1 + "HTTP 404" stderr                   → unprotected
#     A7  exit 1 + "Must have admin" stderr            → no-admin
#     A8  exit 1 + "HTTP 403" stderr                   → no-admin
#     A9  exit 1 + unexpected message                  → skip:*
#
#   Phase B — step_branch_protection() apply path (unprotected + admin + flag):
#     B1  PUT payload enforce_admins = false
#     B2  PUT payload required_approving_review_count = 1
#     B3  PUT payload required_status_checks = null  (never invents checks, AC#3)
#     B4  PUT payload restrictions = null
#     B5  BRANCH_PROTECTION_STATUS set to "applied ..." after successful PUT
#
# Hermetic: gh is stubbed on PATH throughout; no network calls, no real gh api.
# macOS bash 3.2 compatible.
#
# Run:  hooks/tests/setup-project-branch-protection.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-setup-project"

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
# Phase A — classify_branch_protection() unit tests
# =============================================================================

echo "Phase A: classify_branch_protection() classification states"

FN_CLASSIFY="$TMP/classify.sh"
awk '/^classify_branch_protection\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SCRIPT" > "$FN_CLASSIFY"
if ! grep -q 'protected-sufficient' "$FN_CLASSIFY"; then
  echo "  FAIL: could not extract classify_branch_protection() from $SCRIPT"
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

# --- A5: exit 1 + "Branch not protected" stderr → unprotected ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
printf 'Branch not protected\n' >&2
exit 1
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
if [ "$got" = "unprotected" ]; then
  pass "A5: 'Branch not protected' stderr → unprotected"
else
  fail "A5: expected 'unprotected', got '$got'"
fi

# --- A6: exit 1 + "HTTP 404" stderr → unprotected ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
printf 'HTTP 404: Not Found\n' >&2
exit 1
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
if [ "$got" = "unprotected" ]; then
  pass "A6: 'HTTP 404' stderr → unprotected"
else
  fail "A6: expected 'unprotected', got '$got'"
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
# Phase B — step_branch_protection() apply path
#
# Scenario: unprotected repo + author is ADMIN + --apply-branch-protection flag
# Verifies the PUT payload fields and the BRANCH_PROTECTION_STATUS outcome.
# =============================================================================

echo ""
echo "Phase B: step_branch_protection() apply-path payload assertions"

# Extract both functions (classify is called by step internally)
FN_STEP="$TMP/step_functions.sh"
awk '/^classify_branch_protection\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SCRIPT" > "$FN_STEP"
awk '/^step_branch_protection\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SCRIPT" >> "$FN_STEP"

if ! grep -q 'step_branch_protection' "$FN_STEP"; then
  echo "  FAIL: could not extract step_branch_protection() from $SCRIPT"
  exit 1
fi

# Stub dependencies that step_branch_protection() references but are not in
# the extracted fragment (logging helpers from the script's global scope).
warn()   { printf '!!  %s\n' "$*" >&2; }
sublog() { printf '    %s\n' "$*" >&2; }

# Set up a real git repo so `git -C "$PROJECT" rev-parse --is-inside-work-tree` passes.
PROJ_DIR="$TMP/step_project"
mkdir -p "$PROJ_DIR"
( cd "$PROJ_DIR" && git init >/dev/null 2>&1 ) || true

# Set required globals.
ATELIER_CONFIG_DIR="$TMP/atelier"
mkdir -p "$ATELIER_CONFIG_DIR/gh/author"
PROJECT="$PROJ_DIR"
APPLY_BRANCH_PROTECTION_FLAG=true
NONINTERACTIVE=false
BRANCH_PROTECTION_STATUS=""

# Clear any stale counter file from Phase A.
rm -f "$TMP/protection_get_count"

# Write a stateful gh stub.  The protection GET is called twice:
#   call 1 (classify before apply): returns 404 (unprotected)
#   call 2 (classify for re-verify): returns 200 with count=1
# The PUT is intercepted; its --input file is copied to $TMP/put_payload.json.
cat > "$TMP/bin/gh" << SHIMEOF
#!/usr/bin/env bash
SAVE_DIR="${TMP}"
COUNT_FILE="\${SAVE_DIR}/protection_get_count"

case "\$*" in
  *"nameWithOwner,defaultBranchRef"*)
    printf '{"nameWithOwner":"testowner/testrepo","defaultBranchRef":{"name":"main"}}\n'
    ;;
  *"viewerPermission"*)
    printf 'ADMIN\n'
    ;;
  *"-X PUT"*"protection"*)
    prev=""
    for a in "\$@"; do
      if [ "\$prev" = "--input" ]; then
        cp "\$a" "\${SAVE_DIR}/put_payload.json"
        break
      fi
      prev="\$a"
    done
    printf '{"required_pull_request_reviews":{"required_approving_review_count":1}}\n'
    ;;
  *"protection"*)
    count=0
    [ -f "\$COUNT_FILE" ] && count="\$(cat "\$COUNT_FILE")"
    count=\$((count + 1))
    printf '%d' "\$count" > "\$COUNT_FILE"
    if [ "\$count" -le 1 ]; then
      printf 'Branch not protected\n' >&2
      exit 1
    else
      printf '{"required_pull_request_reviews":{"required_approving_review_count":1}}\n'
    fi
    ;;
  *)
    printf 'gh-stub: unexpected args: %s\n' "\$*" >&2
    exit 1
    ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

# Source extracted functions and run the step.
# shellcheck disable=SC1090
source "$FN_STEP"
step_branch_protection

# --- B1: PUT payload has enforce_admins = false ---
if [ -f "$TMP/put_payload.json" ]; then
  enforce_admins="$(jq -r '.enforce_admins' "$TMP/put_payload.json" 2>/dev/null || true)"
  if [ "$enforce_admins" = "false" ]; then
    pass "B1: PUT payload enforce_admins = false"
  else
    fail "B1: PUT payload enforce_admins: expected 'false', got '$enforce_admins'"
  fi
else
  fail "B1: PUT payload file not captured — gh -X PUT was not called"
fi

# --- B2: PUT payload has required_approving_review_count = 1 ---
if [ -f "$TMP/put_payload.json" ]; then
  review_count="$(jq -r '.required_pull_request_reviews.required_approving_review_count' \
    "$TMP/put_payload.json" 2>/dev/null || true)"
  if [ "$review_count" = "1" ]; then
    pass "B2: PUT payload required_approving_review_count = 1"
  else
    fail "B2: PUT payload required_approving_review_count: expected '1', got '$review_count'"
  fi
else
  fail "B2: PUT payload file not captured"
fi

# --- B3: PUT payload has required_status_checks = null (no invented checks, AC#3) ---
if [ -f "$TMP/put_payload.json" ]; then
  status_checks="$(jq -r '.required_status_checks' "$TMP/put_payload.json" 2>/dev/null || true)"
  if [ "$status_checks" = "null" ]; then
    pass "B3: PUT payload required_status_checks = null (no invented checks)"
  else
    fail "B3: PUT payload required_status_checks: expected 'null', got '$status_checks'"
  fi
else
  fail "B3: PUT payload file not captured"
fi

# --- B4: PUT payload has restrictions = null ---
if [ -f "$TMP/put_payload.json" ]; then
  restrictions="$(jq -r '.restrictions' "$TMP/put_payload.json" 2>/dev/null || true)"
  if [ "$restrictions" = "null" ]; then
    pass "B4: PUT payload restrictions = null"
  else
    fail "B4: PUT payload restrictions: expected 'null', got '$restrictions'"
  fi
else
  fail "B4: PUT payload file not captured"
fi

# --- B5: BRANCH_PROTECTION_STATUS indicates "applied" after successful PUT ---
case "$BRANCH_PROTECTION_STATUS" in
  applied*)
    pass "B5: BRANCH_PROTECTION_STATUS = '$BRANCH_PROTECTION_STATUS' (contains 'applied')"
    ;;
  *)
    fail "B5: BRANCH_PROTECTION_STATUS: expected 'applied ...', got '$BRANCH_PROTECTION_STATUS'"
    ;;
esac

# =============================================================================
# Result
# =============================================================================
echo ""
if [ "$fails" -eq 0 ]; then
  echo "setup-project-branch-protection (#31): all assertions passed."
  exit 0
else
  echo "setup-project-branch-protection (#31): $fails assertion(s) failed."
  exit 1
fi
