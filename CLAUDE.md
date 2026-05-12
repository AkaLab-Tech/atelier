# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This repo is **atelier** — an AI-operated workstation distributed as a Claude Code native plugin. It targets a non-technical operator who delivers software by talking to Claude (no manual branching, testing, or PR work).

The repo is currently **pre-implementation**: the only authoritative artifact is [PLAN.md](PLAN.md). There is no source code, no `install.sh`, no `.claude-plugin/`, no `agents/` / `skills/` / `commands/` / `hooks/` directories yet. Do not invent build/lint/test commands — none exist. When asked to implement something, **start by reading PLAN.md** and align with the phase being worked on (see PLAN.md §12).

## Source of truth & decision log

- [PLAN.md](PLAN.md) is the design source of truth. Items are tagged: ✅ agreed · 🟡 proposed · ❓ open · ✂️ removed. Do not contradict an ✅ item without flagging it explicitly.
- When a design decision changes during a conversation, update PLAN.md in the same change — do not let the plan drift.

## Tracking flow

This repo uses the single-file layout for [ROADMAP.md](ROADMAP.md) → [IN_PROGRESS.md](IN_PROGRESS.md) → [HISTORY.md](HISTORY.md). The `roadmap-tracking-flow` skill activates automatically. When a PR closes a task, the **same PR** must remove the entry from `IN_PROGRESS.md` and add it to `HISTORY.md` — never split that across commits.

Note: the **operator-facing** ROADMAP format defined in PLAN.md §5 (P0/P1/P2 with `bug`/`feat`/`chore` tags, `~estimate`, `blocked_by:`) is the format used inside *target projects* the operator manages. The `ROADMAP.md` at this repo's root tracks **atelier's own development** and uses the simpler high/medium/low priority layout from the `roadmap-tracking-flow` skill.

## Architecture (planned, per PLAN.md §1)

Three layers, each with a different delivery mechanism:

1. **Plugin layer** — the bulk of atelier ships as a Claude Code native plugin (`.claude-plugin/plugin.json` + `marketplace.json`). Claude Code auto-discovers `agents/`, `skills/`, `commands/`, `hooks/`, `CLAUDE.md` from the plugin root. **Plugin scripts and hooks must reference paths via `$CLAUDE_PLUGIN_ROOT`** — never hardcode absolute paths or assume `~/.claude/...`.
2. **Host-OS layer** — `install.sh` Phase C.1 handles what cannot live inside a plugin: base deps, Claude Code itself, GitHub HTTPS auth, the external `git-wt` package, `.env*` in git's global excludes, `fnm` shellrc hooks, git identity. (Note: pnpm supply-chain guardrails live in each project's `.npmrc`, not in `~/.npmrc` — see §3.)
3. **Per-project layer** — `/setup-project <path>` creates `.claude/settings.json` (instantiated from `settings.template.json` with the worktree path injected), project `ROADMAP.md`, project `.claude/CLAUDE.md`, project `.npmrc` (pnpm guardrails from PLAN.md §4).

Isolation: every task runs inside its own git worktree (managed via the external `git-wt` skill, sourced from [Miguelslo27/git-wt](https://github.com/Miguelslo27/git-wt) — **not** maintained here). `Edit`/`Write` permissions are scoped to that worktree per task.

## Hard constraints (already decided in PLAN.md — do not relitigate without flagging)

These are binding rules an implementer must respect:

- **Package manager**: `pnpm` only. Never fall back to `npm` (PLAN.md §2 step 2).
- **Node**: managed by `fnm` with per-project `.nvmrc`. No `nvm`, no system Node assumptions.
- **GitHub auth**: HTTPS only. **Never** generate, reference, or rely on SSH keys. Cloning is `gh repo clone` or `https://github.com/...` (PLAN.md §2 step 5).
- **Dependency installs** (PLAN.md §4): self-question if stdlib suffices → compare ≥2 alternatives → justify in commit/PR → reject packages <7 days old (per-project `.npmrc minimum-release-age=10080` written by `/setup-project`) → reject moderate+ vulnerabilities (per-project `.npmrc audit-level=moderate`). Use `/safe-install` once it exists.
- **Git push** is restricted to `origin task/<id>-<slug>`. Pushing to `main`/`master`/`develop`/`staging` or any `--force` push is in the absolute deny list (PLAN.md §3).
- **`package.json` and `pnpm-lock.yaml`** are not edited directly — always go through `pnpm add/remove/update`.
- **Workflows under `.github/workflows/**`** are not edited by agents.
- **Secrets**: `.env*` is in git's global excludes; a `PreToolUse` hook (to be implemented) blocks any commit that touches `.env*`.
- **Commits**: Conventional Commits style. Merges are squash-only. Post-merge: delete remote branch, remove worktree, mark roadmap item `[x]`.

## Permissions model (PLAN.md §3)

The full allow/deny/ask matrix lives in PLAN.md §3 and will be materialized as `settings.template.json` (Phase 1, milestone M1.4). When extending permissions:
- Default mode is `acceptEdits`.
- Network access is **allowlist-based, grown organically** — do not add broad network grants speculatively.
- Add new entries to the template, not directly to per-task `settings.json` (that file is regenerated each task).

The repo's own `.claude/settings.json` is a working dev convenience for the maintainer and is **not** the template the plugin will ship.

## Push / PR / merge gates (PLAN.md §6)

Implementations of `pr-flow` and the auto-merge logic must enforce:

- **Push gate**: lint + typecheck + unit/integration tests all green.
- **PR gate**: push gate + Playwright e2e green with screenshots attached + auto-generated description (roadmap ref, summary, validation checklist, screenshots).
- **Auto-merge gate**: CI green + independent `reviewer` agent (Opus, fresh context) approves.
- **Never auto-merge** — falls back to human: changes touching `package.json`/`pnpm-lock.yaml`, `Dockerfile`/`docker-compose*`, `.github/workflows/**`, PRs >500 lines, pending human comments, or `request-changes` from reviewer.

## Failure recovery (PLAN.md §8)

Retry budget is fixed: 3 attempts → reset worktree → 3 more attempts → hard stop with a `blocked` GitHub issue containing all `<worktree>/.task-log/<timestamp>-<attempt>.md` entries. Do not silently extend this budget.

## Out of scope for v1

Per PLAN.md §11: multi-repo tasks, deployment/release management, cost monitoring, visual-regression baselines, ROADMAP↔Issues sync. Suggestions touching these belong in the deferred-to-v2 table, not in v1 work.

## Working with this repo right now

- The active branch is typically a `docs/*` or `setup/*` branch — design changes happen in PRs against `main`.
- Until Phase 1 lands, "build" tasks are documentation tasks. Do not fabricate scripts or commands; if PLAN.md says a piece will exist, treat it as TBD and propose where it should live.
