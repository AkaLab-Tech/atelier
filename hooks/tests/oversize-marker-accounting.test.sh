#!/usr/bin/env bash
#
# Regression test for #30 — the [OVERSIZE] marker is actually accountable.
#
# Root cause (three chained defects in pr-author's OVERSIZE path):
#   1. The size gate was step 5 — AFTER step 3's `IN_PROGRESS → HISTORY`
#      tracking move, whose own verification asserts `IN_PROGRESS.md` no
#      longer contains the `#<id>` heading. So "mark the task's entry in
#      IN_PROGRESS.md" was an internally impossible instruction: by the time
#      the gate ran there was no active entry left to mark. The agent
#      improvised.
#   2. The marker commit was created AFTER step 4's push, so it never
#      reached origin.
#   3. The marker lived only on `task/<id>-<slug>`, whose PR is never
#      opened, so it never reached the main checkout's `IN_PROGRESS.md` —
#      making `task-orchestrator` step 1's `[OVERSIZE]` filter dead code.
#      Step 8 compounded this by claiming, falsely, that the branch on
#      origin carries "the code + tracking commits + the [OVERSIZE] marker
#      commit".
#
# Fix asserted here: the gate moved to step 3 (before the tracking move,
# before the push); on exit 1 it marks the still-active entry, commits the
# marker, SKIPS the tracking move, still pushes so origin carries code +
# marker, and never reaches `gh pr create` (now step 6). `task-orchestrator`
# step 8 states truthfully what is on origin and owns landing an
# operator-visible marker on the base branch via a `docs/oversize-<id>` PR
# dispatched to `pr-opener`. `skills/pr-flow/SKILL.md` — the executable
# recipe pr-author loads — is reordered to match.
#
# Contract invariants asserted:
#   Group 1 — agents/pr-author.md: step ORDER (gate before tracking move)
#     - size gate is step 3, tracking move step 4, push step 5, PR step 6
#     - regression guards: the old numbering (tracking move = 3, push = 4,
#       size gate = 5) is gone
#   Group 2 — agents/pr-author.md: OVERSIZE skips the tracking move
#     - exit 1 explicitly does NOT run step 4; the entry stays active
#     - the ordering rationale (after step 4 there is nothing left to mark)
#     - the marker is prepended to the STILL-ACTIVE IN_PROGRESS.md entry
#   Group 3 — agents/pr-author.md: OVERSIZE still pushes; marker precedes push
#     - marker is committed, then step 5 (push) still runs
#     - step 5 knows the branch may carry the marker commit instead of the
#       tracking commit — never both
#     - the marker cannot reach the base branch on its own (honest scope)
#     - regression guards: the old "Why before push & after the branch
#       already exists" justification and the old "mark it, return" scope
#       (no push) are gone
#   Group 4 — agents/task-orchestrator.md: the false origin claim is GONE
#     - NEGATIVE: "code + tracking commits + the [OVERSIZE] marker commit"
#     - replacement states the branch deliberately lacks the tracking commit
#     - step 3 (not step 5) is named as the gate that trips
#   Group 5 — agents/task-orchestrator.md: step 8 owns the base-branch marker
#     - step 8 lands an operator-visible marker on the base branch
#     - via a dedicated `docs/oversize-<id>` branch dispatched to `pr-opener`
#     - step 1's filter is honest about which marker it can actually see
#     - the orchestrator's Edit allowance covers the step-8 marker
#   Group 6 — skills/pr-flow/SKILL.md: the recipe agrees with the agent file
#     - heading order: 3 size gate / 4 tracking move / 5 push / 6 PR
#     - OVERSIZE bullet skips step 4 and still runs step 5
#     - step 5 states it runs on the OVERSIZE path too
#     - NEGATIVE: the contradictory "can only be measured after step 4 lands
#       the tracking commit" justification is gone, along with the old
#       heading order and the old "branch is already on origin — that's
#       fine" hand-wave
#   Group 7 — cross-file consistency: no stale step references left behind
#     - task-decomposer / release.md / orchestrator point at the new order
#     - no "step 4.5" phrasing in the files this branch owns
#       (NOTE: `scripts/atelier-pr-size-check` has a known stale "step 4.5"
#       help-text mention that is deliberately out of scope for #30 — it is
#       NOT asserted here on purpose.)
#
# Hermetic: greps committed prose only — no network, no `gh`, no temp dirs.
#
# Run:  hooks/tests/oversize-marker-accounting.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PR_AUTHOR="$REPO_ROOT/agents/pr-author.md"
ORCH="$REPO_ROOT/agents/task-orchestrator.md"
SKILL="$REPO_ROOT/skills/pr-flow/SKILL.md"
DECOMPOSER="$REPO_ROOT/agents/task-decomposer.md"
RELEASE="$REPO_ROOT/commands/release.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_prose <file> <fixed-string> <label>
# Passes when the fixed string is present in the file; fails otherwise.
chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

# chk_absent <file> <fixed-string> <label>
# Passes when the fixed string is ABSENT from the file; fails otherwise.
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    fail "$label — token '$pattern' found but should be absent in $file"
  else
    pass "$label"
  fi
}

# ---------------------------------------------------------------------------
# Group 1: agents/pr-author.md — the size gate is ordered BEFORE the
# tracking move, before the push, and before `gh pr create`.
# ---------------------------------------------------------------------------

chk_prose "$PR_AUTHOR" \
  '3. **Size gate — run `atelier-pr-size-check` BEFORE the tracking move and BEFORE the push.**' \
  "pr-author: size gate is step 3 and says it runs before the tracking move + push"

chk_prose "$PR_AUTHOR" \
  '4. **Move the tracking forward as a separate commit' \
  "pr-author: the IN_PROGRESS → HISTORY tracking move is step 4 (after the gate)"

chk_prose "$PR_AUTHOR" \
  '5. **Push to the right place.**' \
  "pr-author: the push is step 5 (after the gate and the tracking move)"

chk_prose "$PR_AUTHOR" \
  '6. **Open the PR with `gh pr create`.**' \
  "pr-author: gh pr create is step 6 (last, and unreachable on the OVERSIZE path)"

chk_prose "$PR_AUTHOR" \
  'the size gate clears (step 3)' \
  "pr-author: step 4 names step 3 as the gate it waits on (forward reference is consistent)"

chk_prose "$PR_AUTHOR" \
  'you returned `oversized` after the size gate tripped (step 3)' \
  'pr-author: the terminal-states preamble points `oversized` at step 3'

chk_prose "$PR_AUTHOR" \
  'proceed to commit → size gate → tracking commit → push → `gh pr create`' \
  "pr-author: the precondition preamble spells the corrected pipeline order"

# Regression guards — the pre-fix numbering must be gone.
chk_absent "$PR_AUTHOR" \
  '3. **Move the tracking forward as a separate commit' \
  "pr-author: OLD numbering gone — tracking move is no longer step 3"

chk_absent "$PR_AUTHOR" \
  '4. **Push to the right place.**' \
  "pr-author: OLD numbering gone — push is no longer step 4"

chk_absent "$PR_AUTHOR" \
  '5. **Size gate — run `atelier-pr-size-check` BEFORE `gh pr create`**' \
  "pr-author: OLD numbering gone — size gate is no longer step 5"

# ---------------------------------------------------------------------------
# Group 2: agents/pr-author.md — on OVERSIZE the tracking move is SKIPPED,
# because the still-active entry is what carries the marker.
# ---------------------------------------------------------------------------

chk_prose "$PR_AUTHOR" \
  '**do NOT run step 4**' \
  "pr-author: OVERSIZE exit explicitly does NOT run step 4 (the tracking move)"

chk_prose "$PR_AUTHOR" \
  'so its entry must stay active' \
  "pr-author: OVERSIZE states the task entry must stay active (task is not done)"

chk_prose "$PR_AUTHOR" \
  '**Mark the entry that is still there.**' \
  "pr-author: OVERSIZE marks the entry that is still present in IN_PROGRESS.md"

chk_prose "$PR_AUTHOR" \
  'were this gate to run after step 4, the entry would already be in `HISTORY.md` and there would be nothing left to mark' \
  "pr-author: OVERSIZE spells out why the gate must precede the tracking move (#30 root cause)"

chk_prose "$PR_AUTHOR" \
  "and step 3's OVERSIZE exit (no PR is opened, the task is not done, and the still-active entry is what carries the \`[OVERSIZE]\` marker)" \
  "pr-author: decision rules carve the OVERSIZE exit out of the never-skip-the-tracking-move rule"

# ---------------------------------------------------------------------------
# Group 3: agents/pr-author.md — on OVERSIZE the push STILL happens, so
# origin carries code + marker; i.e. the marker is committed BEFORE the push.
# ---------------------------------------------------------------------------

chk_prose "$PR_AUTHOR" \
  '**Commit the marker** as `chore(tracking): mark #<id> [OVERSIZE]' \
  "pr-author: OVERSIZE commits the marker as its own chore(tracking) commit"

chk_prose "$PR_AUTHOR" \
  '**Still run step 5 (push).**' \
  "pr-author: OVERSIZE still runs the push (step 5) after committing the marker"

chk_prose "$PR_AUTHOR" \
  'The branch — code commit + marker commit, no tracking move — belongs on origin' \
  "pr-author: OVERSIZE states origin must carry the code commit + the marker commit"

chk_prose "$PR_AUTHOR" \
  "the code commit plus either the tracking commit (normal path) or the \`[OVERSIZE]\` marker commit (step 3's exit-1 path) — never both" \
  "pr-author: step 5 (push) knows the branch carries tracking OR marker, never both"

chk_prose "$PR_AUTHOR" \
  'whose PR is never opened, so it cannot reach the base branch on its own' \
  "pr-author: honest about the marker not reaching the base branch by itself"

chk_prose "$PR_AUTHOR" \
  "Landing an operator-visible marker on the base is \`task-orchestrator\`'s step 8" \
  "pr-author: hands base-branch marker ownership to task-orchestrator step 8"

chk_prose "$PR_AUTHOR" \
  'detect oversize, mark the active entry, push, return' \
  "pr-author: scope statement includes the push on the OVERSIZE path"

# Regression guards — the pre-fix OVERSIZE prose must be gone.
chk_absent "$PR_AUTHOR" \
  'Why before push & after the branch already exists' \
  "pr-author: OLD 'why before push & after the branch already exists' rationale gone"

chk_absent "$PR_AUTHOR" \
  'Stay narrowly scoped to "detect oversize, mark it, return"' \
  "pr-author: OLD scope statement (marks, returns, never pushes) gone"

chk_absent "$PR_AUTHOR" \
  'so it lands on the same branch as the code + tracking commits' \
  "pr-author: OLD claim that the marker lands alongside the tracking commit gone"

# ---------------------------------------------------------------------------
# Group 4: agents/task-orchestrator.md — the false origin claim is gone.
# ---------------------------------------------------------------------------

chk_absent "$ORCH" \
  'The branch is already on origin with the code + tracking commits + the `[OVERSIZE]` marker commit' \
  "task-orchestrator: FALSE 'code + tracking commits + marker commit' claim removed (#30 defect 3)"

chk_prose "$ORCH" \
  'The branch is already on origin with the code commit + the `[OVERSIZE]` marker commit' \
  "task-orchestrator: replacement states origin carries the code commit + the marker commit"

chk_prose "$ORCH" \
  'and deliberately **without** the `IN_PROGRESS → HISTORY` tracking commit, since the task is not done' \
  "task-orchestrator: replacement states the branch deliberately lacks the tracking commit"

chk_prose "$ORCH" \
  'when its step 3 size-gate trips' \
  "task-orchestrator: names pr-author's step 3 as the gate that trips"

chk_absent "$ORCH" \
  'when its step 5 size-gate trips' \
  "task-orchestrator: OLD 'step 5 size-gate' reference gone"

chk_prose "$ORCH" \
  'it marks that entry `[OVERSIZE]` on the task branch, pushes the branch, and returns without opening the PR and without moving the tracking' \
  "task-orchestrator: describes pr-author's OVERSIZE return accurately (marks, pushes, no PR, no move)"

# ---------------------------------------------------------------------------
# Group 5: agents/task-orchestrator.md — step 8 owns landing the
# base-branch marker; step 1's filter is honest about what it can see.
# ---------------------------------------------------------------------------

chk_prose "$ORCH" \
  '**Land the operator-visible marker on the base branch before you yield.**' \
  "task-orchestrator: step 8 owns landing the operator-visible base-branch marker"

chk_prose "$ORCH" \
  'on a dedicated `docs/oversize-<id>` branch' \
  "task-orchestrator: step 8 lands the marker on a dedicated docs/oversize-<id> branch"

chk_prose "$ORCH" \
  '**dispatch `pr-opener` via `Task`**' \
  "task-orchestrator: step 8 dispatches pr-opener to author the marker PR (never gh pr create itself)"

chk_prose "$ORCH" \
  'This is the step that makes your own step-1 `[OVERSIZE]` filter real' \
  "task-orchestrator: step 8 states it is what makes step 1's OVERSIZE filter real"

chk_prose "$ORCH" \
  'whose PR is never opened, so it never reaches this checkout' \
  "task-orchestrator: step 1's filter is honest that pr-author's marker never reaches this checkout"

chk_prose "$ORCH" \
  '**your own step 8 lands on the base branch** via the `docs/oversize-<id>` PR' \
  "task-orchestrator: step 1 names step 8's docs PR as the marker it actually filters on"

chk_prose "$ORCH" \
  "step 3's tracking move, and step 8's \`[OVERSIZE]\` marker on the base branch" \
  "task-orchestrator: the Edit/Write allowance covers step 8's base-branch marker"

chk_prose "$ORCH" \
  "including step 8's \`docs/oversize-<id>\` bookkeeping PR" \
  "task-orchestrator: the never-run-gh-pr-create rule names the step-8 bookkeeping PR as pr-opener's"

chk_prose "$ORCH" \
  '[OVERSIZE] marker landed via <docs-pr-url>' \
  "task-orchestrator: the oversized terminal report surfaces the docs PR URL"

# ---------------------------------------------------------------------------
# Group 6: skills/pr-flow/SKILL.md — the executable recipe agrees with the
# agent file (gate before the tracking move / before the push).
# ---------------------------------------------------------------------------

chk_prose "$SKILL" \
  '### 3. Size gate — `atelier-pr-size-check` before the tracking move and before the push' \
  "pr-flow: recipe step 3 is the size gate, before the tracking move and the push"

chk_prose "$SKILL" \
  '### 4. Move tracking — same commit set, not a follow-up' \
  "pr-flow: recipe step 4 is the tracking move (after the gate)"

chk_prose "$SKILL" \
  '### 5. Push only to `origin task/<id>-<slug>`' \
  "pr-flow: recipe step 5 is the push (after the gate)"

chk_prose "$SKILL" \
  '### 6. Open the PR with `gh pr create`' \
  "pr-flow: recipe step 6 is gh pr create"

chk_prose "$SKILL" \
  '**do not run step 4**' \
  "pr-flow: OVERSIZE bullet skips step 4 (the tracking move)"

chk_prose "$SKILL" \
  'then still run step 5 so the branch reaches `origin`' \
  "pr-flow: OVERSIZE bullet still runs step 5 so origin carries the marker"

chk_prose "$SKILL" \
  'Once step 4 has moved that entry to `HISTORY.md` there is nothing left to mark' \
  "pr-flow: records the #30 root cause (nothing left to mark after the tracking move)"

chk_prose "$SKILL" \
  'This step runs on the OVERSIZE path too (carrying the code commit + the marker commit)' \
  "pr-flow: step 5 states it runs on the OVERSIZE path too"

# Regression guards — the pre-fix recipe order + justification must be gone.
chk_absent "$SKILL" \
  'Why here and not earlier: the size budget is a property of the diff' \
  "pr-flow: OLD 'why here and not earlier' justification gone"

chk_absent "$SKILL" \
  'can only be measured after step 4 lands the tracking commit' \
  "pr-flow: OLD contradictory claim (measurable only after the tracking commit) gone"

chk_absent "$SKILL" \
  '### 3. Push only to `origin task/<id>-<slug>`' \
  "pr-flow: OLD heading order gone — the push is no longer step 3"

chk_absent "$SKILL" \
  '### 5. Size gate — `atelier-pr-size-check` before opening the PR' \
  "pr-flow: OLD heading order gone — the size gate is no longer step 5"

chk_absent "$SKILL" \
  "The branch is already on \`origin\` — that's fine" \
  "pr-flow: OLD 'branch is already on origin — that's fine' hand-wave gone"

# ---------------------------------------------------------------------------
# Group 7: cross-file consistency — no stale step references left behind in
# the files this branch owns.
# ---------------------------------------------------------------------------

chk_prose "$DECOMPOSER" \
  'trip the size gate at `pr-author` step 3' \
  "task-decomposer: points at pr-author step 3 as the size gate"

chk_absent "$DECOMPOSER" \
  'trip the size gate at `pr-author` step 5' \
  "task-decomposer: OLD 'pr-author step 5' size-gate reference gone"

chk_prose "$RELEASE" \
  'push gate → code commit → size gate → push → `gh pr create`' \
  "release: the release-PR flow sketch uses the corrected order (gate before push)"

chk_absent "$RELEASE" \
  'push gate → code commit → push → size gate → `gh pr create`' \
  "release: OLD flow sketch (push before size gate) gone"

# "step 4.5" was the pre-#30 shorthand for wedging the gate between the
# tracking move and the push. None of the files this branch owns may keep it.
# (scripts/atelier-pr-size-check still carries one in its --help text; that
# file was out of scope for #30 and is deliberately not asserted here.)
for f in "$PR_AUTHOR" "$ORCH" "$SKILL" "$DECOMPOSER" "$RELEASE"; do
  chk_absent "$f" 'step 4.5' \
    "no stale 'step 4.5' reference in $(basename "$(dirname "$f")")/$(basename "$f")"
done

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "oversize-marker-accounting (#30): all assertions passed."
  exit 0
else
  echo "oversize-marker-accounting (#30): $fails assertion(s) failed."
  exit 1
fi
