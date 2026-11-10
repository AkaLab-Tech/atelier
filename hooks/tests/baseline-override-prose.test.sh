#!/usr/bin/env bash
# Prose test for #749 (#744 part 4): the signed baseline override wording is present across
# the orchestrator, next/resume-task, the broker catalog + skill, safe-commit, /validate,
# troubleshooting (every reason the hook can emit) and PLAN.md.
# Exit: 0 = all passed, 1 = at least one failed.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILN=0
ok() { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAILN=$((FAILN+1)); echo "  FAIL: $1"; }
has() { # file pattern label  (extended regex)
  if grep -qE -- "$2" "$ROOT/$1"; then ok "$3"; else bad "$3"; fi
}
hasf() { # file fixed-string label
  if grep -qF -- "$2" "$ROOT/$1"; then ok "$3"; else bad "$3"; fi
}

hasf agents/task-orchestrator.md 'atelier-baseline-override --worktree <wt>' "orchestrator calls the override helper"
hasf agents/task-orchestrator.md 'held: baseline override needs operator confirmation (<N> tests)' "orchestrator held line"
for f in commands/next-task.md commands/resume-task.md; do
  hasf "$f" 'held: baseline override needs operator confirmation' "$f carries the held-line prefix"
done

cat_file="$ROOT/agents/decision-broker/catalog.json"
when="$(jq -r '.["baseline-conflict"].options[] | select(.id=="override") | .when' "$cat_file" 2>/dev/null)" \
  || when="$(jq -r '.. | objects | select(has("baseline-conflict")) | .["baseline-conflict"].options[] | select(.id=="override") | .when' "$cat_file")"
case "$when" in *"signed selector confirmation"*) ok "catalog override.when: signed selector confirmation" ;; *) bad "catalog override.when: signed selector confirmation" ;; esac
case "$when" in *"unattended runs hold"*) ok "catalog override.when: unattended runs hold" ;; *) bad "catalog override.when: unattended runs hold" ;; esac
if jq -e '.. | objects | select(has("baseline-conflict")) | .["baseline-conflict"].deterministicRule' "$cat_file" >/dev/null 2>&1; then
  ok "catalog baseline-conflict deterministicRule present"; else bad "catalog baseline-conflict deterministicRule present"; fi

# shellcheck disable=SC2016  # backticks are literal pattern text
has skills/decision-broker/SKILL.md 'waives `/validate` only' "broker skill: override waives /validate only"
has skills/decision-broker/SKILL.md 'never a commit-time grant' "broker skill: decisions.jsonl never a commit-time grant"

has skills/safe-commit/SKILL.md '^## Approved baseline override' "safe-commit: section heading"
hasf skills/safe-commit/SKILL.md 'all covered by signed baseline override captured_at=' "safe-commit: test-red-waived decision text"
hasf skills/safe-commit/SKILL.md 'jest and vitest only' "safe-commit: jest/vitest only"
hasf skills/safe-commit/SKILL.md 'Lint and typecheck are never waived' "safe-commit: lint and typecheck never waived"

has commands/validate.md '^### Waived baseline set' "validate: section heading"
has commands/validate.md 'commit still needs the operator' "validate: a commit needs the signed record"
has commands/validate.md 'signed' "validate: mentions signed record"

# Every reason the hook can emit must be documented in troubleshooting.
reasons="$(grep -oE 'bo_reason="[a-z-]+"' "$ROOT/hooks/safe-commit.sh" | sed -E 's/bo_reason="(.*)"/\1/' | sort -u)"
if [ -n "$reasons" ]; then ok "hook exposes bo_reason values ($(echo "$reasons" | wc -w | tr -d ' '))"; else bad "hook exposes bo_reason values"; fi
for r in $reasons; do
  hasf docs/troubleshooting.md "\`$r\`" "troubleshooting documents reason $r"
done
hasf docs/troubleshooting.md 'Baseline override: not applied — <reason>' "troubleshooting names the hook line"

has PLAN.md 'signed baseline override' "PLAN.md push gate mentions the signed baseline override"
# shellcheck disable=SC2016  # backticks are literal pattern text
{
  hasf PLAN.md 'waives `/validate` only and never grants a commit' "PLAN: override waives /validate only, never grants a commit"
  hasf PLAN.md 'jest/vitest only, never lint or typecheck' "PLAN: jest/vitest only, lint and typecheck never waived"
  hasf agents/task-orchestrator.md 'only the helper'"'"'s `override=valid`' "orchestrator: only override=valid unblocks a commit-bearing dispatch"
  hasf agents/task-orchestrator.md 'as permission to commit' "orchestrator: decisions.jsonl override never permission to commit"
  hasf agents/task-orchestrator.md 'rule:host-only' "orchestrator: mentions rule:host-only"
  hasf skills/decision-broker/SKILL.md 'including `auto`) waives `/validate` only' "broker skill: auto override waives /validate only"
  hasf skills/decision-broker/SKILL.md 'unattended runs hold' "broker skill: unattended runs hold"
  hasf skills/decision-broker/SKILL.md "operator's signed selector answer in the main session" "broker skill: commit needs main-session selector answer"
  hasf skills/safe-commit/SKILL.md 'Unattended runs hold.' "safe-commit: unattended runs hold"
  hasf skills/safe-commit/SKILL.md 'main-session selector answer' "safe-commit: record comes from main-session selector answer"
  hasf skills/safe-commit/SKILL.md '`decisions.jsonl` alone never grants it' "safe-commit: decisions.jsonl never grants"
  hasf commands/validate.md 'The waiver covers `/validate` only' "validate: waiver covers /validate only"
  hasf commands/validate.md '`auto`, or `rule:host-only`' "validate: any mode incl. auto and rule:host-only"
  hasf commands/validate.md 'main-session selector answer' "validate: record from main-session selector answer"
  hasf commands/validate.md '`decisions.jsonl` never grants it' "validate: decisions.jsonl never grants"
  hasf commands/validate.md 'Lint and typecheck are never waived, and v1 covers jest and vitest only' "validate: lint/typecheck never waived, jest and vitest only"
  hasf docs/operator-guide.md 'only waives those tests during `/validate`' "operator guide: override waives /validate only"
  hasf docs/operator-guide.md 'even an automatic one' "operator guide: automatic override included"
  hasf docs/operator-guide.md 'Unattended runs stop and wait for you' "operator guide: unattended runs hold"
  hasf docs/operator-guide.md 'jest and vitest tests only; lint and typecheck are never waived' "operator guide: jest/vitest only, lint/typecheck never waived"
  hasf docs/troubleshooting.md 'only waives `/validate`' "troubleshooting: override waives /validate only"
  hasf docs/troubleshooting.md 'Unattended runs hold with `held: baseline override needs operator confirmation (<N> tests)`' "troubleshooting: unattended hold line"
  hasf docs/troubleshooting.md 'Lint and typecheck are never waived.' "troubleshooting: lint/typecheck never waived"
  hasf docs/troubleshooting.md 'Reason: `$pm run test` failed with exit N' "troubleshooting quotes the hook Reason line"
}
# The quoted hook output is the real one.
# shellcheck disable=SC2016  # $vars are literal text in the hook source
hasf hooks/safe-commit.sh '"test-red-waived"' "hook logs the test-red-waived decision"
# shellcheck disable=SC2016
hasf hooks/safe-commit.sh 'Baseline override: not applied — $bo_reason' "hook prints the Baseline override line"
# shellcheck disable=SC2016
hasf hooks/safe-commit.sh 'failed with exit $exit_code' "hook prints the failed-with-exit Reason"

# Follow-up pins: the exact clauses added to each doc.
hasf skills/decision-broker/SKILL.md 'v1 covers jest and vitest only, and lint and typecheck are never waived' "broker skill: jest/vitest only, lint/typecheck never waived"
hasf docs/operator-guide.md 'never grants a commit' "operator guide: decisions.jsonl never grants a commit"
hasf PLAN.md "the commit needs the operator's main-session selector answer, and unattended runs hold" "PLAN push gate: main-session selector answer, unattended runs hold"
hasf agents/task-orchestrator.md 'unattended runs hold, and v1 covers jest and vitest only' "orchestrator: unattended runs hold, jest/vitest only"
hasf commands/validate.md 'and unattended runs hold' "validate: and unattended runs hold"
# shellcheck disable=SC2016
hasf skills/safe-commit/SKILL.md 'waives `/validate` only' "safe-commit: waives /validate only"

echo
echo "Results: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
