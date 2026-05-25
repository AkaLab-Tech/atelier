# Roadmap

Backlog of work for this project. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Each task lives here as a heading with whatever description it needs (acceptance criteria, design notes, sub-tasks). When work starts, move the block to `IN_PROGRESS.md`.

Tasks are derived from the implementation plan in [PLAN.md §12](PLAN.md). Milestone IDs (M1.1, M2.3, …) refer to that plan and are kept in titles for traceability. Always read the referenced PLAN.md section before starting a task.

---

## High Priority

> **Phase 1 — Foundation.** Blocks everything else. A fresh Mac must be able to run `install.sh`, log in to Claude + GitHub, and end with the `atelier` plugin installed and `/doctor` ✅.

> **Install hardening from M7.1 dogfood-2 + dogfood-3 (2026-05-23 / 2026-05-25).** Findings F1–F12 surfaced during dogfood-2 full-wipe reinstall. F11b discovered during PR-C validation. F13 + F7c discovered during dogfood-3 setup. F14 + F15 + F16 discovered during the dogfood-3 first `/atelier:doctor` run. Closed: PR-A [#70](https://github.com/AkaLab-Tech/atelier/pull/70) (F6+F7a+F9+F11, v0.4.2), PR-B [#72](https://github.com/AkaLab-Tech/atelier/pull/72) (F2+F5+F10+F12), PR-C [#73](https://github.com/AkaLab-Tech/atelier/pull/73) (F1+F3+F4+F8), PR-D [#74](https://github.com/AkaLab-Tech/atelier/pull/74) (F11b), PR-E [#75](https://github.com/AkaLab-Tech/atelier/pull/75) (F7b, v0.5.0), PR-F [#76](https://github.com/AkaLab-Tech/atelier/pull/76) (F13 atelier() shortcut). PR-G (PR _pending_) closes F16 (doctor.md allowed-tools, v0.5.1). F7c + F14 + F15 remain as follow-ups (see entries below).

### M7.1.F14 — `/atelier:doctor` drift checks should read marketplace, not source repo API

`[correctness]` · Source: M7.1 dogfood-3 first `/atelier:doctor` run (2026-05-25)

The plugin-drift checks in `commands/doctor.md` query `gh api repos/AkaLab-Tech/atelier/releases/latest` (and same for `claude-roadmap-tools`) to detect upstream drift. This fails with 404 when the source repo is private and `@AtelierAuthor` is not a member of the org — exactly the dogfood-3 starting state. The doctor then enters a recovery loop trying alternate endpoints (`tags`, `contents/.claude-plugin/marketplace.json`), each also failing or stalling.

Symptom from dogfood-3: doctor printed `gh: Not Found (HTTP 404)` for the atelier repo + got cancelled in the middle of parallel calls. Worked around by making `AkaLab-Tech/atelier` public; the source repo's privacy is no longer the gating factor, but the doctor's architecture remains fragile.

**Scope:**

- [ ] Read the upstream plugin version from the **local marketplace clone** (`$ATELIER_CONFIG_DIR/plugins/marketplaces/akalab-tech/atelier/.claude-plugin/plugin.json`) instead of the source repo's GitHub releases API. The marketplace IS the canonical source of truth for "what version is published to operators" — bypassing the source repo eliminates the private-repo / org-membership dependency entirely.
- [ ] Fall back to the source repo's `releases/latest` (existing behavior) only when the local marketplace clone is missing or corrupt; surface a `↷` skip in that case rather than cascading the failure.
- [ ] Same approach for `claude-roadmap-tools` drift check.
- [ ] Update the doctor's check-1 / check-2 narrative to document the marketplace-first behavior.

**Acceptance:** running `/atelier:doctor` on a system where `AkaLab-Tech/atelier` is private and the doctor's gh identity lacks org access still reports `✓ atelier <version> (up to date)` — drift detection works without requiring API access to the source repo.

**Trigger to revisit:** before the next M7.1 dogfood iteration where atelier might run against a private repo with a non-member identity. Captured 2026-05-25 immediately after F14 was bypassed by flipping `AkaLab-Tech/atelier` to public — the underlying architectural fragility remains.

### M7.1.F15 — `/atelier:doctor` parallel checks should fail independently, not cascade-cancel

`[ux-blocking]` · Source: M7.1 dogfood-3 first `/atelier:doctor` run (2026-05-25)

When doctor launches its checks in parallel and one fails (e.g. the F14 404), the Claude Code session cancels every other in-flight parallel call with `Cancelled: parallel tool call Bash(gh api repos/AkaLab-Tech/atelier/release…) errored`. The operator sees a partial report — no plugin versions, no git-wt SHA, no host checks — and the session enters an uncertain state trying to "recover" from the failure rather than completing all the *other* checks that would have worked fine.

This is a Claude Code default-behavior issue (parallel tool calls share a fate), but `doctor.md` can mitigate it by:

**Scope:**

- [ ] Run checks **sequentially**, not in parallel. Doctor's checks have no real interdependency — sequential adds maybe 1-2s on a clean run but produces a complete report regardless of individual failures.
- [ ] Each check uses an explicit `|| true` or `|| echo "<failure-text>"` so a non-zero exit doesn't bubble up to the harness.
- [ ] The check-narrative in `doctor.md` updated to emphasize the `✓ / ✗ / —` per-check independence: an `✗` on one row never affects the others.

**Acceptance:** running `/atelier:doctor` on a system where one check intentionally fails (e.g. `gh api` rate-limited, docker daemon down) produces a full report — all other checks complete and are marked individually `✓ / ✗ / —`.

**Trigger to revisit:** captured 2026-05-25 alongside F14. Same dogfood-3 run that surfaced F14 also surfaced this — operator's first doctor was interrupted with partial output, requiring manual re-runs.

### M7.1.F7c — Shellrc block needs versioning + auto re-injection on install.sh re-run

`[ux-blocking]` · Source: M7.1 PR-E ([#75](https://github.com/AkaLab-Tech/atelier/pull/75)) live validation (2026-05-25)

`phase_c_1_shellrc_hooks` is idempotent by sentinel detection: it greps for `# >>> atelier hooks (managed by install.sh) >>>` and short-circuits with `step_skip` when found. Operators upgrading from one atelier version to a later one (e.g. v0.4.2 → v0.5.0, where F7b added `GIT_CONFIG_GLOBAL` to `task()`) will NOT get the new shellrc block automatically — they have to manually strip the block between sentinels and re-run `install.sh`. The block's docstring already mentions this manual procedure, but it's a real UX gap for plugin upgrades.

**Scope:**

- [ ] Embed a `# atelier-hooks-version: N` line inside the heredoc block, incremented each time the block contents change.
- [ ] `phase_c_1_shellrc_hooks` parses the existing block's version line; if missing or older than the current script's version, strip + re-inject instead of skipping.
- [ ] Print a clear `→ refreshing atelier shellrc block (vX → vY)` message when the upgrade path triggers, so operators understand why their shellrc changed.
- [ ] Document the contract inside the block (one-line header comment) so future maintainers know to bump the version when they edit the block contents.

**Acceptance:** running `./install.sh` against a `~/.zshrc` with an older-version atelier block re-injects the current block, replacing the old one in place. The sentinels stay stable so block discovery still works; only the body changes.

**Trigger to revisit:** captured 2026-05-25 during the F7b live validation, when the operator's existing shellrc block lacked the new `GIT_CONFIG_GLOBAL` export and `step_skip "atelier hooks already present in .zshrc"` silently swallowed the upgrade. Manual workaround documented in v0.5.0 release notes; a code fix should land before M7.2 (network allowlist iteration) so subsequent install.sh changes propagate automatically.

---

## Medium Priority

> **Phases 2–5 — Single-project agent flow + robustness + multi-project foundation.** Done when the toy-repo flow can pick a task, implement it, open a reviewed PR, auto-merge it, clean up, and survive failures with retries — and when an operator can install / uninstall atelier without risking unrelated Claude state.

### M2.6 — Spike: native `auto` permission mode as layer 3 vs custom LLM-backed hook

`[security-design]` · Source: design conversation (2026-05-25) · `blocked_by: M2.5`

Three-layer permission model from M2.5 leaves layer 3 (semantic judgment for commands the static matrix and pattern hooks don't enumerate) as an open question. Two real options exist:

- **Option A — Native auto-mode.** Claude Code's built-in `auto` permission mode (Anthropic-maintained classifier, ~17% false negative rate per official docs). Activated globally via `~/.claude/settings.json` `"defaultMode": "auto"`. Zero implementation cost.
- **Option B — Custom `PreToolUse` LLM hook.** The original v2.3 plan: `PermissionRequest` Bash hook calling Haiku 4.5, no cache, project-scoped, integrates with `<worktree>/.task-log/hook-decisions.jsonl`.
- **Option C — Both** as defense in depth.

**Investigation surface:**

- [ ] **Composition with the static matrix.** Does `auto` mode respect `deny`/`allow` patterns from `settings.json`, or override them? If override, A is incompatible with atelier's matrix-driven security model.
- [ ] **Per-task vs global scope.** Auto-mode lives in `~/.claude/settings.json` (global); atelier's per-task settings are written to `<worktree>/.claude/settings.json`. Document whether enabling auto-mode globally is acceptable for the non-technical operator, given it affects all Claude sessions (including non-atelier ones).
- [ ] **17% false-negative profile.** Where does auto-mode miss? Pull Anthropic's published examples; categorize the misses (composition? semantic ambiguity? novel commands?). Compare against what the M2.5-extended matrix already catches.
- [ ] **Latency.** Benchmark auto-mode overhead vs no-permission-mode baseline on a typical 30-command task.

**Deliverable:** `docs/research/permission-layer-3.md` with a recommendation (A / B / C) and the rationale. Updates [PLAN.md §11 v2.3](PLAN.md) accordingly — A makes v2.3 obsolete; B keeps v2.3 as planned; C reshapes v2.3 to ship alongside auto-mode.

**Acceptance:** `docs/research/permission-layer-3.md` exists with all four investigation sections populated. PLAN.md §11 v2.3 is updated with `Decided in: docs/research/permission-layer-3.md` and the option that was picked.

**Trigger to revisit:** captured 2026-05-25 after discovering auto-mode is available on Max (and all plans), contrary to earlier assumption. Spike runs before any v2.3 implementation work — building a custom hook when Anthropic's classifier is good enough would be waste; relying solely on auto-mode when its 17% FN rate matters would be unsafe.

### M4.22 — Spike: Coolify VPS integration research

Research spike to inform a future implementation (M4.23). Atelier today has no path to deploy or manage apps on a VPS-hosted Coolify instance. Before committing to an implementation, audit what already exists in the ecosystem and document Coolify's API surface so the impl task starts from concrete options rather than guesses.

[PLAN.md §11](PLAN.md) lists *deployment/release management* as out-of-scope for v1. This spike does not contradict that — it produces a written artifact that informs whether and how to lift that scope later. The implementation task (M4.23) stays tagged `v2` until the spike completes and the team explicitly decides to promote it.

**Investigation surface:**

- [ ] **Ecosystem inventory.** Catalog existing tooling for Coolify integration: Claude Code MCP servers, plugins, skills, agents (search the official marketplace + community marketplaces); third-party CLIs (`coolify-cli`, Terraform providers); libraries / API wrappers in any language. For each entry record: source URL, license, last-update date, maintenance status, coverage vs gaps.
- [ ] **API surface mapping.** For each use case below, document the relevant Coolify API endpoints, required auth, expected payloads/responses, rate-limit posture, and idempotency characteristics:
  - Deploy from branch / commit.
  - List apps, fetch status, tail logs.
  - Manage env vars / secrets (CRUD).
  - Provision new apps.
  - Anything else the API exposes that fits atelier's workflow (cron jobs, databases, backups, etc.) — flag opportunistically.
- [ ] **Auth flow design.** Document the per-project `.env` token approach: env var naming convention (e.g., `COOLIFY_API_TOKEN` + `COOLIFY_BASE_URL`), how the skill loads them, fallback behavior when missing, multi-instance support (one operator, multiple Coolify instances across projects).
- [ ] **Recommendation — build-on / wrap / from-scratch.** Based on the inventory: (a) adopt an existing MCP/skill directly, (b) wrap an existing tool with a thin atelier layer, or (c) build a native skill calling Coolify's REST API. Justify the choice and call out the second-best option as a fallback.

**Deliverable:** a markdown document at `docs/research/coolify-integration.md` covering all four sections above. Must be self-contained — whoever picks up M4.23 cold should be able to act on it without re-doing the research.

**Acceptance:** `docs/research/coolify-integration.md` exists with all four sections populated. M4.23's description is updated with a `Based on: docs/research/coolify-integration.md` reference and any scope adjustments the research surfaced (e.g., dropping a use case the API does not support cleanly, or adding one the API exposes cheaply).

**Trigger to revisit:** captured 2026-05-23. Operator wants a path to deploy atelier-managed projects to VPS-hosted Coolify. Spike runs immediately because the implementation cost depends heavily on whether existing tooling already covers the use cases — building from scratch when a maintained MCP already exists would be waste.

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

### M4.23 — Coolify VPS deployment integration (`v2`, `blocked_by: M4.22`)

`v2` · `blocked_by: M4.22`

**Out-of-scope for v1 per [PLAN.md §11](PLAN.md).** Captured as a v2 task so the work is not lost; promotion to v1 requires an explicit decision after M4.22's research artifact lands.

Implementation of Coolify VPS integration covering deploy, status/logs, env vars/secrets, and app provisioning. Full scope is whatever M4.22's research determines the API supports and what adds value to the atelier workflow. The exact shape (MCP adoption / skill wrapper / native API client) is set by M4.22's recommendation.

**Constraints already settled (do not relitigate):**

- **Auth:** per-project `.env`, gitignored by atelier's existing `.env*` guardrail. Token env var naming convention is finalized in M4.22's auth-flow section.
- **Minimum use cases:** deploy from branch/commit, list apps + status + logs, CRUD env vars/secrets, provision new apps. Anything else the API exposes that fits the atelier workflow may be added opportunistically (per M4.22's mapping).
- **Auto-merge guardrail:** any PR that touches deployment config (analogous rationale to PLAN.md §6 for `Dockerfile`/`docker-compose*`) must fall back to human review. The `auto-merge` skill's never-auto-merge list needs an additional entry for whatever paths the implementation introduces.

**Sub-tasks (refine after M4.22):**

- [ ] Adopt M4.22's recommendation (build-on / wrap / from-scratch).
- [ ] Skill / agent / command surface area as decided by M4.22.
- [ ] `settings.template.json` permissions delta: allowlist for Coolify-related Bash / MCP calls scoped to the worktree; deny anything that would touch other projects' deployments.
- [ ] `/doctor` extension: verify the Coolify connection (token + base URL reachable) when the project has Coolify configured.
- [ ] Operator-facing docs: a `docs/coolify.md` (or section in `commands/setup-project.md`) explaining how to wire a project to a Coolify instance.

**Acceptance:** an atelier task can trigger a Coolify deploy of the current branch's HEAD, fetch the resulting app status + last N log lines, set/get an env var, and provision a fresh app — all from inside a Claude session, with the Coolify API token loaded from the project's `.env` only. PRs touching Coolify config fall back to human review per the extended guardrail list.

**Trigger to revisit:** after M4.22 lands AND the team explicitly decides to promote deployment work into v1 (or accepts this stays v2 with the spike having unblocked the path).

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
