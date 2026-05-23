# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M4.14 — Implement↔validate inner loop with iteration budget

The `/next-task` chain currently runs implementation and validation as a single forward pass. Any failure (lint, typecheck, unit tests) falls through to the `retry-with-logs` skill, which resets the worktree and restarts the entire task. There is no cheap inner loop where the implementer can iterate against quick validation before committing to the heavier PR-gate path.

This task introduces an explicit implement↔validate loop driven by `task-orchestrator`, separating fast checks (run on every iteration) from slow checks (run once, before PR):

1. **`/validate`** — new slash command that runs the **fast** validation layer (lint + typecheck + unit/integration tests) and prints a structured result (pass/fail + per-check output). Invocable standalone for manual debug.
2. **`/validate --full`** — adds the **slow** layer (Playwright e2e + screenshot capture). Run once before `/pr-flow`, never inside the loop.
3. **`task-orchestrator` loop logic** — after `implementer` returns, the orchestrator calls `/validate`. On fail, it re-invokes `implementer` with the validation output appended to the prompt (so the next attempt sees what failed). The loop counter is anchored to the existing 3+3 retry budget from [PLAN.md §8](PLAN.md): up to 3 inner iterations → trigger `retry-with-logs` worktree reset → up to 3 more inner iterations → hard stop with the existing `blocked` issue path.
4. **Iteration counter** — persisted at `<worktree>/.task-log/attempt-count` so a session restart does not silently reset the budget.

The hook-driven variant (auto-reprompt on `Stop`) is captured separately as M4.15 — alternative path, not a replacement for the orchestrator-driven loop.

**Acceptance:**

- `/validate` exists as a standalone command and prints a structured pass/fail summary.
- Running `/next-task` on a task whose first implementation attempt fails lint/typecheck/unit-tests triggers an automatic in-place re-implementation **without** a worktree reset, up to 3 times.
- On the 4th failure, `retry-with-logs` resets the worktree and iteration 4 begins fresh; iterations 4–6 follow the same inner-loop pattern.
- On the 7th total failure, the task is marked `[BLOCKED]` with the existing GitHub issue flow (must not regress).
- `task-orchestrator` prompt explicitly documents the loop contract and the counter location.

**Trigger to revisit:** when an implementation attempt routinely fails on issues that do not require a full worktree reset to fix (typos, missing imports, lint-only). Identified in conversation 2026-05-21 — the current single-pass-then-reset flow over-rotates on full resets when a cheap inner loop would catch most trivial mistakes.

**Progress notes:** worktree `task/m4.14-implement-validate-loop` created 2026-05-23 from `dbc4b8c` (post-#64 merge). MINOR bump (`0.1.0` → `0.2.0`) per PLAN.md §14.2 (new slash command + material change to task-orchestrator).
