---
description: Continue a task after interruption or unblocking. Auto-detects the resume mode from `IN_PROGRESS.md` state — "interrupted" (active entry, partial progress) vs "blocked-resumed" (entry has the `[BLOCKED]` marker and the GitHub issue has been closed by the operator). Runs the mode-specific cleanup, then hands off to `task-orchestrator`.
argument-hint: "<task-id> [--yes|-y]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(git status:*), Bash(git branch:*), Bash(git wt:*), Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(git checkout:*), Bash(ls:*), Bash(rm:*), Bash(rmdir:*), Bash(env:*), Bash(gh issue view:*), Bash(gh pr create:*), Skill, Task
---

You are running the `/resume-task` slash command. Two distinct entry points lead here — both end with the same orchestrator hand-off, but they require different pre-flight cleanup:

- **Interrupted-resume.** The operator's previous session was killed mid-task (Claude crashed, the laptop slept past the harness timeout, the network dropped during a `git push`, etc.). The task is still active in `IN_PROGRESS.md` (no `[BLOCKED]` marker), `.task-log/` may or may not exist, the worktree is intact. The retry budget continues where it left off — logs are preserved.
- **Blocked-resume.** The task previously reached hard-stop, `unblocker` opened a GitHub `blocked` issue, `IN_PROGRESS.md` carries the `[BLOCKED] see #<NN>` marker. The operator has now closed the issue (the unambiguous "ready to retry" signal — see [M4.2 contract in HISTORY.md](HISTORY.md)) and wants a fresh attempt. `.task-log/` must be wiped, the budget resets to 6, the marker comes off.

The command **auto-detects** which mode applies from the state of `IN_PROGRESS.md`. The operator does not pick.

## User input

`$ARGUMENTS` must include the task id (e.g. `#42` or `42` — strip a leading `#` if present). **Required** — refuse if empty with: `Usage: /atelier:resume-task <task-id> [--yes|-y]`. Do not auto-pick a task. May additionally carry the `--yes` / `-y` flag described in the Interaction mode section below.

## Interaction mode (read once at the start)

Same contract as `/atelier:next-task` (M4.6). You are **non-interactive** if any of:

- `$ARGUMENTS` contains the literal token `--yes` (whitespace-bounded).
- `$ARGUMENTS` contains the literal token `-y` (whitespace-bounded).
- The environment variable `ATELIER_AUTO` is set to a non-empty value.

Otherwise you are **interactive**. In non-interactive mode, never use `AskUserQuestion` — auto-resolve per the inline rule for each step (or stop with a clear error when no safe default exists). Pass the mode through to `task-orchestrator` in the briefing at step 5.

## Steps

### 1. Sanity-check the worktree

Run `git status --short` and `git branch --show-current` in the main worktree.

- **Working tree clean** → proceed to step 2.
- **Working tree dirty, interactive mode** → surface the state and ask the operator to stash or commit before proceeding. The resume flow needs to commit a 1-line bookkeeping change to `IN_PROGRESS.md` (blocked-resume) and an unrelated dirty tree corrupts the audit trail.
- **Working tree dirty, non-interactive mode** → **stop with error** pointing at the dirty state and the resolution (`git stash` or commit). Do NOT auto-stash.

### 2. Locate the task entry in `IN_PROGRESS.md`

Read `IN_PROGRESS.md`. Search for a heading line that contains the task id (`#<id>`, the bare `<id>`, or the explicit `task/<id>-<slug>` form — be tolerant). Three outcomes:

- **Exactly one match found.** Proceed to step 3 with the matched heading.
- **Zero matches.** The task is not in `IN_PROGRESS.md`. Maybe it's in `ROADMAP.md` (operator wanted `/atelier:next-task #<id>`, not `/atelier:resume-task`), in `HISTORY.md` (already merged), or doesn't exist at all. Surface which of those it is and suggest the right command. Stop.
- **Multiple matches.** Two different tasks have the same id in their headings — an inconsistency in the operator's tracking files. Stop and surface the ambiguity. Do not guess.

### 3. Detect the resume mode

Look at the matched heading line from step 2.

- If it contains the literal `[BLOCKED]` substring → **blocked-resume mode**. Continue to step 4a.
- Otherwise → **interrupted-resume mode**. Skip to step 5.

### 4a. Blocked-resume preflight — verify the GitHub issue is closed

The heading metadata block (the `> Blocked at … GitHub issue: <url>` lines added by `unblocker`) carries the issue URL. Extract the issue number from that URL. Then:

```bash
gh issue view <issue-number> --json state,closedAt --jq '.state'
```

Three outcomes:

- **`CLOSED`** → operator gave the "ready to retry" signal. Proceed to step 4b.
- **`OPEN`** → operator has not finished triage. Stop with:
  ```text
  ✗ /resume-task: GitHub issue #<NN> is still OPEN.
     The close itself is the "ready to retry" signal (M4.2 contract).
     Investigate the issue, push any fix you decided was needed,
     close the issue, then re-run `/atelier:resume-task <task-id>`.
  ```
- **Issue does not exist** (`gh` returns 404) → the marker references a deleted issue, which is an inconsistency. Stop and surface it; the operator must restore the issue or manually clean the `[BLOCKED]` marker before resuming.

### 4b. Blocked-resume — wipe `.task-log/` and unmark `[BLOCKED]`

The contract from M4.2: closing the issue is the operator's signal. The 6 attempt logs are already preserved in the closed issue's body (the `<details>` blocks added by `unblocker`), so the on-disk copies can be deleted to give the retry budget a clean slate.

1. Resolve the worktree path from the heading's metadata block (the `> Worktree (preserved): <path>` line). Call it `<wt>`.

2. **Wipe `<wt>/.task-log/`.** List the files, remove each one explicitly (no recursive `rm -r`, no `-f`), then `rmdir` the empty directory:

   ```bash
   ls -1 "<wt>/.task-log/" | while IFS= read -r f; do rm "<wt>/.task-log/$f"; done
   rmdir "<wt>/.task-log"
   ```

   If `.task-log/` does not exist (the operator pre-cleaned it, or it never had any files), skip. Do not error.

3. **Unmark the `[BLOCKED]` heading and remove the metadata block from `IN_PROGRESS.md`.** Use `Edit` to:
   - Replace the heading line `### <id> — <title> — [BLOCKED] see #<NN>` with the original `### <id> — <title>` form (recover the title from the heading itself — strip the ` — [BLOCKED] see #<NN>` suffix).
   - Delete the metadata block that follows the heading (the `> Blocked at … / GitHub issue: … / Worktree (preserved): … / Logs: …` quoted block).
   - Leave the original task block contents (acceptance criteria, etc.) untouched.

4. **Commit and push the unmark on a dedicated branch** (mirrors the `unblocker` pattern that wrote the marker):

   ```bash
   git checkout -b docs/resume-<id>
   git add IN_PROGRESS.md
   git commit -m "docs(tracking): unmark task <id> [BLOCKED] — resuming via /resume-task (issue #<NN> closed)"
   git push origin docs/resume-<id>
   gh pr create \
     --title "docs(tracking): unmark task <id> [BLOCKED] — resuming" \
     --body "Auto-opened by /atelier:resume-task after issue #<NN> was closed. Removes the [BLOCKED] marker from IN_PROGRESS.md so the orchestrator stops filtering this task out. Pair PR to the one that originally marked it blocked."
   ```

   Capture the PR URL — it goes into the final output. If `gh pr create` fails, leave the local commit on the docs branch, push when possible, and surface the failure (do **not** edit the task-worktree copy as a fallback — same reasoning as the `unblocker`).

5. **Switch back to `main`** so the next step's task-orchestrator hand-off runs from a clean base branch:

   ```bash
   git checkout main
   ```

### 5. (both modes) Hand off to `task-orchestrator` in **resume mode**

Launch the `atelier:task-orchestrator` agent with these inputs:

- `task_id`: `<id>`
- `worktree_path`: `<wt>` (the absolute path captured in step 4b for blocked-resume, or resolved from `git wt list` matching `task/<id>-*` for interrupted-resume)
- `branch`: `task/<id>-<slug>` (from `git branch --show-current` inside `<wt>`, or from `git wt list`)
- **`resume_mode`**: `interrupted` | `blocked` — pass this **explicitly** in the agent prompt. The orchestrator's Step 1 ("Pick the task") has special handling for this flag: it does **not** treat the active `IN_PROGRESS.md` entry as an anomaly and does **not** invoke `task-discovery`. It jumps directly to the specialist chain starting from `implementer`.
- **`interactive`**: `true` | `false` — propagate the interaction mode from the section above. The orchestrator does not have its own confirmation step in resume mode, so this is mostly forward-looking (specialists that may add prompts in the future inherit the flag).

For **blocked-resume**, also tell the orchestrator that `.task-log/` was wiped and the budget is a fresh 6.

For **interrupted-resume**, the budget continues — `.task-log/` may have N existing logs (0..6) and `retry-with-logs` will pick up at attempt N+1 on the first specialist failure.

## Output

End the command with a single status block:

```text
✓ /resume-task <id>
  Mode:           blocked-resume | interrupted-resume
  Worktree:       <absolute-path>
  Branch:         task/<id>-<slug>
  Issue (closed): #<NN> — <url>           (blocked-resume only)
  Unmark PR:      <url>                   (blocked-resume only)
  Task log:       wiped (0 attempts on disk) | preserved (<N>/6 attempts on disk)
  Next:           task-orchestrator resuming in <wt> with the specialist chain.
```

If a step aborted, report exactly which one and the actionable next instruction for the operator.

## Hard refusals

- **Never** resume a task when `IN_PROGRESS.md` does not contain it. The orchestrator's Step 1 invariant is that an active entry exists; resuming without one corrupts the contract.
- **Never** wipe `.task-log/` in interrupted-resume mode. The whole point of that mode is that the budget continues — wiping would silently extend it past the 6-attempt cap from PLAN.md §8.
- **Never** wipe `.task-log/` when the GitHub issue is still open. The close-as-signal is the only signal — until it happens, the logs are operator evidence in flight.
- **Never** push to `origin task/<id>-<slug>` from this command. The task branch is for the failing implementation; the bookkeeping change (`docs/resume-<id>`) lives on its own branch.
- **Never** use `rm -r`, `rm -rf`, or `rm -fr` even though the deny list does not match every form. The `Bash(rm:*)` allowance in this command's frontmatter is for the explicit per-file deletion of `.task-log/` contents only — recursive removal is out of scope and creates a foot-gun.
- **Never** invoke `unblocker` from this command. Resume reverses what `unblocker` did; re-invoking it would loop.
- **Never** silently overwrite an in-flight `IN_PROGRESS.md` heading. If the heading mid-file changed between step 2's read and step 4b's edit (concurrent operator edit), stop and surface — the resume needs a stable target.

## Why this command exists

Without `/resume-task`, every interruption forces the operator into manual recovery: read `.task-log/` to figure out what happened, edit `IN_PROGRESS.md` by hand, find the right branch to re-checkout. After a `hard-stop` it is worse — the marker must come off, the logs cleared, the budget reset, and the orchestrator told to start over without re-picking. This command is the inverse of `unblocker`'s state mutation (for blocked-resume) and the inverse of a crashed session (for interrupted-resume). Same command, two flows, one operator intent: *get this task moving again*.
