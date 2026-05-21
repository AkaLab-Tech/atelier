---
description: Initialise a project so the operator can run atelier tasks in it — delegates to the `atelier-setup-project` bash helper installed by `install.sh` Phase C.1. Idempotent — re-running on a configured project offers a reconfigure flow (interactive only).
argument-hint: "[project-path] [--yes|-y]"
allowed-tools: Bash(atelier-setup-project:*)
---

You are running the `/setup-project` slash command. This command is a **thin wrapper**: the actual bootstrap lives in the `atelier-setup-project` bash script installed at `~/.local/bin/atelier-setup-project` (by `install.sh` Phase C.1). The wrapper exists because the Claude Code harness gates `Write` / `Edit` on any path under `.claude/**` with an interactive approval prompt that fatally hangs `claude -p` (non-interactive) mode. Running the bootstrap outside the harness sidesteps that gate entirely. See HISTORY.md → M4.9 for the full rationale.

## What to do

Invoke the bash helper, passing through the operator's arguments verbatim and the plugin root from `$CLAUDE_PLUGIN_ROOT`:

```bash
atelier-setup-project --plugin-root "$CLAUDE_PLUGIN_ROOT" $ARGUMENTS
```

That single command does **all** of the work:

1. Resolves the project path (defaults to `.` if `$ARGUMENTS` is empty); refuses `$HOME`, `/`, `/etc`, `/usr`, `/Applications`, `/bin`, `/sbin`, `/var`, `/opt`, `/private`, and the plugin root itself.
2. Detects non-interactive mode via `--yes` / `-y` in `$ARGUMENTS`, or `$ATELIER_AUTO`.
3. Reads `$ATELIER_CONFIG_DIR/projects.json` (default `~/.claude-work/projects.json`, per M5.0 + M5.0.2). If the project is already configured: interactive → ask to reconfigure; non-interactive → refuse with exit code 2.
4. Writes `<path>/.claude/settings.json` from `$ATELIER_CONFIG_DIR/templates/settings.template.json` (the **instantiated** template — install.sh already substituted any install-time placeholders) with `<worktree>` → project path. Validates the result parses with `jq empty` and that no literal `<worktree>` token remains.
5. Creates `<path>/ROADMAP.md`, `<path>/IN_PROGRESS.md`, `<path>/HISTORY.md`, `<path>/.claude/CLAUDE.md` only when missing (the latter from `$CLAUDE_PLUGIN_ROOT/templates/project-claude.md.template`).
6. Creates or appends to `<path>/.npmrc` the three PLAN.md §4 guardrails (`ignore-scripts=true`, `minimum-release-age=10080`, `audit-level=moderate`); never weakens existing values.
7. Creates or appends to `<path>/.gitignore` the four required entries (`.task-log/`, `.claude/settings.json`, `.claude/settings.local.json`, `.DS_Store`). `.claude/settings.json` is gitignored because the helper substitutes `<worktree>` with the operator's absolute path; committing it would propagate that path to every clone.
8. Records the setup in `$ATELIER_CONFIG_DIR/projects.json` with `setupCompleted` and `setupVersion`.

The helper prints its own progress and final summary to stdout. Relay its output back to the operator verbatim — do not paraphrase. If the helper exits non-zero, surface the error and stop; do not try to "fix forward".

## Hard refusals

These all live in the bash helper; documented here so the operator knows what to expect when reading the `/setup-project` contract:

- **Never overwrite** `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` / `.claude/CLAUDE.md` if they already exist.
- **Never weaken** an existing `.npmrc` (no `audit-level` downgrade, no `minimum-release-age` reduction).
- **Never reconfigure under `--yes` / `ATELIER_AUTO`**: re-running on a configured project in non-interactive mode exits with code 2.
- **Never run `git init`** or any git write — `/setup-project` is for atelier scaffolding only.
- **Never invoke `Write`, `Edit`, `mkdir`, `sed`, or `jq` directly from this slash command.** All file work happens inside the bash helper, which is the only tool allowed here.

## Where to look if something breaks

- `atelier-setup-project --help` prints the full CLI contract.
- `which atelier-setup-project` should resolve to `~/.local/bin/atelier-setup-project` (a symlink installed by `install.sh` Phase C.1).
- If `which` is empty: re-run `install.sh` Phase C.1, or check that `~/.local/bin` is on `$PATH`.
- If the helper reports "cannot locate the atelier plugin root", `$CLAUDE_PLUGIN_ROOT` is not set (you are probably running ad-hoc via `claude --plugin-dir`). Run `atelier-setup-project --plugin-root /abs/path/to/atelier-checkout <path>` directly from your terminal, or export `ATELIER_PLUGIN_ROOT` in your shell.

## Known maintenance tax (follow-up captured in M4.9 IN_PROGRESS entry)

This spec and `scripts/atelier-setup-project` implement the same flow in two languages (markdown contract vs. bash). They have to be hand-synced when either changes. A future task will collapse the duplication — either by making the bash script the source of truth (and reducing this spec to "see `atelier-setup-project --help`") or by adding a CI smoke check that asserts the two stay aligned. Until then, when you change one, change the other in the same PR.
