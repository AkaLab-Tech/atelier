# Roadmap

Backlog of work for this project. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Each task lives here as a heading with whatever description it needs (acceptance criteria, design notes, sub-tasks). When work starts, move the block to `IN_PROGRESS.md`.

Tasks are derived from the implementation plan in [PLAN.md §12](PLAN.md). Milestone IDs (M1.1, M2.3, …) refer to that plan and are kept in titles for traceability. Always read the referenced PLAN.md section before starting a task.

---

## High Priority

> **Phase 1 — Foundation.** Blocks everything else. A fresh Mac must be able to run `install.sh`, log in to Claude + GitHub, and end with the `atelier` plugin installed and `/doctor` ✅.

---

## Medium Priority

> **Phases 2–5 — Single-project agent flow + robustness + multi-project foundation.** Done when the toy-repo flow can pick a task, implement it, open a reviewed PR, auto-merge it, clean up, and survive failures with retries — and when an operator can install / uninstall atelier without risking unrelated Claude state.

---

## Low Priority / Ideas

> **Phases 5–7 + deferred v2 patterns.** Multi-project, docs, end-to-end validation, and the OMC-borrowed ideas from PLAN.md §11.

### M4.4 — Blocked-task visibility in `/status`

Extend the existing `/status` command so it also lists tasks currently marked `[BLOCKED]` in `IN_PROGRESS.md`, with their issue URL and the count of attached `.task-log/*.md` entries. Today the operator only sees blocked tasks by filtering GitHub Issues by label `blocked` or by reading `IN_PROGRESS.md` manually — neither is discoverable from inside a Claude session.

**Acceptance:** `/status` on a project with N blocked tasks prints `Blocked: N` followed by one line per task with `<id> — <title> — <issue-url>`.

**Trigger to revisit:** when the operator starts having more than ~2 blocked tasks open simultaneously and finding them becomes friction. Identified while designing M4.2 — deferred because the M4.2 + M4.3 loop is functional without it; this is pure quality-of-life.

### M4.5 — `/abandon-task <id>`

A slash command for the Camino C of the blocked-task lifecycle (operator decides the task will not be retried). Today this requires the operator to (a) close the GitHub `blocked` issue with a `wontfix` comment and (b) manually move the entry from `IN_PROGRESS.md` to `HISTORY.md` with an "abandoned" note. The command automates both steps:

1. Close the GitHub `blocked` issue with a `wontfix` reason comment.
2. Move the `[BLOCKED]` entry from `IN_PROGRESS.md` to `HISTORY.md` under an explicit `### <id> — <title> — abandoned — <date>` heading.
3. Preserve the `.task-log/` directory inside the worktree (post-mortem evidence stays in case the task is ever revived) and `git wt rm` the worktree only after the operator confirms.

**Acceptance:** running `/abandon-task <id>` on a `[BLOCKED]` entry closes the issue with `wontfix`, moves the entry to `HISTORY.md` with `abandoned` mark, and removes the worktree (with confirmation).

**Trigger to revisit:** after M4.2 + M4.3 land and the operator hits a real "I'm not retrying this" situation. Identified while designing M4.2 — deferred because the manual workaround (close issue + edit two markdown files) works fine for the rare case where a task is genuinely abandoned.

### M4.21 — `/validate` Python toolchain in `allowed-tools` frontmatter

`commands/validate.md` (added in [M4.14](HISTORY.md) / PR #65) detects Python-project tooling in its body (`ruff` for lint, `mypy` / `pyright` for typecheck, `pytest` for tests via `pnpm` script) but its `allowed-tools` frontmatter only explicitly grants the JS/TS toolchain (`Bash(eslint:*)`, `Bash(biome:*)`, `Bash(tsc:*)`, `Bash(vitest:*)`, `Bash(jest:*)`, etc.) plus a single `Bash(pytest:*)` and `Bash(playwright:*)`. Missing: `Bash(ruff:*)`, `Bash(mypy:*)`, `Bash(pyright:*)`.

Concrete effect on a Python project: the first time `/validate` tries to invoke any of those three tools, the Claude Code harness prompts the operator for permission ("Allow `Bash(ruff check)` once / always?"). Same outcome as Phase 0 of any new permission — not broken, just interactive. The inner loop ([M4.14](HISTORY.md)) under `claude -p` would stall on that prompt.

**Scope:**

- [ ] Add `Bash(ruff:*)`, `Bash(mypy:*)`, `Bash(pyright:*)` to `commands/validate.md` frontmatter `allowed-tools`.
- [ ] Sanity check: any other Python-friendly invocations the body uses (e.g. `pnpm` is already covered; if `pdm` / `uv` / `poetry` are later added to the detection logic, allowlist those too).
- [ ] No behavior change — purely a permission-prompt prevention.

**Acceptance:** running `/atelier:validate` against a Python project (`pyproject.toml` with `[tool.ruff]` + `[tool.mypy]`) under `claude -p` completes without a permission prompt for any of the three tools. Static check: `grep -E "Bash\\(ruff|Bash\\(mypy|Bash\\(pyright" commands/validate.md` returns 3 matches.

**Trigger to revisit:** when the first Python project gets `/atelier:setup-project`-ed and `/validate` runs against it. Until atelier sees a Python project in real use, this is purely defensive — captured here so the next operator who hits the prompt knows the fix is one frontmatter edit. Identified during PR #65 pre-merge review (2026-05-23).

### M4.15 — `Stop`-hook auto-reprompt on validation failure (exceptional path)

`blocked_by: M4.14`

Complement to M4.14. Where M4.14 puts the implement↔validate loop inside `task-orchestrator` (the orchestrator reads the validation output and decides whether to re-invoke `implementer`), M4.15 explores doing the same thing one layer lower — at the harness level, via a `Stop` hook that triggers automatically when an assistant turn ends with a failed validation.

The hook script:

1. Detects that the last turn ran `/validate` (or `/validate --full`) and the exit was failure.
2. Reads `<worktree>/.task-log/attempt-count` and increments it. If the count exceeds the 3+3 budget, the hook does **nothing** — the orchestrator-side `blocked` issue path takes over.
3. Emits a structured retry prompt back to Claude containing:
   - An explicit `RETRY-attempt-N / 6` header (so the model knows this is not a fresh task and how much budget remains).
   - The full output of the failed validation (stdout + stderr from the failing checks) verbatim.
   - A directive: *"the previous attempt failed the checks below — correct the issues without restarting the task; do not reset the worktree".*

This is **not** the primary loop mechanism (M4.14 is). It is captured as an alternative for cases where the orchestrator-driven loop is too high-latency (long agent dispatch overhead per turn) or where the operator wants the loop to keep running across session restarts without re-entering `/next-task`.

**Acceptance:**

- A `Stop` hook script under `hooks/` detects validation-failure conditions and emits a structured retry prompt with `RETRY-attempt-N` framing and the previous validation output verbatim.
- The hook respects the same 3+3 budget anchored to `<worktree>/.task-log/attempt-count` (the file written by M4.14) — never exceeds it, never bypasses the `blocked` issue path.
- Hook is **opt-in** (off by default), enabled via a per-project setting or env var — atelier ships without it active to avoid surprising the operator.
- When active, the hook composes with M4.14 cleanly (no double-incrementing the counter, no race between orchestrator-driven and hook-driven reprompts).

**Trigger to revisit:** after M4.14 is in production and the operator observes that orchestrator dispatch latency dominates iteration time, **or** wants the loop to survive a session restart. Captured in conversation 2026-05-21 as an exceptional-case mechanism — the operator likes the idea but explicitly tagged it as "for later".

### M5.1 — Project registry

`~/.claude-work/projects.json` tracks every project the operator has set up. Fields per project: path, name, last-task timestamp, setup version.

### M5.2 — `/setup-project` full bootstrap

Extend the Phase 2 command to be the canonical multi-project entry point: registers in `projects.json`, creates `.claude/settings.json`, project `ROADMAP.md`, project `.claude/CLAUDE.md`, project `.npmrc` (pnpm guardrails), `.gitignore` entries.

### M5.3 — `task` alias resolves project from cwd

Shell alias detects which registered project the cwd belongs to and opens a Claude session that auto-invokes `/next-task` for that project. Falls back to a project-picker menu if cwd is not inside a registered project.

### M6.1 — `update.sh`

Incremental updater per [PLAN.md §9](PLAN.md): `git pull` → diff changed files → apply deltas → if `settings.template.json` changed, prompt the operator with a human-readable permissions diff (added / removed / impact) before applying.

### M6.2 — Operator guide

Junior-friendly walkthrough: clone → install → first task. No git/branching/PR jargon.

### M6.3 — Product owner guide (ROADMAP.md format)

How to write [PLAN.md §5](PLAN.md)-shaped roadmaps: priorities, types, estimates, `blocked_by`, acceptance criteria. With examples.

### M6.4 — Troubleshooting doc

Common failure modes and recovery: auth expired, plugin not loading, hooks blocking unexpectedly, `git-wt` misconfigured, `.npmrc` guardrail false-positives.

Two specific items captured during dogfood-1 that belong here:

- **GitHub same-identity self-approval limitation.** When `pr-author` and `reviewer` run under the same GitHub identity (the operator's, in single-developer projects), GitHub silently downgrades the reviewer's `gh pr review --approve` to a comment, which trips both auto-merge guardrails #2 (review status) and #6 (pending human comment). The auto-merge skill is correct to hold the PR. Two operator-side mitigations to document: (a) configure a separate bot identity for `atelier:reviewer` (recommended for ≥1 active project), or (b) accept that single-developer projects always merge manually and add `--squash --delete-branch` to the operator's muscle memory. Identified in dogfood-1 (Finding #11).
- **Claude Code permission-cache mis-alignment after worktree reset.** When `retry-with-logs` triggers the reset between attempt 03 and 04, the worktree is recreated via `git worktree remove --force` + `git worktree add`. The harness's permission cache continues to apply the pre-reset deny list against the recreated worktree path inconsistently — in dogfood-1, two separate `Edit` calls on a deny-listed path succeeded in attempts 04 and 05 (and were reverted to honor the hard refusal). Mitigation until Claude Code fixes the harness: between attempt 03 and attempt 04, the operator should restart the Claude Code session, or the orchestrator should surface a warning that enforcement is undefined post-reset. Identified in dogfood-1 (Finding B).

### M7.1 — Dogfood on a real (non-toy) project

Run a full task cycle on an actual project. Capture friction.

### M7.2 — Iterate the network allowlist

Grow the allowlist organically based on what M7.1 needs. Document each addition with a one-line justification.

### M7.3 — Measure autonomous merge rate

Sample 10 real tasks; compute the % that reach merged state without human intervention. Target ≥80%.

### v2 ideas (deferred)

Per [PLAN.md §11](PLAN.md). Revisit only after v1 is stable.

- v2.1 — Skill auto-injector hook (`UserPromptSubmit`) to load skills by context signals.
- v2.2 — Router skill with subcommands (`/atelier setup|doctor|update|reconfigure`).
- v2.3 — `PermissionRequest` Bash hook for dynamic permissions, replacing static `settings.template.json`.
- v2.4 — Project-memory hooks (`SessionStart` + `PostToolUse`) to auto-persist project learnings.
- v2.5 — `/learner` + `/skillify` to extract reusable patterns from successful tasks.
- v2.6 — Node.js hook dispatcher (`scripts/run.cjs`) for portable, fail-open hook execution.

### Out of scope for v1

Per [PLAN.md §11](PLAN.md). Listed here so they are not picked up by accident: multi-repo coordination, deployment/release management, cost monitoring / per-task budgets, visual regression baselines, ROADMAP ↔ Issues bidirectional sync.
