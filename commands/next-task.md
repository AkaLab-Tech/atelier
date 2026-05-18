---
description: Pick the next task from `ROADMAP.md`, set up its worktree, and hand it to the `task-orchestrator` agent end-to-end.
argument-hint: "[task-id]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(git status:*), Bash(git branch:*), Bash(git wt:*), Bash(sed:*), Skill, Task
---

You are running the `/next-task` slash command. Drive the full pickup-to-PR flow for one task from the project's `ROADMAP.md`, exactly as [PLAN.md §7](PLAN.md) prescribes.

User input: `$ARGUMENTS` (optional — if non-empty, treat it as a specific task id like `#42` to claim instead of auto-picking).

## Steps

### 1. Sanity-check the worktree

Run `git status --short` and `git branch --show-current`. If the working tree is dirty or the branch is anything other than `main` / `master` / a base branch, **stop**: surface the state and ask the operator whether to stash, continue on the current branch, or abort. Picking a new task on top of unrelated uncommitted work corrupts the chain.

### 2. Refuse to start if `IN_PROGRESS.md` is occupied

Read `IN_PROGRESS.md`. If it contains anything other than the placeholder HTML comments, a task is already in progress. **Do not silently override it.** Report the existing entry and offer two options:

- Resume the in-progress task with `/resume-task` (M4.3 — once it ships).
- Explicitly close out the existing task first (move to `HISTORY.md` or back to `ROADMAP.md`) before picking a new one.

Stop until the operator chooses.

### 3. Pick the task — `task-discovery` skill

If `$ARGUMENTS` is empty: invoke the `atelier:task-discovery` skill on the project's `ROADMAP.md`. It returns the structured record (`id`, `title`, `type`, `priority`, `estimate`, `blocked_by`, `worktree`, `acceptance`, `context`) per PLAN.md §5.

If `$ARGUMENTS` names a specific id: find that block in `ROADMAP.md` directly, parse it into the same shape, and **validate** it is unchecked and has no open `blocked_by` — surface the violation and stop if either fails.

### 4. Confirm with the operator

Display the chosen task in a short summary (`id`, `title`, `priority`, `estimate`). Ask explicitly: *"Claim this task?"*. Wait for a yes/no. If no, stop — do not move tracking or create a worktree.

### 5. Move `ROADMAP.md` → `IN_PROGRESS.md` in a single edit

Remove the task block from `ROADMAP.md`. Paste it into `IN_PROGRESS.md` between the marker comments. The roadmap-tracking-flow convention says the same PR that closes the task moves it from `IN_PROGRESS.md` to `HISTORY.md`, so this edit lives on the per-task branch you are about to create.

### 6. Create the per-task worktree — `git-wt` skill

Invoke the external `git-wt` skill (or `git wt switch <branch>` directly) to create the worktree at `task/<id-without-#>-<kebab-slug>` cut from updated `main` (or `dev` if it exists; the skill resolves the base policy). Capture the **absolute path** the skill prints on stdout — every subsequent step runs scoped to that path.

### 7. Instantiate the per-task `.claude/settings.json`

Read `$CLAUDE_PLUGIN_ROOT/templates/settings.template.json`. The template contains the literal placeholder `<worktree>` (in `additionalDirectories` and in some `Read(...)`/`Edit(...)`/`Write(...)` patterns) that must be substituted with the worktree path from step 6. The simplest substitution:

```bash
sed "s|<worktree>|<absolute-worktree-path>|g" \
    "$CLAUDE_PLUGIN_ROOT/templates/settings.template.json" \
    > <worktree>/.claude/settings.json
```

Make sure `<worktree>/.claude/` exists first (`mkdir -p`). Confirm the resulting file parses as JSON (`jq empty <worktree>/.claude/settings.json`). If it does not, **stop** and report.

### 8. Hand off to `task-orchestrator`

Launch the `atelier:task-orchestrator` agent (Opus) with the worktree path and the structured task record from step 3 as its briefing. From this point the chain (`implementer` → `tester` → `pr-author`) is the orchestrator's responsibility — `/next-task`'s job ends here.

## Output

End the command with a single status line:

```text
✓ Task claimed: <id> — <title>
  Worktree:    <absolute-path>
  Branch:      task/<id>-<slug>
  Next:        task-orchestrator running in the worktree.
```

Or, if any step aborted, report exactly which step and why — the operator decides whether to resume from there.

## Hard refusals

- **Never** create a worktree if `IN_PROGRESS.md` already has a task — see step 2.
- **Never** claim a task whose `blocked_by:` references an open item.
- **Never** edit `settings.template.json` itself from this command (that template is the source of truth — see M1.4); only the **instantiated** `<worktree>/.claude/settings.json` is written here.
- **Never** push or open a PR from this command — that is `pr-author`'s job at the end of the chain.
