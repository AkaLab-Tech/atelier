#!/usr/bin/env bash
#
# Regression test for #557 — /atelier:next-task can claim the next part of a
# multi-part task whose board item is still In Progress (non-`files` backend).
#
# The claim token for a next part is the consumed `Ready` field
# (setReady(id, false)), never moveTask; the open task/* PR registry stays the
# concurrency signal. Six signals (a)-(f) must all hold; a missing one falls
# back to the interrupted-claim message. /resume-task redirects an unclaimed
# next part to /next-task, the plan approval stamp carries an ISO-8601 UTC
# timestamp, and the orchestrator recognises the claim from the item itself.
#
# Hermetic: greps committed prose only; no network, no temp dirs.
#
# Run:  hooks/tests/next-task-next-part-claim.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NEXT_TASK="$REPO_ROOT/commands/next-task.md"
RESUME_TASK="$REPO_ROOT/commands/resume-task.md"
PLAN_TASK="$REPO_ROOT/commands/plan-task.md"
PLANNER="$REPO_ROOT/agents/planner.md"
ORCH="$REPO_ROOT/agents/task-orchestrator.md"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF -e "$pattern" "$file" 2>/dev/null; then pass "$label"
  else fail "$label — token '$pattern' not found in $file"; fi
}
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF -e "$pattern" "$file" 2>/dev/null; then
    fail "$label — token '$pattern' found but should be absent in $file"
  else pass "$label"; fi
}

for f in "$NEXT_TASK" "$RESUME_TASK" "$PLAN_TASK" "$PLANNER" "$ORCH"; do
  if [ -f "$f" ]; then pass "file: ${f#"$REPO_ROOT"/} exists"; else fail "file: $f not found"; fi
done

# ---------------------------------------------------------------------------
# Group 1: next-task classifier — six signals
# ---------------------------------------------------------------------------
chk_prose "$NEXT_TASK" '**Claim kind — first claim or next part (non-`files` backend, explicitly named id only).**' \
  "classifier: heading, non-files + explicitly named id only"
chk_prose "$NEXT_TASK" 'Before any worktree exists, classify the claim and record `CLAIM_KIND=first|next-part`' \
  "classifier: runs before the worktree is created"
chk_prose "$NEXT_TASK" 'it is never an orchestrator brief field' \
  "classifier: CLAIM_KIND is not a brief field"
chk_prose "$NEXT_TASK" 'Read the item fresh with `getTask(id)` (not from the cache). If its Status is **not** in `stateMap.inProgress`, `CLAIM_KIND=first`' \
  "signal (a): fresh getTask; Status outside inProgress -> first"
chk_prose "$NEXT_TASK" 'Status is in `stateMap.inProgress` (signal a)' \
  "signal (a): Status in stateMap.inProgress"
chk_prose "$NEXT_TASK" '(b) no open `task/<id>-*` PR.' \
  "signal (b): no open task/<id>-* PR"
chk_prose "$NEXT_TASK" '(c) the `getTask(id)` record has `Ready` set.' \
  "signal (c): fresh getTask record has Ready set"
chk_prose "$NEXT_TASK" '(d) at least one merged `task/<id>-*` PR' \
  "signal (d): at least one merged task/<id>-* PR"
chk_prose "$NEXT_TASK" 'gh pr list --state merged --json number,headRefName,mergedAt' \
  "signal (d): gh pr list --state merged with mergedAt"
chk_prose "$NEXT_TASK" 'startswith("task/<id>-")' \
  "signal (d): jq startswith filter"
chk_prose "$NEXT_TASK" 'Take the newest `mergedAt`; the count is the number of merged parts.' \
  "signal (d): newest mergedAt and merged-part count"
chk_prose "$NEXT_TASK" '(e) the approval timestamp in the plan'"'"'s `Status: ready (approved <ISO-8601 UTC> — product lead)` line' \
  "signal (e): plan approval timestamp"
chk_prose "$NEXT_TASK" 'is later than that newest `mergedAt`. A plan with no timestamp never qualifies.' \
  "signal (e): later than newest mergedAt; no timestamp never qualifies"
chk_prose "$NEXT_TASK" '(f) no local `task/<id>-*` worktree (`git wt list`).' \
  "signal (f): no local task/<id>-* worktree"
chk_prose "$NEXT_TASK" '(a), (b), (c), (d), (e) and (f) all hold → `CLAIM_KIND=next-part`, merged parts = N-1' \
  "all six signals required for next-part"
chk_prose "$NEXT_TASK" 'none inferred from absence' \
  "signals are read fresh, none inferred from absence"

# ---------------------------------------------------------------------------
# Group 2: fallback to interrupted-claim, open-PR registry wording
# ---------------------------------------------------------------------------
chk_prose "$NEXT_TASK" 'stop with the interrupted-claim message from step 6 case 2 (including its `/atelier:resume-task` hint) plus one line naming the missing signal' \
  "missing signal: falls back to interrupted-claim message + hint + missing-signal line"
chk_prose "$NEXT_TASK" 'missing signal: Ready is not set' \
  "missing-signal example: Ready is not set"
chk_prose "$NEXT_TASK" 'missing signal: no merged task/<id>-* PR' \
  "missing-signal example: no merged PR"
chk_prose "$NEXT_TASK" 'missing signal: a local worktree task/<id>-* already exists' \
  "missing-signal example: local worktree exists"
chk_prose "$NEXT_TASK" 'A missing signal is never treated as permission.' \
  "missing signal is never permission"
chk_prose "$NEXT_TASK" 'gets this interrupted-claim message (with `missing signal: Ready is not set`) instead of the planning-gate "not planned" refusal' \
  "In Progress with Ready clear -> interrupted-claim, not 'not planned'"
chk_prose "$NEXT_TASK" 'An open one keeps today'"'"'s verdict: **genuine race**, stop as in step 6 case 3 and do not suggest `/atelier:resume-task`.' \
  "open task/<id>-* PR keeps the genuine-race verdict, no resume hint"
chk_prose "$NEXT_TASK" '3. **Genuine race** — either the item'"'"'s Status is in `inProgress` **and** an open `task/<id>-*` PR already exists' \
  "step 6 case 3: open-PR registry wording kept"
chk_prose "$NEXT_TASK" 'resolve: /atelier:resume-task <id>' \
  "step 6 case 2: interrupted-claim /atelier:resume-task hint unchanged"

# ---------------------------------------------------------------------------
# Group 3: exclusions
# ---------------------------------------------------------------------------
chk_prose "$NEXT_TASK" 'Auto-pick never reaches this classifier and never selects an In Progress item: it reads the `roadmap` bucket only.' \
  "auto-pick excluded"
chk_prose "$NEXT_TASK" 'The `files` backend has no next-part path and is always `first`.' \
  "files backend excluded (always first)"
chk_prose "$NEXT_TASK" '**Never** claim a next part through auto-pick, on the `files` backend, or without consuming `Ready`' \
  "hard refusal: no next part via auto-pick / files / without consuming Ready"
chk_prose "$NEXT_TASK" '**never** create the worktree before the claim kind is decided' \
  "hard refusal: worktree only after the claim kind is decided"
chk_prose "$NEXT_TASK" 'never treat a missing next-part signal (a)-(f) as permission' \
  "hard refusal: missing signal is not permission"

# ---------------------------------------------------------------------------
# Group 4: branch naming
# ---------------------------------------------------------------------------
chk_prose "$NEXT_TASK" 'the new branch is `task/<id>-<slug>-part<N>`, N = merged parts + 1' \
  "branch: task/<id>-<slug>-part<N>, N = merged parts + 1"
chk_prose "$NEXT_TASK" 'The `task/<id>-` prefix is kept' \
  "branch: task/<id>- prefix kept"
chk_prose "$NEXT_TASK" 'For a first claim the branch name is unchanged.' \
  "branch: first claim unchanged"
chk_prose "$NEXT_TASK" 'Branch:      task/<id>-<slug>   (next part: task/<id>-<slug>-part<N>)' \
  "output block shows the next-part branch"

# ---------------------------------------------------------------------------
# Group 5: Ready consumption as the claim token
# ---------------------------------------------------------------------------
chk_prose "$NEXT_TASK" '**`CLAIM_KIND=next-part` — claim by consuming `Ready`, never `moveTask`**' \
  "step 6: next-part claims by consuming Ready, never moveTask"
chk_prose "$NEXT_TASK" 'Re-read the item with a fresh `getTask(id)` and re-check the open `task/<id>-*` PR list.' \
  "step 6: fresh re-read before taking the token"
chk_prose "$NEXT_TASK" '(c) `Ready` is still set' \
  "step 6: Ready re-checked at re-read"
chk_prose "$NEXT_TASK" 'Call `setReady(id, false)` (one atomic field update).' \
  "step 6: setReady(id, false) after the re-read"
chk_prose "$NEXT_TASK" 'That consumed `Ready` is the claim token' \
  "step 6: consumed Ready is the token"
chk_prose "$NEXT_TASK" 'If `Ready` is already cleared or an open `task/<id>-*` PR has appeared at the re-read, that is a **genuine race**' \
  "step 6: lost token (Ready cleared / PR appeared) is a genuine race"
chk_prose "$NEXT_TASK" 'do **not** suggest `/atelier:resume-task`, and remove the empty worktree just created in step 5' \
  "step 6: lost token -> no resume hint, empty worktree removed"
chk_prose "$NEXT_TASK" 'lands on the resume path (`/atelier:resume-task` step 3b) deterministically' \
  "step 6: interrupted next-part claim lands on resume step 3b"
chk_prose "$NEXT_TASK" '- **`CLAIM_KIND=first`** — as follows, unchanged:' \
  "step 6: first claim path unchanged (moveTask)"
chk_prose "$NEXT_TASK" 'Call `moveTask(id, "roadmap", "in_progress")` via the `roadmap-tracking-flow` skill.' \
  "step 6: first claim still uses moveTask roadmap -> in_progress"
chk_prose "$NEXT_TASK" '`claiming task <id> (next part <N>)`' \
  "step 4: next-part log line"

# ---------------------------------------------------------------------------
# Group 6: resume-task redirect
# ---------------------------------------------------------------------------
chk_prose "$RESUME_TASK" 'this is an unclaimed next part** → stop and point to `/atelier:next-task <id>`' \
  "resume-task: unclaimed next part -> redirect to /atelier:next-task"
chk_prose "$RESUME_TASK" '`/resume-task` is not an unguarded side door to a claim' \
  "resume-task: not a side door to a claim"
chk_prose "$RESUME_TASK" '(c) the `getTask(id)` record has `Ready` set; (d) at least one merged `task/<id>-*` PR exists' \
  "resume-task: signals (c) and (d)"
chk_prose "$RESUME_TASK" '(e) the plan'"'"'s approval timestamp (`ready (approved <ISO-8601 UTC> — product lead)`) is later than the newest `mergedAt`' \
  "resume-task: signal (e)"
chk_prose "$RESUME_TASK" '(f) no local `task/<id>-*` worktree exists (`git wt list`)' \
  "resume-task: signal (f)"
chk_prose "$RESUME_TASK" 'claim the next part with /atelier:next-task <id>.' \
  "resume-task: redirect message"
chk_prose "$RESUME_TASK" 'If `Ready` is already cleared (a next-part claim that consumed it and was then interrupted), none of this applies and the next bullet resumes it.' \
  "resume-task: consumed-Ready interrupted claim still resumable"
chk_prose "$RESUME_TASK" '**Status is in `inProgress` and no open PR exists** → **board-interrupted-resume mode**. Checked after the next-part bullet above.' \
  "resume-task: board-interrupted-resume kept, checked after the redirect"
chk_prose "$RESUME_TASK" 'Skip step 3; go to step 3b.' \
  "resume-task: step 3b still reached"

# ---------------------------------------------------------------------------
# Group 7: timestamped approval stamp
# ---------------------------------------------------------------------------
STAMP='ready (approved <ISO-8601 UTC> — product lead)'
chk_prose "$PLAN_TASK" "$STAMP" "plan-task: timestamped approval stamp"
chk_absent "$PLAN_TASK" 'ready (approved — product lead)' "plan-task: old untimestamped stamp gone"
chk_prose "$PLAN_TASK" 'a plan without the timestamp is never accepted as one' \
  "plan-task: plan without timestamp never accepted as a next part"
chk_prose "$PLAN_TASK" 'the next part can be planned — proceed as for any task' \
  "plan-task: In Progress + Ready clear is plannable, not refused"
chk_prose "$PLANNER" "$STAMP" "planner: timestamped approval stamp"
chk_prose "$PLANNER" 'the full UTC timestamp, e.g. `2026-10-22T14:03:00Z`' \
  "planner: full UTC timestamp example"
chk_absent "$PLANNER" 'ready (approved <date>)' "planner: old <date> stamp gone"

# ---------------------------------------------------------------------------
# Group 8: task-orchestrator step 1
# ---------------------------------------------------------------------------
chk_prose "$ORCH" '**Next part of a multi-part task (non-`files` backend only).**' \
  "orchestrator: next-part recognition present"
chk_prose "$ORCH" 'its Status is In Progress, its `Ready` is already consumed (cleared by the claim)' \
  "orchestrator: In Progress + Ready consumed"
chk_prose "$ORCH" 'timestamp is later than the newest merged `task/<id>-*` PR' \
  "orchestrator: plan timestamp later than newest merged PR"
chk_prose "$ORCH" 'no open `task/<id>-*` PR exists' \
  "orchestrator: no open PR"
chk_prose "$ORCH" 'No brief field carries this; recognise it from the item and the plan.' \
  "orchestrator: recognised from the item, no brief field"
chk_prose "$ORCH" 'A plan without the timestamp, or any signal missing, is not a next part' \
  "orchestrator: missing timestamp/signal -> not a next part"
chk_absent "$ORCH" 'claim_kind' "orchestrator: no claim_kind brief field"
chk_absent "$NEXT_TASK" 'claim_kind' "next-task: no claim_kind brief field"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "next-task-next-part-claim (#557): all assertions passed."
  exit 0
else
  echo "next-task-next-part-claim (#557): $fails assertion(s) failed."
  exit 1
fi
