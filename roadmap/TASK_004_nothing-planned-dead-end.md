# TASK_004 — Idea — actionable "nothing planned" dead-end: surface plan candidates

Surfaced finishing M7.1: when `/atelier:next-task` finds no `[ready]` task it stops with a bare "run `/atelier:plan-task` first" error. Instead, make the dead-end **actionable** — hand the operator a ranked shortlist of what to plan next, so `task` always returns something useful (either a started task or a precise "plan one of these").

**Where it lives:** in `task-discovery` + `/next-task`'s no-eligible-task path — **not** the `task-orchestrator` (the orchestrator is only dispatched *after* a task is claimed; with nothing claimable it never runs). `task-discovery` already parses the whole ROADMAP and knows each item's `[ready]` state, so it has the data — it just needs to **return the unplanned candidates** instead of only an error.

**Smart dead-end, by ROADMAP state:**
- **§5 backlog with unplanned candidates** → ranked shortlist (P0 > P1 > P2, tie-break by *no open `blocked_by`*), each line `#id · title · priority · why-not-ready`, suggesting `/atelier:plan-task #X`.
- **Non-§5 ROADMAP** (nothing parseable) → suggest `/adopt-roadmap --format atelier` first (the deminut state today).
- **Empty backlog** → say so.

**Interaction:**
- **Interactive** → offer to plan one now (`AskUserQuestion` → dispatch `/atelier:plan-task #X`).
- **Headless** (`ATELIER_AUTO`) → only print the list; never auto-plan — approving a plan is a human gate by design.

**Trigger to revisit:** soon — it directly improves the most common autonomous dead-end (validated live during M7.1: a real run on deminut hit exactly this, and an ad-hoc list was helpful but not guaranteed).
