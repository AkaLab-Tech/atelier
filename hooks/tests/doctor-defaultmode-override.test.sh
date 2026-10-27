#!/usr/bin/env bash
#
# Regression test for #635 / #402 — atelier-doctor check_project_defaultmode_override().
#
#   D1 no defaultMode key anywhere        -> OK, no fix
#   D2 settings.json defaultMode=auto     -> OK, no WARN, no fix
#   D3 settings.json acceptEdits          -> WARN naming file + mode, manual fix
#   D4 settings.local.json acceptEdits    -> WARN naming the local file
#   D5 invalid JSON project settings      -> ignored (OK, no WARN)
#   D6 no .claude dir at all              -> OK
#
# Hermetic: function extracted from scripts/atelier-doctor, push_* stubbed,
# fixtures in a scratch CLAUDE_PROJECT_DIR. No network.
#
# Run:  hooks/tests/doctor-defaultmode-override.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/atelier-doctor"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

export HOME="$TMP/home"; mkdir -p "$HOME"
export ATELIER_CONFIG_DIR="$TMP/cfg"

FN_FILE="$TMP/fns.sh"
awk '/^check_project_defaultmode_override\(\) \{/{f=1} f{print} f&&/^\}/{f=0}' "$DOCTOR" > "$FN_FILE"
grep -q 'check_project_defaultmode_override()' "$FN_FILE" || { echo "  FAIL: could not extract function from $DOCTOR"; exit 1; }
# shellcheck disable=SC1090
source "$FN_FILE"

HOST_OUT="$TMP/host_out"; MANUAL_OUT="$TMP/manual_out"
push_host()       { printf '%s\n' "$*" >> "$HOST_OUT"; }
push_fix_manual() { printf '%s\n' "$*" >> "$MANUAL_OUT"; }
export OK="OKMARK" WARN="WARNMARK" SKIP="SKIPMARK" FAIL="FAILMARK"

# scenario <name> <settings.json|NONE> <settings.local.json|NONE>
scenario() {
  rm -f "$HOST_OUT" "$MANUAL_OUT"; touch "$HOST_OUT" "$MANUAL_OUT"
  CLAUDE_PROJECT_DIR="$TMP/$1"; export CLAUDE_PROJECT_DIR
  mkdir -p "$CLAUDE_PROJECT_DIR"
  if [ "$2" != NONE ] || [ "$3" != NONE ]; then mkdir -p "$CLAUDE_PROJECT_DIR/.claude"; fi
  [ "$2" = NONE ] || printf '%s\n' "$2" > "$CLAUDE_PROJECT_DIR/.claude/settings.json"
  [ "$3" = NONE ] || printf '%s\n' "$3" > "$CLAUDE_PROJECT_DIR/.claude/settings.local.json"
  check_project_defaultmode_override
}

echo "atelier-doctor check_project_defaultmode_override (#635/#402)"

scenario d1 '{"permissions":{"allow":[]}}' NONE
if grep -q 'OKMARK no project/local defaultMode override' "$HOST_OUT" && ! grep -q WARNMARK "$HOST_OUT" && [ ! -s "$MANUAL_OUT" ]; then
  pass "D1 no key -> OK, no warning"; else fail "D1: $(cat "$HOST_OUT")"; fi

scenario d2 '{"permissions":{"defaultMode":"auto"}}' NONE
if grep -q 'OKMARK .*settings.json sets permissions.defaultMode = "auto"' "$HOST_OUT" && ! grep -q WARNMARK "$HOST_OUT" && [ ! -s "$MANUAL_OUT" ]; then
  pass "D2 auto -> OK, no warning"; else fail "D2: $(cat "$HOST_OUT")"; fi

scenario d3 '{"permissions":{"defaultMode":"acceptEdits"}}' NONE
if grep -q 'WARNMARK .*/d3/.claude/settings.json sets permissions.defaultMode = "acceptEdits"' "$HOST_OUT" && grep -q 'remove .permissions.defaultMode from .*/d3/.claude/settings.json' "$MANUAL_OUT"; then
  pass "D3 acceptEdits in settings.json -> WARN + manual fix"; else fail "D3: $(cat "$HOST_OUT") / $(cat "$MANUAL_OUT")"; fi

scenario d4 NONE '{"permissions":{"defaultMode":"acceptEdits"}}'
if grep -q 'WARNMARK .*/d4/.claude/settings.local.json sets permissions.defaultMode = "acceptEdits"' "$HOST_OUT" && [ "$(grep -c WARNMARK "$HOST_OUT")" = 1 ]; then
  pass "D4 acceptEdits in settings.local.json -> WARN"; else fail "D4: $(cat "$HOST_OUT")"; fi

scenario d5 '{not json' NONE
if grep -q 'OKMARK no project/local defaultMode override' "$HOST_OUT" && ! grep -q WARNMARK "$HOST_OUT"; then
  pass "D5 invalid JSON ignored"; else fail "D5: $(cat "$HOST_OUT")"; fi

scenario d6 NONE NONE
if grep -q 'OKMARK no project/local defaultMode override' "$HOST_OUT"; then
  pass "D6 no .claude dir -> OK"; else fail "D6: $(cat "$HOST_OUT")"; fi

[ "$fails" -eq 0 ] && { echo "All assertions passed."; exit 0; } || { echo "$fails assertion(s) failed."; exit 1; }
