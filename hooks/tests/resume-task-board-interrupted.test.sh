#!/usr/bin/env bash
#
# Regression test for #66 — /atelier:resume-task board-interrupted-resume
# entry point (non-`files` backend).
#
# Before #66, a non-`files` backend (github-project / linear) had no way to
# resume a claim that died between /atelier:next-task's moveTask (step 6)
# and pr-author opening a PR (step 8): the board item was left "In Progress"
# with no IN_PROGRESS.md entry (there is none on this backend) and no open
# PR, so none of resume-task.md's three pre-#66 entry points (interrupted /
# blocked / pr-open, all anchored on IN_PROGRESS.md or an open PR) could
# find it, and a re-claim attempt through next-task just mis-reported a
# race condition. #66 adds a fourth entry point — board-interrupted-resume —
# that anchors on the backend's own Status field instead.
#
# Asserts commands/resume-task.md encodes this so a future careless edit
# that silently drops or contradicts the contract fails CI.
#
# Contract invariants asserted:
#   Group 1 — Frontmatter grants (#66)
#     - Bash(git worktree:*), Bash(gh api graphql:*), Bash(atelier-task-backend:*)
#   Group 2 — Entry-point catalog + backend-aware anchor
#     - board-interrupted-resume named as a fourth, non-files-only entry point
#     - step 1 captures BACKEND via atelier-task-backend
#     - step 2 branches on backend: files anchors on IN_PROGRESS.md, non-files
#       anchors on the board's Status field
#   Group 3 — Step 2 non-files branching (Status x open-PR combination)
#     - Status in inProgress + open PR      -> PR-open-resume
#     - Status in inProgress + no open PR   -> board-interrupted-resume, goes to step 3b
#     - Status not in inProgress            -> not in flight here, stop
#   Group 4 — Step 3b worktree resolve-or-recreate
#     - looks for the worktree via `git wt list` / `git worktree list --porcelain`
#     - worktree found -> resume_mode: interrupted, use as-is
#     - worktree not found -> recreate via `git wt switch task/<id>-<slug> --from origin/<base>`
#     - never re-issues moveTask (both in step 3b body and Hard refusals)
#   Group 5 — Step 5 hand-off carries board-interrupted-resume through cleanly
#     - worktree_path sourced from step 3b for this mode
#     - resume_mode passed is `interrupted` (identical to plain interrupted-resume)
#     - resident plan-storage carry via getPlan(id), main_checkout_root omitted
#   Group 6 — Output block + hard refusals
#     - Mode enum in the output status block includes board-interrupted-resume
#     - "no anchor" hard refusal covers the non-files Status-field case
#   Group 7 — No-regression: pre-#66 entry points still documented
#     - interrupted-resume, blocked-resume, pr-open-resume still present
#     - IN_PROGRESS.md-anchored files-backend branch of step 2 unchanged
#
# Hermetic: greps committed prose only; no network, no jq, no temp dirs.
#
# Run:  hooks/tests/resume-task-board-interrupted.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESUME_TASK="$REPO_ROOT/commands/resume-task.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_prose <file> <fixed-string> <label>
# Passes when the fixed string is present in the file; fails otherwise.
chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF -e "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

# chk_absent <file> <fixed-string> <label>
# Passes when the fixed string is ABSENT in the file; fails otherwise.
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF -e "$pattern" "$file" 2>/dev/null; then
    fail "$label — token '$pattern' found but should be absent in $file"
  else
    pass "$label"
  fi
}

if [ -f "$RESUME_TASK" ]; then
  pass "file: commands/resume-task.md exists"
else
  fail "file: commands/resume-task.md not found"
fi

# ---------------------------------------------------------------------------
# Group 1: Frontmatter grants (#66)
# ---------------------------------------------------------------------------

chk_prose "$RESUME_TASK" 'Bash(git worktree:*)' \
  "frontmatter: Bash(git worktree:*) in allowed-tools (#66)"

chk_prose "$RESUME_TASK" 'Bash(gh api graphql:*)' \
  "frontmatter: Bash(gh api graphql:*) in allowed-tools (#66)"

chk_prose "$RESUME_TASK" 'Bash(atelier-task-backend:*)' \
  "frontmatter: Bash(atelier-task-backend:*) in allowed-tools (#66)"

# ---------------------------------------------------------------------------
# Group 2: Entry-point catalog + backend-aware anchor
# ---------------------------------------------------------------------------

chk_prose "$RESUME_TASK" '**Board-interrupted-resume (non-`files` backend only, #66).**' \
  "entry-point catalog: board-interrupted-resume named as a fourth entry point"

chk_prose "$RESUME_TASK" 'BACKEND="$(atelier-task-backend "$MAIN_ROOT")"' \
  "step 1: BACKEND captured via atelier-task-backend"

chk_prose "$RESUME_TASK" '### 2. Locate the task entry — backend-aware anchor' \
  "step 2: retitled as backend-aware anchor"

chk_prose "$RESUME_TASK" '**Non-`files` backend (`github-project` / `linear`) — the board'"'"'s Status field is the anchor, cross-checked against the open-PR registry (#66):**' \
  "step 2: non-files branch anchors on the board's Status field"

# ---------------------------------------------------------------------------
# Group 3: Step 2 non-files branching (Status x open-PR combination)
# ---------------------------------------------------------------------------

chk_prose "$RESUME_TASK" '**and an open PR exists** → **PR-open-resume mode**' \
  "step 2 non-files: Status in inProgress + open PR -> PR-open-resume"

chk_prose "$RESUME_TASK" '**Status is in `inProgress` and no open PR exists** → **board-interrupted-resume mode**' \
  "step 2 non-files: Status in inProgress + no open PR -> board-interrupted-resume"

chk_prose "$RESUME_TASK" 'Skip step 3; go to step 3b.' \
  "step 2 non-files: board-interrupted-resume routes to step 3b"

chk_prose "$RESUME_TASK" '**Status is not in `inProgress`**' \
  "step 2 non-files: Status not in inProgress -> not in flight here"

# ---------------------------------------------------------------------------
# Group 4: Step 3b worktree resolve-or-recreate
# ---------------------------------------------------------------------------

chk_prose "$RESUME_TASK" '### 3b. Board-interrupted-resume — resolve or recreate the worktree (non-`files` backend, #66)' \
  "step 3b: heading present"

chk_prose "$RESUME_TASK" 'git wt list   # or: git worktree list --porcelain' \
  "step 3b: looks for the worktree via git wt list / git worktree list --porcelain"

chk_prose "$RESUME_TASK" '**Worktree found** → the common case' \
  "step 3b: worktree-found branch uses it as-is"

chk_prose "$RESUME_TASK" 'git wt switch task/<id>-<slug> --from origin/<base>' \
  "step 3b: worktree-not-found branch recreates via git wt switch --from origin/<base>"

chk_prose "$RESUME_TASK" 'Proceed to step 5 with `resume_mode: interrupted`.' \
  "step 3b: both worktree outcomes proceed with resume_mode: interrupted"

chk_prose "$RESUME_TASK" 'Either way, **do not** call `moveTask` again here' \
  "step 3b: never re-issues moveTask"

chk_prose "$RESUME_TASK" '**Never** call `moveTask` again during board-interrupted-resume (step 3b, #66)' \
  "Hard refusals: never call moveTask again during board-interrupted-resume"

# ---------------------------------------------------------------------------
# Group 5: Step 5 hand-off carries board-interrupted-resume through cleanly
# ---------------------------------------------------------------------------

chk_prose "$RESUME_TASK" 'the worktree found or recreated in step 3b for board-interrupted-resume — a non-`files`-backend task' \
  "step 5: worktree_path sourced from step 3b for board-interrupted-resume"

chk_prose "$RESUME_TASK" 'Board-interrupted-resume (step 3b, non-`files` backend, #66) also passes `interrupted`' \
  "step 5: board-interrupted-resume passes resume_mode: interrupted (identical orchestrator handling)"

chk_prose "$RESUME_TASK" 'Call `getPlan(id)` via the `roadmap-tracking-flow` skill and pass its **Approach**, **Affected areas**, and **Acceptance criteria** **inline**' \
  "step 5: resident plan-storage carried inline via getPlan(id)"

chk_prose "$RESUME_TASK" 'Omit `main_checkout_root` for this mode — it has no meaning here, mirroring `/atelier:next-task` step 8.' \
  "step 5: main_checkout_root omitted under resident plan storage"

# ---------------------------------------------------------------------------
# Group 6: Output block + hard refusals
# ---------------------------------------------------------------------------

chk_prose "$RESUME_TASK" 'Mode:           blocked-resume | interrupted-resume | board-interrupted-resume | pr-open-resume' \
  "output block: Mode enum includes board-interrupted-resume"

chk_prose "$RESUME_TASK" 'For a non-`files` backend it means the board'"'"'s Status field is not in the `inProgress` bucket **and** no open `task/<id>-*` PR exists' \
  "Hard refusals: no-anchor refusal covers the non-files Status-field case"

# ---------------------------------------------------------------------------
# Group 7: No-regression — pre-#66 entry points still documented
# ---------------------------------------------------------------------------

chk_prose "$RESUME_TASK" '**Interrupted-resume.**' \
  "no-regression: interrupted-resume entry point still documented"

chk_prose "$RESUME_TASK" '**Blocked-resume.**' \
  "no-regression: blocked-resume entry point still documented"

chk_prose "$RESUME_TASK" '**PR-open-resume.**' \
  "no-regression: pr-open-resume entry point still documented"

chk_prose "$RESUME_TASK" 'Read `IN_PROGRESS.md`. Search for a heading line that contains the task id' \
  "no-regression: files-backend step 2 branch (IN_PROGRESS.md anchor) unchanged"

chk_absent "$RESUME_TASK" 'The command **auto-detects** which mode applies from the state of `IN_PROGRESS.md` and (for PR-open-resume) the presence of an open PR. The operator does not pick.' \
  "no-regression: pre-#66 auto-detect summary (files-only wording) superseded by backend-aware wording"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "resume-task-board-interrupted (#66): all assertions passed."
  exit 0
else
  echo "resume-task-board-interrupted (#66): $fails assertion(s) failed."
  exit 1
fi
