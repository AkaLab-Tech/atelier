# atelier

An atelier of AI agents for autonomous software delivery. You describe what you want done; atelier writes the code, runs the tests, opens a pull request, reviews it, and saves the result — without you having to know what a branch is.

## First time?

Read the **[Operator Guide](docs/operator-guide.md)** — a Jr-friendly walkthrough from zero to your first task. It covers prerequisites, the full install, setting up your first project, and writing the first task. About 30 minutes from start to finish.

## Daily use

Once atelier is installed, the typical loop is five steps. This section is the quick reference; for the long-form rationale, see the [Operator Guide](docs/operator-guide.md).

> Run `atelier --help` from any shell to list every `atelier-*` helper (`atelier-update`, `atelier-list-projects`, `atelier-remove-project`, `atelier-doctor`, `atelier-measure-merge-rate`, `atelier-uninstall`). Inside a Claude session, the same surface is reachable as slash commands under `/atelier:*`.

### 1. Set up a project (one-time per project)

```bash
cd <path-to-project>
atelier /atelier:setup-project .
```

Idempotent — safe to re-run. Creates `.claude/`, `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, project `.npmrc` (Node projects), and `.gitignore` entries. Registers the project in `$ATELIER_CONFIG_DIR/projects.json` so `task` can find it from any subdirectory.

To inspect or undo project setup:

```bash
atelier-list-projects                  # list every registered project + status
atelier-list-projects --json           # same, machine-readable
atelier-remove-project .               # deregister current project (keep files)
atelier-remove-project . --purge       # also strip atelier-added .gitignore / .npmrc entries
```

The same commands are available as `/atelier:list-projects` and `/atelier:remove-project` inside a Claude session.

### 2. Write a task in the project's `ROADMAP.md`

Add a line under `## 🎯 P1 — Next`:

```markdown
- [ ] feat add a "Share" button to the article view
- [ ] bug fix the typo on the homepage
- [ ] chore add a script to seed the database
```

Format: `[ ]` + type (`feat` / `bug` / `chore`) + short description. Optional fields per [PLAN.md §5](PLAN.md): `[~estimate]`, `[#issue-id]`, `[blocked_by:<other-task>]`.

### 3. Plan it

A task can't run until it has an approved plan. Inside a Claude session for the project:

```text
/atelier:plan-task <id>
```

atelier reads the task, looks through the codebase, and drafts a plan — the approach, which areas it touches, the acceptance criteria, and any risks. You review it and approve (or ask for changes). On approval, the plan is saved to `.plan/<id>.md` and the task is marked `[ready]`. Large tasks are split into smaller sub-tasks here, and you approve the split too.

You approve the plan **once, up front**. The task itself never stops mid-run to ask you to approve an approach — that decision is made here.

### 4. Run it

From anywhere on your machine:

```bash
task
```

Resolves the project from your cwd (longest-prefix match against the registry). If your cwd isn't inside any registered project, an `fzf` picker opens for you to pick one (sorted by `setupCompleted` desc).

The task runs end-to-end inside the Claude session you can watch live:

1. Picks the first `[ready]` item from `ROADMAP.md`, moves it to `IN_PROGRESS.md`.
2. **implementer** writes the code in a fresh worktree.
3. **tester** runs the project's tests.
4. **pr-author** opens a pull request on GitHub.
5. **reviewer** (separate GitHub identity) reads the diff + approves or requests changes.
6. **auto-merge** lands the PR if the gates from [PLAN.md §6](PLAN.md) pass (CI green + approval + nothing on the never-auto-merge list).
7. `HISTORY.md` updated; task moved out of `IN_PROGRESS.md`.

Wall time varies: a typo fix ~5 min, a small feature ~30–60 min. Leave it running and come back.

### 5. Inspect what landed

```bash
gh pr list --state merged --limit 5   # recent PRs
cat HISTORY.md                        # narrative log inside the project
gh issue list --label blocked         # tasks atelier gave up on (if any)
```

If atelier hit the retry budget (3 attempts → reset → 3 more) and gave up, it opens a GitHub issue labeled `blocked` containing every `.task-log/*.md` entry from the attempts. Read those to decide whether to retry (refine the task) or abandon (close `wontfix`).

### 6. Measure the autonomous merge rate

After ≥10 atelier-driven PRs have merged on a project:

```bash
cd <path-to-project>
atelier-measure-merge-rate --sample 10
```

Auto-detects the repo from `cwd`, and the author / reviewer identities from `$ATELIER_CONFIG_DIR/gh/{author,reviewer}`. Explicit form:

```bash
atelier-measure-merge-rate \
  --sample 10 \
  --repo OWNER/NAME \
  --author <atelier-author-handle> \
  --reviewer <atelier-reviewer-handle>
```

Output is a markdown table on stdout — copy-paste it into an issue, gist, or commit message. Exit code: `0` if ≥80% autonomous (the [PLAN.md §12 Phase 7](PLAN.md) ship gate), `1` if below, `2` on usage / runtime error.

A PR is "autonomous" iff (a) author == `--author`, (b) ≥1 approval from `--reviewer`, (c) no review comments or change-requests from foreign accounts. Full methodology and limits: [docs/measurements/autonomous-merge-rate.md](docs/measurements/autonomous-merge-rate.md).

### When something doesn't work

First step: `atelier-doctor` (or `/atelier:doctor` inside a Claude session). Each `✗` line lists the fix command; pass `--fix` to apply the auto-fixable ones (`atelier-doctor --fix` or `/atelier:doctor --fix`).

If `atelier-doctor` reports drift between the installed version and the latest release, run `atelier-update` (or `/atelier:update`) — it pulls latest, refreshes `$ATELIER_CONFIG_DIR/templates/`, and re-runs the plugin update under the atelier config root.

Symptom-indexed common problems: [docs/troubleshooting.md](docs/troubleshooting.md). Covers the dogfood findings + every operator-facing failure mode derivable from the design.

### Pause / abandon / reset

- **Pause a session:** Ctrl+C in the Claude session. The task stays in `IN_PROGRESS.md`. Run `task` again later to resume.
- **Abandon a blocked task:** close the GitHub `blocked` issue with `wontfix`, manually move the entry from `IN_PROGRESS.md` to `HISTORY.md` under an "abandoned" heading. Future work: `/abandon-task` slash command (tracked in `ROADMAP.md`).
- **Remove atelier from one project:** `atelier-remove-project <path>` (deregister only) or `atelier-remove-project <path> --purge` (also strip the `.gitignore` / `.npmrc` atelier-additions). Files under `.claude/`, `ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md` are preserved.
- **Reset everything (nuclear):** `atelier-uninstall --purge` + `rm -rf ~/atelier` + `git clone` + `./install.sh`. See the [troubleshooting doc](docs/troubleshooting.md#reset-everything-nuclear-option). Project files and `.claude/` folders inside projects are not touched.

## Already have Claude Code + GitHub set up?

`atelier` ships through the [AkaLab-Tech plugin catalog](https://github.com/AkaLab-Tech/claude-plugins). The plugin alone (without `install.sh`'s host-OS layer — `git-wt`, the `task`/`atelier` shell functions, the isolated config root) gets you the slash commands but not the full workflow:

```
/plugin marketplace add AkaLab-Tech/claude-plugins
/plugin install atelier@akalab-tech
```

The same `marketplace add` step exposes the other AkaLab-Tech plugins (e.g. install [`claude-roadmap-tools`](https://github.com/AkaLab-Tech/claude-roadmap-tools) with `/plugin install claude-roadmap-tools@akalab-tech`).

For the full setup (recommended), run [`install.sh`](install.sh) per the [Operator Guide](docs/operator-guide.md). Subsequent atelier updates use `atelier-update` (or `/atelier:update` from inside a Claude session) — it pulls the latest atelier release, refreshes `$ATELIER_CONFIG_DIR/templates/`, and runs `claude plugin update` for you. See [operator-rules.md → Keeping atelier up to date](operator-rules.md).

## Other docs

- [docs/quickstart.md](docs/quickstart.md) — command-first runbook: update, verify, onboard an existing project, set up a new one, cut a release.
- [docs/troubleshooting.md](docs/troubleshooting.md) — symptom-indexed guide for when something doesn't work.
- [operator-rules.md](operator-rules.md) — invariants every atelier session honors (update flow, epic + sub-tasks, oversize handling, config-root semantics).
- [docs/measurements/autonomous-merge-rate.md](docs/measurements/autonomous-merge-rate.md) — methodology for the Phase 7 ship-gate metric.
- [PLAN.md](PLAN.md) — full design source of truth (architecture, milestones, decisions).
- [docs/dogfood-guide.md](docs/dogfood-guide.md) — integration-test guide for end-to-end validation on a real machine.
- [ROADMAP.md](ROADMAP.md) — what's queued, what's open, what's blocked.
