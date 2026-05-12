# Roadmap

Backlog of work for this project. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Each task lives here as a heading with whatever description it needs (acceptance criteria, design notes, sub-tasks). When work starts, move the block to `IN_PROGRESS.md`.

Tasks are derived from the implementation plan in [PLAN.md §12](PLAN.md). Milestone IDs (M1.1, M2.3, …) refer to that plan and are kept in titles for traceability. Always read the referenced PLAN.md section before starting a task.

---

## High Priority

> **Phase 1 — Foundation.** Blocks everything else. A fresh Mac must be able to run `install.sh`, log in to Claude + GitHub, and end with the `atelier` plugin installed and `/doctor` ✅.

### M1.3 — `install.sh` (Phases A + B + C.1 + C.2)

Single entry-point installer. **Splits into four sub-phases per PLAN.md §2** — keep them in one script with clear sections, not four scripts.

- [ ] **Phase A** — detect OS/arch; install base deps via brew/apt: `git`, `gh`, `fnm`, `pnpm` (via `corepack enable`), `jq`, `fzf`, `playwright`. Install Claude Code if missing.
- [ ] **Phase B** — drive `claude /login` (browser) and `gh auth login --hostname github.com --git-protocol https --web --scopes "repo,workflow,project,read:org"` + `gh auth setup-git`. **HTTPS only — never SSH.**
- [ ] **Phase C.1** — install external `git-wt` non-interactively (`/tmp/git-wt/install.sh --skill-for=claude`); write global `.npmrc` (`ignore-scripts=true`, `minimum-release-age=10080`, `audit-level=moderate`); add `.env*` to `core.excludesFile`; configure git identity (prompt only if missing); inject shellrc hooks (`fnm env --use-on-cd`, `task`, `task-status` aliases).
- [ ] **Phase C.2** — drive Claude Code to run `/plugin marketplace add AkaLab-Tech/atelier` + `/plugin install atelier@akalab-tech`. Fallback: print the two commands for the operator to paste.
- [ ] Final verification block: `claude --version`, `gh auth status`, `git wt help`, plugin presence, `/doctor` invocation; print ✅/❌ per check.
- [ ] Idempotency: re-running on an already-configured machine must not break anything and must surface a clear status.

**Acceptance:** running `install.sh` on a clean Mac VM finishes with all final checks green.

### M1.4 — `settings.template.json`

Materialize the full allow / deny / ask matrix from [PLAN.md §3](PLAN.md). Stays as a **template** in this milestone — per-task instantiation (worktree path injected into `Edit`/`Write` patterns and `additionalDirectories`) is built in Phase 2.

- [ ] `defaultMode: acceptEdits`.
- [ ] Allow list: read/edit/write (placeholder for `<worktree>` patterns), git read/write, `git push origin task/*` only, `gh` subset, `pnpm` subset, test/lint/type tooling.
- [ ] Deny list (absolute): `rm -rf:*`, `sudo:*`, `git push --force*`, `git push * main|master|develop|staging`, `git reset --hard*` outside task/*, `git config --global*`, `gh auth logout/refresh`, `gh repo delete`, `gh api POST/PATCH/DELETE`, `pnpm publish`, `npm publish`, `curl|sh`, reads of `~/.ssh/.aws/.gnupg/.config/gh`, edits of `~/.zshrc`/`~/.bashrc`/`~/.ssh`/`.github/workflows/**`/`package.json`/`pnpm-lock.yaml`, any edit outside the worktree.
- [ ] Ask list: `Edit(.env*)`, `Edit(Dockerfile)`, `Edit(docker-compose*)`, `gh pr close*`.

**Acceptance:** the template parses as valid JSON, every entry from PLAN.md §3 is present, and a sample per-task instantiation (manual for now) produces a `settings.json` that Claude Code accepts.

### M1.5 — Plugin-shipped `CLAUDE.md` (operator rules)

Author the `CLAUDE.md` that ships **inside the plugin** — this is read by Claude when an operator runs a task in any project, and contains the rules agents must follow ([PLAN.md §4](PLAN.md) dep installs, [§6](PLAN.md) push/PR/merge, [§7](PLAN.md) agent contracts).

- **Note:** distinct from the repo-root `CLAUDE.md` already at this repo's root, which guides Claude when *maintaining atelier itself*. Decide where the shipped file lives (likely `.claude-plugin/CLAUDE.md` or a plugin-relative path the manifest declares) and confirm it is auto-loaded by Claude Code when the plugin is installed.
- [ ] Resolve where the plugin's CLAUDE.md must live for auto-discovery.
- [ ] Write the operator-facing rules (no maintainer content): dep install rules §4, push/PR/merge gates §6, retry budget §8.
- [ ] Verify the shipped CLAUDE.md does not collide with or override the user's personal `~/.claude/CLAUDE.md`.

**Acceptance:** in a clean Claude Code install with the plugin loaded, a session in any project sees the plugin's rules in context, and the operator's personal `~/.claude/CLAUDE.md` is untouched.

---

## Medium Priority

> **Phases 2–4 — Single-project agent flow + robustness.** Done when the toy-repo flow can pick a task, implement it, open a reviewed PR, auto-merge it, clean up, and survive failures with retries.

### M2.1 — Phase 2 agents

Implement the four core agents per [PLAN.md §7](PLAN.md): `task-orchestrator` (Opus), `implementer` (Sonnet), `tester` (Sonnet), `pr-author` (Sonnet). Each gets a definition file under `agents/` with model, tools, and a tight prompt.

**Acceptance:** each agent loads, can be invoked from a slash command, and the orchestrator can route to the other three.

### M2.2 — Phase 2 skills

Author `task-discovery` (parses ROADMAP §5 format), `pr-flow` (branch → commit → push → PR), `safe-commit` (lint + typecheck + tests pre-commit), `safe-install` (audit + `pnpm view` before `pnpm add`). The `git-wt` skill ships from the external package — do **not** re-implement.

**Acceptance:** each skill is auto-discovered from `skills/`, has a SKILL.md with clear triggers, and is exercised by at least one slash command.

### M2.3 — Phase 2 slash commands

Author `/next-task`, `/status`, `/finish-task`, `/setup-project`, `/doctor`. `/next-task` instantiates the per-task `settings.json` from `settings.template.json` with the worktree path injected. `/setup-project` is idempotent via `~/.claude/.atelier-config.json` (`setupCompleted` ISO timestamp + `setupVersion`); re-running offers a reconfigure flow.

**Acceptance:** in a toy repo, `/next-task` runs end-to-end (pick task → worktree → implement → PR draft) without manual intervention.

### M2.4 — Phase 2 hooks

Implement `block-env-commit` (`PreToolUse` on `git add`/`git commit` blocks any path matching `.env*`) and `safe-commit` (lint + typecheck + tests gate before commit).

**Acceptance:** attempting to `git add .env` is blocked with a clear message; `git commit` is blocked when lint or tests fail.

### M3.1 — `e2e-runner` agent + `visual-validation` skill

Sonnet agent that drives Playwright and captures screenshots; companion skill that knows how to attach screenshots to a PR description.

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

Extend the Phase 2 command to be the canonical multi-project entry point: registers in `projects.json`, creates `.claude/settings.json`, project `ROADMAP.md`, project `.claude/CLAUDE.md`, `.gitignore` entries.

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
