---
description: Show the operator what's in progress, what's blocked, and what's awaiting review — across the current project's roadmap, worktrees, and open PRs.
allowed-tools: Read, Glob, Grep, Bash(git wt list), Bash(git branch:*), Bash(git status:*), Bash(gh pr list:*)
---

You are running the `/status` slash command. This is **read-only** — never modify any file or perform a git/gh write.

Your job is to produce a single compact dashboard the operator can scan in five seconds.

## What to collect

### 1. In-progress tasks

Read `IN_PROGRESS.md`. For each task block you find, extract `id`, `title`, and (if present) `priority` / `estimate`. If the file is empty (only placeholder comments), report "no active task".

### 2. Worktrees

Run `git wt list` (the external `git-wt` CLI). List every worktree whose branch matches `task/*`. For each, capture:
- Worktree path
- Branch name
- Whether the working tree is dirty: `git -C <path> status --porcelain` non-empty → dirty.

Match these worktrees against the in-progress task by branch name (`task/<id>-<slug>` should pair with an `IN_PROGRESS.md` entry containing the same `<id>`). Flag mismatches (orphan worktree without an in-progress entry, or an in-progress entry without a worktree).

### 3. Open PRs

Run `gh pr list --json number,title,headRefName,isDraft,reviewDecision,mergeable --limit 20`. Parse the JSON. Categorise by `headRefName`:
- **From `task/*` branches** — atelier-originated PRs.
- **From other branches** — out-of-band PRs (operator's own, dependabot, etc.).

For each, capture: `#number`, title, `headRefName`, `isDraft` (true/false), `reviewDecision` (`APPROVED` / `CHANGES_REQUESTED` / `REVIEW_REQUIRED` / null), `mergeable` (`MERGEABLE` / `CONFLICTING` / `UNKNOWN`).

### 4. Blocked tasks

Read `ROADMAP.md`. Find every unchecked item with a `blocked_by:` pointing at an open (`[ ]`) id elsewhere in the same file. For each, capture `id`, `title`, and the blocker id.

## Output format

Use this exact dashboard shape so the operator can grep / scan reliably:

```text
== atelier status ==

▶ In progress
  • <#id> — <title> (<priority>, ~<estimate>)
    Worktree: <absolute-path> [clean | dirty: N file(s)]
    Branch:   task/<id>-<slug>

  (or: no active task — operator can run /next-task)

▶ Open PRs (from task/* branches)
  • #<NN> <title>
    Branch: <headRefName>
    State:  <draft|ready>  Review: <APPROVED|CHANGES_REQUESTED|REVIEW_REQUIRED|none>  Mergeable: <MERGEABLE|CONFLICTING|UNKNOWN>

  (omit the section entirely if there are none)

▶ Out-of-band PRs (non-task/* branches)
  • #<NN> <title> — <headRefName>

  (omit if there are none)

▶ Blocked in ROADMAP.md
  • <#id> — <title> (blocked_by: <#blocker-id>)

  (omit if there are none)

▶ Orphans (need cleanup)
  • Worktree without IN_PROGRESS entry: <branch> at <path>
  • IN_PROGRESS entry without worktree: <#id> — <title>

  (omit if there are none)
```

## Decision rules

- **Never** suggest a remediation as an automatic action. If an orphan worktree exists, **mention** that the operator might want `git wt rm <branch>`, but do not run it.
- **Never** invoke the `task-orchestrator` or any specialist agent from this command — `/status` is informational.
- If `gh pr list` fails (not authenticated, no network), report `PRs: <unavailable — gh auth status?>` and continue with the other sections.
- If `git wt list` fails (binary missing), report `Worktrees: <git-wt not installed — see /atelier:doctor>` and continue.

## Edge cases

- **No `IN_PROGRESS.md` at all** (operator hasn't run roadmap-tracking-flow init): report it once and recommend the operator initialise tracking (or run `/setup-project`).
- **PR title is very long**: truncate to 80 chars + `…` for the dashboard; the operator can run `gh pr view <NN>` for full detail.
- **The current directory is not inside a registered atelier project** — surface that clearly. `/status` makes sense only inside a project.
