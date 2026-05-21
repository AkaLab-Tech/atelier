---
description: Pick the next task from `ROADMAP.md`, set up its worktree, and hand it to the `task-orchestrator` agent end-to-end.
argument-hint: "[task-id] [--yes|-y]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(git status:*), Bash(git branch:*), Bash(git wt:*), Bash(sed:*), Bash(mkdir:*), Bash(jq:*), Bash(test:*), Bash(env:*), Skill, Task
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

Read the **instantiated** settings template from `$CLAUDE_CONFIG_DIR/templates/settings.template.json`. This is atelier's per-install copy — `install.sh` already substituted any install-time placeholders (the `<atelier-config-dir>` location of atelier's config root, per M5.0.2). The only remaining placeholder is `<worktree>`, which must be substituted with the **absolute path of the per-task worktree** (from step 6), NOT the main repo path.

> Note on the path: `$CLAUDE_CONFIG_DIR` is the env var Claude Code reads to know where its install lives, so it's the canonical source for atelier's config root **from inside a session loaded from it**. Equivalent to `$ATELIER_CONFIG_DIR` (set by the shellrc hook) when `task()` launched the session.

**Critical implementation detail:** the Claude Code harness has a built-in guard that requires explicit operator approval for the `Write` and `Edit` tools when the target path is under `.claude/**`. That guard hangs the chain in non-interactive (`-p`) mode. The atelier convention is therefore to write `.claude/settings.json` **via Bash shell redirection** (`sed > file`), never via the `Write` / `Edit` tools — the redirect is a `Bash` tool operation, which the per-path matchers handle via the standard allow / deny matrix and which is not subject to the harness's `.claude/**` interactive guard. The path `<worktree>-worktrees/**` is in `additionalDirectories`, so the `Bash` redirect to `<task-worktree>/.claude/settings.json` is permitted.

Run **as a single Bash command** (this command's frontmatter allows the four pieces — `mkdir`, `sed`, `jq`, `test`):

```bash
mkdir -p <absolute-worktree-path>/.claude && \
  sed 's|<worktree>|<absolute-worktree-path>|g' \
    "$CLAUDE_CONFIG_DIR/templates/settings.template.json" \
  > <absolute-worktree-path>/.claude/settings.json && \
  jq empty <absolute-worktree-path>/.claude/settings.json && \
  test "$(jq -r '.permissions.additionalDirectories[0]' <absolute-worktree-path>/.claude/settings.json)" = "<absolute-worktree-path>"
```

The five guards in order: directory exists; sed succeeded; output parses as JSON; `<worktree>` placeholder was actually substituted (no literal `<worktree>` left); and the substitution landed in the canonical first slot of `additionalDirectories`. Any of them failing → **stop and report** with the exact failure (do NOT advance to step 8 with a missing / corrupt / unmodified settings file — silently skipping this leaves the task in a half-configured state that only surfaces when the operator later opens a session inside the task worktree).

**Hard refusals:**
- **Never** use the `Write` tool to create `<task-worktree>/.claude/settings.json`. The harness blocks it in non-interactive mode. Always Bash + redirect.
- **Never** substitute `<worktree>` with the main-repo path. The whole point of per-task settings is to scope `Edit` / `Write` to the task's worktree.
- **Never** skip the substitution-verification guard (the last two checks above). A file that exists but still contains the literal `<worktree>` placeholder would silently widen the `additionalDirectories` to `<worktree>/**` (matching nothing useful) and the operator would not notice until much later.
- **Never** read the template directly from `$CLAUDE_PLUGIN_ROOT/templates/settings.template.json`. That is the source-with-placeholders copy shipped with the plugin. The instantiated copy under `$CLAUDE_CONFIG_DIR/templates/` is the only one with install-time placeholders resolved.

### 8. Hand off to `task-orchestrator`

Launch the `atelier:task-orchestrator` agent (Opus) with the worktree path and the structured task record from step 3 as its briefing. **Include the interaction mode in the briefing** — when non-interactive, pass `interactive: false` (or equivalent prose) so the orchestrator's Step 1 standard-mode branch skips its own confirmation prompt (Step 1 also reads `ATELIER_AUTO` as a fallback, but the briefing is the authoritative signal when set). From this point the chain (`implementer` → `tester` → `pr-author`) is the orchestrator's responsibility — `/next-task`'s job ends here.

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
- **Never** edit `settings.template.json` itself from this command — that template is the source of truth shipped with the plugin; only the **instantiated** `<worktree>/.claude/settings.json` is written here.
- **Never** push or open a PR from this command — that is `pr-author`'s job at the end of the chain.
