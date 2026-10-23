#!/usr/bin/env bash
#
# Regression test for #604 — the settings template must deny the Read tool on
# .env* files (project root, task worktree, sibling task worktrees), and
# scripts/atelier-permission-diff must describe each of those entries in plain
# language instead of falling back to "(no description)".
#
# Hermetic: reads only templates/settings.template.json and runs
# scripts/atelier-permission-diff against fixture JSON in a temp dir. It never
# opens any .env* file.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/settings.template.json"
DIFF="$REPO_ROOT/scripts/atelier-permission-diff"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not found"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ENTRIES=(
  'Read(./.env*)'
  'Read(<worktree>/.env*)'
  'Read(<worktree>-worktrees/**/.env*)'
)

echo "Group 1 — template parses and denies Read on .env*"
if jq . "$TEMPLATE" >/dev/null 2>&1; then pass "template parses with jq"; else fail "template does not parse"; fi
for e in "${ENTRIES[@]}"; do
  if jq -e --arg e "$e" '.permissions.deny | index($e) != null' "$TEMPLATE" >/dev/null 2>&1; then
    pass "permissions.deny contains $e"
  else
    fail "permissions.deny is missing $e"
  fi
  if jq -e --arg e "$e" '(.permissions.allow // []) | index($e) == null' "$TEMPLATE" >/dev/null 2>&1; then
    pass "permissions.allow does not contain $e"
  else
    fail "permissions.allow wrongly contains $e"
  fi
done

echo "Group 2 — atelier-permission-diff describes each entry"
printf '{"permissions":{"deny":[]}}\n' > "$TMP/old.json"
for e in "${ENTRIES[@]}"; do
  jq -n --arg e "$e" '{permissions:{deny:[$e]}}' > "$TMP/new.json"
  out="$(bash "$DIFF" --old "$TMP/old.json" --new "$TMP/new.json" --no-color 2>&1)"
  rc=$?
  line="$(printf '%s\n' "$out" | grep -F -- "$e" || true)"
  if [ "$rc" -eq 1 ] && [ -n "$line" ]; then pass "diff reports $e (exit 1)"; else fail "diff did not report $e (rc=$rc)"; fi
  case "$line" in
    *"BLOCKED: read .env*"*) pass "$e has a plain-language BLOCKED description" ;;
    *) fail "$e has no specific description: $line" ;;
  esac
  case "$line" in
    *"(no description)"*) fail "$e fell back to generic description" ;;
    *) pass "$e is not described generically" ;;
  esac
done

echo
if [ "$fails" -eq 0 ]; then echo "All tests passed."; exit 0; fi
echo "$fails test(s) failed."; exit 1
