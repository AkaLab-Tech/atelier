# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M4.20 — `task-orchestrator` subagent inherits parent `cwd`, not worktree

**Blocking autonomous chain post-step-7.** Surfaced during the M4.16 ([PR #57](https://github.com/AkaLab-Tech/atelier/pull/57)) end-to-end validation run on 2026-05-22 — the chain executed `/atelier:next-task` steps 1-7 cleanly under `claude -p`, including the M4.16 helper writing `<worktree>/.claude/settings.json` correctly. Step 8 (handoff to `task-orchestrator`) blocked: the subagent dispatched by the `Task` tool inherits `cwd=<repo principal>` from the parent invocation rather than switching to `cwd=<worktree>`. The harness's subprocess sandbox enforces `cwd`, not `additionalDirectories` from settings.json — so `Bash`-driven `git`, `pnpm`, `gh` calls against the worktree path fail even though the worktree is in `additionalDirectories`. `Read` / `Edit` / `Write` to absolute worktree paths still work (those go through the harness's permission layer, which respects `additionalDirectories`), but the chain can't actually exercise the worktree.

Workaround until fixed: operator opens a new Claude Code session with `cwd=<worktree>` and runs `/atelier:resume-task <id>`. The `IN_PROGRESS.md` entry created at step 5 survives across sessions and `resume-task` is designed exactly for this re-entry path.

**Scope:**

1. Identify the dispatch point in `commands/next-task.md` step 8 (and possibly `agents/task-orchestrator.md`'s briefing) that hands off to the orchestrator.
2. Pass the worktree path to the orchestrator in a way the harness honors when launching the subprocess — likely via a `Task` tool invocation that explicitly sets the working directory, or by instructing the orchestrator to `cd <worktree>` as its very first action before any `Bash` (Read/Edit/Write are already fine).
3. Update `agents/task-orchestrator.md` to make the cwd switch the first explicit step of the agent's flow, with a hard refusal to invoke any `Bash` tool before that switch completes.
4. End-to-end re-validate with the same fixture as M4.16's chain run (`/tmp/atelier-m4.16-fullchain/` template, `cd /Users/mike/Work/atelier-dogfood-4`, `claude --plugin-dir <wt> -p "/atelier:next-task #1 --yes"`). Acceptance is the chain advancing past step 8 — implementer reaching the worktree, writing `src/greet.ts` + test, tester running vitest cleanly.

**Acceptance:**

- `/atelier:next-task #1 --yes` against a real project under `claude -p` reaches `pr-author` (PR creation) without operator intervention.
- No regression for interactive operators (the cwd switch is harmless when invoked from a session already inside the worktree — `resume-task` already does this implicitly).

**Trigger to revisit:** before any retry of dogfood-4 or any other autonomous chain validation. Without this, M4.16 unblocks step 7 but the chain still dies at step 8 in `-p` mode. Captured 2026-05-22 during M4.16 PR #57 chain run.

**Progress notes:** worktree `task/m4.20-task-orchestrator-cwd` created 2026-05-22 from `b7db7be` (post-#59 merge).
