# Roadmap

Backlog of work for this project. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Each task lives here as a heading with whatever description it needs (acceptance criteria, design notes, sub-tasks). When work starts, move the block to `IN_PROGRESS.md`.

Tasks are derived from the implementation plan in [PLAN.md §12](PLAN.md). Milestone IDs (M1.1, M2.3, …) refer to that plan and are kept in titles for traceability. Always read the referenced PLAN.md section before starting a task.

---

## High Priority

> **Phase 1 — Foundation.** Blocks everything else. A fresh Mac must be able to run `install.sh`, log in to Claude + GitHub, and end with the `atelier` plugin installed and `/doctor` ✅.

---

## Medium Priority

> **Phases 2–4 — Single-project agent flow + robustness.** Done when the toy-repo flow can pick a task, implement it, open a reviewed PR, auto-merge it, clean up, and survive failures with retries.

### M2.2 — Phase 2 skills

Author `task-discovery` (parses ROADMAP §5 format), `pr-flow` (branch → commit → push → PR), `safe-commit` (lint + typecheck + tests pre-commit), `safe-install` (audit + `pnpm view` before `pnpm add`). The `git-wt` skill ships from the external package — do **not** re-implement.

**Acceptance:** each skill is auto-discovered from `skills/`, has a SKILL.md with clear triggers, and is exercised by at least one slash command.

### M2.3 — Phase 2 slash commands

Author `/next-task`, `/status`, `/finish-task`, `/setup-project`, `/doctor`. `/next-task` instantiates the per-task `settings.json` from `settings.template.json` with the worktree path injected. `/setup-project` writes the project's `.npmrc` guardrails (`ignore-scripts=true`, `minimum-release-age=10080`, `audit-level=moderate`) per PLAN.md §4, and is idempotent via `~/.claude/.atelier-config.json` (`setupCompleted` ISO timestamp + `setupVersion`); re-running offers a reconfigure flow.

**Acceptance:** in a toy repo, `/next-task` runs end-to-end (pick task → worktree → implement → PR draft) without manual intervention.

### M2.4 — Phase 2 hooks (dynamic security layer)

Implement the `PreToolUse` hook suite that complements the **static** permissions matrix from M1.4 / `settings.template.json`. The static matrix decides *which tool* an agent can invoke; these hooks decide *with what content*. Neither layer alone is enough — see [PLAN.md §3](PLAN.md) "Defense-in-depth".

- [ ] `block-env-commit` (`PreToolUse` on `git add`/`git commit`): blocks any path matching `.env*` with a clear message.
- [ ] `safe-commit` (`PreToolUse` on `git commit`): lint + typecheck + tests gate before the commit lands.
- [ ] `scan-edit-write` (`PreToolUse` on `Edit`/`Write`): scan the proposed file contents for security-gap patterns (`eval(` of unsanitised input, hardcoded secrets, SQL-injection-shaped templates, shell-injection-shaped templates, etc.) and block the write when a high-confidence match is found.
- [ ] `scan-git-add` (`PreToolUse` on `git add`): scan the proposed staged contents (resolved via `git diff --cached` on a dry-run) for the same security-gap patterns plus secret detection (entropy heuristics + known credential prefixes).
- [ ] `safe-package-change` (`PreToolUse` on `pnpm install`/`add`/`update`/`run`): analyse the resulting `package.json` (and any new dependency's published manifest) for malicious lifecycle scripts in the `scripts` field, suspicious `bin` entries, typosquatting names, and `postinstall` hooks that fetch and execute code. Block high-confidence threats; surface a clear message and require operator confirmation for marginal cases. Complements the per-project `.npmrc` guardrails from PLAN.md §4 (which already disable lifecycle scripts wholesale; this hook catches the cases where an operator deliberately re-enables them or pulls in a transitive dep that needs running).

**Pre-implementation note:** before coding the three new content-scanning hooks above (`scan-edit-write`, `scan-git-add`, `safe-package-change`), produce a short threat-model addendum in `PLAN.md` §3 (or a sibling doc) that lists the exact pattern catalogue each hook checks. The patterns themselves are the security surface and deserve explicit review before any matcher code lands.

**Acceptance:** `git add .env` is blocked with a clear message; `git commit` is blocked when lint or tests fail; the three content-scanning hooks reject deterministic positive cases (planted secret in a test fixture, planted `eval(stdin)` pattern in a test fixture, planted `"postinstall": "curl … | sh"` in a test `package.json`) and pass clean cases.

### M3.1 — `e2e-runner` agent + `visual-validation` skill

Sonnet agent that drives Playwright and captures screenshots; companion skill that knows how to attach screenshots to a PR description. **Includes installing Playwright + browsers** (chromium/firefox/webkit) on the host — this responsibility moved from `install.sh` M1.3 Phase A into M3.1 so operators who never run e2e tasks don't pay the ~250 MB browser download upfront.

**Acceptance:** a PR opened by the toy-repo flow has Playwright output attached and screenshots embedded in the description.

### M3.2 — `reviewer` agent (Opus, fresh context)

Independent reviewer with explicit checklist per [PLAN.md §6](PLAN.md). Must run with no carry-over from the implementing session.

**Acceptance:** reviewer can `approve` or `request-changes` on a PR, and its decision feeds the auto-merge gate.

### M3.3 — Auto-merge logic with guardrails

Implement the gate from [PLAN.md §6](PLAN.md): merge only when CI green + reviewer approves, and **never** auto-merge for `package.json`/`pnpm-lock.yaml`/`Dockerfile`/`docker-compose*`/`.github/workflows/**`/PRs >500 lines / pending human comments / `request-changes`. Squash strategy. Post-merge: delete remote branch, remove worktree, mark roadmap item `[x]`.

**Acceptance:** toy-repo flow ends with a merged PR, deleted branch, cleaned worktree, and `[x]` in the project's ROADMAP.md.

### M4.1 — Retry logic with log persistence

Per-attempt logs at `<worktree>/.task-log/<timestamp>-<attempt>.md` (initial hypothesis, actions, final error, reasoning). Budget: 3 attempts → reset worktree → 3 more → hard stop. Logs from all attempts feed each retry.

**Acceptance:** injecting a deterministic failing test triggers exactly 3 retries, then a reset, then 3 more, then escalation.

### M4.2 — `unblocker` agent

On hard stop, opens a `blocked` issue on GitHub with all `.task-log` entries attached, notifies the operator, and moves the orchestrator to the next task.

**Acceptance:** the 6-failure scenario from M4.1 ends with a `blocked` issue created and the next task picked up.

### M4.3 — `/resume-task <id>`

Continue a task after interruption: re-attach to its worktree, replay context from logs, resume from the last successful step.

**Acceptance:** killing a session mid-task and running `/resume-task <id>` continues without re-running already-completed steps.

---

## Low Priority / Ideas

> **Phases 5–7 + deferred v2 patterns.** Multi-project, docs, end-to-end validation, and the OMC-borrowed ideas from PLAN.md §11.

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
