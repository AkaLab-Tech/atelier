# TASK_027 — `/plan-task` decomposition is lost when the plan commit is not pushed to `origin/main`

**Type:** `bug` · **Priority:** P2 · **Estimate:** `~TODO`

**Problem.** `/atelier:plan-task` commits the epic decomposition (the ROADMAP rewrite + `[ready]` flips) and the `.plan/<id>.md` files to the **local** base branch and explicitly does **not** push (`commands/plan-task.md`: *"Never push the commit. The plan commit lives on the current branch; the operator decides when to push"*). But `/atelier:next-task`'s `task-orchestrator` creates the task worktree branched from **`origin/main`**, so a plan/decomposition commit that never reached `origin/main` is invisible to it.

Observed 2026-06-23 on atelier-dev #22 (M9.5): the planner decomposed #22 → #22a/#22b/#22c with a local-only plan commit; the orchestrator implemented #22a from a worktree based on `origin/main` and merged PR #233 carrying only the 4 code/HISTORY files — the ROADMAP epic rewrite and `.plan/22b.md` / `.plan/22c.md` were dropped. The result was an inconsistent `origin/main` (HISTORY recorded #22a done while ROADMAP still showed an undecomposed #22), which had to be repaired with a separate tracking-only PR (#234).

**Scope (sketch).**
- Decide the contract: either (a) the `task-orchestrator` bases the task worktree on local `main` when it is ahead of `origin/main` (so an unpushed plan rides along), or (b) `/plan-task` lands its decomposition + `.plan/` on `origin/main` (e.g. via a small tracking PR) before the task is claimable.
- Whichever path: add a guard so claiming a `[ready]` task whose decomposition/plan is not on the worktree base **fails loudly** (or auto-reconciles) instead of silently operating on stale ROADMAP state.
- Update `commands/plan-task.md` / `commands/next-task.md` prose + a hermetic `hooks/tests/*.test.sh` to lock the chosen contract.

**Acceptance.** After `/atelier:plan-task` decomposes an epic, running `/atelier:next-task` on it produces a PR whose merge leaves `origin/main` **internally consistent** (ROADMAP, IN_PROGRESS, HISTORY, and `.plan/` all agree) with no manual reconciliation step. A decomposition that is not yet visible to the orchestrator is either carried automatically or rejected with a clear message — never silently dropped. Decompose at `/atelier:plan-task`.
