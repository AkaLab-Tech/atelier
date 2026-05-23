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

### M4.17 — `docker-env` skill + `docker-runner` agent (on-demand local containers)

Sonnet agent + skill for on-demand Docker container management during task execution. The agent scaffolds `Dockerfile`/`docker-compose.yml`; the skill drives lifecycle (`up`/`down`/`logs`/`ps`) scoped to the task worktree. Daily-work productivity tool — useful when a task needs to test against Postgres, Redis, or a similar service without contaminating the operator's machine.

- [ ] **`docker-runner` agent (Sonnet)** — authors `Dockerfile` and `docker-compose.yml`, pins base image tags, declares services / env / ports / healthchecks. Image choices follow [PLAN.md §4](PLAN.md) dep-install rules (justify in commit, prefer official images, avoid <7-day-old tags).
- [ ] **`docker-env` skill** — compose project name = `<task-id>-<slug>` so parallel tasks isolate networks/volumes; lifecycle commands `up`, `down`, `logs <service>`, `ps`. Auto-discovered and invoked by `implementer` when the task needs services.
- [ ] **Runtime detection** — probe `docker info` at first use; fail with a clear actionable message if no daemon is running. `install.sh` does **not** install Colima or Docker Desktop — the operator chooses and installs a runtime; the skill works against whichever daemon is reachable.
- [ ] **Permissions delta in `settings.template.json`** — `Edit(<worktree>/**/Dockerfile)` and `Edit(<worktree>/**/docker-compose*)` auto-allowed inside the task worktree; [PLAN.md §3](PLAN.md) "ask" remains for any path outside the worktree. [PLAN.md §6](PLAN.md) auto-merge block for Dockerfile / docker-compose* stays in force — PRs touching these files still fall back to human review.
- [ ] **`Stop` hook** — tears down the task's containers and removes named volumes prefixed with `<task-id>` on session end, so no orphans accumulate.

**Acceptance:** in a toy repo with no Docker config, a task that requires Postgres ends with the agent having generated `docker-compose.yml`, the skill having started the service, tests passing against it, and the `Stop` hook cleaning everything up — leaving no orphan containers, networks, or volumes. A PR touching `docker-compose.yml` still falls back to human review per PLAN.md §6.

**Trigger to revisit:** the first time a task needs to test against a containerized service and the operator would otherwise write Docker config by hand. Captured 2026-05-22 as a daily-work productivity tool that complements (not blocks) the core agent flow.

### M4.19 — `/setup-project` auto-generates root `CLAUDE.md` (interview or codebase scan)

`/setup-project` today writes a placeholder `.claude/CLAUDE.md` from a generic template and leaves the **root** `CLAUDE.md` (the file Claude Code uses to learn project architecture / stack / conventions) entirely up to the operator. Result: agents start every task with effectively zero project context until the operator manually populates that file.

This task makes `/setup-project` populate the root `CLAUDE.md` automatically, branching on whether the project is **new** or **existing**. The atelier-specific `.claude/CLAUDE.md` is **also** managed (current placeholder template stays; existing idempotency rule in `commands/setup-project.md` line 34 still applies — never overwrite if already present).

**Detection (auto, with override):**

- Heuristic on the target path:
  - **`new`** when the repo has 0 commits OR tracks ≤3 files all matching docs-only patterns (`README*`, `LICENSE*`, `.gitignore`).
  - **`existing`** when the repo has any manifest file (`package.json`, `go.mod`, `Cargo.toml`, `pyproject.toml`, `Gemfile`, …), a populated source dir (`src/`, `lib/`, `app/`), or >3 tracked files.
- CLI override: `atelier-setup-project --mode=new|existing` forces the branch and skips the heuristic. Default is the heuristic.

**`new` branch — single-question interview + AI drafts:**

- One open question to the operator: *"What is this project about? (free-form)"*.
- A sub-agent converts the answer into a structured root `CLAUDE.md` covering: purpose, anticipated stack, anticipated conventions. Sections with unknown values are explicitly marked `TBD` (e.g., *"Test runner: TBD"*) so a later task can fill them in.

**`existing` branch — `project-profiler` agent (Sonnet, read-only):**

- Tools restricted to `Read`, `Glob`, `Grep`. No execution, no installs, no network — the agent's prompt forbids them explicitly.
- Scans `README*`, manifest files, top-level dir layout, CI configs (`.github/workflows/*`), test/lint configs (`vitest.config.*`, `eslint.config.*`, `tsconfig.json`, etc.).
- Writes the root `CLAUDE.md` with: detected stack (from manifests), high-level architecture, conventions (test runner, linter, package manager, deploy target if detectable). Whatever it cannot infer with confidence is left as `TBD` rather than guessed.

**Both branches:**

- Never overwrite an existing root `CLAUDE.md` (same idempotency rule as `.claude/CLAUDE.md`).
- Status (`written` / `kept-existing`) logged in the `/setup-project` summary block.

**Sub-tasks:**

- [ ] Heuristic function in `scripts/atelier-setup-project` returning `new|existing`.
- [ ] `--mode=new|existing` CLI flag, overriding the heuristic.
- [ ] `agents/project-profiler.md` — Sonnet, tools `Read` / `Glob` / `Grep` only, prompt explicitly forbidding execution / install / network.
- [ ] `templates/project-claude-root.md.template` for the `new` branch (placeholders the interview / AI fills in).
- [ ] `/setup-project` step 5 extended: branch on detection, run the appropriate path, write the root `CLAUDE.md` only when missing.
- [ ] `commands/setup-project.md` updated to document the new step + override flag.

**Acceptance:**

- `/setup-project` on an empty repo (0 commits): asks the open question, writes root `CLAUDE.md` reflecting the answer, writes `.claude/CLAUDE.md` from the current placeholder template.
- `/setup-project` on a populated repo (has `package.json` + `src/`): no interview, `project-profiler` writes root `CLAUDE.md` with detected stack / conventions; `.claude/CLAUDE.md` written from the current template.
- `atelier-setup-project --mode=new` on a populated repo forces the interview branch (ignores heuristic).
- Re-running `/setup-project` on a project that already has a root `CLAUDE.md` leaves it untouched (logs `kept-existing`).

**Trigger to revisit:** captured 2026-05-22. Without this, every new project bootstrapped via atelier starts with agents having zero project context until the operator manually writes the root `CLAUDE.md` — friction at exactly the moment the operator is trying to get the project running.

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
