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
- `task-orchestrator` (or the operator) has already invoked `reviewer` and the review verdict is readable via `atelier-review-verdict <owner/repo> <NN>` (a head-sha-bound verdict review, or GitHub's `reviewDecision`).

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
atelier-review-verdict <owner/repo> <NN>   # one line: verdict=<approve|approved|request-changes|stale|none> [sha=<40-hex>]
```

Exit `0` (`verdict=approve sha=…` or `verdict=approved sha=…`) proceeds; **record the `sha`** — the merge in § "The merge" is pinned to it. Anything else holds: exit `1` → `held: review verdict is <verdict>; expected approve/approved` (`stale` means the head moved after the reviewer's verdict — re-review needed); exit `2` (a `gh` read failed) → `held: review verdict unreadable` — never a pass.

The helper resolves, in order: GitHub's net `reviewDecision` `CHANGES_REQUESTED` → `request-changes`; `APPROVED` → `approved` (a human, or the default `approve` reviewer mode); when `reviewDecision` is null, empty or `REVIEW_REQUIRED`, each author's latest `APPROVED`/`CHANGES_REQUESTED` review is taken (dismissed ones ignored): any `CHANGES_REQUESTED` → `request-changes`, else the reviewer login's `APPROVED` (not the PR author) → `approved` when on `headRefOid`, `stale` when on an older commit; otherwise the latest review by the reviewer login carrying the `<!-- atelier-reviewer-verdict/v1 -->` marker, valid only when its author is not the PR author and its `commit.oid`, its body `Head:` and the PR's `headRefOid` all match. A rejection in `verdict` mode is itself a COMMENTED v1 `Decision: request-changes` review (resolves to `request-changes` at that head, `stale` after a push), so it never leaves a sticky `CHANGES_REQUESTED`. It honours GitHub's net decision — if the `atelier:reviewer` agent approved but a human later marked `request-changes`, the result is `request-changes`.

Note: the `reviewer` agent runs under `GH_CONFIG_DIR=$ATELIER_CONFIG_DIR/gh/reviewer`, a distinct GitHub user from the author identity at `$ATELIER_CONFIG_DIR/gh/author`. The helper rejects any verdict authored by the PR author's login, so if the two identities resolve to the same GitHub login this guardrail keeps holding until the reviewer dir is re-authenticated with a different account.

Reviewer has no access to the repo: on a freshly-created **private** repo the reviewer identity is often not a collaborator, so it never managed to post a verdict and the helper returns `none`. Do not treat this as a normal "waiting for review" hold that will resolve on its own — it never will. When the review never landed because the reviewer could not resolve the repo, surface it as the terminal state `held: reviewer cannot access this repo — auto-merge unavailable; grant the reviewer read access (run /atelier:setup-project or add it as a collaborator)`, not an open-ended wait.

Reviewer held back from approving: in `autoMerge.reviewerApprovalMode: "approve"` mode, when the auto-mode classifier vetoes the reviewer's `--approve` as self-approval — the veto keys on the **actor/session** that coordinated both authoring and review, not on both parties being agent-controlled (see `operator-rules.md` § "PR authoring is always sub-agent work") — the denial is terminal: the reviewer posts nothing in any other form and returns `classifier-blocked` (see `agents/reviewer.md` § Output). In `"advisory"` mode the reviewer posts a plain `--comment` review without the v1 verdict marker, so the helper returns `none`. Either way this guardrail holds and the PR is withheld for a human merge — the correct, designed outcome, not a bug in the guardrail. `task-orchestrator` surfaces `classifier-blocked` before it ever reaches the `auto-merge` skill (see `agents/task-orchestrator.md` step 8), so the skill should rarely be invoked on such a PR; if it is invoked anyway, guardrail #2 holds it exactly as it would any other `none` verdict.

### 3. All CI checks succeeded

```bash
gh pr view <NN> --json statusCheckRollup --jq '.statusCheckRollup'
```

This returns an array of check objects (with `conclusion` and `status` fields). Pass condition: **every** check has `conclusion == "SUCCESS"` (or `status == "COMPLETED" && conclusion == "NEUTRAL"`, which means skipped checks). Fail if any is `FAILURE`, `CANCELLED`, `TIMED_OUT`, `STARTUP_FAILURE`, or still `IN_PROGRESS` / `QUEUED`.

If the array is **empty**, it is never a pass by itself: GitHub registers check-runs asynchronously after a push, so an empty rollup right after a push usually means "CI has not reported yet". Decide with two probes, run from the project root:

- **CI coverage of the base branch** (local, permission-free): `atelier-ci-coverage . <baseRefName>` prints `coverage=<covered|uncovered|unknown|none>` plus a `reason=` line. It reads the workflow files on `origin/<baseRefName>` and checks whether any of them triggers on pull requests into that base (an unfiltered `push` trigger also counts as covered, since it runs on the PR head commit; `push` limited to plain branch names does not; a workflow limited to `pull_request: branches: [main]` never runs for a PR into `stage`). Only a narrow, certain `on:` grammar is accepted; expressions, `workflow_call`/`workflow_run`, `branches-ignore`, path filters, `push` with `tags`/`paths`/`branches-ignore`, globs, anchors and anything unclassifiable give `unknown`. `covered` and `unknown` both mean "has CI" (fail closed); a git error, a missing helper or unparseable output is also `unknown`. `none` = no workflow files at all.
- **Required status checks on the base branch**: query the rulesets / branch-protection read **only if that call is permitted** in the session. If the call is denied, prompts, or errors, the answer is "unknown" — never assume "none".

Outcomes:

1. Coverage `covered` or `unknown`, or required checks present, or the required-checks probe could not be determined → **hold**: `held: CI not reported yet` (append `(could not determine required checks)` when the required-checks probe was the unknown one).
2. Coverage `uncovered` and no required checks → no CI will ever report on a PR into this base, so waiting is pointless: guardrail 3 **passes**. Surface it in the report: `CI: no workflow runs on PRs to <base> (<reason>), no required checks: guardrail 3 passes (no CI will report)`. When `.atelier.json` sets `autoMerge.uncoveredBaseCi` to `"hold"` (or to any value other than `"pass"`; absent means `"pass"`), this case ends terminally instead: `held: no CI runs on PRs to <base> — human merge required (autoMerge.uncoveredBaseCi: hold)` — a final state, never an endless wait.
3. Coverage `none` and no required checks (no workflow files and no required checks) → guardrail 3 **passes vacuously**. Surface it in the report: `CI: no checks configured (no .github/workflows on <base>, no required checks): guardrail 3 passes vacuously`.

→ `held: CI not green (<N> check(s) failed | <N> still running)`.
→ `held: CI not reported yet` (empty rollup on a repo with CI, or CI presence could not be determined).

Note: when the skill is invoked via `task-orchestrator`, pending CI has already been waited on by the orchestrator's pre-merge CI wait step before this skill is called. The skill remains evaluate-once; the bounded wait lives upstream. When the skill is invoked directly by the operator ("merge the PR"), pending CI still yields `held` here, and so does an empty rollup on a repo with CI (`held: CI not reported yet`) — re-invoke after CI completes or reports, or use `/atelier:babysit-prs` for unattended monitoring.

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
gh pr merge <NN> --squash --delete-branch --match-head-commit <sha> --body-file <(echo "")
```

- `--squash` is the only strategy atelier ships (PLAN.md §6).
- `--delete-branch` removes the remote branch in the same call.
- `--match-head-commit <sha>` is the `sha` recorded in guardrail #2 (the reviewed head): a push racing the gate makes the merge fail instead of landing unreviewed code. On that failure report `held: head moved after review` and do not retry.
- `--body-file <(echo "")` clears the squash-commit body to just the title — the original PR body lives on the closed PR for history; the merge commit on `main` should be terse.

Capture the merge commit SHA from the command output (it prints `Merged pull request #N (commit: <sha>)`).

## Post-merge cleanup

Once the merge succeeds:

**Best-effort task-complete cue** (fire immediately, before steps 1-5): run

```bash
"$HOME/.local/bin/atelier-notify-cue" task-complete &
```

Absolute anchor because this skill runs inside subagents whose PATH may
exclude `~/.local/bin` — same rationale as `sync-notification-hook.sh`'s
`atelier-notify` anchor. This runs **only** on a successful merge (never on
a `held` PR — it lives in this section, not in the guardrail evaluation
above). It is opt-in (silent no-op when `.notification.onTaskComplete` is
off/absent, per `atelier-notify-cue`'s own contract) and fully backgrounded:
its exit code, timing, and output are never inspected, never gate steps 1-5
below, and never appear in — or change — the `Decision:` line or the
structured report. Treat it exactly like a fire-and-forget log line.

Read `postMergeCleanup` from `<project>/.atelier.json` before running steps 4 and 5. The block and its defaults:

```jsonc
"postMergeCleanup": {
  "fastForwardBase": true,   // fast-forward the local base branch after merge
  "sweepOrphans":    true    // sweep merged task/* branches via atelier-housekeeping
}
```

Absent block or absent key → treat as `true`. Setting a key to `false` disables that step.

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

4. **Fast-forward the local base branch** (when `postMergeCleanup.fastForwardBase` is `true`). The squash commit now lives on `origin/<base>`; this step closes the gap so the operator's local ref is current without a manual pull.

   - **Resolve `<base>`**: run `git -C <project_root> ls-remote --heads origin dev`. Non-empty → `<base>` is `dev`; empty → `<base>` is `main`. (Same policy as `/next-task` step 1 and `git-wt`.)
   - **Refresh the remote-tracking ref**: `git -C <project_root> fetch origin <base>`. Safe and unconditional — updates `origin/<base>` only.
   - **Bring the local ref forward** — branch on the main worktree's checkout state:
     - If `<base>` is the branch currently checked out in the main worktree **and** `git -C <project_root> status --porcelain` is empty:
       ```bash
       git -C <project_root> merge --ff-only origin/<base>
       ```
       If `merge --ff-only` exits non-zero (diverged) → **skip and surface**: `base <base> not fast-forwarded: local ref has diverged from origin/<base>`.
     - If `<base>` is **not** checked out in any worktree:
       ```bash
       git -C <project_root> fetch origin <base>:<base>
       ```
       (The refspec form is fast-forward-only by construction; it exits non-zero if ff is impossible, which is also a skip-and-surface case.)
     - If the main worktree is **dirty** (non-empty `status --porcelain`) → **skip and surface**: `base <base> not fast-forwarded: main worktree is dirty`.
   - An already-current base is a no-op success (both commands exit 0 with `Already up to date.`).

   Note: this step always targets the **main worktree** (`<project_root>`), never the task worktree — which `auto-merge` has already removed in step 1.

5. **Orphan `task/*` sweep** (when `postMergeCleanup.sweepOrphans` is `true`). Delegates entirely to the existing `atelier-housekeeping` binary — do not hand-roll the enumeration, classification, or deletion:

   ```bash
   atelier-housekeeping --project <project_root> --yes --no-stamp
   ```

   - `--yes` non-interactively applies the sweep; this is justified by the auto-merge "the gate is the consent" authorization model (§ Authorization model above).
   - `--no-stamp` prevents the per-task sweep from silencing the operator's daily `/atelier:housekeeping` nudge (`housekeeping-last-check`).
   - No `--include-unmerged` — unmerged orphans are reported but never deleted.
   - The binary already enforces every safety rail: protected branches, open PRs, dirty worktrees, active/`[BLOCKED]`/`[OVERSIZE]` tasks (via `IN_PROGRESS.md`), unmerged-work skip, no `--force`/non-ff push.
   - The merge deleted *this* task's remote branch via `--delete-branch`; the sweep mops up **prior cycles'** local + remote `task/*` debris.
   - Capture stdout and fold counts into the structured report (§ Structured output — `Swept:` line).
   - Idempotent: re-running enumerates fresh and exits `OK: nothing to clean up`.

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
Base:          <fast-forwarded origin/<base> → <sha> | skipped — <reason> | disabled>
Swept:         <N local + M remote task/* branches removed | nothing to clean up | disabled>
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
- **Never** force-update, `reset --hard`, or stash the operator's working tree during the base fast-forward (step 4). A dirty main worktree, a diverged base, or a non-zero exit from `merge --ff-only` must skip and surface — never mutate the operator's checked-out state.
- **Never** hand-roll the orphan sweep (step 5). The only permitted deletion path is `atelier-housekeeping --project <root> --yes --no-stamp`. Do not call `git branch -d`, `git push --delete`, or `git wt rm` for branches other than the just-merged task branch — those are the binary's responsibility, not the skill's.
- **Never** let the task-complete notification cue (`atelier-notify-cue task-complete`) gate, slow, or appear in the `Decision:`/structured report. It is a fire-and-forget best-effort convenience — fired only on merge success, never on `held`, and its outcome (success, silent no-op, or failure) is never inspected.

