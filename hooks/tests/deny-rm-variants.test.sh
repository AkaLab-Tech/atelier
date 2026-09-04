#!/usr/bin/env bash
#
# Regression test for #199 — cover equivalent rm -rf variants (-Rf, -r -f,
# --recursive --force, verbose flag, etc.) in the deny rule.
#
# Pre-fix, templates/settings.template.json's permissions.deny only listed
# the two literal spellings "Bash(rm -rf *)" and "Bash(rm -fr *)". An agent
# could route around the deny rule with an equivalent invocation the glob
# didn't happen to match: case-swapped flags (-Rf/-fR), separated flags
# (-r -f / -f -r / -R -f / -f -R), long-flag spellings
# (--recursive --force / --force --recursive), mixed short/long
# (-r --force / --recursive -f), or a verbose flag folded in (-rfv/-Rfv/-frv).
# The fix adds 13 new deny entries covering those variants, plus matching
# describe_permission() case arms in scripts/atelier-permission-diff so the
# operator-facing permission diff renders a human description instead of
# falling through to "(no description)".
#
# This test asserts:
#   1. all 13 new deny entries are present in the source template
#      (asserted individually, so a failure names the missing pattern);
#   2. the two pre-existing entries are still present (regression guard —
#      additive-only fix);
#   3. the template is valid JSON;
#   4. each of the 13 patterns is reachable in atelier-permission-diff's
#      describe_permission() and renders a human-readable "BLOCKED:
#      recursive remove..." description — exercised via a REAL invocation
#      of the script (not a grep for literal text in its source), by
#      diffing a reconstructed pre-fix baseline (built with jq, not a line
#      grep, so it's robust to reformatting) against the real template.
#
# Hermetic: no network, no writes outside $TMP, no dependence on files
# outside the worktree. Requires jq (already a hard dependency of this
# repo's tests, and of atelier-permission-diff itself).
#
# Run:  hooks/tests/deny-rm-variants.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/settings.template.json"
PERM_DIFF="$REPO_ROOT/scripts/atelier-permission-diff"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "#199 rm -rf variant deny-list regression"

# The 13 new patterns (source form) and their expected human descriptions,
# as parallel indexed arrays (bash 3.2 on this box has no associative
# arrays, matching the convention of the rest of this suite).
NEW_PATTERNS=(
  "Bash(rm -Rf *)"
  "Bash(rm -fR *)"
  "Bash(rm -r -f *)"
  "Bash(rm -f -r *)"
  "Bash(rm -R -f *)"
  "Bash(rm -f -R *)"
  "Bash(rm --recursive --force *)"
  "Bash(rm --force --recursive *)"
  "Bash(rm -r --force *)"
  "Bash(rm --recursive -f *)"
  "Bash(rm -rfv *)"
  "Bash(rm -Rfv *)"
  "Bash(rm -frv *)"
)
NEW_DESCRIPTIONS=(
  "BLOCKED: recursive remove"
  "BLOCKED: recursive remove"
  "BLOCKED: recursive remove (separated flags)"
  "BLOCKED: recursive remove (separated flags)"
  "BLOCKED: recursive remove (separated flags)"
  "BLOCKED: recursive remove (separated flags)"
  "BLOCKED: recursive remove (long flags)"
  "BLOCKED: recursive remove (long flags)"
  "BLOCKED: recursive remove (mixed flags)"
  "BLOCKED: recursive remove (mixed flags)"
  "BLOCKED: recursive remove (verbose)"
  "BLOCKED: recursive remove (verbose)"
  "BLOCKED: recursive remove (verbose)"
)

PRE_EXISTING_PATTERNS=(
  "Bash(rm -rf *)"
  "Bash(rm -fr *)"
)

# =============================================================================
# Group 1 — static check: each of the 13 new deny entries is present in the
# source template's permissions.deny array. Asserted individually so a
# failure names exactly which pattern is missing.
# =============================================================================
deny_has_entry() {
  local file="$1" entry="$2"
  jq -e --arg want "$entry" '(.permissions.deny // []) | any(. == $want)' \
    "$file" >/dev/null 2>&1
}

for i in "${!NEW_PATTERNS[@]}"; do
  entry="${NEW_PATTERNS[$i]}"
  if deny_has_entry "$TEMPLATE" "$entry"; then
    pass "deny[] carries $entry"
  else
    fail "deny[] is missing $entry — rm -rf variant is not covered by the deny rule"
  fi
done

# =============================================================================
# Group 2 — regression guard: the two pre-existing entries must still be
# present. Additive-only fix, never a replacement.
# =============================================================================
for entry in "${PRE_EXISTING_PATTERNS[@]}"; do
  if deny_has_entry "$TEMPLATE" "$entry"; then
    pass "pre-existing deny entry untouched: $entry"
  else
    fail "pre-existing deny entry regressed/removed: $entry"
  fi
done

# =============================================================================
# Group 3 — templates/settings.template.json is valid JSON.
# =============================================================================
if jq . "$TEMPLATE" >/dev/null 2>&1; then
  pass "templates/settings.template.json is valid JSON"
else
  fail "templates/settings.template.json is not valid JSON"
fi

# =============================================================================
# Group 4 — real invocation: each of the 13 patterns is reachable in
# atelier-permission-diff's describe_permission() and renders a
# human-readable description, not a raw-glob "(no description)" fallback.
#
# Baseline is reconstructed with jq (removing exactly the 13 new entries
# from permissions.deny, nothing else) rather than a line-oriented grep, so
# the diff surfaced is deterministic and robust to reformatting of the
# template. Everything else (including the 2 pre-existing rm entries) is
# left untouched, so the ONLY category/added lines in the rendered diff are
# these 13 deny entries — giving a precise assertion surface.
# =============================================================================
[ -x "$PERM_DIFF" ] || fail "scripts/atelier-permission-diff is not executable"

REMOVE_JSON="$(printf '%s\n' "${NEW_PATTERNS[@]}" | jq -R . | jq -s .)"
BASELINE="$TMP/pre-fix-settings.template.json"
if jq --argjson remove "$REMOVE_JSON" \
     '.permissions.deny |= (map(select(. as $x | ($remove | index($x)) | not)))' \
     "$TEMPLATE" > "$BASELINE" 2>/dev/null \
   && jq . "$BASELINE" >/dev/null 2>&1; then
  pass "reconstructed pre-fix baseline built and is valid JSON"
else
  fail "failed to build reconstructed pre-fix baseline via jq"
fi

# Sanity: the baseline must NOT carry the 13 new entries (so the real diff
# below actually exercises them as additions).
baseline_clean=true
for entry in "${NEW_PATTERNS[@]}"; do
  if deny_has_entry "$BASELINE" "$entry"; then
    baseline_clean=false
    fail "reconstructed baseline unexpectedly still carries $entry — jq removal did not work"
  fi
done
$baseline_clean && pass "reconstructed baseline carries none of the 13 new entries (RED)"

DIFF_OUT="$("$PERM_DIFF" --old "$BASELINE" --new "$TEMPLATE" --no-color 2>&1)"
DIFF_RC=$?

# Exit code 1 means "changes detected" per the script's own contract — that
# IS the expected/successful outcome here, not a test failure.
if [ "$DIFF_RC" -eq 1 ]; then
  pass "atelier-permission-diff exits 1 (changes detected) for baseline vs. template"
else
  fail "atelier-permission-diff rc=$DIFF_RC (expected 1 — changes detected) (out: $DIFF_OUT)"
fi

for i in "${!NEW_PATTERNS[@]}"; do
  entry="${NEW_PATTERNS[$i]}"
  desc="${NEW_DESCRIPTIONS[$i]}"
  want_line="  + ${entry} → ${desc} [deny]"
  if printf '%s\n' "$DIFF_OUT" | grep -F -q "$want_line"; then
    pass "rendered diff describes $entry as \"$desc\""
  else
    fail "rendered diff does not carry the expected line for $entry (wanted: \"$want_line\")"
  fi
done

# Negative control on the render itself: none of the 13 new entries should
# fall through to the generic "(no description" fallback line.
for entry in "${NEW_PATTERNS[@]}"; do
  fallback_line="  + ${entry} → (no description"
  if printf '%s\n' "$DIFF_OUT" | grep -F -q "$fallback_line"; then
    fail "$entry falls through describe_permission() to the raw-glob fallback — missing case arm"
  else
    pass "$entry does not fall through to the raw-glob fallback"
  fi
done

echo ""
if [ "$fails" -eq 0 ]; then
  echo "#199 rm -rf variant deny-list regression: all assertions passed."
  exit 0
else
  echo "#199 rm -rf variant deny-list regression: $fails assertion(s) failed."
  exit 1
fi
