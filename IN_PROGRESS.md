# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M2.9 — Custom `PreToolUse` Haiku hook as targeted second layer above auto-mode (formerly PLAN §11 v2.3)

`[security-design]` · Source: [docs/research/permission-layer-3.md](docs/research/permission-layer-3.md) Recommendation · `blocked_by: M2.8 (closed, PR #114)`

Originally tracked as PLAN.md §11 v2.3. The M2.6 spike confirmed it complements auto-mode rather than replaces it — useful for the narrow residual high-risk surface where the documented ~17% FN rate of auto-mode matters (e.g. anything touching `pnpm-lock.yaml`, deploy paths, never-auto-merge files).

**Status note:** started speculatively. The ≥10-merged-tasks-under-auto-mode bar is met, but no false-negative incident of the relevant class is in HISTORY — the operator chose to build it now anyway (decision recorded; the PR description states this). Branch: `feat/m2-9-layer3-haiku-hook`.

**Scope:**

- [x] A `PreToolUse` Bash hook that calls Haiku 4.5 with a structured prompt: tool name, args, the risk-class tag of the path being touched (if any), the task's `CLAUDE.md` excerpt about deploy/secrets. — `hooks/semantic-risk-judge.sh`
- [x] Cache **disabled** — every invocation is a fresh judgment. The OMC reference design caches per command string; atelier does not, because the same command can be safe or unsafe depending on cwd and surrounding state.
- [x] Logs decisions to `<worktree>/.task-log/hook-decisions.jsonl` for post-mortem and operator review.
- [x] Scope: project-level only (not global). Operator opts in per project by adding `semanticRiskJudge.enabled: true` to `.atelier.json`.

**Implementation status:** code complete on `feat/m2-9-layer3-haiku-hook`, verified locally (bash -n, JSON parse, dry-runs of all four decision paths + catalogue coverage). Pending: open PR, then move this block to `HISTORY.md` in the same PR.

**Decisions (operator-confirmed):** fail-open on Haiku unavailability (allow + log degraded); risky verdict escalates to `ask`, never hard `deny`; a cheap local risk-gate runs before any model call so only high-risk commands invoke Haiku.

**Acceptance refinement:** the original PLAN.md §11 v2.3 surface is made concrete — the high-risk surface is catalogued in `hooks/patterns/semantic-risk-judge.json` (lockfile, container build, CI/CD, manifest, deploy paths) with a `riskClass` tag per entry.

**Plugin bump:** **0.13.0 → 0.14.0** (new hook = minor, PLAN.md §14.2). Cut release `v0.14.0`.
