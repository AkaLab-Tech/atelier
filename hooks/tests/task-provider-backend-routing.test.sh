#!/usr/bin/env bash
#
# Test: task-provider backend routing contract (M9.1)
#
# Asserts that the prose in `commands/next-task.md` and
# `skills/task-discovery/SKILL.md` encodes the M9.1 backend-routing contract:
#   - non-`files` backend routes backlog read through listTasks("roadmap")
#   - chosen task enrichment goes through getTask(id)
#   - claim move uses moveTask(id, "roadmap", "in_progress")
#   - close move uses appendHistoryEntry(id, prMetadata)
#   - the `files` git-backed path (git show origin/<base>:ROADMAP.md) is preserved
#   - the claim registry = open task/* PRs language is present for both backends
#   - skills/task-discovery/SKILL.md has the "Backend-aware backlog source" section
#
# Hermetic: greps committed prose only; no network, no jq, no temp dirs.
#
# Run:  hooks/tests/task-provider-backend-routing.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NEXT_TASK="$REPO_ROOT/commands/next-task.md"
SKILL="$REPO_ROOT/skills/task-discovery/SKILL.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_prose <file> <grep-pattern> <label>
# Passes when the pattern is present in the file; fails otherwise.
chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

# ---------------------------------------------------------------------------
# Group 1: commands/next-task.md — backend-routing contract operations
# ---------------------------------------------------------------------------

chk_prose "$NEXT_TASK" 'listTasks' \
  "next-task: non-files backlog obtained via listTasks"

chk_prose "$NEXT_TASK" 'getTask' \
  "next-task: full task record retrieved via getTask"

chk_prose "$NEXT_TASK" 'moveTask' \
  "next-task: claim move drives moveTask"

chk_prose "$NEXT_TASK" 'appendHistoryEntry' \
  "next-task: close move references appendHistoryEntry"

chk_prose "$NEXT_TASK" 'atelier-task-backend' \
  "next-task: backend resolved via atelier-task-backend"

# ---------------------------------------------------------------------------
# Group 2: commands/next-task.md — files-backend no-regression invariant
# ---------------------------------------------------------------------------

chk_prose "$NEXT_TASK" 'git show origin' \
  "next-task: files backend reads backlog via git show origin/<base>:ROADMAP.md"

chk_prose "$NEXT_TASK" 'IN_PROGRESS.md' \
  "next-task: files backend local-file tracking (IN_PROGRESS.md) preserved"

# ---------------------------------------------------------------------------
# Group 3: commands/next-task.md — claim registry backend-agnostic invariant
# (both backends use open task/* PRs as the registry — §16.4 invariant)
# ---------------------------------------------------------------------------

chk_prose "$NEXT_TASK" 'task/*' \
  "next-task: claim registry = open task/* PRs (backend-agnostic)"

# ---------------------------------------------------------------------------
# Group 4: skills/task-discovery/SKILL.md — Backend-aware backlog source section
# ---------------------------------------------------------------------------

chk_prose "$SKILL" 'Backend-aware backlog source' \
  "SKILL.md: Backend-aware backlog source section present (M9.1)"

chk_prose "$SKILL" 'listTasks' \
  "SKILL.md: caller obtains backlog via listTasks"

chk_prose "$SKILL" 'getTask' \
  "SKILL.md: caller enriches task via getTask"

chk_prose "$SKILL" 'atelier-task-backend' \
  "SKILL.md: backend resolved via atelier-task-backend"

# ---------------------------------------------------------------------------

echo ""
if [ "$fails" -eq 0 ]; then
  echo "task-provider-backend-routing: all assertions passed."
  exit 0
else
  echo "task-provider-backend-routing: $fails assertion(s) failed."
  exit 1
fi
