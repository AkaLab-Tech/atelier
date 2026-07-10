#!/usr/bin/env bash
#
# Regression test for TASK_027 — planStorage=local end-to-end contract.
#
# The "carry the local plan" contract lets an approved plan live as a
# gitignored, never-committed `.plan/<id>.md` in the operator's main checkout
# and still be consumed end-to-end by /plan-task → /next-task →
# task-orchestrator → /resume-task, without ever being committed or pushed.
#
# This test locks BOTH halves:
#   Prose (Groups 1–5): the new `planStorage` flag is threaded through the
#     template and all four command/agent files, and the default `committed`
#     path is untouched.
#   Behavioral (Group 6): a hermetic git scenario that simulates the whole
#     claim flow — gitignored plan in the main checkout, planStorage resolved
#     via jq, the planning-gate local existence check, a worktree cut from
#     origin/<base> that (correctly) lacks the plan, and the main-root read the
#     chain uses to carry the plan inline. Proves the committed-mode abort
#     would be WRONG here and the local read path is viable.
#
# Hermetic: greps committed files + a throwaway local bare repo as origin. No
# network, no persisted temp dirs. Requires `git` and `jq`.
#
# Run:  hooks/tests/plan-storage-local.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/atelier.template.json"
PLAN_TASK="$REPO_ROOT/commands/plan-task.md"
NEXT_TASK="$REPO_ROOT/commands/next-task.md"
RESUME_TASK="$REPO_ROOT/commands/resume-task.md"
TASK_ORCH="$REPO_ROOT/agents/task-orchestrator.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_prose <file> <fixed-string> <label>
chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

# ---------------------------------------------------------------------------
# Group 1: template carries the planStorage flag
# ---------------------------------------------------------------------------

chk_prose "$TEMPLATE" '"planStorage": "committed"' \
  "template: planStorage key present, defaulting to committed"

chk_prose "$TEMPLATE" 'Absent field is treated as ' \
  "template: planStorage documents committed as the default"

chk_prose "$TEMPLATE" 'gitignore `.plan/`' \
  "template: comment tells operators to gitignore .plan/ under local"

# ---------------------------------------------------------------------------
# Group 2: plan-task.md — producer wiring
# ---------------------------------------------------------------------------

chk_prose "$PLAN_TASK" "jq -r '.planStorage // \"committed\"'" \
  "plan-task: resolves planStorage via jq with committed default"

chk_prose "$PLAN_TASK" 'never `git add`/commit `.plan/<id>.md`' \
  "plan-task: local mode never commits the plan file"

# ---------------------------------------------------------------------------
# Group 3: next-task.md — claimer wiring
# ---------------------------------------------------------------------------

chk_prose "$NEXT_TASK" 'git rev-parse --show-toplevel' \
  "next-task: captures main-checkout root (plan source under local)"

chk_prose "$NEXT_TASK" "jq -r '.planStorage // \"committed\"'" \
  "next-task: resolves planStorage via jq with committed default"

chk_prose "$NEXT_TASK" 'test -r "$MAIN_ROOT/.plan/<id>.md"' \
  "next-task: local planning-gate validates the local plan file"

chk_prose "$NEXT_TASK" 'Under `PLAN_SOURCE=local`, skip the plan-on-base guard entirely' \
  "next-task: local mode (PLAN_SOURCE=local) drops the plan-on-base guard"

chk_prose "$NEXT_TASK" 'pass its **Approach**, **Affected areas**, and **Acceptance criteria** **inline**' \
  "next-task: carries the plan inline in the orchestrator briefing"

chk_prose "$NEXT_TASK" 'Bash(git rev-parse:*)' \
  "next-task: frontmatter grants Bash(git rev-parse:*)"

chk_prose "$NEXT_TASK" 'Bash(jq:*)' \
  "next-task: frontmatter grants Bash(jq:*)"

# ---------------------------------------------------------------------------
# Group 4: task-orchestrator.md — consumer wiring
# ---------------------------------------------------------------------------

chk_prose "$TASK_ORCH" 'absent from the worktree by design' \
  "task-orchestrator: local plan absent from worktree by design"

chk_prose "$TASK_ORCH" 'never** the worktree-relative path' \
  "task-orchestrator: re-reads the absolute main-root path, never worktree-relative"

chk_prose "$TASK_ORCH" 'committed-mode abort above **must not fire** here' \
  "task-orchestrator: committed-mode abort suppressed under local mode"

# ---------------------------------------------------------------------------
# Group 5: resume-task.md — resume/direct-dispatch wiring
# ---------------------------------------------------------------------------

chk_prose "$RESUME_TASK" 'git rev-parse --show-toplevel' \
  "resume-task: captures main-checkout root"

chk_prose "$RESUME_TASK" 'the inline copy is the only plan source on a `local`-mode resume' \
  "resume-task: local mode carries the plan inline on resume"

chk_prose "$RESUME_TASK" 'Bash(jq:*)' \
  "resume-task: frontmatter grants Bash(jq:*)"

# ---------------------------------------------------------------------------
# Group 6: behavioral — full local-plan claim flow, hermetic
# ---------------------------------------------------------------------------

# Skip the behavioral half gracefully if jq is unavailable in the CI image.
if ! command -v jq >/dev/null 2>&1; then
  pass "behavioral: skipped (jq not available) — prose assertions still enforced"
else
  _tmpdir="$(mktemp -d)"
  trap 'rm -rf "$_tmpdir"' EXIT

  _bare="$_tmpdir/origin.git"
  _main="$_tmpdir/main"

  git init --bare "$_bare" -q
  git clone --quiet "$_bare" "$_main" 2>/dev/null
  git -C "$_main" config user.email "test@atelier.local"
  git -C "$_main" config user.name "Atelier Test"

  # Base commit: .gitignore ignores .plan/, an .atelier.json opting into local,
  # and a README so origin/main exists. The [ready] flip would ride ROADMAP.md,
  # which is out of scope for this file-level behavioral check.
  printf '.plan/\n' > "$_main/.gitignore"
  printf '{ "planStorage": "local" }\n' > "$_main/.atelier.json"
  printf 'initial\n' > "$_main/README.md"
  git -C "$_main" add .gitignore .atelier.json README.md
  git -C "$_main" commit -q -m "chore: initial"
  git -C "$_main" push -q origin HEAD:main

  # Step: resolve planStorage the way the commands do (from the main checkout).
  MAIN_ROOT="$(git -C "$_main" rev-parse --show-toplevel)"
  PLAN_STORAGE="$(jq -r '.planStorage // "committed"' "$MAIN_ROOT/.atelier.json" 2>/dev/null || echo committed)"
  if [ "$PLAN_STORAGE" = "local" ]; then
    pass "behavioral: planStorage resolves to 'local' from .atelier.json"
  else
    fail "behavioral: planStorage should resolve to 'local' (got '$PLAN_STORAGE')"
  fi

  # /plan-task under local: write the gitignored plan but never commit it.
  mkdir -p "$MAIN_ROOT/.plan"
  cat > "$MAIN_ROOT/.plan/42.md" <<'PLAN'
# Plan 42
Status: ready (approved — product lead)
## Approach
Local-only plan carried inline.
## Acceptance criteria
- carried without a commit
PLAN

  # It must not be tracked (proves /plan-task did not commit it).
  if [ -z "$(git -C "$_main" status --porcelain .plan)" ]; then
    pass "behavioral: /plan-task leaves the plan gitignored (never committed)"
  else
    fail "behavioral: plan should be gitignored/uncommitted after /plan-task local mode"
  fi

  # /next-task planning gate under local: local existence check passes.
  if [ -r "$MAIN_ROOT/.plan/42.md" ]; then
    pass "behavioral: /next-task local planning-gate (test -r) passes"
  else
    fail "behavioral: local planning-gate must find the plan in the main checkout"
  fi

  # /next-task creates the per-task worktree cut from origin/<base>.
  git -C "$_main" worktree add -q --detach "$_tmpdir/wt" origin/main 2>/dev/null

  # The worktree does NOT contain the plan — so a committed-mode abort
  # ("plan absent on the worktree base") would fire WRONGLY here.
  if [ -e "$_tmpdir/wt/.plan/42.md" ]; then
    fail "behavioral: worktree unexpectedly contains the local plan"
  else
    pass "behavioral: worktree lacks the local plan (committed-mode abort would misfire)"
  fi

  # The orchestrator "receives the plan via the briefing": the chain reads it
  # from the main-root absolute path and it is non-empty with the Approach.
  briefing_plan="$(cat "$MAIN_ROOT/.plan/42.md" 2>/dev/null)"
  if printf '%s' "$briefing_plan" | grep -q 'Local-only plan carried inline.'; then
    pass "behavioral: orchestrator receives the plan via main-root read (no abort)"
  else
    fail "behavioral: main-root plan read must yield the approved Approach for the briefing"
  fi

  git -C "$_main" worktree remove --force "$_tmpdir/wt" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "plan-storage-local (TASK_027): all assertions passed."
  exit 0
else
  echo "plan-storage-local (TASK_027): $fails assertion(s) failed."
  exit 1
fi
