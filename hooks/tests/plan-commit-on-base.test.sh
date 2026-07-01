#!/usr/bin/env bash
#
# Regression test for #27 — plan commit dropped when unpushed.
#
# Asserts that `commands/plan-task.md`, `commands/next-task.md`, and
# `agents/task-orchestrator.md` encode the plan-on-base contract introduced in
# #27 so that a future careless edit that silently drops or contradicts these
# invariants fails CI.
#
# Contract invariants asserted:
#   Group 1 — commands/plan-task.md: claimability contract
#     - Next: line states origin/<base> precondition
#     - "only claimable once it is on origin/<base>" sense present
#     - "never push to a protected branch directly" still present (no regression)
#     - epic rewrite + .plan sub-tasks must land together documented
#   Group 2 — commands/next-task.md: plan-on-base guard
#     - refusal message token "is not on origin/<base>" present
#     - refusal message token "never landed" present
#     - refusal message token "push/merge the plan commit" present
#     - new Hard-refusals bullet (stale ROADMAP state / drop the decomposition)
#     - Bash(git cat-file:*) in allowed-tools
#   Group 3 — agents/task-orchestrator.md: plan-not-on-base backstop
#     - "plan not on base" backstop sentence present
#   Group 4 — behavioral: git cat-file probe detects dropped-plan condition
#     - probe exits non-zero when .plan/<id>.md committed locally but not pushed
#     - probe exits zero after push to origin
#
# Hermetic: prose assertions grep committed files only; behavioral assertion
# uses a local bare repo as origin remote — no network, no jq, no temp dirs
# persisted after exit.
#
# Run:  hooks/tests/plan-commit-on-base.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLAN_TASK="$REPO_ROOT/commands/plan-task.md"
NEXT_TASK="$REPO_ROOT/commands/next-task.md"
TASK_ORCH="$REPO_ROOT/agents/task-orchestrator.md"

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
# Group 1: commands/plan-task.md — claimability contract
# ---------------------------------------------------------------------------

chk_prose "$PLAN_TASK" 'only claimable once it is on origin/<base>' \
  "plan-task: claimability contract — 'only claimable once it is on origin/<base>' present"

chk_prose "$PLAN_TASK" 'push/merge this commit to origin/<base> first' \
  "plan-task: Next: line precondition — 'push/merge this commit to origin/<base> first' present"

chk_prose "$PLAN_TASK" 'never push to a protected branch directly' \
  "plan-task: no-regression — 'never push to a protected branch directly' still present"

chk_prose "$PLAN_TASK" 'epic rewrite and every `.plan/<sub-id>.md` must land together' \
  "plan-task: decomposed case — epic rewrite + sub-plan files land together documented"

# ---------------------------------------------------------------------------
# Group 2: commands/next-task.md — plan-on-base guard
# ---------------------------------------------------------------------------

chk_prose "$NEXT_TASK" 'is not on origin/<base>' \
  "next-task: refusal message token 'is not on origin/<base>' present"

chk_prose "$NEXT_TASK" 'never landed' \
  "next-task: refusal message token 'never landed' present"

chk_prose "$NEXT_TASK" 'push/merge the plan commit' \
  "next-task: refusal message token 'push/merge the plan commit' present"

chk_prose "$NEXT_TASK" 'would otherwise operate on stale ROADMAP state and drop the decomposition' \
  "next-task: Hard-refusals bullet — stale ROADMAP state / drop the decomposition"

chk_prose "$NEXT_TASK" 'Bash(git cat-file:*)' \
  "next-task: frontmatter allowed-tools contains Bash(git cat-file:*)"

# ---------------------------------------------------------------------------
# Group 3: agents/task-orchestrator.md — plan-not-on-base backstop
# ---------------------------------------------------------------------------

chk_prose "$TASK_ORCH" 'plan commit was not on `origin/<base>` at cut time' \
  "task-orchestrator: plan-not-on-base backstop sentence present"

chk_prose "$TASK_ORCH" 'second independent backstop' \
  "task-orchestrator: backstop described as second independent backstop"

# ---------------------------------------------------------------------------
# Group 4: behavioral — git cat-file probe detects dropped-plan condition
# ---------------------------------------------------------------------------

# Build a throwaway hermetic git environment: a local bare repo as "origin",
# a base branch with no .plan/ committed, and a local commit that adds
# .plan/27.md without pushing.  Assert the probe fails (non-zero) before push
# and passes (zero) after push.

_tmpdir="$(mktemp -d)"
_cleanup() { rm -rf "$_tmpdir"; }
trap _cleanup EXIT

_bare="$_tmpdir/origin.git"
_repo="$_tmpdir/repo"

# Create the bare "origin" repo.
git init --bare "$_bare" -q

# Clone it as the working repo.
git clone --quiet "$_bare" "$_repo" 2>/dev/null

# Configure a local git identity so commits succeed in CI.
git -C "$_repo" config user.email "test@atelier.local"
git -C "$_repo" config user.name "Atelier Test"

# Create an initial commit on the base branch so origin/main exists.
mkdir -p "$_repo/.plan"
printf 'initial\n' > "$_repo/README.md"
git -C "$_repo" add README.md
git -C "$_repo" commit -q -m "chore: initial"
git -C "$_repo" push -q origin HEAD:main

# Commit .plan/27.md ONLY locally — do not push.
printf '# Plan 27\n' > "$_repo/.plan/27.md"
git -C "$_repo" add .plan/27.md
git -C "$_repo" commit -q -m "chore(plan): mark #27 ready with approved plan"

# Probe: .plan/27.md is present locally but NOT on origin/main — must fail.
if git -C "$_repo" cat-file -e origin/main:.plan/27.md 2>/dev/null; then
  fail "behavioral: probe must exit non-zero before push (dropped-plan condition not detected)"
else
  pass "behavioral: probe exits non-zero — dropped-plan condition detected correctly"
fi

# Push the plan commit to origin/main.
git -C "$_repo" push -q origin HEAD:main

# Probe: .plan/27.md is now on origin/main — must succeed.
if git -C "$_repo" cat-file -e origin/main:.plan/27.md 2>/dev/null; then
  pass "behavioral: probe exits zero after push — plan-on-base condition confirmed"
else
  fail "behavioral: probe must exit zero after push (plan present on origin/main)"
fi

# ---------------------------------------------------------------------------
# Group 5: planStorage=local contract (TASK_027) — prose invariants
# ---------------------------------------------------------------------------
#
# The committed-mode invariants above must stay intact (Groups 1–3); the local
# mode ADDS a second contract in which the plan is a gitignored file carried
# inline, and the plan-on-base guard is dropped.

chk_prose "$PLAN_TASK" 'never `git add`/commit `.plan/<id>.md`' \
  "plan-task: local mode never commits the plan file"

chk_prose "$PLAN_TASK" 'gitignored, never-committed' \
  "plan-task: local plan described as gitignored, never-committed"

chk_prose "$NEXT_TASK" 'Under `PLAN_STORAGE=local`, skip the plan-on-base guard entirely' \
  "next-task: local mode drops the plan-on-base guard"

chk_prose "$NEXT_TASK" 'git rev-parse --show-toplevel' \
  "next-task: captures the main-checkout root via git rev-parse --show-toplevel"

chk_prose "$NEXT_TASK" 'never copies gitignored/untracked files' \
  "next-task: documents the root cause (worktree add drops ignored files)"

chk_prose "$NEXT_TASK" 'planStorage=committed' \
  "next-task: no-regression — committed mode still named as the default path"

chk_prose "$TASK_ORCH" 'absent from the worktree by design' \
  "task-orchestrator: local plan is absent from the worktree by design"

chk_prose "$TASK_ORCH" 'committed-mode abort above **must not fire** here' \
  "task-orchestrator: committed-mode abort suppressed under local mode"

RESUME_TASK="$REPO_ROOT/commands/resume-task.md"
chk_prose "$RESUME_TASK" 'the inline copy is the only plan source on a `local`-mode resume' \
  "resume-task: local mode carries the plan inline"

# ---------------------------------------------------------------------------
# Group 6: behavioral — gitignored local plan + worktree isolation (TASK_027)
# ---------------------------------------------------------------------------
#
# Proves the whole reason planStorage=local needs the carry-inline contract:
# a gitignored plan physically persists ONLY in the main checkout; `git
# worktree add` does a clean checkout of the tree and does NOT copy it. So the
# committed-mode plan-on-base probe would (correctly) fail for a valid local
# plan — which is exactly why the guard is dropped and the plan is read locally.

_main="$_tmpdir/main"          # nested under $_tmpdir so the EXIT trap cleans it
_bare2="$_tmpdir/origin2.git"

git init --bare "$_bare2" -q
git clone --quiet "$_bare2" "$_main" 2>/dev/null
git -C "$_main" config user.email "test@atelier.local"
git -C "$_main" config user.name "Atelier Test"

# Base commit: .gitignore ignores .plan/, plus a README so origin/main exists.
printf '.plan/\n' > "$_main/.gitignore"
printf 'initial\n' > "$_main/README.md"
git -C "$_main" add .gitignore README.md
git -C "$_main" commit -q -m "chore: initial"
git -C "$_main" push -q origin HEAD:main

# Operator writes a gitignored, never-committed plan in the main checkout.
mkdir -p "$_main/.plan"
printf '# Plan 42\nApproach: local-only\n' > "$_main/.plan/42.md"

# It is readable at the main-checkout root (the plan source under local mode).
if [ -r "$_main/.plan/42.md" ]; then
  pass "behavioral(local): plan readable at main-checkout root"
else
  fail "behavioral(local): plan must be readable at main-checkout root"
fi

# It is gitignored — `git status --porcelain .plan` reports nothing for it.
if [ -z "$(git -C "$_main" status --porcelain .plan)" ]; then
  pass "behavioral(local): plan is gitignored (absent from git status)"
else
  fail "behavioral(local): plan must be gitignored (git status should be silent)"
fi

# Committed-mode probe FAILS (the plan is not on origin) — this is why local
# mode drops the plan-on-base guard rather than refusing a valid plan.
if git -C "$_main" cat-file -e origin/main:.plan/42.md 2>/dev/null; then
  fail "behavioral(local): committed probe unexpectedly found the local plan on origin"
else
  pass "behavioral(local): committed probe fails for a local plan — guard correctly dropped"
fi

# Cut a worktree from origin/main (as /next-task does).
git -C "$_main" worktree add -q --detach "$_tmpdir/wt" origin/main 2>/dev/null

# ROOT CAUSE: the gitignored plan is NOT copied into the worktree.
if [ -e "$_tmpdir/wt/.plan/42.md" ]; then
  fail "behavioral(local): worktree unexpectedly contains the gitignored plan"
else
  pass "behavioral(local): worktree does NOT contain the gitignored plan — root cause confirmed"
fi

# The carry-the-local-plan contract: the main-root copy still reads fine, so
# the chain can carry it inline in the orchestrator briefing.
if [ -r "$_main/.plan/42.md" ]; then
  pass "behavioral(local): main-root plan still readable — carry-inline path viable"
else
  fail "behavioral(local): main-root plan must remain readable for carry-inline"
fi

# Detach the worktree so the EXIT trap's rm -rf does not leave a registered ref.
git -C "$_main" worktree remove --force "$_tmpdir/wt" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "plan-commit-on-base (#27): all assertions passed."
  exit 0
else
  echo "plan-commit-on-base (#27): $fails assertion(s) failed."
  exit 1
fi
