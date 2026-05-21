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

### M5.0.3 — `atelier-uninstall` with chat-session preservation

Today there is no clean way to uninstall atelier. To remove atelier, the operator has to manually:

1. Edit `~/.zshrc` to remove the atelier hooks block (between sentinel comments).
2. `rm ~/.local/bin/atelier-setup-project`.
3. `CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR claude plugin uninstall atelier@akalab-tech` and `claude-roadmap-tools@akalab-tech`.
4. Decide what to do with `$ATELIER_CONFIG_DIR` — which contains chat history (`history.jsonl`), session state (`projects/`), plans (`plans/`), backups — without a clear convention.

M5.0.3 ships a single command — `scripts/atelier-uninstall` — that automates steps 1–3 and gives the operator a clear default for step 4 (preserve), with an explicit opt-in for destructive wipe.

**Default mode (conservative):**

- Remove the atelier hooks block from `~/.zshrc` and/or `~/.bashrc` (via `sed` against the existing sentinel comments — same comments used at install time).
- Remove the `~/.local/bin/atelier-setup-project` symlink and the new `~/.local/bin/atelier-uninstall` symlink.
- Uninstall `atelier@akalab-tech` and `claude-roadmap-tools@akalab-tech` plugins under `$ATELIER_CONFIG_DIR`.
- **NOT removed:** `$ATELIER_CONFIG_DIR` itself. The operator's chat history, sessions, plans, backups all remain in place. They can still `CLAUDE_CONFIG_DIR=~/.claude-work claude` (or whatever the chosen path was) later to access archived sessions, even though atelier is no longer "installed" on their system.

**Purge mode (`--purge` flag):**

- All of the above, plus `rm -rf "$ATELIER_CONFIG_DIR"`.
- Requires explicit confirmation prompt: *"This will permanently delete all chat history, sessions, plans, and backups under `<path>`. Type 'PURGE' (uppercase) to confirm."*.
- Non-interactive `--purge --yes` is allowed, but the operator must explicitly opt in to both flags.

**Acceptance:** `atelier-uninstall` from any shell removes atelier's shellrc footprint, symlinks, and plugin install — without touching the operator's chat sessions by default. `atelier-uninstall --purge` (with confirmation) wipes everything. After a default uninstall, re-installing atelier via `install.sh` picks up the same `$ATELIER_CONFIG_DIR` and does NOT require re-authenticating to Claude (auth tokens persist in `$ATELIER_CONFIG_DIR/.claude.json`).

**Trigger to revisit:** when an operator (including the maintainer) needs to decommission atelier without losing chat history. Captured post-M5.0 alongside M5.0.2 as the natural pair of install-side and uninstall-side hardening.

### M4.11 — Investigate the M4.7 thesis under `claude --plugin-dir` ad-hoc CLI mode

M4.7 documented that `Bash > <wt>/.claude/settings.json` bypasses the harness's `.claude/**` `Write`/`Edit` interactive guard *when the path is in `additionalDirectories`*. The probe at M4.7 design time confirmed this empirically. The empirical test of M4.9 (PR [#39](https://github.com/AkaLab-Tech/atelier/pull/39) comment) also showed `Bash(atelier-setup-project:*)` running clean from inside `claude -p`.

Dogfood-3 found a case where the thesis breaks: `/next-task` step 7's inline `mkdir -p <wt>/.claude && sed ... > <wt>/.claude/settings.json` was denied by the harness **in `claude --plugin-dir` ad-hoc CLI mode**, despite `<wt>-worktrees/**` being in `additionalDirectories`. The chain died at step 7 (Finding D3-2 — see HISTORY's dogfood-3 entry).

Why this matters: an operator running atelier via marketplace install probably doesn't hit this (the marketplace path sets `$CLAUDE_PLUGIN_ROOT` and configures the harness's plugin-scope differently). But `--plugin-dir` is the mode developers use to smoke-test plugin changes locally, and the one dogfood-3 happened to use.

**Hypothesis (to verify):** the harness's `.claude/**` guard has two enforcement layers — (a) the `Write`/`Edit` tool-level guard that M4.7 bypassed via Bash redirect, and (b) a path-prefix sandboxing layer applied at session start, which `--plugin-dir` configures differently than marketplace install. The Bash redirect bypasses (a) but not (b).

**Acceptance:** a clear written answer to *"under what session-load mode (marketplace install / `--plugin-dir` / `--allowedTools` flag / etc.) does `Bash > <wt>/.claude/settings.json` actually succeed, given `<wt>` is in `additionalDirectories`?"*. If the answer is "marketplace install yes, `--plugin-dir` no", update [commands/next-task.md](commands/next-task.md) to either (1) document the limitation and require marketplace install for full chains, or (2) gate step 7 behind a runtime probe that picks an alternative path when the harness blocks (e.g., emit a clear actionable error pointing at marketplace install).

**Trigger to revisit:** before dogfood-4 (or a re-run of dogfood-3). Currently blocking any autonomous agent-chain validation of atelier via `claude -p --plugin-dir`.

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
