#!/usr/bin/env bash
#
# Regression test for #451 — a gate/browser run denied by the sandbox or the
# auto-mode classifier must stop cleanly instead of looping.
#
# Root cause pattern this guards against: implementer/tester/e2e-runner had no
# declared path for a denied browser gate run, so they retried the bypass
# (`dangerouslyDisableSandbox`), burned the retry-with-logs budget, and the
# parent session could not run the command for them without routing around the
# denial. The fix: (a) the permission template declares the gate commands
# (env-prefixed shapes + a scoped autoMode.allow entry); (b) every specialist
# returns `needs-operator-permission` with Command/Denial/Worktree on the first
# denial; (c) task-orchestrator treats it as a terminal held state outside the
# retry budget; (d) operator-rules.md states the never-bypass / never-relay rule.
#
# Hermetic: greps committed prose and jq-parses the committed template; no
# network, no temp dirs.
#
# Run:  hooks/tests/gate-run-permission-denial.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMPL="$REPO_ROOT/agents/implementer.md"
TESTER="$REPO_ROOT/agents/tester.md"
E2E="$REPO_ROOT/agents/e2e-runner.md"
VV="$REPO_ROOT/skills/visual-validation/SKILL.md"
ORCH="$REPO_ROOT/agents/task-orchestrator.md"
RULES="$REPO_ROOT/operator-rules.md"
TEMPLATE="$REPO_ROOT/templates/settings.template.json"
AUTOMODE="$REPO_ROOT/templates/automode.user.json"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF -- "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

chk_section() {
  local section="$1" pattern="$2" label="$3"
  if printf '%s' "$section" | grep -qF -- "$pattern"; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in extracted section"
  fi
}

for f in "$IMPL" "$TESTER" "$E2E" "$VV" "$ORCH" "$RULES" "$TEMPLATE" "$AUTOMODE"; do
  [ -f "$f" ] || { echo "  FAIL: $f not found"; exit 1; }
done

# ---------------------------------------------------------------------------
# Specialists: never-bypass rule + status with Command / Denial / Worktree
# ---------------------------------------------------------------------------
for f in "$IMPL" "$TESTER" "$E2E"; do
  n="$(basename "$f")"
  chk_prose "$f" 'Never** set `dangerouslyDisableSandbox`' "$n: never sets dangerouslyDisableSandbox"
  chk_prose "$f" 'stop on the first sandbox or auto-mode classifier denial' "$n: stops on first denial"
  chk_prose "$f" 'no handing the command to the parent or another session' "$n: no relaying the denied command"
  chk_prose "$f" '`Command:`' "$n: status carries Command"
  chk_prose "$f" '`Denial:`' "$n: status carries Denial"
  chk_prose "$f" '`Worktree:`' "$n: status carries Worktree"
done

chk_prose "$IMPL" 'Next: needs-operator-permission' "implementer: Next status token"
chk_prose "$TESTER" 'Final state: needs-operator-permission' "tester: Final state status token"
chk_prose "$TESTER" 'is **not** a test failure, a code bug or a flake' "tester: step 5 says a denial is not a test failure"
chk_prose "$E2E" 'NEEDS-OPERATOR-PERMISSION' "e2e-runner: Suite result status token"
chk_prose "$VV" 'NEEDS-OPERATOR-PERMISSION' "visual-validation: step 3 denied-run status"
chk_prose "$VV" 'never set `dangerouslyDisableSandbox`' "visual-validation: step 3 never-bypass rule"
chk_prose "$IMPL" 'project defines its own browser test command' "implementer: step 6 covers project-defined browser test command"

# ---------------------------------------------------------------------------
# task-orchestrator: step 7 exclusion, step 8 held bullet, Output, Decision rule
# ---------------------------------------------------------------------------
STEP7="$(awk '/^7\. \*\*Enforce the retry budget/ {print; exit}' "$ORCH")"
STEP8="$(grep -F 'When `implementer`, `tester` or `e2e-runner` returned `needs-operator-permission`' "$ORCH")"
[ -n "$STEP7" ] && pass "orchestrator: step 7 extracted" || fail "orchestrator: step 7 extraction empty"
[ -n "$STEP8" ] && pass "orchestrator: step 8 held bullet extracted" || fail "orchestrator: step 8 held bullet extraction empty"

chk_section "$STEP7" 'is never passed to `retry-with-logs`' "orchestrator: step 7 excludes needs-operator-permission from retry-with-logs"
chk_section "$STEP7" 'does not use up the budget' "orchestrator: step 7 does not spend the budget"
chk_section "$STEP8" '**terminal held state**' "orchestrator: step 8 terminal held state"
chk_section "$STEP8" 'held: needs operator permission — <step> gate run denied (<tag>): <command>' "orchestrator: step 8 held string"
chk_section "$STEP8" 'do **not** invoke `unblocker`' "orchestrator: step 8 no unblocker"
chk_section "$STEP8" 'never forwarded to another session' "orchestrator: step 8 authorization never forwarded"

OUT_LINES="$(grep -F -- '- Status: ' "$ORCH")"
n_out="$(printf '%s\n' "$OUT_LINES" | grep -cF 'held: needs operator permission')"
[ "$n_out" -ge 2 ] && pass "orchestrator: both Status vocabularies (task and non-task) list the held string" \
  || fail "orchestrator: expected the held string in both Status vocabularies, found $n_out"

chk_prose "$ORCH" 'Never** re-dispatch a specialist with the same command after `needs-operator-permission`' "orchestrator: Decision rule — no same-command re-dispatch"
chk_prose "$ORCH" 'never brief another session with it' "orchestrator: Decision rule — no relaying"

# ---------------------------------------------------------------------------
# operator-rules.md subsection
# ---------------------------------------------------------------------------
RULES_SEC="$(awk '
  /^### Gate runs and sandbox\/classifier denials/ { capture=1; next }
  capture && /^##+ / { exit }
  capture { print }
' "$RULES")"
[ -n "$RULES_SEC" ] && pass "operator-rules: subsection extracted" || fail "operator-rules: subsection extraction empty"
chk_section "$RULES_SEC" 'Never request `dangerouslyDisableSandbox` for a gate command' "operator-rules: never-bypass rule"
chk_section "$RULES_SEC" 'A denial is terminal for that step' "operator-rules: denial is terminal"
chk_section "$RULES_SEC" 'needs-operator-permission' "operator-rules: names the status"
chk_section "$RULES_SEC" 'plan session only *informs* the operator' "operator-rules: plan session only informs"
chk_section "$RULES_SEC" 'no session' "operator-rules: no session forwards the authorization"
chk_section "$RULES_SEC" '`autoMode`' "operator-rules: states the autoMode project-scope limitation"

# ---------------------------------------------------------------------------
# templates/automode.user.json (user level, #456): scoped autoMode.allow;
# settings.template.json: env-prefixed permissions.allow shapes, no autoMode
# ---------------------------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  if jq -e '(.autoMode.allow | type == "array" and length >= 1)' "$AUTOMODE" >/dev/null 2>&1; then
    pass "automode.user.json: autoMode.allow exists"
  else
    fail "automode.user.json: autoMode.allow missing or empty"
  fi
  if jq -e '[.autoMode.allow[] | select(contains("atelier task worktree") and contains("-worktrees/") and contains("registered project"))] | length >= 1' "$AUTOMODE" >/dev/null 2>&1; then
    pass "automode.user.json: autoMode.allow entry is scoped to an atelier task worktree / registered project root"
  else
    fail "automode.user.json: no autoMode.allow entry scoped to an atelier task worktree / registered project root"
  fi
  if jq -e '[.autoMode.allow[] | select(contains("PW_CHROME_CHANNEL=chrome") and contains("CI=1"))] | length >= 1' "$AUTOMODE" >/dev/null 2>&1; then
    pass "automode.user.json: autoMode.allow entry covers the literal PW_CHROME_CHANNEL / CI env prefixes"
  else
    fail "automode.user.json: autoMode.allow entry does not mention the literal PW_CHROME_CHANNEL / CI env prefixes"
  fi
  if jq -e '[.autoMode.allow[] | select(test("Never with dangerouslyDisableSandbox"))] | length >= 1' "$AUTOMODE" >/dev/null 2>&1; then
    pass "automode.user.json: autoMode.allow entry excludes dangerouslyDisableSandbox"
  else
    fail "automode.user.json: autoMode.allow entry does not exclude dangerouslyDisableSandbox"
  fi
  if jq -e '[.autoMode.allow[] | select(test("(?<!Never with )dangerouslyDisableSandbox") and (test("Never with dangerouslyDisableSandbox")|not))] | length == 0' "$AUTOMODE" >/dev/null 2>&1; then
    pass "automode.user.json: no autoMode.allow entry grants dangerouslyDisableSandbox"
  else
    fail "automode.user.json: an autoMode.allow entry mentions dangerouslyDisableSandbox without excluding it"
  fi
  if jq -e '.autoMode.allow[0] | startswith("[atelier-managed:gate-runs] ")' "$AUTOMODE" >/dev/null 2>&1; then
    pass "automode.user.json: entry starts with the [atelier-managed:gate-runs] marker"
  else
    fail "automode.user.json: entry lacks the [atelier-managed:gate-runs] marker"
  fi
  # #456: Claude Code ignores autoMode in project settings, so the project template must not carry one.
  if jq -e 'has("autoMode") | not' "$TEMPLATE" >/dev/null 2>&1; then
    pass "template: settings.template.json has no autoMode block (user-level only, #456)"
  else
    fail "template: settings.template.json still carries an autoMode block"
  fi
  if jq -e '.permissions.allow | (length == (unique | length))' "$TEMPLATE" >/dev/null 2>&1; then
    pass "template: permissions.allow has no duplicate entries"
  else
    fail "template: permissions.allow has duplicates: $(jq -c '.permissions.allow | group_by(.) | map(select(length > 1) | .[0])' "$TEMPLATE")"
  fi
  if jq -e '[.permissions.allow[] | select(test("^Bash\\((PW_CHROME_CHANNEL=chrome|CI=1|CI=true) .* \\*\\)$"))] | length == 0' "$TEMPLATE" >/dev/null 2>&1; then
    pass "template: no env-prefixed allow entry ends in ' *)' (bare '*' only)"
  else
    fail "template: an env-prefixed allow entry ends in ' *)': $(jq -c '[.permissions.allow[] | select(test("^Bash\\((PW_CHROME_CHANNEL=chrome|CI=1|CI=true) .* \\*\\)$"))]' "$TEMPLATE")"
  fi
  if jq -e '[.permissions.allow[] | select(test("^Bash\\((PW_CHROME_CHANNEL=chrome|CI=1|CI=true) "))] | length == 12' "$TEMPLATE" >/dev/null 2>&1; then
    pass "template: exactly 12 env-prefixed gate-run shapes (3 prefixes x 4 commands)"
  else
    fail "template: expected 12 env-prefixed shapes, got $(jq '[.permissions.allow[] | select(test("^Bash\\((PW_CHROME_CHANNEL=chrome|CI=1|CI=true) "))] | length' "$TEMPLATE")"
  fi
  for shape in 'Bash(PW_CHROME_CHANNEL=chrome pnpm exec vitest*)' 'Bash(PW_CHROME_CHANNEL=chrome pnpm exec playwright test*)' 'Bash(PW_CHROME_CHANNEL=chrome pnpm test*)' 'Bash(PW_CHROME_CHANNEL=chrome pnpm run test*)' 'Bash(CI=1 pnpm exec vitest*)' 'Bash(CI=1 pnpm exec playwright test*)' 'Bash(CI=1 pnpm test*)' 'Bash(CI=1 pnpm run test*)' 'Bash(CI=true pnpm exec vitest*)' 'Bash(CI=true pnpm exec playwright test*)' 'Bash(CI=true pnpm test*)' 'Bash(CI=true pnpm run test*)'; do
    if jq -e --arg s "$shape" '.permissions.allow | index($s) != null' "$TEMPLATE" >/dev/null 2>&1; then
      pass "template: permissions.allow carries '$shape'"
    else
      fail "template: permissions.allow missing '$shape'"
    fi
  done
  # A trailing ':*' equals ' *' and needs a space, so 'pnpm run test:*' would not match 'pnpm run test:storybook'.
  if jq -e '[.permissions.allow[] | select(test("pnpm run test:\\*"))] | length == 0' "$TEMPLATE" >/dev/null 2>&1; then
    pass "template: no 'pnpm run test:*' (colon-star) allow shape"
  else
    fail "template: a permissions.allow entry uses the 'pnpm run test:*' colon-star shape (does not match 'pnpm run test:storybook')"
  fi
  if jq -e '[.permissions.allow[] | select(test("=\\* +pnpm "))] | length == 0' "$TEMPLATE" >/dev/null 2>&1; then
    pass "template: no env-prefixed pnpm allow entry has a wildcard env-assignment value"
  else
    fail "template: a permissions.allow entry has a '=*' wildcard env-assignment value"
  fi
  if jq -e '[.permissions.allow[] | select(test("^Bash\\([^ ]*=[^ ]* +pnpm ")) | select(test("^Bash\\((PW_CHROME_CHANNEL=chrome|CI=1|CI=true) pnpm ")|not)] | length == 0' "$TEMPLATE" >/dev/null 2>&1; then
    pass "template: env-prefixed allow entries use only the literal PW_CHROME_CHANNEL=chrome / CI=1 / CI=true prefixes"
  else
    fail "template: an env-prefixed allow entry uses a prefix other than the literal three"
  fi
  if jq -e '[.permissions.allow[] | select(test("^Bash\\([^ ]*\\*[^ ]* +pnpm "))] | length == 0' "$TEMPLATE" >/dev/null 2>&1; then
    pass "template: no wildcard before the pnpm command token"
  else
    fail "template: a permissions.allow entry has a wildcard before the pnpm command token"
  fi
  if jq -e '[.permissions.allow[] | select(test("NODE_OPTIONS|dangerouslyDisableSandbox"))] | length == 0' "$TEMPLATE" >/dev/null 2>&1; then
    pass "template: permissions.allow has no NODE_OPTIONS / dangerouslyDisableSandbox shape"
  else
    fail "template: permissions.allow carries a NODE_OPTIONS or dangerouslyDisableSandbox shape"
  fi
else
  echo "  SKIP: jq not available — template assertions not run"
fi

echo ""
if [ "$fails" -eq 0 ]; then
  echo "gate-run-permission-denial (#451): all assertions passed."
  exit 0
else
  echo "gate-run-permission-denial (#451): $fails assertion(s) failed."
  exit 1
fi
