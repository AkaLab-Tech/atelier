---
description: Decompose a single ROADMAP.md task into an epic with sub-tasks, in place, before it is planned. Standalone pre-split — the operator can run it ahead of `/atelier:plan-task`, which also decomposes oversize tasks on its own.
argument-hint: "<task-id>"
allowed-tools: Read, Bash(jq:*), Bash(git -C * status:*), Bash(git -C * diff:*), Bash(git -C * add:*), Bash(git -C * commit:*), Task
---

You are running the `/atelier:slice-task` slash command. The operator invokes this when they already know a flat task is going to be too large and want it pre-split into an epic before planning — independent of the planner's own oversize check during `/atelier:plan-task`.

## What this command does

Dispatches the `task-decomposer` agent on a single task in the current project's `ROADMAP.md`, rewrites that task block as an epic with sub-tasks (PLAN.md §5 format), and commits the rewrite as a dedicated `chore(roadmap)` commit on the current branch.

This command does **not** start the implement chain and does **not** mark anything `[ready]`. It only reshapes the ROADMAP entry. After slicing, each sub-task still has to be planned with `/atelier:plan-task <sub-id>` (which writes `.plan/<sub-id>.md` and flips `[ready]`) before `/atelier:next-task` can claim it.

## Argument parsing

`$ARGUMENTS` must carry a single task id matching `^#?\d+$` (with or without leading `#`). Examples that should resolve: `#42`, `42`. Anything else: refuse with a clear error.

If `$ARGUMENTS` is empty or has more than one token, print usage and exit:

```text
Usage: /atelier:slice-task <task-id>
Example: /atelier:slice-task #42
```

## Phase 1 — Pre-flight

1. **Resolve the project root.** The current working directory is the project root in the canonical case (`/atelier:slice-task` is invoked from inside the project the operator is working on). If the cwd does not contain a `ROADMAP.md`, print: *"slice-task must be run from a project root with ROADMAP.md present"* and exit.
2. **Check `taskDecomposer.enabled`.** Run `jq '.taskDecomposer.enabled // true' .atelier.json` (default `true` when missing). If `false`, **warn but proceed** — the operator explicitly invoked the manual command, which overrides the project-wide off-switch. Surface a one-line note: *"Note: `taskDecomposer.enabled` is false in .atelier.json; running anyway because /slice-task is the manual override."*
3. **Verify the working tree is clean** on the relevant slice: `git status --porcelain ROADMAP.md`. If `ROADMAP.md` has uncommitted changes, refuse — the decomposer's `Edit` would mix the operator's pending edits with the rewrite, and the resulting commit would be malformed. Surface: *"ROADMAP.md has uncommitted changes; commit or stash them first."*

## Phase 2 — Dispatch the agent

Invoke the `task-decomposer` agent via the `Task` tool. The briefing must include:

- `task_id`: the parsed id (with `#` prefix).
- `project_root`: the absolute path resolved in Phase 1.
- `entry_point`: `manual`.

Do **not** pass `trigger_signals` — the planner passes those when it invokes the decomposer during `/plan-task`; in manual mode, the operator's invocation is the trigger.

## Phase 3 — Commit the rewrite

If the agent returned `status: decomposed`:

1. `Bash`: `git diff --stat ROADMAP.md` — confirm exactly one file changed and that the change is what the agent described in its return.
2. `Bash`: `git add ROADMAP.md`.
3. `Bash`: commit with the conventional-commits message:
   ```text
   chore(roadmap): decompose <task_id> into <N> sub-tasks via /slice-task
   ```
4. Surface the commit SHA to the operator.

If the agent returned `refused-*` or `error`:

- Do **not** commit anything; the agent has already left `ROADMAP.md` unchanged (or the verification failed and the `Edit` was rejected by the agent's own check).
- Surface the agent's `status` and the reason verbatim to the operator. Suggest the next action based on the status:
  - `refused-already-epic` → "Task is already an epic; nothing to slice."
  - `refused-not-found` → "No task with id `<task_id>` found in ROADMAP.md."
  - `refused-marker-present` → "Task carries an `[OVERSIZE]` or `[BLOCKED]` marker; resolve the marker first before slicing."
  - `error: task lacks an explicit id` → "Add an explicit `#<id>` to the task line in ROADMAP.md before slicing."
  - `error: task acceptance criteria too vague` → "Add concrete acceptance bullets to the task before slicing — the decomposer cannot guess sub-task boundaries from a one-line title."
  - Any other `error` → surface the agent's message and stop.

## Phase 4 — Report

Print a compact summary the operator can scan:

```text
== /atelier:slice-task <task_id> ==

Decomposed:   <task_id> → <epic_id> with <N> sub-tasks
Sub-tasks:
  - <#id>a — <title> (~<est>)
  - <#id>b — <title> (~<est>) blocked_by:<#id>a
  ...
Commit:       <sha>
Next:         run /atelier:plan-task on each sub-task (<#id>a, <#id>b, ...) to plan + mark it [ready], then /atelier:next-task to claim it
```

On refusal / error, the summary is the agent's reason plus the suggested next action from Phase 3.

## Decision rules

- **Never** push the commit yourself. The slice-task commit lives on the current branch; if the branch is `main` (the operator ran the command from the main worktree, not a task worktree), surface the situation but do not push — the operator decides when to push.
- **Never** invoke `task-orchestrator`, `implementer`, or any other agent from this command. `/slice-task` is decomposition-only.
- **Never** edit `IN_PROGRESS.md` or `HISTORY.md`. The decomposition happens before the task is claimed, so there is no `IN_PROGRESS.md` entry yet to update.
- **Never** retry on a refused / error outcome. The operator's input is needed before the next attempt (clarify the spec, remove the marker, etc.). Auto-retry would just waste another Opus pass on the same misshapen input.

## Edge cases

- **The operator runs the command inside a task worktree** (not the main worktree): the project root resolution lands on the task worktree's copy of `ROADMAP.md`, which is the wrong target — `ROADMAP.md` belongs on `main`. Detect this by checking `git rev-parse --abbrev-ref HEAD`; if it starts with `task/`, refuse with: *"/atelier:slice-task must be run from the main worktree, not a task worktree. The ROADMAP.md you'd be editing is on the wrong branch."*
- **The task id resolves to a sub-task inside an existing epic** (e.g. `#42b`): the decomposer's `refused-already-epic` path covers this — the sub-task is already part of an epic, which is a decomposed shape. Surface the existing epic's id so the operator can navigate to it.
- **Multiple tasks share the same id** (data quality issue in `ROADMAP.md`): the decomposer reads the first match top-down. Surface a warning in the report so the operator can deduplicate the ROADMAP.
