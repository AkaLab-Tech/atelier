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
#   Phase G — THE #45 REVIEW'S CRITICAL FINDING, pinned so it can never
#     regress: apply_protection() re-reads the rule under the ADMIN
#     identity before building any payload, and short-circuits with zero
#     PUT whenever that read already shows required_approving_review_count
#     >= 1 — even when the PROBE identity's earlier classify saw something
#     else entirely (403/no-admin) and only the later-resolved admin
#     identity can see the rule is already strict. Before this fix, the
#     decision used which identity's view? the probe's; the execution used
#     the admin's privileges — so a repo with an existing
#     required_approving_review_count: 3 got silently rewritten down to 1.
#     Every `gh` invocation is logged; G asserts no "-X PUT" line ever
#     appears in that log, the reported status is "already-sufficient", and
#     the existing rule's count is untouched (still 3).
#
#   Phase H — boolean protection-field carry-through (#45 review, important
#     finding: PUT is a full replace, so any field the payload omits resets
#     to the API default). required_linear_history / required_
#     conversation_resolution / allow_force_pushes / allow_deletions /
#     block_creations / lock_branch must all be carried through from
#     `.<field>.enabled` on GET to a plain boolean on the PUT payload, not
#     silently reset to false.
#
#   Phase I — refusal to guess at fields this helper does not model (#45
#     review, important finding): a non-empty dismissal_restrictions or
#     bypass_pull_request_allowances on the existing rule (GET returns
#     user/team OBJECTS; PUT wants ID LISTS — reformatting blind risks
#     silently dropping who they cover) makes apply_protection() refuse to
#     PUT at all; the top-level --apply exits 3 with print_unmergeable_
#     block's text (naming the offending field) on stdout.
#
#   Phase J — --manual mode (#45 review, important finding: a read-only
#     doctor invocation must never risk a mutating PUT via a second,
#     transiently-successful admin-identity resolution). Passing --repo/
#     --branch explicitly means --manual needs no git/gh call at all to
#     resolve them; combined with a `gh` stub that fails hard on ANY
#     invocation, this proves --manual never probes an admin identity or
#     reads the protection endpoint, while still printing the complete
#     manual block.
#
#   Phase F — cheap regression guards:
#     F1  classify_branch_protection lives in exactly ONE file under
#         scripts/ (grep -rc 'Branch not protected' scripts/ has exactly
#         one non-zero match, and it is scripts/atelier-branch-protection).
#     F2  install.sh symlinks atelier-branch-protection in Phase C.1.
#
#   Phases K-N were added after #45 review CYCLE 2, whose two CRITICAL
#   findings survived cycle 1 precisely because no fixture exercised them:
#
#   Phase K — CRITICAL FINDING #1: a failed re-read of the existing rule
#     under the ADMIN identity (inside apply_protection()) must never be
#     treated as "no rule exists". K1a: a non-404 error (transient 5xx) on
#     the admin re-read -> exit 2, zero PUT, JSON status "read-failed", raw
#     gh error on stderr. K1b: a 404-shaped error whose companion
#     .protected branch-detail read itself fails -> must ALSO abort, not
#     fall through to "unprotected". K1c (positive regression, guards
#     against over-correcting K1a/K1b into "never applies anything"): a
#     CONFIRMED genuinely-unprotected re-read (404 + .protected==false)
#     under the admin identity, exercised inside apply_protection() itself
#     (not just classify_branch_protection() in isolation) -> must still
#     fall through to MIN_PAYLOAD and PUT successfully.
#
#   Phase L — CRITICAL FINDING #2: a non-null, non-empty top-level
#     `restrictions` on the existing rule must refuse to PUT (like
#     dismissal_restrictions / bypass_pull_request_allowances already do),
#     not be silently replaced with `restrictions: null`. Every existing-
#     rule fixture elsewhere in this suite uses restrictions: null, so
#     Phase C's C7 assertion ("restrictions = null" in the PUT) pins
#     nothing about preservation — L1/L2 are what actually pin it. L1: non-
#     empty restrictions.users/teams -> exit 3, print_unmergeable_block
#     names restrictions, no PUT. L2 (negative companion): restrictions
#     present but every array empty -> must NOT trigger refusal.
#
#   Phase M — require_last_push_approval carry-through: previously silently
#     reset to false by the merge payload; now preserved from the existing
#     rule, the same pattern the Phase H booleans already cover for the
#     other protection flags.
#
#   Phase N — the enforce_admins relaxation note (critical finding sub-
#     point (a)): text output only (no JSON field). N1: existing rule had
#     enforce_admins.enabled=true -> note present. N2 (negative companion):
#     existing rule already had it false -> note absent.
#
#   D3 (folded into the existing Phase D) — cheap: print_manual_block's new
#     WARNING about the PUT being a full replace is part of the block D1
#     already captures; nothing previously asserted that line's presence.
#
#   Phases O-Q were added after #45 review CYCLE 3, whose reviewer note
#   flagged coverage gaps that let three fresh instances of the same
#   "silent destructive full-replace, reported as applied/exit 0" class
#   through cycle 2: H4/H5/H6 were vacuous (fixed above), and no fixture
#   covered dismissal_restrictions.apps, an unparseable-but-rc-0 read, or
#   setup-project's exit-2 arm (that last one lives in
#   setup-project-branch-protection.test.sh, not here).
#
#   Phase O — the has_unmodeled_restrictions clauses must be symmetric: all
#     three (dismissal_restrictions / bypass_pull_request_allowances /
#     top-level restrictions) enumerate users+teams+apps. Before this cycle's
#     fix, dismissal_restrictions only counted users+teams — an apps-only
#     dismissal_restrictions escaped refusal entirely (applied, exit 0, PUT
#     silently omitted the field). O1/O2/O3 pin an apps-only fixture against
#     all three clauses so the asymmetry that caused the bug cannot recur in
#     any of them, not just the one that was empirically found broken.
#
#   Phase P — an admin re-read that returns rc 0 (success) but is otherwise
#     unusable must never be treated as "no rule exists" either. P1: rc 0 +
#     an EMPTY body (previously fell through both existing guards with no
#     check at all — the review's "more reachable" door). P2: rc 0 + a body
#     that is not valid JSON (jq cannot build a merge payload from it). Both
#     -> --apply exits 2, JSON status "read-failed", zero PUT.
#
#   Phase Q — allow_fork_syncing carry-through, the field that was silently
#     omitted and reset to its API default (false) on every PUT. Q1 uses
#     enabled: true on the existing rule specifically because it is the
#     non-default value — a fixture asserting false would pass even if the
#     field were dropped entirely (the same gap Phase H's fixture had before
#     this cycle's correction to H4/H5/H6).
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

# --- D3 (cheap, #45 cycle-2 review item 5): print_manual_block's new
#     WARNING about the PUT being a full replace must be part of the block
#     that D1 already captured. Existing Phase D/J assertions grep other
#     substrings from this function and pass unmodified; nothing previously
#     asserted this line. ---
if printf '%s' "$out_text" | grep -q "WARNING:"; then
  pass "D3: manual block includes the new WARNING about full-replace PUT semantics"
else
  fail "D3: expected 'WARNING:' text in the manual block (got: $out_text)"
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
# Phase G — THE #45 REVIEW'S CRITICAL FINDING: never PUT a rule the ADMIN
# identity can already see is sufficient, even when the PROBE identity saw
# something else entirely (403/no-admin).
# =============================================================================

echo ""
echo "Phase G: apply_protection() re-reads under the admin identity and never PUTs an already-sufficient rule"

PHASE_G_ATELIER_CFG="$TMP/phase-g-atelier-cfg"
GH_AUTHOR_DIR="$PHASE_G_ATELIER_CFG/gh/author"   # the PROBE identity (default_gh_dir())
GH_ADMIN_DIR="$PHASE_G_ATELIER_CFG/gh/admin"     # the ADMIN identity (resolve_admin_gh_dir())
mkdir -p "$GH_AUTHOR_DIR" "$GH_ADMIN_DIR"
printf 'WRITE\n' > "$GH_AUTHOR_DIR/perm"   # author identity: not admin (matters for candidate 3 order)
printf 'ADMIN\n' > "$GH_ADMIN_DIR/perm"    # admin identity: candidate 2, resolves first

EXISTING_STRICT_JSON="$TMP/existing_strict.json"
cat > "$EXISTING_STRICT_JSON" << 'EOF'
{
  "required_status_checks": {"strict": true, "contexts": ["ci/build"]},
  "enforce_admins": {"enabled": true},
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "required_approving_review_count": 3
  },
  "restrictions": null
}
EOF

GH_CALL_LOG_G="$TMP/gh_call_log_g"
rm -f "$GH_CALL_LOG_G"

# The PROBE identity (author dir) 403s reading the protection endpoint — it
# genuinely cannot see the rule. Only the ADMIN identity (admin dir) can
# read it, and what it reads is an existing rule that ALREADY requires 3
# approving reviews.
cat > "$TMP/bin/gh" << SHIMEOF
#!/usr/bin/env bash
EXISTING_JSON="${EXISTING_STRICT_JSON}"
CALL_LOG="${GH_CALL_LOG_G}"
ADMIN_DIR="${GH_ADMIN_DIR}"
printf '%s\n' "\$*" >> "\$CALL_LOG"
case "\$*" in
  *"-X PUT"*"protection"*)
    printf 'UNEXPECTED PUT INVOKED\n' >> "\$CALL_LOG"
    printf '{}\n'
    ;;
  *"branches/"*"/protection"*)
    if [ "\${GH_CONFIG_DIR:-}" = "\$ADMIN_DIR" ]; then
      cat "\$EXISTING_JSON"
    else
      printf 'Must have admin rights to Repository.\n' >&2
      exit 1
    fi
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

out_g="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_G_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" --json 2>&1)"
rc_g=$?

[ "$rc_g" -eq 0 ] \
  && pass "G0: --apply exits 0 when the admin re-read shows the rule is already sufficient" \
  || fail "G0: --apply exited $rc_g, expected 0 (output: $out_g)"

status_g="$(printf '%s' "$out_g" | jq -r '.status // empty' 2>/dev/null)"
[ "$status_g" = "already-sufficient" ] \
  && pass "G1: reported status = 'already-sufficient'" \
  || fail "G1: expected status 'already-sufficient', got '$status_g' (output: $out_g)"

if [ -f "$GH_CALL_LOG_G" ] && grep -q -- "-X PUT" "$GH_CALL_LOG_G"; then
  fail "G2: THE CRITICAL REGRESSION — a PUT was made despite the admin-identity re-read already showing required_approving_review_count=3 (call log: $(cat "$GH_CALL_LOG_G"))"
else
  pass "G2: no PUT was ever made — no '-X PUT' invocation appears in the gh call log"
fi

count_after_g="$(jq -r '.required_pull_request_reviews.required_approving_review_count' "$EXISTING_STRICT_JSON")"
[ "$count_after_g" = "3" ] \
  && pass "G3: the existing rule's required_approving_review_count is untouched (still 3)" \
  || fail "G3: expected the existing rule to remain count=3, got '$count_after_g'"

# =============================================================================
# Phase H — boolean protection fields are carried through as plain booleans,
# not reset to false (PUT is a full replace; #45 review important finding)
# =============================================================================

echo ""
echo "Phase H: apply_protection() carries through required_linear_history / required_conversation_resolution / allow_force_pushes / allow_deletions / block_creations / lock_branch"

PHASE_H_ATELIER_CFG="$TMP/phase-h-atelier-cfg"
mkdir -p "$PHASE_H_ATELIER_CFG/gh/admin" "$PHASE_H_ATELIER_CFG/gh/author"
printf 'WRITE\n' > "$PHASE_H_ATELIER_CFG/gh/admin/perm"
printf 'ADMIN\n' > "$PHASE_H_ATELIER_CFG/gh/author/perm"

EXISTING_BOOLEANS_JSON="$TMP/existing_booleans.json"
cat > "$EXISTING_BOOLEANS_JSON" << 'EOF'
{
  "required_status_checks": null,
  "enforce_admins": {"enabled": true},
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "required_linear_history": {"enabled": true},
  "required_conversation_resolution": {"enabled": true},
  "allow_force_pushes": {"enabled": true},
  "allow_deletions": {"enabled": true},
  "block_creations": {"enabled": true},
  "lock_branch": {"enabled": true}
}
EOF

PUT_PAYLOAD_CAPTURE_H="$TMP/put_payload_h.json"
rm -f "$PUT_PAYLOAD_CAPTURE_H"

cat > "$TMP/bin/gh" << SHIMEOF
#!/usr/bin/env bash
EXISTING_JSON="${EXISTING_BOOLEANS_JSON}"
PUT_PAYLOAD_CAPTURE="${PUT_PAYLOAD_CAPTURE_H}"
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

out_h="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_H_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" --json 2>&1)"
rc_h=$?

[ "$rc_h" -eq 0 ] \
  && pass "H0: --apply exits 0 on a protected-insufficient branch with boolean protection fields set" \
  || fail "H0: --apply exited $rc_h, expected 0 (output: $out_h)"

if [ ! -f "$PUT_PAYLOAD_CAPTURE_H" ]; then
  fail "H: PUT payload was never captured — gh -X PUT was not called"
else
  lh="$(jq -r '.required_linear_history' "$PUT_PAYLOAD_CAPTURE_H")"
  [ "$lh" = "true" ] \
    && pass "H1: required_linear_history carried through as plain boolean true (not reset to false)" \
    || fail "H1: required_linear_history: expected 'true', got '$lh'"

  crr="$(jq -r '.required_conversation_resolution' "$PUT_PAYLOAD_CAPTURE_H")"
  [ "$crr" = "true" ] \
    && pass "H2: required_conversation_resolution carried through as plain boolean true" \
    || fail "H2: required_conversation_resolution: expected 'true', got '$crr'"

  afp="$(jq -r '.allow_force_pushes' "$PUT_PAYLOAD_CAPTURE_H")"
  [ "$afp" = "true" ] \
    && pass "H3: allow_force_pushes carried through as plain boolean true" \
    || fail "H3: allow_force_pushes: expected 'true', got '$afp'"

  # H4-H6 fixture values are true (non-default) so these assertions actually
  # discriminate: with a false fixture matching the field's own API default,
  # the assertion would pass even if the field's carry-through were broken
  # (#45 review, test-assertion gap).
  ad="$(jq -r '.allow_deletions' "$PUT_PAYLOAD_CAPTURE_H")"
  [ "$ad" = "true" ] \
    && pass "H4: allow_deletions carried through as plain boolean true (not reset to false)" \
    || fail "H4: allow_deletions: expected 'true', got '$ad'"

  bc="$(jq -r '.block_creations' "$PUT_PAYLOAD_CAPTURE_H")"
  [ "$bc" = "true" ] \
    && pass "H5: block_creations carried through as plain boolean true (not reset to false)" \
    || fail "H5: block_creations: expected 'true', got '$bc'"

  lb="$(jq -r '.lock_branch' "$PUT_PAYLOAD_CAPTURE_H")"
  [ "$lb" = "true" ] \
    && pass "H6: lock_branch carried through as plain boolean true (not reset to false)" \
    || fail "H6: lock_branch: expected 'true', got '$lb'"
fi

# =============================================================================
# Phase I — refuses to PUT when the existing rule uses a field this helper
# does not model (dismissal_restrictions / bypass_pull_request_allowances):
# GET returns user/team OBJECTS, PUT wants ID LISTS — refuse rather than
# guess (#45 review, important finding)
# =============================================================================

echo ""
echo "Phase I: apply_protection() refuses to PUT when dismissal_restrictions / bypass_pull_request_allowances are set"

PHASE_I_ATELIER_CFG="$TMP/phase-i-atelier-cfg"
mkdir -p "$PHASE_I_ATELIER_CFG/gh/admin" "$PHASE_I_ATELIER_CFG/gh/author"
printf 'WRITE\n' > "$PHASE_I_ATELIER_CFG/gh/admin/perm"
printf 'ADMIN\n' > "$PHASE_I_ATELIER_CFG/gh/author/perm"

run_unmergeable_case() {
  # $1 = existing-rule JSON file, $2 = label (used to name the call-log file)
  local existing_json="$1" label="$2" call_log
  call_log="$TMP/gh_call_log_${label}"
  rm -f "$call_log"

  cat > "$TMP/bin/gh" << SHIMEOF
#!/usr/bin/env bash
EXISTING_JSON="${existing_json}"
CALL_LOG="${call_log}"
printf '%s\n' "\$*" >> "\$CALL_LOG"
case "\$*" in
  *"-X PUT"*"protection"*)
    printf 'UNEXPECTED PUT INVOKED\n' >> "\$CALL_LOG"
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

  printf '%s' "$call_log"
}

# --- I1: dismissal_restrictions.teams non-empty ---
EXISTING_DISMISSAL_JSON="$TMP/existing_dismissal.json"
cat > "$EXISTING_DISMISSAL_JSON" << 'EOF'
{
  "required_status_checks": null,
  "enforce_admins": {"enabled": false},
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0,
    "dismissal_restrictions": {"users": [], "teams": [{"slug": "platform-team"}]}
  },
  "restrictions": null
}
EOF

call_log_i1="$(run_unmergeable_case "$EXISTING_DISMISSAL_JSON" "i1")"

out_i1="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_I_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" 2>&1)"
rc_i1=$?

[ "$rc_i1" -eq 3 ] \
  && pass "I1: --apply exits 3 when the existing rule sets dismissal_restrictions.teams" \
  || fail "I1: expected exit 3, got $rc_i1 (output: $out_i1)"

if printf '%s' "$out_i1" | grep -q "dismissal_restrictions"; then
  pass "I1: print_unmergeable_block's text on stdout names dismissal_restrictions"
else
  fail "I1: expected 'dismissal_restrictions' on stdout (got: $out_i1)"
fi

if [ -f "$call_log_i1" ] && grep -q -- "-X PUT" "$call_log_i1"; then
  fail "I1: PUT was made despite the unmodeled dismissal_restrictions field (call log: $(cat "$call_log_i1"))"
else
  pass "I1: no PUT was made"
fi

# --- I2: bypass_pull_request_allowances.users non-empty ---
EXISTING_BYPASS_JSON="$TMP/existing_bypass.json"
cat > "$EXISTING_BYPASS_JSON" << 'EOF'
{
  "required_status_checks": null,
  "enforce_admins": {"enabled": false},
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0,
    "bypass_pull_request_allowances": {"users": [{"login": "release-bot"}], "teams": [], "apps": []}
  },
  "restrictions": null
}
EOF

call_log_i2="$(run_unmergeable_case "$EXISTING_BYPASS_JSON" "i2")"

out_i2="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_I_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" 2>&1)"
rc_i2=$?

[ "$rc_i2" -eq 3 ] \
  && pass "I2: --apply exits 3 when the existing rule sets bypass_pull_request_allowances.users" \
  || fail "I2: expected exit 3, got $rc_i2 (output: $out_i2)"

if printf '%s' "$out_i2" | grep -q "bypass_pull_request_allowances"; then
  pass "I2: print_unmergeable_block's text on stdout names bypass_pull_request_allowances"
else
  fail "I2: expected 'bypass_pull_request_allowances' on stdout (got: $out_i2)"
fi

if [ -f "$call_log_i2" ] && grep -q -- "-X PUT" "$call_log_i2"; then
  fail "I2: PUT was made despite the unmodeled bypass_pull_request_allowances field (call log: $(cat "$call_log_i2"))"
else
  pass "I2: no PUT was made"
fi

# =============================================================================
# Phase J — --manual mode: never probes an admin identity or reads the
# protection endpoint, regardless of which identities would resolve
# (#45 review, important finding — a read-only doctor invocation must never
# risk a mutating PUT via a transiently-successful second admin-identity
# resolution)
# =============================================================================

echo ""
echo "Phase J: --manual mode never invokes gh at all and still prints the complete manual block"

# --repo/--branch are passed explicitly so --manual needs no git/gh call to
# resolve them either; combined with a gh stub that fails hard on ANY
# invocation, ANY call to gh from --manual mode (admin-identity probing or
# a protection-endpoint read) would surface as "gh-stub:" in the output.
cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
printf 'gh-stub: --manual mode must never invoke gh (args: %s)\n' "$*" >&2
exit 1
SHIMEOF
chmod +x "$TMP/bin/gh"

out_manual="$(ATELIER_ADMIN_GH_CONFIG_DIR="$TMP/phase-j-would-be-admin" \
  bash "$HELPER_SCRIPT" --manual --repo "$OWNER_REPO" --branch "$BRANCH" 2>&1)"
rc_manual=$?

[ "$rc_manual" -eq 0 ] \
  && pass "J1: --manual exits 0" \
  || fail "J1: --manual exited $rc_manual, expected 0 (output: $out_manual)"

if printf '%s' "$out_manual" | grep -q "gh-stub"; then
  fail "J2: --manual invoked gh (got: $out_manual)"
else
  pass "J2: --manual never invoked gh — no admin-identity probe, no protection-endpoint read"
fi

if printf '%s' "$out_manual" | grep -q "gh api -X PUT" \
  && printf '%s' "$out_manual" | grep -q "branches/$BRANCH/protection" \
  && printf '%s' "$out_manual" | grep -q "No admin identity available"; then
  pass "J3: --manual still prints the complete copy-pasteable manual block"
else
  fail "J3: --manual output missing the complete manual block (got: $out_manual)"
fi

# =============================================================================
# Phase K — #45 REVIEW CYCLE-2 CRITICAL FINDING #1: a failed re-read of the
# existing rule under the ADMIN identity must never be treated as "no rule
# exists". Before this fix, a transient error on that re-read (5xx, secondary
# rate limit, or a 404 whose .protected companion read itself failed) fell
# through to payload="" -> MIN_PAYLOAD -> an unconditional full-replace PUT,
# silently erasing status checks / code-owner reviews / linear history /
# force-push and deletion locks / restrictions, then reporting "applied",
# exit 0. Only a CONFIRMED-unprotected 404 (branch-detail .protected==false)
# may still fall through to MIN_PAYLOAD.
# =============================================================================

echo ""
echo "Phase K: apply_protection() aborts instead of PUTting when the ADMIN identity's re-read of the existing rule fails"

PHASE_K_ATELIER_CFG="$TMP/phase-k-atelier-cfg"
GH_AUTHOR_DIR_K="$PHASE_K_ATELIER_CFG/gh/author"   # PROBE identity (default_gh_dir()) — always 403s, never admin
GH_ADMIN_DIR_K="$PHASE_K_ATELIER_CFG/gh/admin"     # ADMIN identity (resolve_admin_gh_dir()) — re-read behavior varies per case
mkdir -p "$GH_AUTHOR_DIR_K" "$GH_ADMIN_DIR_K"
printf 'WRITE\n' > "$GH_AUTHOR_DIR_K/perm"
printf 'ADMIN\n' > "$GH_ADMIN_DIR_K/perm"

# --- K1a: transient 502 on the admin re-read (not 404-shaped at all) ->
#     apply_protection() must return 3 -> top-level --apply exits 2, zero
#     PUT, JSON status "read-failed", raw gh error surfaced on stderr. ---
GH_CALL_LOG_K1="$TMP/gh_call_log_k1"
rm -f "$GH_CALL_LOG_K1"

cat > "$TMP/bin/gh" << SHIMEOF
#!/usr/bin/env bash
CALL_LOG="${GH_CALL_LOG_K1}"
ADMIN_DIR="${GH_ADMIN_DIR_K}"
printf '%s\n' "\$*" >> "\$CALL_LOG"
case "\$*" in
  *"-X PUT"*"protection"*)
    printf 'UNEXPECTED PUT INVOKED\n' >> "\$CALL_LOG"
    printf '{}\n'
    ;;
  *".protected"*)
    printf 'UNEXPECTED .protected CALL — a non-404 error must never trigger the branch-detail disambiguation\n' >> "\$CALL_LOG"
    printf 'false\n'
    ;;
  *"api user --jq .login"*)
    printf 'fake-admin-login\n'
    ;;
  *"viewerPermission"*)
    permfile="\${GH_CONFIG_DIR:-}/perm"
    if [ -f "\$permfile" ]; then cat "\$permfile"; else printf 'NONE\n'; fi
    ;;
  *"branches/"*"/protection"*)
    if [ "\${GH_CONFIG_DIR:-}" = "\$ADMIN_DIR" ]; then
      printf 'HTTP 502: Bad Gateway\n' >&2
      exit 1
    else
      printf 'Must have admin rights to Repository.\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'gh-stub: unexpected args: %s\n' "\$*" >&2
    exit 1
    ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

K1_STDERR="$TMP/k1.stderr"
out_k1="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_K_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" --json 2>"$K1_STDERR")"
rc_k1=$?

[ "$rc_k1" -eq 2 ] \
  && pass "K1a: transient 502 on the admin re-read -> --apply exits 2 (not treated as 'no rule exists')" \
  || fail "K1a: expected exit 2, got $rc_k1 (output: $out_k1)"

status_k1="$(printf '%s' "$out_k1" | jq -r '.status // empty' 2>/dev/null)"
[ "$status_k1" = "read-failed" ] \
  && pass "K1a: JSON status = 'read-failed'" \
  || fail "K1a: expected JSON status 'read-failed', got '$status_k1' (output: $out_k1)"

if grep -q "502" "$K1_STDERR"; then
  pass "K1a: the underlying gh error (502) is surfaced on stderr"
else
  fail "K1a: expected the raw gh error on stderr (got: $(cat "$K1_STDERR"))"
fi

if [ -f "$GH_CALL_LOG_K1" ] && grep -q -- "-X PUT" "$GH_CALL_LOG_K1"; then
  fail "K1a: THE CRITICAL REGRESSION — a PUT was made despite a failed (non-404) admin re-read (call log: $(cat "$GH_CALL_LOG_K1"))"
else
  pass "K1a: no PUT was ever made — no '-X PUT' invocation appears in the gh call log"
fi

# --- K1b: a 404-shaped error on the admin re-read whose companion
#     .protected branch-detail read ITSELF fails -> must ALSO abort, not
#     fall through to "confirmed unprotected". ---
GH_CALL_LOG_K2="$TMP/gh_call_log_k2"
rm -f "$GH_CALL_LOG_K2"

cat > "$TMP/bin/gh" << SHIMEOF
#!/usr/bin/env bash
CALL_LOG="${GH_CALL_LOG_K2}"
ADMIN_DIR="${GH_ADMIN_DIR_K}"
printf '%s\n' "\$*" >> "\$CALL_LOG"
case "\$*" in
  *"-X PUT"*"protection"*)
    printf 'UNEXPECTED PUT INVOKED\n' >> "\$CALL_LOG"
    printf '{}\n'
    ;;
  *".protected"*)
    if [ "\${GH_CONFIG_DIR:-}" = "\$ADMIN_DIR" ]; then
      printf 'HTTP 503: Service Unavailable\n' >&2
      exit 1
    else
      printf 'UNEXPECTED .protected CALL FROM PROBE\n' >> "\$CALL_LOG"
      printf 'false\n'
    fi
    ;;
  *"api user --jq .login"*)
    printf 'fake-admin-login\n'
    ;;
  *"viewerPermission"*)
    permfile="\${GH_CONFIG_DIR:-}/perm"
    if [ -f "\$permfile" ]; then cat "\$permfile"; else printf 'NONE\n'; fi
    ;;
  *"branches/"*"/protection"*)
    if [ "\${GH_CONFIG_DIR:-}" = "\$ADMIN_DIR" ]; then
      printf 'Branch not protected\n' >&2
      exit 1
    else
      printf 'Must have admin rights to Repository.\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'gh-stub: unexpected args: %s\n' "\$*" >&2
    exit 1
    ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

out_k2="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_K_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" 2>&1)"
rc_k2=$?

[ "$rc_k2" -eq 2 ] \
  && pass "K1b: 404 admin re-read whose companion .protected read itself fails -> --apply exits 2 (not treated as unprotected)" \
  || fail "K1b: expected exit 2, got $rc_k2 (output: $out_k2)"

if printf '%s' "$out_k2" | grep -q "refusing to apply without reading it first"; then
  pass "K1b: text-mode stderr carries the explanatory 'refusing to apply' message"
else
  fail "K1b: expected the explanatory message on stderr (got: $out_k2)"
fi

if [ -f "$GH_CALL_LOG_K2" ] && grep -q -- "-X PUT" "$GH_CALL_LOG_K2"; then
  fail "K1b: THE CRITICAL REGRESSION — a PUT was made despite the .protected companion read itself failing (call log: $(cat "$GH_CALL_LOG_K2"))"
else
  pass "K1b: no PUT was ever made"
fi

# --- K1c (POSITIVE REGRESSION — guards against over-correcting K1a/K1b into
#     "never applies anything"): a CONFIRMED genuinely-unprotected re-read
#     (404 + .protected==false) under the admin identity, exercised INSIDE
#     apply_protection() itself (not just classify_branch_protection() in
#     isolation), must still fall through to MIN_PAYLOAD and PUT
#     successfully. ---
GH_CALL_LOG_K3="$TMP/gh_call_log_k3"
PUT_PAYLOAD_CAPTURE_K3="$TMP/put_payload_k3.json"
rm -f "$GH_CALL_LOG_K3" "$PUT_PAYLOAD_CAPTURE_K3"

cat > "$TMP/bin/gh" << SHIMEOF
#!/usr/bin/env bash
CALL_LOG="${GH_CALL_LOG_K3}"
ADMIN_DIR="${GH_ADMIN_DIR_K}"
PUT_PAYLOAD_CAPTURE="${PUT_PAYLOAD_CAPTURE_K3}"
printf '%s\n' "\$*" >> "\$CALL_LOG"
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
  *".protected"*)
    if [ "\${GH_CONFIG_DIR:-}" = "\$ADMIN_DIR" ]; then
      printf 'false\n'
    else
      printf 'UNEXPECTED .protected CALL FROM PROBE\n' >> "\$CALL_LOG"
      printf 'false\n'
    fi
    ;;
  *"api user --jq .login"*)
    printf 'fake-admin-login\n'
    ;;
  *"viewerPermission"*)
    permfile="\${GH_CONFIG_DIR:-}/perm"
    if [ -f "\$permfile" ]; then cat "\$permfile"; else printf 'NONE\n'; fi
    ;;
  *"branches/"*"/protection"*)
    if [ "\${GH_CONFIG_DIR:-}" = "\$ADMIN_DIR" ]; then
      printf 'Branch not protected\n' >&2
      exit 1
    else
      printf 'Must have admin rights to Repository.\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'gh-stub: unexpected args: %s\n' "\$*" >&2
    exit 1
    ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

out_k3="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_K_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" --json 2>&1)"
rc_k3=$?

[ "$rc_k3" -eq 0 ] \
  && pass "K1c: confirmed genuinely-unprotected admin re-read (404 + .protected=false) inside apply_protection() -> --apply still exits 0" \
  || fail "K1c: expected exit 0, got $rc_k3 (output: $out_k3)"

status_k3="$(printf '%s' "$out_k3" | jq -r '.status // empty' 2>/dev/null)"
[ "$status_k3" = "applied" ] \
  && pass "K1c: JSON status = 'applied' (over-correcting K1a/K1b must not disable applying to a genuinely unprotected branch)" \
  || fail "K1c: expected JSON status 'applied', got '$status_k3' (output: $out_k3)"

if [ ! -f "$PUT_PAYLOAD_CAPTURE_K3" ]; then
  fail "K1c: PUT payload was never captured — the minimal rule was not applied to the genuinely-unprotected branch"
else
  count_k3="$(jq -r '.required_pull_request_reviews.required_approving_review_count' "$PUT_PAYLOAD_CAPTURE_K3")"
  [ "$count_k3" = "1" ] \
    && pass "K1c: PUT payload requires >=1 approving review (MIN_PAYLOAD applied)" \
    || fail "K1c: required_approving_review_count: expected '1', got '$count_k3'"
fi

# =============================================================================
# Phase L — #45 REVIEW CYCLE-2 CRITICAL FINDING #2: a non-null, non-empty
# top-level `restrictions` on the existing rule must refuse (like
# dismissal_restrictions / bypass_pull_request_allowances already do), not
# be silently PUT as `restrictions: null`. Every existing-rule fixture
# elsewhere in this suite uses restrictions: null, so C7 ("restrictions =
# null" in the PUT) pins nothing about preservation — these two cases do.
# =============================================================================

echo ""
echo "Phase L: apply_protection() refuses to PUT when top-level restrictions is non-null and non-empty, but proceeds when it is present-but-empty"

PHASE_L_ATELIER_CFG="$TMP/phase-l-atelier-cfg"
mkdir -p "$PHASE_L_ATELIER_CFG/gh/admin" "$PHASE_L_ATELIER_CFG/gh/author"
printf 'WRITE\n' > "$PHASE_L_ATELIER_CFG/gh/admin/perm"
printf 'ADMIN\n' > "$PHASE_L_ATELIER_CFG/gh/author/perm"

# --- L1: restrictions.users/teams non-empty -> exits 3, print_unmergeable_
#     block names restrictions, no PUT. Reuses run_unmergeable_case() from
#     Phase I (generic: existing-rule JSON in, call-log path out). ---
EXISTING_RESTRICTIONS_JSON="$TMP/existing_restrictions.json"
cat > "$EXISTING_RESTRICTIONS_JSON" << 'EOF'
{
  "required_status_checks": null,
  "enforce_admins": {"enabled": false},
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0
  },
  "restrictions": {"users": [{"login": "alice"}], "teams": [{"slug": "releasers"}], "apps": []}
}
EOF

call_log_l1="$(run_unmergeable_case "$EXISTING_RESTRICTIONS_JSON" "l1")"

out_l1="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_L_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" 2>&1)"
rc_l1=$?

[ "$rc_l1" -eq 3 ] \
  && pass "L1: --apply exits 3 when the existing rule sets a non-empty top-level restrictions" \
  || fail "L1: expected exit 3, got $rc_l1 (output: $out_l1)"

if printf '%s' "$out_l1" | grep -q "restrictions"; then
  pass "L1: print_unmergeable_block's text on stdout names restrictions"
else
  fail "L1: expected 'restrictions' on stdout (got: $out_l1)"
fi

if [ -f "$call_log_l1" ] && grep -q -- "-X PUT" "$call_log_l1"; then
  fail "L1: THE CRITICAL REGRESSION — a PUT was made despite a non-empty top-level restrictions on the existing rule (call log: $(cat "$call_log_l1"))"
else
  pass "L1: no PUT was made"
fi

# --- L2 (negative companion): restrictions present but ALL arrays empty ->
#     must NOT trigger refusal; apply proceeds normally and PUTs. ---
EXISTING_EMPTY_RESTRICTIONS_JSON="$TMP/existing_empty_restrictions.json"
cat > "$EXISTING_EMPTY_RESTRICTIONS_JSON" << 'EOF'
{
  "required_status_checks": null,
  "enforce_admins": {"enabled": false},
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0
  },
  "restrictions": {"users": [], "teams": [], "apps": []}
}
EOF

PUT_PAYLOAD_CAPTURE_L2="$TMP/put_payload_l2.json"
rm -f "$PUT_PAYLOAD_CAPTURE_L2"

cat > "$TMP/bin/gh" << SHIMEOF
#!/usr/bin/env bash
EXISTING_JSON="${EXISTING_EMPTY_RESTRICTIONS_JSON}"
PUT_PAYLOAD_CAPTURE="${PUT_PAYLOAD_CAPTURE_L2}"
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

out_l2="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_L_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" --json 2>&1)"
rc_l2=$?

[ "$rc_l2" -eq 0 ] \
  && pass "L2: present-but-empty top-level restrictions does NOT trigger refusal — --apply exits 0" \
  || fail "L2: expected exit 0, got $rc_l2 (output: $out_l2)"

status_l2="$(printf '%s' "$out_l2" | jq -r '.status // empty' 2>/dev/null)"
[ "$status_l2" = "applied" ] \
  && pass "L2: JSON status = 'applied' (an empty restrictions object is not 'unmodeled')" \
  || fail "L2: expected JSON status 'applied', got '$status_l2' (output: $out_l2)"

if [ ! -f "$PUT_PAYLOAD_CAPTURE_L2" ]; then
  fail "L2: PUT payload was never captured — apply_protection() incorrectly refused on an empty restrictions object"
else
  pass "L2: PUT was made despite restrictions being present (empty arrays are not unmodeled)"
fi

# =============================================================================
# Phase M — require_last_push_approval carry-through (#45 review cycle-2:
# previously silently reset to false by the merge payload, like the Phase H
# booleans were before the earlier fix).
# =============================================================================

echo ""
echo "Phase M: apply_protection() carries through require_last_push_approval from the existing rule"

PHASE_M_ATELIER_CFG="$TMP/phase-m-atelier-cfg"
mkdir -p "$PHASE_M_ATELIER_CFG/gh/admin" "$PHASE_M_ATELIER_CFG/gh/author"
printf 'WRITE\n' > "$PHASE_M_ATELIER_CFG/gh/admin/perm"
printf 'ADMIN\n' > "$PHASE_M_ATELIER_CFG/gh/author/perm"

EXISTING_LASTPUSH_JSON="$TMP/existing_lastpush.json"
cat > "$EXISTING_LASTPUSH_JSON" << 'EOF'
{
  "required_status_checks": null,
  "enforce_admins": {"enabled": false},
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "require_last_push_approval": true,
    "required_approving_review_count": 0
  },
  "restrictions": null
}
EOF

PUT_PAYLOAD_CAPTURE_M="$TMP/put_payload_m.json"
rm -f "$PUT_PAYLOAD_CAPTURE_M"

cat > "$TMP/bin/gh" << SHIMEOF
#!/usr/bin/env bash
EXISTING_JSON="${EXISTING_LASTPUSH_JSON}"
PUT_PAYLOAD_CAPTURE="${PUT_PAYLOAD_CAPTURE_M}"
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

out_m="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_M_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" --json 2>&1)"
rc_m=$?

[ "$rc_m" -eq 0 ] \
  && pass "M0: --apply exits 0 on a protected-insufficient branch with require_last_push_approval set" \
  || fail "M0: --apply exited $rc_m, expected 0 (output: $out_m)"

if [ ! -f "$PUT_PAYLOAD_CAPTURE_M" ]; then
  fail "M: PUT payload was never captured — gh -X PUT was not called"
else
  rlpa="$(jq -r '.required_pull_request_reviews.require_last_push_approval' "$PUT_PAYLOAD_CAPTURE_M")"
  [ "$rlpa" = "true" ] \
    && pass "M1: require_last_push_approval preserved (true) — previously silently reset to false" \
    || fail "M1: require_last_push_approval: expected 'true', got '$rlpa'"
fi

# =============================================================================
# Phase N — enforce_admins relaxation note (#45 review cycle-2 critical
# finding sub-point (a)): text output only, no JSON field. Present when the
# existing rule had enforce_admins.enabled=true, absent otherwise.
# =============================================================================

echo ""
echo "Phase N: text-mode success output notes when enforce_admins was true on the existing rule and is kept false"

PHASE_N_ATELIER_CFG="$TMP/phase-n-atelier-cfg"
mkdir -p "$PHASE_N_ATELIER_CFG/gh/admin" "$PHASE_N_ATELIER_CFG/gh/author"
printf 'WRITE\n' > "$PHASE_N_ATELIER_CFG/gh/admin/perm"
printf 'ADMIN\n' > "$PHASE_N_ATELIER_CFG/gh/author/perm"

# --- N1: existing enforce_admins.enabled=true -> note present ---
EXISTING_ENFORCE_TRUE_JSON="$TMP/existing_enforce_true.json"
cat > "$EXISTING_ENFORCE_TRUE_JSON" << 'EOF'
{
  "required_status_checks": null,
  "enforce_admins": {"enabled": true},
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0
  },
  "restrictions": null
}
EOF

cat > "$TMP/bin/gh" << SHIMEOF
#!/usr/bin/env bash
EXISTING_JSON="${EXISTING_ENFORCE_TRUE_JSON}"
case "\$*" in
  *"-X PUT"*"protection"*)
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

out_n1="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_N_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" 2>&1)"
rc_n1=$?

[ "$rc_n1" -eq 0 ] \
  && pass "N0: --apply exits 0 when the existing rule has enforce_admins.enabled=true" \
  || fail "N0: --apply exited $rc_n1, expected 0 (output: $out_n1)"

if printf '%s' "$out_n1" | grep -q "note: enforce_admins was true on the existing rule and is kept false"; then
  pass "N1: text output contains the enforce_admins relaxation note when the existing rule had it true"
else
  fail "N1: expected the relaxation note in text output (got: $out_n1)"
fi

# --- N2 (negative companion): existing enforce_admins.enabled=false -> note
#     ABSENT. ---
EXISTING_ENFORCE_FALSE_JSON="$TMP/existing_enforce_false.json"
cat > "$EXISTING_ENFORCE_FALSE_JSON" << 'EOF'
{
  "required_status_checks": null,
  "enforce_admins": {"enabled": false},
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0
  },
  "restrictions": null
}
EOF

cat > "$TMP/bin/gh" << SHIMEOF
#!/usr/bin/env bash
EXISTING_JSON="${EXISTING_ENFORCE_FALSE_JSON}"
case "\$*" in
  *"-X PUT"*"protection"*)
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

out_n2="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_N_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" 2>&1)"
rc_n2=$?

[ "$rc_n2" -eq 0 ] \
  && pass "N0b: --apply exits 0 when the existing rule has enforce_admins.enabled=false" \
  || fail "N0b: --apply exited $rc_n2, expected 0 (output: $out_n2)"

if printf '%s' "$out_n2" | grep -q "note: enforce_admins was true"; then
  fail "N2: relaxation note unexpectedly present when the existing rule already had enforce_admins=false (got: $out_n2)"
else
  pass "N2: relaxation note absent when the existing rule already had enforce_admins=false"
fi

# =============================================================================
# Phase O — #45 REVIEW CYCLE-3: has_unmodeled_restrictions must be symmetric
# across all three clauses (dismissal_restrictions / bypass_pull_request_
# allowances / top-level restrictions) — each enumerates users+teams+apps.
# An apps-only fixture on EACH clause, reusing run_unmergeable_case() from
# Phase I. Before this cycle's fix, dismissal_restrictions counted only
# users+teams, so O1 (apps-only) would have escaped refusal entirely:
# applied, exit 0, the apps-only field silently dropped from the PUT.
# =============================================================================

echo ""
echo "Phase O: apps-only unmodeled restrictions are refused symmetrically on all three clauses"

PHASE_O_ATELIER_CFG="$TMP/phase-o-atelier-cfg"
mkdir -p "$PHASE_O_ATELIER_CFG/gh/admin" "$PHASE_O_ATELIER_CFG/gh/author"
printf 'WRITE\n' > "$PHASE_O_ATELIER_CFG/gh/admin/perm"
printf 'ADMIN\n' > "$PHASE_O_ATELIER_CFG/gh/author/perm"

# --- O1: dismissal_restrictions with ONLY apps populated (users/teams empty)
#     — the exact shape that previously escaped refusal. ---
EXISTING_DISMISSAL_APPS_JSON="$TMP/existing_dismissal_apps.json"
cat > "$EXISTING_DISMISSAL_APPS_JSON" << 'EOF'
{
  "required_status_checks": null,
  "enforce_admins": {"enabled": false},
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0,
    "dismissal_restrictions": {"users": [], "teams": [], "apps": [{"slug": "my-app", "id": 123}]}
  },
  "restrictions": null
}
EOF

call_log_o1="$(run_unmergeable_case "$EXISTING_DISMISSAL_APPS_JSON" "o1")"

out_o1="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_O_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" 2>&1)"
rc_o1=$?

[ "$rc_o1" -eq 3 ] \
  && pass "O1: --apply exits 3 when dismissal_restrictions has ONLY apps populated (users/teams empty)" \
  || fail "O1: expected exit 3, got $rc_o1 (output: $out_o1)"

if printf '%s' "$out_o1" | grep -q "dismissal_restrictions"; then
  pass "O1: print_unmergeable_block's text on stdout names dismissal_restrictions"
else
  fail "O1: expected 'dismissal_restrictions' on stdout (got: $out_o1)"
fi

if [ -f "$call_log_o1" ] && grep -q -- "-X PUT" "$call_log_o1"; then
  fail "O1: THE CRITICAL REGRESSION — a PUT was made despite an apps-only dismissal_restrictions (call log: $(cat "$call_log_o1"))"
else
  pass "O1: no PUT was made"
fi

# --- O2: bypass_pull_request_allowances with ONLY apps populated ---
EXISTING_BYPASS_APPS_JSON="$TMP/existing_bypass_apps.json"
cat > "$EXISTING_BYPASS_APPS_JSON" << 'EOF'
{
  "required_status_checks": null,
  "enforce_admins": {"enabled": false},
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0,
    "bypass_pull_request_allowances": {"users": [], "teams": [], "apps": [{"slug": "my-app", "id": 123}]}
  },
  "restrictions": null
}
EOF

call_log_o2="$(run_unmergeable_case "$EXISTING_BYPASS_APPS_JSON" "o2")"

out_o2="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_O_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" 2>&1)"
rc_o2=$?

[ "$rc_o2" -eq 3 ] \
  && pass "O2: --apply exits 3 when bypass_pull_request_allowances has ONLY apps populated" \
  || fail "O2: expected exit 3, got $rc_o2 (output: $out_o2)"

if printf '%s' "$out_o2" | grep -q "bypass_pull_request_allowances"; then
  pass "O2: print_unmergeable_block's text on stdout names bypass_pull_request_allowances"
else
  fail "O2: expected 'bypass_pull_request_allowances' on stdout (got: $out_o2)"
fi

if [ -f "$call_log_o2" ] && grep -q -- "-X PUT" "$call_log_o2"; then
  fail "O2: THE CRITICAL REGRESSION — a PUT was made despite an apps-only bypass_pull_request_allowances (call log: $(cat "$call_log_o2"))"
else
  pass "O2: no PUT was made"
fi

# --- O3: top-level restrictions with ONLY apps populated ---
EXISTING_RESTRICTIONS_APPS_JSON="$TMP/existing_restrictions_apps.json"
cat > "$EXISTING_RESTRICTIONS_APPS_JSON" << 'EOF'
{
  "required_status_checks": null,
  "enforce_admins": {"enabled": false},
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0
  },
  "restrictions": {"users": [], "teams": [], "apps": [{"slug": "my-app", "id": 123}]}
}
EOF

call_log_o3="$(run_unmergeable_case "$EXISTING_RESTRICTIONS_APPS_JSON" "o3")"

out_o3="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_O_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" 2>&1)"
rc_o3=$?

[ "$rc_o3" -eq 3 ] \
  && pass "O3: --apply exits 3 when top-level restrictions has ONLY apps populated" \
  || fail "O3: expected exit 3, got $rc_o3 (output: $out_o3)"

if printf '%s' "$out_o3" | grep -q "restrictions"; then
  pass "O3: print_unmergeable_block's text on stdout names restrictions"
else
  fail "O3: expected 'restrictions' on stdout (got: $out_o3)"
fi

if [ -f "$call_log_o3" ] && grep -q -- "-X PUT" "$call_log_o3"; then
  fail "O3: THE CRITICAL REGRESSION — a PUT was made despite an apps-only top-level restrictions (call log: $(cat "$call_log_o3"))"
else
  pass "O3: no PUT was made"
fi

# =============================================================================
# Phase P — #45 REVIEW CYCLE-3: an admin re-read that returns rc 0 but is
# otherwise unusable must never be treated as "no rule exists" either — the
# non-404-error and failed-companion-read doors were pinned in Phase K, but
# an rc-0 read that comes back empty or unparseable fell through BOTH
# existing guards untouched (the review's "more reachable" door).
# =============================================================================

echo ""
echo "Phase P: apply_protection() aborts instead of PUTting when the admin re-read returns rc 0 but an unusable body"

PHASE_P_ATELIER_CFG="$TMP/phase-p-atelier-cfg"
GH_AUTHOR_DIR_P="$PHASE_P_ATELIER_CFG/gh/author"   # PROBE identity — always 403s, never admin
GH_ADMIN_DIR_P="$PHASE_P_ATELIER_CFG/gh/admin"     # ADMIN identity — re-read behavior varies per case
mkdir -p "$GH_AUTHOR_DIR_P" "$GH_ADMIN_DIR_P"
printf 'WRITE\n' > "$GH_AUTHOR_DIR_P/perm"
printf 'ADMIN\n' > "$GH_ADMIN_DIR_P/perm"

# --- P1: rc 0, EMPTY body ---
GH_CALL_LOG_P1="$TMP/gh_call_log_p1"
rm -f "$GH_CALL_LOG_P1"

cat > "$TMP/bin/gh" << SHIMEOF
#!/usr/bin/env bash
CALL_LOG="${GH_CALL_LOG_P1}"
ADMIN_DIR="${GH_ADMIN_DIR_P}"
printf '%s\n' "\$*" >> "\$CALL_LOG"
case "\$*" in
  *"-X PUT"*"protection"*)
    printf 'UNEXPECTED PUT INVOKED\n' >> "\$CALL_LOG"
    printf '{}\n'
    ;;
  *"api user --jq .login"*)
    printf 'fake-admin-login\n'
    ;;
  *"viewerPermission"*)
    permfile="\${GH_CONFIG_DIR:-}/perm"
    if [ -f "\$permfile" ]; then cat "\$permfile"; else printf 'NONE\n'; fi
    ;;
  *"branches/"*"/protection"*)
    if [ "\${GH_CONFIG_DIR:-}" = "\$ADMIN_DIR" ]; then
      : # rc 0, deliberately no stdout at all
    else
      printf 'Must have admin rights to Repository.\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'gh-stub: unexpected args: %s\n' "\$*" >&2
    exit 1
    ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

P1_STDERR="$TMP/p1.stderr"
out_p1="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_P_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" --json 2>"$P1_STDERR")"
rc_p1=$?

[ "$rc_p1" -eq 2 ] \
  && pass "P1: rc-0-but-empty admin re-read -> --apply exits 2 (not treated as 'no rule exists')" \
  || fail "P1: expected exit 2, got $rc_p1 (output: $out_p1)"

status_p1="$(printf '%s' "$out_p1" | jq -r '.status // empty' 2>/dev/null)"
[ "$status_p1" = "read-failed" ] \
  && pass "P1: JSON status = 'read-failed'" \
  || fail "P1: expected JSON status 'read-failed', got '$status_p1' (output: $out_p1)"

if grep -q "empty body" "$P1_STDERR"; then
  pass "P1: apply_protection()'s own diagnostic ('empty body') is surfaced on stderr"
else
  fail "P1: expected the empty-body diagnostic on stderr (got: $(cat "$P1_STDERR"))"
fi

if [ -f "$GH_CALL_LOG_P1" ] && grep -q -- "-X PUT" "$GH_CALL_LOG_P1"; then
  fail "P1: THE CRITICAL REGRESSION — a PUT was made despite an rc-0-but-empty admin re-read (call log: $(cat "$GH_CALL_LOG_P1"))"
else
  pass "P1: no PUT was ever made"
fi

# --- P2: rc 0, body that is NOT valid JSON (jq cannot build a merge payload
#     from it) ---
GH_CALL_LOG_P2="$TMP/gh_call_log_p2"
rm -f "$GH_CALL_LOG_P2"

cat > "$TMP/bin/gh" << SHIMEOF
#!/usr/bin/env bash
CALL_LOG="${GH_CALL_LOG_P2}"
ADMIN_DIR="${GH_ADMIN_DIR_P}"
printf '%s\n' "\$*" >> "\$CALL_LOG"
case "\$*" in
  *"-X PUT"*"protection"*)
    printf 'UNEXPECTED PUT INVOKED\n' >> "\$CALL_LOG"
    printf '{}\n'
    ;;
  *"api user --jq .login"*)
    printf 'fake-admin-login\n'
    ;;
  *"viewerPermission"*)
    permfile="\${GH_CONFIG_DIR:-}/perm"
    if [ -f "\$permfile" ]; then cat "\$permfile"; else printf 'NONE\n'; fi
    ;;
  *"branches/"*"/protection"*)
    if [ "\${GH_CONFIG_DIR:-}" = "\$ADMIN_DIR" ]; then
      printf '<html>oops</html>\n'
    else
      printf 'Must have admin rights to Repository.\n' >&2
      exit 1
    fi
    ;;
  *)
    printf 'gh-stub: unexpected args: %s\n' "\$*" >&2
    exit 1
    ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

P2_STDERR="$TMP/p2.stderr"
out_p2="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_P_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" --json 2>"$P2_STDERR")"
rc_p2=$?

[ "$rc_p2" -eq 2 ] \
  && pass "P2: rc-0-but-unparseable admin re-read -> --apply exits 2 (not treated as 'no rule exists')" \
  || fail "P2: expected exit 2, got $rc_p2 (output: $out_p2)"

status_p2="$(printf '%s' "$out_p2" | jq -r '.status // empty' 2>/dev/null)"
[ "$status_p2" = "read-failed" ] \
  && pass "P2: JSON status = 'read-failed'" \
  || fail "P2: expected JSON status 'read-failed', got '$status_p2' (output: $out_p2)"

if grep -q "could not build a merge payload" "$P2_STDERR"; then
  pass "P2: apply_protection()'s own diagnostic ('could not build a merge payload') is surfaced on stderr"
else
  fail "P2: expected the unparseable-body diagnostic on stderr (got: $(cat "$P2_STDERR"))"
fi

if [ -f "$GH_CALL_LOG_P2" ] && grep -q -- "-X PUT" "$GH_CALL_LOG_P2"; then
  fail "P2: THE CRITICAL REGRESSION — a PUT was made despite an unparseable admin re-read body (call log: $(cat "$GH_CALL_LOG_P2"))"
else
  pass "P2: no PUT was ever made"
fi

# =============================================================================
# Phase Q — #45 REVIEW CYCLE-3: allow_fork_syncing carry-through, the field
# that was silently omitted from the merge payload and reset to its API
# default (false) on every PUT. Q1 uses enabled: true specifically because
# it is the NON-default value — a fixture asserting false would pass even
# if the field were dropped entirely (the same gap Phase H's fixture had
# before this cycle's H4/H5/H6 correction).
# =============================================================================

echo ""
echo "Phase Q: apply_protection() carries through allow_fork_syncing"

PHASE_Q_ATELIER_CFG="$TMP/phase-q-atelier-cfg"
mkdir -p "$PHASE_Q_ATELIER_CFG/gh/admin" "$PHASE_Q_ATELIER_CFG/gh/author"
printf 'WRITE\n' > "$PHASE_Q_ATELIER_CFG/gh/admin/perm"
printf 'ADMIN\n' > "$PHASE_Q_ATELIER_CFG/gh/author/perm"

EXISTING_FORKSYNC_JSON="$TMP/existing_forksync.json"
cat > "$EXISTING_FORKSYNC_JSON" << 'EOF'
{
  "required_status_checks": null,
  "enforce_admins": {"enabled": false},
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "allow_fork_syncing": {"enabled": true}
}
EOF

PUT_PAYLOAD_CAPTURE_Q="$TMP/put_payload_q.json"
rm -f "$PUT_PAYLOAD_CAPTURE_Q"

cat > "$TMP/bin/gh" << SHIMEOF
#!/usr/bin/env bash
EXISTING_JSON="${EXISTING_FORKSYNC_JSON}"
PUT_PAYLOAD_CAPTURE="${PUT_PAYLOAD_CAPTURE_Q}"
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

out_q="$(HOME="$CLI_HOME" XDG_CONFIG_HOME="$CLI_XDG" ATELIER_CONFIG_DIR="$PHASE_Q_ATELIER_CFG" \
  bash "$HELPER_SCRIPT" --apply --repo "$OWNER_REPO" --branch "$BRANCH" --json 2>&1)"
rc_q=$?

[ "$rc_q" -eq 0 ] \
  && pass "Q0: --apply exits 0 on a protected-insufficient branch with allow_fork_syncing.enabled=true" \
  || fail "Q0: --apply exited $rc_q, expected 0 (output: $out_q)"

if [ ! -f "$PUT_PAYLOAD_CAPTURE_Q" ]; then
  fail "Q: PUT payload was never captured — gh -X PUT was not called"
else
  afs="$(jq -r '.allow_fork_syncing' "$PUT_PAYLOAD_CAPTURE_Q")"
  [ "$afs" = "true" ] \
    && pass "Q1: allow_fork_syncing carried through as plain boolean true (non-default value; a false fixture would not discriminate)" \
    || fail "Q1: allow_fork_syncing: expected 'true', got '$afs'"
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
