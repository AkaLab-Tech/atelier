---
backend: github-project
backendId: PVTI_lADOCSHEDc4Bbr7mzgw4dds
---
# TASK_024 — Auto review-fix loop on `request-changes`

**Type:** `feat` · **Priority:** P2 · **Estimate:** `~TODO`

**Problem.** When `reviewer` returns `request-changes`, the orchestrator stops and leaves the PR for manual follow-up (`agents/task-orchestrator.md:175`). There is no automatic fix→re-review iteration. The operator wants the cycle to "review, approve, merge — and if it does not approve, repeat."

**Scope (sketch).**
- On `request-changes`, automatically re-dispatch `implementer` (and `tester`) to address the reviewer's findings on the same `task/*` worktree, then re-run `reviewer`.
- Bound the loop (e.g. N iterations) tied into the PLAN.md §8 retry budget so it cannot spin forever; on exhaustion, fall back to the operator with the accumulated review findings + attempt logs.
- Each re-review starts fresh-context (the reviewer already does); feed it the prior findings + the fixing diff.

**Acceptance.** A PR that gets `request-changes` is automatically iterated (fix → re-review) up to the bound; if it converges to `APPROVED` + green CI, it proceeds to `auto-merge`; if it exhausts the budget, it escalates to the operator. Decompose at `/atelier:plan-task`.
