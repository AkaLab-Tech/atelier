---
description: Review and clean up the task-cycle debris that auto-merge's per-task cleanup leaves behind — orphan worktrees, merged/closed local `task/*` branches, and merged/closed `origin/task/*` remotes — across every atelier-registered project. Always enumerates first and requires your explicit authorization before deleting anything; never touches active/blocked/oversize tasks, open PRs, dirty worktrees, or protected branches.
argument-hint: "[--project PATH] [--include-unmerged]"
allowed-tools: Bash(atelier-housekeeping:*)
---

You are running the `/atelier:housekeeping` slash command — the operator-facing
entry point to atelier's daily worktree/branch cleanup. It wraps the
`atelier-housekeeping` bash binary, which enumerates removable items across the
operator's registered projects and deletes them only on authorization.

The operator authorizes deletion **in this conversation**, not via a TTY prompt
the binary cannot reach. So this command always runs the read-only report
first, shows it, and only deletes after the operator says yes.

## What to do

1. **Enumerate (read-only).** Run the binary in report mode, forwarding any
   `$ARGUMENTS` the operator passed (e.g. `--project`, `--include-unmerged`):

   ```bash
   atelier-housekeeping --report $ARGUMENTS
   ```

   Relay its output to the operator verbatim — it already produces a
   categorized summary (worktrees, local branches, remote branches, and a
   "needs review" group for unmerged work).

2. **If nothing is removable** (the binary prints `OK: nothing to clean up`),
   you are done. Do not run anything else.

3. **If there are removable items, ask for authorization.** Summarize the
   counts per category in one line and ask the operator to confirm. Do **not**
   proceed without an explicit yes. Offer the per-project scope (`--project`)
   if they want to narrow it.

4. **On explicit authorization, apply.** Run the binary in sweep mode with
   `--yes` (and the same scope arguments the operator approved):

   ```bash
   atelier-housekeeping --yes $ARGUMENTS
   ```

   Relay the result verbatim.

## Stop rule

Your turn ends when you finish emitting the binary's last line (after the
report, if the operator declines or there is nothing to do; after the sweep,
if they authorized). No "all clean!" epilogue.

## Decision rules

- **Never** run the sweep (`--yes`, or sweep mode without `--report`) before
  the operator has seen the report and explicitly authorized it. The whole
  point of this command is "always ask first".
- **Never** add `--include-unmerged` on the operator's behalf. Unmerged work
  (orphan branches with no PR, or a PR closed without merging) is listed under
  "needs review" and skipped by default. Only pass it if the operator asked.
- **Never** invoke any tool other than `Bash(atelier-housekeeping)`. The binary
  owns all git/gh enumeration and every deletion — do not run `git worktree
  remove`, `git branch -d`, or `git push --delete` yourself.
- **Never** re-interpret the safety rails. The binary already refuses to touch
  active/blocked/oversize tasks, open PRs, dirty worktrees, and protected
  branches. If the operator asks you to force-remove one of those, decline and
  explain it is a deliberate safety rail.

## Edge cases

- **No registered projects / no config**: the binary errors with a clear
  message (atelier not installed). Relay it; do not try to repair.
- **`gh` not installed**: the binary notes it and falls back to
  merged-into-main detection only (PR state unknown). Relay the note; the
  reduced sweep is still safe.
- **Non-interactive context**: this command is interactive by design (it waits
  for the operator's authorization). Do not auto-add `--yes` to bypass that.
