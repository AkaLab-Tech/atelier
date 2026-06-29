#!/usr/bin/env bash
#
# Regression test for #26 — Auto post-merge cleanup (base ff + orphan sweep).
#
# Asserts structural and prose invariants so that future edits that silently
# drop or contradict the contracts added by #26 will fail CI:
#
#   Group 1 — config structure: postMergeCleanup block present in both
#              .atelier.json and templates/atelier.template.json, with
#              fastForwardBase and sweepOrphans keys.
#   Group 2 — behavioral: both JSON files parse as valid JSON; both keys
#              default to true.
#   Group 3 — SKILL.md step 4 (base ff): prose present with correct guards
#              (merge --ff-only, not force-update).
#   Group 4 — SKILL.md step 5 (orphan sweep): prose present with the exact
#              housekeeping invocation flags (--yes --no-stamp, no
#              --include-unmerged).
#   Group 5 — SKILL.md hard refusals: never force-update/reset/stash the
#              base; never hand-roll the sweep.
#   Group 6 — SKILL.md structured output: Base: and Swept: template lines
#              present with 'disabled' state option.
#   Group 7 — task-orchestrator.md: merged close-out report surfaces both
#              the Base: and Swept: lines from the skill's structured output.
#
# Hermetic: all assertions run against committed files only — no network,
# no temp dirs persisted after exit.
#
# Run:  hooks/tests/post-merge-cleanup-config.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ATELIER_JSON="$REPO_ROOT/.atelier.json"
TEMPLATE_JSON="$REPO_ROOT/templates/atelier.template.json"
SKILL="$REPO_ROOT/skills/auto-merge/SKILL.md"
ORCH="$REPO_ROOT/agents/task-orchestrator.md"

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

# chk_absent <file> <fixed-string> <label>
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    fail "$label — unexpected token '$pattern' found in $file"
  else
    pass "$label"
  fi
}

echo "post-merge-cleanup-config (#26) — config + skill prose regression"

# ---------------------------------------------------------------------------
# Group 1: config structure — postMergeCleanup block in both JSON files
# ---------------------------------------------------------------------------

chk_prose "$ATELIER_JSON" '"postMergeCleanup"' \
  ".atelier.json: postMergeCleanup config block present"

chk_prose "$ATELIER_JSON" '"fastForwardBase"' \
  ".atelier.json: fastForwardBase key present in postMergeCleanup"

chk_prose "$ATELIER_JSON" '"sweepOrphans"' \
  ".atelier.json: sweepOrphans key present in postMergeCleanup"

chk_prose "$ATELIER_JSON" '"_comment"' \
  ".atelier.json: postMergeCleanup block has a _comment field"

chk_prose "$TEMPLATE_JSON" '"postMergeCleanup"' \
  "templates/atelier.template.json: postMergeCleanup config block present"

chk_prose "$TEMPLATE_JSON" '"fastForwardBase"' \
  "templates/atelier.template.json: fastForwardBase key present"

chk_prose "$TEMPLATE_JSON" '"sweepOrphans"' \
  "templates/atelier.template.json: sweepOrphans key present"

chk_prose "$TEMPLATE_JSON" '"_comment"' \
  "templates/atelier.template.json: postMergeCleanup block has a _comment field"

# ---------------------------------------------------------------------------
# Group 2: behavioral — JSON validity and default values
# ---------------------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  fail "jq not available — cannot validate JSON config structure"
else
  if jq -e '.postMergeCleanup.fastForwardBase == true' "$ATELIER_JSON" >/dev/null 2>&1; then
    pass ".atelier.json: postMergeCleanup.fastForwardBase defaults to true (valid JSON)"
  else
    fail ".atelier.json: postMergeCleanup.fastForwardBase is not true (or file is invalid JSON)"
  fi

  if jq -e '.postMergeCleanup.sweepOrphans == true' "$ATELIER_JSON" >/dev/null 2>&1; then
    pass ".atelier.json: postMergeCleanup.sweepOrphans defaults to true (valid JSON)"
  else
    fail ".atelier.json: postMergeCleanup.sweepOrphans is not true (or file is invalid JSON)"
  fi

  if jq -e '.postMergeCleanup.fastForwardBase == true' "$TEMPLATE_JSON" >/dev/null 2>&1; then
    pass "templates/atelier.template.json: postMergeCleanup.fastForwardBase defaults to true (valid JSON)"
  else
    fail "templates/atelier.template.json: postMergeCleanup.fastForwardBase is not true (or file is invalid JSON)"
  fi

  if jq -e '.postMergeCleanup.sweepOrphans == true' "$TEMPLATE_JSON" >/dev/null 2>&1; then
    pass "templates/atelier.template.json: postMergeCleanup.sweepOrphans defaults to true (valid JSON)"
  else
    fail "templates/atelier.template.json: postMergeCleanup.sweepOrphans is not true (or file is invalid JSON)"
  fi
fi

# ---------------------------------------------------------------------------
# Group 3: SKILL.md step 4 — base fast-forward prose
# ---------------------------------------------------------------------------

chk_prose "$SKILL" 'Fast-forward the local base branch' \
  "SKILL.md: step 4 'Fast-forward the local base branch' heading present"

chk_prose "$SKILL" 'postMergeCleanup.fastForwardBase' \
  "SKILL.md: step 4 gated by postMergeCleanup.fastForwardBase"

chk_prose "$SKILL" 'merge --ff-only origin/' \
  "SKILL.md: step 4 uses merge --ff-only (safe, non-force update path)"

chk_prose "$SKILL" 'skip and surface' \
  "SKILL.md: step 4 specifies skip-and-surface on guard failure (not force)"

chk_prose "$SKILL" 'ls-remote --heads origin dev' \
  "SKILL.md: step 4 uses ls-remote to resolve dev-or-main base branch"

# ---------------------------------------------------------------------------
# Group 4: SKILL.md step 5 — orphan sweep prose
# ---------------------------------------------------------------------------

chk_prose "$SKILL" 'Orphan `task/*` sweep' \
  "SKILL.md: step 5 'Orphan task/* sweep' heading present"

chk_prose "$SKILL" 'postMergeCleanup.sweepOrphans' \
  "SKILL.md: step 5 gated by postMergeCleanup.sweepOrphans"

# Exact flags the skill MUST pass — any drift here breaks the safety contract.
chk_prose "$SKILL" 'atelier-housekeeping --project <project_root> --yes --no-stamp' \
  "SKILL.md: step 5 invokes housekeeping with exact --project --yes --no-stamp flags"

# No --include-unmerged: unmerged work must NEVER be auto-deleted (AC§4).
chk_absent "$SKILL" '--include-unmerged' \
  "SKILL.md: --include-unmerged NOT present — unmerged orphans are reported, never deleted"

chk_prose "$SKILL" 'Idempotent' \
  "SKILL.md: step 5 documents idempotency contract"

# ---------------------------------------------------------------------------
# Group 5: SKILL.md hard refusals
# ---------------------------------------------------------------------------

# Never force-update / reset / stash the operator's working tree (step 4).
chk_prose "$SKILL" 'Never' \
  "SKILL.md: hard-refusals section contains 'Never' statements"

chk_prose "$SKILL" 'force-update' \
  "SKILL.md: hard refusal against force-update present"

chk_prose "$SKILL" 'reset --hard' \
  "SKILL.md: hard refusal against reset --hard present"

chk_prose "$SKILL" 'stash' \
  "SKILL.md: hard refusal against stash present"

# Never hand-roll the sweep (step 5): only the binary is permitted to delete.
chk_prose "$SKILL" 'hand-roll the orphan sweep' \
  "SKILL.md: hard refusal against hand-rolling the orphan sweep"

chk_prose "$SKILL" 'git branch -d' \
  "SKILL.md: hard refusal names git branch -d as a forbidden direct call"

chk_prose "$SKILL" 'git push --delete' \
  "SKILL.md: hard refusal names git push --delete as a forbidden direct call"

# ---------------------------------------------------------------------------
# Group 6: SKILL.md structured output — Base: and Swept: template lines
# ---------------------------------------------------------------------------

chk_prose "$SKILL" 'Base:' \
  "SKILL.md: structured output template includes 'Base:' line for ff status"

chk_prose "$SKILL" 'Swept:' \
  "SKILL.md: structured output template includes 'Swept:' line for sweep counts"

# The 'disabled' state must be present so operators know what a disabled step
# looks like in the report.
chk_prose "$SKILL" 'disabled' \
  "SKILL.md: structured output includes 'disabled' state (for fastForwardBase/sweepOrphans: false)"

# ---------------------------------------------------------------------------
# Group 7: task-orchestrator.md — merged close-out surfaces both lines
# ---------------------------------------------------------------------------

chk_prose "$ORCH" 'Base:' \
  "task-orchestrator.md: merged close-out report surfaces the 'Base:' line"

chk_prose "$ORCH" 'Swept:' \
  "task-orchestrator.md: merged close-out report surfaces the 'Swept:' line"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "post-merge-cleanup-config (#26): all assertions passed."
  exit 0
else
  echo "post-merge-cleanup-config (#26): $fails assertion(s) failed."
  exit 1
fi
