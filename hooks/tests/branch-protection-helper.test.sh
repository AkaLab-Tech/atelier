#!/usr/bin/env bash
#
# Tests for task #45 — scripts/atelier-branch-protection, the single source
# of truth for branch-protection classification and application. Extracted
# out of the two hand-copied variants that used to live in
# atelier-setup-project and atelier-doctor (see that script's own header
# comment for the history).
#
# COVERAGE
#   Phase A — classify_branch_protection() classification states, extracted
#     directly from scripts/atelier-branch-protection (function-level unit
#     tests). THE central assertion in this suite is A5 (protected-noadmin):
#     a 404 from the protection endpoint whose branch-detail endpoint
#     reports .protected == true classifies as protected-noadmin, NOT
#     unprotected — the twin-fix gap PR #284 left open in setup-project.
#
#   Phase B — resolve_admin_gh_dir() candidate ORDER, extracted directly
#     (admin_candidate_dirs() + resolve_admin_gh_dir()):
#       1. $ATELIER_ADMIN_GH_CONFIG_DIR
#       2. $ATELIER_CONFIG_DIR/gh/admin
#       3. $ATELIER_CONFIG_DIR/gh/author
#       4. ${XDG_CONFIG_HOME:-$HOME/.config}/gh
#     asserts the FIRST qualifying candidate wins even when a later one also
#     qualifies, and that resolve_admin_gh_dir returns empty + rc 1 when no
#     candidate directory even exists.
#
#   Phase C — merge-not-overwrite PUT payload, black-box through the real
#     CLI (`--apply`, since apply_protection()'s payload builder is not
#     safely extractable in isolation — it depends on classify_branch_
#     protection(), MIN_PAYLOAD, and jq state that only exist together at
#     the top level). On a protected-insufficient branch, the payload must
#     PRESERVE required_status_checks / dismiss_stale_reviews /
#     require_code_owner_reviews from the existing rule while FORCING
#     required_approving_review_count=1, enforce_admins=false (load-bearing:
#     true would block the bot's own squash-merges), restrictions=null.
#
#   Phase D — exit code 3 + the manual instruction block on stdout when no
#     admin identity resolves at all — asserted both with and without
#     --json, since the header comment promises the block prints "on
#     stdout regardless of --json".
#
#   Phase E — --help usage, `bash -n`, and the executable bit.
#
#   Phase F — cheap regression guards:
#     F1  classify_branch_protection lives in exactly ONE file under
#         scripts/ (grep -rc 'Branch not protected' scripts/ has exactly
#         one non-zero match, and it is scripts/atelier-branch-protection).
#     F2  install.sh symlinks atelier-branch-protection in Phase C.1.
#
# Hermetic: gh is stubbed on PATH throughout; no network calls, no writes
# outside $TMP, no dependency on the operator's real ~/.config/gh (HOME,
# XDG_CONFIG_HOME, and ATELIER_CONFIG_DIR are all pinned inside $TMP for
# every subprocess invocation of the real CLI).
# macOS bash 3.2 compatible.
#
# Run:  hooks/tests/branch-protection-helper.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER_SCRIPT="$REPO_ROOT/scripts/atelier-branch-protection"
INSTALL_SH="$REPO_ROOT/install.sh"

command -v jq  >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH";  exit 0; }
command -v git >/dev/null 2>&1 || { echo "  SKIP: git not on PATH"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

mkdir -p "$TMP/bin"
export PATH="$TMP/bin:$PATH"

OWNER_REPO="testowner/testrepo"
BRANCH="main"
AUTH_DIR="$TMP/probe-identity"
mkdir -p "$AUTH_DIR"

# =============================================================================
# Phase A — classify_branch_protection() classification states
# =============================================================================

echo "Phase A: classify_branch_protection() classification states"

FN_CLASSIFY="$TMP/classify.sh"
awk '/^classify_branch_protection\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$HELPER_SCRIPT" > "$FN_CLASSIFY"
if ! grep -q 'protected-sufficient' "$FN_CLASSIFY"; then
  echo "  FAIL: could not extract classify_branch_protection() from $HELPER_SCRIPT"
  exit 1
fi
# shellcheck disable=SC1090
source "$FN_CLASSIFY"

# --- A1: 200, count=2 → protected-sufficient ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
printf '{"required_pull_request_reviews":{"required_approving_review_count":2}}\n'
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
[ "$got" = "protected-sufficient" ] \
  && pass "A1: 200 count=2 → protected-sufficient" \
  || fail "A1: expected 'protected-sufficient', got '$got'"

# --- A2: 200, count=0 → protected-insufficient ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
printf '{"required_pull_request_reviews":{"required_approving_review_count":0}}\n'
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
[ "$got" = "protected-insufficient" ] \
  && pass "A2: 200 count=0 → protected-insufficient" \
  || fail "A2: expected 'protected-insufficient', got '$got'"

# --- A3: 404, branch endpoint .protected=false → unprotected ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
case "$*" in
  *".protected"*) printf 'false\n' ;;
  *) printf 'Branch not protected\n' >&2; exit 1 ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
[ "$got" = "unprotected" ] \
  && pass "A3: 404 + .protected=false → unprotected" \
  || fail "A3: expected 'unprotected', got '$got'"

# --- A4: 403 ("Must have admin") → no-admin ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
printf 'Must have admin rights to Repository.\n' >&2
exit 1
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
[ "$got" = "no-admin" ] \
  && pass "A4: 'Must have admin' stderr → no-admin" \
  || fail "A4: expected 'no-admin', got '$got'"

# --- A5 (THE CENTRAL ASSERTION — PR #284's twin-fix gap): 404 from the
#     protection endpoint ("Branch not protected"), but the no-admin-safe
#     branch-detail endpoint reports .protected == true → protected-noadmin,
#     NOT unprotected. GitHub returns 404 (not 403) to a non-admin token
#     even when the branch IS protected; misclassifying this as unprotected
#     would make a caller propose overwriting a rule that already exists,
#     using an identity that cannot even read it. ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
case "$*" in
  *".protected"*) printf 'true\n' ;;
  *) printf 'Branch not protected\n' >&2; exit 1 ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
[ "$got" = "protected-noadmin" ] \
  && pass "A5: 404 from protection endpoint + .protected=true → protected-noadmin (not unprotected)" \
  || fail "A5: expected 'protected-noadmin', got '$got'"

# --- A5b: same but via the literal "HTTP 404" stderr spelling, to prove
#     the disambiguation triggers on every 404 message shape the code
#     matches, not just "Branch not protected". ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
case "$*" in
  *".protected"*) printf 'true\n' ;;
  *) printf 'HTTP 404: Not Found\n' >&2; exit 1 ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
[ "$got" = "protected-noadmin" ] \
  && pass "A5b: 'HTTP 404' stderr + .protected=true → protected-noadmin" \
  || fail "A5b: expected 'protected-noadmin', got '$got'"

# --- A6: unexpected error → skip:<msg> ---
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
printf 'rate limit exceeded\n' >&2
exit 1
SHIMEOF
chmod +x "$TMP/bin/gh"

got="$(classify_branch_protection "$AUTH_DIR" "$OWNER_REPO" "$BRANCH")"
case "$got" in
  skip:*) pass "A6: unexpected error → skip:* (got '$got')" ;;
  *)      fail "A6: expected 'skip:...', got '$got'" ;;
esac

# =============================================================================
# Phase B — resolve_admin_gh_dir() candidate order
# =============================================================================

echo ""
echo "Phase B: resolve_admin_gh_dir() candidate order"

FN_RESOLVE="$TMP/resolve.sh"
awk '/^admin_candidate_dirs\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$HELPER_SCRIPT" > "$FN_RESOLVE"
awk '/^resolve_admin_gh_dir\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$HELPER_SCRIPT" >> "$FN_RESOLVE"
if ! grep -q 'resolve_admin_gh_dir' "$FN_RESOLVE"; then
  echo "  FAIL: could not extract resolve_admin_gh_dir() from $HELPER_SCRIPT"
  exit 1
fi
# shellcheck disable=SC1090
source "$FN_RESOLVE"

# gh stub for viewerPermission: dispatches on the GH_CONFIG_DIR passed via
# `env GH_CONFIG_DIR=<candidate> gh repo view ...`, reading a `perm` file
# written into each candidate directory by the test cases below.
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
case "$*" in
  *"viewerPermission"*)
    permfile="${GH_CONFIG_DIR:-}/perm"
    if [ -f "$permfile" ]; then cat "$permfile"; else printf 'NONE\n'; fi
    ;;
  *)
    printf 'gh-stub: unexpected args: %s\n' "$*" >&2
    exit 1
    ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

CAND1="$TMP/cand1-explicit-override"          # $ATELIER_ADMIN_GH_CONFIG_DIR
ATELIER_CFG_B="$TMP/atelier-cfg"
CAND2="$ATELIER_CFG_B/gh/admin"                # $ATELIER_CONFIG_DIR/gh/admin
CAND3="$ATELIER_CFG_B/gh/author"               # $ATELIER_CONFIG_DIR/gh/author
CAND4="$TMP/cand4-xdg-default/gh"              # ${XDG_CONFIG_HOME}/gh

setup_candidates() {
  rm -rf "$CAND1" "$ATELIER_CFG_B" "$CAND4"
  mkdir -p "$CAND1" "$CAND2" "$CAND3" "$CAND4"
  export ATELIER_ADMIN_GH_CONFIG_DIR="$CAND1"
  export ATELIER_CONFIG_DIR="$ATELIER_CFG_B"
  export XDG_CONFIG_HOME="$TMP/cand4-xdg-default"
}

# --- B1: only candidate 3 (author) reports ADMIN → resolve returns it ---
setup_candidates
printf 'WRITE\n' > "$CAND1/perm"
printf 'WRITE\n' > "$CAND2/perm"
printf 'ADMIN\n' > "$CAND3/perm"
printf 'WRITE\n' > "$CAND4/perm"

got="$(resolve_admin_gh_dir "$OWNER_REPO")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$got" = "$CAND3" ]; then
  pass "B1: only candidate 3 (author) is ADMIN → resolved to candidate 3"
else
  fail "B1: expected candidate 3 ('$CAND3'), got '$got' (rc=$rc)"
fi

# --- B2: candidates 1 AND 3 both report ADMIN → order wins, resolve
#     returns candidate 1 (the explicit override), not candidate 3 ---
setup_candidates
printf 'ADMIN\n' > "$CAND1/perm"
printf 'WRITE\n' > "$CAND2/perm"
printf 'ADMIN\n' > "$CAND3/perm"
printf 'ADMIN\n' > "$CAND4/perm"

got="$(resolve_admin_gh_dir "$OWNER_REPO")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$got" = "$CAND1" ]; then
  pass "B2: candidates 1 and 3 both ADMIN → resolved to candidate 1 (first in order)"
else
  fail "B2: expected candidate 1 ('$CAND1'), got '$got' (rc=$rc)"
fi

# --- B3: only candidate 4 (XDG default, last in order) reports ADMIN ---
setup_candidates
printf 'WRITE\n' > "$CAND1/perm"
printf 'NONE\n'  > "$CAND2/perm"
printf 'WRITE\n' > "$CAND3/perm"
printf 'ADMIN\n' > "$CAND4/perm"

got="$(resolve_admin_gh_dir "$OWNER_REPO")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$got" = "$CAND4" ]; then
  pass "B3: only candidate 4 (XDG default) is ADMIN → resolved to candidate 4 (last resort)"
else
  fail "B3: expected candidate 4 ('$CAND4'), got '$got' (rc=$rc)"
fi

# --- B4: none of the candidates report ADMIN → empty output, rc 1 ---
setup_candidates
printf 'WRITE\n' > "$CAND1/perm"
printf 'WRITE\n' > "$CAND2/perm"
printf 'NONE\n'  > "$CAND3/perm"
printf 'READ\n'  > "$CAND4/perm"

got="$(resolve_admin_gh_dir "$OWNER_REPO")"; rc=$?
if [ "$rc" -eq 1 ] && [ -z "$got" ]; then
  pass "B4: no candidate qualifies → empty output, rc 1"
else
  fail "B4: expected empty output + rc 1, got output='$got' rc=$rc"
fi

unset ATELIER_ADMIN_GH_CONFIG_DIR ATELIER_CONFIG_DIR XDG_CONFIG_HOME

# =============================================================================
# Phase C — merge-not-overwrite PUT payload (black-box through the real CLI)
# =============================================================================

echo ""
echo "Phase C: apply_protection() merge-not-overwrite PUT payload"

# Isolated environment for every CLI subprocess in Phases C and D: pinned
# HOME/XDG_CONFIG_HOME/ATELIER_CONFIG_DIR inside $TMP, gh shadowed first on
# PATH — the operator's real ~/.config/gh is never consulted.
CLI_HOME="$TMP/cli-home"
CLI_XDG="$TMP/cli-xdg"
mkdir -p "$CLI_HOME" "$CLI_XDG"

PHASE_C_ATELIER_CFG="$TMP/phase-c-atelier-cfg"
mkdir -p "$PHASE_C_ATELIER_CFG/gh/admin" "$PHASE_C_ATELIER_CFG/gh/author"
printf 'WRITE\n' > "$PHASE_C_ATELIER_CFG/gh/admin/perm"
printf 'ADMIN\n' > "$PHASE_C_ATELIER_CFG/gh/author/perm"

EXISTING_JSON="$TMP/existing.json"
cat > "$EXISTING_JSON" << 'EOF'
{
  "required_status_checks": {"strict": true, "contexts": ["ci/build", "ci/test"]},
  "enforce_admins": {"enabled": true},
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "required_approving_review_count": 0
  },
  "restrictions": null
}
EOF

PUT_PAYLOAD_CAPTURE="$TMP/put_payload.json"
rm -f "$PUT_PAYLOAD_CAPTURE"

cat > "$TMP/bin/gh" << SHIMEOF
#!/usr/bin/env bash
EXISTING_JSON="${EXISTING_JSON}"
PUT_PAYLOAD_CAPTURE="${PUT_PAYLOAD_CAPTURE}"
case "\$*" in
  *"-X PUT"*"protection"*)
    prev=""
    for a in "\$@"; do
      if [ "\$prev" = "--input" ]; then
        cp "\$a" "\$PUT_PAYLOAD_CAPTURE"
        break
      fi
      prev="\$a"
    done
    printf '{}\n'
    ;;
  *"branches/"*"/protection"*)
    cat "\$EXISTING_JSON"
    ;;
  *"api user --jq .login"*)
    printf 'fake-admin-login\n'
    ;;
  *"viewerPermission"*)
    permfile="\${GH_CONFIG_DIR:-}/perm"
    if [ -f "\$permfile" ]; then cat "\$permfile"; else printf 'NONE\n'; fi
    ;;
  *)
    printf 'gh-stub: unexpected args: %s\n' "\$*" >&2
    exit 1
    ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

out="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_C_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" --json 2>&1)"
rc=$?

if [ "$rc" -eq 0 ]; then
  pass "C0: --apply on protected-insufficient with a resolvable admin identity exits 0"
else
  fail "C0: --apply exited $rc, expected 0 (output: $out)"
fi

status="$(printf '%s' "$out" | jq -r '.status // empty' 2>/dev/null)"
if [ "$status" = "applied" ]; then
  pass "C0: JSON status = 'applied'"
else
  fail "C0: expected JSON status 'applied', got '$status' (output: $out)"
fi

if [ ! -f "$PUT_PAYLOAD_CAPTURE" ]; then
  fail "C: PUT payload was never captured — gh -X PUT was not called"
else
  strict="$(jq -r '.required_status_checks.strict' "$PUT_PAYLOAD_CAPTURE")"
  [ "$strict" = "true" ] \
    && pass "C1: required_status_checks.strict preserved (true)" \
    || fail "C1: required_status_checks.strict: expected 'true', got '$strict'"

  contexts="$(jq -c '.required_status_checks.contexts' "$PUT_PAYLOAD_CAPTURE")"
  [ "$contexts" = '["ci/build","ci/test"]' ] \
    && pass "C2: required_status_checks.contexts preserved" \
    || fail "C2: required_status_checks.contexts: expected '[\"ci/build\",\"ci/test\"]', got '$contexts'"

  dismiss="$(jq -r '.required_pull_request_reviews.dismiss_stale_reviews' "$PUT_PAYLOAD_CAPTURE")"
  [ "$dismiss" = "true" ] \
    && pass "C3: dismiss_stale_reviews preserved (true)" \
    || fail "C3: dismiss_stale_reviews: expected 'true', got '$dismiss'"

  codeowner="$(jq -r '.required_pull_request_reviews.require_code_owner_reviews' "$PUT_PAYLOAD_CAPTURE")"
  [ "$codeowner" = "true" ] \
    && pass "C4: require_code_owner_reviews preserved (true)" \
    || fail "C4: require_code_owner_reviews: expected 'true', got '$codeowner'"

  count="$(jq -r '.required_pull_request_reviews.required_approving_review_count' "$PUT_PAYLOAD_CAPTURE")"
  [ "$count" = "1" ] \
    && pass "C5: required_approving_review_count forced to 1 (existing was 0)" \
    || fail "C5: required_approving_review_count: expected '1', got '$count'"

  # C6 — LOAD-BEARING: enforce_admins must be false, not the existing rule's
  # true. true would block the AtelierAuthor bot's own squash-merges — the
  # bot itself would then be subject to the very rule it needs to pass
  # through, breaking auto-merge in a new way.
  enforce="$(jq -r '.enforce_admins' "$PUT_PAYLOAD_CAPTURE")"
  [ "$enforce" = "false" ] \
    && pass "C6: enforce_admins forced to false (load-bearing — required for bot squash-merge)" \
    || fail "C6: enforce_admins: expected 'false', got '$enforce' — THIS WOULD BREAK AUTO-MERGE"

  restrictions="$(jq -r '.restrictions' "$PUT_PAYLOAD_CAPTURE")"
  [ "$restrictions" = "null" ] \
    && pass "C7: restrictions = null" \
    || fail "C7: restrictions: expected 'null', got '$restrictions'"
fi

# =============================================================================
# Phase D — exit code 3 + manual instruction block when no admin resolves
# =============================================================================

echo ""
echo "Phase D: exit code 3 + manual instruction block printed on stdout"

PHASE_D_ATELIER_CFG="$TMP/phase-d-atelier-cfg"
mkdir -p "$PHASE_D_ATELIER_CFG"   # deliberately empty: no gh/admin, no gh/author

cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
case "$*" in
  *".protected"*)
    printf 'false\n'
    ;;
  *"branches/"*"/protection"*)
    printf 'Branch not protected\n' >&2
    exit 1
    ;;
  *"viewerPermission"*)
    printf 'NONE\n'
    ;;
  *)
    printf 'gh-stub: unexpected args: %s\n' "$*" >&2
    exit 1
    ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

# --- D1: without --json ---
out_text="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$TMP/phase-d-xdg" ATELIER_CONFIG_DIR="$PHASE_D_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" 2>/dev/null)"
rc_text=$?

[ "$rc_text" -eq 3 ] \
  && pass "D1: --apply with no admin identity exits 3" \
  || fail "D1: expected exit 3, got $rc_text"

if printf '%s' "$out_text" | grep -q "gh api -X PUT" \
  && printf '%s' "$out_text" | grep -q "printf" \
  && printf '%s' "$out_text" | grep -q "branches/$BRANCH/protection" \
  && printf '%s' "$out_text" | grep -q "No admin identity available"; then
  pass "D1: stdout contains the complete copy-pasteable manual instruction block"
else
  fail "D1: stdout missing the manual block (got: $out_text)"
fi

# --- D2: WITH --json — the manual block still prints as plain text on
#     stdout, per the header comment's "regardless of --json" promise ---
out_json="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$TMP/phase-d-xdg" ATELIER_CONFIG_DIR="$PHASE_D_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" --json 2>/dev/null)"
rc_json=$?

[ "$rc_json" -eq 3 ] \
  && pass "D2: --apply --json with no admin identity still exits 3" \
  || fail "D2: expected exit 3, got $rc_json"

if printf '%s' "$out_json" | grep -q "gh api -X PUT"; then
  pass "D2: --json does not suppress the manual block (still plain text on stdout)"
else
  fail "D2: --json unexpectedly suppressed the manual block (got: $out_json)"
fi

if ! printf '%s' "$out_json" | jq empty >/dev/null 2>&1; then
  pass "D2: manual-block stdout is NOT parsed as JSON (confirms it bypasses --json formatting)"
else
  fail "D2: manual-block stdout unexpectedly parses as valid JSON — sanity check failed"
fi

# =============================================================================
# Phase E — --help, bash -n, executable bit
# =============================================================================

echo ""
echo "Phase E: CLI surface sanity"

if bash -n "$HELPER_SCRIPT"; then
  pass "E1: bash -n scripts/atelier-branch-protection — no syntax errors"
else
  fail "E1: bash -n scripts/atelier-branch-protection failed"
fi

if [ -x "$HELPER_SCRIPT" ]; then
  pass "E2: scripts/atelier-branch-protection is executable"
else
  fail "E2: scripts/atelier-branch-protection is NOT executable"
fi

help_out="$(bash "$HELPER_SCRIPT" --help 2>&1)"
help_rc=$?

[ "$help_rc" -eq 0 ] \
  && pass "E3: --help exits 0" \
  || fail "E3: --help exited $help_rc, expected 0"

if printf '%s' "$help_out" | grep -q "USAGE" \
  && printf '%s' "$help_out" | grep -q -- "--status" \
  && printf '%s' "$help_out" | grep -q -- "--apply"; then
  pass "E4: --help prints usage documenting --status and --apply"
else
  fail "E4: --help output missing expected usage content (got: $help_out)"
fi

# =============================================================================
# Phase F — cheap regression guards
# =============================================================================

echo ""
echo "Phase F: regression guards"

MATCHES="$(grep -rl 'Branch not protected' "$REPO_ROOT/scripts/" 2>/dev/null || true)"
MATCH_COUNT="$(printf '%s\n' "$MATCHES" | grep -c . || true)"

if [ "$MATCH_COUNT" -eq 1 ] && [ "$MATCHES" = "$HELPER_SCRIPT" ]; then
  pass "F1: classify_branch_protection's 'Branch not protected' string lives in exactly one file (scripts/atelier-branch-protection)"
else
  fail "F1: expected exactly one match at $HELPER_SCRIPT, got: $MATCHES"
fi

if grep -q '_phase_c_1_symlink_helper atelier-branch-protection' "$INSTALL_SH"; then
  pass "F2: install.sh symlinks atelier-branch-protection in Phase C.1"
else
  fail "F2: install.sh does not symlink atelier-branch-protection"
fi

# =============================================================================
# Result
# =============================================================================
echo ""
if [ "$fails" -eq 0 ]; then
  echo "branch-protection-helper (#45): all assertions passed."
  exit 0
else
  echo "branch-protection-helper (#45): $fails assertion(s) failed."
  exit 1
fi
