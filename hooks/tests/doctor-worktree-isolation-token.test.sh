#!/usr/bin/env bash
#
# Regression test for #196a review finding 3 — atelier-doctor's
# check_worktree_isolation_token() surfaces which session-token source
# hooks/block-cross-worktree-edit.sh would resolve for the CURRENT
# session, so the silent degrade to a per-subagent-unstable token is never
# invisible to the operator.
#
# COVERAGE
#   T1: CLAUDE_CODE_BRIDGE_SESSION_ID set   → OK line, no fix registered
#   T2: CLAUDE_CODE_BRIDGE_SESSION_ID unset → FAIL line naming the weaker
#       fallback, one manual fix registered
#
# Hermetic: the check function is extracted from scripts/atelier-doctor and
# run with push_* stubs. No network, no real $HOME/.claude-work.
#
# Run:  hooks/tests/doctor-worktree-isolation-token.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/atelier-doctor"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

FN_FILE="$TMP/fns.sh"
awk '/^check_worktree_isolation_token\(\) \{/{f=1} f{print} f&&/^\}/{f=0}' \
  "$DOCTOR" > "$FN_FILE"
if ! grep -q 'check_worktree_isolation_token()' "$FN_FILE"; then
  echo "  FAIL: could not extract check_worktree_isolation_token() from $DOCTOR"
  exit 1
fi
# shellcheck disable=SC1090
source "$FN_FILE"

HOST_OUT="$TMP/host_out"
FIX_OUT="$TMP/fix_out"
push_host()       { printf '%s\n' "$*" >> "$HOST_OUT"; }
push_fix_manual() { printf '%s\n' "$*" >> "$FIX_OUT"; }
OK="✓"; FAIL="✗"
reset_capture() { rm -f "$HOST_OUT" "$FIX_OUT"; }

echo "#196a doctor regression — check_worktree_isolation_token"

# T1: bridge env set → strong token source, OK, no fix.
reset_capture
CLAUDE_CODE_BRIDGE_SESSION_ID="test-bridge-token" check_worktree_isolation_token
if grep -qF "$OK" "$HOST_OUT" 2>/dev/null && grep -q "CLAUDE_CODE_BRIDGE_SESSION_ID set" "$HOST_OUT"; then
  pass "bridge env set → OK line reported"
else
  fail "expected an OK line mentioning the bridge env being set, got: $(cat "$HOST_OUT" 2>/dev/null)"
fi
[ ! -s "$FIX_OUT" ] && pass "bridge env set → no fix registered" \
                     || fail "unexpected fix registered when bridge env is set: $(cat "$FIX_OUT")"

# T2: bridge env unset → weak fallback, FAIL, one manual fix.
reset_capture
(
  unset CLAUDE_CODE_BRIDGE_SESSION_ID
  check_worktree_isolation_token
)
if grep -qF "$FAIL" "$HOST_OUT" 2>/dev/null && grep -q "session_id" "$HOST_OUT"; then
  pass "bridge env unset → FAIL line naming the session_id fallback"
else
  fail "expected a FAIL line naming the session_id fallback, got: $(cat "$HOST_OUT" 2>/dev/null)"
fi
[ -s "$FIX_OUT" ] && pass "bridge env unset → a fix is registered (visibility, not auto-remediable)" \
                   || fail "expected a manual fix to be registered when the bridge env is unset"

# T3: the check is genuinely read-only — it must never touch
# $ATELIER_CONFIG_DIR/state (or create it) in either mode, since it only
# inspects an env var. Run both modes against a fresh, otherwise-untouched
# config dir and assert nothing was created under it.
reset_capture
FRESH_ATELIER_CFG="$TMP/fresh-atelier-cfg"
mkdir -p "$FRESH_ATELIER_CFG"
(
  ATELIER_CONFIG_DIR="$FRESH_ATELIER_CFG" CLAUDE_CODE_BRIDGE_SESSION_ID="test-bridge-token" check_worktree_isolation_token
)
(
  unset CLAUDE_CODE_BRIDGE_SESSION_ID
  ATELIER_CONFIG_DIR="$FRESH_ATELIER_CFG" check_worktree_isolation_token
)
if [ -z "$(ls -A "$FRESH_ATELIER_CFG" 2>/dev/null)" ]; then
  pass "check_worktree_isolation_token never creates or mutates state under \$ATELIER_CONFIG_DIR (read-only, in either mode)"
else
  fail "expected \$ATELIER_CONFIG_DIR to remain empty after both check modes, found: $(ls -A "$FRESH_ATELIER_CFG" 2>/dev/null)"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "All #196a doctor-worktree-isolation-token regression checks passed."
  exit 0
else
  echo "$fails #196a doctor-worktree-isolation-token regression check(s) FAILED."
  exit 1
fi
