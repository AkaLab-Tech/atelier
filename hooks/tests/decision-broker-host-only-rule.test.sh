#!/usr/bin/env bash
#
# Regression test for #533 — decision-broker's deterministic `host-only` rule
# for `baseline-conflict`: when the failures are red locally but the base sha's
# CI is green, the skill returns `override` via `atelier-base-ci` without
# dispatching a broker agent. Asserts the committed prose/JSON wiring:
#   - SKILL Step 3.5 names the helper, `rule:host-only`, `evidence`, and the
#     auto-only scope (never overrides fixed ids / ask / panic)
#   - the precedence summary still ranks the fixed byCategory id above the rule
#   - catalog.json parses, `override` still exists, default stays `fix-first`
#   - the orchestrator names the waived set and the identifier requirement
#   - install.sh registers the helper, the template allows it, it is executable
#
# Hermetic: greps committed files; jq only for JSON.
#
# Run:  hooks/tests/decision-broker-host-only-rule.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$REPO_ROOT/skills/decision-broker/SKILL.md"
CATALOG="$REPO_ROOT/agents/decision-broker/catalog.json"
ORCH="$REPO_ROOT/agents/task-orchestrator.md"
INSTALL="$REPO_ROOT/install.sh"
TEMPLATE="$REPO_ROOT/templates/settings.template.json"
HELPER="$REPO_ROOT/scripts/atelier-base-ci"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

chk_prose() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3 — token '$2' not found in $1"; fi
}
chk_section() {
  if printf '%s' "$1" | grep -qF -- "$2"; then pass "$3"; else fail "$3 — token '$2' not found in section"; fi
}

for f in "$SKILL" "$CATALOG" "$ORCH" "$INSTALL" "$TEMPLATE"; do
  [ -f "$f" ] || { echo "  FAIL: $f not found"; exit 1; }
done

# --- SKILL Step 3.5 ------------------------------------------------------------
STEP35="$(awk '
  /^### Step 3\.5 / { capture=1; print; next }
  capture && /^##/ { exit }
  capture { print }
' "$SKILL")"
if [ -n "$STEP35" ]; then pass "Step 3.5 section extracted"; else fail "Step 3.5 section missing"; fi

chk_section "$STEP35" 'atelier-base-ci' "Step 3.5 names atelier-base-ci"
chk_section "$STEP35" 'rule:host-only' "Step 3.5 names rule:host-only"
chk_section "$STEP35" 'evidence' "Step 3.5 mentions evidence"
chk_section "$STEP35" 'choice: override' "Step 3.5 returns override"
chk_section "$STEP35" 'base_ci=green' "Step 3.5 requires base_ci=green"
chk_section "$STEP35" 'the resolved policy is `auto`' "Step 3.5 scope: only when resolved policy is auto"
chk_section "$STEP35" 'non-empty set of failing identifiers' "Step 3.5 requires failing identifiers"
chk_section "$STEP35" 'not reasons to deviate' "Step 3.5: pending/none/unknown do not deviate"

# --- precedence summary --------------------------------------------------------
chk_prose "$SKILL" 'sits below all of these' "precedence: rule sits below the existing levels"
chk_prose "$SKILL" 'never overrides a fixed id, `ask`, `ATELIER_ASK_FOR` or panic' \
  "precedence: rule never overrides fixed id / ask / ATELIER_ASK_FOR / panic"
fixed_ln="$(grep -nF '`decisionPolicy.byCategory.<category>` in `.atelier.json` (this step)' "$SKILL" | head -1 | cut -d: -f1)"
rule_ln="$(grep -nF 'The deterministic pre-check (Step 3.5) sits below' "$SKILL" | head -1 | cut -d: -f1)"
if [ -n "$fixed_ln" ] && [ -n "$rule_ln" ] && [ "$fixed_ln" -lt "$rule_ln" ]; then
  pass "precedence: byCategory item (line $fixed_ln) precedes the rule note (line $rule_ln)"
else
  fail "precedence: byCategory item ($fixed_ln) not above rule note ($rule_ln)"
fi

# --- Step 5 log ----------------------------------------------------------------
chk_prose "$SKILL" 'rule:host-only |' "Step 5: source enum includes rule:host-only"
chk_prose "$SKILL" '"evidence": {' "Step 5: evidence object in the log line"
chk_prose "$SKILL" '"waived"' "Step 5: evidence carries waived"

# --- catalog -------------------------------------------------------------------
if jq -e . "$CATALOG" >/dev/null 2>&1; then pass "catalog.json parses with jq"; else fail "catalog.json invalid JSON"; fi
if jq -e '.categories["baseline-conflict"].options[] | select(.id=="override")' "$CATALOG" >/dev/null 2>&1 \
   || jq -e '[.. | objects | select(.id? == "override")] | length > 0' "$CATALOG" >/dev/null 2>&1; then
  pass "catalog: override option still exists"
else
  fail "catalog: override option missing"
fi
if jq -e '[.. | objects | select(has("deterministicRule"))][0].default == "fix-first"' "$CATALOG" >/dev/null 2>&1; then
  pass "catalog: baseline-conflict default stays fix-first"
else
  fail "catalog: baseline-conflict default is not fix-first"
fi
if jq -e '[.. | objects | select(has("deterministicRule"))][0].deterministicRule | contains("override")' "$CATALOG" >/dev/null 2>&1; then
  pass "catalog: deterministicRule maps to override"
else
  fail "catalog: deterministicRule missing/incorrect"
fi

# --- orchestrator --------------------------------------------------------------
chk_prose "$ORCH" 'waived set' "orchestrator names the waived set"
chk_prose "$ORCH" 'exact failing test/check identifiers' "orchestrator requires the exact failing identifiers"
chk_prose "$ORCH" 'host-only rule does not apply' "orchestrator: no identifiers -> rule does not apply"

# --- install.sh / template / executable ----------------------------------------
chk_prose "$INSTALL" '_phase_c_1_symlink_helper atelier-base-ci' "install.sh symlinks atelier-base-ci"
chk_prose "$TEMPLATE" '"Bash(atelier-base-ci:*)"' "settings template allows atelier-base-ci"
if jq -e . "$TEMPLATE" >/dev/null 2>&1; then pass "settings template parses with jq"; else fail "settings template invalid JSON"; fi
if [ -x "$HELPER" ]; then pass "scripts/atelier-base-ci is executable"; else fail "scripts/atelier-base-ci not executable"; fi

echo ""
if [ "$fails" -eq 0 ]; then
  echo "decision-broker-host-only-rule (#533): all assertions passed."
  exit 0
else
  echo "decision-broker-host-only-rule (#533): $fails assertion(s) failed."
  exit 1
fi
