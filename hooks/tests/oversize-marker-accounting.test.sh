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
# Review fix cycle 1 added groups 8-10: the same "impossible instruction /
# false claim" class re-appeared three more times in the reordered prose.
#
# Review fix cycle 2 added groups 11-12: cycle 1 gave `pr-author` a SECOND way
# to return `oversized` (from a `follow_up: true` dispatch) without teaching
# `task-orchestrator` step 8 to tell the two apart, and the backend-tracked
# carve-out added in cycle 0 was not inherited by the sub-steps under it.
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
#   Group 8 — agents/pr-author.md: FOLLOW-UP mode's `oversized` still pushes
#     - after the reorder, follow-up step 3's exit-1 returned `oversized`
#       without ever reaching step 5, so a fix commit stranded locally while
#       the already-open PR kept showing pre-fix code — and that falsified
#       `task-orchestrator`'s "already on origin" premise. Same defect class
#       as #30 defect 2, one mode over.
#     - exit 1 now runs step 5 first, keeps step 6 skipped, and the
#       valid-terminal-states line says so
#     - NEGATIVE: the push-less `Exit 1 → return \`oversized\`` exit and the
#       unqualified `\`oversized\` (step 3 tripped),` terminal are gone
#   Group 9 — agents/pr-author.md: the Output block admits the OVERSIZE
#     terminal exists
#     - the `Tracking:` bullet used to say the `IN_PROGRESS → HISTORY` line
#       "should always read exactly that. There is no 'skipped' path" — on
#       an agent whose own step 3 deliberately skips that move. Same class:
#       a rule that contradicts the procedure it documents.
#     - `PR:` gained the `not opened — OVERSIZE` alternative; `Tracking:`
#       gained the OVERSIZE and backend-tracked variants; the no-skip rule
#       is scoped to *outside* that terminal
#     - NEGATIVE: "should always read exactly that" is gone
#   Group 10 — pr-author + SKILL: the local size verdict is a LOWER BOUND
#     - both files claimed bookkeeping stays out of the count "by
#       construction". It does not: `atelier-pr-size-check`'s
#       `DEFAULT_EXEMPT` covers lockfiles/generated/tests/migrations and NOT
#       `IN_PROGRESS.md` / `HISTORY.md`, so the `--pr`-mode run the reviewer
#       and the auto-merge gate perform counts the tracking commit. The two
#       gates disagreed by ~1 file / ~15 lines.
#     - resolution asserted here is prose-only: the local `--branch` count is
#       code-only *only because step 4's commit does not exist yet*, and the
#       verdict is an early lower bound (near-budget pass = provisional)
#     - NEGATIVE: both "by construction" claims are gone
#     - `scripts/atelier-pr-size-check` was deliberately NOT changed and is
#       deliberately NOT asserted against here.
#   Group 11 — agents/task-orchestrator.md: step 8 discriminates first-pass
#     from `follow_up: true` `oversized`
#     - step 8 was keyed only on "pr-author returned oversized", but on a
#       follow-up dispatch every premise inverts: the tracking move already
#       landed, there is no marker commit, and the PR already exists. Acting
#       on the first-pass assumption would land a `docs/oversize-<id>` PR
#       marking `IN_PROGRESS.md` on the base while the task's own open PR
#       already carries the `HISTORY.md` move — on merge `main` holds both,
#       corrupting exactly what `atelier-housekeeping` and step 1 key on.
#     - the discriminator exists and both paths are labelled; the follow-up
#       path skips broker + marker + auto-merge and exits the loop
#     - the marker-landing action is scoped "first-pass only, never on the
#       follow-up path"; the terminal report carries both statuses
#     - reachability: review-fix Step 4 names the `oversized` return and
#       routes it to step 8 instead of falling through to the reviewer
#     - `pr-author`'s size-gate waiver is scoped to the first pass
#     - NEGATIVE: the conflated single path, the unconditional marker-landing
#       heading, the two-case enumeration, Step 4's single outcome and the
#       untagged status line are gone
#   Group 12 — pr-author + SKILL: the backend-tracked carve-out is INHERITED
#     - exit-1 sub-step 1 skipped the `IN_PROGRESS.md` edit on
#       `github-project` / `linear`, but sub-steps 2 ("commit the marker") and
#       3 ("code commit + marker commit") were unconditional — telling the
#       agent to commit a file it had just been told not to write. Same class
#       as #30 defect 1, and it lands on the backend THIS repo uses.
#     - sub-step 2 is skipped too (never fabricate an empty commit); sub-step
#       3 says the branch carries the code commit alone; step 5's
#       tracking-XOR-marker invariant admits the "neither" case
#     - NEGATIVE: the unconditional `never both.` and
#       `no tracking move — belongs on origin` forms are gone, along with
#       SKILL's edit-only parenthetical
#
# Anchor policy (reviewer nit, cycle 1): each literal is the SHORTEST phrase
# that still (a) survives a reasonable copy-edit and (b) still fires against
# the pre-fix text. Long literals that remain are deliberate — they encode a
# whole ordering/enumeration invariant that no shorter substring captures
# (e.g. the `commit → size gate → tracking commit → push → gh pr create`
# pipeline sketch, where the sequence *is* the assertion).
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
  '3. **Size gate' \
  "pr-author: the size gate is step 3"

chk_prose "$PR_AUTHOR" \
  'BEFORE the tracking move and BEFORE the push' \
  "pr-author: the size gate heading states it runs before the tracking move + push"

chk_prose "$PR_AUTHOR" \
  '4. **Move the tracking forward' \
  "pr-author: the IN_PROGRESS → HISTORY tracking move is step 4 (after the gate)"

chk_prose "$PR_AUTHOR" \
  '5. **Push to the right place' \
  "pr-author: the push is step 5 (after the gate and the tracking move)"

chk_prose "$PR_AUTHOR" \
  '6. **Open the PR with `gh pr create`' \
  "pr-author: gh pr create is step 6 (last, and unreachable on the OVERSIZE path)"

chk_prose "$PR_AUTHOR" \
  'the size gate clears (step 3)' \
  "pr-author: step 4 names step 3 as the gate it waits on (forward reference is consistent)"

chk_prose "$PR_AUTHOR" \
  'after the size gate tripped (step 3)' \
  'pr-author: the terminal-states preamble points `oversized` at step 3'

# Deliberately long: the sequence IS the invariant — no shorter substring
# captures "gate sits between the code commit and the tracking commit".
chk_prose "$PR_AUTHOR" \
  'proceed to commit → size gate → tracking commit → push → `gh pr create`' \
  "pr-author: the precondition preamble spells the corrected pipeline order"

# Regression guards — the pre-fix numbering must be gone.
chk_absent "$PR_AUTHOR" \
  '3. **Move the tracking forward' \
  "pr-author: OLD numbering gone — tracking move is no longer step 3"

chk_absent "$PR_AUTHOR" \
  '4. **Push to the right place' \
  "pr-author: OLD numbering gone — push is no longer step 4"

chk_absent "$PR_AUTHOR" \
  '5. **Size gate' \
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
  'were this gate to run after step 4' \
  "pr-author: OVERSIZE spells out why the gate must precede the tracking move (#30 root cause)"

chk_prose "$PR_AUTHOR" \
  "and step 3's OVERSIZE exit" \
  "pr-author: decision rules carve the OVERSIZE exit out of the never-skip-the-tracking-move rule"

# ---------------------------------------------------------------------------
# Group 3: agents/pr-author.md — on OVERSIZE the push STILL happens, so
# origin carries code + marker; i.e. the marker is committed BEFORE the push.
# ---------------------------------------------------------------------------

chk_prose "$PR_AUTHOR" \
  '**Commit the marker**' \
  "pr-author: OVERSIZE commits the marker as its own commit"

chk_prose "$PR_AUTHOR" \
  '**Still run step 5 (push).**' \
  "pr-author: OVERSIZE still runs the push (step 5) after committing the marker"

# NOTE (cycle 2): this literal survived cycle 2 verbatim — the backend-tracked
# carve-out was appended as a trailing parenthetical rather than spliced into
# the phrase. It is NOT vacuous (it still fires against prose that drops the
# code+marker claim), but on its own it would also pass against prose that
# lost the carve-out again, so group 12 pairs it with the negative on the
# pre-carve-out sentence tail `no tracking move — belongs on origin`.
chk_prose "$PR_AUTHOR" \
  'code commit + marker commit, no tracking move' \
  "pr-author: OVERSIZE states origin must carry the code commit + the marker commit"

# Deliberately long: the invariant is the exclusive-or over the two commit
# shapes; "never both" alone would pass against prose that lists the wrong
# alternatives.
chk_prose "$PR_AUTHOR" \
  "either the tracking commit (normal path) or the \`[OVERSIZE]\` marker commit (step 3's exit-1 path) — never both" \
  "pr-author: step 5 (push) knows the branch carries tracking OR marker, never both"

chk_prose "$PR_AUTHOR" \
  'cannot reach the base branch on its own' \
  "pr-author: honest about the marker not reaching the base branch by itself"

chk_prose "$PR_AUTHOR" \
  'Landing an operator-visible marker on the base' \
  "pr-author: hands base-branch marker ownership to task-orchestrator step 8"

chk_prose "$PR_AUTHOR" \
  'detect oversize, mark the active entry, push, return' \
  "pr-author: scope statement includes the push on the OVERSIZE path"

# Regression guards — the pre-fix OVERSIZE prose must be gone.
chk_absent "$PR_AUTHOR" \
  'Why before push' \
  "pr-author: OLD 'why before push & after the branch already exists' rationale gone"

chk_absent "$PR_AUTHOR" \
  'detect oversize, mark it, return' \
  "pr-author: OLD scope statement (marks, returns, never pushes) gone"

chk_absent "$PR_AUTHOR" \
  'the same branch as the code + tracking commits' \
  "pr-author: OLD claim that the marker lands alongside the tracking commit gone"

# ---------------------------------------------------------------------------
# Group 4: agents/task-orchestrator.md — the false origin claim is gone.
# ---------------------------------------------------------------------------

chk_absent "$ORCH" \
  'the code + tracking commits + the `[OVERSIZE]` marker commit' \
  "task-orchestrator: FALSE 'code + tracking commits + marker commit' claim removed (#30 defect 3)"

chk_prose "$ORCH" \
  'the code commit + the `[OVERSIZE]` marker commit' \
  "task-orchestrator: replacement states origin carries the code commit + the marker commit"

chk_prose "$ORCH" \
  'deliberately **without** the `IN_PROGRESS → HISTORY` tracking commit' \
  "task-orchestrator: replacement states the branch deliberately lacks the tracking commit"

chk_prose "$ORCH" \
  'when its step 3 size-gate trips' \
  "task-orchestrator: names pr-author's step 3 as the gate that trips"

chk_absent "$ORCH" \
  'when its step 5 size-gate trips' \
  "task-orchestrator: OLD 'step 5 size-gate' reference gone"

chk_prose "$ORCH" \
  'pushes the branch, and returns without opening the PR' \
  "task-orchestrator: describes pr-author's OVERSIZE return accurately (marks, pushes, no PR)"

# ---------------------------------------------------------------------------
# Group 5: agents/task-orchestrator.md — step 8 owns landing the
# base-branch marker; step 1's filter is honest about what it can see.
# ---------------------------------------------------------------------------

chk_prose "$ORCH" \
  '**Land the operator-visible marker on the base branch' \
  "task-orchestrator: step 8 owns landing the operator-visible base-branch marker"

chk_prose "$ORCH" \
  'on a dedicated `docs/oversize-<id>` branch' \
  "task-orchestrator: step 8 lands the marker on a dedicated docs/oversize-<id> branch"

chk_prose "$ORCH" \
  '**dispatch `pr-opener` via `Task`**' \
  "task-orchestrator: step 8 dispatches pr-opener to author the marker PR (never gh pr create itself)"

chk_prose "$ORCH" \
  'makes your own step-1 `[OVERSIZE]` filter real' \
  "task-orchestrator: step 8 states it is what makes step 1's OVERSIZE filter real"

chk_prose "$ORCH" \
  'so it never reaches this checkout' \
  "task-orchestrator: step 1's filter is honest that pr-author's marker never reaches this checkout"

chk_prose "$ORCH" \
  '**your own step 8 lands on the base branch**' \
  "task-orchestrator: step 1 names step 8's docs PR as the marker it actually filters on"

chk_prose "$ORCH" \
  "step 8's \`[OVERSIZE]\` marker on the base branch" \
  "task-orchestrator: the Edit/Write allowance covers step 8's base-branch marker"

chk_prose "$ORCH" \
  "step 8's \`docs/oversize-<id>\` bookkeeping PR" \
  "task-orchestrator: the never-run-gh-pr-create rule names the step-8 bookkeeping PR as pr-opener's"

chk_prose "$ORCH" \
  '[OVERSIZE] marker landed via <docs-pr-url>' \
  "task-orchestrator: the oversized terminal report surfaces the docs PR URL"

# ---------------------------------------------------------------------------
# Group 6: skills/pr-flow/SKILL.md — the executable recipe agrees with the
# agent file (gate before the tracking move / before the push).
# ---------------------------------------------------------------------------

chk_prose "$SKILL" \
  '### 3. Size gate' \
  "pr-flow: recipe step 3 is the size gate"

chk_prose "$SKILL" \
  '### 4. Move tracking' \
  "pr-flow: recipe step 4 is the tracking move (after the gate)"

chk_prose "$SKILL" \
  '### 5. Push only to' \
  "pr-flow: recipe step 5 is the push (after the gate)"

chk_prose "$SKILL" \
  '### 6. Open the PR' \
  "pr-flow: recipe step 6 is gh pr create"

chk_prose "$SKILL" \
  '**do not run step 4**' \
  "pr-flow: OVERSIZE bullet skips step 4 (the tracking move)"

chk_prose "$SKILL" \
  'still run step 5 so the branch reaches' \
  "pr-flow: OVERSIZE bullet still runs step 5 so origin carries the marker"

chk_prose "$SKILL" \
  'there is nothing left to mark' \
  "pr-flow: records the #30 root cause (nothing left to mark after the tracking move)"

chk_prose "$SKILL" \
  'This step runs on the OVERSIZE path too' \
  "pr-flow: step 5 states it runs on the OVERSIZE path too"

# Regression guards — the pre-fix recipe order + justification must be gone.
chk_absent "$SKILL" \
  'Why here and not earlier' \
  "pr-flow: OLD 'why here and not earlier' justification gone"

chk_absent "$SKILL" \
  'only be measured after step 4' \
  "pr-flow: OLD contradictory claim (measurable only after the tracking commit) gone"

chk_absent "$SKILL" \
  '### 3. Push only to' \
  "pr-flow: OLD heading order gone — the push is no longer step 3"

chk_absent "$SKILL" \
  '### 5. Size gate' \
  "pr-flow: OLD heading order gone — the size gate is no longer step 5"

chk_absent "$SKILL" \
  "already on \`origin\` — that's fine" \
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
# Group 8: agents/pr-author.md — FOLLOW-UP mode's `oversized` terminal is no
# longer push-less. Post-reorder the gate returned at step 3 and step 5
# (push) was never reached, so a fix commit stranded locally while the
# already-open PR kept showing pre-fix code — and that falsified
# `task-orchestrator`'s "already on origin, only the PR object is missing"
# premise. Same defect class as #30 defect 2, one mode over.
# ---------------------------------------------------------------------------

chk_prose "$PR_AUTHOR" \
  '**still run step 5 (push)**' \
  "pr-author follow-up: exit 1 still runs step 5 (push) before returning oversized"

chk_prose "$PR_AUTHOR" \
  'The push is not optional on this path' \
  "pr-author follow-up: the push on the oversized path is stated as mandatory"

chk_prose "$PR_AUTHOR" \
  '"already on origin" premise' \
  "pr-author follow-up: names the orchestrator premise a push-less return would falsify"

chk_prose "$PR_AUTHOR" \
  'Skip step 6 — the PR exists' \
  "pr-author follow-up: step 6 (gh pr create) stays skipped — the PR already exists"

chk_prose "$PR_AUTHOR" \
  "after step 5's push" \
  "pr-author follow-up: the valid-terminal-states line says oversized comes after the push"

# Regression guards — the push-less follow-up exit must be gone.
chk_absent "$PR_AUTHOR" \
  'Exit 1 → return `oversized`' \
  "pr-author follow-up: OLD push-less 'Exit 1 → return oversized' exit gone"

chk_absent "$PR_AUTHOR" \
  '`oversized` (step 3 tripped),' \
  "pr-author follow-up: OLD unqualified '(step 3 tripped)' terminal (no push) gone"

chk_absent "$PR_AUTHOR" \
  '`oversized` (step 5 tripped)' \
  "pr-author follow-up: OLD pre-#30 '(step 5 tripped)' terminal reference gone"

# ---------------------------------------------------------------------------
# Group 9: agents/pr-author.md Output block — the `Tracking:` bullet used to
# assert the `IN_PROGRESS → HISTORY` line "should always read exactly that.
# There is no 'skipped' path", on an agent whose own step 3 deliberately
# skips that move. The rule now names the terminals it does not cover.
# ---------------------------------------------------------------------------

chk_prose "$PR_AUTHOR" \
  'not opened — OVERSIZE' \
  "pr-author Output: the PR: bullet has an OVERSIZE alternative (no PR was opened)"

chk_prose "$PR_AUTHOR" \
  'not moved — task not done' \
  "pr-author Output: the Tracking: bullet has an OVERSIZE variant (the move did not happen)"

chk_prose "$PR_AUTHOR" \
  'marker committed on the active entry' \
  "pr-author Output: the OVERSIZE variant names the marker on the still-active entry"

chk_prose "$PR_AUTHOR" \
  'not moved — tracking lives in the backend' \
  "pr-author Output: the Tracking: bullet has a backend-tracked variant (no marker written)"

chk_prose "$PR_AUTHOR" \
  'Outside that terminal there is no "skipped" path' \
  "pr-author Output: the no-skipped-path rule is scoped to outside the OVERSIZE terminal"

# Regression guards — the unqualified absolutes must be gone.
chk_absent "$PR_AUTHOR" \
  'should always read exactly that' \
  "pr-author Output: OLD absolute 'should always read exactly that' claim gone"

chk_absent "$PR_AUTHOR" \
  'handed back to tester").' \
  "pr-author Output: OLD two-outcome PR: bullet (no OVERSIZE alternative) gone"

# ---------------------------------------------------------------------------
# Group 10: pr-author + SKILL — the local `--branch` size verdict is an early
# LOWER BOUND, not an exempt-by-construction final word. `DEFAULT_EXEMPT` in
# `scripts/atelier-pr-size-check` covers lockfiles / generated / tests /
# migrations and NOT `IN_PROGRESS.md` / `HISTORY.md`, so the `--pr`-mode run
# the reviewer and the auto-merge gate perform counts the tracking commit —
# the two gates disagreed by ~1 file / ~15 lines. The resolution asserted
# here is prose-only; the script is deliberately unchanged and unasserted.
# ---------------------------------------------------------------------------

chk_prose "$PR_AUTHOR" \
  'This verdict is a lower bound' \
  "pr-author: the local size verdict is stated to be a lower bound"

chk_prose "$PR_AUTHOR" \
  '`DEFAULT_EXEMPT` does not exempt' \
  "pr-author: states DEFAULT_EXEMPT does not exempt the tracking files"

chk_prose "$PR_AUTHOR" \
  'either limit as provisional' \
  "pr-author: a near-budget pass is explicitly provisional"

chk_absent "$PR_AUTHOR" \
  'keeps bookkeeping lines out of the counted diff' \
  "pr-author: OLD false 'keeps bookkeeping out of the counted diff' claim gone"

chk_prose "$SKILL" \
  "step 4's commit does not exist yet" \
  "pr-flow: the count is code-only only because step 4's commit does not exist yet"

chk_prose "$SKILL" \
  '`DEFAULT_EXEMPT`' \
  "pr-flow: names DEFAULT_EXEMPT as the actual exemption mechanism"

chk_prose "$SKILL" \
  'not `IN_PROGRESS.md` / `HISTORY.md`' \
  "pr-flow: states the tracking files are NOT in DEFAULT_EXEMPT"

chk_prose "$SKILL" \
  'counts the tracking commit too' \
  "pr-flow: the later --pr-mode run counts the tracking commit too"

chk_prose "$SKILL" \
  'not the authoritative one' \
  "pr-flow: this gate is the cheap early check, not the authoritative one"

chk_prose "$SKILL" \
  '`prSize.exempt`' \
  "pr-flow: points at the per-project prSize.exempt escape hatch"

chk_absent "$SKILL" \
  'stay out of the count by construction' \
  "pr-flow: OLD false 'bookkeeping stays out of the count by construction' claim gone"

# ---------------------------------------------------------------------------
# Group 11: agents/task-orchestrator.md — step 8's `oversized` branch
# discriminates FIRST-PASS from `follow_up: true`.
#
# After cycle 1, `pr-author` can return `oversized` from two different
# dispatches, and step 8 was keyed only on "pr-author returned oversized". On a
# follow-up dispatch every premise of that single path is inverted: the branch
# already carries the `IN_PROGRESS → HISTORY` move (landed on the first pass),
# there is no `[OVERSIZE]` marker commit, and the PR object already exists — so
# "the only thing missing is the PR object" is false. Acting on it anyway would
# open a `docs/oversize-<id>` PR pulling the task out of `ROADMAP.md` into a
# marked `IN_PROGRESS.md` entry *while* that task's own PR is open carrying the
# `HISTORY.md` move — so on merge `main` would hold both, which is exactly the
# state `atelier-housekeeping` and step 1's filter key on.
#
# Highest-value regression guards here: the discriminator exists, the
# marker-landing action is scoped first-pass-only, and the follow-up path
# forbids the `docs/oversize-<id>` landing outright.
# ---------------------------------------------------------------------------

chk_prose "$ORCH" \
  'discriminate on the dispatch that produced' \
  "task-orchestrator: step 8 discriminates on the dispatch that produced the oversized return"

chk_prose "$ORCH" \
  'leave the branch in opposite states' \
  "task-orchestrator: states first-pass and follow_up:true leave the branch in opposite states"

chk_prose "$ORCH" \
  '**Follow-up `oversized`' \
  "task-orchestrator: a labelled follow-up oversized path exists"

chk_prose "$ORCH" \
  '**First-pass `oversized`' \
  "task-orchestrator: the old premise is relabelled as the first-pass path"

# The three inverted premises, asserted one by one — a regression to the
# conflated form loses all three at once.
chk_prose "$ORCH" \
  '**already landed** on the first pass' \
  "task-orchestrator follow-up: premise 1 — the tracking move already landed"

chk_prose "$ORCH" \
  'there is **no** `[OVERSIZE]` marker commit' \
  "task-orchestrator follow-up: premise 2 — there is no marker commit on this branch"

chk_prose "$ORCH" \
  'the PR object **already exists**' \
  "task-orchestrator follow-up: premise 3 — the PR object already exists"

# The four things the follow-up path must NOT do.
chk_prose "$ORCH" \
  '**do not** consult the `decision-broker`' \
  "task-orchestrator follow-up: does not consult the decision-broker (no catalog option applies)"

chk_prose "$ORCH" \
  '**do not** land a base-branch marker' \
  "task-orchestrator follow-up: forbids landing the docs/oversize-<id> base-branch marker"

chk_prose "$ORCH" \
  'is precisely the corrupt state' \
  "task-orchestrator follow-up: names the corruption a base-branch marker would create"

chk_prose "$ORCH" \
  '**do not** invoke `auto-merge`' \
  "task-orchestrator follow-up: does not invoke auto-merge (the size guardrail would hold it)"

chk_prose "$ORCH" \
  'without spending another cycle' \
  "task-orchestrator follow-up: terminates by exiting the review-fix loop, no extra cycle"

# The first-pass-only scoping of the marker-landing action itself.
chk_prose "$ORCH" \
  'first-pass `oversized` only, never on the follow-up path' \
  "task-orchestrator: the marker-landing action is scoped first-pass-only"

chk_prose "$ORCH" \
  'already has both an open PR and the tracking move' \
  "task-orchestrator: the housekeeping rationale enumerates the follow-up case too"

# The terminal report distinguishes the two.
chk_prose "$ORCH" \
  '<docs-pr-url>` (first-pass)' \
  "task-orchestrator: the existing oversized status is tagged (first-pass)"

chk_prose "$ORCH" \
  'oversized (follow-up) —' \
  "task-orchestrator: the terminal report gained an oversized (follow-up) status"

chk_prose "$ORCH" \
  'no marker landed, tracking already moved' \
  "task-orchestrator: the follow-up status states no marker landed and tracking already moved"

# Reachability: the review-fix loop's Step 4 must name the `oversized` return
# and route it to step 8, or an oversized follow-up falls through to Step 5 and
# re-dispatches `reviewer` against an untriaged PR — the discriminator above
# would never be reached at all.
chk_prose "$ORCH" \
  '`oversized`, when the fix grew the cumulative diff' \
  "task-orchestrator: review-fix Step 4 names oversized as a follow-up outcome of pr-author"

chk_prose "$ORCH" \
  'do **not** proceed to Step 5' \
  "task-orchestrator: an oversized follow-up return does not fall through to the reviewer re-dispatch"

chk_prose "$ORCH" \
  "into step 8's **follow-up \`oversized\`** path" \
  "task-orchestrator: Step 4 routes the oversized return into step 8's follow-up path"

# pr-author's side of the discriminator: the size-gate waiver is first-pass only.
chk_prose "$PR_AUTHOR" \
  'also **first-pass only**' \
  "pr-author: the waived-gate re-dispatch is scoped to the first pass"

chk_prose "$PR_AUTHOR" \
  'follow-up exit 1 always pushes and returns' \
  "pr-author: a follow-up exit 1 always pushes and returns oversized (never waived)"

# Regression guards — the conflated single-path form must be gone.
chk_absent "$ORCH" \
  'budget. The branch is already on origin' \
  "task-orchestrator: OLD conflated single path (premises asserted unconditionally) gone"

chk_absent "$ORCH" \
  'on the base branch before you yield.**' \
  "task-orchestrator: OLD unconditional marker-landing heading (no first-pass scope) gone"

chk_absent "$ORCH" \
  'so neither needs one' \
  "task-orchestrator: OLD two-case enumeration (slice-task / open-anyway only) gone"

chk_absent "$ORCH" \
  'the new commit SHA.' \
  "task-orchestrator: OLD Step 4 single-outcome return (PR URL + SHA only) gone"

chk_absent "$ORCH" \
  '<docs-pr-url>` | `blocked' \
  "task-orchestrator: OLD status line (one oversized status, untagged) gone"

# ---------------------------------------------------------------------------
# Group 12: agents/pr-author.md + skills/pr-flow/SKILL.md — the backend-tracked
# carve-out is INHERITED by the sub-steps that follow it.
#
# Exit-1 sub-step 1 already carved out backend-tracked projects (`github-project`
# / `linear` — no `IN_PROGRESS.md` at the repo root: skip the edit), but sub-steps
# 2 and 3 did not inherit it: "Commit the marker" and "code commit + marker
# commit" were unconditional, so on a backend-tracked project the agent was told
# to commit a file it had just been told not to write. Same class as #30 defect 1
# — an internally impossible instruction the agent has to improvise around. This
# lands on the backend THIS repo uses, so it is not hypothetical.
#
# `pr-author.md`'s Output block was already correct (group 9 asserts its
# `not moved — tracking lives in the backend` variant) and is deliberately
# unchanged here.
# ---------------------------------------------------------------------------

chk_prose "$PR_AUTHOR" \
  'this sub-step is skipped too' \
  "pr-author: exit-1 sub-step 2 (commit the marker) inherits the backend-tracked carve-out"

chk_prose "$PR_AUTHOR" \
  'never fabricate an empty commit' \
  "pr-author: forbids fabricating an empty commit when sub-step 1 wrote nothing"

chk_prose "$PR_AUTHOR" \
  'sub-step 2 produced no marker' \
  "pr-author: exit-1 sub-step 3 inherits it too — the branch carries the code commit alone"

chk_prose "$PR_AUTHOR" \
  'never both, and on a backend-tracked project' \
  "pr-author: step 5's tracking-XOR-marker invariant admits the backend-tracked third case"

chk_prose "$PR_AUTHOR" \
  'so the branch carries the code commit alone' \
  "pr-author: step 5 states the backend-tracked exit-1 branch carries neither bookkeeping commit"

chk_prose "$PR_AUTHOR" \
  'counts two files' \
  "pr-author: the --pr-mode overcount is two files (the tracking move touches IN_PROGRESS + HISTORY)"

chk_prose "$SKILL" \
  'the edit and the commit are skipped' \
  "pr-flow: the OVERSIZE bullet skips BOTH the edit and the commit on a backend-tracked project"

chk_prose "$SKILL" \
  'the branch carries the code commit alone' \
  "pr-flow: states what the backend-tracked exit-1 branch actually carries"

# Regression guards — the unconditional claims must be gone. The second one is
# the re-anchor for the group-3 `code commit + marker commit, no tracking move`
# assertion: that literal survives cycle 2 verbatim, so only this negative
# proves the carve-out parenthetical is still attached to it.
chk_absent "$PR_AUTHOR" \
  'never both.' \
  "pr-author: OLD unconditional 'never both.' absolute (no backend-tracked case) gone"

chk_absent "$PR_AUTHOR" \
  'no tracking move — belongs on origin' \
  "pr-author: OLD unconditional sub-step 3 claim (marker commit always exists) gone"

chk_absent "$PR_AUTHOR" \
  'counts roughly one file' \
  "pr-author: OLD 'roughly one file' undercount gone"

chk_absent "$SKILL" \
  '(skip this edit on a project' \
  "pr-flow: OLD edit-only carve-out (the commit did not inherit it) gone"

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
