---
name: auto-merge
description: >-
  Evaluate the six auto-merge guardrails from PLAN.md §6 against an open
  pull request, and — only when ALL guardrails pass — squash-merge it
  with `gh pr merge --squash --delete-branch`, then clean up the local
  worktree. ALWAYS load this skill when about to run `gh pr merge`,
  when the user says "merge the PR", "auto-merge", "ship it", "land
  this", "is this PR ready to merge?", or when `task-orchestrator`
  reaches the end of a task chain after `reviewer` has approved. The
  skill carries the executable detail the `operator-rules.md`
  SessionStart hook cannot — exact gh JSON queries, the six-guardrail
  evaluation order, the squash-and-cleanup recipe, and the structured
  output the orchestrator consumes. Refuses to merge anything that
  trips a guardrail. Always squash, never rebase or merge-commit.
  Trigger even when the user does not say "auto-merge" explicitly —
  any phrasing about landing a finished PR belongs here.
---

# auto-merge

The executable form of [PLAN.md §6](PLAN.md)'s auto-merge gate. The `reviewer` agent decides whether the PR is **correct**; this skill decides whether the PR is **mergeable without a human in the loop**. Two separate decisions.

## Preconditions

- Operator has authenticated `gh` (`gh auth status` returns OK). Without it the skill cannot read PR state and must stop.
- The PR exists and is identified by a number or URL.
- `task-orchestrator` (or the operator) has already invoked `reviewer` and the review verdict is visible via `gh pr view --json reviewDecision`.

If any precondition is missing, **stop and report** — do not partially-merge.

## The six guardrails

Evaluate in this order. **Each is short-circuiting**: the first failure stops the evaluation, the skill reports `held: <reason>` and does **not** merge.

### 1. PR is not a draft

```bash
gh pr view <NN> --json isDraft --jq .isDraft
```

If `true` → `held: PR is still a draft`.

### 2. Reviewer approved

```bash
gh pr view <NN> --json reviewDecision --jq .reviewDecision
```

Valid values: `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, `null` (no review requested).

Only `APPROVED` proceeds. Anything else (including `null`) → `held: review status is <value>; expected APPROVED`.

Important: GitHub's `reviewDecision` is the **net** decision after all reviews. If the `atelier:reviewer` agent approved but a human later marked `request-changes`, GitHub returns `CHANGES_REQUESTED` (correctly). The skill honours GitHub's verdict — it does not double-check the agent's individual review.

Note: the `reviewer` agent runs under `GH_CONFIG_DIR=$ATELIER_CONFIG_DIR/gh/reviewer`, a distinct GitHub user from the author identity at `$ATELIER_CONFIG_DIR/gh/author`. With distinct identities, GitHub honours the reviewer's `--approve` and `reviewDecision` resolves to `APPROVED`. If the two identities resolve to the same GitHub login, this guardrail keeps holding until the reviewer dir is re-authenticated with a different account.

Reviewer has no access to the repo: on a freshly-created **private** repo the reviewer identity is often not a collaborator, so it never managed to post an approval and `reviewDecision` is `REVIEW_REQUIRED`/`null`. Do not treat this as a normal "waiting for review" hold that will resolve on its own — it never will. When the review never landed because the reviewer could not resolve the repo, surface it as the terminal state `held: reviewer cannot access this repo — auto-merge unavailable; grant the reviewer read access (run /atelier:setup-project or add it as a collaborator)`, not an open-ended wait.

### 3. All CI checks succeeded

```bash
gh pr view <NN> --json statusCheckRollup --jq '.statusCheckRollup'
```

This returns an array of check objects (with `conclusion` and `status` fields). Pass condition: **every** check has `conclusion == "SUCCESS"` (or `status == "COMPLETED" && conclusion == "NEUTRAL"`, which means skipped checks). Fail if any is `FAILURE`, `CANCELLED`, `TIMED_OUT`, `STARTUP_FAILURE`, or still `IN_PROGRESS` / `QUEUED`.

If the array is empty (no checks configured), the skill treats it as **pass** — projects without CI shouldn't be blocked by the absence of CI. Surface this in the report so the operator knows.

→ `held: CI not green (<N> check(s) failed | <N> still running)`.

Note: when the skill is invoked via `task-orchestrator`, pending CI has already been waited on by the orchestrator's pre-merge CI wait step before this skill is called. The skill remains evaluate-once; the bounded wait lives upstream. When the skill is invoked directly by the operator ("merge the PR"), pending CI still yields `held` here — re-invoke after CI completes, or use `/atelier:babysit-prs` for unattended monitoring.

### 4. No forbidden files in the diff

```bash
gh pr view <NN> --json files --jq '.files[].path'
```

Reject if any path matches:
- `^package\.json$`, `^pnpm-lock\.yaml$`, `^package-lock\.json$`, `^yarn\.lock$` (root-level lockfiles and manifest)
- `^Dockerfile$`, `^Dockerfile\..*`, `^.*Dockerfile$`
- `^docker-compose\..*\.yml$`, `^docker-compose\.yml$`, `^docker-compose\.yaml$`
- Any path under `\.github/workflows/`

→ `held: forbidden path(s) in diff: <comma-separated list>`.

Note: this catches the **path**, not the diff intent. A PR that only adds a docs/README change to a package's metadata but accidentally also touches `package.json` falls into this guardrail and goes to human review. That's the intended behaviour.

### 5. PR within the project's size budget

Invoke `atelier-pr-size-check` against the PR. The tool applies the AND-gate (`>maxLines` AND `>maxFiles`, after exempting tests / lockfiles / migrations) using the values from `<project>/.atelier.json` or the built-in defaults (`200` lines, `10` files):

```bash
atelier-pr-size-check --pr <NN> --project <project-root>
```

Exit codes:

- **0** within budget → continue to guardrail #6.
- **1** OVERSIZE → `held: PR exceeds size budget (<counted-lines> lines AND <counted-files> files, limits <maxLines>/<maxFiles>)`. Include the tool's stdout — particularly the suggested slice boundaries — in the held-state report so the operator (and the orchestrator on the next pass) see the slicing hints.
- **2** error → `held: size check failed (<stderr-tail>)`. Do not silently widen the gate.

The AND-gate is deliberate: a tightly-scoped diff that grows long, or a broad refactor that stays small, both pass — only PRs that breach **both** axes after exemptions auto-block. Per-project overrides live in `<project>/.atelier.json`'s `prSize.{maxLines,maxFiles,exempt}`. The skill never widens the gate at runtime; if a project legitimately needs a higher ceiling, that decision is made in `.atelier.json` and version-controlled.

### 6. No unresolved human comments

```bash
gh pr view <NN> --json comments
```

Each comment object has `author.login` and `body`. Reject the PR for auto-merge if there is **any** comment whose `author.login` is not on the bot list (default: `github-actions[bot]`, `dependabot[bot]`, plus any operator-configured bot names) **and** the comment text does not contain a resolution marker (`resolved`, `done`, `lgtm`, `looks good`, case-insensitive) **and** does not start with `:+1:` / `👍`.

This is heuristic — GitHub does not expose a structured "resolved" flag for top-level PR comments (only for inline review comments via the GraphQL `reviewThreads` API). The safe default is **conservative**: pending unresolved human comment → human merge.

→ `held: <N> pending human comment(s) (latest by @<user>)`.

## Authorization model — the gate IS the consent

The six guardrails ARE the operator's pre-given authorization. Atelier's contract with the operator is: *"configure the policy, configure the gates, then the chain runs autonomously"*. The operator has already consented to merging by:

- Adopting atelier (which ships PLAN.md §6's auto-merge policy as its default).
- Authoring the project (which version-controls the size budget + per-category policy in `<project>/.atelier.json`).
- Running `/atelier:next-task` (which dispatches the chain).

Asking *"should I merge now?"* after the gate resolves to `merged` converts the gate from a policy decision into a request-for-permission, which negates the entire reason the gate exists. The default Claude Code disposition to confirm before "actions affecting shared state" is **explicitly overridden** here: the gate's positive verdict IS the authorization.

**Do NOT** prompt the operator to confirm the merge when all six guardrails resolve to `merged`. Execute the `gh pr merge` command directly. The structured output (with `Decision: merged` plus `Merge commit: <sha>` below) IS the report — no additional confirmation step exists between the gate and the merge.

**Per-PR opt-outs already exist** (no ad-hoc confirmation needed):

- **Panic switch**: `/atelier:abort-auto [reason]` flips every remaining decision to `ask` per `[[decision-broker]]`. Use this when the operator wants every remaining call in the active task routed through them.
- **Per-project policy**: `<project>/.atelier.json` `decisionPolicy.byCategory` routes specific categories to `ask` (or to a fixed option) for the whole project.
- **Per-task flags**: `task --policy=ask` (everything ask) or `task --ask-for=auto-merge` (just this) for a single task lifecycle.

These escape hatches leave a paper trail in the project / task; an ad-hoc *"confirm before main?"* prompt does not.

## Merge — only when all six guardrails pass

```bash
gh pr merge <NN> --squash --delete-branch --body-file <(echo "")
```

- `--squash` is the only strategy atelier ships (PLAN.md §6).
- `--delete-branch` removes the remote branch in the same call.
- `--body-file <(echo "")` clears the squash-commit body to just the title — the original PR body lives on the closed PR for history; the merge commit on `main` should be terse.

Capture the merge commit SHA from the command output (it prints `Merged pull request #N (commit: <sha>)`).

## Post-merge cleanup

Once the merge succeeds:

1. **Local worktree removal**. Resolve the branch name from `gh pr view <NN> --json headRefName --jq .headRefName`. Then:
   ```bash
   git wt rm <branch>
   ```
   `git-wt` confirms before removing; the skill must pass that confirmation through to the operator (do not auto-confirm). If the worktree is dirty (unexpected after a clean merge), surface that and **do not** force-remove.

2. **Roadmap item closure**.
   - When the project uses the `roadmap-tracking-flow` layout (`ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md`), `pr-flow` already moved the entry to `HISTORY.md` in the merged PR's own commits. **Verify** by reading `HISTORY.md` for the task ID; if it's there, the cleanup is already done.
   - When the project uses the PLAN.md §5 single-file ROADMAP (with `- [ ]` / `- [x]` checkboxes), the skill replaces the matching `- [ ]` line with `- [x]` and commits the change with a Conventional Commits message:
     ```text
     chore(roadmap): mark <#id> done (auto-merge after PR <#NN>)
     ```
     Push directly to `main` for this single-line bookkeeping commit is **not** allowed by the static permissions matrix. The operator must do this commit themselves; the skill surfaces the change as a `gh pr` follow-up or asks the operator to land it in the next task's PR.

3. **Local branch cleanup** (if it remains). `git wt rm` removes both the worktree and the branch in most cases; verify with `git branch --list task/*` and report any orphan task branches.

## Structured output

```text
== auto-merge report ==

PR:           <url>
Title:        <title>
Branch:       <head> → <base>
Lines:        +<additions> / -<deletions> (total: <sum>)
Files:        <count>

Guardrails:
  draft:          ✓ | ✗ — <reason>
  review:         ✓ APPROVED | ✗ <state>
  CI:             ✓ <N>/<N> checks SUCCESS | ✗ <state>
  forbidden:      ✓ none | ✗ <comma-separated paths>
  size:           ✓ <N> lines / <M> files (within budget) | ✗ OVERSIZE <N>/<M> (limits <maxLines>/<maxFiles>)
  comments:       ✓ no pending | ✗ <N> pending (latest @<user>)

Decision: merged | held — <comma-separated failed guardrails>

<if merged>
Merge commit:  <sha>
Worktree:      <removed | retained at <path>>
Roadmap:       <found in HISTORY.md | marked [x] | manual follow-up needed>
</if>

<if held>
Next step:     human review required. Operator can:
  - Run `gh pr merge --squash --delete-branch <NN>` manually after addressing the blocker(s).
  - Resolve the blocker (e.g. resolve pending comments) and re-invoke this skill.
</if>
```

## Hard refusals

- **Never** ask the operator to confirm the merge after the six guardrails resolve to `merged`. The gate is the authorization — see § Authorization model. Per-PR opt-outs live in `/atelier:abort-auto`, `<project>/.atelier.json`, and the `task --policy` / `--ask-for` flags. An ad-hoc *"should I merge?"* prompt is a contract violation regardless of phrasing (*"confirm before touching main?"*, *"shall I land this?"*, *"OK to merge?"* are all the same violation).
- **Never** merge when ANY guardrail fails. The whole point of the six is short-circuiting safety.
- **Never** use `--merge` or `--rebase` strategies. Squash only.
- **Never** loop or retry within this skill on a transient guardrail state (CI still running, comment pending). The skill evaluates once and returns `held` — the orchestrator is responsible for waiting on pending CI and re-invoking this skill when CI completes (see pre-merge CI wait in `task-orchestrator`). A direct operator invocation ("merge the PR") that encounters pending CI yields `held` here and returns; re-invoke after CI resolves, or let `/atelier:babysit-prs` handle the unattended case. This refusal applies to the skill itself — the orchestrator's upstream wait is intentional and does not contradict it.
- **Never** force-remove a dirty worktree post-merge. Something unexpected happened; surface it to the operator.
- **Never** push `chore(roadmap): mark X done` directly to `main`. The static permissions matrix denies it. Surface the change as a follow-up.
- **Never** mark a roadmap item `[x]` for a PR that was held. The auto-merge skill only modifies state on success.
- **Never** override `reviewDecision`. If GitHub says `CHANGES_REQUESTED`, that is final until a new review supersedes it.
- **Never** silently widen the size budget. The threshold is the AND-gate from `atelier-pr-size-check`, configurable per-project via `<project>/.atelier.json`'s `prSize.{maxLines,maxFiles,exempt}`. If a project legitimately needs a higher ceiling, the operator updates that file (version-controlled, reviewable) — the skill never raises the gate at runtime.

