#!/usr/bin/env bash
#
# Regression test for #24 — bounded auto review-fix loop.
#
# Asserts that `agents/task-orchestrator.md`, `agents/pr-author.md`,
# `agents/reviewer.md`, `templates/atelier.template.json`, `.atelier.json`,
# and `PLAN.md` encode the review-fix loop contract introduced in #24 so that
# a future careless edit that silently drops or contradicts these invariants
# fails CI.
#
# Contract invariants asserted:
#   Group 1 — agents/task-orchestrator.md: loop section + triage contract
#     - "Review-fix loop" sub-section present
#     - Loop reads reviewFix.enabled from .atelier.json
#     - Code-addressable categories: correctness, test coverage, code quality, security
#     - Structural category: scope alignment (not auto-fixed)
#   Group 2 — agents/task-orchestrator.md: dual bound + loop mechanics
#     - reviewFix.maxCycles referenced as the per-cycle cap
#     - Dual bound: "whichever cap is hit first" wording present
#     - follow_up: true briefing signal for pr-author dispatch
#     - "review-fix exhausted" status in the Output enum
#   Group 3 — agents/task-orchestrator.md: decision rules
#     - Never exceed maxCycles
#     - Never feed prior reviewer findings to reviewer
#     - Never auto-fix structural findings
#     - Never commit/push fix-cycle code inline
#   Group 4 — agents/pr-author.md: follow-up mode
#     - "Follow-up mode" section present
#     - Entry condition: follow_up: true
#     - Skip step 3 (IN_PROGRESS → HISTORY tracking move)
#     - Skip step 6 (gh pr create)
#     - Returns existing PR URL + new commit SHA
#     - Size gate runs on cumulative branch diff
#   Group 5 — agents/reviewer.md: fresh-context invariant re-affirmed
#     - References the review-fix loop by name
#     - Hard refusal: prior-cycle findings in briefing must be discarded
#     - Orchestrator deliberately does not pass prior findings
#   Group 6 — config: reviewFix block in both config files (prose + JSON)
#     - "reviewFix" key present in .atelier.json and templates/atelier.template.json
#     - Template carries a _comment for the reviewFix block
#   Group 7 — PLAN.md §6 + §8 record the loop
#     - §6: code-addressable concept + reviewFix.maxCycles referenced
#     - §8: 6-attempt ceiling shared with review-fix cycles
#   Group 8 — behavioral: JSON validity + required field values via jq
#     - Both config files parse as valid JSON
#     - reviewFix.enabled == true and reviewFix.maxCycles == 2 in both
#
# Hermetic: all assertions run against committed files only — no network, no
# temp dirs persisted after exit.
#
# Run:  hooks/tests/review-fix-loop.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORCH="$REPO_ROOT/agents/task-orchestrator.md"
PR_AUTHOR="$REPO_ROOT/agents/pr-author.md"
REVIEWER="$REPO_ROOT/agents/reviewer.md"
ATELIER_JSON="$REPO_ROOT/.atelier.json"
TEMPLATE_JSON="$REPO_ROOT/templates/atelier.template.json"
PLAN="$REPO_ROOT/PLAN.md"

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

# ---------------------------------------------------------------------------
# Group 1: agents/task-orchestrator.md — loop section + triage contract
# ---------------------------------------------------------------------------

chk_prose "$ORCH" 'Review-fix loop' \
  "task-orchestrator: 'Review-fix loop' sub-section present"

chk_prose "$ORCH" 'reviewFix.enabled' \
  "task-orchestrator: loop gate reads reviewFix.enabled from .atelier.json"

chk_prose "$ORCH" 'correctness' \
  "task-orchestrator: triage — 'correctness' listed as code-addressable finding"

chk_prose "$ORCH" 'test coverage' \
  "task-orchestrator: triage — 'test coverage' listed as code-addressable finding"

chk_prose "$ORCH" 'code quality' \
  "task-orchestrator: triage — 'code quality' listed as code-addressable finding"

chk_prose "$ORCH" 'security' \
  "task-orchestrator: triage — 'security' listed as code-addressable finding"

chk_prose "$ORCH" 'scope alignment' \
  "task-orchestrator: triage — 'scope alignment' listed as structural (non-code) finding"

# ---------------------------------------------------------------------------
# Group 2: agents/task-orchestrator.md — dual bound + loop mechanics
# ---------------------------------------------------------------------------

chk_prose "$ORCH" 'reviewFix.maxCycles' \
  "task-orchestrator: dual bound — reviewFix.maxCycles is the per-cycle cap"

chk_prose "$ORCH" 'whichever cap is hit first' \
  "task-orchestrator: dual bound — 'whichever cap is hit first' ends the loop"

chk_prose "$ORCH" 'follow_up: true' \
  "task-orchestrator: dispatches pr-author with follow_up: true in the briefing"

chk_prose "$ORCH" 'review-fix exhausted' \
  "task-orchestrator: output status enum includes 'review-fix exhausted'"

# ---------------------------------------------------------------------------
# Group 3: agents/task-orchestrator.md — decision rules
# ---------------------------------------------------------------------------

chk_prose "$ORCH" 'resetting the cycle counter mid-task is forbidden' \
  "task-orchestrator: decision rule — silently extending the review-fix cycle count is forbidden"

chk_prose "$ORCH" 'Pass prior findings to `implementer`' \
  "task-orchestrator: decision rule — prior findings go to implementer, not reviewer"

chk_prose "$ORCH" 'not code-addressable by re-running `implementer`' \
  "task-orchestrator: decision rule — structural findings not fixable by re-running implementer"

chk_prose "$ORCH" 'Fix re-push in the review-fix loop always goes through' \
  "task-orchestrator: decision rule — fix re-push always goes through pr-author, not inline"

# ---------------------------------------------------------------------------
# Group 4: agents/pr-author.md — follow-up mode
# ---------------------------------------------------------------------------

chk_prose "$PR_AUTHOR" 'Follow-up mode' \
  "pr-author: 'Follow-up mode' section present"

chk_prose "$PR_AUTHOR" 'follow_up: true' \
  "pr-author: entry condition checks for follow_up: true in briefing"

chk_prose "$PR_AUTHOR" 'Skip step 3 entirely' \
  "pr-author: follow-up mode skips the IN_PROGRESS → HISTORY tracking move"

chk_prose "$PR_AUTHOR" 'Skip step 6 entirely' \
  "pr-author: follow-up mode skips gh pr create"

chk_prose "$PR_AUTHOR" 'existing PR URL + the new commit SHA' \
  "pr-author: follow-up mode returns existing PR URL + new commit SHA"

chk_prose "$PR_AUTHOR" 'cumulative branch diff' \
  "pr-author: size gate still runs on cumulative branch diff in follow-up mode"

# ---------------------------------------------------------------------------
# Group 5: agents/reviewer.md — fresh-context invariant re-affirmed
# ---------------------------------------------------------------------------

chk_prose "$REVIEWER" 'review-fix loop' \
  "reviewer: fresh-context section references the orchestrator's review-fix loop"

chk_prose "$REVIEWER" 'prior-cycle findings supplied in the briefing' \
  "reviewer: hard refusal — prior-cycle findings in briefing must be discarded"

chk_prose "$REVIEWER" 'orchestrator deliberately does' \
  "reviewer: affirms orchestrator deliberately does not pass prior findings"

# ---------------------------------------------------------------------------
# Group 6: config — reviewFix block present in both config files
# ---------------------------------------------------------------------------

chk_prose "$ATELIER_JSON" '"reviewFix"' \
  ".atelier.json: reviewFix block present"

chk_prose "$TEMPLATE_JSON" '"reviewFix"' \
  "templates/atelier.template.json: reviewFix block present"

chk_prose "$TEMPLATE_JSON" 'Bounded automated review-fix loop' \
  "templates/atelier.template.json: reviewFix _comment uses house style (Bounded automated review-fix loop)"

# ---------------------------------------------------------------------------
# Group 7: PLAN.md — §6 + §8 record the loop
# ---------------------------------------------------------------------------

chk_prose "$PLAN" 'code-addressable' \
  "PLAN.md §6: records 'code-addressable' findings concept for the loop"

chk_prose "$PLAN" 'reviewFix.maxCycles' \
  "PLAN.md §6: references reviewFix.maxCycles as the per-cycle cap"

chk_prose "$PLAN" '6-attempt ceiling is' \
  "PLAN.md §8: records that the 6-attempt ceiling is shared with the fix loop"

chk_prose "$PLAN" 'review-fix cycles' \
  "PLAN.md §8: explicitly names review-fix cycles in the failure recovery section"

# ---------------------------------------------------------------------------
# Group 8: behavioral — JSON validity + required field values via jq
# ---------------------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  fail "behavioral: jq not available — cannot validate config JSON structure"
else
  # .atelier.json — valid JSON with reviewFix.enabled == true
  if jq -e '.reviewFix.enabled == true' "$ATELIER_JSON" >/dev/null 2>&1; then
    pass "behavioral: .atelier.json is valid JSON with reviewFix.enabled == true"
  else
    fail "behavioral: .atelier.json reviewFix.enabled is not true (or file is invalid JSON)"
  fi

  # .atelier.json — reviewFix.maxCycles == 2
  if jq -e '.reviewFix.maxCycles == 2' "$ATELIER_JSON" >/dev/null 2>&1; then
    pass "behavioral: .atelier.json reviewFix.maxCycles == 2"
  else
    fail "behavioral: .atelier.json reviewFix.maxCycles is not 2 (or file is invalid JSON)"
  fi

  # templates/atelier.template.json — valid JSON with reviewFix.enabled == true
  if jq -e '.reviewFix.enabled == true' "$TEMPLATE_JSON" >/dev/null 2>&1; then
    pass "behavioral: templates/atelier.template.json is valid JSON with reviewFix.enabled == true"
  else
    fail "behavioral: templates/atelier.template.json reviewFix.enabled is not true (or file is invalid JSON)"
  fi

  # templates/atelier.template.json — reviewFix.maxCycles == 2
  if jq -e '.reviewFix.maxCycles == 2' "$TEMPLATE_JSON" >/dev/null 2>&1; then
    pass "behavioral: templates/atelier.template.json reviewFix.maxCycles == 2"
  else
    fail "behavioral: templates/atelier.template.json reviewFix.maxCycles is not 2 (or file is invalid JSON)"
  fi
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "review-fix-loop (#24): all assertions passed."
  exit 0
else
  echo "review-fix-loop (#24): $fails assertion(s) failed."
  exit 1
fi
