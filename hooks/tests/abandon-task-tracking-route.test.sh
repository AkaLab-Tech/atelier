#!/usr/bin/env bash
#
# Regression test for #34 — /atelier:abandon-task's files-backend tracking move
# must ride an EXECUTABLE PR route.
#
# Root cause: step 7's `files.` bullet told the command to make the
# IN_PROGRESS.md -> HISTORY.md edits with `Edit` and then "invoke the
# `atelier:pr-flow` skill to commit them on a `docs/abandon-<id>` branch ...
# and open the PR". That route cannot execute for two independent reasons:
#   (a) `skills/pr-flow/SKILL.md` refuses any branch that does not start with
#       `task/`, so a `docs/abandon-<id>` head is rejected outright; and
#   (b) loading a skill grants no tools — the commands the skill documents
#       would still run from this command's own session, whose grant excludes
#       `git commit` / `git push` / `gh pr create`. Only dispatching a
#       sub-agent that carries its own grants supplies those verbs.
# Fix: prepare `docs/abandon-<id>` in a throwaway `git-wt` worktree, then hand
# the commit -> PR -> review -> merge segment to `task-orchestrator` via `Task`
# in non-task PR coordination mode (no `task_id`), which selects `pr-opener`
# for the `docs/*` head — the same pattern as `/atelier:align` Tier 3 and
# `/atelier:release`.
#
# Contract invariants asserted:
#   Group 1 — step 7 no longer delegates docs/abandon-<id> to pr-flow
#     - the step 7 section is extractable and non-empty (guards the extractor)
#     - the step 7 section contains no `pr-flow` reference at all
#     - the OLD "invoke the `atelier:pr-flow` skill" sentence is gone from the
#       whole file, including the Hard-refusals restatement
#   Group 2 — step 7 names the executable route instead
#     - the section dispatches `task-orchestrator` via the `Task` tool
#     - the briefing carries `mode: non-task-pr`
#     - the briefing withholds `task_id` (the absence is the routing signal)
#     - the head is still `docs/abandon-<id>`, prepared in a throwaway
#       `git wt` worktree rather than in MAIN_ROOT
#     - `pr-opener` is named as the orchestrator's pick, and the command does
#       not dispatch pr-opener/reviewer/auto-merge from its own turn
#   Group 3 — frontmatter allowed-tools safety contract
#     - `allowed-tools` grants `Task` (without it the step 7 dispatch is as
#       unexecutable as the pr-flow route it replaced)
#     - `allowed-tools` still withholds `git commit`, `git push` and
#       `gh pr create` — the whole point of routing through a sub-agent
#
# Hermetic: greps committed prose only; no network, no git/gh execution, no
# temp dirs.
#
# Run:  hooks/tests/abandon-task-tracking-route.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CMD="$REPO_ROOT/commands/abandon-task.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_absent <file> <fixed-string> <label>
# Passes when the fixed string is ABSENT from the file; fails otherwise.
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF -e "$pattern" "$file" 2>/dev/null; then
    fail "$label — token '$pattern' found but should be absent in $file"
  else
    pass "$label"
  fi
}

# chk_section <fixed-string> <label>
# Passes when the fixed string is present in the extracted step 7 section.
chk_section() {
  local pattern="$1" label="$2"
  if printf '%s' "$STEP7" | grep -qF -e "$pattern"; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in step 7 of $CMD"
  fi
}

# chk_section_absent <fixed-string> <label>
# Passes when the fixed string is ABSENT from the extracted step 7 section.
chk_section_absent() {
  local pattern="$1" label="$2"
  if printf '%s' "$STEP7" | grep -qF -e "$pattern"; then
    fail "$label — token '$pattern' found but should be absent from step 7 of $CMD"
  else
    pass "$label"
  fi
}

[ -f "$CMD" ] || { echo "  FAIL: $CMD not found"; exit 1; }

# Step 7 ("Move tracking to a terminal state") runs from its own H3 heading up
# to step 8's heading. Scoping the pr-flow assertion to this section keeps the
# test honest: it fires on the tracking-move route specifically, not on any
# incidental mention of pr-flow elsewhere in the file.
step7_section() {
  awk '
    /^### 7\./ { capture = 1 }
    capture && /^### 8\./ { exit }
    capture { print }
  ' "$CMD"
}

STEP7="$(step7_section)"

# ---------------------------------------------------------------------------
# Group 1: step 7 no longer delegates the docs/abandon-<id> branch to pr-flow
# ---------------------------------------------------------------------------

if printf '%s' "$STEP7" | grep -qF '### 7.' && [ "$(printf '%s' "$STEP7" | wc -l)" -gt 3 ]; then
  pass "extractor: step 7 section extracted and non-empty"
else
  fail "extractor: step 7 section could not be extracted from $CMD (headings renumbered?)"
fi

chk_section_absent 'pr-flow' \
  "step 7 (#34): tracking-move route makes no reference to pr-flow (it refuses non-task/* branches)"

chk_absent "$CMD" 'invoke the `atelier:pr-flow` skill' \
  "step 7 (#34): OLD 'invoke the atelier:pr-flow skill' route is gone from the file"

chk_absent "$CMD" 'delegated to the `atelier:pr-flow` skill' \
  "hard-refusals (#34): OLD 'delegated to the atelier:pr-flow skill' restatement is gone"

# ---------------------------------------------------------------------------
# Group 2: step 7 names the executable route instead
# ---------------------------------------------------------------------------

chk_section 'task-orchestrator' \
  "step 7 (#34): tracking-move route names the task-orchestrator agent"

chk_section 'via `Task`' \
  "step 7 (#34): the orchestrator is dispatched via the Task tool"

chk_section 'mode: non-task-pr' \
  "step 7 (#34): the briefing carries mode: non-task-pr"

chk_section 'task_id' \
  "step 7 (#34): the briefing names task_id (as the field it deliberately withholds)"

chk_section 'docs/abandon-<id>' \
  "step 7 (#34): the head branch is still docs/abandon-<id>"

chk_section 'git wt' \
  "step 7 (#34): the docs branch is prepared in a throwaway git-wt worktree"

chk_section 'pr-opener' \
  "step 7 (#34): pr-opener is named as the authoring primitive the orchestrator selects"

chk_section 'Do **not** dispatch `pr-opener`, `reviewer`, or `auto-merge` from this command' \
  "step 7 (#34): the command does not dispatch pr-opener/reviewer/auto-merge from its own turn"

# ---------------------------------------------------------------------------
# Group 3: frontmatter allowed-tools safety contract
# ---------------------------------------------------------------------------

ALLOWED_TOOLS_LINE="$(grep -m1 '^allowed-tools:' "$CMD")"

if printf '%s' "$ALLOWED_TOOLS_LINE" | grep -qE '(: |, )Task(,|$)'; then
  pass "allowed-tools (#34): grants Task — the step 7 orchestrator dispatch is executable"
else
  fail "allowed-tools (#34): Task is not granted, so step 7's orchestrator dispatch cannot run"
fi

for verb in 'git commit' 'git push' 'gh pr create'; do
  if printf '%s' "$ALLOWED_TOOLS_LINE" | grep -qF -e "$verb"; then
    fail "allowed-tools (#34): must NEVER grant '$verb' — that is the sub-agent's job, not this command's"
  else
    pass "allowed-tools (#34): still withholds '$verb'"
  fi
done

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "abandon-task-tracking-route (#34): all assertions passed."
  exit 0
else
  echo "abandon-task-tracking-route (#34): $fails assertion(s) failed."
  exit 1
fi
