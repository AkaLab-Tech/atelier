#!/usr/bin/env bash
#
# Regression test for M9.3b — next-task / task-discovery prose tightening for
# the github-project backend.
#
# Asserts that `commands/next-task.md` and `skills/task-discovery/SKILL.md`
# encode the github-project contract invariants introduced in #20b so that a
# future careless edit that silently drops or contradicts them fails CI.
#
# Contract invariants asserted:
#   Group 1 — next-task.md step 2: github-project backlog source
#     - names `github-project` backend explicitly
#     - uses listTasks("roadmap") for backlog discovery
#     - references githubProject.stateMap for bucket mapping
#     - states the Project's "In Progress" column is NOT the concurrency signal
#       (claim registry = open task/* PRs)
#     - names the Ready field as the non-files planning-gate signal
#       (not a [ready] text token)
#     - Ready rides along in the listTasks / getTask record (no extra backend call)
#   Group 2 — next-task.md step 3: planning-gate validation (#31 union gate)
#     - non-files gate: Ready field set AND a plan found in any valid
#       PLAN_SOURCE location (union of resident/committed/local) — a
#       committed .plan/<id>.md is an explicitly valid source, not excluded
#     - the old buggy "Ready field is set; .plan/<id>.md is committed" wording
#       is gone
#     - step 2 no longer forces a resident override; PLAN_STORAGE stays the
#       preferred write mode and does not by itself decide where a task's
#       plan lives — including when the field is absent/unset (default
#       committed)
#     - plan-on-base guard runs whenever PLAN_SOURCE=committed, regardless of
#       backend (inverted from the pre-#31 "never runs for github-project/
#       linear" claim)
#     - the "land the plan commit" precondition applies whenever
#       PLAN_SOURCE=committed on any backend (inverted from the pre-#31
#       exclusion for non-files backends)
#     - an empty getPlan(id) under resident triggers the same stop-and-refuse
#       as a missing [ready]/.plan, pointing at /atelier:plan-task <id>
#     - step 8 carries the resident plan inline from the step-3-cached
#       getPlan(id) text (no second fetch) and omits main_checkout_root
#     - files gate: [ready] marker still required (no-regression)
#   Group 3 — next-task.md step 6: claim / state transition
#     - moveTask(id, "roadmap", "in_progress") present
#     - github-project Status transition via githubProject.stateMap named
#     - no local ROADMAP.md / IN_PROGRESS.md edits for non-files backend
#   Group 4 — SKILL.md Backend-aware section: github-project additions
#     - GitHubProjectBackend priority mapping present
#     - Ready-field planning gate described
#     - ready-without-plan sentinel present
#     - non-files plan-existence check is a union (resident/committed/local),
#       not a resident-only check (old "identical across all backends" /
#       resident-only wording gone)
#   Group 5 — no-regression: files-backend invariants still hold
#     - [ready] marker still referenced for the files backend
#     - claim registry = open task/* PRs still stated
#
# Hermetic: greps committed prose only; no network, no jq, no temp dirs.
#
# Run:  hooks/tests/next-task-github-project-claim.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NEXT_TASK="$REPO_ROOT/commands/next-task.md"
SKILL="$REPO_ROOT/skills/task-discovery/SKILL.md"

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
# Group 1: commands/next-task.md — step 2 github-project backlog source
# ---------------------------------------------------------------------------

chk_prose "$NEXT_TASK" 'github-project' \
  "next-task step 2: github-project backend named"

chk_prose "$NEXT_TASK" 'listTasks("roadmap")' \
  "next-task step 2: backlog obtained via listTasks(\"roadmap\")"

chk_prose "$NEXT_TASK" 'githubProject.stateMap' \
  "next-task step 2: bucket mapping via githubProject.stateMap"

chk_prose "$NEXT_TASK" 'the Project'"'"'s "In Progress" column is **not** the concurrency signal' \
  "next-task step 2: Project In Progress column NOT the concurrency signal"

chk_prose "$NEXT_TASK" 'Ready' \
  "next-task step 2: Ready field named as non-files planning-gate signal"

chk_prose "$NEXT_TASK" 'not a `[ready]` text token' \
  "next-task step 2: Ready field distinguished from [ready] text token"

chk_prose "$NEXT_TASK" 'Ready` rides along in the returned record, no dedicated extra read is needed' \
  "next-task step 3: Ready rides along in listTasks record (no extra call)"

# ---------------------------------------------------------------------------
# Group 2: commands/next-task.md — step 3 planning-gate validation (TASK_030)
# ---------------------------------------------------------------------------

chk_prose "$NEXT_TASK" 'the gate requires the backend'"'"'s `Ready` field to be set (carried in the `getTask` record) plus a plan found in any valid `PLAN_SOURCE` location' \
  "next-task step 3: non-files gate = Ready set AND a plan found in any valid PLAN_SOURCE location (union)"

chk_prose "$NEXT_TASK" 'a committed plan file is explicitly a valid source for this backend, not excluded' \
  "next-task step 3: committed .plan/<id>.md is explicitly a valid PLAN_SOURCE for non-files backends"

chk_absent "$NEXT_TASK" 'Ready` field is set; `.plan/<id>.md` is committed' \
  "next-task step 3: old buggy non-files gate wording (committed .plan) removed"

chk_prose "$NEXT_TASK" 'the plan may live in any of three places' \
  "next-task step 3: non-files backend plan may live in any of three union locations (not resident-only)"

chk_prose "$NEXT_TASK" 'PLAN_STORAGE` captured here is the **preferred write mode**' \
  "next-task step 1: PLAN_STORAGE is the preferred write mode, not a forced override"

chk_prose "$NEXT_TASK" 'or one that has never set `planStorage` and therefore defaults to `committed`' \
  "next-task step 2: committed default still applies when planStorage field is absent/unset (union discovery)"

chk_prose "$NEXT_TASK" 'The guard now runs whenever `PLAN_SOURCE=committed`, regardless of backend.' \
  "next-task: plan-on-base guard runs whenever PLAN_SOURCE=committed on any backend (inverted from pre-#31)"

chk_absent "$NEXT_TASK" 'refuse with a pointer to land the plan commit. A worktree cut from `origin/<base>` would otherwise operate on stale ROADMAP state and drop the decomposition. **(This applies to `planStorage=committed`.)**' \
  "next-task: old scoped-to-committed-only refusal phrasing (exact string) absent"

chk_prose "$NEXT_TASK" 'This applies whenever `PLAN_SOURCE=committed`, on the `files` backend and on a non-`files` backend alike' \
  "next-task hard refusals: 'land the plan commit' precondition applies whenever PLAN_SOURCE=committed on any backend"

chk_prose "$NEXT_TASK" '.plan/<id>.md' \
  "next-task step 3: .plan/<id>.md check present (files backend)"

chk_prose "$NEXT_TASK" 'an empty `getPlan(id)` under `resident`' \
  "next-task step 3: empty getPlan(id) under resident fails the planning gate"

chk_prose "$NEXT_TASK" 'is not planned — run `/atelier:plan-task #<id>` first' \
  "next-task step 3: planning-gate refusal points to /atelier:plan-task <id>"

chk_prose "$NEXT_TASK" 'sourced from the `getPlan(id)` text already fetched in step 3 (do not fetch it twice)' \
  "next-task step 8: resident plan carried inline from step-3-cached getPlan(id), no second fetch"

chk_prose "$NEXT_TASK" 'Omit `main_checkout_root` — it has no meaning for this mode' \
  "next-task step 8: main_checkout_root omitted under resident mode"

# ---------------------------------------------------------------------------
# Group 3: commands/next-task.md — step 6 claim / state transition
# ---------------------------------------------------------------------------

chk_prose "$NEXT_TASK" 'moveTask(id, "roadmap", "in_progress")' \
  "next-task step 6: claim drives moveTask(id, roadmap, in_progress)"

chk_prose "$NEXT_TASK" 'githubProject.stateMap.inProgress' \
  "next-task step 6: github-project Status transition via githubProject.stateMap.inProgress"

chk_prose "$NEXT_TASK" 'no local `ROADMAP.md` / `IN_PROGRESS.md` edits are made' \
  "next-task step 6: no local ROADMAP/IN_PROGRESS edits for non-files backend"

# ---------------------------------------------------------------------------
# Group 4: skills/task-discovery/SKILL.md — Backend-aware section additions
# ---------------------------------------------------------------------------

chk_prose "$SKILL" 'GitHubProjectBackend' \
  "SKILL.md: GitHubProjectBackend named in backend-aware section"

chk_prose "$SKILL" 'Priority` single-select custom field' \
  "SKILL.md: GitHubProjectBackend priority mapping via Priority single-select"

chk_prose "$SKILL" 'P0 → P0, P1 → P1, P2 → P2' \
  "SKILL.md: GitHubProjectBackend P0/P1/P2 identity mapping"

chk_prose "$SKILL" 'Ready` rides along in the same record, no dedicated extra read is required' \
  "SKILL.md: Ready rides along in listTasks record (no extra read)"

chk_prose "$SKILL" 'ready-without-plan' \
  "SKILL.md: ready-without-plan sentinel present"

chk_absent "$SKILL" 'The `.plan/<id>.md` committed-file check is **identical across all backends**' \
  "SKILL.md: old wording (committed-file check identical across all backends) removed"

chk_prose "$SKILL" 'A non-`files` backend can legitimately hold a committed or local `.plan/<id>.md` alongside resident plans for other tasks' \
  "SKILL.md: non-files plan-existence check is a union (resident/committed/local), not resident-only"

# ---------------------------------------------------------------------------
# Group 5: no-regression — files-backend invariants still hold
# ---------------------------------------------------------------------------

chk_prose "$NEXT_TASK" '[ready]' \
  "next-task no-regression: [ready] marker still referenced for files backend"

chk_prose "$NEXT_TASK" 'task/*' \
  "next-task no-regression: claim registry = open task/* PRs still stated"

chk_prose "$SKILL" '[ready]' \
  "SKILL.md no-regression: [ready] marker still referenced for files backend"

chk_prose "$SKILL" 'task/*' \
  "SKILL.md no-regression: claim registry = open task/* PRs still stated"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "next-task-github-project-claim (M9.3b): all assertions passed."
  exit 0
else
  echo "next-task-github-project-claim (M9.3b): $fails assertion(s) failed."
  exit 1
fi
