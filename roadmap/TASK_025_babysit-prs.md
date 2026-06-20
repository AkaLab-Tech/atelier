# TASK_025 — `/atelier:babysit-prs` — watch open `task/*` PRs and drive them to merge

**Type:** `feat` · **Priority:** P2 · **Estimate:** `~TODO`

**Problem.** No command watches open PRs. After the chain finishes (or holds on pending CI / pending review), nothing re-evaluates the PR — the operator must re-invoke manually. There is no autonomous "babysitter."

**Scope (sketch).**
- A `/atelier:babysit-prs` command (loopable; can build on the `/loop` skill) that enumerates open `task/*` PRs across the current project (or workspace), and for each: checks CI, dispatches/`reviewer` if not yet reviewed, and drives it through the `auto-merge` skill once eligible.
- Surface a per-PR status line (green→merged, pending-CI→waiting, request-changes→needs fix, guardrail-held→reason).
- Read-only enumeration first; the only writes are review posts + guardrail-passing merges (respect §6, including the never-auto-merge set).
- Compose with #023 (CI wait) and #024 (review-fix loop) once those land.

**Acceptance.** Running `/atelier:babysit-prs` (optionally under `/loop`) converges every eligible open `task/*` PR to merged without manual re-invocation, and clearly reports the ones legitimately held for the operator. Decompose at `/atelier:plan-task`.
