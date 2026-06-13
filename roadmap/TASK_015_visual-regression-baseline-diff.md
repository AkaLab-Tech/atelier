# TASK_015 — Visual regression (baseline diff)

**Deferred to v2** (was PLAN.md §11 — out of scope for v1; v1 uses raw screenshots). Revisit after v1 is stable.

Add baseline-diff visual regression on top of the existing screenshot capture in `e2e-runner` / `visual-validation` (today: raw screenshots only, no comparison).

**Scope:**

- Store per-project visual baselines (committed, or via secret gist — consistent with how screenshots are uploaded today).
- On an e2e run, diff each screenshot against its baseline with a configurable threshold.
- A diff above threshold fails the PR gate (or flags the PR), attaching the before / after / diff images.
- First run / missing baseline: capture-and-store, do not fail.

**Acceptance:** a UI change that exceeds the diff threshold flags the PR with before / after / diff images; an unchanged UI passes; baselines are versioned (committed or gist) and updatable.

**Trigger to revisit:** after v1's raw-screenshot e2e flow has real mileage and the tolerance for diffing (false-positive rate) is understood.
