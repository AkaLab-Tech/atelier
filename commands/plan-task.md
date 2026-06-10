---
description: Plan a single ROADMAP.md task — dispatch the planner, review the draft with the product lead, and on approval commit the plan and mark the task `[ready]` so the orchestrator can claim it.
argument-hint: "<task-id>"
allowed-tools: Read, Edit, Bash(jq:*), Bash(git -C * status:*), Bash(git -C * diff:*), Bash(git -C * add:*), Bash(git -C * commit:*), Bash(git -C * checkout:*), Bash(git -C * clean:*), Bash(git status:*), Bash(git diff:*), Bash(git add:*), Bash(git commit:*), Bash(git checkout:*), Bash(git clean:*), Bash(git rev-parse:*), Task
---

You are running the `/atelier:plan-task` slash command. The product lead invokes this to plan a task **before** the orchestrator can claim it. A task is only claimable once it carries the `[ready]` marker and a committed `.plan/<id>.md`; this command is the only way to assert that.

## What this command does

Dispatches the `planner` agent on one task in the current project's `ROADMAP.md`, presents the draft plan(s) to the product lead, and **only on explicit approval** commits the plan artifact(s) under `.plan/`, flips the task line(s) to `[ready]`, and (when the planner decomposed an oversize task) commits the epic rewrite in the same commit.

This command does **not** start the implement chain. The next `/atelier:next-task` will see the `[ready]` entry and claim it.

## Argument parsing

`$ARGUMENTS` must carry a single task id matching `^#?\d+[a-z]?$` (with or without leading `#`; a letter suffix like `42a` is allowed so a single sub-task can be planned). Anything else: print usage and exit.

```text
Usage: /atelier:plan-task <task-id>
Example: /atelier:plan-task #42
```

## Interaction mode

This command is **interactive by design** — approving a plan is a human gate. If running non-interactively (`$ARGUMENTS` carries `--yes`/`-y`, or `ATELIER_AUTO` is set), **do not auto-approve**: run the planner, write the draft, and **stop**, reporting the draft path(s) and that approval requires an interactive `/atelier:plan-task` run. Never flip `[ready]` without a human approval — auto-approving would defeat the entire planning gate.

## Phase 1 — Pre-flight

1. **Resolve the project root.** The cwd is the project root in the canonical case. If it has no `ROADMAP.md`, print *"plan-task must be run from a project root with ROADMAP.md present"* and exit.
2. **Refuse inside a task worktree.** `git rev-parse --abbrev-ref HEAD`; if it starts with `task/`, refuse: *"/atelier:plan-task must be run from the main worktree, not a task worktree. The ROADMAP.md and `.plan/` you'd be editing are on the wrong branch."* Plans belong on the base branch alongside the ROADMAP.
3. **Verify the relevant paths are clean.** `git status --porcelain ROADMAP.md .plan`. If `ROADMAP.md` or `.plan/` has uncommitted changes, refuse — the planner's writes would mix with the operator's pending edits and the commit would be malformed. Surface: *"ROADMAP.md / .plan have uncommitted changes; commit or stash them first."*

## Phase 2 — Dispatch the planner

Invoke the `planner` agent via the `Task` tool. The briefing must include:

- `task_id`: the parsed id (with `#` prefix).
- `project_root`: the absolute path resolved in Phase 1.
- `entry_point`: `plan-task`.

**Wait for it to return.** The planner writes draft `.plan/<id>.md` file(s) (and, for an oversize task, rewrites the ROADMAP block into an epic via `task-decomposer`) — all as **uncommitted** working-tree changes.

## Phase 3 — Review with the product lead

If the planner returned `status: planned`:

1. `Bash`: `git diff --stat ROADMAP.md .plan` — confirm only the expected files changed.
2. Present the draft to the product lead in a compact, readable form: for each unit, show its `title`, the `Approach`, `Affected areas`, `Acceptance criteria`, and `Risks / open questions` from the draft `.plan/<id>.md`. If the task was decomposed, show the epic + sub-task split first.
3. Ask explicitly: **"Approve this plan?"** — and accept either a plain approval or approval-with-edits. If the product lead asks for changes that are small wording tweaks, apply them to the `.plan/<id>.md` with `Edit` and re-confirm. If they want a materially different approach, discard (Phase 5) and suggest re-running `/atelier:plan-task` after refining the ROADMAP task.

If the planner returned `refused-*` / `error`, skip to Phase 5 (nothing to commit) and surface the reason with the matching next action:

- `refused-not-found` → "No task with id `<task_id>` in ROADMAP.md."
- `refused-already-done` → "Task is already `[x]`; nothing to plan."
- `refused-marker-present` → "Task carries `[OVERSIZE]`/`[BLOCKED]`; resolve the marker first."
- `refused-already-ready` → "Task is already `[ready]` with a committed plan. To re-plan, remove the `[ready]` marker (and `.plan/<id>.md`) first, then re-run."
- `error: task lacks an explicit id` → "Add an explicit `#<id>` to the task line before planning."
- Any other `error` → surface verbatim and stop.

## Phase 4 — On approval: flip `[ready]`, commit

Only after explicit approval:

1. **Flip `[ready]`** on each id the planner returned in `ready_to_mark` (units with no open `blocked_by` are marked first; a unit gated by an unmet `blocked_by` is still planned and gets `[ready]` too — the orchestrator's `blocked_by` filter keeps it from being claimed early). Edit the item line in `ROADMAP.md`, inserting the literal token `[ready]` immediately after the checkbox:
   ```text
   - [ ] [ready] `feat` Export reports to CSV `#42` `~4h`
   ```
   Never flip the **epic** line — readiness is a per-claimable-unit property; the orchestrator descends into sub-tasks.
2. **Flip the draft status** in each `.plan/<id>.md` from `Status: draft (pending product-lead approval)` to `Status: ready (approved — product lead)`.
3. **Stage and commit** the plan, the `[ready]` flips, and (if decomposed) the epic rewrite together:
   ```bash
   git add ROADMAP.md .plan
   ```
   Commit with a conventional message:
   ```text
   chore(plan): mark <task_id> ready with approved plan
   ```
   For the decomposed case:
   ```text
   chore(plan): decompose <task_id> into <N> sub-tasks and mark ready
   ```
4. Surface the commit SHA.

## Phase 5 — Discard (rejection / refusal)

When the product lead rejects, or the planner refused/errored after leaving working-tree changes (e.g. a decomposer rewrite landed before a later failure):

1. `git checkout -- ROADMAP.md` to revert any ROADMAP rewrite.
2. Remove the draft plan files the planner wrote that are not tracked: `git clean -f .plan` (only the new draft files; never touch already-committed plans). Confirm with `git status --porcelain .plan` before and after.
3. Report that nothing was committed and the ROADMAP/`.plan` are back to their pre-command state.

## Output

```text
== /atelier:plan-task <task_id> ==

Planned:   <task_id> — <title>   (decomposed into <N> sub-tasks: <#ids>)   # decomposition line only when applicable
Plans:     .plan/<id>.md [, .plan/<id>.md ...]
Ready:     <#ids flipped to [ready]>
Commit:    <sha>
Next:      run /atelier:next-task to claim <first ready id>
```

On refusal / rejection, the output is the reason plus the suggested next action, and a line confirming nothing was committed.

## Hard refusals

- **Never** flip `[ready]` or commit a plan without explicit product-lead approval. In non-interactive mode, stop at the draft.
- **Never** start the implement chain or invoke `task-orchestrator` / `implementer` from this command. `/plan-task` is planning-only.
- **Never** run from a task worktree — the ROADMAP and `.plan/` you'd edit are on the wrong branch (Phase 1 step 2).
- **Never** push the commit. The plan commit lives on the current branch; the operator decides when to push (and never to a protected branch directly).
- **Never** edit `IN_PROGRESS.md` or `HISTORY.md` — the task is not claimed yet, so there is no in-progress entry.
