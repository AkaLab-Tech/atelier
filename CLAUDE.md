# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This repo is **atelier** — an AI-operated workstation distributed as a Claude Code native plugin. It targets a non-technical operator who delivers software by talking to Claude (no manual branching, testing, or PR work).

The repo is **implemented and shipping** (currently v0.37.x — see `.claude-plugin/plugin.json`). What exists today:

- `install.sh` — the phased installer (~2400 LOC, phased: 0 / A / B / C.1 / C.2). Runs from a git clone OR a plugin-cache snapshot (`--from-cache`, #39).
- `bootstrap.sh` — the repo-less one-line entry point (#39): installs Claude Code, registers the marketplace, installs the atelier plugin, then delegates to the cached `install.sh --from-cache`. The only curl|bash artifact; keep it small and auditable.
- `.claude-plugin/` — plugin + marketplace manifests.
- `scripts/` — 26 `atelier-*` helper binaries (doctor, setup-project, task backends, etc.).
- `hooks/` — 11 hook scripts + `hooks.json` manifest + pattern catalogues in `hooks/patterns/`, with a hermetic regression suite (34 `*.test.sh`) in `hooks/tests/`.
- `agents/` — 14 agent definitions; `skills/` — 9 skills; `commands/` — 29 slash commands.
- `docs/` (operator guide, quickstart, troubleshooting, research notes) and `templates/` (settings, project CLAUDE.md, `.atelier.json`).
- CI: `.github/workflows/structural.yml` runs `bash -n` on all shell, the `hooks/tests/*.test.sh` suite, JSON validation, YAML-frontmatter parsing, and an `atelier-setup-project --help` smoke.

When asked to implement something, **start by reading PLAN.md** and align with the phase being worked on (see PLAN.md §12).

## Source of truth & decision log

- [PLAN.md](PLAN.md) is the design source of truth. Items are tagged: ✅ agreed · 🟡 proposed · ❓ open · ✂️ removed. Do not contradict an ✅ item without flagging it explicitly.
- When a design decision changes during a conversation, update PLAN.md in the same change — do not let the plan drift.

## Tracking flow

This repo tracks its own roadmap in a **GitHub Project** (backend `github-project` in [.roadmap.json](.roadmap.json): AkaLab-Tech project #1, with Todo / In Progress / Done mapped to roadmap / in-progress / history). There are **no local `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` files at the repo root** — do not create them. Task plans live as `.plan/<id><letter>.md` files, and PRs reference their board item (`#NN`) in the title/description; state moves on the board, not in tracked files.

## Architecture (per PLAN.md §1)

Three layers, each with a different delivery mechanism:

1. **Plugin layer** — the bulk of atelier ships as a Claude Code native plugin (`.claude-plugin/plugin.json` + `marketplace.json`). Claude Code auto-discovers `agents/`, `skills/`, `commands/`, `hooks/`, `CLAUDE.md` from the plugin root. **Plugin scripts and hooks must reference paths via `$CLAUDE_PLUGIN_ROOT`** — never hardcode absolute paths or assume `~/.claude/...`.
2. **Host-OS layer** — `install.sh` Phase C.1 handles what cannot live inside a plugin: base deps, Claude Code itself, GitHub HTTPS auth, the external `git-wt` package, `.env*` in git's global excludes, `fnm` shellrc hooks, git identity. The 26 `atelier-*` helpers are copied into a versioned runtime dir (`~/.local/share/atelier/<version>/`, `current` symlink swapped atomically, previous version kept for rollback — #39 F2) and symlinked from `~/.local/bin` through `current/`; `atelier-update` swaps versions from the plugin cache with no git operations (managed mode), while clone installs keep the git-pull flow. (Note: pnpm supply-chain guardrails live in each project's `.npmrc`, not in `~/.npmrc` — see §3.)
3. **Per-project layer** — `/setup-project <path>` creates `.claude/settings.json` (instantiated from `settings.template.json` with the worktree path injected), project `ROADMAP.md`, project `.claude/CLAUDE.md`, project `.npmrc` (pnpm guardrails from PLAN.md §4).

Isolation: every task runs inside its own git worktree (managed via the external `git-wt` skill, sourced from [AkaLab-Tech/git-wt](https://github.com/AkaLab-Tech/git-wt) — **not** maintained here). `Edit`/`Write` permissions are scoped to that worktree per task.

## Hard constraints (already decided in PLAN.md — do not relitigate without flagging)

These are binding rules an implementer must respect:

- **Package manager**: `pnpm` only. Never fall back to `npm` (PLAN.md §2 step 2).
- **Node**: managed by `fnm` with per-project `.nvmrc`. No `nvm`, no system Node assumptions.
- **GitHub auth**: HTTPS only. **Never** generate, reference, or rely on SSH keys. Cloning is `gh repo clone` or `https://github.com/...` (PLAN.md §2 step 5).
- **Dependency installs** (PLAN.md §4): self-question if stdlib suffices → compare ≥2 alternatives → justify in commit/PR → reject packages <7 days old (per-project `.npmrc minimum-release-age=10080` written by `/setup-project`) → reject moderate+ vulnerabilities (per-project `.npmrc audit-level=moderate`). Use `/safe-install` once it exists.
- **Git push** is restricted to `origin task/<id>-<slug>`. Pushing to `main`/`master`/`develop`/`staging` or any `--force` push is denied — the static globs in the permission template cover the literal shapes, but the categorical mechanism is the `PreToolUse` hook `hooks/block-protected-push.sh`, which resolves the actual destination ref and force flags (any refspec form, any flag spelling) before the push runs (PLAN.md §3).
- **`package.json` and `pnpm-lock.yaml`** are not edited directly — always go through `pnpm add/remove/update`.
- **Workflows under `.github/workflows/**`** are not edited by agents.
- **Secrets**: `.env*` is in git's global excludes; the `PreToolUse` hook `hooks/block-env-commit.sh` blocks any add/commit that touches `.env*`, and `hooks/scan-git-add.sh` / `hooks/scan-edit-write.sh` scan content against the catalogues in `hooks/patterns/`.
- **Commits**: Conventional Commits style. Merges are squash-only. Post-merge: delete remote branch, remove worktree, mark roadmap item `[x]`.

## Permissions model (PLAN.md §3)

The full allow/deny/ask matrix lives in PLAN.md §3 and is materialized as [templates/settings.template.json](templates/settings.template.json) (instantiated per project by `/atelier:setup-project`). When extending permissions:
- Default mode is `acceptEdits`.
- Network access is **allowlist-based, grown organically** — do not add broad network grants speculatively.
- Add new entries to the template, not directly to per-task `settings.json` (that file is regenerated each task).

The repo's own `.claude/settings.json` is a working dev convenience for the maintainer and is **not** the template the plugin will ship.

## Push / PR / merge gates (PLAN.md §6)

Implementations of `pr-flow` and the auto-merge logic must enforce:

- **Push gate**: lint + typecheck + unit/integration tests all green.
- **PR gate**: push gate + Playwright e2e green with screenshots attached + auto-generated description (roadmap ref, summary, validation checklist, screenshots).
- **Auto-merge gate**: CI green + independent `reviewer` agent (Opus, fresh context) approves.
- **Never auto-merge** — falls back to human: changes touching `package.json`/`pnpm-lock.yaml`, `Dockerfile`/`docker-compose*`, `.github/workflows/**`, oversize PRs (default: `>200 lines` AND `>10 files` after exemptions for tests/lockfiles/migrations — see `scripts/atelier-pr-size-check`; per-project override in `<project>/.atelier.json`), pending human comments, or `request-changes` from reviewer.

## Failure recovery (PLAN.md §8)

Retry budget is fixed: 3 attempts → reset worktree → 3 more attempts → hard stop with a `blocked` GitHub issue containing all `<worktree>/.task-log/<timestamp>-<attempt>.md` entries. Do not silently extend this budget.

## Out of scope for v1

Per PLAN.md §11: multi-repo tasks, deployment/release management, cost monitoring, visual-regression baselines, ROADMAP↔Issues sync. Suggestions touching these belong in the deferred-to-v2 table, not in v1 work.

## Working with this repo right now

- Work happens on `task/<id>-<slug>` (or `fix/*` / `docs/*` / `chore/*`) branches in PRs against `main` — never commit to `main` directly.
- There is no compile step. Validate changes the way CI does (`.github/workflows/structural.yml`): `bash -n` every touched shell file, run the hermetic suite (`for t in hooks/tests/*.test.sh; do bash "$t"; done`), and check touched JSON with `jq .` / `python3 -m json.tool`. Run `shellcheck` on modified scripts when available.
- New hook behaviour needs a matching hermetic test in `hooks/tests/*.test.sh` — the suite is auto-discovered by CI, so adding a test never requires editing the workflow.
