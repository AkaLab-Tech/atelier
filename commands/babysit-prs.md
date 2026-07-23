---
description: One idempotent pass — enumerate every open `task/*` PR, triage each against the `auto-merge` six guardrails (read-only), drive eligible PRs to merge via `task-orchestrator` `pr-open` dispatch, and report per-PR status. Run unattended via `/loop <interval> /atelier:babysit-prs`.
argument-hint: "[--workspace] [--yes|-y]"
allowed-tools: Read, Glob, Bash(env:*), Bash(gh pr list:*), Bash(gh pr view:*), Bash(git worktree list:*), Bash(git remote:*), Bash(atelier-pr-size-check:*), Bash(atelier-setup-workspace:*), Task
---

You are running the `/atelier:babysit-prs` slash command. Your job is one **idempotent, convergent pass**: enumerate every open `task/*` PR in scope, triage each against the `auto-merge` six guardrails (read-only first), dispatch eligible PRs to `task-orchestrator` in `pr-open` resume mode, and report the outcome.

**No internal sleep/poll loop.** The command runs a single pass and returns. Unattended recurring runs are delegated entirely to the Claude Code built-in `/loop`:
- Fixed-cadence: `/loop 10m /atelier:babysit-prs` (re-runs every 10 minutes; `Esc` stops; 7-day cap).
- Self-paced: `/loop /atelier:babysit-prs` (the model picks a 1 min–1 h delay and ends the loop by not scheduling another once every PR is terminal).

The pass verdict at the end of each run tells a self-paced `/loop` whether to continue.

## Interaction mode (read once at the start)

Same contract as `/atelier:next-task` and `/atelier:resume-task`. You are **non-interactive** if any of:

- `$ARGUMENTS` contains the literal token `--yes` (whitespace-bounded).
- `$ARGUMENTS` contains the literal token `-y` (whitespace-bounded).
- The environment variable `ATELIER_AUTO` is set to a non-empty value. Probe with `env | grep -E '^ATELIER_AUTO='`.

Otherwise you are **interactive**. In non-interactive mode, never use `AskUserQuestion` — auto-resolve per the inline rule for each step, or stop with a clear error when no safe default exists. Propagate `interactive: false` to every `task-orchestrator` dispatch briefing.

## Steps

### 1. Parse arguments and determine scope

Strip `--yes` / `-y` from `$ARGUMENTS`. If the remaining text contains `--workspace`, set **scope = workspace**; otherwise **scope = project** (default).

**Project scope (default):** the current repo only. Resolve `owner/repo` from:

```bash
git remote get-url origin
```

Parse `owner/repo` from the URL (HTTPS `https://github.com/<owner>/<repo>[.git]` or SSH `git@github.com:<owner>/<repo>.git` — atelier enforces HTTPS-only cloning but the URL form still parses correctly).

**Workspace scope (`--workspace`):** find the workspace this project belongs to:

```bash
atelier-setup-workspace --which-workspace <current-dir>
```

If exit non-zero (not a registered workspace member), stop with:

> Render the labels below in the operator's chatLanguage — the English is illustrative structure, not literal output.

```text
✗ /atelier:babysit-prs --workspace: the current project is not part of a registered workspace.
   Register a workspace first with /atelier:setup-workspace, then re-run.
```

On success the command prints the workspace slug. Read `$ATELIER_CONFIG_DIR/workspaces.json`, locate the workspace by slug, and collect every `members[].path`. For each member resolve `owner/repo` with `git -C <member-path> remote get-url origin`. Members whose git remote is unreachable are listed as `skipped (remote unavailable)` in the final report; skip their PR enumeration.

### 2. Read per-pass config

Read `.atelier.json` from the current project root. Extract:

- `babysitPrs.maxPrsPerPass` (default `10`) — upper bound on how many PRs are dispatched to the orchestrator in this pass. PRs beyond the cap are reported as `deferred (pass cap)` and picked up on the next pass.
- `reviewFix.enabled` (default `true`) — whether `CHANGES_REQUESTED` PRs are actionable (dispatch for review-fix loop) or terminal (surface as `needs fix`).

For workspace scope the cap applies to the **total** dispatches across all member repos in this pass, not per-member.

### 3. Enumerate open `task/*` PRs — same filter as `status.md §3` / `next-task` step 2

For each repo in scope, run:

```bash
gh pr list --repo <owner/repo> --state open \
  --json number,title,headRefName,isDraft,reviewDecision,statusCheckRollup,mergeable,url \
  --limit 50
```

From the returned JSON, keep only records whose `headRefName` starts with `task/` — these are the §16.4 claim-registry PRs. Non-`task/*` records are **out-of-band**; note them once in the final report and ignore entirely.

Draft PRs (`isDraft: true`) are **skipped** — note them as `skipped (draft)` and never drive them regardless of any other state.

If `gh pr list` fails (unauthenticated, network error, repo not found), report `<owner/repo>: enumeration failed — <error>` and continue with the remaining repos.

Collect the surviving (non-draft, `task/*`) records into a **triage list**.

### 4. Triage each PR — read-only guardrail lens

For each PR in the triage list, apply the `auto-merge` six guardrails as a read-only lens (guardrail order from `skills/auto-merge/SKILL.md` §§ 1–6) to determine its **disposition**. The first failing guardrail sets the disposition. The goal is to classify PRs as **actionable** (dispatch to orchestrator) vs **terminal** (report to operator; never re-dispatch).

**Guardrail 1 — draft.** Already handled in step 3.

**Guardrail 2 — reviewer approved.**

- `reviewDecision == "APPROVED"` → guardrail passes; continue to guardrail 3.
- `reviewDecision == "CHANGES_REQUESTED"` → **needs-fix**. If `reviewFix.enabled` is `true` (default), this is actionable (the orchestrator's review-fix loop drives it). If `reviewFix.enabled` is `false`, disposition is terminal: `needs fix (request-changes) — reviewFix disabled`.
- `reviewDecision` is `null` or `"REVIEW_REQUIRED"` → may be genuinely unreviewed **or** the unprotected-repo quirk (reviewer ran and approved, but GitHub left `reviewDecision` empty because branch protection is not enabled). Distinguish with one additional query:

  ```bash
  gh pr view <NN> --repo <owner/repo> --json reviews \
    --jq '[.reviews[] | select(.state == "APPROVED")] | length'
  ```

  - Count == 0 → **unreviewed**. Actionable: dispatch so the orchestrator runs reviewer → auto-merge.
  - Count > 0 → **unprotected-repo hold**: an `APPROVED` review exists but `reviewDecision` is still null. **Terminal.** Disposition: `held — review gate: unprotected repo`. The operator must enable branch protection on the repo — this will never self-resolve and must **not** be re-polled. Surface it clearly; never dispatch.

**Guardrail 3 — CI.**

Using `statusCheckRollup` from step 3's JSON (no additional query needed):

- Any check with `status == "IN_PROGRESS"` or `status == "QUEUED"` → **CI-pending**. Disposition: `waiting (CI)`. Skip dispatch; the pass verdict will report `re-poll suggested` so `/loop` continues.
- Any check with `conclusion` in `FAILURE`, `CANCELLED`, `TIMED_OUT`, `STARTUP_FAILURE` → **CI-failed**. Disposition: `held — CI failed: <check-name>`. Terminal; the implementer must push a fix.
- All checks `SUCCESS`, or (`status == "COMPLETED"` and `conclusion == "NEUTRAL"`), or array is empty → guardrail passes; continue to guardrail 4.

**Mergeable check (adjacent to guardrail 3):** if `mergeable == "CONFLICTING"` for any PR, set disposition `held — conflicting (needs manual rebase)`. Terminal. Apply this check before proceeding to guardrail 4.

**Guardrail 4 — forbidden files.**

```bash
gh pr view <NN> --repo <owner/repo> --json files \
  --jq '[.files[].path | select(
    test("^package\\.json$") or
    test("^pnpm-lock\\.yaml$") or test("^package-lock\\.json$") or test("^yarn\\.lock$") or
    test("^Dockerfile$") or test("^Dockerfile\\.") or test(".*Dockerfile$") or
    test("^docker-compose\\.") or test("^docker-compose\\.(yml|yaml)$") or
    test("^\\.github/workflows/")
  )] | join(", ")'
```

Non-empty output → disposition: `held — forbidden path(s) in diff: <list>`. Terminal. Never dispatch.

**Guardrail 5 — size.**

```bash
atelier-pr-size-check --pr <NN> --project <project-root>
```

- Exit 0 → guardrail passes; continue to guardrail 6.
- Exit 1 → disposition: `held — OVERSIZE (<lines> lines / <files> files, limits <maxLines>/<maxFiles>)` (include the tool's stdout for slice hints). Terminal.
- Exit 2 → treat conservatively: `held — size check error`. Terminal.

**Guardrail 6 — pending human comments.**

```bash
gh pr view <NN> --repo <owner/repo> --json comments \
  --jq '[.comments[] | select(
    (.author.login | test("\\[bot\\]$") | not) and
    (.body | ascii_downcase | test("resolved|done|lgtm|looks good") | not) and
    (.body | startswith(":+1:") | not) and
    (.body | startswith("👍") | not)
  )] | length'
```

Count > 0 → disposition: `held — <N> pending human comment(s)`. Terminal.

**Final disposition after all guardrails pass:**

- `reviewDecision == "APPROVED"` + CI green + not conflicting + no forbidden + not oversize + no pending comments → **mergeable-now**. Actionable.
- `reviewDecision` null/`REVIEW_REQUIRED` + count of approved reviews == 0 → **unreviewed**. Actionable.
- `reviewDecision == "CHANGES_REQUESTED"` + `reviewFix.enabled: true` → **needs-fix-dispatchable**. Actionable.

### 5. Drive eligible PRs

Collect all actionable PRs (dispositions: mergeable-now, unreviewed, needs-fix-dispatchable). Apply `maxPrsPerPass`: if more than the cap, process the first N by PR number ascending; mark the rest `deferred (pass cap)`.

For each actionable PR, resolve the local worktree path:

```bash
git worktree list --porcelain
```

Find the worktree entry whose `branch` field equals `refs/heads/<headRefName>`. If found, use its `worktree` field as `<worktree_path>`; if not found, use `<none>`.

**Dispatch sequentially** — complete each orchestrator `Task` invocation before starting the next. Sequential dispatch prevents concurrent `gh pr merge` calls from racing on overlapping GitHub state (e.g. two PRs whose branches both touch the same file and whose merge order matters).

Each dispatch is a `Task` invocation of `atelier:task-orchestrator` with this briefing:

```text
resume_mode: pr-open
task_id:     <numeric id from headRefName — e.g. "25" from "task/25-babysit-prs">
branch:      <headRefName>
worktree_path: <resolved path or <none>>
pr_number:   <NN>
pr_url:      <url>
interactive: <true | false>
caller:      /atelier:babysit-prs (fan-out pass — re-enter at reviewer → auto-merge only;
             do NOT re-run implementer / tester / pr-author)

cwd reminder: Your Bash cwd is NOT inside the worktree. Every Bash call targeting the
worktree must use git -C <worktree_path>, gh --repo <owner/repo>, or
cd <worktree_path> && ... prefix. See operator-rules.md § Operating against the task worktree.
```

Record the orchestrator's returned status for the final report.

### 6. Produce the per-pass report

> Render the labels below in the operator's chatLanguage — the English is illustrative structure, not literal output.

```text
== babysit-prs report ==
Pass scope:  project (<owner/repo>)  |  workspace (<slug>: <N> repos)
PRs found:   <N> open task/* PR(s)  [<M> draft + <K> out-of-band skipped]

▶ Driven this pass  (omit section if empty)
  • #<NN> <title>  [<headRefName>]
    Disposition:  mergeable-now | unreviewed | needs-fix (request-changes)
    Outcome:      merged <sha> | held — <guardrails> | request-changes (<N> findings) | ...

▶ Waiting — re-poll next pass  (omit section if empty)
  • #<NN> <title>  [<headRefName>]
    Reason:  waiting (CI) — <check-name> <IN_PROGRESS|QUEUED>

▶ Terminal holds — operator action required  (omit section if empty)
  • #<NN> <title>  [<headRefName>]
    Held:    <reason>
    Action:  <short actionable instruction>

▶ Skipped  (omit section if empty)
  • #<NN> <title> — draft
  • #<NN> <title>  [<headRefName>] — out-of-band
  • #<NN> <title>  [<headRefName>] — deferred (pass cap: <maxPrsPerPass>)

Pass verdict: terminal | re-poll suggested (<N> PR(s) waiting on CI)
```

**Pass verdict** — the self-paced `/loop` convergence signal:
- `terminal` — no open `task/*` PR is in a transient state; a self-paced `/loop` may stop without scheduling another iteration.
- `re-poll suggested` — at least one PR is `waiting (CI)`; keep looping. PRs in terminal holds are NOT re-poll triggers — they need operator action, not time.

## Hard refusals

- **Never** dispatch the orchestrator for a PR whose triage disposition is terminal (CI-failed, conflicting, forbidden files, OVERSIZE, pending human comments, unprotected-repo review-gate, never-reviewed after unprotected-repo detection). The triage front-end exists to prevent fruitless re-dispatch cycles.
- **Never** touch non-`task/*` PRs. They are listed once as `skipped (out-of-band)` and then ignored.
- **Never** merge directly. All state-changing writes go through the orchestrator's `reviewer → auto-merge` path. babysit-prs is a fan-out + convergence layer, not an independent merge actor.
- **Never** implement an internal sleep/poll loop. One pass, one return. `/loop` is the recurring mechanism.
- **Never** dispatch orchestrators in parallel. Drive one PR at a time — sequential dispatch prevents concurrent merges from racing on shared GitHub state.
- **Never** weaken or skip a guardrail. All six are applied faithfully in triage; the orchestrator's `auto-merge` skill remains authoritative and short-circuits on the first failure regardless.
- **Never** merge the never-auto-merge set: draft, non-`task/*`, forbidden files, oversize, pending human comments, `CHANGES_REQUESTED` with `reviewFix.enabled: false`, unprotected-repo review-gate, CI-failed, conflicting.
- **Never** re-poll an unprotected-repo review-gate hold. Once an `APPROVED` review exists and `reviewDecision` is still null, that is a configuration problem (missing branch protection), not a transient state. Report it once as terminal; do not count it as `re-poll suggested`.
- **Never** honour a `decisionPolicy: ask` override by prompting in non-interactive mode. In non-interactive mode, stop with a clear error when no safe default exists — never guess, never prompt.
