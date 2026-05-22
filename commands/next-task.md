---
description: Pick the next task from `ROADMAP.md`, set up its worktree, and hand it to the `task-orchestrator` agent end-to-end.
argument-hint: "[task-id] [--yes|-y]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(git status:*), Bash(git branch:*), Bash(git wt:*), Bash(atelier-setup-project:*), Bash(env:*), Skill, Task
---

You are running the `/next-task` slash command. Drive the full pickup-to-PR flow for one task from the project's `ROADMAP.md`, exactly as [PLAN.md §7](PLAN.md) prescribes.

User input: `$ARGUMENTS` (optional — may carry a specific task id like `#42` to claim instead of auto-picking, and/or the `--yes` / `-y` flag described below). The two can appear in any order.

## Interaction mode (read once at the start)

Before doing anything that would otherwise pause for operator input, decide whether you are running in **non-interactive** mode. You are non-interactive if **any** of these is true:

- `$ARGUMENTS` contains the literal token `--yes` (surrounded by whitespace or string boundaries).
- `$ARGUMENTS` contains the literal token `-y` (surrounded by whitespace or string boundaries — not embedded in another flag).
- The environment variable `ATELIER_AUTO` is set to any non-empty value. Probe with `env | grep -E '^ATELIER_AUTO='`.

If none of those is true, you are **interactive**.

**Rule for every "ask the operator" step below:** in interactive mode, ask as written. In non-interactive mode, **never** use `AskUserQuestion` or any other prompt — auto-resolve per the per-step rule documented inline (typically: proceed with the safe default, or stop with a clear error if no safe default exists). Prefer **stop with error** over a silent guess when in doubt — a clear refusal is recoverable, a wrong assumption may corrupt the chain.

## Steps

### 1. Sanity-check the worktree

Run `git status --short` and `git branch --show-current`.

- **Working tree clean and branch is `main` / `master` / a base branch** → proceed to step 2.
- **Working tree dirty or non-base branch, interactive mode** → surface the state and ask the operator whether to stash, continue on the current branch, or abort. Picking a new task on top of unrelated uncommitted work corrupts the chain.
- **Working tree dirty or non-base branch, non-interactive mode** → **stop with error**:
  ```text
  ✗ /next-task: working tree is dirty or current branch is not a base branch.
     status: <one-line summary>
     branch: <name>
     In non-interactive mode, the command refuses rather than guess.
     Resolve manually (commit, stash, or `git checkout main`) and re-run.
  ```
  Do NOT auto-stash or auto-checkout — that hides operator-in-progress work.

### 2. Refuse to start if `IN_PROGRESS.md` is occupied

Read `IN_PROGRESS.md`. If it contains anything other than the placeholder HTML comments, a task is already in progress. **Do not silently override it** — this applies in both interactive and non-interactive mode; an occupied `IN_PROGRESS.md` is never overridden by `/next-task`.

- **Interactive mode:** report the existing entry and offer two options:
  - Resume the in-progress task with `/atelier:resume-task <id>`.
  - Explicitly close out the existing task first (move to `HISTORY.md` or back to `ROADMAP.md`) before picking a new one.
- **Non-interactive mode:** stop with a clear error pointing at the same two options. The operator must rerun manually after resolving.

### 3. Pick the task — `task-discovery` skill

Strip the `--yes` / `-y` flag from `$ARGUMENTS` before parsing the task id (so `#42 --yes` still resolves to id `#42`).

If the remaining `$ARGUMENTS` is empty: invoke the `atelier:task-discovery` skill on the project's `ROADMAP.md`. It returns the structured record (`id`, `title`, `type`, `priority`, `estimate`, `blocked_by`, `worktree`, `acceptance`, `context`) per PLAN.md §5.

If `$ARGUMENTS` names a specific id: find that block in `ROADMAP.md` directly, parse it into the same shape, and **validate** it is unchecked and has no open `blocked_by` — surface the violation and stop if either fails.

### 4. Confirm with the operator

Display the chosen task in a short summary (`id`, `title`, `priority`, `estimate`).

- **Interactive mode:** ask explicitly: *"Claim this task?"*. Wait for a yes/no. If no, stop — do not move tracking or create a worktree.
- **Non-interactive mode:** log a single line `auto-claiming task <id> (non-interactive)` and proceed to step 5. No prompt. The operator's `--yes` / `-y` flag (or `ATELIER_AUTO=1`) **is** the consent.

### 5. Move `ROADMAP.md` → `IN_PROGRESS.md` in a single edit

Remove the task block from `ROADMAP.md`. Paste it into `IN_PROGRESS.md` between the marker comments. The roadmap-tracking-flow convention says the same PR that closes the task moves it from `IN_PROGRESS.md` to `HISTORY.md`, so this edit lives on the per-task branch you are about to create.

### 6. Create the per-task worktree — `git-wt` skill

Invoke the external `git-wt` skill (or `git wt switch <branch>` directly) to create the worktree at `task/<id-without-#>-<kebab-slug>` cut from updated `main` (or `dev` if it exists; the skill resolves the base policy). Capture the **absolute path** the skill prints on stdout — every subsequent step runs scoped to that path.

### 7. Instantiate the per-task `.claude/settings.json`

Invoke the `atelier-setup-project` helper in per-task mode. The helper performs all five guards (template existence, sed substitution, JSON validity, no leftover `<worktree>` / `<atelier-config-dir>` placeholders, substitution landed in the canonical first slot of `additionalDirectories`) inside a subprocess **outside the harness's permission scope** — which is how this step completes in non-interactive `claude -p` mode despite the harness's `.claude/**` sensitive-directory guard.

Run **as a single Bash command**:

```bash
atelier-setup-project --per-task-settings <absolute-worktree-path>
```

Where `<absolute-worktree-path>` is the path captured in step 6, NOT the main repo path.

Exit codes:
- `0` → success. Helper prints `OK: per-task settings created: <path>/.claude/settings.json`.
- non-zero → one of the five guards failed. **Stop and report** the helper's stderr verbatim. Do NOT advance to step 8.

**Hard refusals:**
- **Never** substitute `<worktree>` with the main-repo path. The whole point of per-task settings is to scope `Edit` / `Write` to the task's worktree.
- **Never** bypass the helper with an inline `mkdir + sed + > .claude/settings.json` chain. The harness denies `.claude/**` writes — that is exactly what motivated this helper (see HISTORY → M4.11, M4.16).
- **Never** advance to step 8 if the helper exits non-zero. Stop and report verbatim. Do not retry with `--dangerously-skip-permissions` to force a pass; that loses every other safety guarantee in the template.

### 8. Hand off to `task-orchestrator`

Launch the `atelier:task-orchestrator` agent (Opus) via the `Task` tool. The briefing must include:

- **`worktree_path`** — absolute path to the per-task worktree from step 6.
- **task record** — structured fields from step 3 (`id`, `title`, `type`, `priority`, `estimate`, `worktree`, `acceptance`, `context`).
- **interaction mode** — when non-interactive, pass `interactive: false` (or equivalent prose) so the orchestrator's Step 1 standard-mode branch skips its own confirmation prompt (Step 1 also reads `ATELIER_AUTO` as a fallback, but the briefing is the authoritative signal when set).
- **cwd reminder** — the explicit one-liner: *"Your `Bash` cwd is the cwd this `/next-task` invocation inherited, NOT `<worktree_path>`. Every `Bash` call targeting the worktree must use `git -C <worktree_path>`, `pnpm --dir <worktree_path>`, `gh --repo <owner/name>`, or `cd <worktree_path> && ...` prefix. Read/Edit/Write on absolute paths are fine. See `operator-rules.md` § Operating against the task worktree."* The orchestrator's own system prompt repeats this rule (defense in depth), but the briefing is the authoritative carrier — if `SessionStart` did not fire for the subagent dispatch, the briefing is the only place the rule reaches the orchestrator.

From this point the chain (`implementer` → `tester` → `pr-author`) is the orchestrator's responsibility — `/next-task`'s job ends here.

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
- **Never** edit `settings.template.json` itself from this command — that file is the template, not the output. The helper writes the instantiated copy to `<worktree>/.claude/settings.json`; this command never touches either file directly.
- **Never** push or open a PR from this command — that is `pr-author`'s job at the end of the chain.
