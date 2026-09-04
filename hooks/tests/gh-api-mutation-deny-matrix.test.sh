#!/usr/bin/env bash
#
# Regression test for #197 — close gh api mutation deny bypasses (implicit
# POST, graphql, syntax variants).
#
# Root cause: templates/settings.template.json only denied `gh api` mutations
# in two syntax shapes (`-X POST`, `--method POST`, leading position, and only
# for POST/PATCH/DELETE — PUT was missing entirely). An agent could route
# around the deny glob just by dropping the space (`-XPOST`), using `=`
# (`--method=POST`), or putting the endpoint before the flag
# (`gh api repos/x/y/issues -X POST`). #197 closes those syntax gaps for all
# four verbs (POST/PATCH/PUT/DELETE) in both leading and endpoint-first
# argument order.
#
# This is a STATIC MATRIX test in the same style as
# hooks/tests/deny-gh-identity-tokens.test.sh and the Layer 1 matrix in
# hooks/tests/block-protected-push.test.sh: a path-parameterized jq predicate,
# exact-string equality (not substring/regex), run over the real shipped
# template. No hook is involved (a categorical PreToolUse guard for gh api
# mutations is explicitly out of scope for #197 — see PLAN.md §3), so there is
# no Layer 2 to test here, only the Layer 1 glob surface itself.
#
# Contract invariants asserted:
#   Group 1 — all 4 verbs (POST/PATCH/PUT/DELETE) are denied in all 4 syntax
#     shapes (`-X V`, `-XV`, `--method V`, `--method=V`), in BOTH leading
#     position (`gh api -X POST*`) and endpoint-first position
#     (`gh api * -X POST*`) — 32 entries total.
#   Group 2 — negative control: the predicate does not vacuously pass.
#   Group 3 — the pre-existing read-only gh api ALLOW entries are untouched
#     (additive-only fix).
#   Group 4 — no blanket -f/-F/--field/--raw-field/--input/graphql deny was
#     introduced. Denying those would break the repo's own github-project
#     board-tracking backend, which relies on exactly that implicit-POST
#     shape for its sanctioned mutations (addProjectV2DraftIssue,
#     updateProjectV2ItemFieldValue, addProjectV2ItemById — see PLAN.md §3).
#     This guards against a *future* over-tightening regression, not #197's
#     own diff (#197 deliberately leaves this gap open and documents it).
#
# Hermetic: no network, no `gh` calls, no writes outside a mktemp dir (in
# fact this test does no writes at all — it only reads the committed
# template).
#
# Run:  hooks/tests/gh-api-mutation-deny-matrix.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/settings.template.json"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "#197 regression — gh api mutation deny matrix (templates/settings.template.json)"

if [ ! -f "$TEMPLATE" ]; then
  echo "FATAL: templates/settings.template.json not found at $TEMPLATE"
  exit 1
fi

if ! jq -e . "$TEMPLATE" >/dev/null 2>&1; then
  echo "FATAL: templates/settings.template.json is not valid JSON"
  exit 1
fi
pass "templates/settings.template.json: valid JSON"

# --- helper: does <file>'s permissions.deny array literally contain <entry>?
deny_has_entry() {
  local file="$1" entry="$2"
  jq -e --arg want "$entry" \
    '(.permissions.deny // []) | any(. == $want)' \
    "$file" >/dev/null 2>&1
}

# --- helper: does <file>'s permissions.allow array literally contain <entry>?
allow_has_entry() {
  local file="$1" entry="$2"
  jq -e --arg want "$entry" \
    '(.permissions.allow // []) | any(. == $want)' \
    "$file" >/dev/null 2>&1
}

# =============================================================================
# Group 1 — full 4-verb x 4-syntax x 2-position matrix (32 entries)
# =============================================================================
echo
echo "  -- Group 1: full verb x syntax x position matrix --"

VERBS=(POST PATCH PUT DELETE)

for verb in "${VERBS[@]}"; do
  for entry in \
    "Bash(gh api -X ${verb}*)" \
    "Bash(gh api -X${verb}*)" \
    "Bash(gh api --method ${verb}*)" \
    "Bash(gh api --method=${verb}*)" \
    "Bash(gh api * -X ${verb}*)" \
    "Bash(gh api * -X${verb}*)" \
    "Bash(gh api * --method ${verb}*)" \
    "Bash(gh api * --method=${verb}*)"; do
    if deny_has_entry "$TEMPLATE" "$entry"; then
      pass "deny[] carries $entry"
    else
      fail "deny[] is MISSING $entry — #197 syntax-variant closure regressed"
    fi
  done
done

# =============================================================================
# Group 2 — negative control: the predicate must actually discriminate.
# =============================================================================
echo
echo "  -- Group 2: negative control --"

if deny_has_entry "$TEMPLATE" 'Bash(gh api -X TRACE*)'; then
  fail "negative control is broken: deny_has_entry matched an entry (TRACE) that is not in the template"
else
  pass "negative control: deny_has_entry correctly rejects an absent verb (TRACE)"
fi

# =============================================================================
# Group 3 — pre-existing read-only gh api ALLOW entries are untouched.
# =============================================================================
echo
echo "  -- Group 3: pre-existing read-only gh api allow entries untouched --"

for entry in \
  'Bash(GH_CONFIG_DIR=* gh api user*)' \
  'Bash(gh api repos/AkaLab-Tech/atelier/releases/latest*)' \
  'Bash(gh api repos/AkaLab-Tech/atelier/tags*)' \
  'Bash(gh api repos/AkaLab-Tech/git-wt/commits/main*)'; do
  if allow_has_entry "$TEMPLATE" "$entry"; then
    pass "allow[] still carries $entry"
  else
    fail "allow[] is MISSING $entry — #197 must be additive-only on deny[], not touch read-only allow[] entries"
  fi
done

# =============================================================================
# Group 4 — no blanket -f/-F/--field/--raw-field/--input/graphql deny.
# =============================================================================
echo
echo "  -- Group 4: no over-tightening into implicit-POST / graphql surface --"

# Deliberate non-goal (PLAN.md §3): a blanket deny on any of these would
# break the github-project tracking backend's own sanctioned mutations.
FORBIDDEN_OVERREACH_SUBSTRINGS=(
  '-f '
  '-f*'
  '-F '
  '-F*'
  '--field'
  '--raw-field'
  '--input'
  'graphql'
)

overreach_found=0
while IFS= read -r deny_entry; do
  for bad in "${FORBIDDEN_OVERREACH_SUBSTRINGS[@]}"; do
    case "$deny_entry" in
      *"$bad"*)
        fail "deny[] entry '$deny_entry' matches forbidden overreach substring '$bad' — would break github-project board tracking (PLAN.md §3 non-goal)"
        overreach_found=1
        ;;
    esac
  done
done < <(jq -r '(.permissions.deny // [])[] | select(test("gh api"))' "$TEMPLATE")

if [ "$overreach_found" -eq 0 ]; then
  pass "no gh api deny[] entry over-tightens into implicit-POST fields or graphql"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "#197 gh api mutation deny matrix: all assertions passed."
  exit 0
else
  echo "#197 gh api mutation deny matrix: $fails assertion(s) failed."
  exit 1
fi
