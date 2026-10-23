#!/usr/bin/env bash
# Prose test for #545: the protected-paths approval (guardrail 4) wording is present in the
# shellcheck disable=SC2016
# auto-merge skill, babysit-prs and the policy docs, and the two operator approvals never cross.
# Exit: 0 = all passed, 1 = at least one failed.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAILN=0
has() { # file pattern label
  if grep -qE -- "$2" "$ROOT/$1"; then PASS=$((PASS+1)); echo "  PASS: $3"; else FAILN=$((FAILN+1)); echo "  FAIL: $3"; fi
}
for f in skills/auto-merge/SKILL.md commands/babysit-prs.md; do
  has "$f" 'atelier-size-waiver --kind protected-paths <owner/repo> <NN>' "$f: guardrail 4 calls --kind protected-paths"
  has "$f" 'atelier-size-waiver --package-json-version-only <owner/repo> <NN>' "$f: guardrail 4 calls the version-only check"
  has "$f" 'package-json=version-only' "$f: version-only result removes package.json"
  has "$f" 'package-json=changed' "$f: changed result keeps package.json"
  has "$f" '[Ll]ockfile, Dockerfile, compose' "$f: lockfile/Dockerfile/compose/workflow never exempt"
  has "$f" 'ambiguous' "$f: ambiguous result grants nothing"
done
has skills/auto-merge/SKILL.md 'any lockfile, Dockerfile, compose or workflow change, still needs approval' "skill: lockfile stays a forbidden path"
has skills/auto-merge/SKILL.md 'pnpm-lock' "skill: pnpm-lock still in the forbidden-path patterns"
has commands/babysit-prs.md 'pnpm-lock' "babysit-prs: pnpm-lock still in the forbidden-path patterns"
has skills/auto-merge/SKILL.md 'fail closed' "skill: version-only check fails closed"
has skills/auto-merge/SKILL.md 'Never\*\* let a size waiver satisfy guardrail #4, or a protected-paths approval satisfy guardrail #5' "skill: approvals never cross (refusal)"
has skills/auto-merge/SKILL.md 'never cross' "skill: 'never cross' wording"
has skills/auto-merge/SKILL.md 'Protected-paths-approval:' "skill: merge body audit line"
has skills/auto-merge/SKILL.md 'protected-paths-approval' "skill: decisions.jsonl kind"
has skills/auto-merge/SKILL.md 'approve protected paths' "skill: approval trigger phrase"
has skills/auto-merge/SKILL.md 'apruebo archivos protegidos' "skill: Spanish approval phrase"
has skills/auto-merge/SKILL.md '`--match-head-commit`' "skill: merge pinned to the approved sha"
has commands/babysit-prs.md 'APPROVED by @' "babysit-prs: APPROVED by @ row note"
has commands/babysit-prs.md 'forbidden files without a valid operator approval' "babysit-prs: forbidden without approval stays terminal"
for f in PLAN.md operator-rules.md CLAUDE.md; do
  has "$f" 'protected-paths approval' "$f carries the protected-paths approval wording"
  has "$f" 'never satisfies the size guardrail' "$f: approval never satisfies the size guardrail"
  has "$f" 'a size waiver never satisfies this one' "$f: size waiver never satisfies guardrail 4"
done
has PLAN.md 'changes only the top-level `"version"` value' "PLAN.md: version-only exemption"
has operator-rules.md 'changes only the top-level `"version"` value' "operator-rules.md: version-only exemption"
has PLAN.md 'any lockfile change, still does' "PLAN.md: lockfile change still needs approval"
has operator-rules.md 'any lockfile change, still does' "operator-rules.md: lockfile change still needs approval"
echo
echo "Results: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
