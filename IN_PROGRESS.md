# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

<!-- Single-file layout: paste the task block from ROADMAP.md here. -->
<!-- Indexed layout: link to roadmap/TASK_NNN_<slug>.md and write progress notes inside that file, not here. -->

### M4.30 — Plan-gated execution: orchestrator only claims pre-planned, approved tasks

`[orchestrator]` `[planning]` · Source: operator request (2026-06-08) · Related: [PLAN.md §5](PLAN.md) (ROADMAP format + selection order), [agents/task-orchestrator.md](agents/task-orchestrator.md) (steps 1/4/5), [agents/task-decomposer.md](agents/task-decomposer.md), `task-discovery` skill

Today the `task-orchestrator` picks the highest-priority unchecked ROADMAP item and improvises its plan at execution time (only `task-decomposer` fires, and only for oversize-likely tasks — M4.24.b). The operator, who is non-technical, is then asked to confirm a plan they have no basis to evaluate. Invert this: **planning is a separate, explicit, product-lead-owned step that commits an approved plan into the repo, and the orchestrator only ever claims tasks that already carry one.** The orchestrator must never author or improvise a plan; an unplanned task is simply not claimable.

**Design (per operator decision 2026-06-08):** a dedicated **planner agent** invoked by the product lead via **`/plan-task <id>`**. The planner reads the task + scans the codebase and produces a concrete plan (approach, affected files/areas, acceptance criteria, decomposition into sub-tasks if oversize, risks/open questions). The product lead reviews and approves; approval commits the plan and marks the task **`[ready]`**. The orchestrator selects only `[ready]` items.

**Decisions taken (2026-06-10):**

- **Plan storage:** indexed, one `.plan/<id>.md` artifact per claimable unit in the target project (committed — it is approved spec + evidence). Not inline in the ROADMAP block; not the `roadmap/TASK_NNN` indexed layout.
- **Planner ↔ decomposer:** the planner owns the decomposition path — when a task is oversize-likely it invokes `task-decomposer` itself. The orchestrator's step-4 auto-decompose trigger is removed (a claimed task is already `[ready]` and, if needed, already decomposed).

**Scope:**

- [ ] **Planner agent** (`agents/planner.md`, Opus): reads a ROADMAP task, scans the repo, emits a structured plan. Does **not** write code. Subsumes / coordinates with `task-decomposer` for the oversize-split case (avoid two competing decomposition paths — decide whether the planner calls the decomposer or replaces its auto-trigger).
- [ ] **`/plan-task <id>` command** driven by the product lead: dispatches the planner, presents the draft, and on explicit product-lead approval commits the plan + flips the task to `[ready]`. Where the plan lives: inline in the ROADMAP block vs. an indexed `roadmap/TASK_NNN` file vs. a `.plan/` artifact — decide and document.
- [ ] **`[ready]` marker convention** added to [PLAN.md §5](PLAN.md): how readiness is written, how it interacts with `[ ]`/`[x]`/epic-derived checkboxes and `blocked_by`.
- [ ] **Orchestrator gate** ([agents/task-orchestrator.md](agents/task-orchestrator.md) step 1 + step 4): `task-discovery` selects only `[ready]` items; the orchestrator **refuses** an explicitly-named un-`[ready]` task with a clear message (*"task #<id> is not planned — run `/plan-task <id>` first"*), and **never** improvises a plan or asks the operator to approve one. Remove/replace the step-4 auto-decompose trigger accordingly.
- [ ] **`task-discovery` skill**: teach it the `[ready]` filter so auto-pick skips unplanned items the same way it skips `blocked_by`.
- [ ] **Operator/product-lead docs**: document the plan→approve→execute split and that the operator no longer approves improvised plans (ties into the M6.3 product-owner guide).

**Acceptance:** an un-`[ready]` ROADMAP task is never auto-picked and is refused on explicit pick with a pointer to `/plan-task`; running `/plan-task <id>`, having the product lead approve, commits a plan and marks the task `[ready]`; the orchestrator then claims it and runs the specialist chain **without** authoring its own plan or asking the operator to approve one.

**Trigger to revisit:** requested by the operator 2026-06-08 — the operator cannot meaningfully approve plans the orchestrator improvises, so planning must move upstream to the product lead. Natural follow-on to M7.1.F52 (orchestrator over-reaching into work that isn't its own).
