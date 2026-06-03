# Roadmap

Backlog of work for this project. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Each task lives here as a heading with whatever description it needs (acceptance criteria, design notes, sub-tasks). When work starts, move the block to `IN_PROGRESS.md`.

Tasks are derived from the implementation plan in [PLAN.md §12](PLAN.md). Milestone IDs (M1.1, M2.3, …) refer to that plan and are kept in titles for traceability. Always read the referenced PLAN.md section before starting a task.

---

## High Priority

> **Phase 1 — Foundation.** Blocks everything else. A fresh Mac must be able to run `install.sh`, log in to Claude + GitHub, and end with the `atelier` plugin installed and `/doctor` ✅.

> **Install hardening from M7.1 dogfood-2 + dogfood-3 (2026-05-23 / 2026-05-25).** Findings F1–F12 surfaced during dogfood-2 full-wipe reinstall. F11b discovered during PR-C validation. F13 + F7c discovered during dogfood-3 setup. F14 + F15 + F16 discovered during the dogfood-3 first `/atelier:doctor` run. Closed: PR-A [#70](https://github.com/AkaLab-Tech/atelier/pull/70) (F6+F7a+F9+F11, v0.4.2), PR-B [#72](https://github.com/AkaLab-Tech/atelier/pull/72) (F2+F5+F10+F12), PR-C [#73](https://github.com/AkaLab-Tech/atelier/pull/73) (F1+F3+F4+F8), PR-D [#74](https://github.com/AkaLab-Tech/atelier/pull/74) (F11b), PR-E [#75](https://github.com/AkaLab-Tech/atelier/pull/75) (F7b, v0.5.0), PR-F [#76](https://github.com/AkaLab-Tech/atelier/pull/76) (F13 atelier() shortcut). PR-G (PR _pending_) closes F16 (doctor.md allowed-tools, v0.5.1). F7c + F14 + F15 remain as follow-ups (see entries below).

---

## Medium Priority

> **Phases 2–5 — Single-project agent flow + robustness + multi-project foundation.** Done when the toy-repo flow can pick a task, implement it, open a reviewed PR, auto-merge it, clean up, and survive failures with retries — and when an operator can install / uninstall atelier without risking unrelated Claude state.

### M2.8 — Adopt Claude Code's native `auto` permission mode as layer 3

`[security-design]` · Source: [docs/research/permission-layer-3.md](docs/research/permission-layer-3.md) (M2.6 spike + M2.7 validation, 2026-05-29) · `blocked_by: M2.7 (already closed, all OQ favorable)`

M2.7 confirmed empirically that adoption is safe on Claude Code v2.1.156: `CLAUDE_CONFIG_DIR` honors `defaultMode: "auto"` (OQ-A), issue #55507 does not reproduce so user-level `auto` survives the merge with a project `permissions` block (OQ-B), and the auto-mode classifier explicitly intercepts the shell-syntax bypass that motivated the spike (OQ-C, observed annotation "Allowed by auto mode classifier" on a `for … do … done` loop). This milestone ships the adoption.

**Scope:**

- [ ] **`templates/settings.template.json`** — remove the `"defaultMode": "acceptEdits"` line. Project-level `defaultMode` overrides user-level by normal merge precedence; leaving it would mask the user-level `auto`. The allow / deny / ask blocks stay unchanged — they compose with auto-mode as documented.
- [ ] **`install.sh` Phase C.1** — add a step that writes `{"permissions": {"defaultMode": "auto"}}` into `$ATELIER_CONFIG_DIR/settings.json` (merge with the existing keys; do not clobber `enabledPlugins`, `extraKnownMarketplaces`, `theme`, etc.). Idempotent: skip if already present at the right value.
- [ ] **`scripts/atelier-doctor`** — new check that `$ATELIER_CONFIG_DIR/settings.json` has `permissions.defaultMode == "auto"`. `--fix` writes the setting if missing.
- [ ] **`docs/operator-guide.md` + `docs/troubleshooting.md` + `operator-rules.md`** — document the auto-mode adoption: what it changes for the operator (no more permission prompts for shell loops or new commands within the deny-respecting envelope) and what stays the same (deny list still blocks force-push, never-auto-merge surface, etc.).
- [ ] **`docs/research/permission-layer-3.md`** — add a "Shipped in M2.8 (PR #N)" line to the addendum's Resolution summary.

**Plugin bump:** **0.7.5 → 0.8.0** per PLAN.md §14.2. Minor bump — operator-visible UX change (fewer permission prompts, semantic-classifier gate) that is not breaking but observably different. Cut release `v0.8.0`.

**Acceptance:**

- A fresh `install.sh` on a host with no prior atelier config produces `$ATELIER_CONFIG_DIR/settings.json` with `permissions.defaultMode == "auto"`.
- `atelier-doctor` reports the auto-mode check as `✓`; on a host without the setting, `atelier-doctor --fix` adds it.
- Inside an atelier task worktree, `/status` Config tab reports `Default permission mode: Auto mode`; `/status` Status tab reports `Setting sources: User settings, Shared project settings`.
- A `for p in foo bar; do echo "$p"; done` invocation by Claude inside the task worktree no longer surfaces the *"Contains shell syntax (string) that cannot be statically analyzed"* prompt.
- The `Bash(git worktree*)`, `Bash(git wt*)`, and the rest of the existing allow list still match before the classifier fires (verified by `/permissions` showing all allow entries intact).

**Trigger to revisit:** captured 2026-05-29 immediately after M2.7's three OQs resolved favorably. Run before any further enumeration-gap fixes — once auto-mode is live, follow-up F-series findings about specific missing allow entries either disappear (covered by the classifier) or get a more focused fix scope.

### M2.9 — Custom `PreToolUse` Haiku hook as targeted second layer above auto-mode (formerly PLAN §11 v2.3)

`[security-design]` · Source: [docs/research/permission-layer-3.md](docs/research/permission-layer-3.md) Recommendation · `blocked_by: M2.8`

Originally tracked as PLAN.md §11 v2.3. The M2.6 spike confirmed it complements auto-mode rather than replaces it — useful for the narrow residual high-risk surface where the documented ~17% FN rate of auto-mode matters (e.g. anything touching `pnpm-lock.yaml`, deploy paths, never-auto-merge files). Deferred from "v2" to a tracked v1 follow-up *after* M2.8 ships and the residual surface is observable in production.

**Scope:**

- [ ] A `PreToolUse` Bash hook that calls Haiku 4.5 with a structured prompt: tool name, args, the M2.5 risk-class tag of the path being touched (if any), the task's `CLAUDE.md` excerpt about deploy/secrets.
- [ ] Cache **disabled** — every invocation is a fresh judgment. The OMC reference design caches per command string; atelier does not, because the same command can be safe or unsafe depending on cwd and surrounding state.
- [ ] Logs decisions to `<worktree>/.task-log/hook-decisions.jsonl` for post-mortem and operator review.
- [ ] Scope: project-level only (not global). Operator opts in per project by adding a key to `.atelier.json`.

**Acceptance:** see [PLAN.md §11 v2.3](PLAN.md) for the original surface area; refine once M2.8 has shipped and the residual FN cases are observable.

**Trigger to revisit:** after M2.8 has been in production long enough to surface real residual cases (target: ≥ 10 merged tasks under auto-mode). Run only if there are observed FN incidents that motivate the additional layer.

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

### M6.3 — Product owner guide (ROADMAP.md format)

How to write [PLAN.md §5](PLAN.md)-shaped roadmaps: priorities, types, estimates, `blocked_by`, acceptance criteria. With examples.

### M7.1 — Dogfood on a real (non-toy) project

Run a full task cycle on an actual project. Capture friction.

### M7.2 — Iterate the network allowlist

Grow the allowlist organically based on what M7.1 needs. Document each addition with a one-line justification.

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
