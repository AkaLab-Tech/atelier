---
description: Deconfigure the current project from atelier. Default mode preserves operator content (ROADMAP/IN_PROGRESS/HISTORY, .claude/CLAUDE.md, .gitignore, .npmrc); `--purge` extends the cleanup to those files (with surgical strip of atelier's exact entries in .gitignore/.npmrc). Wraps the `atelier-remove-project` host-OS helper (M7.1.F32).
argument-hint: "[--purge] [--yes|-y]"
allowed-tools: Bash(atelier-remove-project:*), Bash(pwd)
---

You are running the `/atelier:remove-project` slash command. This is a thin wrapper around the `atelier-remove-project` bash binary (M7.1.F32) that detects the current project root and runs the removal against it.

## ⚠ Important safety caveat — running from inside Claude Code

When this command runs from a Claude Code session **inside the project being deconfigured**, it deletes the `<project>/.claude/settings.json` that the current session is actively using. The session may keep working until it reads the file again (Claude Code caches it at start), but any new session opened in the project will fall back to no-atelier permissions until you re-run `/atelier:setup-project`.

Recommendation: surface this caveat to the operator **before** running the binary, then proceed if they don't object.

## What to do

1. **Capture the project root** by running `pwd` (the slash command's cwd is the project the operator opened Claude Code in).
2. **Surface the safety caveat** above to the operator in 2-3 lines, then proceed unless they cancel via stop/escape.
3. **Run the binary** with the captured path and any flags from `$ARGUMENTS`. The binary handles its own interactive confirmation (lists what will be deleted / preserved, prompts `[y/N]`) unless `--yes` is in `$ARGUMENTS`.

```bash
ATELIER_REMOVE_TARGET="$(pwd)"
atelier-remove-project "$ATELIER_REMOVE_TARGET" $ARGUMENTS
```

4. **Pass the binary's stdout verbatim** to the operator. The binary's report already lists what was deleted, what was preserved, and the unregister status.

## Stop rule

Your turn ends when you finish emitting the binary's last line. No commentary, no "everything looks good", no follow-up suggestions. Same rule as `/atelier:doctor` (M7.1.F25): the binary's report is the entire output the operator needs.

## Decision rules

- **Never** invoke any tool other than `Bash(atelier-remove-project)` and `Bash(pwd)`. The binary handles every step of the removal — deletions, registry update, .gitignore/.npmrc strip, on-disk inventory.
- **Never** modify any file outside the binary. The binary is the single point of writes; replicating its logic inline would drift.
- **Never** auto-add `--yes` to `$ARGUMENTS`. If the operator wants non-interactive mode they pass it explicitly. Defaulting to interactive prevents accidental deletion.
- **Never** offer to undo. The binary's `--purge` is irreversible by design (operator content like `ROADMAP.md` is gone). The operator can re-run `/atelier:setup-project` to scaffold a fresh project, but the deleted content is not recoverable from the binary's report.

## Edge cases

- **The cwd is NOT a registered atelier project**: the binary detects this in its pre-flight and exits 0 with `nothing to do — exiting cleanly`. Pass that through verbatim. Do not retry with `--purge` or anything else.
- **The cwd is inside a task worktree** (`<project>-worktrees/<task>/`): the binary uses the operator-supplied path verbatim, so `pwd` from a worktree would target the **worktree** as the project — wrong. Detect this in step 1 by checking whether the current branch name matches `task/*` (via `git rev-parse --abbrev-ref HEAD`) and refuse with: *"You appear to be inside a task worktree. Run `/atelier:remove-project` from the main project root, not a worktree."*
- **The operator passes a positional argument** (e.g. `/atelier:remove-project /some/other/path`): forward it to the binary AS-IS (it accepts an absolute path argument). The cwd-detection default applies only when `$ARGUMENTS` has no positional.
