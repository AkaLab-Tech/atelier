#!/usr/bin/env bash
#
# Regression test for M9.3c — plan-task planning gate: Project Ready field.
#
# Asserts that `commands/plan-task.md` encodes the github-project backend
# contract introduced in #20c so that a future careless edit that silently
# drops or contradicts these invariants fails CI.
#
# Contract invariants asserted:
#   Group 1 — Frontmatter grants
#     - Bash(atelier-task-backend:*) present in allowed-tools
#     - Skill present in allowed-tools (drives the setReady write)
#   Group 2 — Phase 1 backend resolution + guards
#     - atelier-task-backend invoked to resolve backend
#     - branches on files vs non-files (github-project)
#     - .roadmap.json presence substitutes for ROADMAP.md-presence guard
#     - non-files clean-paths check guards .plan only (no ROADMAP.md)
#   Group 3 — Phase 4 ready flip (heart of #20c)
#     - non-files calls setReady(id, true) via roadmap-tracking-flow skill
#     - github-project commits .plan only (git add .plan, not ROADMAP.md)
#     - unchanged commit message present
#     - §16.5 cited (gate-split spec)
#     - .plan/<id>.md stays a committed tracked repo file for both backends
#   Group 4 — Phase 5 discard
#     - github-project discard reverts only .plan (no ROADMAP.md)
#     - on mid-Phase-4 failure, calls setReady(id, false) to un-set
#   Group 5 — Interaction mode (interactive-only for BOTH backends)
#     - headless/--yes/ATELIER_AUTO: write draft and stop without flipping Ready
#   Group 6 — New hard refusal
#     - "never edit ROADMAP.md for a non-files backend" refusal present
#   Group 7 — No-regression (files path unchanged)
#     - [ready] token still referenced for the files backend
#     - files Phase 4 still does git add ROADMAP.md .plan
#
# Hermetic: greps committed prose only; no network, no jq, no temp dirs.
#
# Run:  hooks/tests/plan-task-github-project-ready.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLAN_TASK="$REPO_ROOT/commands/plan-task.md"

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
# Passes when the fixed string is ABSENT in the file; fails otherwise.
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    fail "$label — token '$pattern' found but should be absent in $file"
  else
    pass "$label"
  fi
}

# ---------------------------------------------------------------------------
# Group 1: Frontmatter grants
# ---------------------------------------------------------------------------

chk_prose "$PLAN_TASK" 'Bash(atelier-task-backend:*)' \
  "frontmatter: Bash(atelier-task-backend:*) in allowed-tools"

chk_prose "$PLAN_TASK" 'Skill' \
  "frontmatter: Skill in allowed-tools (drives setReady write)"

# ---------------------------------------------------------------------------
# Group 2: Phase 1 backend resolution + guards
# ---------------------------------------------------------------------------

chk_prose "$PLAN_TASK" 'atelier-task-backend <project-root>' \
  "Phase 1: atelier-task-backend invoked to resolve backend"

chk_prose "$PLAN_TASK" '`files` backend:' \
  "Phase 1: branches on files backend"

chk_prose "$PLAN_TASK" 'non-`files` backend' \
  "Phase 1: branches on non-files (github-project) backend"

chk_prose "$PLAN_TASK" 'the presence of `.roadmap.json` (which the backend resolver requires) substitutes for `ROADMAP.md` presence' \
  "Phase 1: .roadmap.json presence substitutes for ROADMAP.md-presence guard"

chk_prose "$PLAN_TASK" '`git status --porcelain .plan` only — there is no `ROADMAP.md` to guard' \
  "Phase 1: non-files clean-paths check guards .plan only (no ROADMAP.md)"

# ---------------------------------------------------------------------------
# Group 3: Phase 4 ready flip
# ---------------------------------------------------------------------------

chk_prose "$PLAN_TASK" 'setReady(id, true)' \
  "Phase 4: non-files calls setReady(id, true)"

chk_prose "$PLAN_TASK" 'call the backend'"'"'s `setReady(id, true)` operation via the `roadmap-tracking-flow` skill' \
  "Phase 4: setReady driven through roadmap-tracking-flow skill"

chk_prose "$PLAN_TASK" 'git add .plan' \
  "Phase 4: github-project commits .plan only"

chk_prose "$PLAN_TASK" 'chore(plan): mark <task_id> ready with approved plan' \
  "Phase 4: conventional commit message unchanged"

chk_prose "$PLAN_TASK" '§16.5' \
  "Phase 4: §16.5 cited (gate-split spec)"

chk_prose "$PLAN_TASK" '.plan/<id>.md` is committed' \
  "Phase 4: .plan/<id>.md stays a committed tracked repo file"

# ---------------------------------------------------------------------------
# Group 4: Phase 5 discard
# ---------------------------------------------------------------------------

chk_prose "$PLAN_TASK" 'There is no `ROADMAP.md` to revert.' \
  "Phase 5: github-project discard reverts only .plan (no ROADMAP.md)"

chk_prose "$PLAN_TASK" 'setReady(id, false)' \
  "Phase 5: on mid-Phase-4 failure, calls setReady(id, false) to un-set"

chk_prose "$PLAN_TASK" 'call `setReady(id, false)` via the `roadmap-tracking-flow` skill to un-set the `Ready` field' \
  "Phase 5: setReady(id, false) un-set driven through roadmap-tracking-flow skill"

# ---------------------------------------------------------------------------
# Group 5: Interaction mode (interactive-only for BOTH backends)
# ---------------------------------------------------------------------------

chk_prose "$PLAN_TASK" '`$ARGUMENTS` carries `--yes`/`-y`, or `ATELIER_AUTO` is set' \
  "interaction mode: headless/--yes/ATELIER_AUTO detection"

chk_prose "$PLAN_TASK" '**do not auto-approve**: run the planner, write the draft, and **stop**' \
  "interaction mode: write draft and stop without flipping Ready"

chk_prose "$PLAN_TASK" 'In non-interactive mode, stop after writing the draft regardless of backend' \
  "interaction mode: stop applies for BOTH backends"

chk_prose "$PLAN_TASK" '"approval remains interactive-only, never headless"' \
  "interaction mode: §16.5 interactive-only quoted"

# ---------------------------------------------------------------------------
# Group 6: New hard refusal
# ---------------------------------------------------------------------------

chk_prose "$PLAN_TASK" '**Never** edit `ROADMAP.md` for a non-`files` backend — there is none; the `Ready` flip goes through the backend (`setReady`) only.' \
  "hard refusal: never edit ROADMAP.md for a non-files backend"

# ---------------------------------------------------------------------------
# Group 7: No-regression — files backend path unchanged
# ---------------------------------------------------------------------------

chk_prose "$PLAN_TASK" '[ready]' \
  "no-regression: [ready] token still referenced for files backend"

chk_prose "$PLAN_TASK" 'git add ROADMAP.md .plan' \
  "no-regression: files Phase 4 still does git add ROADMAP.md .plan"

# ---------------------------------------------------------------------------
# Group 8: planStorage=local (TASK_027) — Ready set without a plan commit
# ---------------------------------------------------------------------------
#
# Under planStorage=local, the github-project backend still flips the Ready
# field but commits NOTHING (the plan file is gitignored, and there is no
# ROADMAP.md). Asserts the local-mode branch documents that split.

chk_prose "$PLAN_TASK" 'planStorage=local' \
  "local mode: planStorage=local branch present"

chk_prose "$PLAN_TASK" '`github-project` backend, `local`:' \
  "local mode: github-project local sub-case documented"

chk_prose "$PLAN_TASK" 'make **no commit at all**' \
  "local mode: github-project sets Ready but makes no commit"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "plan-task-github-project-ready (M9.3c): all assertions passed."
  exit 0
else
  echo "plan-task-github-project-ready (M9.3c): $fails assertion(s) failed."
  exit 1
fi
