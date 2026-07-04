---
description: Show the operator what's in progress, what's blocked, and what's awaiting review — across the current project's roadmap, worktrees, and open PRs.
allowed-tools: Read, Glob, Grep, Bash(git wt list), Bash(git branch:*), Bash(git status:*), Bash(gh pr list:*), Bash(atelier-task-backend:*), Bash(gh issue list:*)
---

You are running the `/status` slash command. This is **read-only** — never modify any file or perform a git/gh write.

Your job is to produce a single compact dashboard the operator can scan in five seconds.

## Bash output handling — never retry on success

When a Bash call returns exit code 0 with non-empty stdout, treat it as **successful** and use the captured output verbatim. The Bash tool's UI may collapse long output with `… +N lines (ctrl+o to expand)` — that ellipsis is **cosmetic**; the full output is already in your context. **Do NOT re-invoke the same command** "to see the rest" — there is no rest, and repeated identical invocations create a loop the operator has to interrupt. If you genuinely need different data, run a *different* command. Identical successive Bash invocations are always a bug in your own reasoning, never a system retry.

This rule matters especially for the worktree probe in section 2 below (`git wt list`, `git -C <path> status --porcelain`): one successful call per worktree is enough.

## What to collect

### 0. Resolve backend

Run `atelier-task-backend .` once, at the start of the command, and hold the result (`BACKEND`) for the rest of the run. `files` drives the local `ROADMAP.md` / `IN_PROGRESS.md` reads below unchanged; any other value (`linear`, `github-project`, …) means those files legitimately do not exist at the repo root, so sections 1 and 4 below degrade gracefully instead of reporting a false "missing" error.

### 1. In-progress tasks

When `BACKEND` is `files`: read `IN_PROGRESS.md`. For each task block you find, extract `id`, `title`, and (if present) `priority` / `estimate`. Classify by marker prefix on the heading line:

- **No marker** → active task currently being worked on. There should be at most one of these at any time; more than one indicates a chain that did not finish cleanly.
- **`[BLOCKED]` marker** → task that `unblocker` parked after a hard-stop. Cross-reference against the `gh issue list` result from section 4 (the issue list is authoritative); render it in the `▶ Blocked` section, not here.
- **`[OVERSIZE]` marker** → task whose PR was refused by `pr-author`'s size gate (branch pushed, no PR opened, suggested slice boundaries in `pr-author`'s output and possibly the GitHub branch description). The operator handles these by re-planning into sub-tasks, opening the PR manually, or raising the budget in `.atelier.json`.

If the file is empty (only placeholder comments), report "no active task".

When `BACKEND` is not `files`: `IN_PROGRESS.md` legitimately does not exist. Skip straight to reporting in-progress state from whatever the backend's board surfaces elsewhere in this command (open PRs, worktrees) — do not report a missing-file error for this section. In-progress board reads beyond that are out of scope for this command; a bare "no local IN_PROGRESS.md — this project tracks state on the `<BACKEND>` board" line is sufficient.

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

Two independent kinds of blocked, always checked regardless of `BACKEND`:

**Hard-stopped** (backend-independent — the GitHub issue queue is the single source of truth). Run `gh issue list --label blocked --state open --json number,title,url,createdAt`. Every issue in the result is a task `unblocker` halted after the retry budget; the issue title carries the shape `[blocked] <id> — <title>`, parse `id` and `title` out of it. Format `createdAt` as a cheap "opened `<YYYY-MM-DD>`" (date portion only). When `BACKEND` is `files`, also cross-reference the `[BLOCKED] see #NN` marker from section 1 — the issue list stays authoritative; the marker is only used to confirm the `IN_PROGRESS.md` entry matches a real open issue.

**Dependency-gated** (backend-aware):
- When `BACKEND` is `files`: read `ROADMAP.md`. Find every unchecked item with a `blocked_by:` pointing at an open (`[ ]`) id elsewhere in the same file. For each, capture `id`, `title`, and the blocker id.
- When `BACKEND` is not `files`: do not attempt to reconstruct this list — there is no local file to scan. Render a single note instead: "dependency-gated view lives on the `<BACKEND>` board".

## Output format

Use this exact dashboard shape so the operator can grep / scan reliably:

```text
== atelier status ==

▶ In progress
  • <#id> — <title> (<priority>, ~<estimate>)
    Worktree: <absolute-path> [clean | dirty: N file(s)]
    Branch:   task/<id>-<slug>

  (or: no active task — operator can run /atelier:next-task)

▶ Oversize (PR refused by size gate)
  • <#id> — <title>
    Branch: task/<id>-<slug> (pushed, no PR)
    Resolution: re-plan into sub-tasks | open PR manually (`gh pr create`) | raise budget in .atelier.json

  (omit if there are none)

▶ Blocked
  Hard-stopped (halted after retry budget — investigate, then /atelier:resume-task):
  • <#id> — <title>
    Issue: #<NN> — <url>  (opened <YYYY-MM-DD>)

  Dependency-gated (waiting on another task to merge):
  • <#id> — <title> (blocked_by: <#blocker-id>)

  (omit each subsection when empty; omit the whole section when both are empty.
   On a non-files backend, the dependency-gated subsection is instead a single line:
   "dependency-gated view lives on the <BACKEND> board".)

▶ Open PRs (from task/* branches)
  • #<NN> <title>
    Branch: <headRefName>
    State:  <draft|ready>  Review: <APPROVED|CHANGES_REQUESTED|REVIEW_REQUIRED|none>  Mergeable: <MERGEABLE|CONFLICTING|UNKNOWN>

  (omit the section entirely if there are none)

▶ Out-of-band PRs (non-task/* branches)
  • #<NN> <title> — <headRefName>

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
- If `gh issue list` fails (not authenticated, no network), report `Blocked (hard-stopped): <unavailable — gh auth status?>` and continue with the other sections — do not skip the whole `▶ Blocked` section, the dependency-gated subsection may still be renderable.
- If `git wt list` fails (binary missing), report `Worktrees: <git-wt not installed — see /atelier:doctor>` and continue.

## Edge cases

- **No `IN_PROGRESS.md` at all**: if `BACKEND` is `files` and the operator simply hasn't run roadmap-tracking-flow init, report it once and recommend the operator initialise tracking (or run `/atelier:setup-project`). If `BACKEND` is not `files`, this is expected (state lives on the board) — do not treat it as an error.
- **PR title is very long**: truncate to 80 chars + `…` for the dashboard; the operator can run `gh pr view <NN>` for full detail.
- **The current directory is not inside a registered atelier project** — surface that clearly. `/status` makes sense only inside a project.
