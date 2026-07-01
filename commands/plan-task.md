---
description: Plan a single ROADMAP.md task — dispatch the planner, review the draft with the product lead, and on approval commit the plan and mark the task `[ready]` so the orchestrator can claim it.
argument-hint: "<task-id>"
allowed-tools: Read, Edit, Bash(jq:*), Bash(git -C * status:*), Bash(git -C * diff:*), Bash(git -C * add:*), Bash(git -C * commit:*), Bash(git -C * checkout:*), Bash(git -C * clean:*), Bash(git status:*), Bash(git diff:*), Bash(git add:*), Bash(git commit:*), Bash(git checkout:*), Bash(git clean:*), Bash(git rev-parse:*), Bash(atelier-task-backend:*), Skill, Task
---

You are running the `/atelier:plan-task` slash command. The product lead invokes this to plan a task **before** the orchestrator can claim it. A task is only claimable once it carries the `[ready]` marker (or the Project's `Ready` field is set, for a `github-project` backend) and a committed `.plan/<id>.md`; this command is the only way to assert that.

## What this command does

Dispatches the `planner` agent on one task in the current project's backlog, presents the draft plan(s) to the product lead, and **only on explicit approval** commits the plan artifact(s) under `.plan/`, flips the task to `[ready]` (for a `files` backend) or sets the Project's `Ready` field via the backend (for a `github-project` backend), and (when the planner decomposed an oversize task) commits the epic rewrite in the same commit.

This command does **not** start the implement chain. The next `/atelier:next-task` will see the `[ready]` entry (or the `Ready` field) and claim it.

## Argument parsing

`$ARGUMENTS` must carry a single task id matching `^#?\d+[a-z]?$` (with or without leading `#`; a letter suffix like `42a` is allowed so a single sub-task can be planned). Anything else: print usage and exit.

```text
Usage: /atelier:plan-task <task-id>
Example: /atelier:plan-task #42
```

## Interaction mode

This command is **interactive by design** — approving a plan is a human gate. If running non-interactively (`$ARGUMENTS` carries `--yes`/`-y`, or `ATELIER_AUTO` is set), **do not auto-approve**: run the planner, write the draft, and **stop**, reporting the draft path(s) and that approval requires an interactive `/atelier:plan-task` run.

Never flip `[ready]` or set the Project's `Ready` field without a human approval — auto-approving would defeat the entire planning gate. For a `github-project` backend, this is doubly mandatory: the OAuth write to the Project field cannot be auto-resolved (§16.5: "approval remains interactive-only, never headless"). In non-interactive mode, stop after writing the draft regardless of backend.

## Phase 1 — Pre-flight

1. **Resolve the project root and backend.** The cwd is the project root in the canonical case. Resolve the backend:
   ```bash
   atelier-task-backend <project-root>   # → files | linear | github-project
   ```
   - **`files` backend:** if the cwd has no `ROADMAP.md`, print *"plan-task must be run from a project root with ROADMAP.md present"* and exit.
   - **non-`files` backend (e.g. `github-project`):** the presence of `.roadmap.json` (which the backend resolver requires) substitutes for `ROADMAP.md` presence — a `github-project` repo without a §5 `ROADMAP.md` must **not** be refused on the ROADMAP-presence check. If neither `.roadmap.json` nor `ROADMAP.md` is present, the backend resolver itself will have failed — surface its error and exit.

2. **Refuse inside a task worktree.** `git rev-parse --abbrev-ref HEAD`; if it starts with `task/`, refuse: *"/atelier:plan-task must be run from the main worktree, not a task worktree. The backlog and `.plan/` you'd be editing are on the wrong branch."* Plans belong on the base branch.

3. **Verify the relevant paths are clean.**
   - **`files` backend:** `git status --porcelain ROADMAP.md .plan`. If `ROADMAP.md` or `.plan/` has uncommitted changes, refuse — the planner's writes would mix with the operator's pending edits and the commit would be malformed. Surface: *"ROADMAP.md / .plan have uncommitted changes; commit or stash them first."*
   - **non-`files` backend:** `git status --porcelain .plan` only — there is no `ROADMAP.md` to guard. If `.plan/` has uncommitted changes, refuse with the same message (omitting `ROADMAP.md` from the text).
   - **Under `planStorage=local` (step 4 below):** `.plan/` is gitignored, so `git status --porcelain .plan` reports nothing for it — the plan file never enters the working-tree-clean accounting. The `ROADMAP.md` half of the check still applies for the `files` backend (the `[ready]` flip is still committed).

4. **Resolve the plan-storage mode (TASK_027).** Read `planStorage` from `<project-root>/.atelier.json` — default `committed` when the field or the file is absent:
   ```bash
   jq -r '.planStorage // "committed"' .atelier.json 2>/dev/null || echo committed
   ```
   - **`committed`** (default) — the plan file is committed to the base branch alongside the readiness flip (Phase 4, unchanged). It lands on `origin/<base>`, is checked out into every task worktree, and appears in the task PR.
   - **`local`** — the plan file is a **gitignored, never-committed** artifact in this main checkout. You still write it and still set readiness, but you **never** `git add`/commit `.plan/<id>.md`. `/atelier:next-task` and `/atelier:resume-task` read it locally from here and carry its contents inline in the orchestrator briefing (PLAN.md §16.5, TASK_027). This mode requires `.plan/` to be gitignored in the repo. Known trade-off: the plan does **not** appear in the task PR, so reviewers lose the "what was approved" audit trail.

## Phase 2 — Dispatch the planner

Invoke the `planner` agent via the `Task` tool. The briefing must include:

- `task_id`: the parsed id (with `#` prefix).
- `project_root`: the absolute path resolved in Phase 1.
- `entry_point`: `plan-task`.

**Wait for it to return.** The planner writes draft `.plan/<id>.md` file(s) (and, for an oversize task, rewrites the ROADMAP block into an epic via `task-decomposer`) — all as **uncommitted** working-tree changes.

## Phase 3 — Review with the product lead

If the planner returned `status: planned`:

1. `Bash`: for a `files` backend, `git diff --stat ROADMAP.md .plan`; for a non-`files` backend, `git diff --stat .plan` — confirm only the expected files changed.
2. Present the draft to the product lead in a compact, readable form: for each unit, show its `title`, the `Approach`, `Affected areas`, `Acceptance criteria`, and `Risks / open questions` from the draft `.plan/<id>.md`. If the task was decomposed, show the epic + sub-task split first.
3. Ask explicitly: **"Approve this plan?"** — and accept either a plain approval or approval-with-edits. If the product lead asks for changes that are small wording tweaks, apply them to the `.plan/<id>.md` with `Edit` and re-confirm. If they want a materially different approach, discard (Phase 5) and suggest re-running `/atelier:plan-task` after refining the task.

If the planner returned `refused-*` / `error`, skip to Phase 5 (nothing to commit) and surface the reason with the matching next action:

- `refused-not-found` → "No task with id `<task_id>` in the backlog."
- `refused-already-done` → "Task is already `[x]`; nothing to plan."
- `refused-marker-present` → "Task carries `[OVERSIZE]`/`[BLOCKED]`; resolve the marker first."
- `refused-already-ready` → "Task is already `[ready]` (or `Ready` field is set) with a committed plan. To re-plan, clear the ready state and remove `.plan/<id>.md` first, then re-run."
- `error: task lacks an explicit id` → "Add an explicit `#<id>` to the task line before planning."
- Any other `error` → surface verbatim and stop.

## Phase 4 — On approval: flip `[ready]`, commit

Only after explicit approval:

**Plan-storage mode (from Phase 1 step 4).** The backend sub-sections below describe the default `planStorage=committed` path. Under `planStorage=local`, apply the **same steps except never `git add`/commit `.plan/<id>.md`** — it stays a gitignored local artifact. Concretely:

- **`files` backend, `local`:** still flip `[ready]` in `ROADMAP.md` (and, if decomposed, still commit the epic rewrite), and still commit that `ROADMAP.md` change (`git add ROADMAP.md` — **omit `.plan`**), because the `[ready]` marker must still reach `origin/<base>` for `/next-task` to see it. The `.plan/<id>.md` file(s) stay local and uncommitted.
- **`github-project` backend, `local`:** set the Project's `Ready` field (`setReady(id, true)`) exactly as below, and make **no commit at all** — there is no `ROADMAP.md`, and `.plan/<id>.md` stays local.

In both `local` cases, still flip the draft plan's `Status:` line to `ready (approved — product lead)` inside the local `.plan/<id>.md` (a working-tree edit that is simply never staged). Everything else in Phase 4 below is the `committed`-mode path.

### `files` backend (unchanged — `planStorage=committed`)

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

### `github-project` backend (new)

Do **not** edit `ROADMAP.md` — there is none for this backend; the `Ready` flip goes through the backend only (see Hard refusals).

1. **Set the Project's `Ready` field** for each id in `ready_to_mark`: call the backend's `setReady(id, true)` operation via the `roadmap-tracking-flow` skill. This sets the dedicated `Ready` Project field (a boolean/single-select custom field, separate from Status, per §16.5). Drive this exactly the way `next-task` step 6 drives `moveTask` — through the `roadmap-tracking-flow` skill, not a raw `gh` invocation.
2. **Flip the draft status** in each `.plan/<id>.md` from `Status: draft (pending product-lead approval)` to `Status: ready (approved — product lead)`.
3. **Stage and commit** the plan (`.plan` only — `ROADMAP.md` is not part of this backend's repo state):
   ```bash
   git add .plan
   ```
   Commit with the same conventional message:
   ```text
   chore(plan): mark <task_id> ready with approved plan
   ```
   For the decomposed case:
   ```text
   chore(plan): decompose <task_id> into <N> sub-tasks and mark ready
   ```
4. Surface the commit SHA.

The planning gate is satisfied when **both** the Project's `Ready` field is set **and** `.plan/<id>.md` is committed — a `Ready` item without a committed plan file is the same inconsistency §5 defines for the `files` backend (§16.5).

## Phase 5 — Discard (rejection / refusal)

When the product lead rejects, or the planner refused/errored after leaving working-tree changes (e.g. a decomposer rewrite landed before a later failure):

### `files` backend (unchanged)

1. `git checkout -- ROADMAP.md` to revert any ROADMAP rewrite.
2. Remove the draft plan files the planner wrote that are not tracked: `git clean -f .plan` (only the new draft files; never touch already-committed plans). Confirm with `git status --porcelain .plan` before and after.
3. Report that nothing was committed and the ROADMAP/`.plan` are back to their pre-command state.

### `github-project` backend (new)

1. Remove the draft plan files the planner wrote that are not tracked: `git clean -f .plan`. Confirm with `git status --porcelain .plan` before and after. There is no `ROADMAP.md` to revert.
2. If `setReady(id, true)` already ran before a later failure in Phase 4, call `setReady(id, false)` via the `roadmap-tracking-flow` skill to un-set the `Ready` field. Because approval is the gate and the `setReady` call happens **after** approval, a rejection from the product lead never reaches the flip — the un-set path covers only a mid-Phase-4 failure (e.g. `setReady` succeeded but the subsequent `git commit` failed).
3. Report that nothing was committed and the `.plan` is back to its pre-command state; if the `Ready` field was un-set, confirm that too.

## Output

```text
== /atelier:plan-task <task_id> ==

Planned:   <task_id> — <title>   (decomposed into <N> sub-tasks: <#ids>)   # decomposition line only when applicable
Plans:     .plan/<id>.md [, .plan/<id>.md ...]
Ready:     <#ids flipped to [ready] / Ready field set>
Commit:    <sha>
Next:      push/merge this commit to origin/<base> first (a decomposition is only claimable once it is on origin/<base>); then run /atelier:next-task to claim <first ready id>
```

Under `planStorage=local`, adjust the tail lines: annotate `Plans:` with `(local — gitignored, not committed)`; for the `files` backend `Commit:` shows only the `ROADMAP.md` `[ready]`/epic-rewrite commit (the plan is not in it), and for the `github-project` backend the `Commit:` line is omitted entirely (nothing was committed). The `Next:` line still requires the `files` backend's `ROADMAP.md` `[ready]`/decomposition to reach `origin/<base>`, but **drops the "land the plan commit" precondition for the plan file itself** — `/next-task` reads the plan locally from this main checkout.

On refusal / rejection, the output is the reason plus the suggested next action, and a line confirming nothing was committed.

## Hard refusals

- **Never** flip `[ready]` or set the Project's `Ready` field without explicit product-lead approval. In non-interactive mode, stop at the draft — for both `files` and `github-project` backends.
- **Never** start the implement chain or invoke `task-orchestrator` / `implementer` from this command. `/plan-task` is planning-only.
- **Never** run from a task worktree — the backlog and `.plan/` you'd edit are on the wrong branch (Phase 1 step 2).
- **Never** push the commit; never push to a protected branch directly. Landing happens via a normal PR to `origin/<base>` (squash-merge), not a direct push. For the decomposed case, the epic rewrite and every `.plan/<sub-id>.md` must land together in that one commit/PR — they are already one commit, so a partial landing cannot occur. **Claimability contract (`planStorage=committed`):** `/next-task` cuts the task worktree from `origin/<base>` and reads the merged ROADMAP from `origin/<base>` — a plan/decomposition committed locally but not yet on `origin/<base>` is invisible and is silently dropped. **The plan commit is not claimable until it is on `origin/<base>`.** Until then, running `/atelier:next-task` will refuse with a clear message pointing to the unmerged plan. **Under `planStorage=local` this claimability precondition does not apply to the plan *file*** — the plan is read from the main checkout and is never expected on `origin/<base>` (for the `files` backend, the `[ready]`/epic-rewrite in `ROADMAP.md` must still land, exactly as above).
- **Never** edit `IN_PROGRESS.md` or `HISTORY.md` — the task is not claimed yet, so there is no in-progress entry.
- **Never** edit `ROADMAP.md` for a non-`files` backend — there is none; the `Ready` flip goes through the backend (`setReady`) only.
