# atelier operator rules

These rules apply to **every task** you run in an atelier-managed project.
They are loaded into context automatically by atelier's `SessionStart` hook
at the start of each session. Authoritative versions live in
[PLAN.md §4](https://github.com/AkaLab-Tech/atelier/blob/main/PLAN.md) (deps),
§6 (push/PR/merge), §7 (agents), §8 (failure recovery).

## Dependency installs (§4)

Before any `pnpm add`:

1. **Self-question** — does stdlib or an existing utility already solve this?
2. **Compare** ≥ 2 alternatives. Prefer: more downloads, maintained in the
   last 6 months, minimal transitive deps.
3. **Justify** the choice explicitly in the commit message or PR description.
4. **Never** install a package < 7 days old.
5. **Never** install a package with reported moderate+ vulnerabilities.

Steps 4 and 5 are also enforced by the per-project `.npmrc` that
`/setup-project` writes (`minimum-release-age=10080`,
`audit-level=moderate`) — but you must reason about them explicitly, not
rely on the npmrc as a silent backstop.

Use the `safe-install` skill (invoked automatically by the dependency-install
slash commands, or directly when an agent proposes `pnpm add`). The skill
walks the five rules above explicitly: `pnpm view <pkg>` → decision → `pnpm
add <pkg>` → `pnpm audit`.

## Push, PR, and merge gates (§6)

### Never commit to protected branches

Never `git commit` (or `git push`) to `main`, `master`, `develop`,
`staging`, or any release branch — including in **target projects**
atelier manages, where the operator may be the sole contributor and
skipping the PR loop for a one-line fix looks tempting.

For every code change, create a branch first:

1. `git checkout -b task/<id>-<slug>` for ROADMAP-driven tasks. The
   `/next-task` flow does this automatically via the `git-wt` skill.
2. `git checkout -b chore/<short-name>` for non-roadmap chores
   (migrations, dependency bumps, cleanups, infrastructure).
3. `git checkout -b docs/<topic>` for documentation-only changes.
4. `git checkout -b fix/<short-name>` for non-roadmap bug fixes.

Commit on that branch. Push it. Open a PR. Merge via the project's
review/merge gates (squash, post-merge branch cleanup).

This applies even when there is no team to review the PR — the audit
trail and the "Revert this PR" affordance are independent of team
size, and the discipline prevents accidentally pushing un-reviewed
changes to `origin main` when the operator (or an agent) is in a
hurry. **No exceptions for "throwaway" target projects:** atelier's
own dogfood repos have already produced one violation of this rule
(HISTORY → M4.12); the bar is the same everywhere.

The atelier permission model (PLAN.md §3) blocks **pushes** to
protected branches via `Bash(git push * main)` deny rules in
`settings.template.json`. The **commit-level** rule here is a
discipline the operator + agents enforce by always working on a
non-protected branch before the first `git commit`. A future
milestone may add a `PreToolUse` hook that enforces this at commit
time; until then, the rule is prompt-level only.

### Before pushing

Push to `origin task/<id>-<slug>` only when **all** of these pass:

1. Lint.
2. Type-check.
3. Unit + integration tests.

Commit messages must follow Conventional Commits.

### Before opening the PR

In addition to all push preconditions:

1. e2e tests (Playwright) pass with screenshots attached.
2. PR description is auto-generated and includes: the roadmap reference, a
   summary, a validation checklist, and the screenshots.

### Auto-merge gate

Auto-merge **only** when:

1. CI is green, **and**
2. The independent `reviewer` agent (Opus, fresh context) approves per its
   checklist.

**Never auto-merge** — fall back to the human operator — when any of the
following applies:

- Changes to `package.json` or `pnpm-lock.yaml`.
- Changes to `Dockerfile` or `docker-compose*`.
- Changes to `.github/workflows/**`.
- PR exceeds 500 lines changed.
- Human comments are pending on the PR.
- Reviewer marks `request-changes`.

**Merge strategy:** squash.

**Post-merge:** delete the remote branch, remove the local worktree, mark
the roadmap item `[x]`.

## Failure recovery (§8)

Every attempt writes a log to `<worktree>/.task-log/<timestamp>-<attempt>.md`
containing: the initial hypothesis, the actions taken, the final error, and
your reasoning on what went wrong.

**Retry budget — fixed at 6 total attempts:**

1. Attempts 1–3 — retry, feeding prior logs back as context.
2. After 3 failed attempts → **reset the worktree** (wipe and start over
   from a clean state, still feeding the prior logs forward).
3. Attempts 4–6 (post-reset) — retry.
4. After 6 total failed attempts → **hard stop**: open a `blocked` issue on
   GitHub with all logs attached, notify the operator, move to the next task.

**Do not silently extend the retry budget.** Six is the cap.

## Agents you interact with (§7)

The orchestrator routes specialists in this order for a typical task:

`task-orchestrator` (Opus, plans the task) → `implementer` (Sonnet) →
`tester` (Sonnet) → `e2e-runner` (Sonnet) → `pr-author` (Sonnet) →
`reviewer` (Opus, fresh context, no carryover).

On hard stop, `unblocker` (Sonnet) opens the blocked GitHub issue with the
attached logs.

Entry point: the `/next-task` slash command picks the highest-priority
unblocked item from the project's `ROADMAP.md` and routes it through this
chain.
