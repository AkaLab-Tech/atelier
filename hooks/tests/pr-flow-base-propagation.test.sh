#!/usr/bin/env bash
#
# Regression test for #413 — pr-flow propagates the task base branch, applies
# prSize.exempt, and closes the issue only on merge.
#
# Root cause: pr-flow / pr-author hard-coded `--base main` for the PR base and
# the size check, the orchestrator briefing did not carry the base resolved by
# `/atelier:next-task` step 1, the orchestrator's own fallback assumed
# "dev if it exists, else main", the reviewer's size check ran without
# `--project` (so `prSize.exempt` was ignored), and pr-author closed the issue
# / set Done when the PR opened instead of on merge.
#
# Asserted here (prose only; hermetic grep, no network):
#   - no `--base main` in pr-flow / pr-author; `--base <base>` in both
#     (including pr-author's `gh pr create`)
#   - next-task step 8 briefing and the orchestrator briefing contract name
#     `base`; the orchestrator no longer says "cut from updated `main`"
#   - the orchestrator's base fallback is the PR's `baseRefName`, then
#     `atelier-resolve-base`, failing closed; the dev-else-main rule is gone
#   - the reviewer's size-check invocation carries `--project`
#   - pr-author and pr-flow name `closingIssuesReferences` and
#     `missing-closing-reference`, and forbid closing the issue / setting Done
#     when the PR opens
#   - next-task's forward reference no longer tells pr-author to call
#     `appendHistoryEntry` (the token stays, attributed to auto-merge)
#   - auto-merge closes the non-`files` task after the merge (issue CLOSED
#     check, `Roadmap: manual follow-up needed`)
#
# The hooks/tests fixtures (agent-write-grants, diff-scope-check) legitimately
# contain `--base main` and are deliberately not scanned.
#
# Run:  hooks/tests/pr-flow-base-propagation.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PR_AUTHOR="$REPO_ROOT/agents/pr-author.md"
REVIEWER="$REPO_ROOT/agents/reviewer.md"
ORCH="$REPO_ROOT/agents/task-orchestrator.md"
NEXT_TASK="$REPO_ROOT/commands/next-task.md"
AUTOMERGE="$REPO_ROOT/skills/auto-merge/SKILL.md"
SKILL="$REPO_ROOT/skills/pr-flow/SKILL.md"

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
    fail "$label — token '$pattern' found but should be absent in $file"
  else
    pass "$label"
  fi
}

for f in "$PR_AUTHOR" "$REVIEWER" "$ORCH" "$NEXT_TASK" "$AUTOMERGE" "$SKILL"; do
  [ -r "$f" ] || { echo "FAIL: cannot read $f"; exit 1; }
done

# --- Group 1: no literal `--base main`; `--base <base>` everywhere ----------
chk_absent "$SKILL" '--base main' "pr-flow: no literal --base main"
chk_absent "$PR_AUTHOR" '--base main' "pr-author: no literal --base main"
chk_prose "$SKILL" '--base <base>' "pr-flow: --base <base> present"
chk_prose "$PR_AUTHOR" '--base <base>' "pr-author: --base <base> present"
chk_prose "$PR_AUTHOR" '`gh pr create --base <base>`' "pr-author: gh pr create carries --base <base>"
chk_prose "$SKILL" 'never a literal `main`' "pr-flow: base is never a literal main"
chk_prose "$PR_AUTHOR" 'never a literal `main`' "pr-author: base is never a literal main"

# --- Group 2: the briefing names `base` ------------------------------------
chk_prose "$NEXT_TASK" '- **`base: <base>`** — the base branch resolved in step 1' "next-task: step 8 briefing names base"
chk_prose "$ORCH" '`base` — the task base branch' "orchestrator: briefing contract names base"
chk_absent "$ORCH" 'cut from updated `main`' "orchestrator: no 'cut from updated main'"
chk_prose "$ORCH" 'cut from `origin/<base>`' "orchestrator: worktree is cut from origin/<base>"

# --- Group 3: orchestrator fallback = baseRefName, then resolve-base, fails closed
chk_prose "$ORCH" 'the PR'"'"'s `baseRefName`; else `atelier-resolve-base <project_root>`' "orchestrator: fallback is baseRefName then atelier-resolve-base"
chk_prose "$ORCH" 'fail closed: stop and surface the reason' "orchestrator: unresolved base fails closed"
chk_prose "$ORCH" 'Never fall back to `main` or probe for `dev`' "orchestrator: never falls back to main or probes dev"
chk_absent "$ORCH" 'dev if it exists, else main' "orchestrator: no 'dev if it exists, else main'"
chk_absent "$ORCH" 'dev` if' "orchestrator: no dev-if-exists-else-main rule"
chk_absent "$ORCH" 'ls-remote --heads origin dev' "orchestrator: no ls-remote --heads origin dev probe"

# --- Group 4: reviewer size check carries --project ------------------------
chk_prose "$REVIEWER" 'atelier-pr-size-check --pr <NN> --project <project-root>' "reviewer: size-check invocation carries --project"

# --- Group 5: closing reference + no early close ---------------------------
for pair in "pr-author:$PR_AUTHOR" "pr-flow:$SKILL"; do
  name="${pair%%:*}"; file="${pair#*:}"
  chk_prose "$file" 'closingIssuesReferences' "$name: names closingIssuesReferences"
  chk_prose "$file" 'missing-closing-reference' "$name: names missing-closing-reference"
  chk_prose "$file" 'gh issue close' "$name: mentions gh issue close (as forbidden)"
done
chk_prose "$PR_AUTHOR" '**Never** `gh issue close` and never set Done when the PR opens' "pr-author: forbids closing the issue / Done at PR open"
chk_prose "$SKILL" 'Opening the PR never closes the issue or sets Done' "pr-flow: opening the PR never closes the issue or sets Done"

# --- Group 6: appendHistoryEntry belongs to auto-merge ---------------------
chk_prose "$NEXT_TASK" '`pr-author` does not call `appendHistoryEntry`/`moveTask`' "next-task: pr-author does not call appendHistoryEntry"
chk_prose "$NEXT_TASK" 'in `auto-merge` post-merge step 2, which calls `appendHistoryEntry(id, prMetadata)`' "next-task: appendHistoryEntry attributed to auto-merge"
chk_absent "$NEXT_TASK" '`pr-author` must call `appendHistoryEntry' "next-task: no 'pr-author must call appendHistoryEntry'"

# --- Group 7: auto-merge closes non-files tasks after the merge ------------
chk_prose "$AUTOMERGE" 'check the issue is CLOSED (`gh issue view <id> --json state`)' "auto-merge: post-merge CLOSED check"
chk_prose "$AUTOMERGE" 'Roadmap: manual follow-up needed' "auto-merge: manual follow-up report when still open"
chk_prose "$AUTOMERGE" 'the close happens now, on merge, via `Closes #<id>`' "auto-merge: the close happens on merge"

if [ "$fails" -eq 0 ]; then
  echo "pr-flow-base-propagation (#413): all assertions passed."
  exit 0
fi
echo "pr-flow-base-propagation (#413): $fails assertion(s) failed."
exit 1
