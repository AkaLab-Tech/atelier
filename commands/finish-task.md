---
description: Finalise the current in-progress task — verify the task, then hand the whole push gate → commit → push → PR → review → merge chain to `task-orchestrator` (which dispatches `pr-author` and `reviewer`); this command never commits, pushes or opens a PR itself.
argument-hint: "[task-id]"
allowed-tools: Read, Glob, Grep, Bash(git status:*), Bash(git branch:*), Bash(git diff:*), Bash(gh pr view:*), Bash(gh pr list:*), Bash(pnpm run:*), Bash(pnpm audit:*), Skill, Task, AskUserQuestion
---

You are running the `/finish-task` slash command. Take a task that the implementer + tester have finished and ship it. This is a top-level session, and top-level sessions only orchestrate (`operator-rules.md` § "Top-level sessions only orchestrate"): you verify the task and dispatch `task-orchestrator`; you never run `git add`, `git commit`, `git push` or `gh pr create` yourself.

User input: `$ARGUMENTS` (optional — if present, must match the in-progress task id; if mismatch, refuse to proceed so the operator doesn't finalise the wrong worktree).

## Steps

### 1. Identify the task

Determine which task we are finalising:

1. Read `IN_PROGRESS.md`. The single task block there is the candidate.
2. If `$ARGUMENTS` is non-empty, confirm it matches the id of that block. If they disagree, **stop**: tell the operator the in-progress task id and ask whether they want to abort or to switch the in-progress entry first.
3. Run `git branch --show-current`. The branch should be `task/<id>-<slug>` matching the in-progress task. If not (e.g., still on `main`), **stop** and surface the mismatch — the operator likely forgot to switch worktrees, or `git wt switch` was not invoked.

### 2. Check the push gate (read-only)

Invoke the `atelier:safe-commit` skill in check-only fashion: run the lint + typecheck + unit + integration steps and read the structured `GREEN / RED / PARTIAL` report. Running the project's validation is not authoring; do not stage, commit or push.

- **RED** → stop and surface the failing step's output verbatim. Do not dispatch the orchestrator.
- **PARTIAL** (some steps N/A because no pnpm scripts are defined) → ask the operator to confirm proceeding anyway via the interactive selector (`AskUserQuestion`). Dispatch only on confirmation; otherwise stop.
- **GREEN** → continue.

### 3. Hand off to `task-orchestrator`

Dispatch the `task-orchestrator` agent via `Task` in **non-task PR coordination mode** (`agents/task-orchestrator.md` § "Non-task PR coordination mode"). The `task/*` head selects `pr-author` as the authoring primitive. Pass exactly these facts (never authority claims):

- `mode: non-task-pr`
- `repo` (owner/name), `worktree` (the absolute path of the current task worktree), `base`, `head: task/<id>-<slug>`
- `author_agent: pr-author`
- `title` / `body`: the roadmap entry title and a one-line summary; `pr-author` composes the real description from the plan and diff
- `tracking_move: true` — `pr-author` moves the task block `IN_PROGRESS.md` → `HISTORY.md` in the same PR (the `pr-flow` same-PR-tracking rule); the orchestrator itself moves nothing
- `interactive: true` unless the operator ran this under `--yes`/autonomous mode
- No `task_id` (that field would route the orchestrator into its standard task chain and re-run the implementer)

The orchestrator owns the rest: `pr-author` runs the push gate (`safe-commit`), commits, pushes to `origin task/<id>-<slug>` and opens the PR; then `reviewer` and the Auto-merge gate run as the orchestrator's own sub-agents. This command does not dispatch `pr-author`, `reviewer` or `auto-merge` itself.

Handle the orchestrator's terminal response:

- **`merged`** or **PR opened** — surface the PR URL and state.
- **`held: <reason>`** — surface the reason verbatim (the orchestrator's own gate run in `pr-author` may still hold, e.g. RED shows the failing step's output). Do not retry or work around it from this session.

### 4. Report back

End with:

> Render the labels below in the operator's chatLanguage — the English is illustrative structure, not literal output.

```text
✓ Task finalised: <id> — <title>
  Commit:  <short-sha>
  Branch:  origin task/<id>-<slug>
  PR:      <url>
  Tracking: IN_PROGRESS → HISTORY moved in this PR (#<predicted-or-actual-number>)
  Status:  <merged | held: reason>

  Next steps for the operator:
  - If held: resolve the reported reason (the PR is reviewed and merged by the orchestrator's chain, not by this session).
  - Run `git wt rm task/<id>-<slug>` post-merge to clean up the worktree.
```

(The post-merge worktree cleanup is the operator's call — `/finish-task` never deletes a worktree, because a still-open PR may need follow-up commits.)

## Hard refusals

- **Never** commit, push, or run `gh pr create` from this command's own turn. Everything that writes goes through `task-orchestrator` → `pr-author`.
- **Never** dispatch `pr-author`, `reviewer` or `auto-merge` directly — only `task-orchestrator` does.
- **Never** hand off a branch outside `task/*`. `pr-flow` enforces this too; `/finish-task` provides an early surface.
- **Never** `git wt rm` from this command. Worktree cleanup belongs **after** merge — and is a manual operator step (or `/cleanup-task` in a future phase, if needed).
- **Never** mark the PR auto-merge-ready. The auto-merge gate requires the `reviewer` agent's approval, which the orchestrator dispatches.
- **Never** add `Co-Authored-By: Claude` (or any agent attribution) to the commit message or PR body.

## Edge cases

- **The implementer or tester crashed mid-chain** and there is no clean change to ship → `/finish-task` should detect this from `git diff` being empty + the worktree being on a fresh branch. Surface it and suggest `/atelier:resume-task <id>` instead.
- **`IN_PROGRESS.md` is empty** → there is no task to finalise. Surface and stop; the operator should run `/atelier:next-task` first.
- **A previous run already pushed** but didn't open the PR (Ctrl+C between push and `gh pr create`) → detect this via `git status` showing the branch is ahead-of-remote = 0 commits, tell the orchestrator in the briefing that the branch is already pushed so `pr-author` skips to `gh pr create`. Surface the partial-recovery clearly so the operator knows what happened.
