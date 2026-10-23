#!/usr/bin/env bash
# Prose test for #543: the size-waiver wording is present in the auto-merge skill,
# babysit-prs, the orchestrator and the policy docs.
# Exit: 0 = all passed, 1 = at least one failed.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILN=0
has() { # file pattern label
  if grep -qE -- "$2" "$ROOT/$1"; then PASS=$((PASS+1)); echo "  PASS: $3"; else FAILN=$((FAILN+1)); echo "  FAIL: $3"; fi
}
has skills/auto-merge/SKILL.md 'atelier-size-waiver <owner/repo> <NN>' "skill calls the resolver"
has skills/auto-merge/SKILL.md 'never waivable' "skill: exit 2 non-waivable"
has skills/auto-merge/SKILL.md 'Size-waiver:' "skill: merge body audit line"
has skills/auto-merge/SKILL.md 'WAIVED by @' "skill: report line"
has skills/auto-merge/SKILL.md 'decisions\.jsonl' "skill: decisions.jsonl entry"
has commands/babysit-prs.md 'Bash\(atelier-size-waiver:\*\)' "babysit-prs allows the helper"
has commands/babysit-prs.md 'atelier-size-waiver <owner/repo> <NN>' "babysit-prs calls the resolver"
has commands/babysit-prs.md 'never waivable' "babysit-prs: exit 2 non-waivable"
has skills/auto-merge/SKILL.md 'On exit 1 only' "skill: resolver called on size-check exit 1 only"
has skills/auto-merge/SKILL.md 'do not call `atelier-size-waiver` on exit 2' "skill: resolver not called on exit 2"
has skills/auto-merge/SKILL.md 'only\*\* when the result is `valid` \*\*and\*\* its `sha` equals the sha recorded in guardrail #2' "skill: passes only on valid + pinned sha"
has skills/auto-merge/SKILL.md '`--match-head-commit`' "skill: merge pinned with --match-head-commit"
has skills/auto-merge/SKILL.md 'a sha mismatch' "skill: sha mismatch keeps the PR held"
has skills/auto-merge/SKILL.md 'held: PR exceeds size budget' "skill: held message without a valid waiver"
has skills/auto-merge/SKILL.md 'add how to waive' "skill: how-to-waive guidance"
has skills/auto-merge/SKILL.md 'waive size' "skill: waiver review trigger phrase"
has skills/auto-merge/SKILL.md '\.task-log/decisions\.jsonl' "skill: decisions.jsonl under the worktree task-log"
has commands/babysit-prs.md 'Exit 1 .* run `atelier-size-waiver' "babysit-prs: resolver on exit 1"
has commands/babysit-prs.md '`sha` equal to the PR.s current head sha' "babysit-prs: valid requires current head sha"
has commands/babysit-prs.md 'WAIVED by @' "babysit-prs: WAIVED by @ row note"
has commands/babysit-prs.md 'held . OVERSIZE' "babysit-prs: otherwise held - OVERSIZE"
has commands/babysit-prs.md 'waive size' "babysit-prs: how-to-waive guidance"
has commands/babysit-prs.md 'OVERSIZE without a valid operator waiver' "babysit-prs: oversize without waiver stays terminal"
has agents/task-orchestrator.md 'size waiver' "orchestrator names the waiver"
for f in PLAN.md operator-rules.md CLAUDE.md; do
  has "$f" 'size waiver' "$f carries the waiver wording"
  has "$f" 'never waivable' "$f: size-check error never waivable"
done
echo
echo "Results: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
