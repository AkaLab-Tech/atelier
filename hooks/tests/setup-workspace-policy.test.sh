#!/usr/bin/env bash
#
# Regression test for the workspace-wide decision-policy flag
# (`atelier-setup-workspace --policy`). The helper sets decisionPolicy.default
# in EVERY member's .atelier.json from one command, instead of per-repo
# /atelier:set-policy. This test drives apply_member_policy() directly.
#
# Hermetic: extracts apply_member_policy() from scripts/atelier-setup-workspace
# and runs it against throwaway .atelier.json files. Requires jq (an install.sh
# Phase-A dep and what the helper itself needs).
#
# Run:  hooks/tests/setup-workspace-policy.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-setup-workspace"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# --- extract the function under test ---------------------------------------
FN="$TMP/apply_member_policy.sh"
awk '/^apply_member_policy\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SCRIPT" > "$FN"
if ! grep -q 'decisionPolicy' "$FN"; then
  echo "  FAIL: could not extract apply_member_policy() from $SCRIPT"; exit 1
fi
# shellcheck disable=SC1090
source "$FN"

# --- case 1: sets default and PRESERVES _comment + byCategory --------------
F1="$TMP/a.json"
cat > "$F1" <<'JSON'
{
  "decisionPolicy": {
    "_comment": "keep me",
    "default": "ask",
    "byCategory": { "scope-creep-detected": "auto" }
  },
  "prSize": { "maxLines": 200 }
}
JSON
if apply_member_policy "$F1" "auto"; then pass "apply returned success"; else fail "apply returned failure"; fi
[ "$(jq -r '.decisionPolicy.default' "$F1")" = "auto" ] \
  && pass "default flipped to auto" || fail "default not flipped"
[ "$(jq -r '.decisionPolicy._comment' "$F1")" = "keep me" ] \
  && pass "_comment preserved" || fail "_comment lost"
[ "$(jq -r '.decisionPolicy.byCategory["scope-creep-detected"]' "$F1")" = "auto" ] \
  && pass "byCategory preserved" || fail "byCategory lost"
[ "$(jq -r '.prSize.maxLines' "$F1")" = "200" ] \
  && pass "unrelated keys preserved" || fail "unrelated keys lost"

# --- case 2: no decisionPolicy block yet -> creates it ---------------------
F2="$TMP/b.json"; echo '{"prSize":{"maxFiles":10}}' > "$F2"
apply_member_policy "$F2" "ask" && pass "apply on file without decisionPolicy" || fail "apply failed (no-block file)"
[ "$(jq -r '.decisionPolicy.default' "$F2")" = "ask" ] \
  && pass "decisionPolicy created with default" || fail "decisionPolicy not created"
[ "$(jq -r '.prSize.maxFiles' "$F2")" = "10" ] \
  && pass "no-block: unrelated keys preserved" || fail "no-block: unrelated keys lost"

# --- case 3: missing file -> non-zero --------------------------------------
if apply_member_policy "$TMP/does-not-exist.json" "auto"; then fail "missing file should fail"; else pass "missing file returns non-zero"; fi

# --- case 4: invalid JSON -> non-zero, file untouched ----------------------
F4="$TMP/bad.json"; printf 'not json{' > "$F4"
if apply_member_policy "$F4" "auto"; then fail "invalid JSON should fail"; else pass "invalid JSON returns non-zero"; fi
[ "$(cat "$F4")" = 'not json{' ] && pass "invalid JSON left untouched" || fail "invalid JSON was clobbered"

# --- result -----------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "workspace --policy apply_member_policy: all assertions passed."
  exit 0
else
  echo "workspace --policy apply_member_policy: $fails assertion(s) failed."
  exit 1
fi
