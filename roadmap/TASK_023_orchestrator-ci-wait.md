---
backend: github-project
backendId: PVTI_lADOCSHEDc4Bbr7mzgw4dck
---
# TASK_023 — Orchestrator waits for the CI cycle before the auto-merge gate

**Type:** `feat` · **Priority:** P2 · **Estimate:** `~TODO`

**Problem.** `auto-merge` (`skills/auto-merge/SKILL.md`) evaluates CI **once**: if `statusCheckRollup` has any check still `IN_PROGRESS`/`QUEUED`, it holds and returns (`SKILL.md:207` — *"Never retry on a transient guardrail failure (CI still running)"*). So when the specialist chain finishes before CI goes green, the cycle stops short and the PR is left for a manual re-invoke. The operator wants the full cycle to include waiting for the CI/CD run.

**Scope (sketch).**
- Add a bounded CI wait before the merge gate — e.g. `gh pr checks <NN> --watch` with a timeout / max-poll budget — so a still-running CI **waits then re-evaluates** instead of holding-and-stopping.
- Distinguish *pending* (wait) from *failed* (stop, surface) cleanly. A `FAILURE` must NOT be waited on.
- Keep it interruptible and budget-bounded; respect the existing six guardrails unchanged after CI resolves.

**Acceptance.** A task whose CI is still running when the chain ends results in atelier **waiting** for the checks to complete and then merging (if all guardrails pass) or surfacing the failure — without a manual re-invoke. Decompose at `/atelier:plan-task`.
