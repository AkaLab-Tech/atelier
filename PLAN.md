# AI-Operated Workstation — Plan

> Source of truth for design. All decisions below are agreed unless marked otherwise.
> Status legend: ✅ agreed · 🟡 proposed · ❓ open decision · ✂️ removed

---

## 0. Goal

Enable a non-technical operator to deliver software work end-to-end (features, tests, bug fixes, e2e validation, PRs) by only talking to Claude. The operator never needs to know what a branch, a test, or a PR is. They open a session, ask "what's next?", and the AI executes autonomously.

This repo (`atelier`) is the single artifact the operator clones. `install.sh` leaves the machine fully configured.

**Separation of concerns:** the install configures the machine for an **operator profile**. It does NOT overwrite the developer's personal `~/.claude/CLAUDE.md`. The operator's Claude environment is intentionally more permissive (autonomous pushes, dependency installs under guardrails) than a typical developer's, because the goal is zero-intervention task execution.

---

## 1. Architecture overview ✅

### Two-layer configuration

- **Global** — distributed as a **Claude Code native plugin**. This repo ships `.claude-plugin/plugin.json` + `marketplace.json` so the operator installs everything with `/plugin marketplace add` + `/plugin install atelier`. Claude Code auto-discovers `agents/`, `skills/`, `commands/`, `hooks/` and `CLAUDE.md` from the plugin root. Hooks and scripts reference files via `$CLAUDE_PLUGIN_ROOT` — never hardcoded paths.
- **Host-OS layer** (handled by `install.sh` before the plugin is installed): things that can't live inside a Claude plugin — base deps, Claude Code itself, GitHub auth, `git-wt` external package, global `.npmrc`, `.env*` in git excludes, `fnm`/alias shellrc hooks, git identity.
- **Per project** (created by `/setup-project <path>`): `ROADMAP.md`, `.claude/settings.json` (generated from `settings.template.json`), `.claude/CLAUDE.md` with project-specific rules, optional project-specific agents/skills that override globals.

### Isolation guarantees

- Each `task` invocation anchors to the current working directory's project.
- Agents in project A do not see context or permissions of project B.
- All edits happen inside the task's **worktree**. The slash command `/next-task` instantiates a fresh `.claude/settings.json` from `settings.template.json`, injecting the worktree path into `additionalDirectories` and `Edit`/`Write` patterns. On task close the settings revert to the base (no editable paths).

### Why a plugin and not symlinks

The native plugin system gives us: (a) one-liner install/update via `/plugin marketplace update atelier`, (b) semver via `plugin.json`, (c) `$CLAUDE_PLUGIN_ROOT` for clean multi-checkout support, (d) auto-discovery by convention. It does **not** increase lock-in vs symlinks — both depend on Claude Code loading skills/agents/hooks; the manifest just formalizes the same contract. Reference: [Yeachan-Heo/oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) validated this pattern at scale.

---

## 2. Installation flow (`install.sh`) ✅

The operator runs **one command** and answers at most **two prompts** (Claude login + GitHub login).

### Phase A — Preparation (no interaction)
1. Detect OS (macOS/Linux) and architecture.
2. Verify / install base dependencies via Homebrew (mac) or apt (linux):
   - `git`, `gh`, `fnm`, `pnpm`, `jq`, `fzf`, `playwright`.
   - **Node** is managed by `fnm` (Rust-based, fast startup, native `.nvmrc` support). Each project pins its Node version in a `.nvmrc` file at its root; `fnm` auto-switches on `cd` via `eval "$(fnm env --use-on-cd)"` (added to the operator's shellrc in Phase C). If a project has no `.nvmrc`, `fnm` falls back to the latest LTS installed at provisioning time.
   - **`pnpm`** is the package manager of choice — never fall back to `npm`. Installed via `corepack enable` once Node is available.
   - **`fzf`** enables the interactive picker for `git wt switch` (see Phase C, `git-wt` install).
3. Install Claude Code if not present (official installer).

### Phase B — Authentication (only human interaction)
4. Claude Code login: launch `claude /login`, opens browser.
5. GitHub login — **HTTPS only, no SSH keys ever**:
   ```bash
   gh auth login --hostname github.com --git-protocol https --web \
     --scopes "repo,workflow,project,read:org"
   gh auth setup-git   # registers gh as git credential helper (idempotent)
   ```
   Token stored in OS keychain. All slash commands must clone via HTTPS (`gh repo clone` or `https://github.com/...`).

### Phase C — Host-OS configuration + plugin install

Phase C is split in two: **C.1** handles what can't live inside a Claude Code plugin (host binaries, shell, git config, external tools). **C.2** installs the atelier plugin itself via Claude Code's native plugin system.

#### C.1 — Host-OS configuration (no interaction)

6. Install **`git-wt`** (external, [Miguelslo27/git-wt](https://github.com/Miguelslo27/git-wt)) non-interactively for Claude:
   ```bash
   git clone https://github.com/Miguelslo27/git-wt.git /tmp/git-wt
   /tmp/git-wt/install.sh --skill-for=claude
   ```
   Installs the binary to `~/.local/bin/git-wt`, injects the shell wrapper into `~/.zshrc`/`~/.bashrc`, and drops the Claude skill at `~/.claude/skills/git-wt/`.
7. Install global `.npmrc` guardrails:
   ```ini
   ignore-scripts=true          # block postinstall/preinstall scripts
   minimum-release-age=10080    # 7 days in minutes — anti supply-chain
   audit-level=moderate         # pnpm audit fails on moderate+ vulns
   ```
8. Ensure `.env*` is in git's global excludes (`core.excludesFile`).
9. Configure git identity (prompt only if missing).
10. Add shell hooks and aliases to `~/.zshrc`/`~/.bashrc`:
    - `eval "$(fnm env --use-on-cd)"` → auto-switch Node version per project's `.nvmrc`.
    - `task` → opens a Claude session that auto-invokes `/next-task` for the current project (detected from cwd).
    - `task-status` → shows the operator's open PRs.

#### C.2 — Claude Code plugin install (last step)

11. Install the `atelier` plugin from this repo's marketplace manifest. This replaces the old symlink-into-`~/.claude/` approach. Two delivery options (implementation detail, tested during Phase 1):
    - **Preferred** — `install.sh` drives Claude Code non-interactively to run:
      ```
      /plugin marketplace add AkaLab-Tech/atelier
      /plugin install atelier@atelier
      ```
    - **Fallback** — `install.sh` prints the two commands for the operator to paste into their next `claude` session.

    Once installed, Claude Code auto-discovers `agents/`, `skills/`, `commands/`, `hooks/` and `CLAUDE.md` from `$CLAUDE_PLUGIN_ROOT`. Subsequent updates use `/plugin marketplace update atelier` — no re-symlinking.

12. Final verification: `claude --version`, `gh auth status`, `git wt help`, presence of the `atelier` plugin in `~/.claude/plugins/` (or Claude's equivalent cache), and a call to the bundled `/doctor` slash command (see §7) to sanity-check the plugin surface. Print ✅/❌ per check.

---

## 3. Permissions matrix ✅

Lives in `settings.template.json`. `/next-task` instantiates a per-task `settings.json` that injects the current worktree path to scope `Edit`/`Write`.

**`defaultMode`: `acceptEdits`**

### 🟢 Allow
- Read: `Read(<worktree>/**)`, Glob, Grep.
- Edit / Write: restricted to the current task's worktree (including docs).
- Git read: `status`, `diff`, `log`, `show`, `branch`, `blame`, `fetch`, `ls-files`.
- Git write: `add`, `commit`, `checkout -b`, `switch`, `worktree`, `stash`.
- Git push: `git push origin task/*` **only**. Deny everything else.
- GitHub CLI: `gh issue *`, `gh pr create/view/list/comment`, `gh pr merge` (only under §6 conditions), `gh project *`, `gh repo clone/view`.
- pnpm: `install`, `add`, `remove`, `update`, `run *`, `test`, `exec *`, `audit`, `view`.
- Tests / lint / types: `vitest`, `jest`, `pytest`, `playwright test`, `eslint`, `prettier`, `tsc`, `biome`.
- Filesystem in worktree: `ls`, `mkdir -p`, `mv`, `cp`.
- Network: **allowlist-based**, grown organically as needed.

### 🔴 Deny (absolute)
- `Bash(rm -rf:*)` and variants touching `/`, `~`, `*`.
- `Bash(sudo:*)`.
- `Bash(git push --force*)`, `git push -f*`.
- `Bash(git push * main)`, `* master`, `* develop`, `* staging`.
- `Bash(git reset --hard*)` on non-task branches.
- `Bash(git config --global*)`.
- `Bash(gh auth logout*)`, `gh auth refresh*`.
- `Bash(gh repo delete*)`.
- `Bash(gh api POST:*)`, `gh api PATCH:*`, `gh api DELETE:*`. Revisit only if a concrete use case appears.
- `Bash(pnpm publish*)`, `npm publish*`.
- `Bash(curl*|*sh*)`, `wget*|*sh*`.
- `Read(~/.ssh/**)`, `~/.aws/**`, `~/.gnupg/**`, `~/.config/gh/**`.
- `Edit(~/.zshrc)`, `~/.bashrc`, `~/.ssh/**`.
- `Edit(.github/workflows/**)`.
- `Edit(package.json)` and `Edit(pnpm-lock.yaml)` — always via `pnpm add/remove/update`.
- Any `Edit`/`Write` outside the current task's worktree.

### 🟡 Ask
- `Edit(.env*)` — allowed locally, never committed (hook blocks commits that include `.env*`).
- `Edit(Dockerfile)`, `Edit(docker-compose*)` — allowed but must document the change and validate it doesn't break the build.
- `Bash(gh pr close*)`.

---

## 4. Dependency install rules ✅

The agent must follow these before any `pnpm add`:

1. **Self-question**: does stdlib / existing utilities already solve this?
2. **Compare** ≥2 alternatives. Prefer: more downloads, maintained in last 6 months, minimal transitive deps.
3. **Justify** the choice in commit message / PR description.
4. **Never** install a package < 7 days old (enforced by `.npmrc minimum-release-age`).
5. **Never** install with reported vulnerabilities (enforced by `.npmrc audit-level`).
6. Use `/safe-install <pkg>` which wraps: `pnpm view` → decision → `pnpm add` → `pnpm audit`.

---

## 5. ROADMAP.md format ✅

Markdown with nested checkboxes + inline metadata. One file per project, written by the product owner. **Source of truth** — not synced to GitHub Issues (for now).

```markdown
# Roadmap — <project>

## 🔥 P0 — Blockers

- [ ] `bug` Login redirects to 404 after OAuth `#23` `~2h`
  - Repro: Chrome, new account, click "Login with Google" → 404.
  - Acceptance: redirects to dashboard + e2e test covers flow.

## 🎯 P1 — Next

- [ ] `feat` Export reports to CSV `~4h` `blocked_by:#23`
  - Button "Export" at `/reports`, downloads CSV with active filters applied.

## 💭 P2 — Backlog

- [ ] `chore` Upgrade Vite to v6 `~1h`
```

**Conventions:**
- Sections ordered by priority: P0 → P1 → P2.
- Item line: `- [ ] <type> <title> [<id>] [~estimate] [blocked_by:...]`.
- Types: `bug`, `feat`, `chore`, `docs`, `refactor`.
- Sub-bullets: context, repro, acceptance criteria.
- `[x]` marks completed tasks (kept for history).

The agent picks the first unchecked item of the highest-priority section with no open `blocked_by` dependency.

---

## 6. Push / PR / Merge rules ✅

### Push
Push to `origin task/<id>-<slug>` when and only when:
1. Lint passes.
2. Type-check passes.
3. Unit + integration tests pass.
4. Commit message ready (Conventional Commits style).

### PR
Open a PR (not draft) when:
1. All push preconditions are met, **and**
2. e2e (Playwright) passes with screenshots attached, **and**
3. Description auto-generated: roadmap reference, summary, validation checklist, screenshots.

### Merge — option B (auto-merge after agent review) with guardrails

Auto-merge when:
1. CI green, **and**
2. Independent `reviewer` agent (Opus, fresh context) approves per checklist.

**Never auto-merge** (falls back to human operator):
- Changes to `package.json` / `pnpm-lock.yaml`.
- Changes to `Dockerfile` / `docker-compose*`.
- Changes to `.github/workflows/**`.
- PR exceeds 500 lines changed (threshold adjustable).
- Human comments pending on PR.
- Reviewer marks `request-changes`.

**Merge strategy:** squash.
**Post-merge:** delete remote branch, remove local worktree, mark roadmap item `[x]`.

---

## 7. Agents, skills, slash commands ✅

### Agents (with model assignment)

| Agent | Model | Purpose |
|---|---|---|
| `task-orchestrator` | Opus | Plans the task, routes to specialists |
| `implementer` | Sonnet | Writes feature / fix code |
| `tester` | Sonnet | Writes and runs unit + integration tests |
| `e2e-runner` | Sonnet | Drives Playwright, captures screenshots |
| `pr-author` | Sonnet | Opens PR, writes description, posts status |
| `reviewer` | Opus | Independent review before merge |
| `unblocker` | Sonnet | Handles failure recovery + blocking issues |

### Skills (global)

Auto-discovered by Claude Code from the plugin's `./skills/` directory (no explicit manifest entries needed).

- `task-discovery` — parse `ROADMAP.md`, pick next task.
- `git-wt` — worktree per task. **Sourced externally** from [Miguelslo27/git-wt](https://github.com/Miguelslo27/git-wt); installed in Phase C step 6. Not maintained in this repo.
- `pr-flow` — branch → commit → push → PR.
- `visual-validation` — Playwright screenshots.
- `safe-commit` — lint + typecheck + tests before commit.
- `safe-install` — audit + `pnpm view` before `pnpm add`.

### Slash commands (global)

- `/next-task` — full pickup-to-PR flow.
- `/resume-task <id>` — continue after interruption.
- `/finish-task` — finalize PR.
- `/status` — what's in progress, blocked, awaiting review.
- `/setup-project <path>` — initialize a new project with `.claude/settings.json`, `ROADMAP.md`, `.gitignore` entries. **Idempotent**: writes `~/.claude/.atelier-config.json` with `setupCompleted` (ISO timestamp) + `setupVersion`. Re-running on a configured project skips the wizard and offers a "reconfigure" flow instead. Pattern borrowed from [`omc-setup`](https://github.com/Yeachan-Heo/oh-my-claudecode/blob/main/skills/omc-setup/SKILL.md).
- `/doctor` — health check. Verifies: plugin version vs. latest, no legacy hooks leaking into `~/.claude/settings.json`, `git-wt` binary present, `fnm` hook active in shellrc, `.npmrc` guardrails in place, per-project `.atelier-config.json` consistency. Borrowed from [`omc-doctor`](https://github.com/Yeachan-Heo/oh-my-claudecode/tree/main/skills/omc-doctor).

---

## 8. Failure recovery ✅

**Per-attempt logging:** each attempt writes to `<worktree>/.task-log/<timestamp>-<attempt>.md` with:
- Initial hypothesis.
- Actions taken.
- Final error.
- Reasoning on what went wrong.

**Retry logic:**
1. Attempts 1–3: retry, feeding prior logs as context.
2. If 3 attempts fail → **reset**: wipe worktree, start over from a clean state (still feeding logs).
3. Attempts 4–6 (post-reset): retry.
4. If 6 total attempts fail → **hard stop**: open a `blocked` issue on GitHub with all logs, notify operator, move to next task.

On successful merge, logs are attached to the PR as an artifact.

---

## 9. Update flow (`update.sh`) ✅

1. `git pull` inside the `atelier` repo.
2. Detect changed files since last pull.
3. Apply only the deltas (re-symlink changed files, patch `.npmrc` if changed, etc.).
4. **If `settings.template.json` changed**, prompt the operator with a detailed permission diff:

```
⚠️  The update changes the agent's permissions

NEW permissions (the agent will now do this without asking you):
  + Bash(pnpm audit:*)       → audit vulnerabilities
  + Edit(docker-compose.yml) → modify container config

REMOVED permissions (the agent can no longer do this):
  - Bash(gh api POST:*)      → GraphQL mutations blocked

Impact on your day-to-day:
  - Docker-related tasks now progress without asking (previously asked).
  - If a task needs to POST to the GitHub API, it will get blocked and ask you.

Apply? [y/N]
  · If you are NOT 100% sure, answer N and talk to the Product Owner.
```

---

## 10. Secrets handling ✅

- Project secrets live in `.env` files **inside each project** (never committed).
- `install.sh` adds `.env*` to git's global excludes.
- `PreToolUse` hook blocks any `git add` / `git commit` that touches `.env*`, even if `.gitignore` is missing.
- Revisit if more complex secret management is needed (1Password CLI, keychain, etc.).

---

## 11. Out of scope (v1) and deferred to v2

### Out of scope (v1)

- Multi-repo coordination in a single task.
- Deployment / release management.
- Cost monitoring / per-task budget caps.
- Visual regression (baseline diff) — v2. v1 uses raw screenshots.
- Bidirectional ROADMAP ↔ GitHub Issues sync.

### Deferred to v2 — borrowed patterns from OMC

Concrete ideas to revisit once v1 is stable. All sourced from [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode).

| # | Idea | OMC reference | Value for atelier |
|---|---|---|---|
| v2.1 | **Skill auto-injector hook** (`UserPromptSubmit`) that picks skills by context signals so agents load only what they need | [`scripts/skill-injector.mjs`](https://github.com/Yeachan-Heo/oh-my-claudecode/blob/main/scripts/skill-injector.mjs) | Smaller context per turn, lower cost |
| v2.2 | **Router skill with subcommands** (`/atelier setup\|doctor\|update\|reconfigure`) | [`skills/oh-my-claudecode`](https://github.com/Yeachan-Heo/oh-my-claudecode/tree/main/skills/oh-my-claudecode) | Single entry point, less command clutter |
| v2.3 | **`PermissionRequest` Bash hook** that decides permissions dynamically based on the current worktree/state, replacing the static `settings.template.json` instantiation | [`scripts/permission-handler.mjs`](https://github.com/Yeachan-Heo/oh-my-claudecode/blob/main/scripts/permission-handler.mjs) | More precise than static patterns; reacts to runtime state |
| v2.4 | **Project-memory hooks** (`SessionStart` + `PostToolUse`) that auto-detect project state and persist learnings per project | [`scripts/project-memory-session.mjs`](https://github.com/Yeachan-Heo/oh-my-claudecode/blob/main/scripts/project-memory-session.mjs) + [`scripts/project-memory-posttool.mjs`](https://github.com/Yeachan-Heo/oh-my-claudecode/blob/main/scripts/project-memory-posttool.mjs) | Replaces manual registry writes with automatic observation |
| v2.5 | **`/learner` + `/skillify`** — extract reusable patterns from successful tasks into new skills | [`skills/learner`](https://github.com/Yeachan-Heo/oh-my-claudecode/tree/main/skills) family | The reviewer loop becomes a learning loop |
| v2.6 | **Node.js hook dispatcher** (`scripts/run.cjs`): all hooks call a wrapper that handles timeouts, fail-open, Node binary resolution, Windows compatibility | [`scripts/run.cjs`](https://github.com/Yeachan-Heo/oh-my-claudecode/blob/main/scripts/run.cjs) | Robustness + portability; required if we add the v2 hooks above |

---

## 12. Implementation plan

Phases are sequential. Each phase ends with a verifiable milestone.

### Phase 1 — Foundation
**Deliverables:**
- M1.1 Repo skeleton: `.claude-plugin/`, `agents/`, `skills/`, `commands/`, `hooks/`, `templates/`, `scripts/`.
- M1.2 Plugin manifest: `.claude-plugin/plugin.json` (name, version, description, `skills: "./skills/"`) and `.claude-plugin/marketplace.json`. Validate the plugin loads in a clean Claude Code install via `/plugin marketplace add <local-path>` → `/plugin install atelier@atelier`.
- M1.3 `install.sh` doing **only** Phase A (deps) + Phase B (auth) + Phase C.1 (host-OS: git-wt, `.npmrc`, `.env*` excludes, git identity, shell hooks) + Phase C.2 (drive Claude Code to install the plugin, or print the paste-in commands).
- M1.4 `settings.template.json` with the full allow/deny/ask matrix from §3 (stays as a template; per-task instantiation is a Phase 2 skill).
- M1.5 Global operator `CLAUDE.md` at repo root with the rules agents must follow (dep install §4, push/PR/merge §6).

**Done when:** a fresh Mac runs `install.sh`, logs into both services, finishes with the `atelier` plugin installed and verifiable via `/doctor` showing all ✅.

### Phase 2 — Single-project workflow
**Deliverables:**
- M2.1 Agents: `task-orchestrator`, `implementer`, `tester`, `pr-author`.
- M2.2 Skills: `task-discovery` (parses ROADMAP §5), `pr-flow`, `safe-commit`, `safe-install`. (`git-wt` skill ships from the external package.)
- M2.3 Slash commands: `/next-task`, `/status`, `/finish-task`, `/setup-project` (idempotent via `.atelier-config.json`), `/doctor`.
- M2.4 Hooks: `block-env-commit`, `safe-commit` (lint+test pre-commit).

**Done when:** in a toy repo with 3 tasks in ROADMAP.md, `task` picks the first one, implements it, opens a PR, and reports back — without any operator intervention after the initial `task`.

### Phase 3 — Validation + review
**Deliverables:**
- M3.1 `e2e-runner` agent + `visual-validation` skill.
- M3.2 `reviewer` agent (Opus) with explicit checklist.
- M3.3 Auto-merge logic with all guardrails from §6.

**Done when:** the toy-repo flow ends with a merged PR (squash), closed roadmap item, deleted branch, cleaned worktree.

### Phase 4 — Robustness
**Deliverables:**
- M4.1 Retry logic with log persistence (§8).
- M4.2 `unblocker` agent: hard stop + blocking issue creation.
- M4.3 Resume flow: `/resume-task` continues after interruption.

**Done when:** injecting a failing test into the toy repo causes 3 retries, then a reset, then 3 more retries, then a clean blocking issue + operator notification.

### Phase 5 — Multi-project
**Deliverables:**
- M5.1 Project registry at `~/.claude-work/projects.json`.
- M5.2 `/setup-project` bootstraps a new project.
- M5.3 `task` alias resolves current project from cwd (fallback to menu if not inside one).

**Done when:** two toy projects coexist, `task` in each picks from its own ROADMAP.md, agents don't cross-pollinate.

### Phase 6 — Update + documentation
**Deliverables:**
- M6.1 `update.sh` with incremental diff + permissions-prompt UX (§9).
- M6.2 Operator guide (Jr-friendly).
- M6.3 Product owner guide (how to write ROADMAP.md).
- M6.4 Troubleshooting doc.

**Done when:** a Jr following only the operator guide can clone, install, and run a full task cycle on a pre-configured project.

### Phase 7 — End-to-end validation
**Deliverables:**
- M7.1 Dogfood on a real (non-toy) project.
- M7.2 Iterate on the network allowlist based on actual usage.
- M7.3 Measure: % of tasks reaching merged state without intervention.

**Done when:** ≥ 80% of a sample of 10 real tasks complete to a merged PR autonomously.

---

## 13. Next step

Start **Phase 1**. First piece: repo skeleton + `install.sh` Phase A (dependencies).
