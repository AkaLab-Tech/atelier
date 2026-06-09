# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M7.1.F52 — Orchestrator performs specialist work inline instead of delegating

`[orchestrator]` · Source: dogfood (2026-06-05) · **Partially addressed** by [M7.1.F55](HISTORY.md) ([#142](https://github.com/AkaLab-Tech/atelier/pull/142)) — the `pr-author`-authoring slice (re-dispatch instead of absorb) is covered; the broader hardening below stays open.

The `task-orchestrator` ([agents/task-orchestrator.md](agents/task-orchestrator.md)) is specified as a planner/router that "does not write feature code, tests, or PR descriptions itself" and delegates to `implementer` → `tester` → `pr-author`. In real chains it sometimes does the work itself and ends up asking the operator implementation-level questions, bypassing the specialist boundary entirely. This collapses the per-agent safety scoping and the auditable chain checkpoints the design relies on.

**Scope:**

- [ ] Reproduce: capture a chain where the orchestrator skips a `Task` dispatch and acts inline (which step, what triggered it).
- [ ] Reinforce the delegation contract in the orchestrator prompt — make "never implement/test/author inline; always dispatch the specialist via `Task`" a hard refusal, not just a prose description.
- [ ] Close the gap that lets implementation-level questions reach the operator: genuine ambiguity routes through `decision-broker` or surfaces as a terminal state, never as an inline operator question.
- [ ] Consider a guard: if the orchestrator is about to edit source files or write tests directly, treat it as a bug and stop.

**Acceptance:** on a representative ROADMAP task, the orchestrator dispatches `implementer` / `tester` / `pr-author` via `Task` for all code/test/PR work and never edits source or asks implementation-level questions itself; any genuine ambiguity goes through `decision-broker` or a terminal hand-off.

**Trigger to revisit:** captured 2026-06-05 from live dogfooding. Fix before further orchestrator-flow work so the delegation boundary is trustworthy.
