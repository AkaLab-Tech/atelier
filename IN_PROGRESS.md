# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M7.1.F52 — `pr-author` ended its turn at the green push gate without committing/pushing/opening the PR; orchestrator absorbed the work inline

`[dogfood-fix]` · Discovered during M7.1 dogfood Nivel 4 on `storefront` (task BUG-RESILIENCE.1, 2026-06-02). Transcript evidence: `pr-author` subagent `agent-a5128c32f3e1e5d3b` returned with `stop_reason: end_turn` and `output_tokens: 245` right after `safe-commit` reported `GREEN — commit allowed` — no `git commit`, no SHA, no PR. The orchestrator then finished the commit/push/PR inline instead of re-dispatching `pr-author`.

**Root cause:** `pr-author` confused the gate verdict (a *precondition*) with its deliverable (the *PR URL*). `safe-commit`'s green report ending in `commit allowed` reads like a finish line, and the orchestrator had no rule against absorbing a specialist's role inline (the explicit "never absorb inline" rule existed only for `unblocker`).

**Scope:**

- [ ] `agents/pr-author.md` — state that the push gate is a precondition, not the deliverable; enumerate the only valid terminal states (PR URL / `oversized` / gate-red→`tester`); forbid ending the turn after a green gate.
- [ ] `skills/safe-commit/SKILL.md` — add a mandatory `Next step:` line to the green report (anchor line `Result: GREEN — commit allowed.` kept stable for the parser) + a decision rule that `GREEN` ≠ "done".
- [ ] `agents/task-orchestrator.md` — detect an INCOMPLETE `pr-author` return (gate green, no PR URL/SHA), route it through `retry-with-logs` and re-dispatch; add a decision rule forbidding inline absorption of `pr-author`'s role.

**Plugin bump:** **0.13.0 → 0.13.1** (behavioral fix to agent/skill specs, PLAN.md §14.2 patch). Cut release `v0.13.1`.

**Acceptance:**

- `pr-author.md` makes ending the turn at a green gate an explicit malformed return.
- `safe-commit` green report carries the `Next step:` guard line; anchor line unchanged.
- `task-orchestrator.md` has both an `incomplete` handling branch (step 8) and a "never absorb `pr-author` inline" decision rule.
