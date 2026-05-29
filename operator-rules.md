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
- PR exceeds the per-project size budget: by default both `>200 lines` **and** `>10 files` after exempting tests / lockfiles / migrations (run `atelier-pr-size-check` to see the exact count and any slicing hints). Either dimension alone is fine; only PRs that breach both axes fall back. Per-project override via `<project>/.atelier.json`.
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

## Invoking `claude` from atelier scripts (M7.1.F29)

Atelier maintains a config root **separate** from the operator's personal
Claude Code config: `$ATELIER_CONFIG_DIR` (default `~/.claude-work/`) vs.
the personal `~/.claude/`. This separation exists so atelier's autonomous-
mode rules and installed plugins don't conflict with the operator's
personal settings.

**Every `claude` invocation from an atelier script must prefix
`CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR"`**, e.g.:

```bash
CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude plugin list --json
CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude plugin install <id>
CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude plugin update <id>
CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude plugin marketplace update <name>
```

Without the prefix, `claude` reads/writes the operator's personal config
root, so atelier-managed plugins appear "not installed" and updates land
in the wrong cache. The `atelier()` shell function (installed by
`install.sh` into the shellrc hook) already sets the env var for
interactive sessions; the issue only applies to scripts that invoke
`claude` directly as a subprocess.

The same rule applies to suggestions the doctor / setup-project / similar
scripts surface to the operator as copy-paste commands.

## Keeping atelier up to date (M6.1)

Atelier ships as a Claude Code plugin **plus** a host-OS layer (the
`atelier-*` helpers symlinked into `~/.local/bin/` by `install.sh`).
Both have to be refreshed when upstream releases a new version:

- `atelier-update` (terminal command): pulls `origin/main` on the
  clone, refreshes the instantiated templates in `$ATELIER_CONFIG_DIR/templates/`,
  and triggers `claude plugin update` for the agents/skills/commands
  Claude Code loads at session start. Refuses dirty trees and
  non-`main` branches.
- `/atelier:update` (slash command): wraps the helper so the
  permission-diff prompt resolves through Claude Code's I/O. Use this
  whenever the upstream release touches `settings.template.json` — the
  helper will show you what changed and ask before applying.
- `atelier-doctor --fix` (M7.1.F30): after the standard health check
  report, auto-execute the runnable fix commands the doctor would
  otherwise have asked you to copy-paste (typically the
  `CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR claude plugin update ...`
  calls when the plugin is out of date). Manual fixes — paths,
  re-run-install.sh instructions, hand-edit suggestions — still print
  as text for the operator to act on. Useful when you trust the
  doctor's diagnosis and don't want to re-paste each command.
  Available also as `/atelier:doctor --fix` from inside Claude Code.

When `settings.template.json` changes, the prompt shows:

- `+` lines: permissions the agent will **gain** (more autonomy in
  those areas).
- `-` lines: permissions the agent will **lose** (more prompting in
  those areas).
- An impact summary so you can read what changes about your
  day-to-day before deciding.

If you decline (`N`): the clone has the new template but
`$ATELIER_CONFIG_DIR/templates/settings.template.json` keeps the old
permissions. Re-run from an interactive shell when you're ready to
accept.

After any successful update, **restart open Claude Code sessions** —
the plugin cache is refreshed but each session loads its agents /
skills / commands at start.

## Epic + sub-tasks (M4.24.a)

Large tasks that would produce an oversize PR can be expressed as an
**epic** with sub-tasks. The epic acts as a container; each sub-task is
an independent unit the orchestrator claims, implements, and PRs
separately. See PLAN.md §5 for the full format.

Shape (in `ROADMAP.md`):

```markdown
- [ ] `feat` Epic: Landing page editor `#42` `~6h`
  - [ ] `feat` schema + API endpoints `#42a` `~2h`
  - [ ] `feat` admin form UI `#42b` `~2h` `blocked_by:#42a`
  - [ ] `feat` public landing renderer `#42c` `~2h` `blocked_by:#42a`
```

Rules to remember:

- The **epic line is never claimed** directly — the orchestrator
  descends into sub-tasks and picks the first eligible one.
- Sub-task ids use a letter suffix under the epic's id: `#42a`, `#42b`,
  ... Use `blocked_by:#<sibling-id>` between siblings when the order
  matters (schema before UI, etc.).
- The epic's `[x]` is **auto-derived** when all sub-tasks are `[x]`.
  Do not flip the epic checkbox manually — the `task-discovery` skill
  computes it on read.
- `[OVERSIZE]` and `[BLOCKED]` markers on a sub-task apply only to that
  sub-task. The same markers on the epic line apply to the whole epic.

When does the orchestrator auto-decompose? M4.24.b (a follow-up to this
milestone) wires the `task-decomposer` agent into the orchestrator's
plan step: tasks that trip oversize-likely heuristics (`~estimate > 4h`,
acceptance criteria with > 5 distinct bullets, title containing
`epic`/`system`/`framework`/`platform`, or mention of ≥ 3 top-level
dirs) are decomposed automatically before `implementer` runs. The
operator can:

- **Pre-empt**: write the epic structure manually in `ROADMAP.md`.
  The orchestrator sees it is already shaped as an epic and skips the
  decomposer step entirely.
- **Override**: invoke `/atelier:slice-task <id>` to ask the decomposer
  to act on a task the heuristics did not detect.
- **Disable**: set `taskDecomposer.enabled: false` in
  `<project>/.atelier.json` to turn off the automatic pass project-wide.

## Permission model: layer 3 is auto-mode (M2.8)

Atelier ships with **Claude Code's native auto permission mode** as the layer-3 fallback for the static allow/deny/ask matrix in `templates/settings.template.json`. `install.sh` writes `{"permissions": {"defaultMode": "auto"}}` into `$ATELIER_CONFIG_DIR/settings.json`; `atelier`-launched sessions inherit auto-mode while the operator's personal `~/.claude/` config stays untouched.

What auto-mode does, for the operator:

- **Bash commands the matrix did not enumerate** (e.g. a new `gh` subcommand the template doesn't list yet, a `git wt ls` alias the matcher can't expand statically) are evaluated by Anthropic's classifier instead of prompting. Most pass; the residual that don't are the high-risk surface where the prompt is still the right answer.
- **Shell control flow** (`for`/`while`/`if`, compound `&&`/`||`, command substitution) — what used to trip *"Contains shell syntax (string) that cannot be statically analyzed"* — is now classifier-judged. The friction symptom that originated M2.6 is gone.

What the static matrix still does, unchanged:

- `permissions.deny` from the project template **always wins** — the classifier is a second gate that fires only after the deny list. `git push --force*`, `rm -rf /`, the never-auto-merge surface, etc. are blocked categorically regardless of auto-mode.
- `permissions.allow` from the project template still **short-circuits** the classifier — known-safe commands skip the round-trip and run immediately.

What changed at install time:

- `templates/settings.template.json` no longer carries `"defaultMode": "acceptEdits"`. Project-level `defaultMode` overrides user-level by normal merge precedence; leaving it would have masked the user-level `auto`. Allow / deny / additionalDirectories unchanged.
- `atelier-doctor` checks `$ATELIER_CONFIG_DIR/settings.json` has `permissions.defaultMode == "auto"`. `atelier-doctor --fix` writes the setting if missing — useful for hosts that upgraded across the v0.8.0 cut without re-running `install.sh`.

Empirical reproducibility (Q4 of the spike): the classifier adds ~200–400 ms per Bash call; reads and in-worktree edits skip it entirely. Token overhead is ~10–15% on a long refactor. Acceptable for atelier's typical task wall-time.

Full design notes + the three open-questions that validated this adoption: [docs/research/permission-layer-3.md](docs/research/permission-layer-3.md) (M2.6 spike + M2.7 addendum).

If you ever want to disable auto-mode for an atelier session and fall back to `acceptEdits`, edit `$ATELIER_CONFIG_DIR/settings.json` and change `.permissions.defaultMode` to `acceptEdits` (or remove the key). The deny list and allow list keep working unchanged.
