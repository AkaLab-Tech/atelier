#!/usr/bin/env bash
#
# Regression test for #635 — hooks/mode-drift-nudge.sh.
#
#   M1 auto in registered project            -> silent
#   M2 acceptEdits in registered project     -> one notice, then silent on repeat
#   M3 acceptEdits in unregistered dir       -> silent
#   M4 mode changes between prompts          -> notice naming both modes
#   M5 worktree of a registered project      -> counts as registered
#   M6 no permission_mode in input           -> silent (fail-open)
#
# Run:  hooks/tests/mode-drift-nudge.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/mode-drift-nudge.sh"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

export ATELIER_CONFIG_DIR="$TMP/cfg"; mkdir -p "$ATELIER_CONFIG_DIR"
PROJ="$TMP/proj"
jq -n --arg p "$PROJ" '{projects: {($p): {name: "proj"}}}' > "$ATELIER_CONFIG_DIR/projects.json"

run() { # sid mode cwd
  jq -n --arg s "$1" --arg m "$2" --arg c "$3" \
    '{hook_event_name: "UserPromptSubmit", session_id: $s, permission_mode: $m, cwd: $c}' \
    | bash "$HOOK"
}

out="$(run s1 auto "$PROJ")"
[ -z "$out" ] && pass "M1 auto -> silent" || fail "M1 auto emitted: $out"

out="$(run s2 acceptEdits "$PROJ")"
if printf '%s' "$out" | jq -e '.systemMessage | contains("acceptEdits")' >/dev/null 2>&1; then
  pass "M2 acceptEdits -> notice"
else fail "M2 no notice: $out"; fi
out="$(run s2 acceptEdits "$PROJ")"
[ -z "$out" ] && pass "M2 repeat prompt -> silent" || fail "M2 repeat emitted: $out"

out="$(run s3 acceptEdits "$TMP/elsewhere")"
[ -z "$out" ] && pass "M3 unregistered dir -> silent" || fail "M3 emitted: $out"

run s4 auto "$PROJ" >/dev/null
out="$(run s4 plan "$PROJ")"
if printf '%s' "$out" | jq -e '.systemMessage | contains("\"auto\"") and contains("\"plan\"")' >/dev/null 2>&1; then
  pass "M4 mode change -> notice"
else fail "M4 no change notice: $out"; fi

out="$(run s5 acceptEdits "$PROJ-worktrees/task-1-x")"
[ -n "$out" ] && pass "M5 worktree counts as registered" || fail "M5 silent in worktree"

out="$(jq -n --arg c "$PROJ" '{session_id: "s6", cwd: $c}' | bash "$HOOK")"
[ -z "$out" ] && pass "M6 no permission_mode -> silent" || fail "M6 emitted: $out"

[ "$fails" -eq 0 ] && { echo "mode-drift-nudge: all passed"; exit 0; }
echo "mode-drift-nudge: $fails failed"; exit 1
