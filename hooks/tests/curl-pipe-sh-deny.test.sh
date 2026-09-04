#!/usr/bin/env bash
#
# Regression test for #198 — broaden the curl/wget-pipe-to-shell deny
# entries in templates/settings.template.json.
#
# Pre-fix, the deny list only covered four literal, space-delimited forms:
#   Bash(curl * | sh*)
#   Bash(curl * | bash*)
#   Bash(wget * | sh*)
#   Bash(wget * | bash*)
# Claude Code's Bash permission globs match the command string verbatim
# modulo the trailing `*` wildcard, so any whitespace variation around the
# pipe (or piping into e.g. `zsh`/`ksh`/a full path to a shell) slipped
# straight past the deny rule. The fix replaces those four narrow entries
# with four broadened globs that match regardless of spacing and cover
# both the pipe form and process-substitution form:
#   Bash(curl*|*sh*)
#   Bash(wget*|*sh*)
#   Bash(*<(curl*)
#   Bash(*<(wget*)
#
# This test pins:
#   1. the shipped template's deny[] contains exactly those four broadened
#      entries as its complete curl/wget-related deny set (guards against a
#      future partial revert reintroducing a narrower form alongside, or
#      silently dropping one of the four);
#   2. none of the four old narrow spaced forms are present anywhere in
#      deny[] (guards against the old form being left in place, or
#      resurrected, alongside the new one);
#   3. templates/settings.template.json is valid JSON.
#
# Runtime permission-engine matching (i.e. actually invoking Claude Code's
# glob matcher against sample commands) is not exercised here — that
# requires the live Claude Code permission engine and cannot be driven
# hermetically. This is a known, accepted limitation; only entry-presence
# in the template is asserted.
#
# Hermetic: no network, no writes outside a throwaway $TMP, no dependence
# on operator machine state. Resolves templates/settings.template.json
# relative to this test file's own location. Requires jq (already a hard
# dependency of this repo's tests).
#
# Run:  hooks/tests/curl-pipe-sh-deny.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/settings.template.json"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "#198 regression — broadened curl/wget-pipe-to-shell deny entries"

# =============================================================================
# Group 1 — valid JSON.
# =============================================================================
if jq . "$TEMPLATE" >/dev/null 2>&1; then
  pass "templates/settings.template.json is valid JSON"
else
  fail "templates/settings.template.json is NOT valid JSON"
fi

# =============================================================================
# Group 2 — the four broadened entries are present in deny[].
# =============================================================================
broadened_entries=(
  'Bash(curl*|*sh*)'
  'Bash(wget*|*sh*)'
  'Bash(*<(curl*)'
  'Bash(*<(wget*)'
)

for entry in "${broadened_entries[@]}"; do
  if jq -e --arg want "$entry" '(.permissions.deny // []) | any(. == $want)' \
       "$TEMPLATE" >/dev/null 2>&1; then
    pass "deny[] contains broadened entry: $entry"
  else
    fail "deny[] is missing broadened entry: $entry"
  fi
done

# =============================================================================
# Group 3 — none of the four old narrow spaced forms remain.
# =============================================================================
narrow_entries=(
  'Bash(curl * | sh*)'
  'Bash(curl * | bash*)'
  'Bash(wget * | sh*)'
  'Bash(wget * | bash*)'
)

for entry in "${narrow_entries[@]}"; do
  if jq -e --arg stale "$entry" '(.permissions.deny // []) | any(. == $stale)' \
       "$TEMPLATE" >/dev/null 2>&1; then
    fail "deny[] still contains stale narrow entry: $entry (should have been replaced)"
  else
    pass "deny[] correctly omits stale narrow entry: $entry"
  fi
done

# =============================================================================
# Group 4 — the broadened set is *exactly* the curl/wget-related deny
# entries: no extra curl/wget entries beyond the four expected ones (guards
# against a future partial revert that reintroduces a fifth/duplicate
# variant alongside the correct four).
# =============================================================================
actual_curl_wget_entries="$(jq -r '(.permissions.deny // [])[] | select(test("curl|wget"))' "$TEMPLATE" 2>/dev/null | sort)"
expected_curl_wget_entries="$(printf '%s\n' "${broadened_entries[@]}" | sort)"

if [ "$actual_curl_wget_entries" = "$expected_curl_wget_entries" ]; then
  pass "deny[] curl/wget entries are exactly the four broadened forms (no extras, no omissions)"
else
  fail "deny[] curl/wget entries do not exactly match the expected four broadened forms
    expected:
$(printf '%s\n' "$expected_curl_wget_entries" | sed 's/^/      /')
    actual:
$(printf '%s\n' "$actual_curl_wget_entries" | sed 's/^/      /')"
fi

# =============================================================================
# Group 5 — negative control: a reconstructed pre-fix baseline (the real
# template with the four broadened entries swapped back for the four old
# narrow ones) must fail the "exact set" predicate above. This is the
# RED/GREEN pin proving Group 4 is not vacuous.
# =============================================================================
BASELINE="$TMP/pre-fix-settings.template.json"
python3 - "$TEMPLATE" "$BASELINE" <<'PY'
import json, sys

src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    data = json.load(f)

broadened_to_narrow = {
    "Bash(curl*|*sh*)": ["Bash(curl * | sh*)", "Bash(curl * | bash*)"],
    "Bash(wget*|*sh*)": ["Bash(wget * | sh*)", "Bash(wget * | bash*)"],
}
drop = {"Bash(*<(curl*)", "Bash(*<(wget*)"}

deny = data["permissions"]["deny"]
new_deny = []
for entry in deny:
    if entry in broadened_to_narrow:
        new_deny.extend(broadened_to_narrow[entry])
    elif entry in drop:
        continue
    else:
        new_deny.append(entry)
data["permissions"]["deny"] = new_deny

with open(dst, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY

if [ -f "$BASELINE" ]; then
  pass "reconstructed pre-fix baseline written"
else
  fail "failed to write reconstructed pre-fix baseline"
fi

baseline_curl_wget_entries="$(jq -r '(.permissions.deny // [])[] | select(test("curl|wget"))' "$BASELINE" 2>/dev/null | sort)"

if [ "$baseline_curl_wget_entries" != "$expected_curl_wget_entries" ]; then
  pass "negative control: reconstructed pre-fix baseline correctly fails the exact-set predicate (RED)"
else
  fail "negative control is broken: reconstructed pre-fix baseline unexpectedly matches the exact-set predicate — the assertion is not discriminating"
fi

jq . "$BASELINE" >/dev/null 2>&1 \
  && pass "reconstructed pre-fix baseline is still valid JSON" \
  || fail "reconstructed pre-fix baseline is not valid JSON"

# Sanity: reconstructing and discarding the baseline must never touch the
# real worktree file.
if diff -q "$TEMPLATE" "$REPO_ROOT/templates/settings.template.json" >/dev/null 2>&1; then
  pass "worktree templates/settings.template.json untouched by baseline reconstruction"
else
  fail "worktree templates/settings.template.json was unexpectedly modified"
fi

echo ""
if [ "$fails" -eq 0 ]; then
  echo "#198 curl/wget deny broadening regression: all assertions passed."
  exit 0
else
  echo "#198 curl/wget deny broadening regression: $fails assertion(s) failed."
  exit 1
fi
