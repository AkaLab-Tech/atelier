---
description: Pick the next task from `ROADMAP.md`, set up its worktree, and hand it to the `task-orchestrator` agent end-to-end.
argument-hint: "[task-id] [--yes|-y]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(git fetch:*), Bash(git ls-remote:*), Bash(git show:*), Bash(git cat-file:*), Bash(git rev-parse:*), Bash(git wt:*), Bash(gh pr list:*), Bash(atelier-setup-project:*), Bash(atelier-resolve-dep:*), Bash(atelier-task-backend:*), Bash(jq:*), Bash(env:*), Bash(test:*), Skill, Task
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
- **Capture the operator main-checkout root and the plan-storage mode (TASK_027).** This command runs in the operator's main checkout, which is where a `planStorage=local` plan physically lives — the task worktree (cut from `origin/<base>`) will **not** contain it, because `git worktree add` does a clean checkout of the tree and never copies gitignored/untracked files. Capture both now:
  ```bash
  MAIN_ROOT="$(git rev-parse --show-toplevel)"
  PLAN_STORAGE="$(jq -r '.planStorage // "committed"' "$MAIN_ROOT/.atelier.json" 2>/dev/null || echo committed)"
  ```
  `MAIN_ROOT` is the **plan source root** for `planStorage=local` — the worktree created in step 5 is *not*. `PLAN_STORAGE` is `committed` (default) or `local`; it governs the planning gate's `.plan` check (step 3) and the briefing (step 8).

(If the operator is mid-work on a feature branch with uncommitted changes, that is fine and expected — say nothing about it.)

### 2. Read the backlog and check concurrency — the task provider

The **backlog source** and the **claim registry** are an abstraction (the *task provider*), so a non-files backend (Linear, GitHub Projects — M9) can replace the file-/git-backed backlog below without touching any of the git/worktree mechanics in steps 3–8.

**Resolve the backlog backend first (M9.1):**

```bash
atelier-task-backend <project-root>   # → files | linear | github-project (absent .roadmap.json ⇒ files)
```

- `files` (the default) → the git-backed backlog below.
- non-`files` → discover the backlog and drive the `ROADMAP → IN_PROGRESS → HISTORY` transitions through `claude-roadmap-tools`' `RoadmapBackend` for that backend (`listTasks` / `getTask` / `moveTask` / `appendHistoryEntry`; see `docs/RoadmapBackend.md`) instead of reading `origin/<base>:ROADMAP.md`. The **claim registry stays the open `task/*` PRs** regardless of backend (§16.4) — for the `github-project` backend the Project's "In Progress" column is **not** the concurrency signal; only the open `task/*` PRs are. Both `LinearBackend` (M9.1) and `GitHubProjectBackend` (M9.2, now live) exercise this path. For `github-project` specifically: `listTasks("roadmap")` returns items whose **Status** field value is in the set mapped to the `roadmap` bucket via `githubProject.stateMap` (defaults `["Backlog","Todo"]`); the planning-gate filter reads the item's **Ready** custom field (a boolean/single-select Project field — not a `[ready]` text token in a markdown line) to determine eligibility. See step 3 for the `Ready`-field validation and §16.5 (owned by #20c) for how `Ready` is set.

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

**Non-`files` backend:** if the remaining `$ARGUMENTS` is empty, the backlog is obtained via `listTasks("roadmap")` per `docs/RoadmapBackend.md` (see `roadmap-tracking-flow` skill). Pass the returned task list to `atelier:task-discovery` — the same selection rules (P0→P1→P2 priority order, `blocked_by`, planning gate, `[OVERSIZE]`/`[BLOCKED]` filters; see `skills/task-discovery/SKILL.md` §§ "Selection algorithm" and "Backend-aware backlog source") apply to the list. For the planning gate, the `[ready]` check is replaced by the backend's **Ready** field carried in each task record returned by `listTasks` (both `listTasks` and `getTask` fulfil their contract via the project-detail operation, which fetches each item with all its field values — so `Ready` rides along in the returned record, no dedicated extra read is needed). After the selection algorithm picks an `id`, call `getTask(id)` to retrieve the full task record (`title`, `body`, `priority`, `Ready` field value, metadata) and merge it into the structured result.

**Collision-avoidance (within-repo parallelism):** when other tasks are already in flight, prefer a candidate whose declared `scope:` / paths do **not** overlap theirs — overlapping work would only collide at merge time. Tasks in *different* workspace members never collide. If no `scope:` is declared, proceed optimistically: a residual conflict is caught by the auto-merge gate (the first PR merges; the others rebase + re-validate; a real conflict falls back to a human).

If `$ARGUMENTS` names a specific id:

- **`files` backend:** find that block in the `origin/<base>` ROADMAP directly, parse it into the same shape, and **validate** it is unchecked, not already in the claimed-id set, carries the `[ready]` marker (with a committed `.plan/<id>.md`), and has no open `blocked_by` — surface the violation and stop if any fails.
- **Non-`files` backend:** call `getTask(id)` to retrieve the task (the returned record includes the **Ready** field value — no extra call needed; see `docs/RoadmapBackend.md` line 198), then apply the same validations: not in claimed-id set; `Ready` field is set; `.plan/<id>.md` is committed; no open `blocked_by`.

The **planning-gate validation** is absolute: a named-but-unplanned task is refused exactly like an auto-picked one. For the **`files` backend**, the gate requires the `[ready]` marker on the line plus a `.plan/<id>.md`. For a **non-`files` backend**, the gate requires the backend's `Ready` field to be set (carried in the `getTask` record) plus a `.plan/<id>.md`.

**The `.plan` file check depends on `PLAN_STORAGE` (step 1):**

- **`committed`** (default) — the plan is a tracked repo file present on `origin/<base>` (§16.5). The plan-on-base guard just below is the authoritative existence check.
- **`local`** (TASK_027) — the plan is a **gitignored file in the main checkout**, so validate it there instead: `test -r "$MAIN_ROOT/.plan/<id>.md"` (id without `#`). It is never on `origin/<base>` by design, and the plan-on-base guard below is **skipped** for this mode.

If the task fails the planning gate (missing `Ready` / missing `[ready]`, or the mode-appropriate `.plan/<id>.md` is absent/unreadable), **stop and refuse** in both interactive and non-interactive mode — never improvise a plan, never offer to plan it inline:

```text
✗ /next-task: task #<id> is not planned — run `/atelier:plan-task #<id>` first.
   A task is only claimable once a product lead has approved a plan and it carries [ready].
```

**Plan-on-base guard (`PLAN_STORAGE=committed` only — all backends):** Even when the planning gate passes (the task is `[ready]` and a `.plan/<id>.md` exists somewhere), verify the plan file is actually present on `origin/<base>` — the ref the worktree will be cut from. Use the existence probe:

```bash
git cat-file -e origin/<base>:.plan/<id>.md
```

This probe is backend-agnostic: for `planStorage=committed`, `.plan/<id>.md` is always a tracked repo file (§16.5), regardless of whether the backlog lives in `ROADMAP.md` or a non-`files` backend. If the probe exits non-zero (file absent on `origin/<base>`), **stop and refuse** — the plan was committed locally by `/atelier:plan-task` but never landed on the base:

```text
✗ /next-task: task #<id> is marked [ready] but its plan/decomposition is not on origin/<base>.
   The plan was committed locally by /atelier:plan-task but never landed.
   A worktree cut from origin/<base> would silently operate on stale ROADMAP state.
   resolve: push/merge the plan commit to origin/<base> (e.g. open a PR for it), then re-run.
```

For the **`files` backend with a decomposed epic**: if `origin/<base>:ROADMAP.md` still shows the undecomposed parent (no sub-task lines) while a local-only decomposition exists, the same refusal fires — the orchestrator must never claim a sub-task whose epic rewrite has not reached `origin/<base>`. This `ROADMAP.md`-on-base check is about the **backlog/decomposition**, which is committed under *both* storage modes, so it applies to `planStorage=local` too; only the `.plan/<sub-id>.md` file half is exempt under `local`.

**Under `PLAN_STORAGE=local`, skip the plan-on-base guard entirely** — the plan lives in the main checkout by design and is never expected on `origin/<base>`. Its existence was already confirmed by the mode-appropriate planning-gate check above (`test -r "$MAIN_ROOT/.plan/<id>.md"`). The worktree will not receive the file; step 8 carries the plan contents inline to the orchestrator instead.

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

- Call `moveTask(id, "roadmap", "in_progress")` via the `roadmap-tracking-flow` skill. This is atomic: the task moves out of the backend's roadmap bucket and into its in-progress bucket in a single operation — no local `ROADMAP.md` / `IN_PROGRESS.md` edits are made. For `github-project` specifically, the Status field on the Project item transitions from a value in `githubProject.stateMap.roadmap` (e.g. `"Backlog"` or `"Todo"`) to the first value in `githubProject.stateMap.inProgress` (default `"In Progress"`); the mapping is resolved via the stateMap in `.roadmap.json`.
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
- **plan-storage mode + plan source (TASK_027)** — always pass `plan_storage: <committed|local>` (the `PLAN_STORAGE` from step 1) and `main_checkout_root: <MAIN_ROOT>`.
  - Under **`committed`**, the plan is on `origin/<base>` and therefore already checked out at `<worktree>/.plan/<id>.md`; the orchestrator Reads it there as today — nothing extra to carry.
  - Under **`local`**, the worktree does **not** have the file. **Read `<MAIN_ROOT>/.plan/<id>.md` now** (it is on disk here in the main checkout) and pass its **Approach**, **Affected areas**, and **Acceptance criteria** **inline** in the briefing, so the orchestrator builds against the approved plan without touching the worktree copy. Also pass `main_checkout_root` so the orchestrator can re-read the absolute `<MAIN_ROOT>/.plan/<id>.md` if needed. **Never** point the orchestrator at `<worktree>/.plan/<id>.md` in this mode — the file is absent there by design.
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
- **Never** claim a `[ready]` task whose `.plan/<id>.md` (or, for a decomposed epic, the sub-task rewrite) is not present on `origin/<base>` — refuse with a pointer to land the plan commit. A worktree cut from `origin/<base>` would otherwise operate on stale ROADMAP state and drop the decomposition. **(This applies to `planStorage=committed`.)** Under `planStorage=local` the plan file is deliberately never on `origin/<base>`: validate it in the main checkout (`test -r "$MAIN_ROOT/.plan/<id>.md"`) and carry its contents inline (step 8) instead — but the `ROADMAP.md` decomposition-on-base check still applies, since the backlog is committed under both modes.
- **Never** look for a `planStorage=local` plan in the task worktree — `git worktree add` never copies the gitignored file, so `<worktree>/.plan/<id>.md` is always absent under `local` mode. The only source is `<MAIN_ROOT>/.plan/<id>.md` in the operator's main checkout.
