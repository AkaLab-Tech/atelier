#!/usr/bin/env bash
#
# Tests for task #31 (M7.1.F31) / #45 — setup-project branch protection step.
#
# #45 extracted classify_branch_protection() (and the inline payload/PUT/
# verify block) out of atelier-setup-project entirely; it now lives only in
# the shared helper scripts/atelier-branch-protection, and
# step_branch_protection() delegates to it as an external binary via
# resolve_branch_protection_helper().
#
# #45 CYCLE 7 (DESCOPE): the write path (the PUT payload apply_protection()
# builds) is UNVERIFIED against GitHub's real API contract — see the "PUT
# CONTRACT UNVERIFIED" comment above that function in the helper. The
# default is no longer "apply automatically" — it is "classify and report
# only" (`--status`, never PUTs). --apply-branch-protection flips from a
# deprecated no-op to the real, functional opt-in that reaches --apply.
# --no-branch-protection is unchanged (skips the step entirely, detect and
# apply both). This repoint touches every phase below except A and C:
#   - APPLY_BRANCH_PROTECTION_FLAG must now be seeded (see the "Set required
#     globals" block) — step_branch_protection() reads it under `set -uo
#     pipefail`, and this harness sources only the extracted fragment, never
#     the whole script where the flag is normally declared.
#   - B1 is repointed from "default-on applies" to "default path only
#     classifies (--status), never applies"; the old B1 content (apply
#     opt-in) survives as B1-apply-opt-in, now explicitly gated behind
#     APPLY_BRANCH_PROTECTION_FLAG=true.
#   - B4, and every case in Phase D and Phase E, are ONLY reachable via
#     --apply (rc 2/3/4 never occur on the --status-only default path, which
#     the real helper always exits 0 for) — each now explicitly sets
#     APPLY_BRANCH_PROTECTION_FLAG=true before calling step_branch_
#     protection() and resets it to false afterward. Before this fix the
#     whole file crashed at Phase B with "APPLY_BRANCH_PROTECTION_FLAG:
#     unbound variable", so B2/B3/B4/D*/E* had not actually run since the
#     descope landed — re-verified here, all green.
#   - Phase F (new) — the real-error path: a PUT failure (rc 4) surfaces the
#     helper's captured stderr VERBATIM through BRANCH_PROTECTION_STATUS and
#     warn(), replacing the old generic "check the resolved identity has
#     repo-admin" guess.
#   - Phase G (new) — the single most important guarantee of the descope,
#     pinned directly rather than inferred from status wording: end to end
#     against the REAL atelier-branch-protection helper (not the stub), the
#     default path's own `gh` call log contains zero "-X PUT" invocations.
#
# COVERAGE
#   Phase A — classify_branch_protection() : all classification states,
#     extracted from scripts/atelier-branch-protection (the single source of
#     truth), not scripts/atelier-setup-project (deleted there). Unaffected
#     by cycle 7.
#
#   Phase B — step_branch_protection() delegation to the external helper:
#     B1  default path (APPLY_BRANCH_PROTECTION_FLAG=false, the default):
#         invokes the helper with --status (NEVER --apply — zero PUTs by
#         construction), BRANCH_PROTECTION_STATUS = "detected: <class> on
#         <repo>/<branch> (not applied — pass --apply-branch-protection to
#         apply now)" for a gap class.
#     B1-ok  negative companion: an already-sufficient class on the default
#         path reports "ok (...)", not "detected: ...".
#     B1-apply-opt-in  APPLY_BRANCH_PROTECTION_FLAG=true reaches the
#         helper's --apply mode and reports "applied ..." — this is what B1
#         used to cover under the old default-on assumption.
#     B2  --no-branch-protection: step is skipped, the helper is never
#         invoked, BRANCH_PROTECTION_STATUS = "declined (--no-branch-protection)"
#     B3  helper-not-found path: when atelier-branch-protection is on none
#         of PATH / $PLUGIN_ROOT/scripts / script-relative dir,
#         BRANCH_PROTECTION_STATUS = "skipped (atelier-branch-protection
#         helper not found)" and the step still returns 0 — silently
#         skipping protection on every fresh install would be the worst
#         failure of this task, so this path is explicitly asserted.
#     B4  no admin identity resolves (helper exits 3, under
#         APPLY_BRANCH_PROTECTION_FLAG=true): the step still returns 0
#         (advisory-never-fails), BRANCH_PROTECTION_STATUS is the
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
#     C1  --apply-branch-protection is accepted (#45 cycle 7: the real,
#         functional opt-in now, not a deprecated no-op)
#     C2  --no-branch-protection is accepted
#
#   Phase D — #45 REVIEW CYCLE-3: step_branch_protection()'s catch-all `*)`
#     case arm (any helper exit code other than 0/3/4 — in practice always 2)
#     — only reachable via --apply (APPLY_BRANCH_PROTECTION_FLAG=true in
#     every case here, cycle 7). Before cycle 3's fix it also discarded the
#     helper's stderr (2>/dev/null) and ignored $out, collapsing BOTH of the
#     helper's distinct rc-2 reasons into a bare "skipped (branch protection
#     helper exited 2)". D1: the classifier's skip:<msg> shape (e.g. a
#     transient gh 5xx during the initial classify). D2: the read-failed
#     shape (an unusable admin re-read). Both must fold $out's .message into
#     BRANCH_PROTECTION_STATUS and warn() it, mirroring the 0/3/4 arms. D3
#     (negative companion): when $out carries no parseable .message at all,
#     the bare "helper exited $rc" fallback text is used.
#
#   Phase E — #45 REVIEW CYCLE 5, finding 2's setup-project-side half: the
#     "applied" arm reads $out's .enforce_admins_relaxed / .message and
#     warn()s the message when relaxed (the helper's own --json emission of
#     these fields is pinned in branch-protection-helper.test.sh's Phase U)
#     — only reachable via --apply (APPLY_BRANCH_PROTECTION_FLAG=true,
#     cycle 7). E1/E2/E3: enforce_admins_relaxed:true -> warn() fires with
#     the message, BRANCH_PROTECTION_STATUS still reads "applied ...".
#     E4/E5 (negative companion): enforce_admins_relaxed:false +
#     message:null -> warn() must NOT fire at all.
#
#   Phase F (#45 cycle 7, new) — the rc-4 PUT-failure path relays the
#     helper's captured stderr VERBATIM through BRANCH_PROTECTION_STATUS and
#     warn(), instead of the old generic "check the resolved identity has
#     repo-admin" guess that used to misdirect a real failure (e.g. a 422
#     from a payload the endpoint rejects) toward a permissions problem that
#     may not exist.
#
#   Phase G (#45 cycle 7, new) — THE ZERO-PUT-BY-DEFAULT GUARANTEE, pinned
#     directly against the REAL atelier-branch-protection helper (not the
#     stub used everywhere else in this file — PATH is temporarily patched
#     and PLUGIN_ROOT pointed at the real repo so resolve_branch_protection_
#     helper() falls through to the actual script), asserting from `gh`'s
#     own call log that the default path issues zero "-X PUT" calls — this
#     is the single most important guarantee of the descope; every other
#     phase infers it from status wording or a stubbed intermediary, this
#     one pins it at the real `gh` boundary.
#
# Hermetic: gh and atelier-branch-protection are stubbed on PATH throughout
# (Phase G is the one exception — it stubs only gh, against the real
# helper); no network calls, no real gh api. macOS bash 3.2 compatible.
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

# Set required globals. #45 cycle 7: APPLY_BRANCH_PROTECTION_FLAG must be
# seeded here — step_branch_protection() now reads it under `set -uo
# pipefail`, and this harness sources only the extracted function fragment
# (never the whole script, which is where the flag is normally declared),
# so without this line every call below dies "unbound variable" before any
# assertion runs.
PROJECT="$PROJ_DIR"
NO_BRANCH_PROTECTION_FLAG=false
APPLY_BRANCH_PROTECTION_FLAG=false
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

# Fake atelier-branch-protection binary. Writes a marker file recording the
# exact invocation so B1/B1-apply can assert the runnable shape of the
# delegated command. #45 cycle 7: dispatch now branches FIRST on whether the
# real caller passed --status or --apply (the two are no longer
# interchangeable — the default path only ever calls --status, which the
# real helper always exits 0 for; the case/rc-driven modes below are only
# reachable via --apply, which is now opt-in). --status is dispatched on
# $HELPER_STATUS_CLASS; --apply keeps the existing $HELPER_MODE dispatch.
HELPER_INVOKED="$TMP/helper_invoked"
cat > "$TMP/bin/atelier-branch-protection" << SHIMEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${HELPER_INVOKED}"
case "\$*" in
  *"--status"*)
    printf '{"repo":"testowner/testrepo","branch":"main","class":"%s","gh_dir":"/tmp/probe","admin_gh_dir":null}\n' \
      "\${HELPER_STATUS_CLASS:-protected-insufficient}"
    exit 0
    ;;
esac
case "\${HELPER_MODE:-applied}" in
  applied)
    printf '{"status":"applied","repo":"testowner/testrepo","branch":"main","class":"protected-sufficient","identity":"fake-admin","gh_dir":"/tmp/fake-admin"}\n'
    exit 0
    ;;
  applied-relaxed)
    # #45 review finding 2: enforce_admins_relaxed + message are the JSON
    # counterpart of the helper's text-only relaxation note (see the real
    # helper's emit_result --json branch). This mode exercises the arm in
    # step_branch_protection() that reads them and warn()s the message.
    printf '{"status":"applied","repo":"testowner/testrepo","branch":"main","class":"protected-insufficient","identity":"fake-admin","gh_dir":"/tmp/fake-admin","enforce_admins_relaxed":true,"message":"enforce_admins was true on the existing rule and is kept false so the bot can still squash-merge its own PRs"}\n'
    exit 0
    ;;
  applied-not-relaxed)
    # Negative companion: enforce_admins_relaxed:false + message:null must
    # NOT produce a warn() call — only a true relaxation is worth surfacing.
    printf '{"status":"applied","repo":"testowner/testrepo","branch":"main","class":"protected-insufficient","identity":"fake-admin","gh_dir":"/tmp/fake-admin","enforce_admins_relaxed":false,"message":null}\n'
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
  put-failed)
    # #45 cycle 7, the real-error path: the PUT itself failed and the
    # helper's captured stderr is relayed verbatim via .message — must
    # surface through BRANCH_PROTECTION_STATUS / warn() as-is, not the old
    # generic "check the resolved identity has repo-admin" guess.
    printf '{"status":"put-failed","repo":"testowner/testrepo","branch":"main","class":"protected-insufficient","identity":"fake-admin","gh_dir":"/tmp/fake-admin","message":"HTTP 422: Validation Failed: required_signatures is not a permitted key for this endpoint"}\n'
    exit 4
    ;;
esac
SHIMEOF
chmod +x "$TMP/bin/atelier-branch-protection"

# --- B1 (#45 cycle 7, REPOINTED): the default path — no flag, or
#     APPLY_BRANCH_PROTECTION_FLAG explicitly false — never mutates. It must
#     invoke the helper with --status (NOT --apply — zero PUTs by
#     construction, since the real helper's --status mode never PUTs), and
#     produce the "detected: <class> ... not applied ..." wording that tells
#     the operator remediation exists but was not run. This replaces the
#     pre-cycle-7 assertion that the default path applied automatically —
#     that behaviour is deliberately gone; B1-apply-opt-in below covers what
#     used to be here, now gated behind the explicit flag. ---
rm -f "$HELPER_INVOKED"
NO_BRANCH_PROTECTION_FLAG=false
APPLY_BRANCH_PROTECTION_FLAG=false
export HELPER_STATUS_CLASS="protected-insufficient"
BRANCH_PROTECTION_STATUS=""
step_branch_protection
step_rc=$?

if [ "$step_rc" -eq 0 ]; then
  pass "B1: step_branch_protection() returns 0 on the default (detect-only) path"
else
  fail "B1: step_branch_protection() returned $step_rc, expected 0"
fi

if [ -f "$HELPER_INVOKED" ] \
  && grep -q -- "--status" "$HELPER_INVOKED" \
  && grep -q -- "--repo testowner/testrepo" "$HELPER_INVOKED" \
  && grep -q -- "--branch main" "$HELPER_INVOKED"; then
  pass "B1: default path invokes the helper with --status --repo --branch"
else
  fail "B1: helper was not invoked with the expected args (got: $(cat "$HELPER_INVOKED" 2>/dev/null || printf '<not invoked>'))"
fi

if [ -f "$HELPER_INVOKED" ] && ! grep -q -- "--apply" "$HELPER_INVOKED"; then
  pass "B1: default path NEVER invokes the helper with --apply (zero PUTs by construction)"
else
  fail "B1: default path unexpectedly invoked --apply (got: $(cat "$HELPER_INVOKED" 2>/dev/null))"
fi

if [ "$BRANCH_PROTECTION_STATUS" = "detected: protected-insufficient on testowner/testrepo/main (not applied — pass --apply-branch-protection to apply now)" ]; then
  pass "B1: BRANCH_PROTECTION_STATUS = '$BRANCH_PROTECTION_STATUS'"
else
  fail "B1: BRANCH_PROTECTION_STATUS: expected the 'detected: ... not applied ...' wording, got '$BRANCH_PROTECTION_STATUS'"
fi

# --- B1-ok: default path negative companion — an already-sufficient class
#     reports "ok (...)", not "detected: ...". Cheap regression guard that
#     the detect-only rewrite didn't collapse every class to the same
#     wording. ---
rm -f "$HELPER_INVOKED"
export HELPER_STATUS_CLASS="protected-sufficient"
BRANCH_PROTECTION_STATUS=""
step_branch_protection
step_rc=$?

if [ "$step_rc" -eq 0 ] && [ "$BRANCH_PROTECTION_STATUS" = "ok (required_approving_review_count >= 1)" ]; then
  pass "B1-ok: default path reports 'ok (...)' for an already-sufficient rule, not 'detected: ...'"
else
  fail "B1-ok: expected 'ok (required_approving_review_count >= 1)', got '$BRANCH_PROTECTION_STATUS' (rc=$step_rc)"
fi

unset HELPER_STATUS_CLASS

# --- B1-apply-opt-in (#45 cycle 7, item (c)): APPLY_BRANCH_PROTECTION_FLAG=
#     true is the explicit opt-in that reaches the helper's --apply mode —
#     this is the behaviour B1 used to cover under the old default-on
#     assumption; pinning it here keeps the gated machinery itself covered,
#     not just the fact that it is gated. ---
rm -f "$HELPER_INVOKED"
APPLY_BRANCH_PROTECTION_FLAG=true
export HELPER_MODE="applied"
BRANCH_PROTECTION_STATUS=""
step_branch_protection
step_rc=$?
APPLY_BRANCH_PROTECTION_FLAG=false

if [ "$step_rc" -eq 0 ]; then
  pass "B1-apply-opt-in: step_branch_protection() returns 0 when --apply-branch-protection is set"
else
  fail "B1-apply-opt-in: step_branch_protection() returned $step_rc, expected 0"
fi

if [ -f "$HELPER_INVOKED" ] \
  && grep -q -- "--apply" "$HELPER_INVOKED" \
  && grep -q -- "--repo testowner/testrepo" "$HELPER_INVOKED" \
  && grep -q -- "--branch main" "$HELPER_INVOKED"; then
  pass "B1-apply-opt-in: APPLY_BRANCH_PROTECTION_FLAG=true invokes the helper with --apply --repo --branch"
else
  fail "B1-apply-opt-in: helper was not invoked with the expected args (got: $(cat "$HELPER_INVOKED" 2>/dev/null || printf '<not invoked>'))"
fi

case "$BRANCH_PROTECTION_STATUS" in
  applied*)
    pass "B1-apply-opt-in: BRANCH_PROTECTION_STATUS = '$BRANCH_PROTECTION_STATUS' (contains 'applied')"
    ;;
  *)
    fail "B1-apply-opt-in: BRANCH_PROTECTION_STATUS: expected 'applied ...', got '$BRANCH_PROTECTION_STATUS'"
    ;;
esac

unset HELPER_MODE

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
#     "no admin" message. #45 cycle 7: this outcome (helper exit 3) is only
#     reachable via --apply, which is opt-in now, so this run must set
#     APPLY_BRANCH_PROTECTION_FLAG=true (re-verified per item 3d — this test
#     has not run since the default-path change; with the flag left false it
#     would silently take the --status branch instead and never reach any
#     of these assertions). ---
rm -f "$HELPER_INVOKED" "$WARN_OUT"
export HELPER_MODE="no-admin"
NO_BRANCH_PROTECTION_FLAG=false
APPLY_BRANCH_PROTECTION_FLAG=true
BRANCH_PROTECTION_STATUS=""
step_branch_protection
step_rc=$?
APPLY_BRANCH_PROTECTION_FLAG=false

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
echo "  (#45 cycle 7: rc 2 is only reachable via --apply, so every case below sets APPLY_BRANCH_PROTECTION_FLAG=true)"

# --- D1: the classifier's skip:<msg> shape (rc 2) ---
rm -f "$HELPER_INVOKED" "$WARN_OUT"
export HELPER_MODE="skip-message"
NO_BRANCH_PROTECTION_FLAG=false
APPLY_BRANCH_PROTECTION_FLAG=true
BRANCH_PROTECTION_STATUS=""
step_branch_protection
step_rc=$?
APPLY_BRANCH_PROTECTION_FLAG=false

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
APPLY_BRANCH_PROTECTION_FLAG=true
BRANCH_PROTECTION_STATUS=""
step_branch_protection
step_rc=$?
APPLY_BRANCH_PROTECTION_FLAG=false

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
APPLY_BRANCH_PROTECTION_FLAG=true
BRANCH_PROTECTION_STATUS=""
step_branch_protection
step_rc=$?
APPLY_BRANCH_PROTECTION_FLAG=false

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
# Phase E — #45 CYCLE-5: the "applied" arm reads $out's .enforce_admins_
# relaxed / .message and warn()s the message when relaxed. Finding 2 fixed
# the helper's --json branch to emit these fields at all (see the branch-
# protection-helper.test.sh Phase U companion); this phase pins the
# atelier-setup-project side that consumes them.
# =============================================================================

echo ""
echo "Phase E: step_branch_protection()'s applied arm warns enforce_admins_relaxed's message"
echo "  (#45 cycle 7: the 'applied' status is only reachable via --apply, so E1/E4 set APPLY_BRANCH_PROTECTION_FLAG=true)"

# --- E1: enforce_admins_relaxed:true -> warn() fires with the message ---
rm -f "$HELPER_INVOKED" "$WARN_OUT"
export HELPER_MODE="applied-relaxed"
NO_BRANCH_PROTECTION_FLAG=false
APPLY_BRANCH_PROTECTION_FLAG=true
BRANCH_PROTECTION_STATUS=""
step_branch_protection
step_rc=$?
APPLY_BRANCH_PROTECTION_FLAG=false

if [ "$step_rc" -eq 0 ]; then
  pass "E1: step_branch_protection() returns 0 on the applied+relaxed path"
else
  fail "E1: step_branch_protection() returned $step_rc, expected 0"
fi

if [ -f "$WARN_OUT" ] && grep -q "enforce_admins was true on the existing rule and is kept false" "$WARN_OUT"; then
  pass "E2: warn() fired with the enforce_admins_relaxed message"
else
  fail "E2: expected warn() to fire with the relaxation message (got: $(cat "$WARN_OUT" 2>/dev/null || printf '<nothing>'))"
fi

case "$BRANCH_PROTECTION_STATUS" in
  applied*)
    pass "E3: BRANCH_PROTECTION_STATUS = '$BRANCH_PROTECTION_STATUS' (contains 'applied') even when relaxed" ;;
  *)
    fail "E3: BRANCH_PROTECTION_STATUS: expected 'applied ...', got '$BRANCH_PROTECTION_STATUS'" ;;
esac

# --- E4 (negative companion): enforce_admins_relaxed:false + message:null ->
#     warn() must NOT fire at all. ---
rm -f "$HELPER_INVOKED" "$WARN_OUT"
export HELPER_MODE="applied-not-relaxed"
NO_BRANCH_PROTECTION_FLAG=false
APPLY_BRANCH_PROTECTION_FLAG=true
BRANCH_PROTECTION_STATUS=""
step_branch_protection
step_rc=$?
APPLY_BRANCH_PROTECTION_FLAG=false

if [ "$step_rc" -eq 0 ]; then
  pass "E4: step_branch_protection() returns 0 on the applied+not-relaxed path"
else
  fail "E4: step_branch_protection() returned $step_rc, expected 0"
fi

if [ ! -f "$WARN_OUT" ]; then
  pass "E5: warn() was never called when enforce_admins_relaxed is false"
else
  fail "E5: warn() unexpectedly fired when enforce_admins was not relaxed (got: $(cat "$WARN_OUT"))"
fi

unset HELPER_MODE

# =============================================================================
# Phase F — #45 CYCLE 7, THE REAL-ERROR PATH: a PUT failure surfaces the
# helper's captured stderr (.message) VERBATIM through BRANCH_PROTECTION_
# STATUS and warn(), replacing the old generic "check the resolved identity
# has repo-admin" guess that used to misdirect a real failure (e.g. a 422
# from a payload the endpoint rejects) toward a permissions problem that may
# not exist. Only reachable via --apply (rc 4), so APPLY_BRANCH_PROTECTION_
# FLAG=true here too.
# =============================================================================

echo ""
echo "Phase F: rc-4 PUT-failure path relays the real gh error verbatim, not the old generic guess"

PUT_ERROR_TEXT="HTTP 422: Validation Failed: required_signatures is not a permitted key for this endpoint"

rm -f "$HELPER_INVOKED" "$WARN_OUT"
export HELPER_MODE="put-failed"
NO_BRANCH_PROTECTION_FLAG=false
APPLY_BRANCH_PROTECTION_FLAG=true
BRANCH_PROTECTION_STATUS=""
step_branch_protection
step_rc=$?
APPLY_BRANCH_PROTECTION_FLAG=false

if [ "$step_rc" -eq 0 ]; then
  pass "F1: step_branch_protection() returns 0 on a PUT failure (advisory, never fails)"
else
  fail "F1: step_branch_protection() returned $step_rc, expected 0"
fi

case "$BRANCH_PROTECTION_STATUS" in
  *"$PUT_ERROR_TEXT"*)
    pass "F2: BRANCH_PROTECTION_STATUS contains the real gh error verbatim ('$PUT_ERROR_TEXT')" ;;
  *)
    fail "F2: BRANCH_PROTECTION_STATUS: expected it to contain '$PUT_ERROR_TEXT', got '$BRANCH_PROTECTION_STATUS'" ;;
esac

case "$BRANCH_PROTECTION_STATUS" in
  *"check the resolved identity has repo-admin"*)
    fail "F3: BRANCH_PROTECTION_STATUS still contains the old generic guess (should be gone)" ;;
  *)
    pass "F3: BRANCH_PROTECTION_STATUS does NOT contain the old generic 'check the resolved identity has repo-admin' guess" ;;
esac

if [ -f "$WARN_OUT" ] && grep -qF "$PUT_ERROR_TEXT" "$WARN_OUT"; then
  pass "F4: warn() fired with the real gh error verbatim"
else
  fail "F4: expected warn() to fire with '$PUT_ERROR_TEXT' (got: $(cat "$WARN_OUT" 2>/dev/null || printf '<nothing>'))"
fi

unset HELPER_MODE

# =============================================================================
# Phase G — #45 CYCLE 7, ZERO-PUT-BY-DEFAULT: the single most important
# guarantee of the descope, pinned end to end against the REAL
# atelier-branch-protection helper (not the stub above) so nothing about the
# real script's own --status/--apply dispatch is assumed. The stubbed
# atelier-branch-protection binary is temporarily removed from PATH and
# PLUGIN_ROOT is pointed at the real repo so resolve_branch_protection_
# helper() falls through to the actual scripts/atelier-branch-protection;
# only `gh` is stubbed, and its call log is asserted to contain zero
# "-X PUT" invocations for the default (APPLY_BRANCH_PROTECTION_FLAG=false)
# path — the guarantee is pinned directly from the call log, never inferred
# from status wording (which Phase B already covers separately).
# =============================================================================

echo ""
echo "Phase G: default path issues zero -X PUT calls end-to-end against the REAL helper"

GH_CALL_LOG_G="$TMP/gh_call_log_g"
rm -f "$GH_CALL_LOG_G"
cat > "$TMP/bin/gh" << SHIMEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${GH_CALL_LOG_G}"
case "\$*" in
  *"nameWithOwner,defaultBranchRef"*)
    printf '{"nameWithOwner":"testowner/testrepo","defaultBranchRef":{"name":"main"}}\n'
    ;;
  *"-X PUT"*"protection"*)
    printf '{}\n'
    ;;
  *"branches/"*"/protection"*)
    printf '{"required_pull_request_reviews":{"required_approving_review_count":0}}\n'
    ;;
  *"viewerPermission"*)
    printf 'NONE\n'
    ;;
  *"api user --jq .login"*)
    printf 'fake-login\n'
    ;;
  *)
    printf 'gh-stub-g: unexpected args: %s\n' "\$*" >&2
    exit 1
    ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"

mv "$TMP/bin/atelier-branch-protection" "$TMP/bin/atelier-branch-protection.disabled.g"
SAVED_PLUGIN_ROOT_G="$PLUGIN_ROOT"
PLUGIN_ROOT="$REPO_ROOT"
unset ATELIER_CONFIG_DIR ATELIER_ADMIN_GH_CONFIG_DIR
NO_BRANCH_PROTECTION_FLAG=false
APPLY_BRANCH_PROTECTION_FLAG=false
BRANCH_PROTECTION_STATUS=""
step_branch_protection
step_rc=$?

PLUGIN_ROOT="$SAVED_PLUGIN_ROOT_G"
mv "$TMP/bin/atelier-branch-protection.disabled.g" "$TMP/bin/atelier-branch-protection"

if [ "$step_rc" -eq 0 ]; then
  pass "G1: step_branch_protection() returns 0 against the real helper on the default path"
else
  fail "G1: step_branch_protection() returned $step_rc, expected 0"
fi

if [ -f "$GH_CALL_LOG_G" ] && ! grep -q -- "-X PUT" "$GH_CALL_LOG_G"; then
  pass "G2: zero '-X PUT' calls in gh's call log on the default path (the descope's central guarantee)"
else
  fail "G2: expected zero '-X PUT' calls, got: $(cat "$GH_CALL_LOG_G" 2>/dev/null || printf '<no call log>')"
fi

case "$BRANCH_PROTECTION_STATUS" in
  detected:*)
    pass "G3: BRANCH_PROTECTION_STATUS = '$BRANCH_PROTECTION_STATUS' (the real helper's --status classification, detect-only)" ;;
  *)
    fail "G3: BRANCH_PROTECTION_STATUS: expected a 'detected: ...' classification from the real helper, got '$BRANCH_PROTECTION_STATUS'" ;;
esac

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
  pass "C1: --apply-branch-protection is accepted (#45 cycle 7: the real, functional opt-in now, not a no-op — see B1-apply-opt-in for its behaviour)"
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
