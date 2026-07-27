---
description: Pull the latest atelier from origin/main, render the permission diff (if any), and apply or revert based on the operator's response. Wraps `atelier-update`, supplying the permission-change confirmation through Claude Code's own I/O since the helper's own prompt needs a TTY the slash command's Bash calls never have.
argument-hint: "[--dry-run] [--yes]"
allowed-tools: Bash(atelier-update:*), Bash(atelier-permission-diff:*), AskUserQuestion
---

You are running the `/atelier:update` slash command. This is the front end for the `atelier-update` host-OS helper, with the permission-diff confirmation.

## What this command does

Invokes `atelier-update` against the operator's atelier clone. The helper handles the full update flow: `git pull origin main`, classify changed files, refresh instantiated templates in `$ATELIER_CONFIG_DIR`, trigger `claude plugin update` so future Claude Code sessions load the new agents/skills/commands.

When `templates/settings.template.json` is in the changed-files list, the helper invokes `atelier-permission-diff` to render an added/removed/impact summary in the shape of PLAN.md §9. The helper's own confirmation prompt (`Apply these permission changes? [y/N]`) needs stdin to be a TTY — and a slash command's `Bash` tool calls never have one, so the helper always lands in its non-interactive branch and refuses to apply. The command exists to supply that confirmation another way: it detects the refusal, asks the operator through `AskUserQuestion`, and — on acceptance — re-invokes the helper with `--yes` to apply. On decline, nothing further happens; the helper already left the old template in place.

## Argument parsing

`$ARGUMENTS` is optional. Valid forms:

- empty → full update flow.
- `--dry-run` → pull and classify but skip template refresh + plugin cache update. Useful to inspect what would change without applying.
- `--yes` → forward straight to the helper's `--yes` (skip the confirmation entirely). Only pass this when the operator explicitly asked to skip confirmation for this run — never add it on your own initiative.

Anything else: print usage and exit.

> Render the labels below in the operator's chatLanguage — the English is illustrative structure, not literal output.

```text
Usage: /atelier:update [--dry-run] [--yes]
```

## Phase 1 — Run the helper

```bash
atelier-update $ARGUMENTS
```

Capture exit code and the full stdout/stderr.

- **0** → update applied (or `--dry-run` succeeded), OR the update applied everything except a declined permission change (see below). Pass the helper's report through to the operator as-is — it is already operator-facing.
- **1** → error. Pass the helper's error output through; surface the suggested recovery (typically: commit/stash dirty changes, switch to main, re-run).
- **2** → already up to date. Surface a one-line confirmation: *"atelier is already up to date — nothing to do."*

If `--dry-run` or `--yes` was already in `$ARGUMENTS`, or the output contains no `non-interactive mode: refusing to apply permission changes` warning, stop here — the run is complete, go to Phase 2. Otherwise continue to the no-TTY fallback below.

## No-TTY fallback (permission-diff confirmation)

The helper's own `Apply these permission changes? [y/N]` prompt needs stdin to be a TTY, which this command's `Bash` calls never have — so a run touching `templates/settings.template.json` always lands in the helper's non-interactive branch, prints the rendered diff from `atelier-permission-diff`, then emits `non-interactive mode: refusing to apply permission changes without confirmation` and leaves the old template in place. That refusal is expected, not an error — the confirmation becomes **your** job:

1. Show the operator the permission diff exactly as the helper rendered it (the `atelier-permission-diff` output captured above — added/removed/impact per PLAN.md §9). Do not re-run `atelier-permission-diff` yourself; the helper already produced it.
2. Ask whether to apply the new permissions with `AskUserQuestion` (two options: apply / keep current).
3. On **apply**: re-invoke the helper with `--yes` added to the original `$ARGUMENTS` (`atelier-update $ARGUMENTS --yes`), and pass its output through unchanged.
4. On **keep current**: do nothing further — the helper's fail-safe default already left `$ATELIER_CONFIG_DIR/templates/settings.template.json` untouched. Confirm this to the operator in one line.

In non-interactive runs (`claude -p`, `$ATELIER_AUTO`) `AskUserQuestion` would hang the session: print the diff plus a one-line recommendation to re-run `/atelier:update` interactively (or with `--yes`, if the operator has already told you to skip confirmation for this run), and stop.

## Phase 2 — Post-update notes

If the helper returned 0 and **something was applied** (not `--dry-run`):

1. Surface a reminder: *"Restart open Claude Code sessions to pick up new agents/skills/commands. The plugin cache has been refreshed but Claude Code only loads it at session start."*
2. If `settings.template.json` changed and the operator **declined** in the no-TTY fallback above (or a `claude -p` / `$ATELIER_AUTO` run left the refusal unresolved), surface a follow-up note: *"The new permissions were not applied. The agent will keep using the old set until you re-run `/atelier:update` and accept."*

If `--dry-run` was used, remind the operator: *"This was a dry run — nothing changed on disk. Re-run `/atelier:update` (without --dry-run) to apply."*

## Decision rules

- **Never** invoke `git pull` directly from this command. The helper owns that logic; bypassing it would skip the safety checks (dirty tree refusal, non-main-branch refusal) the helper enforces.
- **Never** invoke `claude plugin update` directly. Same rationale — the helper coordinates the order (pull first, then refresh templates, then plugin cache) so the on-disk state stays consistent.
- **Never** write `$ATELIER_CONFIG_DIR/templates/settings.template.json` yourself, under any circumstance. Applying an accepted permission change always goes through re-invoking the helper with `--yes` — never by copying, `sed`-ing, or otherwise editing the file directly.
- **Never** add `--yes` to `$ARGUMENTS` on your own initiative. It is only ever added after the operator accepts through the no-TTY fallback's `AskUserQuestion`, or when the operator explicitly asked for it up front.

## Edge cases

- **No `claude` CLI on PATH**: the helper warns and continues; surface the warning so the operator knows the plugin cache wasn't refreshed (which means open and new Claude Code sessions will keep loading the cached old version until the operator manually runs `claude plugin update atelier@akalab-tech`).
- **`atelier-permission-diff` not found**: the helper warns and applies the new template without the diff. Surface the warning — the operator should check whether `install.sh` was run after the permission-diff helper landed.
- **Operator runs from inside Claude Code where the per-task `.claude/settings.json` is the active config** (rather than the project-level one): the update only refreshes the instantiated templates in `$ATELIER_CONFIG_DIR/templates/`. Per-task settings in worktrees are regenerated each task by `atelier-setup-project --per-task-settings`, so they pick up the new template on next task. No special handling needed.
