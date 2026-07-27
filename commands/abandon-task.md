---
description: Stop and discard an in-flight task — close its open PR without merging, remove the worktree and branch, and move tracking to a terminal state. The inverse of `/atelier:next-task`'s claim; preserves the approved plan and the task itself for re-claiming later — not a permanent kill.
argument-hint: "<id> [--yes|-y]"
allowed-tools: Read, Edit, Glob, Grep, Bash(git status:*), Bash(git branch:*), Bash(git worktree:*), Bash(git rev-parse:*), Bash(git wt:*), Bash(gh pr list:*), Bash(gh pr view:*), Bash(gh pr close:*), Bash(gh issue view:*), Bash(gh issue close:*), Bash(gh api graphql:*), Bash(atelier-task-backend:*), Bash(atelier-housekeeping:*), Bash(jq:*), Bash(env:*), Bash(test:*), Skill, Task, AskUserQuestion
---

You are running the `/atelier:abandon-task` slash command. Its job is the **inverse of `/atelier:next-task`'s claim**: stop an in-flight task cleanly — close its open PR without merging, remove its worktree and local branch, and move tracking back to a re-plannable terminal state. It does **not** delete the approved plan, does **not** touch `ROADMAP.md`'s eligibility of the task, and does **not** close it out as delivered — the task stays re-claimable via `/atelier:next-task <id>` or `/atelier:resume-task <id>` afterward.

This command never merges, never pushes, and never force-touches a protected branch — see the Hard refusals section.

## User input

`$ARGUMENTS` must include the task id (e.g. `#42` or `42` — strip a leading `#` if present). **Required** — refuse if empty with: `Usage: /atelier:abandon-task <id> [--yes|-y]`. Do not auto-pick a task. May additionally carry the `--yes` / `-y` flag described below.

## Interaction mode (read once at the start)

Same contract as `/atelier:next-task` and `/atelier:resume-task`. You are **non-interactive** if any of:

- `$ARGUMENTS` contains the literal token `--yes` (whitespace-bounded).
- `$ARGUMENTS` contains the literal token `-y` (whitespace-bounded).
- The environment variable `ATELIER_AUTO` is set to a non-empty value. Probe with `env | grep -E '^ATELIER_AUTO='`.

Otherwise you are **interactive**. In non-interactive mode, never use `AskUserQuestion` — auto-resolve per the inline rule for step 4 (or stop with a clear error when no safe default exists).

## Steps

Strip `--yes` / `-y` from `$ARGUMENTS` before parsing the task id, and strip a leading `#` (so `#42 --yes` and `42` both resolve to id `42`).

### 1. Resolve the backend and the main root

This command runs in the operator's main checkout, exactly like `/atelier:resume-task`:

```bash
MAIN_ROOT="$(git rev-parse --show-toplevel)"
BACKEND="$(atelier-task-backend "$MAIN_ROOT")"   # → files | linear | github-project
```

`BACKEND` governs steps 2 and 7 below. Run `git status --short` here too: abandoning does not require a clean tree in the *main* checkout — the destructive work happens in the *task* worktree, removed under its own force in step 6, and step 7's files-backend tracking move rides a throwaway worktree of its own — but a dirty main tree is still worth a quiet note in the final report.

### 2. Locate the in-flight task — the abandon anchor

An "anchor" is proof the task is actually in flight. There are two independent anchors; find at least one before doing anything destructive.

**Anchor A — an open `task/<id>-*` PR.** Use the `startswith` jq filter — **never** `gh pr list --head`, which matches the branch name exactly, not as a prefix, so it never matches the full `task/<id>-<slug>` branch:

```bash
gh pr list --state open --json number,headRefName,url \
  --jq '[.[] | select(.headRefName | startswith("task/<id>-"))][0]'
```

**Anchor B — an active in-progress record with no open PR.** A task can be in flight (a worktree exists, work is underway) before `pr-author` ever pushes a branch, so the absence of Anchor A does not by itself mean "not in flight":

- **github-project** — call `getTask(id)` via the `roadmap-tracking-flow` skill and check whether its Status field value is in `githubProject.stateMap.inProgress` (per `.roadmap.json`). If so, the board itself is the anchor.
- **linear** — analogous: `getTask(id)` and check the issue is in the backend's in-progress state.
- **files** — check `MAIN_ROOT/IN_PROGRESS.md` for a heading containing the id. Recall that a normal files-backend claim lives only on the task branch until merge (per `commands/next-task.md` step 6), so a heading actually present in the *main* checkout's `IN_PROGRESS.md` is specifically the `[BLOCKED]` / `[OVERSIZE]` marker form written by `unblocker` / the orchestrator — that counts as an anchor too.

**Resolve the worktree** (regardless of which anchor fired):

```bash
git worktree list --porcelain
```

Find the entry whose branch matches `task/<id>-*`. Call it `<wt>`. Its absence is not by itself a refusal — a task can be anchored by an open PR whose worktree the operator already removed by hand — but note it in the final report.

**Neither anchor found** → refuse:

> Render the labels below in the operator's chatLanguage — the English is illustrative structure, not literal output.

```text
✗ /atelier:abandon-task: task <id> is not in flight.
   No open task/<id>-* PR and no active in-progress record found.
   It may already be delivered (check HISTORY.md / the board), still sitting
   unclaimed in the backlog (/atelier:next-task <id> claims it), or the id is wrong.
```

### 3. Refuse unsafe cases — before any destruction

Apply these checks before step 4 (confirm) and before any of steps 5–8 (destruction):

- **PR already `MERGED`.** If Anchor A's PR state is `MERGED` (`gh pr view <NN> --json state --jq '.state'`), refuse — it already shipped; there is nothing left to abandon.
- **Protected or non-`task/*` branch.** If the resolved branch (from Anchor A's `headRefName`, or the worktree's branch from step 2) is `main`, `master`, `develop`, `staging`, or does not start with `task/`, refuse — this command only ever touches `task/<id>-<slug>` branches.

Refusal message for either case:

> Render the labels below in the operator's chatLanguage — the English is illustrative structure, not literal output.

```text
✗ /atelier:abandon-task: cannot abandon task <id> — <reason>.
```

### 4. Confirm — the destructive gate

Summarize exactly what will change: the PR (number + URL, if any), the branch, the worktree path (if resolved), and the tracking move planned for step 7.

- **Interactive:** use `AskUserQuestion` to present the summary and ask for explicit confirmation before proceeding. On "no", stop — nothing is touched.
- **Non-interactive** (`--yes` / `-y` / `ATELIER_AUTO`): log `auto-abandoning task <id> (non-interactive)` and proceed. The flag itself is the consent, same contract as `/atelier:next-task` step 4 and `/atelier:resume-task`.

Nothing in steps 5–8 runs before this gate passes.

### 5. Close the PR — never merge

If Anchor A found an open PR:

```bash
gh pr close <NN> --delete-branch --comment "Abandoned via /atelier:abandon-task"
```

`--delete-branch` removes the *remote* branch through GitHub's API — it is not a force push, which is why this command needs no `git push` permission at all. If there is no open PR (Anchor B only), skip this step entirely.

### 6. Remove the worktree and local branch

The worktree is usually dirty (in-flight work), and `atelier-housekeeping` deliberately refuses dirty worktrees — so this command removes it itself, gated by step 4's confirm, using a **local force** (never a push):

```bash
git worktree remove --force "<wt>"
git worktree prune
git branch -D task/<id>-<slug>
```

`.task-log/` lives inside `<wt>` and is removed along with it — nothing extra to clean up there.

If `<wt>` was already absent (step 2 noted it), skip the `worktree remove` call and go straight to `git branch -D` (if the local branch still exists) and `git worktree prune`.

Then run a residual safety sweep — belt-and-suspenders, never the primary removal mechanism, since steps above already did the real work:

```bash
atelier-housekeeping --project "$MAIN_ROOT" --yes --no-stamp
```

### 7. Move tracking to a terminal state — backend-aware

- **github-project.** Move the board item off the in-progress bucket through the `RoadmapBackend` contract via the `roadmap-tracking-flow` skill — **never** by editing local files (there are none to edit on this backend). Probe the Project's Status field options through the same skill, not an ad-hoc raw `gh api` call outside that abstraction (`Bash(gh api graphql:*)` is granted in this command's frontmatter for the skill's own `getTask`/`moveTask` calls, per `commands/next-task.md`'s step 6 precedent — the point is to keep the backend write funneled through one contract, not to withhold the permission): if an `Abandoned` or `Cancelled` option exists, `moveTask(id, "in_progress", <that option>)`; otherwise fall back to `moveTask(id, "in_progress", "roadmap")` (the `Todo` bucket, re-plannable) and note in the final report that no dedicated abandoned/cancelled state exists. Do **not** create a new Status option — that is out of scope for this command.
- **linear.** Analogous `moveTask(id, "in_progress", "backlog")` (or the backend's `Cancelled` state if the skill exposes one) via the `roadmap-tracking-flow` skill.
- **files.** There is usually nothing to edit — a normal in-flight claim lived only on the now-closed PR's branch (which is gone). The **only** case needing an edit is when Anchor B fired because a `[BLOCKED]` / `[OVERSIZE]` entry exists in `MAIN_ROOT/IN_PROGRESS.md`: move that entry to `HISTORY.md` under an explicit `abandoned` mark. That move has to reach the base branch as its own PR, and this command never commits, pushes, or opens it from its own turn: its tool grant excludes `git commit` / `git push` / `gh pr create` (see the frontmatter), and **loading a skill grants no tools** — the commands a skill documents would still run from this session, under this session's grants. What actually supplies those tools is **dispatching a sub-agent that carries its own**. So route the PR exactly the way `/atelier:align` Tier 3 and `/atelier:release` do:

  1. **Prepare the branch in a throwaway worktree** so the operator's checkout is untouched. Invoke the `git-wt` skill (or `git wt switch docs/abandon-<id> --from <base>` directly), `<base>` being the branch `MAIN_ROOT` is checked out on — normally `main`, and the ref that actually carries the `[BLOCKED]` / `[OVERSIZE]` entry. Capture the absolute worktree path it prints.
  2. **Make the tracking move with `Edit`, inside that worktree** (never in `MAIN_ROOT`): take the entry out of `IN_PROGRESS.md` and into `HISTORY.md` under the explicit `abandoned` mark. Leave it uncommitted — `pr-opener` commits it downstream under the atelier-author identity (`GIT_CONFIG_GLOBAL="$ATELIER_CONFIG_DIR/git-identity.conf"`), mirroring the `unblocker` docs-PR pattern.
  3. **Dispatch the `atelier:task-orchestrator` agent via `Task` in non-task PR coordination mode.** Hand it `mode: non-task-pr` and **no** `task_id` — that absence is what routes the orchestrator out of its normal task chain — plus `repo` (owner/name), `worktree` (the path from 1, already prepared on `head`), `base`, `head: docs/abandon-<id>`, `title` (`docs(tracking): abandon task <id>`), `body` (what was abandoned, the closed PR number if any, and why), and `interactive: <bool>` from this command's interaction mode. The orchestrator — not this command — selects `pr-opener` as the authoring primitive for a `docs/*` head and then owns the `reviewer` → Pre-merge CI wait → `auto-merge` segment. Do **not** dispatch `pr-opener`, `reviewer`, or `auto-merge` from this command's own turn.
  4. **Handle the orchestrator's terminal report.** On `merged`, capture the PR URL for the final report and remove the throwaway worktree (`git wt rm docs/abandon-<id>`, or `git worktree remove` + `git worktree prune`). On `held`, surface the held reason verbatim, leave the throwaway worktree in place so the operator can finish the move, and say so in the final report — never merge it yourself.

### 8. Close a stale `blocked` issue, if any

If the task's tracking carried a `[BLOCKED] see #<NN>` marker (files backend) or the board record referenced an open blocked issue:

```bash
gh issue close <NN> --comment "Task abandoned via /atelier:abandon-task"
```

Skip if there was no such issue.

## Output

End the command with a single status block:

> Render the labels below in the operator's chatLanguage — the English is illustrative structure, not literal output.

```text
✓ /atelier:abandon-task <id>
  PR:             closed #<NN> (branch deleted)   | n/a (no open PR)
  Worktree:       removed <absolute-path>          | already absent
  Local branch:   deleted task/<id>-<slug>         | already absent
  Housekeeping:   swept (residual sweep, --no-stamp) | nothing residual
  Tracking:       moved to <Abandoned|Cancelled|Todo/backlog>   (github-project | linear)
                  | moved [BLOCKED]/[OVERSIZE] entry to HISTORY.md via <docs PR url>   (files)
                  | nothing to move (files, normal in-flight claim lived only on the deleted branch)
  Issue closed:   #<NN>                             (only if one existed)
  Next:           task <id> is re-claimable via /atelier:next-task <id> or /atelier:resume-task <id>.
```

If a step aborted, report exactly which one and why — same discipline as `/atelier:resume-task`.

## Hard refusals

- **Never** merge. This command only ever calls `gh pr close`, never `gh pr merge` — abandoning is explicitly the "discard, do not ship" path.
- **Never** push. There is no `git push` verb anywhere in this command's tool grant (see the frontmatter) — remote branch removal goes through `gh pr close --delete-branch` (a GitHub API call, not a push), and the rare files-backend tracking move is delegated to `task-orchestrator`'s non-task PR coordination mode (step 7), which dispatches `pr-opener` to commit and push the `docs/abandon-<id>` branch from that agent's own grants, rather than done with raw `git commit`/`git push` here.
- **Never** touch a protected branch (`main`/`master`/`develop`/`staging`) or any branch that does not start with `task/`. Step 3 refuses before any destructive step runs.
- **Never** abandon a PR whose state is already `MERGED` — it already shipped; abandon only applies to in-flight, unmerged work.
- **Never** destroy anything (close the PR, remove the worktree, delete the branch, move tracking) before step 4's confirm gate has explicitly passed, interactive or non-interactive.
- **Never** delete the approved plan (`.plan/<id>.md`, or the backend-resident plan) or remove the task from the backlog entirely. Abandon is reversible by design — the task stays claimable afterward.
- **Never** invent a new backend Status option (e.g. creating an `Abandoned` column that does not exist). If the option is absent, fall back to the re-plannable bucket and say so.
- **Never** use `rm -r`, `rm -rf`, or `rm -fr` on the worktree path. `git worktree remove --force` is the correct, git-aware removal — a raw recursive delete leaves git's internal worktree bookkeeping (`.git/worktrees/<name>`) dangling.
