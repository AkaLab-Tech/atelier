#!/usr/bin/env bash
#
# Regression test for #590 — templates/settings.template.json pre-authorizes
# dispatching exactly two atelier agents and nothing else.
#
#   A1 the ^(Agent|Task)\( allow entries are exactly
#      Agent(atelier:task-orchestrator) and Agent(atelier:planner)
#   A2 no wildcard / bare-name Agent|Task entry in allow
#   A3 no Agent|Task entry in deny or ask
#   A4 atelier-permission-diff describes both entries (no "(no description")
#   A5 negative control: a third Agent entry is detected by the A1 check
#
# Hermetic: temp JSON files, no network.
#
# Run:  hooks/tests/settings-template-agent-dispatch-allow.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PD="$REPO_ROOT/scripts/atelier-permission-diff"
TEMPLATE="$REPO_ROOT/templates/settings.template.json"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "settings template Agent dispatch allow (#590)"

EXPECTED='["Agent(atelier:planner)","Agent(atelier:task-orchestrator)"]'
agent_allow() {
  jq -c '[.permissions.allow[] | select(test("^(Agent|Task)\\("))] | sort' "$1"
}

# A1
if [ "$(agent_allow "$TEMPLATE")" = "$EXPECTED" ]; then
  pass "A1 allow Agent|Task entries are exactly the two atelier agents"
else
  fail "A1 unexpected Agent|Task allow entries: $(agent_allow "$TEMPLATE")"
fi

# A2
if jq -e '[.permissions.allow[] | select(test("^(Agent|Task)\\(")) | select(test("\\*") or (test("atelier:") | not))] | length == 0' "$TEMPLATE" >/dev/null; then
  pass "A2 no wildcard or bare-name Agent|Task allow entry"
else
  fail "A2 wildcard or bare-name Agent|Task allow entry present"
fi

# A3
if jq -e '[(.permissions.deny // [])[], (.permissions.ask // [])[] | select(test("^(Agent|Task)\\("))] | length == 0' "$TEMPLATE" >/dev/null; then
  pass "A3 no Agent|Task entry in deny or ask"
else
  fail "A3 Agent|Task entry found in deny or ask"
fi

# A4
printf '{"permissions":{"allow":[]}}\n' > "$TMP/old.json"
OUT="$("$PD" --old "$TMP/old.json" --new "$TEMPLATE" --no-color 2>&1)"
for e in 'Agent(atelier:task-orchestrator)' 'Agent(atelier:planner)'; do
  line="$(printf '%s\n' "$OUT" | grep -F -- "$e" | head -1)"
  if [ -n "$line" ] && ! printf '%s' "$line" | grep -qF '(no description'; then
    pass "A4 permission-diff describes $e"
  else
    fail "A4 permission-diff missing/undescribed $e: $line"
  fi
done

# A5
jq '.permissions.allow += ["Agent(atelier:reviewer)"]' "$TEMPLATE" > "$TMP/third.json"
if [ "$(agent_allow "$TMP/third.json")" != "$EXPECTED" ]; then
  pass "A5 negative control: a third Agent entry fails the A1 check"
else
  fail "A5 negative control not detected"
fi

if [ "$fails" -eq 0 ]; then echo "OK"; exit 0; fi
echo "FAILED: $fails"; exit 1
