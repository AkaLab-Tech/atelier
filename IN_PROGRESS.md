# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M7.3 — Measure autonomous merge rate

`[feat][instrumentation]` · Source: PLAN.md §12 Phase 7, M7.3

PLAN.md's Phase 7 acceptance ("≥ 80% of a sample of 10 real tasks complete to a merged PR autonomously") is the ship gate for v1. This entry has two distinct phases:

- **Tooling (this PR)**: ship `scripts/atelier-measure-merge-rate` — a script that samples N recent merged PRs from a repo and classifies each as "autonomous" or "intervention required" against a documented heuristic.
- **Observation (post-PR, observational)**: once N ≥ 10 atelier-driven tasks have been merged on a real project (dogfood-4 or other), run the tool and report. That decision (does the rate hit 80%?) is the formal Phase 7 ship gate, not part of this PR.

**Scope (tooling only):**

- [ ] Create `scripts/atelier-measure-merge-rate` (bash). Flags: `--sample N` (default 10), `--repo OWNER/NAME` (default detected from cwd via `gh repo view`), `--author HANDLE` + `--reviewer HANDLE` (defaults auto-detected from `GH_CONFIG_DIR=$ATELIER_CONFIG_DIR/gh/{author,reviewer} gh api user --jq .login`). Outputs a markdown table to stdout + summary line "X / N autonomous (P%)" + pass/fail vs the 80% threshold.
- [ ] Symlink from `install.sh:phase_c_1_setup_project_helper` alongside `atelier-doctor` / `atelier-task-resolve`.
- [ ] Document the classification heuristic in `docs/measurements/autonomous-merge-rate.md`. A PR is "autonomous" iff (a) author = `--author` handle, (b) ≥1 approval review from `--reviewer` handle, (c) no review comments or change requests from any account other than `--author` or `--reviewer`. Permissive enough to capture intent; honest about what it cannot detect (Claude Code session restarts the operator did manually, etc.).
- [ ] Empirical smoke test: run against the last N PRs in `AkaLab-Tech/atelier` itself. Every PR in this session was maintenance driven by the user — the tool should report 0% autonomous, which validates that it doesn't fabricate passing data.
- [ ] Cross-link the methodology doc from `docs/troubleshooting.md` (when measurements diverge from expectation) and from the `Reference` table in `docs/operator-guide.md`.

**Acceptance:**

- `bash -n scripts/atelier-measure-merge-rate` passes.
- `atelier-measure-merge-rate --sample 10 --repo AkaLab-Tech/atelier --author Miguelslo27 --reviewer Miguelslo27` runs to completion and reports a number (the result itself is observational data, not an acceptance criterion).
- `docs/measurements/autonomous-merge-rate.md` exists with: methodology, classification rules verbatim, how to interpret pass/fail, why "0% on the M2.5→M7.3 maintenance PRs" is expected and what would change.
- HISTORY entry explicitly notes the observation phase is deferred until N atelier-driven tasks land.

**Out of scope:**

- Running the formal 10-task measurement (depends on dogfood-4 or another live project completing tasks).
- Automated CI integration (running the metric on every merge) — that's nice-to-have, not v1.
- A dashboard or graphing — markdown output to stdout is the v1 surface.
