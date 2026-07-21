#!/usr/bin/env bash
#
# Regression test for task #129 — safe-commit.sh PreToolUse hook silently
# skipped by Claude Code's 60-second default hook timeout on slow projects.
#
# OBSERVABLE CONTRACT:
#   Claude Code's per-hook `timeout` field is measured in SECONDS (default 60
#   when absent). The §6 push gate that safe-commit.sh runs (lint + typecheck
#   + unit + integration) can legitimately take several minutes on a real
#   project, so hooks/hooks.json must pin an explicit, generous timeout on the
#   safe-commit.sh command object: `"timeout": 600` (600 SECONDS = 10 minutes).
#
#   The root cause of #129 was a ms-vs-seconds confusion: an earlier attempt
#   at this fix used 600000 (600000 "seconds" ~= 6.9 days, i.e. effectively no
#   timeout, but also the wrong number for the intended 10-minute budget and a
#   sign that the units were misunderstood). This test locks in the *correct*
#   value (600) and explicitly guards against the naive 600000 mistake
#   reappearing in a future edit.
#
# Run:  hooks/tests/safe-commit-timeout.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# --- dependency check --------------------------------------------------------
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

# --- fixture check -------------------------------------------------------
if [ ! -f "$HOOKS_JSON" ]; then
  fail "hooks/hooks.json not found at $HOOKS_JSON"
  echo ""
  echo "safe-commit-timeout (#129): $fails assertion(s) failed."
  exit 1
fi

# --- gather every PreToolUse command object whose command ends with
#     safe-commit.sh, across all matcher groups -------------------------------
SAFE_COMMIT_TIMEOUTS="$(jq -r '
  .hooks.PreToolUse[].hooks[]
  | select(.command | endswith("safe-commit.sh"))
  | .timeout
' "$HOOKS_JSON")"

SAFE_COMMIT_COUNT="$(printf '%s\n' "$SAFE_COMMIT_TIMEOUTS" | grep -c . || true)"

# --- (a) exactly one safe-commit.sh command object exists --------------------
if [ "$SAFE_COMMIT_COUNT" -eq 1 ]; then
  pass "(a) exactly one safe-commit.sh command object found in .hooks.PreToolUse"
else
  fail "(a) expected exactly one safe-commit.sh command object; found $SAFE_COMMIT_COUNT"
fi

TIMEOUT_VALUE="$(printf '%s\n' "$SAFE_COMMIT_TIMEOUTS" | head -n1)"

# --- (b) the timeout is present (not null) ------------------------------------
if [ "$TIMEOUT_VALUE" = "null" ] || [ -z "$TIMEOUT_VALUE" ]; then
  fail "(b) safe-commit.sh command object has no .timeout set (falls back to 60s default)"
else
  pass "(b) safe-commit.sh command object has a .timeout set (${TIMEOUT_VALUE})"
fi

# --- (c) the timeout is exactly the JSON number 600 (600 seconds = 10 min) ---
if jq -e '
  .hooks.PreToolUse[].hooks[]
  | select(.command | endswith("safe-commit.sh"))
  | .timeout == 600
' "$HOOKS_JSON" >/dev/null 2>&1; then
  pass "(c) safe-commit.sh .timeout == 600 (JSON number, seconds)"
else
  fail "(c) safe-commit.sh .timeout is not the JSON number 600; got '${TIMEOUT_VALUE}'"
fi

# --- (d) regression guard: must NOT be the ms-confused 600000 value ----------
if [ "$TIMEOUT_VALUE" = "600000" ]; then
  fail "(d) safe-commit.sh .timeout is 600000 — this is the ms-vs-seconds bug from #129 (600000s ~= 6.9 days, not the intended 10 minutes)"
else
  pass "(d) safe-commit.sh .timeout is not 600000 (ms-vs-seconds mistake not present)"
fi

# --- (e) other Bash-matcher PreToolUse hooks intentionally stay on the
#         default (no timeout override to 600) --------------------------------
OTHER_600_COUNT="$(jq -r '
  [ .hooks.PreToolUse[].hooks[]
    | select((.command | endswith("safe-commit.sh")) | not)
    | select(.timeout == 600)
  ] | length
' "$HOOKS_JSON")"

if [ "$OTHER_600_COUNT" -eq 0 ]; then
  pass "(e) no other PreToolUse command object carries the 600s timeout"
else
  fail "(e) expected 0 non-safe-commit command objects with .timeout == 600; found $OTHER_600_COUNT"
fi

echo ""
if [ "$fails" -eq 0 ]; then
  echo "safe-commit-timeout (#129): all assertions passed."
  exit 0
else
  echo "safe-commit-timeout (#129): $fails assertion(s) failed."
  exit 1
fi
