#!/usr/bin/env bash
#
# Regression test for #376 — an empty statusCheckRollup must hold the merge
# when the repo has CI workflows (or required checks, or that cannot be
# determined), instead of being treated as a vacuous pass.
#
#   Group 1 — skills/auto-merge/SKILL.md
#     - workflows probe via `git ls-tree` on origin/<baseRefName>
#     - hold: `held: CI not reported yet`; fail closed on unknown/error
#     - vacuous pass only when both probes say "none", with the report line
#   Group 2 — commands/babysit-prs.md
#     - `baseRefName` fetched in the step-3 gh pr list --json field list
#     - `waiting (CI not reported yet)` / `re-poll suggested` / `no CI configured`
#   Group 3 — agents/task-orchestrator.md
#     - empty rollup is pending until maxWaitSeconds, then
#       `held: CI not reported after <maxWaitSeconds>s`
#     - Never-bypass rule: empty rollup is pending, not green
#   Group 4 — PLAN.md §6 "never vacuously satisfied" sentence
#   Group 5 — regression guard: old pass-on-empty phrasing is gone
#
# Hermetic: assertions run against committed files only (grep -F, portable
# across BSD and GNU grep) — no network, no temp files.
#
# Run:  hooks/tests/auto-merge-empty-rollup.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

# Literal grep -F patterns legitimately contain backticks; nothing should expand.
# shellcheck disable=SC2016
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$REPO_ROOT/skills/auto-merge/SKILL.md"
CMD="$REPO_ROOT/commands/babysit-prs.md"
ORCH="$REPO_ROOT/agents/task-orchestrator.md"
PLAN="$REPO_ROOT/PLAN.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_prose <file> <fixed-string> <label> — passes when the string is present.
chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF -- "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

# chk_absent <file> <fixed-string> <label> — passes when the string is absent.
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF -- "$pattern" "$file" 2>/dev/null; then
    fail "$label — stale token '$pattern' still present in $file"
  else
    pass "$label"
  fi
}

for f in "$SKILL" "$CMD" "$ORCH" "$PLAN"; do
  if [ ! -f "$f" ]; then
    fail "file exists: $f"
  fi
done

echo "Group 1 — skills/auto-merge/SKILL.md"
chk_prose "$SKILL" 'atelier-ci-coverage . <baseRefName>' \
  "SKILL: coverage probe uses atelier-ci-coverage on <baseRefName>"
chk_prose "$SKILL" 'held: CI not reported yet' \
  "SKILL: holds with 'held: CI not reported yet'"
chk_prose "$SKILL" 'a git error, a missing helper or unparseable output is also `unknown`' \
  "SKILL: coverage probe fails closed on git error"
chk_prose "$SKILL" 'the answer is "unknown" — never assume "none"' \
  "SKILL: required-checks probe unknown is never 'none'"
chk_prose "$SKILL" 'or the required-checks probe could not be determined → **hold**' \
  "SKILL: hold when either probe could not be determined"
chk_prose "$SKILL" 'Coverage `none` and no required checks (no workflow files and no required checks) → guardrail 3 **passes vacuously**' \
  "SKILL: vacuous pass only when no workflow files and no required checks"
chk_prose "$SKILL" 'CI: no checks configured (no .github/workflows on <base>, no required checks): guardrail 3 passes vacuously' \
  "SKILL: explicit vacuous-pass report line"

echo "Group 2 — commands/babysit-prs.md"
chk_prose "$CMD" 'headRefName,baseRefName,isDraft' \
  "babysit-prs: baseRefName in the step-3 gh pr list --json field list"
chk_prose "$CMD" 'waiting (CI not reported yet)' \
  "babysit-prs: 'waiting (CI not reported yet)' disposition"
chk_prose "$CMD" 're-poll suggested' \
  "babysit-prs: 're-poll suggested' verdict"
chk_prose "$CMD" 'no CI configured' \
  "babysit-prs: 'no CI configured' note for the both-negative case"
chk_prose "$CMD" 'atelier-ci-coverage . <baseRefName>' \
  "babysit-prs: coverage probe uses atelier-ci-coverage on <baseRefName>"
chk_prose "$CMD" 'a missing helper or unparseable output counts as `unknown`' \
  "babysit-prs: coverage probe error fails closed"

echo "Group 3 — agents/task-orchestrator.md"
chk_prose "$ORCH" 'an empty rollup is **pending**, not green' \
  "orchestrator: empty rollup is pending on a CI repo"
chk_prose "$ORCH" 'if `ciWait.maxWaitSeconds` runs out first, return `held: CI not reported after <maxWaitSeconds>s`' \
  "orchestrator: held after maxWaitSeconds with an empty rollup"
chk_prose "$ORCH" 'An empty `statusCheckRollup` is pending, not green, on any repo with workflows or required checks' \
  "orchestrator: Never-bypass rule clause (empty rollup pending, not green)"
chk_prose "$ORCH" '| `held: CI not reported after <maxWaitSeconds>s` |' \
  "orchestrator: held status listed in the report Status vocabulary"
chk_prose "$ORCH" 'Only when coverage is `none` or `uncovered` **and** there are no required checks' \
  "orchestrator: one-settle only when no CI will report"

echo "Group 4 — PLAN.md §6"
chk_prose "$PLAN" '"CI green" is never satisfied by an empty `statusCheckRollup` on a repo with workflows or required status checks' \
  "PLAN §6: CI green never vacuously satisfied by an empty rollup"
chk_prose "$PLAN" 'held: CI not reported yet' \
  "PLAN §6: names the 'held: CI not reported yet' hold"

echo "Group 5 — regression guard: old pass-on-empty wording is gone"
chk_absent "$SKILL" 'If the array is empty (no checks configured), the skill treats it as **pass**' \
  "SKILL: no 'empty array treated as pass'"
chk_absent "$CMD" 'or array is empty → guardrail passes' \
  "babysit-prs: no 'or array is empty → guardrail passes'"
chk_absent "$CMD" 'array is empty → guardrail passes' \
  "babysit-prs: no 'array is empty → guardrail passes' (any position)"
chk_absent "$ORCH" 'If the array is empty, wait a 15 s settle window' \
  "orchestrator: no unconditional empty-array settle-then-proceed"

echo "Group 6 — #497: uncovered base (outcome ii) and the autoMerge.uncoveredBaseCi opt-out"
INSTALL="$REPO_ROOT/install.sh"
TEMPLATE="$REPO_ROOT/templates/atelier.template.json"
chk_prose "$SKILL" 'Coverage `uncovered` and no required checks' \
  "SKILL: outcome (ii) names uncovered + no required checks"
chk_prose "$SKILL" 'CI: no workflow runs on PRs to <base> (<reason>), no required checks: guardrail 3 passes (no CI will report)' \
  "SKILL: outcome (ii) report line"
chk_prose "$SKILL" 'autoMerge.uncoveredBaseCi' \
  "SKILL: names the autoMerge.uncoveredBaseCi opt-out"
chk_prose "$SKILL" 'held: no CI runs on PRs to <base> — human merge required' \
  "SKILL: opt-out terminal hold"
chk_prose "$CMD" 'Coverage `uncovered` and no required checks' \
  "babysit-prs: outcome (ii) names uncovered + no required checks"
chk_prose "$CMD" 'no CI for base <baseRefName>' \
  "babysit-prs: outcome (ii) per-PR note"
chk_prose "$CMD" 'autoMerge.uncoveredBaseCi' \
  "babysit-prs: names the autoMerge.uncoveredBaseCi opt-out"
chk_prose "$CMD" 'held — no CI for base <baseRefName> (human merge required)' \
  "babysit-prs: opt-out terminal disposition"
chk_prose "$ORCH" 'no workflow runs on PRs to <base>' \
  "orchestrator: outcome (ii) report note"
chk_prose "$ORCH" 'autoMerge.uncoveredBaseCi' \
  "orchestrator: names the autoMerge.uncoveredBaseCi opt-out"
chk_prose "$ORCH" 'held: no CI runs on PRs to <base> — human merge required' \
  "orchestrator: opt-out terminal hold"
chk_prose "$TEMPLATE" '"uncoveredBaseCi": "pass"' \
  "template: autoMerge.uncoveredBaseCi defaults to pass"
chk_prose "$INSTALL" '_phase_c_1_symlink_helper atelier-ci-coverage' \
  "install.sh: registers the atelier-ci-coverage helper"
if [ -x "$REPO_ROOT/scripts/atelier-ci-coverage" ]; then
  pass "scripts/atelier-ci-coverage is executable"
else
  fail "scripts/atelier-ci-coverage missing or not executable"
fi

echo "Group 7 — #497 guard: the bare 'Non-empty output → the repo has CI' rule is gone"
for f in "$SKILL" "$CMD" "$ORCH"; do
  chk_absent "$f" 'Non-empty output → the repo has CI' \
    "$(basename "$f"): no bare 'Non-empty output → the repo has CI'"
  chk_absent "$f" 'git ls-tree -d --name-only origin/<baseRefName> .github/workflows' \
    "$(basename "$f"): no directory-presence ls-tree probe"
done

if [ "$fails" -eq 0 ]; then
  echo "All assertions passed."
  exit 0
fi
echo "$fails assertion(s) failed."
exit 1
