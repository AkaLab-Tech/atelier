#!/usr/bin/env bash
#
# Regression test for #25 — /atelier:babysit-prs command.
#
# Asserts the following invariants so that future careless edits that
# silently drop or contradict these contracts fail CI:
#
#   Group 1 — cross-file: SKILL.md forward refs resolve to the real command file
#     - `commands/babysit-prs.md` exists (the command the forward refs point at)
#     - No stale "#25 babysit-prs" forward-reference strings remain in SKILL.md
#     - Both updated forward-ref lines now mention `/atelier:babysit-prs`
#   Group 2 — no-internal-poll contract: command is one idempotent pass only
#     - "No internal sleep/poll loop" declared at the top of the command
#     - "Never implement an internal sleep/poll loop" hard refusal present
#     - No `maxPasses` constant / variable in the command (cadence belongs to /loop)
#   Group 3 — task-orchestrator: pr-open resume mode records babysit-prs as a caller
#     - /atelier:babysit-prs named as a caller of pr-open mode in task-orchestrator.md
#   Group 4 — PLAN.md §7 catalog entry
#     - `/babysit-prs` catalog entry present with matching argument-hint
#   Group 5 — config: babysitPrs block present in both JSON config files
#     - "babysitPrs" key present in .atelier.json and templates/atelier.template.json
#   Group 6 — behavioral: JSON validity + babysitPrs.maxPrsPerPass value
#     - Both config files parse as valid JSON with babysitPrs.maxPrsPerPass == 10
#
# Hermetic: all assertions run against committed files only — no network, no
# temp dirs persisted after exit.
#
# Run:  hooks/tests/babysit-prs.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CMD="$REPO_ROOT/commands/babysit-prs.md"
SKILL="$REPO_ROOT/skills/auto-merge/SKILL.md"
ORCH="$REPO_ROOT/agents/task-orchestrator.md"
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

# chk_absent <file> <fixed-string> <label>
# Passes when the fixed string is NOT present in the file; fails otherwise.
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    fail "$label — unexpected token '$pattern' found in $file"
  else
    pass "$label"
  fi
}

# ---------------------------------------------------------------------------
# Group 1: cross-file — SKILL.md forward refs resolve to the real command file
# ---------------------------------------------------------------------------

if [ -f "$CMD" ]; then
  pass "cross-ref: commands/babysit-prs.md exists (SKILL.md forward refs have a real target)"
else
  fail "cross-ref: commands/babysit-prs.md not found — SKILL.md forward refs are broken"
fi

chk_absent "$SKILL" '#25 babysit-prs' \
  "cross-ref: no stale '#25 babysit-prs' forward-reference strings remain in SKILL.md"

chk_prose "$SKILL" '/atelier:babysit-prs' \
  "cross-ref: SKILL.md forward refs use the canonical /atelier:babysit-prs command name"

# ---------------------------------------------------------------------------
# Group 2: no-internal-poll contract — command is a single idempotent pass
# ---------------------------------------------------------------------------

chk_prose "$CMD" 'No internal sleep/poll loop' \
  "no-internal-poll: command declares 'No internal sleep/poll loop' at the top"

chk_prose "$CMD" 'implement an internal sleep/poll loop' \
  "no-internal-poll: hard refusal against implementing an internal sleep/poll loop present"

chk_absent "$CMD" 'maxPasses' \
  "no-internal-poll: no 'maxPasses' in the command (cross-pass cadence belongs to /loop)"

# ---------------------------------------------------------------------------
# Group 3: task-orchestrator — pr-open resume mode records babysit-prs as a caller
# ---------------------------------------------------------------------------

chk_prose "$ORCH" '/atelier:babysit-prs' \
  "task-orchestrator: babysit-prs named as a caller of pr-open resume mode"

# ---------------------------------------------------------------------------
# Group 4: PLAN.md §7 catalog entry
# ---------------------------------------------------------------------------

chk_prose "$PLAN" '/babysit-prs' \
  "PLAN.md §7: /babysit-prs catalog entry present"

chk_prose "$PLAN" '[--workspace] [--yes|-y]' \
  "PLAN.md §7: argument-hint '[--workspace] [--yes|-y]' matches command frontmatter"

# ---------------------------------------------------------------------------
# Group 5: config — babysitPrs block present in both config files
# ---------------------------------------------------------------------------

chk_prose "$ATELIER_JSON" '"babysitPrs"' \
  ".atelier.json: babysitPrs config block present"

chk_prose "$TEMPLATE_JSON" '"babysitPrs"' \
  "templates/atelier.template.json: babysitPrs config block present"

# ---------------------------------------------------------------------------
# Group 6: behavioral — JSON validity + babysitPrs.maxPrsPerPass field values
# ---------------------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  fail "behavioral: jq not available — cannot validate config JSON structure"
else
  if jq -e '.babysitPrs.maxPrsPerPass == 10' "$ATELIER_JSON" >/dev/null 2>&1; then
    pass "behavioral: .atelier.json is valid JSON with babysitPrs.maxPrsPerPass == 10"
  else
    fail "behavioral: .atelier.json babysitPrs.maxPrsPerPass is not 10 (or file is invalid JSON)"
  fi

  if jq -e '.babysitPrs.maxPrsPerPass == 10' "$TEMPLATE_JSON" >/dev/null 2>&1; then
    pass "behavioral: templates/atelier.template.json is valid JSON with babysitPrs.maxPrsPerPass == 10"
  else
    fail "behavioral: templates/atelier.template.json babysitPrs.maxPrsPerPass is not 10 (or file is invalid JSON)"
  fi
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "babysit-prs (#25): all assertions passed."
  exit 0
else
  echo "babysit-prs (#25): $fails assertion(s) failed."
  exit 1
fi
