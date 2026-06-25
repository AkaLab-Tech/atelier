---
backend: github-project
backendId: PVTI_lADOCSHEDc4Bbr7mzgw4dnw
---
# TASK_014 — Cost monitoring / per-task budget caps

**Deferred to v2** (was PLAN.md §11 — out of scope for v1). Revisit after v1 is stable.

Track token / cost usage per task and enforce an optional budget cap, mirroring the fixed retry budget in [PLAN.md §8](PLAN.md).

**Scope:**

- Accumulate per-task token / cost from the agent-chain logs (`.task-log/`).
- Optional cap in `.atelier.json` (e.g. `taskBudget.maxTokens` / `taskBudget.maxUSD`).
- When the cap is exceeded mid-chain: stop the chain and escalate (surface a budget-exceeded log entry, analogous to the hard-stop / `blocked` path), never silently continue.
- Off by default — no cap configured ⇒ current behavior unchanged.

**Acceptance:** a task that exceeds its configured budget halts with a budget-exceeded log entry; with no budget configured the chain behaves exactly as today; per-task cost is recorded in `.task-log/` regardless of whether a cap is set.

**Trigger to revisit:** after v1 is stable and real per-task token spend is observable enough to set sane defaults.
