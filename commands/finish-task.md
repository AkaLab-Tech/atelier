---
description: Finalise the current in-progress task — run the push gate, commit, push to `task/<id>-<slug>`, open the PR with the standard description, and move `IN_PROGRESS.md` → `HISTORY.md` in the same PR.
argument-hint: "[task-id]"
allowed-tools: Read, Edit, Glob, Grep, Bash(git status:*), Bash(git branch:*), Bash(git diff:*), Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(gh pr create:*), Bash(gh pr view:*), Bash(pnpm run:*), Bash(pnpm audit:*), Skill
---

You are running the `/finish-task` slash command. Take a task that the implementer + tester have finished and ship it as an open PR.

User input: `$ARGUMENTS` (optional — if present, must match the in-progress task id; if mismatch, refuse to proceed so the operator doesn't finalise the wrong worktree).

## Steps

### 1. Identify the task

Determine which task we are finalising:

1. Read `IN_PROGRESS.md`. The single task block there is the candidate.
2. If `$ARGUMENTS` is non-empty, confirm it matches the id of that block. If they disagree, **stop**: tell the operator the in-progress task id and ask whether they want to abort or to switch the in-progress entry first.
3. Run `git branch --show-current`. The branch should be `task/<id>-<slug>` matching the in-progress task. If not (e.g., still on `main`), **stop** and surface the mismatch — the operator likely forgot to switch worktrees, or `git wt switch` was not invoked.

### 2. Run the push gate — `safe-commit` skill

Invoke the `atelier:safe-commit` skill against the current worktree. It runs lint + typecheck + unit + integration in order and returns the structured `GREEN / RED / PARTIAL` report.

- **RED** → stop and surface the failing step's output verbatim. Do not commit anything. The operator decides whether to fix-forward or hand back to `tester`.
- **PARTIAL** (some steps N/A because no pnpm scripts are defined) → ask the operator to confirm proceeding anyway. Most atelier-managed projects should have at least one of the three scripts; a fully-N/A result is a strong signal that the project setup is incomplete.
- **GREEN** → continue.

### 3. Open the PR — `pr-flow` skill

Invoke the `atelier:pr-flow` skill. It performs:

1. Stage explicit paths (never `-A`).
2. Compose the Conventional Commits message via HEREDOC, citing the roadmap entry and the acceptance criteria.
3. Push to `origin task/<id>-<slug>` (refuses any other branch).
4. Move the task block from `IN_PROGRESS.md` to `HISTORY.md` in the same PR — this skill handles the same-PR-tracking-rule for you.
5. Open the PR via `gh pr create` with the standard description (Summary / Test plan / Tracking).

Capture the PR URL from the skill's output.

### 4. Report back

End with:

```text
✓ Task finalised: <id> — <title>
  Commit:  <short-sha>
  Branch:  origin task/<id>-<slug>
  PR:      <url>
  Tracking: IN_PROGRESS → HISTORY moved in this PR (#<predicted-or-actual-number>)

  Next steps for the operator:
  - Review the PR.
  - Merge (squash) when ready.
  - Run `git wt rm task/<id>-<slug>` post-merge to clean up the worktree.
```

(The post-merge worktree cleanup is the operator's call — `/finish-task` never deletes a worktree, because a still-open PR may need follow-up commits.)

## Hard refusals

- **Never** push if `safe-commit` returns `RED`. The operator must fix the gate first.
- **Never** open a PR for a branch outside `task/*`. The `pr-flow` skill enforces this too; `/finish-task` provides an early surface.
- **Never** `git wt rm` from this command. Worktree cleanup belongs **after** merge — and is a manual operator step (or `/cleanup-task` in a future phase, if needed).
- **Never** mark the PR auto-merge-ready. The auto-merge gate requires the `reviewer` agent (M3.2); until then, every PR is human-mergeable only.
- **Never** add `Co-Authored-By: Claude` (or any agent attribution) to the commit message or PR body.

## Edge cases

- **The implementer or tester crashed mid-chain** and there is no clean change to ship → `/finish-task` should detect this from `git diff` being empty + the worktree being on a fresh branch. Surface it and suggest `/resume-task <id>` (M4.3) instead.
- **`IN_PROGRESS.md` is empty** → there is no task to finalise. Surface and stop; the operator should run `/next-task` first.
- **A previous run already pushed** but didn't open the PR (Ctrl+C between push and `gh pr create`) → detect this via `git status` showing the branch is ahead-of-remote = 0 commits, then **skip steps 1-2 of pr-flow** and call only `gh pr create`. Surface the partial-recovery clearly so the operator knows what happened.
