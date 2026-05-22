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
`staging`, or any release branch.

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
size.

The atelier permission model (PLAN.md §3) blocks **pushes** to
protected branches via `Bash(git push * main)` deny rules in
`settings.template.json`. The **commit-level** rule here is a
discipline enforced by always working on a non-protected branch
before the first `git commit`.

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

## Operating against the task worktree (cwd vs paths)

Your subprocess sandbox inherits its current working directory from the parent invocation. When `/atelier:next-task` (or another caller) dispatches you to work on a task, the worktree has been created at `<worktree-path>` (the absolute path arrives in your briefing) — but **your cwd is NOT inside it**. The cwd is whatever the operator started Claude Code from (typically the main repo or the operator's home dir).

This matters because the harness's `additionalDirectories` list in `<worktree>/.claude/settings.json` only governs which paths your `Read` / `Edit` / `Write` tools may touch. It does **not** affect what `cwd` your `Bash` subprocesses see. A naked `git status` or `pnpm test` run via `Bash` operates against the cwd it inherited — not the worktree.

**Hard rule — every `Bash` invocation that targets the worktree must use one of these patterns:**

1. **`-C <worktree-path>` flag** for git: `git -C /abs/worktree status`, `git -C /abs/worktree add ...`, `git -C /abs/worktree commit ...`.
2. **`--dir <worktree-path>` flag** for pnpm: `pnpm --dir /abs/worktree install`, `pnpm --dir /abs/worktree test`, `pnpm --dir /abs/worktree exec ...`.
3. **`--repo <owner/name>` flag** for gh (cwd-independent by design): `gh pr create --repo owner/name`, `gh pr view <num> --repo owner/name`.
4. **`cd <worktree-path> && <command>` prefix** when no path-flag exists for the tool: `cd /abs/worktree && npx some-tool`. Bash subprocesses are short-lived (one shell per `Bash` invocation), so the `cd` does not persist across calls — every call needs the prefix.

`Read` / `Edit` / `Write` accept absolute paths and are unaffected by cwd — keep using them with the absolute `<worktree-path>/...` form.

**Never** assume cwd equals worktree. If you find yourself writing `git add .` or `pnpm test` without one of the patterns above, stop and rewrite.

**When you dispatch a specialist** via the `Task` tool, the specialist inherits the same cwd you did (the harness does not propagate cwd through `Task`). Include `<worktree-path>` in the specialist's briefing **and** remind them this rule applies to their Bash calls too. Defense in depth — the specialist also reads `operator-rules.md` via `SessionStart`, but explicit briefing is the authoritative signal.

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
