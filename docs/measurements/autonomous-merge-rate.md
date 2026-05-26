# Autonomous merge rate — methodology

PLAN.md §12 Phase 7 names a single ship gate for v1: **≥80% of a sample of 10 real tasks complete to a merged PR autonomously**. This document explains how that's measured.

The tool is `scripts/atelier-measure-merge-rate` (symlinked into `~/.local/bin` by `install.sh`).

## How to run

```bash
atelier-measure-merge-rate --sample 10 --repo <OWNER/NAME>
```

Optional flags: `--author HANDLE` and `--reviewer HANDLE` (auto-detected from the atelier-isolated `gh` config dirs when omitted), `--threshold PCT` (default 80).

Output is markdown on stdout. Exit code is 0 when the autonomous rate meets the threshold, 1 when it doesn't, 2 on usage / runtime errors.

## What "autonomous" means

A PR is classified **autonomous** iff ALL of:

1. **Author is the atelier-author identity.** The PR was opened by the agent that writes code, not by a human typing `gh pr create`.
2. **At least one approval from the atelier-reviewer identity.** The reviewer agent (running under a different GitHub account per M5.0.1) signed off. Same-identity approvals get silently downgraded to comments by GitHub (dogfood-1 finding #11) and the tool counts those correctly as non-approvals.
3. **No reviews or comments from accounts other than atelier-author + atelier-reviewer.** A human comment or `request-changes` mid-review is a sign someone stepped in — possibly to nudge the agents toward a fix. Auto-merge would have held the PR on pending human comments (PLAN.md §6 guardrail #6).

Anything else classifies as **intervention required**. The reason column on each row says specifically what disqualified the PR.

## What this measurement can NOT detect

The heuristic is permissive — the autonomous count is an **upper bound** on true autonomy. The tool sees GitHub's data only and cannot detect operator actions that leave no PR trace:

- The operator restarted a stuck Claude Code session between attempts (dogfood-1 finding B mitigation). The retry that landed the PR looks like part of the normal flow to GitHub.
- The operator edited `IN_PROGRESS.md` to refine a task mid-run.
- The operator gave verbal direction to atelier inside the Claude chat that influenced the implementation.
- The operator manually merged a PR that the reviewer agent had approved (the merger record reflects the human, but a script using "approved by reviewer" as the signal would still count it).

These actions DO matter for the "autonomous" claim, but they're invisible to GitHub's API. The tool reports the upper bound honestly and the operator interprets the result with knowledge of any out-of-band interventions.

## How to interpret the report

The markdown report has three sections:

- **Header** — identities + threshold used.
- **Per-PR classification** — one row per sampled PR. `✓ autonomous` or `✗ intervention`, with the reason.
- **Summary** — autonomous count / total + percentage + PASS/FAIL vs threshold.

PASS means the rate clears the threshold. FAIL means it doesn't — more dogfood needed before claiming the Phase 7 ship gate.

## Why this PR initially reports 0%

The smoke test for this milestone, run on the M2.5→M7.3 maintenance PRs in `AkaLab-Tech/atelier` itself, reports `0 / 10 autonomous`. That is **expected and correct**:

- Every PR in that range was authored manually by the maintainer (or by Claude on the maintainer's behalf during a Claude Code conversation), not by atelier's autonomous loop.
- None went through the `task` → `task-orchestrator` → implementer → tester → pr-author → reviewer → auto-merge chain.
- Same-identity self-approval (one human controlling both atelier-author and atelier-reviewer identities) means no row gets credit for criterion 2.

The 0% result validates that the tool doesn't fabricate passing data on PRs that clearly weren't autonomous. The formal Phase 7 measurement runs against a different sample: PRs landed by atelier on a real dogfood project (currently `~/Work/atelier-dogfood-4` or successor).

## When the formal measurement should be re-run

PLAN.md Phase 7's "done when" is observational — it depends on real atelier usage. Run the tool again whenever any of the following changes:

- N ≥ 10 atelier-driven PRs have merged on the dogfood project (or another live atelier-managed project).
- A new milestone lands that affects the autonomy chain (retry budget, reviewer prompt, auto-merge guardrails).
- The atelier-reviewer identity changes (e.g. from same-account to a separate bot account).

Record each run's result in a sibling file under `docs/measurements/` so the trend is preserved.

## Limitations to revisit in v2

- The heuristic depends on GitHub's review state being populated correctly. PRs auto-merged by GitHub Actions or external bots may produce edge cases the heuristic doesn't model.
- "No foreign comments" is a strict criterion. A `dependabot` or `github-actions` bot comment would count as foreign. Add a `--allow-bot HANDLE` flag (or read a default list) if that becomes a real problem.
- Per-task latency is not measured here. A task that takes 6 hours and one that takes 6 minutes both count as one PR if autonomous. If wall-time matters for the ship claim, a separate metric is needed.
