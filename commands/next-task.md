---
description: Pick the next task from `ROADMAP.md`, set up its worktree, and hand it to the `task-orchestrator` agent end-to-end.
argument-hint: "[task-id] [--yes|-y]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(git fetch:*), Bash(git ls-remote:*), Bash(git show:*), Bash(git wt:*), Bash(gh pr list:*), Bash(atelier-setup-project:*), Bash(atelier-resolve-dep:*), Bash(atelier-task-backend:*), Bash(env:*), Skill, Task
---

You are running the `/next-task` slash command. Drive the full pickup-to-PR flow for one task from the project's `ROADMAP.md`, exactly as [PLAN.md §7](PLAN.md) prescribes.

User input: `$ARGUMENTS` (optional — may carry a specific task id like `#42` to claim instead of auto-picking, and/or the `--yes` / `-y` flag described below). The two can appear in any order.

## Interaction mode (read once at the start)

Before doing anything that would otherwise pause for operator input, decide whether you are running in **non-interactive** mode. You are non-interactive if **any** of these is true:

- `$ARGUMENTS` contains the literal token `--yes` (surrounded by whitespace or string boundaries).
- `$ARGUMENTS` contains the literal token `-y` (surrounded by whitespace or string boundaries — not embedded in another flag).
- The environment variable `ATELIER_AUTO` is set to any non-empty value. Probe with `env | grep -E '^ATELIER_AUTO='`.

If none of those is true, you are **interactive**.

> **Headless / autonomous runs (M7.1.F69).** A slash command is model prose, not a process, so it cannot probe `[ -t 0 ]` to detect a non-TTY the way the shell helpers do. A headless `claude -p "/atelier:next-task"` therefore looks **interactive** unless you tell it otherwise: any autonomous invocation **must** set `ATELIER_AUTO=1` (or pass `--yes`), or this command will stop at the first decision point waiting for input that never comes.

**Rule for every "ask the operator" step below:** in interactive mode, ask as written. In non-interactive mode, **never** use `AskUserQuestion` or any other prompt — auto-resolve per the per-step rule documented inline (typically: proceed with the safe default, or stop with a clear error if no safe default exists). Prefer **stop with error** over a silent guess when in doubt — a clear refusal is recoverable, a wrong assumption may corrupt the chain.

## Steps

### 1. Resolve the base branch and fetch

The task runs in an **isolated worktree cut from the remote base branch**, so the operator's current branch and any uncommitted work are irrelevant. **Never** inspect, stash, switch, or commit to the operator's checkout, and never refuse on account of its state — it is left completely untouched.

- Resolve the **base branch**: `dev` if `origin/dev` exists, else `main` (the same policy the `git-wt` skill uses). Probe with `git ls-remote --heads origin dev`.
- `git fetch origin <base>` so everything downstream reads the freshest **merged** backlog — a recently-merged PR may have added or reprioritised tasks. Every later step reads `origin/<base>`, never the local working copy.

(If the operator is mid-work on a feature branch with uncommitted changes, that is fine and expected — say nothing about it.)

### 2. Read the backlog and check concurrency — the task provider

The **backlog source** and the **claim registry** are an abstraction (the *task provider*), so a non-files backend (Linear, GitHub Projects — M9) can replace the file-/git-backed backlog below without touching any of the git/worktree mechanics in steps 3–8.

**Resolve the backlog backend first (M9.1):**

```bash
atelier-task-backend <project-root>   # → files | linear | github-project (absent .roadmap.json ⇒ files)
```

- `files` (the default) → the git-backed backlog below.
- non-`files` → discover the backlog and drive the `ROADMAP → IN_PROGRESS → HISTORY` transitions through `claude-roadmap-tools`' `RoadmapBackend` for that backend (`listTasks` / `getTask` / `moveTask` / `appendHistoryEntry`; see `docs/RoadmapBackend.md`) instead of reading `origin/<base>:ROADMAP.md`. The **claim registry stays the open `task/*` PRs** regardless of backend (§16.4). The Linear backend is the first to validate this path; GitHub Projects lands in M9.2.

**Files backend — the git-backed provider (unchanged):**

- **Backlog** = `ROADMAP.md` as it exists on `origin/<base>`: read it with `git show origin/<base>:ROADMAP.md`. The local working copy is **not** the source of truth — a task the operator edited locally but has not merged is **not** eligible until it lands on `origin/<base>`.
- **Claim registry** = the set of **open `task/*` PRs** on origin. Each open `task/<id>-<slug>` PR is one in-flight task. List them with `gh pr list --state open --json number,headRefName` and keep the `headRefName`s that start with `task/`; the `<id>` segment is the claimed task id.

**Concurrency:** atelier allows up to **N** concurrent tasks per repo — `.atelier.json` → `taskConcurrency.max` (default `1`). Worktrees isolate the work, so N tasks run in parallel safely **as long as they do not collide** (step 3 handles collision-avoidance). If the count of open `task/*` PRs is already ≥ N:

- **Interactive:** list the in-flight `task/*` PRs and stop — offer `/atelier:resume-task <id>` or raising `taskConcurrency.max`.
- **Non-interactive:** stop with a clear error listing the open `task/*` PRs.

This replaces the old single-slot `IN_PROGRESS.md` guard: while a task is in flight its claim lives only on its own branch (step 6), so the base branch's `IN_PROGRESS.md` stays empty and is **not** the concurrency signal — the open `task/*` PRs are.

### 3. Pick the task — `task-discovery` skill

Strip the `--yes` / `-y` flag from `$ARGUMENTS` before parsing the task id (so `#42 --yes` still resolves to id `#42`).

Build the **claimed-id set** from step 2 (the open `task/*` PRs). **Never** pick or re-claim an id already in that set, whether auto-picked or explicitly named.

**`files` backend:** if the remaining `$ARGUMENTS` is empty, invoke the `atelier:task-discovery` skill on the **`origin/<base>` ROADMAP content** read in step 2 (not the local file), excluding the claimed-id set. It returns the structured record (`id`, `title`, `type`, `priority`, `estimate`, `blocked_by`, `scope`, `worktree`, `acceptance`, `context`) per PLAN.md §5.

**Non-`files` backend:** if the remaining `$ARGUMENTS` is empty, the backlog is obtained via `listTasks("roadmap")` per `docs/RoadmapBackend.md` (see `roadmap-tracking-flow` skill). Pass the returned task list to `atelier:task-discovery` — the same selection rules (P0→P1→P2 priority order, `blocked_by`, `[ready]`, `[OVERSIZE]`/`[BLOCKED]` filters; see `skills/task-discovery/SKILL.md` §§ "Selection algorithm" and "Backend-aware backlog source") apply to the list. After the selection algorithm picks an `id`, call `getTask(id)` to retrieve the full task record (`title`, `body`, `priority`, metadata) and merge it into the structured result.

**Collision-avoidance (within-repo parallelism):** when other tasks are already in flight, prefer a candidate whose declared `scope:` / paths do **not** overlap theirs — overlapping work would only collide at merge time. Tasks in *different* workspace members never collide. If no `scope:` is declared, proceed optimistically: a residual conflict is caught by the auto-merge gate (the first PR merges; the others rebase + re-validate; a real conflict falls back to a human).

If `$ARGUMENTS` names a specific id:

- **`files` backend:** find that block in the `origin/<base>` ROADMAP directly, parse it into the same shape, and **validate** it is unchecked, not already in the claimed-id set, carries the `[ready]` marker (with a committed `.plan/<id>.md`), and has no open `blocked_by` — surface the violation and stop if any fails.
- **Non-`files` backend:** call `getTask(id)` to retrieve the task, then apply the same validations (not in claimed-id set, `[ready]`, no open `blocked_by`).

The **`[ready]` validation** is absolute: a named-but-unplanned task is refused exactly like an auto-picked one. If the task lacks `[ready]` (or `.plan/<id>.md` is missing), **stop and refuse** in both interactive and non-interactive mode — never improvise a plan, never offer to plan it inline:

```text
✗ /next-task: task #<id> is not planned — run `/atelier:plan-task #<id>` first.
   A task is only claimable once a product lead has approved a plan and it carries [ready].
```

The `blocked_by` validation covers both forms:

- **Intra-repo** (`#NN`): the referenced id must be `[x]` in the `origin/<base>` ROADMAP.
- **Cross-repo** (`<token>#NN`): resolve it offline with the helper, where `<project-root>` is the directory containing this `ROADMAP.md`:
  ```bash
  atelier-resolve-dep --from <project-root> --token <token> --id <#NN>
  ```
  Exit `0` → satisfied, continue. Any non-zero exit → **stop and refuse** with a precise message, e.g.:
  ```text
  ✗ /next-task: task #42 is blocked by backend#23, which is not yet merged.
     workspace: <slug>   blocker: backend#23 — <open|unknown-token|unknown-id>
     resolve:   merge backend#23 (run `task` in the backend member), then re-run.
  ```
  Use the verdict word from the helper's stdout to fill the message. Do **not** claim the task.

### 4. Confirm with the operator

Display the chosen task in a short summary (`id`, `title`, `priority`, `estimate`).

- **Interactive mode:** ask explicitly: *"Claim this task?"*. Wait for a yes/no. If no, stop — do not move tracking or create a worktree.
- **Non-interactive mode:** log a single line `auto-claiming task <id> (non-interactive)` and proceed to step 5. No prompt. The operator's `--yes` / `-y` flag (or `ATELIER_AUTO=1`) **is** the consent.

### 5. Create the per-task worktree — `git-wt` skill

Invoke the `git-wt` skill (or `git wt switch <branch> --from origin/<base>` directly) to create the worktree for branch `task/<id-without-#>-<kebab-slug>` **cut from `origin/<base>`** — the ref fetched in step 1. The operator's local branches are left untouched. Capture the **absolute path** the skill prints on stdout — every subsequent step runs scoped to that path.

### 6. Claim the task — tracking move

Now that the worktree exists, record the claim **before** handing off to the orchestrator. The mechanics differ by backend:

**`files` backend** — make the tracking move **in the worktree, on the task branch** — **never** in the operator's main checkout:

- Remove the task block from `<worktree>/ROADMAP.md`.
- Paste it into `<worktree>/IN_PROGRESS.md` between the marker comments.

This edit lives on the per-task branch and travels through the task's PR; the roadmap-tracking-flow convention says the same PR later moves it from `IN_PROGRESS.md` to `HISTORY.md` when the task closes.

**Non-`files` backend** — drive the claim through the `RoadmapBackend` contract (see `docs/RoadmapBackend.md`) instead of editing local files:

- Call `moveTask(id, "roadmap", "in_progress")` via the `roadmap-tracking-flow` skill. This is atomic: the task moves out of the backend's roadmap bucket and into its in-progress bucket in a single operation — no local `ROADMAP.md` / `IN_PROGRESS.md` edits are made.
- If `moveTask` throws `task-not-in-from-bucket`, the task was already claimed by a concurrent actor — stop and report a race condition; do not proceed.

**For both backends** — the claim lives only on the task branch (files) or in the remote backend (non-files), so `origin/<base>`'s `ROADMAP.md` / `IN_PROGRESS.MD` are unchanged until the PR merges — which is exactly why step 2 uses the open `task/*` PRs (not the base `IN_PROGRESS.md`) as the claim registry.

> **Forward reference — closing the task (pr-author).** When the PR is ready to close, `pr-author` must update tracking in the same PR. For the `files` backend that means the `IN_PROGRESS.md` → `HISTORY.md` move already documented in `skills/pr-flow/SKILL.md` §4. For a non-`files` backend, `pr-author` calls `appendHistoryEntry(id, prMetadata)` (per `docs/RoadmapBackend.md`) instead of editing local files directly — `prMetadata` carries `{ number, url, title, deliveredBullets[], testsNote, followUps? }` from the PR that is about to merge.

### 7. Instantiate the per-task `.claude/settings.json`

Invoke the `atelier-setup-project` helper in per-task mode. The helper performs all five guards (template existence, sed substitution, JSON validity, no leftover `<worktree>` / `<atelier-config-dir>` placeholders, substitution landed in the canonical first slot of `additionalDirectories`) inside a subprocess **outside the harness's permission scope** — which is how this step completes in non-interactive `claude -p` mode despite the harness's `.claude/**` sensitive-directory guard.

Run **as a single Bash command**:

```bash
atelier-setup-project --per-task-settings <absolute-worktree-path>
```

Where `<absolute-worktree-path>` is the path captured in step 5, NOT the main repo path.

Exit codes:
- `0` → success. Helper prints `OK: per-task settings created: <path>/.claude/settings.json`.
- non-zero → one of the five guards failed. **Stop and report** the helper's stderr verbatim. Do NOT advance to step 8.

**Hard refusals:**
- **Never** substitute `<worktree>` with the main-repo path. The whole point of per-task settings is to scope `Edit` / `Write` to the task's worktree.
- **Never** bypass the helper with an inline `mkdir + sed + > .claude/settings.json` chain. The harness denies `.claude/**` writes — that is exactly what motivated this helper (see HISTORY.md).
- **Never** advance to step 8 if the helper exits non-zero. Stop and report verbatim. Do not retry with `--dangerously-skip-permissions` to force a pass; that loses every other safety guarantee in the template.

### 8. Hand off to `task-orchestrator`

Launch the `atelier:task-orchestrator` agent (Opus) via the `Task` tool. The briefing must include:

- **`worktree_path`** — absolute path to the per-task worktree from step 5.
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

- **Never** claim a task that is not `[ready]` with a committed `.plan/<id>.md` — auto-picked or explicitly named. Refuse with a pointer to `/atelier:plan-task <id>`; never improvise or approve a plan from this command.
- **Never** exceed `taskConcurrency.max` open `task/*` PRs, and **never** re-claim an id that already has an open `task/*` PR — see step 2.
- **Never** inspect, stash, switch, or commit to the operator's main checkout — the task runs entirely in its own worktree cut from `origin/<base>`; the operator's local branches and uncommitted work stay untouched.
- **Never** read the local working-copy `ROADMAP.md` as the backlog source — the eligible backlog is `origin/<base>:ROADMAP.md` (merged), so locally-edited, unmerged tasks are not claimable until they land.
- **Never** claim a task whose `blocked_by:` references an open item — including a cross-repo `<token>#id` whose target is not closed in that member's `HISTORY.md` (`atelier-resolve-dep` exits non-zero), or whose token/project is not a resolvable workspace member.
- **Never** edit `settings.template.json` itself from this command — that file is the template, not the output. The helper writes the instantiated copy to `<worktree>/.claude/settings.json`; this command never touches either file directly.
- **Never** push or open a PR from this command — that is `pr-author`'s job at the end of the chain.
