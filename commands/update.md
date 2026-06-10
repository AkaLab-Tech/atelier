---
description: Pull the latest atelier from origin/main, render the permission diff (if any), and apply or revert based on the operator's response. Wraps `atelier-update` with the interactive prompt that the non-TTY terminal invocation cannot offer.
argument-hint: "[--dry-run]"
allowed-tools: Bash(atelier-update:*), Bash(atelier-permission-diff:*)
---

You are running the `/atelier:update` slash command. This is the interactive front for the `atelier-update` host-OS helper, with the permission-diff prompt.

## What this command does

Invokes `atelier-update` against the operator's atelier clone. The helper handles the full update flow: `git pull origin main`, classify changed files, refresh instantiated templates in `$ATELIER_CONFIG_DIR`, trigger `claude plugin update` so future Claude Code sessions load the new agents/skills/commands.

When `templates/settings.template.json` is in the changed-files list, the helper invokes `atelier-permission-diff` to render an added/removed/impact summary in the shape of PLAN.md §9 and **prompts the operator before applying** the new permissions to `$ATELIER_CONFIG_DIR`. On decline, the agent keeps operating under the old permission set until the operator re-runs and accepts.

The slash command exists because the helper's interactive prompt requires a TTY; `claude -p` and some terminal multiplexers don't always provide one. Invoking via the slash command goes through Claude Code's I/O, which is interactive by construction — the prompt always resolves cleanly.

## Argument parsing

`$ARGUMENTS` is optional. Valid forms:

- empty → full update flow.
- `--dry-run` → pull and classify but skip template refresh + plugin cache update. Useful to inspect what would change without applying.

Anything else: print usage and exit.

```text
Usage: /atelier:update [--dry-run]
```

## Phase 1 — Run the helper

```bash
atelier-update $ARGUMENTS
```

Capture exit code:

- **0** → update applied (or `--dry-run` succeeded). Pass the helper's full stdout/stderr through to the operator as-is — the report is already operator-facing.
- **1** → error. Pass the helper's error output through; surface the suggested recovery (typically: commit/stash dirty changes, switch to main, re-run).
- **2** → already up to date. Surface a one-line confirmation: *"atelier is already up to date — nothing to do."*

The helper handles all the heavy lifting (git pull, template refresh, permission diff, prompt, revert, plugin cache update). This command is a thin wrapper that exists so the prompt can be answered through Claude Code's interactive surface.

## Phase 2 — Post-update notes

If the helper returned 0 and **something was applied** (not `--dry-run`):

1. Surface a reminder: *"Restart open Claude Code sessions to pick up new agents/skills/commands. The plugin cache has been refreshed but Claude Code only loads it at session start."*
2. If `settings.template.json` changed and the operator **declined**, surface a follow-up note: *"You declined the new permissions. The agent will keep using the old set until you re-run `/atelier:update` and accept."*

If `--dry-run` was used, remind the operator: *"This was a dry run — nothing changed on disk. Re-run `/atelier:update` (without --dry-run) to apply."*

## Decision rules

- **Never** invoke `git pull` directly from this command. The helper owns that logic; bypassing it would skip the safety checks (dirty tree refusal, non-main-branch refusal) the helper enforces.
- **Never** invoke `claude plugin update` directly. Same rationale — the helper coordinates the order (pull first, then refresh templates, then plugin cache) so the on-disk state stays consistent.
- **Never** modify `$ATELIER_CONFIG_DIR/templates/settings.template.json` from this command. The helper does it (or doesn't, when the operator declines) and the slash command merely surfaces the result.

## Edge cases

- **No `claude` CLI on PATH**: the helper warns and continues; surface the warning so the operator knows the plugin cache wasn't refreshed (which means open and new Claude Code sessions will keep loading the cached old version until the operator manually runs `claude plugin update atelier@akalab-tech`).
- **`atelier-permission-diff` not found**: the helper warns and applies the new template without the diff. Surface the warning — the operator should check whether `install.sh` was run after the permission-diff helper landed.
- **Operator runs from inside Claude Code where the per-task `.claude/settings.json` is the active config** (rather than the project-level one): the update only refreshes the instantiated templates in `$ATELIER_CONFIG_DIR/templates/`. Per-task settings in worktrees are regenerated each task by `atelier-setup-project --per-task-settings`, so they pick up the new template on next task. No special handling needed.
