---
description: Review and clean up the task-cycle debris that auto-merge's per-task cleanup leaves behind — orphan worktrees, merged/closed local `task/*` branches, and merged/closed `origin/task/*` remotes — across every atelier-registered project. Always enumerates first and requires your explicit authorization before deleting anything; never touches claimed tasks (board Status In Progress, or an `IN_PROGRESS.md` entry), open PRs, dirty worktrees, or protected branches.
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
  claimed tasks (board Status In Progress on `github-project`; an
  `IN_PROGRESS.md` entry in the main checkout or the task's worktree on
  `files`; any task whose claim state cannot be read), open PRs, dirty
  worktrees, and protected branches. A worktree is removed only when its PR is
  MERGED; ancestry alone never qualifies. On `github-project`, `task/<N>-<slug>`
  carries the GitHub issue number and the board's Atelier ID is only a
  cross-check: an item whose Atelier ID differs from N, or whose N is another
  issue's Atelier ID, is kept and reported as an Atelier ID mismatch, never
  removed (not even with `--yes`). If the operator asks you to force-remove one of those, decline and
  explain it is a deliberate safety rail.

## Edge cases

- **No registered projects / no config**: the binary errors with a clear
  message (atelier not installed). Relay it; do not try to repair.
- **`gh` not installed**: the binary notes it and falls back to
  merged-into-base detection only (PR state unknown). Relay the note; the
  reduced sweep is still safe.
- **Unresolvable task branch**: if the board cannot resolve a task branch's
  issue, it is reported by name with its reason under Kept (protected) and left
  untouched; the other tasks are classified normally.
  The board is read from `.githubProject.owner`/`projectNumber`; when the
  issue's own project items cannot see the item (a board owned by another
  account, or a user-owned aggregated board), an owner-side scan of that board
  resolves it, and an unreadable or incomplete scan keeps the item as unknown.
- **Non-interactive context**: this command is interactive by design (it waits
  for the operator's authorization). Do not auto-add `--yes` to bypass that.
