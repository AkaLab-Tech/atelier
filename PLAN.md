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

- **Global** — distributed as a **Claude Code native plugin**. This repo ships `.claude-plugin/plugin.json` only; the marketplace catalog (`marketplace.json`) that lists `atelier` lives in a dedicated repo, [AkaLab-Tech/claude-plugins](https://github.com/AkaLab-Tech/claude-plugins), alongside every other AkaLab-Tech plugin. The operator installs everything with `/plugin marketplace add AkaLab-Tech/claude-plugins` + `/plugin install atelier@akalab-tech`. Claude Code auto-discovers `agents/`, `skills/`, `commands/`, `hooks/`, `CLAUDE.md` and `.mcp.json` from the plugin root. Hooks and scripts reference files via `$CLAUDE_PLUGIN_ROOT` — never hardcoded paths.
- **Host-OS layer** (handled by `install.sh` before the plugin is installed): things that can't live inside a Claude plugin — base deps, Claude Code itself, GitHub auth, `git-wt` external package, `.env*` in git excludes, `fnm`/alias shellrc hooks, git identity.
- **Per project** (created by `/setup-project <path>`): `ROADMAP.md`, `.claude/settings.json` (generated from `settings.template.json`), `.claude/CLAUDE.md` with project-specific rules, `.npmrc` (pnpm supply-chain guardrails — see §4), optional project-specific agents/skills that override globals.

### Isolation guarantees

- Each `task` invocation anchors to the current working directory's project.
- Agents in project A do not see context or permissions of project B.
- All edits happen inside the task's **worktree**. The slash command `/next-task` instantiates a fresh `.claude/settings.json` from `settings.template.json`, injecting the worktree path into `additionalDirectories` and `Edit`/`Write` patterns. On task close the settings revert to the base (no editable paths).

### Why a plugin and not symlinks

The native plugin system gives us: (a) one-liner install/update via `/plugin marketplace update akalab-tech` (refreshes every AkaLab-Tech plugin in the catalog), (b) semver via `plugin.json`, (c) `$CLAUDE_PLUGIN_ROOT` for clean multi-checkout support, (d) auto-discovery by convention. It does **not** increase lock-in vs symlinks — both depend on Claude Code loading skills/agents/hooks; the manifest just formalizes the same contract. Reference: [Yeachan-Heo/oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) validated this pattern at scale.

---

## 2. Installation flow (`install.sh`) ✅

The operator runs **one command** and answers at most **two prompts** (Claude login + GitHub login).

### Phase A — Preparation (no interaction, plus one optional Chrome prompt)
1. Detect OS (macOS/Linux) and architecture.
2. Verify / install base dependencies via Homebrew (mac) or apt (linux):
   - `git`, `gh`, `fnm`, `pnpm`, `jq`, `fzf`. (Playwright moved to M3.1 / `e2e-runner`: only operators running e2e tasks need the ~250 MB browser bundle.)
   - **Node** is managed by `fnm` (Rust-based, fast startup, native `.nvmrc` support). Each project pins its Node version in a `.nvmrc` file at its root; `fnm` auto-switches on `cd` via `eval "$(fnm env --use-on-cd)"` (added to the operator's shellrc in Phase C). If a project has no `.nvmrc`, `fnm` falls back to the latest LTS installed at provisioning time.
   - **`pnpm`** is the package manager of choice — never fall back to `npm`. Installed via `corepack enable` once Node is available.
   - **`fzf`** enables the interactive picker for `git wt switch` (see Phase C, `git-wt` install).
3. Install Claude Code if not present via the official native installer: `curl -fsSL https://claude.ai/install.sh | bash`. Lands the signed native binary at `~/.local/bin/claude` and self-updates in the background. The `curl|sh` pattern is in the agent-level deny-list (PLAN.md §3), but `install.sh` runs in the operator's terminal before atelier's agent layer is active, so it is out of that scope.
4. **Optional: system Chrome for `mcp__plugin_atelier_playwright`** (M3.4). Detect Chrome platform-appropriately: macOS — `[ -d "/Applications/Google Chrome.app" ] || [ -d "$HOME/Applications/Google Chrome.app" ]`; Linux — `command -v google-chrome[-stable]`. If present, log and continue. If absent **and** the operator is interactive (TTY + no `--yes`), prompt `Install Google Chrome now via 'brew install --cask google-chrome'? [Y/n]` on macOS — Y installs via brew cask, N skips with the install command for later. On Linux, surface the manual install commands (`apt`/`rpm` snippets) — too distro-dependent to automate generically. In non-interactive mode (`--yes` or no TTY), warn and continue without installing. The MCP server returns an actionable error on first call if Chrome is still missing, and `/doctor` check 4.f re-warns persistently.

### Phase B — Authentication (only human interaction)
4. Claude Code login: run `claude auth login`, which opens a browser tab for OAuth. (The `/login` slash command — described in earlier drafts — only works inside an interactive `claude` session; the CLI subcommand achieves the same flow from a shell script.) Idempotency: `claude auth status` exits `0` if already authenticated, so the script skips the browser when the operator re-runs `install.sh`.
5. GitHub login — **HTTPS only, no SSH keys ever**, and **two distinct atelier-isolated identities** stored inside atelier's config root (M5.0.1):
   ```bash
   # 5a — atelier-author: every operational gh call (pr-author, commits,
   #      push, gh pr create, gh issue) runs under this identity.
   GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author"   gh auth login --hostname github.com --git-protocol https --web --skip-ssh-key --scopes "repo,workflow,project,read:org"
   GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author"   gh auth setup-git   # registers gh as git credential helper (idempotent). The helper is dynamic — it reads $GH_CONFIG_DIR at invocation time, so the operator's normal shell (no GH_CONFIG_DIR exported) falls back to ~/.config/gh/ untouched.

   # 5b — atelier-reviewer: only the `reviewer` agent uses this, and only for
   #      gh pr view/review/comment. Must authenticate with a DIFFERENT
   #      GitHub user than 5a — same-identity self-review makes GitHub
   #      downgrade the approval to a comment (Finding #11 from dogfood-1).
   GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/reviewer" gh auth login --hostname github.com --git-protocol https --web --skip-ssh-key --scopes "repo,workflow,project,read:org"
   ```
   `--skip-ssh-key` is defense-in-depth — `--git-protocol https` already pins HTTPS, but skipping the SSH key prompt prevents any residual SSH affordance. Token stored under each role's config dir (no OS-keychain dependency for the isolated installs). All slash commands must clone via HTTPS (`gh repo clone` or `https://github.com/...`). Idempotency: `GH_CONFIG_DIR=... gh auth status --hostname github.com` exits `0` if already authenticated, so re-runs of `install.sh` don't re-prompt. Phase B ends with `GH_CONFIG_DIR=$ATELIER_CONFIG_DIR/gh/<role> gh api user --jq .login` against each role; if the two logins resolve to the same GitHub user, install.sh **warns loudly** (without aborting) so the operator knows Finding #11 will persist for this install.

   Install.sh never touches the operator's `~/.config/gh/` — that is the operator's personal `gh` state, independent of atelier. The `task()` shellrc alias exports `GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author"` for the session, so every agent inherits the author identity by default; `reviewer` overrides this inline with `GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/reviewer"`.

Phase B is the only interactive step in `install.sh`. When the script runs without a TTY (CI, piped install, `ssh host 'bash install.sh'` without `-t`), Phase B auto-skips with a clear message that lists the manual commands the operator should run from a real terminal. Phases C.1/C.2 continue regardless, so the rest of host-OS configuration still lands.

### Phase C — Host-OS configuration + plugin install

Phase C is split in two: **C.1** handles what can't live inside a Claude Code plugin (host binaries, shell, git config, external tools). **C.2** installs the atelier plugin itself via Claude Code's native plugin system.

#### C.1 — Host-OS configuration (no interaction)

6. Install **`git-wt`** (external, [AkaLab-Tech/git-wt](https://github.com/AkaLab-Tech/git-wt)) non-interactively for Claude:
   ```bash
   git clone https://github.com/AkaLab-Tech/git-wt.git /tmp/git-wt
   /tmp/git-wt/install.sh --skill-for=claude
   ```
   Installs the binary to `~/.local/bin/git-wt`, injects the shell wrapper into `~/.zshrc`/`~/.bashrc`, and drops the Claude skill at `~/.claude/skills/git-wt/`.
7. **pnpm supply-chain guardrails are per-project, not global.** `install.sh` no longer touches `~/.npmrc`. The `.npmrc` file with
   ```ini
   ignore-scripts=true          # block postinstall/preinstall scripts
   minimum-release-age=10080    # 7 days in minutes — anti supply-chain
   audit-level=moderate         # pnpm audit fails on moderate+ vulns
   ```
   is written by `/setup-project` (M2.3) into each atelier-managed project. **Rationale:** writing the guardrail globally during `install.sh` broke unrelated host-level tooling on the maintainer's machine (Claude Code's own native-binary postinstall). Per-project scope keeps the guardrail close to where atelier actually executes `pnpm add`, while leaving the operator's host pnpm/npm usage untouched.
8. Ensure `.env*` is in git's global excludes (`core.excludesFile`).
9. Configure git identity (PR #9 refinement): always prompt for global `user.name` and `user.email`, showing the currently configured values (`git config --global --get user.name`/`user.email`) as defaults so the operator can accept with Enter or overwrite. When there is no TTY (CI / piped install) and both values are already set, keep them silently; when there is no TTY and either is missing, print a clear hint with the manual `git config --global …` commands and continue.
10. Add shell hooks and aliases to `~/.zshrc`/`~/.bashrc`:
    - `eval "$(fnm env --use-on-cd)"` → auto-switch Node version per project's `.nvmrc`.
    - `task` → opens a Claude session that auto-invokes `/next-task` for the current project (detected from cwd).
    - `task-status` → shows the operator's open PRs.

#### C.2 — Claude Code plugin install (last step)

11. Install the `atelier` plugin from the central AkaLab-Tech marketplace catalog ([AkaLab-Tech/claude-plugins](https://github.com/AkaLab-Tech/claude-plugins)). This replaces the old symlink-into-`~/.claude/` approach. `install.sh` calls the `claude plugin` CLI verbs (the slash-command form `/plugin …` only works inside an interactive `claude` session; the CLI subcommand achieves the same flow from a shell script, same pattern as the `claude auth login` refinement for Phase B):
    - **Preferred** — `install.sh` runs non-interactively:
      ```bash
      claude plugin marketplace add AkaLab-Tech/claude-plugins
      claude plugin install atelier@akalab-tech
      ```
      Idempotency: `claude plugin marketplace list --json` is checked for the `akalab-tech` entry before the `add`, and `claude plugin list --json` is checked for `atelier@akalab-tech` before the `install`.
    - **Fallback** — when `claude` is missing from PATH or `claude auth status` reports unauthenticated (e.g. Phase B skipped due to no TTY), `install.sh` prints both commands and continues so the operator can paste them later from a real session.

    Once installed, Claude Code auto-discovers `agents/`, `skills/`, `commands/`, `hooks/` and `CLAUDE.md` from `$CLAUDE_PLUGIN_ROOT`. Subsequent updates use `claude plugin marketplace update akalab-tech` followed by `claude plugin update atelier@akalab-tech` — no re-symlinking. The same `marketplace add` also exposes the other plugins in the catalog, so step 12 below does not need to add it again.

12. Install the **`claude-roadmap-tools`** plugin (separate repo, [AkaLab-Tech/claude-roadmap-tools](https://github.com/AkaLab-Tech/claude-roadmap-tools); see ROADMAP.md M1.6). Provides `/create-roadmap`, `/adopt-roadmap`, `/migrate-roadmap` and the `roadmap-tracking-flow` skill — kept sovereign in its own repo so projects that do not use the full atelier stack can install it standalone. Tracking-format transformations live here, not in atelier: `/adopt-roadmap` normalizes a repo whose tracking files exist but are not canonical (e.g. an `IN_PROGRESS.md` used as a multi-phase tracker). atelier's `/setup-project` only **detects** that case and **delegates** to `/adopt-roadmap` (M7.1.F50) — it never rewrites tracking files inline, preserving the sovereignty boundary. Step 11 already added the `akalab-tech` marketplace, so only the install command is needed here:
    - **Preferred** — `install.sh` runs non-interactively:
      ```bash
      claude plugin install claude-roadmap-tools@akalab-tech
      ```
      Same idempotency hinge: `claude plugin list --json` is checked for `claude-roadmap-tools@akalab-tech` before the `install`.
    - **Fallback** — same condition as step 11 (`claude` missing or unauthenticated); `install.sh` prints the command and continues.

    Subsequent updates use `/plugin marketplace update akalab-tech` followed by `/plugin update claude-roadmap-tools@akalab-tech`, and are surfaced by `/doctor` (see §7). The `claude-roadmap-tools` plugin code still lives in its own GitHub repository; the catalog entry in `AkaLab-Tech/claude-plugins` references it via the `github` plugin source so each plugin retains independent versioning and release cadence (same sovereignty model as `atelier` and the external `git-wt`).

13. Final verification: `claude --version`, `gh auth status`, `git wt help`, presence of the `atelier` **and** `claude-roadmap-tools` plugins in `~/.claude/plugins/` (or Claude's equivalent cache), and a call to the bundled `/doctor` slash command (see §7) to sanity-check the plugin surface. Print ✅/❌ per check.

---

## 3. Permissions matrix ✅

Lives in `settings.template.json`. `/next-task` instantiates a per-task `settings.json` that injects the current worktree path to scope `Edit`/`Write`.

**Defense-in-depth.** This matrix is the **first** security layer: it gates *which tool* an agent can invoke. It does **not** inspect the *content* the tool would act on — `Edit(<worktree>/**)` is allowed for any file in the worktree regardless of what is being written to it. The **second** layer is the `PreToolUse` hook suite delivered in M2.4 (`scan-edit-write`, `scan-git-add`, `safe-package-change`, `block-env-commit`, `safe-commit`): those hooks intercept allowed tool calls and validate intent (proposed file contents, staged git diff, `package.json` changes before `pnpm install`/`add`/`update`/`run`). A **third** layer — LLM-backed semantic judgment for commands layers 1+2 cannot enumerate (shell composition, context-dependent destinations, novel binaries) — is deferred; the A/B/C choice (native auto-mode, custom `PreToolUse` hook, or both) is the M2.6 spike, and the chosen implementation lands as §11 v2.3. Neither layer alone is enough — a leaky static matrix would let through forbidden tools, and a leaky hook layer would miss tools that should never have been invoked. Both must hold for a real attack to land.

**`defaultMode`: `acceptEdits`**

### 🟢 Allow
- Read: `Read(<worktree>/**)`, Glob, Grep.
- Edit / Write: restricted to the current task's worktree (including docs).
- Git read: `status`, `diff`, `log`, `show`, `branch`, `blame`, `fetch`, `ls-files`.
- Git write: `add`, `commit`, `checkout -b`, `switch`, `worktree`, `stash`.
- Git push: `git push origin task/*` **only** — plus `git push --force-with-lease origin task/*` to reconcile a diverged task branch (lease-guarded; never a hard `--force`, never a remote-branch delete, never a protected branch). Deny everything else.
- GitHub CLI: `gh issue *`, `gh pr create/view/list/comment`, `gh pr merge` (only under §6 conditions), `gh project *`, `gh repo clone/view`, `gh auth status` (read-only identity check). Also `Bash(GH_CONFIG_DIR=* gh ...)` for the reviewer's atelier-isolated identity override (M5.0.1): `gh auth status`, `gh api user`, `gh pr view/list/diff/review/comment`.
- pnpm: `install`, `add`, `remove`, `update`, `run *`, `test`, `exec *`, `audit`, `view`.
- Tests / lint / types: `vitest`, `jest`, `pytest`, `playwright test`, `eslint`, `prettier`, `tsc`, `biome`.
- Filesystem in worktree: `ls`, `mkdir -p`, `mv`, `cp`.
- Network: **allowlist-based**, grown organically as needed.

### 🔴 Deny (absolute)
- `Bash(rm -rf:*)` and variants touching `/`, `~`, `*`.
- `Bash(sudo:*)`.
- `Bash(git push --force)`, `Bash(git push --force *)`, `git push -f*` — hard force is denied. **Exception:** `git push --force-with-lease origin task/*` is allowed (the safe, lease-guarded way to reconcile a diverged task branch; refuses if the remote moved unexpectedly, and preserves the open PR). The lease form is *not* a hard `--force` and is the only force variant `pr-author` may use.
- `Bash(git push * --delete *)`, `git push * -d *`, `git push origin :*` — deleting a remote branch is denied. A diverged `task/*` branch is reconciled with `--force-with-lease`, **never** by delete-then-re-push (destructive, orphans the open PR, and the auto-mode classifier blocks it mid-chain).
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

### 🛡️ Threat-model addendum for M2.4 content-scanning hooks

The static matrix above gates *which* tools an agent invokes. The M2.4 `PreToolUse` hook suite gates *what* those allowed tools act on. This subsection enumerates the exact pattern catalogue each content-scanning hook checks, the rationale for each pattern, and the action it takes (block / warn / ask). This is the catalogue an implementer must validate before any matcher code lands.

**Conventions used below:**
- **Block:** the hook returns non-zero and the tool call is rejected outright with the printed message.
- **Warn:** the hook returns 0 but prints a visible warning to the operator's terminal; the tool call proceeds.
- **Ask:** the hook returns 2 (the documented "ask" exit code from the Claude Code hooks reference) so the operator must confirm before the tool call proceeds.

Each hook MUST log its decision (matched pattern, file, action) to `<worktree>/.task-log/hook-decisions.jsonl` for post-mortem auditing. Logs persist across the retry budget (§8) so the `unblocker` agent can see why hooks fired.

#### `scan-edit-write` — `PreToolUse` on `Edit` / `Write`

Scans the **proposed** file contents (the new content the agent wants to write), not the file as it currently is on disk. Runs on every `Edit` and `Write` call inside the worktree.

| Pattern (description) | Match heuristic | Action |
|---|---|---|
| Unsanitised `eval(<input>)` in JS/TS | regex: `\beval\s*\(\s*(req|input|query|params|stdin|process\.argv)` | **Block** |
| Unsanitised `exec` / `execSync` of user input in Node | regex: `\b(exec\|execSync\|spawnSync)\s*\(\s*\$?\{?(req|input|query|params)` | **Block** |
| Hardcoded secrets — generic high-entropy string assignment | regex: `(secret\|token\|api[_-]?key\|password)\s*[:=]\s*["'`][A-Za-z0-9+/=]{24,}["'`]` AND value Shannon entropy ≥ 4.5 | **Block** |
| Hardcoded secrets — known credential prefixes | substring match for any of: `sk-`, `gho_`, `github_pat_`, `ghp_`, `xoxb-`, `xoxp-`, `AKIA`, `ASIA`, `AIza`, `-----BEGIN RSA PRIVATE KEY-----`, `-----BEGIN OPENSSH PRIVATE KEY-----` | **Block** |
| SQL injection shape — string template with user input | regex: `["'`].*SELECT.*\$\{(req\|input\|query\|params)` (case-insensitive) | **Warn** |
| Shell injection shape — string template into `exec` / `spawn` | regex: `(exec\|spawn).*\$\{(req\|input\|query\|params)` | **Warn** |
| Python `eval` / `exec` of user input | regex: `\b(eval\|exec)\s*\(\s*(request\|input\|sys\.argv\|stdin)` | **Block** |
| Disabled security headers / CSP relaxation | regex (case-insensitive): `content-security-policy.*unsafe-eval\|x-frame-options:?\s*allow-all` | **Warn** |

**Known false-positive surfaces (operator/maintainer should be aware before tuning):**
- Test fixtures intentionally containing planted patterns (e.g. a JS test asserting that `eval(input)` is rejected). Mitigation: skip the scan when the file path matches `**/__fixtures__/**` or `**/test*/**/*.fixture.*` or has a leading `// scan-edit-write: skip` comment in the first 5 lines.
- Educational / demo code in `docs/**` or `README*`. Mitigation: skip when path matches `docs/**` or basename starts with `README`.

#### `scan-git-add` — `PreToolUse` on `git add`

Scans the **proposed staged contents** — the diff of what would land in the index. Computed via `git diff --cached --no-color` after a synthetic dry-run, then matched line-by-line.

Reuses every pattern from `scan-edit-write` (a `git add` of a file the agent already wrote may include patterns that slipped past the Edit/Write scan — e.g. they were already in the file before atelier started touching it). Adds these secret-detection patterns that are tuned for diff context rather than full-file context:

| Pattern (description) | Match heuristic | Action |
|---|---|---|
| Added `.env*` file (any path) | filename match `**/.env*` in the staged paths | **Block** (same outcome as the existing `block-env-commit` hook; this duplicate is intentional defence-in-depth) |
| Added file under `**/secrets/**` or `**/credentials/**` | filename glob match | **Block** |
| AWS access key in an added line | regex on added lines: `\b(AKIA\|ASIA)[0-9A-Z]{16}\b` | **Block** |
| GitHub fine-grained PAT in an added line | regex: `\bgithub_pat_[0-9a-zA-Z_]{82}\b` | **Block** |
| Generic 32+ char high-entropy added-line content not in a code-fence or comment | Shannon entropy ≥ 4.5 over a run of ≥ 32 base64-ish characters, line not starting with `#`, `//`, `/*`, `*` | **Ask** |
| Private key block in added lines | substring match for `-----BEGIN (RSA\|OPENSSH\|EC\|DSA\|PGP\|ED25519) PRIVATE KEY-----` | **Block** |

**Known false-positive surfaces:**
- Snapshot test files (`*.snap`, `__snapshots__/**`) often contain high-entropy strings that aren't secrets. Skip these paths.
- Lock files (`pnpm-lock.yaml`, `package-lock.json`, `yarn.lock`) — already in the static matrix deny list (M1.4) for `Edit`, but staged via `git add` if the agent ran `pnpm install` and then naively added everything. Skip the entropy check for lock files.

#### `safe-package-change` — `PreToolUse` on `pnpm install` / `add` / `update` / `run`

Triggers before pnpm modifies dependencies or runs scripts. Analyses (a) the proposed `package.json` (after the agent's prospective change), and (b) for `pnpm add`/`update`, the published `package.json` of each new direct dependency fetched from `https://registry.npmjs.org/<pkg>`.

| Pattern (description) | Match heuristic | Action |
|---|---|---|
| `scripts.preinstall` / `scripts.postinstall` / `scripts.prepare` newly added or changed | JSON-diff comparison of the `scripts` object; flag any new or changed entry in these three fields | **Ask** |
| Lifecycle script that fetches and executes remote code | regex on the script value: `(curl\|wget).*\|\s*(sh\|bash\|zsh\|fish)` or `eval.*\$\(curl` or `node -e ['"]require\(.https` | **Block** |
| Dependency name with typosquatting shape against known top packages | Levenshtein distance ≤ 2 against a curated list (start with: react, vue, angular, lodash, axios, express, next, vite, typescript, jest, vitest, eslint, prettier, playwright). Exact match is fine; near-match triggers. | **Ask** |
| Dependency name with non-ASCII characters | regex: `[^\x00-\x7F]` in package name | **Block** (homoglyph-attack defence) |
| `bin` entry pointing outside the package directory | any `bin` field value containing `../` or starting with `/` (other than published-package-relative paths) | **Block** |
| Direct dependency with `<` 7 days since first publish on npm | query `npm view <pkg> time --json`, compare oldest version's timestamp to current time | **Block** (mirrors the per-project `.npmrc minimum-release-age=10080` from §4 but applies at the hook level too, defense-in-depth) |
| `dependencies` / `devDependencies` entry with a git URL or tarball URL outside `https://registry.npmjs.org` | substring check on the version specifier | **Ask** |
| Removal of an existing lockfile (`pnpm-lock.yaml` not present after the operation) | filesystem check post-dry-run | **Block** |

**Known false-positive surfaces:**
- Legitimate post-install builds (native modules like `sharp`, `puppeteer`, `playwright`, `node-gyp` consumers). Mitigation: maintain a small allowlist of known-good packages whose lifecycle scripts are expected; the hook downgrades the action from Block to Ask for allowlisted packages.
- New typosquat-shaped names from packages adopting a brand close to a popular one (false positive). Mitigation: Ask, not Block — the operator decides.

#### Implementation guardrails

- Each hook script lives at `hooks/<name>.sh` and is registered in `hooks/hooks.json` with an explicit `matcher` for the tool it intercepts. No global "PreToolUse on everything" — each matcher is narrow.
- Scripts MUST be idempotent. Re-running a scan on the same content MUST produce the same decision.
- Scripts MUST exit within 2 seconds on the median input (10 KB file or 200-line diff). The hook system enforces a 10 s hard timeout; staying well under it leaves room for the operator's slower hardware.
- Pattern catalogues live in `hooks/patterns/<hook>.json` (one JSON file per hook), so adding a pattern doesn't require touching the hook script. Each pattern entry has `name`, `description`, `regex` (or `match_type`), `action`, and `rationale` fields. The catalogue file is what an operator reviews when triaging a false positive.
- Every hook decision is appended to `<worktree>/.task-log/hook-decisions.jsonl` with: `timestamp`, `hook`, `tool_call`, `matched_pattern`, `action`, `message`. The `unblocker` agent reads this log when escalating to a blocked issue.

---

## 4. Dependency install rules ✅

The agent must follow these before any `pnpm add`:

1. **Self-question**: does stdlib / existing utilities already solve this?
2. **Compare** ≥2 alternatives. Prefer: more downloads, maintained in last 6 months, minimal transitive deps.
3. **Justify** the choice in commit message / PR description.
4. **Never** install a package < 7 days old (enforced by the per-project `.npmrc minimum-release-age=10080` written by `/setup-project`).
5. **Never** install with reported vulnerabilities (enforced by the per-project `.npmrc audit-level=moderate`).
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
- Item line: `- [ ] [ready] <type> <title> [<id>] [~estimate] [blocked_by:...]` — the `[ready]` token is optional and sits immediately after the checkbox (see **Planning gate** below).
- Types: `bug`, `feat`, `chore`, `docs`, `refactor`.
- Sub-bullets: context, repro, acceptance criteria.
- `[x]` marks completed tasks (kept for history).
- `[ready]` marks a task whose plan a product lead has approved; only `[ready]` tasks are claimable by the orchestrator (see **Planning gate**).

**`blocked_by` — intra-repo and cross-repo (§15):**
- Intra-repo (unchanged): `blocked_by:#<id>` references another task id in the *same* `ROADMAP.md`; resolved within that file.
- Cross-repo (workspaces only): `blocked_by:<token>#<id>` references task `#<id>` in a **sibling member** of the same workspace, where `<token>` is that member's workspace token (§15.2). Resolved **offline** against the sibling's `HISTORY.md` (the task is "merged" when it appears there as a closed entry with a PR reference) via `atelier-resolve-dep`. A `<token>` that is not a workspace member, or an `<id>` that appears nowhere in the sibling's tracking, **refuses** the dependent task — it is never silently eligible.
- Mixed/multiple allowed: `blocked_by:#23,backend#5`.
- The cross-repo `<id>` must match the **task id convention** the sibling repo uses in its `HISTORY.md`, not a GitHub PR number (the two coincide only if the repo uses PR numbers as task ids).

### Epic + sub-tasks (M4.24.a)

A single task that would produce a PR larger than the project's size budget (see §6) can be expressed as an **epic** with sub-tasks. The epic acts as a container; each sub-task is an independent unit the orchestrator can claim, implement, and PR separately.

```markdown
- [ ] `feat` Epic: Landing page editor `#42` `~6h`
  - [ ] `feat` schema + API endpoints `#42a` `~2h`
  - [ ] `feat` admin form UI `#42b` `~2h` `blocked_by:#42a`
  - [ ] `feat` public landing renderer `#42c` `~2h` `blocked_by:#42a`
```

**Epic conventions:**

- Epic title prefix is the literal token `Epic:` followed by the human-readable title.
- Sub-tasks are indented **two spaces** under the epic line. Same `- [ ] <type> ...` shape as a top-level item, but the `<id>` uses a **letter suffix** under the epic's id (`#42a`, `#42b`, `#42c`, ...).
- Sub-tasks may reference each other via `blocked_by:#<sibling-id>`. Cross-epic `blocked_by` (a sub-task blocked by a different epic's task) is allowed but discouraged — usually a signal that the split is wrong.
- The epic line's checkbox `[ ]` / `[x]` is **derived**, not edited by the operator: it auto-flips to `[x]` when every sub-task is `[x]`. Tooling (`task-discovery` skill) computes this on read; nothing writes the epic checkbox manually.
- The epic's `~estimate` should be the sum of its sub-tasks' estimates. Drift is harmless but suggests the split changed shape from what was planned.

### Planning gate (M4.30) ✅

Planning is a separate, explicit, **product-lead-owned** step that runs *before* the orchestrator can claim a task. The orchestrator never improvises a plan and never asks the operator to approve one — an unplanned task is simply not claimable.

- **`[ready]` marker.** A claimable unit (top-level task **or** sub-task) carries the literal token `[ready]` immediately after its checkbox: `- [ ] [ready] \`feat\` Export reports to CSV \`#42\` \`~4h\``. Readiness is a **per-unit** property — the **epic line is never marked `[ready]`** (it is a container; the orchestrator descends into sub-tasks). `[ready]` is independent of `[x]` (done), `[OVERSIZE]`, and `[BLOCKED]`; a `[ready]` task still has to pass the `blocked_by` filter before it is claimed.
- **`.plan/<id>.md` artifact.** Each `[ready]` unit has a committed plan at `.plan/<id-without-#>.md` (e.g. `.plan/42.md`, `.plan/42a.md`) holding: approach, affected areas, acceptance criteria, risks/open questions, and a decomposition note. The `.plan/` directory is **tracked** (the approved plan is spec + evidence). A `[ready]` marker without its `.plan/<id>.md` is an inconsistency — tooling surfaces it and treats the unit as not-ready.
- **The flow.** The product lead runs **`/plan-task <id>`**, which dispatches the `planner` agent (reads the task, scans the codebase, writes the draft plan; when the task is oversize-likely the planner invokes `task-decomposer` and writes one plan per sub-task). The product lead reviews the draft; on **explicit approval** the command commits the plan(s) and flips the unit(s) to `[ready]`. No approval → nothing is committed and nothing becomes `[ready]`.
- **Scope.** The gate governs the operator-facing P0/P1/P2 flow. Atelier's own dev roadmap (`## High / Medium / Low Priority`) does not use `[ready]`.

**Selection order (extended):**

The orchestrator selects work in this order:

1. Highest-priority section (P0 → P1 → P2).
2. Within a section, the first unchecked top-level item. If that item is an epic, descend into its sub-tasks.
3. Within an epic, the first unchecked sub-task with no open `blocked_by` (resolved against sibling sub-tasks first, then global tasks).
4. The candidate must carry `[ready]` with a committed `.plan/<id>.md` (Planning gate above). Unplanned items are skipped exactly like `blocked_by`-gated ones.
5. Sub-tasks marked `[OVERSIZE]` or `[BLOCKED]` are skipped (same as top-level tasks — see M7.1.F26 / M7.1.F27.1).

An epic with **all** sub-tasks `[x]` is fully complete; the epic line itself auto-flips to `[x]` and moves to `HISTORY.md` as a single closing entry referencing each sub-task's PR.

**Decomposition** (M4.24.b → M4.30): oversize-likely tasks are decomposed during **planning**, not during orchestration. The `planner` (invoked by `/plan-task`) evaluates the oversize-likely heuristics and, when they trip, runs the `task-decomposer` agent to rewrite the top-level task as an epic with sub-tasks in place — then plans each sub-task. The operator can pre-empt this by writing the epic structure manually, by running `/atelier:slice-task <id>` to pre-split, or disable the auto-pass via `<project>/.atelier.json`'s `taskDecomposer.enabled: false`. The orchestrator itself never decomposes (the old step-4 auto-trigger is removed). See M4.24.a (this section) for the *format*, M4.24.b for the *engine*, M4.30 for the planning gate that owns it.

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

The orchestrator waits (bounded) for CI to complete before invoking the merge gate, so a still-running CI at chain-end does not require a manual re-invoke. Pending CI (`IN_PROGRESS`/`QUEUED`) is waited on; failed CI (`FAILURE`/`CANCELLED`/`TIMED_OUT`/`STARTUP_FAILURE`) is terminal and stops the chain without merging (CI failure after a green reviewer pass requires the operator to push a fix and re-invoke). Wait budget defaults: `maxWaitSeconds: 900`, `pollIntervalSeconds: 15` — configurable per project via `ciWait` in `<project>/.atelier.json`. See `agents/task-orchestrator.md` § Pre-merge CI wait.

**Never auto-merge** (falls back to human operator):
- Changes to `package.json` / `pnpm-lock.yaml`.
- Changes to `Dockerfile` / `docker-compose*`.
- Changes to `.github/workflows/**`.
- PR exceeds the per-project size budget. Default: `>200 lines` **AND** `>10 files`, post-exemptions for tests / lockfiles / migrations (see `scripts/atelier-pr-size-check`). The AND-gate means either dimension alone (a tightly-scoped long diff, or a broad refactor that stays small) is fine; only PRs that breach both axes fall back to human review. Per-project override via `<project>/.atelier.json`'s `prSize.{maxLines,maxFiles,exempt}`.
- Human comments pending on PR.
- Reviewer marks `request-changes` with structural findings (scope alignment, oversize, missing dependency justification, or pending human comments) that the review-fix loop does not auto-fix, OR `reviewFix.enabled` is `false` in `<project>/.atelier.json`. When `reviewFix.enabled` is `true` (default), a `request-changes` verdict with **code-addressable** findings (correctness / test coverage / code quality / security) triggers a bounded automated fix→re-review loop (up to `reviewFix.maxCycles` cycles, default 2) before falling back to human; a converged `approve` re-enters the normal merge gate. See `agents/task-orchestrator.md` § Review-fix loop and `agents/pr-author.md` § Follow-up mode.

**Merge strategy:** squash.
**Post-merge:** delete remote branch, remove local worktree, mark roadmap item `[x]`.

**Unattended watcher:** `/atelier:babysit-prs` (§7) drives open `task/*` PRs that are not yet reviewed or merged — re-entering at the `reviewer → auto-merge` segment — without any manual re-invocation. Loop it with `/loop <interval> /atelier:babysit-prs`; it runs one idempotent pass per invocation and reports the per-PR verdict.

---

## 7. Agents, skills, slash commands ✅

### Agents (with model assignment)

| Agent | Model | Purpose |
|---|---|---|
| `planner` | Opus | Produces the approved plan (`.plan/<id>.md`); decomposes oversize tasks via `task-decomposer`. Product-lead-invoked via `/plan-task` |
| `task-orchestrator` | Opus | Claims only `[ready]` tasks; routes them through specialists (never plans or decomposes) |
| `implementer` | Sonnet | Writes feature / fix code |
| `tester` | Sonnet | Writes and runs unit + integration tests |
| `e2e-runner` | Sonnet | Drives Playwright, captures screenshots |
| `pr-author` | Sonnet | Opens PR, writes description, posts status |
| `pr-opener` | Sonnet | Authors a non-task PR (e.g. `/atelier:align`'s base PR) so the dispatching session stays a clean, non-authoring reviewer |
| `reviewer` | Opus | Independent review before merge |
| `unblocker` | Sonnet | Handles failure recovery + blocking issues |

**Invariant — PR authoring is always sub-agent work.** Two orthogonal axes gate
review: git identity (`gh/author` vs `gh/reviewer`, §6) and actor/session (the
auto-mode classifier blocks a `reviewer`/`auto-merge` dispatch as self-approval
when the *same session* pushed that PR, independent of which `gh` identity it
used). The dual identities satisfy the first axis but not the second, so a
session must never commit + push + `gh pr create` for a PR it will itself send
to `reviewer` — it delegates authoring instead: `pr-author` for `task/<id>`
branches, `pr-opener` for everything else (align's base PR, ad-hoc chore/docs/
fix branches). See `operator-rules.md` § "PR authoring is always sub-agent
work" for the full rule and its one benign exception.

### Skills (global)

Auto-discovered by Claude Code from the plugin's `./skills/` directory (no explicit manifest entries needed).

- `task-discovery` — parse `ROADMAP.md`, pick next task.
- `git-wt` — worktree per task. **Sourced externally** from [AkaLab-Tech/git-wt](https://github.com/AkaLab-Tech/git-wt); installed in Phase C step 6. Not maintained in this repo.
- `pr-flow` — branch → commit → push → PR.
- `visual-validation` — Playwright screenshots.
- `safe-commit` — lint + typecheck + tests before commit.
- `safe-install` — audit + `pnpm view` before `pnpm add`.

### MCP servers ✅

Declared in `.mcp.json` at the plugin root and auto-loaded when atelier is active. Connections are stdio (lazy: the server process spawns on first tool call, not at session start).

**Namespace convention.** Claude Code namespaces MCP servers loaded via a plugin's `.mcp.json` as `plugin_<pluginname>_<servername>` to avoid collisions with project-level `.mcp.json` servers of the same name. So a server declared as `playwright` in `atelier`'s plugin `.mcp.json` exposes its tools as `mcp__plugin_atelier_playwright__<tool>` (not `mcp__playwright__<tool>`). `settings.template.json` allow/deny entries and agent `tools:` frontmatter must use the prefixed name.

- `playwright` — official `@playwright/mcp` server, started via `npx -y @playwright/mcp@latest`. Provides a controllable browser as an agent tool (`mcp__plugin_atelier_playwright__*`) so `implementer` can validate UI work as it builds and `reviewer` can independently exercise the flow during PR review. Distinct from M3.1's `visual-validation` skill, which drives the project's own `@playwright/test` suite for the PR gate (§6).

  **Scope by agent.** `mcp__plugin_atelier_playwright__*` is in the allow list of `settings.template.json`; only `implementer` and `reviewer` list `mcp__plugin_atelier_playwright` in their agent `tools:` frontmatter, so no other agent can invoke it.

  **First-call cost.** `@playwright/mcp` uses the operator's system Chrome by default — no full browser-bundle download. First call materializes only a profile directory: ~9 MB on macOS at `~/Library/Caches/ms-playwright/mcp-chrome-<hash>/`, equivalent on Linux at `~/.cache/ms-playwright/mcp-chrome-<hash>/`. Distinct from M3.1's `visual-validation` skill which runs `pnpm exec playwright install` and downloads the full ~250 MB chromium/firefox/webkit bundles.

  **Chrome-missing failure mode.** If the operator has no system Chrome installed, the first tool call returns a structured MCP error: `Error: Browser "chrome" is not installed. Run \`npx @playwright/mcp install-browser chrome\` to install`. Recoverable in one command (Playwright's channel install supports `chrome` since v1.30 — on macOS it triggers the Chrome installer, on Linux it goes through apt/yum). On macOS Chrome is near-universal so this is rare; on Linux dev workstations it may not be present. The error is actionable enough that an `implementer` subagent reading the structured response can surface it to the operator with the install command. Pre-flighted by `/doctor` check 4.f, which detects Chrome on macOS via `/Applications/Google Chrome.app` and on Linux via `command -v google-chrome[-stable]` — surfaces the install command before the operator hits the error in a real task.

  **Hard deny: `mcp__plugin_atelier_playwright__browser_run_code_unsafe`.** The MCP server exposes 23 tools; 22 are sandboxed to the browser (navigate, click, snapshot, evaluate-in-page, etc.). The 23rd — `browser_run_code_unsafe` — is documented by the server itself as "Run a Playwright code snippet. Unsafe: executes arbitrary JavaScript in the Playwright server process and is RCE-equivalent." That executes against the operator's host as the operator's user, breaking the read-only contract of `reviewer` and giving `implementer` an unbounded escape hatch. `settings.template.json` denies this single tool by name; the other 22 stay covered by the wildcard.

### Slash commands (global)

- `/plan-task <id>` — product-lead planning gate: dispatch the `planner`, review the draft, and on approval commit `.plan/<id>.md` + mark the task `[ready]` (§5 Planning gate). A task is only claimable once planned.
- `/next-task` — full pickup-to-PR flow (claims only `[ready]` tasks). When nothing is claimable it surfaces a ranked shortlist of plan candidates (via `task-discovery`'s `plan_candidates`, capped at 5, `P0 > P1 > P2` then no-open-`blocked_by`-first) instead of a bare error, and in interactive mode can dispatch `/plan-task <id>` on the top candidate — planning approval itself still happens inside `/plan-task`. Headless runs print the shortlist only.
- `/resume-task <id>` — continue after interruption.
- `/finish-task` — finalize PR.
- `/status` — what's in progress, blocked, awaiting review.
- `/setup-project <path>` — initialize a new project with `.claude/settings.json`, `ROADMAP.md`, `.npmrc` (pnpm guardrails — see §4), `.gitignore` entries. **Idempotent**: writes `~/.claude/.atelier-config.json` with `setupCompleted` (ISO timestamp) + `setupVersion`. Re-running on a configured project skips the wizard and offers a "reconfigure" flow instead. Pattern borrowed from [`omc-setup`](https://github.com/Yeachan-Heo/oh-my-claudecode/blob/main/skills/omc-setup/SKILL.md).
- `/doctor` — health check. Verifies: update status for the three artefacts the operator depends on — `atelier` and `claude-roadmap-tools` via local `plugin.json:version` vs latest release/tag (both live in the shared `akalab-tech` marketplace, so a single `/plugin marketplace update akalab-tech` followed by `/plugin update <name>@akalab-tech` refreshes whichever is stale), and `git-wt` via locally installed SHA (recorded by `install.sh` Phase C.1) vs `gh api repos/AkaLab-Tech/git-wt/commits/main` (re-run external `install.sh --skill-for=claude` to apply, since `git-wt` is **not** a native plugin); no legacy hooks leaking into `~/.claude/settings.json`; `git-wt` binary present; `fnm` hook active in shellrc; current project's `.npmrc` guardrails in place; per-project `.atelier-config.json` consistency. When an update is available, `/doctor` prints the exact command for the operator to apply it — it does **not** apply updates automatically. Borrowed from [`omc-doctor`](https://github.com/Yeachan-Heo/oh-my-claudecode/tree/main/skills/omc-doctor).
- `/babysit-prs [--workspace] [--yes|-y]` — unattended watcher: one idempotent pass over every open `task/*` PR — triage each against the `auto-merge` six guardrails (read-only), drive eligible PRs to merge via `task-orchestrator` `pr-open` dispatch, report per-PR status (`merged` / `waiting (CI)` / `needs fix` / `held — <reason>` / `skipped`). Designed to be looped: `/loop 10m /atelier:babysit-prs`. Composes with the CI-wait (#23) and review-fix (#24) features when present; degrades gracefully without them. See `commands/babysit-prs.md`.

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

**Review-fix loop:** when `reviewer` returns `request-changes` with code-addressable findings and `reviewFix.enabled` is `true` in `<project>/.atelier.json` (default), the orchestrator automatically re-dispatches `implementer` (and `tester` when coverage is implicated) for up to `reviewFix.maxCycles` fix→re-review cycles (default 2, configurable per project). Each fix attempt is logged through the same `.task-log/` mechanism above — the 6-attempt ceiling is **shared** across the inner implementer↔`/validate` loop and review-fix cycles, so the loop cannot spin past the §8 budget regardless of which cap is hit first. On exhaustion (no convergence to `approve` within the cycle bound or the attempt budget), the orchestrator surfaces accumulated findings and `.task-log/` paths and leaves the PR open for the operator. See `agents/task-orchestrator.md` § Review-fix loop.

---

## 9. Update flow (`atelier-update`) ✅

Implemented as `scripts/atelier-update` and the `/atelier:update` slash command (M6.1.a + M6.1.b, shipped v0.6.x). Originally named `update.sh` in this section — renamed to `atelier-update` so it matches the rest of the `atelier-*` helper family.

1. `git pull` inside the `atelier` repo (default `~/atelier`, overridable via `ATELIER_HOME`).
2. Detect changed files since the last pull (`git diff --name-only <prev-head> HEAD`).
3. Apply only the deltas: re-instantiate any changed templates under `$ATELIER_CONFIG_DIR/templates/`, refresh the `~/.local/bin/atelier-*` symlinks if a new helper was added, refresh `$ATELIER_CONFIG_DIR/atelier-help.txt` (M7.1.F34), then `CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" claude plugin update atelier@akalab-tech` to pick up the new plugin version.
4. **If `settings.template.json` changed**, surface a detailed permission diff via `scripts/atelier-permission-diff` (M6.1.b) — added/removed permissions, plus a human-readable description column (the description table is hardcoded in the script):

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

- **Atomic** multi-repo changes — a single task/PR that spans more than one repo. atelier never produces a cross-repo atomic PR; every task is one worktree of one repo and one PR. (Note: *grouping* several single-repo projects into a **workspace**, with *sequenced* cross-repo dependencies, is now **in scope** — see §15. An "epic across repos" is expressed as ordinary single-repo tasks chained by `blocked_by:<token>#id`, never as one atomic unit.)
- Deployment / release management **in atelier core**. (Deploy/manage capabilities are delivered as *separate, optional* plugins that atelier only offers to install and configure via opt-in `install.sh` prompts + `/atelier:setup-*`; atelier core itself performs no deployment. Shipped: [`coolify-integration`](https://github.com/AkaLab-Tech/coolify-integration) (Coolify VPS, M4.22/M4.23), [`vercel-integration`](https://github.com/AkaLab-Tech/vercel-integration) (Vercel, M4.27), [`neon-integration`](https://github.com/AkaLab-Tech/neon-integration) (Neon Postgres, M4.28).)
- Cost monitoring / per-task budget caps.
- Visual regression (baseline diff) — v2. v1 uses raw screenshots.
- Bidirectional ROADMAP ↔ GitHub Issues sync.

### Deferred to v2 — borrowed patterns from OMC

Concrete ideas to revisit once v1 is stable. All sourced from [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode).

| # | Idea | OMC reference | Value for atelier |
|---|---|---|---|
| v2.1 | **Skill auto-injector hook** (`UserPromptSubmit`) that picks skills by context signals so agents load only what they need | [`scripts/skill-injector.mjs`](https://github.com/Yeachan-Heo/oh-my-claudecode/blob/main/scripts/skill-injector.mjs) | Smaller context per turn, lower cost |
| v2.2 | **Router skill with subcommands** (`/atelier setup\|doctor\|update\|reconfigure`) | [`skills/oh-my-claudecode`](https://github.com/Yeachan-Heo/oh-my-claudecode/tree/main/skills/oh-my-claudecode) | Single entry point, less command clutter |
| v2.3 | **Layer 3 of the permission model** — LLM-backed semantic judgment for commands the static matrix (§3) and M2.4 pattern hooks do not enumerate (shell composition, context-dependent destinations, novel binaries). **Decided in [docs/research/permission-layer-3.md](docs/research/permission-layer-3.md) (M2.6 spike 2026-05-29 + M2.7 empirical validation 2026-05-29): Option C — adopt Claude Code's native `auto` permission mode as the primary layer 3. The M2.6 conditional is resolved: OQ-A/B/C all favorable on Claude Code v2.1.156.** Adoption work tracked as M2.8 (ROADMAP, Phase 4 — High Priority). The custom `PreToolUse` Haiku hook (originally option B / the OMC reference) stays as a targeted second layer above auto-mode for the high-risk surface (anything touching `pnpm-lock.yaml`, deploy paths, never-auto-merge files), tracked separately as M2.9 (after M2.8 lands). Option C **complements** layers 1+2, does not replace them — Anthropic's auto-mode reports ~17% false negatives on overeager actions (concentrated in Tier-2 file edits and ambiguous-consent Bash, both of which atelier already scopes via `additionalDirectories` + deny list), so the static layer carries primary responsibility. | [`scripts/permission-handler.mjs`](https://github.com/Yeachan-Heo/oh-my-claudecode/blob/main/scripts/permission-handler.mjs) (option B reference, deferred to M2.9) · [Claude Code auto-mode docs](https://code.claude.com/docs/en/permission-modes) (option A, adopted in M2.8) | Catches semantic-intent attacks that pattern-based layers miss, without sacrificing the auditable allow/deny matrix |
| v2.4 | **Project-memory hooks** (`SessionStart` + `PostToolUse`) that auto-detect project state and persist learnings per project | [`scripts/project-memory-session.mjs`](https://github.com/Yeachan-Heo/oh-my-claudecode/blob/main/scripts/project-memory-session.mjs) + [`scripts/project-memory-posttool.mjs`](https://github.com/Yeachan-Heo/oh-my-claudecode/blob/main/scripts/project-memory-posttool.mjs) | Replaces manual registry writes with automatic observation |
| v2.5 | **`/learner` + `/skillify`** — extract reusable patterns from successful tasks into new skills | [`skills/learner`](https://github.com/Yeachan-Heo/oh-my-claudecode/tree/main/skills) family | The reviewer loop becomes a learning loop |
| v2.6 | **Node.js hook dispatcher** (`scripts/run.cjs`): all hooks call a wrapper that handles timeouts, fail-open, Node binary resolution, Windows compatibility | [`scripts/run.cjs`](https://github.com/Yeachan-Heo/oh-my-claudecode/blob/main/scripts/run.cjs) | Robustness + portability; required if we add the v2 hooks above |

---

## 12. Implementation plan

Phases are sequential. Each phase ends with a verifiable milestone.

### Phase 1 — Foundation
**Deliverables:**
- M1.1 Repo skeleton: `.claude-plugin/`, `agents/`, `skills/`, `commands/`, `hooks/`, `templates/`, `scripts/`.
- M1.2 Plugin manifest: `.claude-plugin/plugin.json` (name `atelier`, version, description, author). The marketplace catalog (`marketplace.json`, name `akalab-tech`) initially shipped here too but was subsequently extracted to the dedicated [AkaLab-Tech/claude-plugins](https://github.com/AkaLab-Tech/claude-plugins) repo so a single marketplace can list every AkaLab-Tech plugin (see ROADMAP.md M1.6 architecture refinement). The `skills/` directory at the plugin root is auto-discovered by Claude Code, so the `skills` field is intentionally omitted. Validate the plugin loads in a clean Claude Code install via `/plugin marketplace add AkaLab-Tech/claude-plugins` → `/plugin install atelier@akalab-tech`.
- M1.3 `install.sh` doing **only** Phase A (deps) + Phase B (auth) + Phase C.1 (host-OS: git-wt, `.env*` excludes, git identity, shell hooks) + Phase C.2 (drive Claude Code to install the plugin, or print the paste-in commands). Note: per-project `.npmrc` guardrails are written by `/setup-project` (M2.3), not by `install.sh`.
- M1.4 `settings.template.json` with the full allow/deny/ask matrix from §3 (stays as a template; per-task instantiation is a Phase 2 skill).
- M1.5 Global operator `CLAUDE.md` at repo root with the rules agents must follow (dep install §4, push/PR/merge §6).

**Done when:** a fresh Mac runs `install.sh`, logs into both services, finishes with the `atelier` plugin installed and verifiable via `/doctor` showing all ✅.

### Phase 2 — Single-project workflow
**Deliverables:**
- M2.1 Agents: `task-orchestrator`, `implementer`, `tester`, `pr-author`.
- M2.2 Skills: `task-discovery` (parses ROADMAP §5), `pr-flow`, `safe-commit`, `safe-install`. (`git-wt` skill ships from the external package.)
- M2.3 Slash commands: `/next-task`, `/status`, `/finish-task`, `/setup-project` (idempotent via `.atelier-config.json`; writes the project's `.npmrc` guardrails per §4), `/doctor`.
- M2.4 Hooks: `block-env-commit`, `safe-commit` (lint+test pre-commit).

**Done when:** in a toy repo with 3 tasks in ROADMAP.md, `task` picks the first one, implements it, opens a PR, and reports back — without any operator intervention after the initial `task`.

### Phase 3 — Validation + review
**Deliverables:**
- M3.1 `e2e-runner` agent + `visual-validation` skill.
- M3.2 `reviewer` agent (Opus) with explicit checklist.
- M3.3 Auto-merge logic with all guardrails from §6.
- M3.4 Playwright MCP server registered via plugin `.mcp.json` (`@playwright/mcp@latest` via `npx -y`); `mcp__plugin_atelier_playwright__*` allowed in `settings.template.json`; `implementer` and `reviewer` list `mcp__plugin_atelier_playwright` in their tools. Gives those two agents a controllable browser for live visual validation, separate from the PR-gate suite driven by M3.1's `visual-validation` skill.

**Done when:** the toy-repo flow ends with a merged PR (squash), closed roadmap item, deleted branch, cleaned worktree.

### Phase 4 — Robustness
**Deliverables:**
- M4.1 Retry logic with log persistence (§8).
- M4.2 `unblocker` agent: hard stop + blocking issue creation.
- M4.3 Resume flow: `/resume-task` continues after interruption.

**Done when:** injecting a failing test into the toy repo causes 3 retries, then a reset, then 3 more retries, then a clean blocking issue + operator notification.

### Phase 5 — Multi-project
**Deliverables:**
- M5.0 Config root isolation: atelier lives under `$ATELIER_CONFIG_DIR` (default `~/.claude-work/`), separate from the operator's personal Claude.
- M5.0.1 `gh` auth isolation: two atelier-isolated `gh` identities at `$ATELIER_CONFIG_DIR/gh/author/` (used by every operational agent) and `$ATELIER_CONFIG_DIR/gh/reviewer/` (used only by the `reviewer` agent). The two must be different GitHub users so `gh pr review --approve` lands as a real approval, fixing Finding #11.
- M5.0.2 Preflight collision check + dynamic `ATELIER_CONFIG_DIR` so the operator can choose a different path when the default already has unrelated content.
- M5.0.3 `atelier-uninstall` with chat-session preservation (default) + `--purge` opt-in.
- M5.1 Project registry at `$ATELIER_CONFIG_DIR/projects.json`.
- M5.2 `/setup-project` bootstraps a new project end-to-end: `.claude/settings.json`, `ROADMAP.md`, `.claude/CLAUDE.md`, `.npmrc` (pnpm guardrails), `.gitignore`, and registry entry.
- M5.3 `task` alias resolves current project from cwd (fallback to menu if not inside one).

**Done when:** two toy projects coexist, `task` in each picks from its own ROADMAP.md, agents don't cross-pollinate.

### Phase 6 — Update + documentation
**Deliverables:**
- M6.1 `atelier-update` with incremental diff + permissions-prompt UX (§9). ✅ Shipped as `scripts/atelier-update` (M6.1.a) + `scripts/atelier-permission-diff` (M6.1.b) + `/atelier:update` slash wrapper.
- M6.2 Operator guide (Jr-friendly). ✅ [docs/operator-guide.md](docs/operator-guide.md).
- M6.3 Product owner guide (how to write ROADMAP.md).
- M6.4 Troubleshooting doc. ✅ [docs/troubleshooting.md](docs/troubleshooting.md).

**Done when:** a Jr following only the operator guide can clone, install, and run a full task cycle on a pre-configured project.

### Phase 7 — End-to-end validation
**Deliverables:**
- M7.1 Dogfood on a real (non-toy) project. **In progress** — see [docs/dogfood-guide.md](docs/dogfood-guide.md) and the M7.1.F* finding stream in [HISTORY.md](HISTORY.md) (F1–F35 closed across v0.4.x → v0.7.x).
- M7.2 Iterate on the network allowlist based on actual usage.
- M7.3 Measure: % of tasks reaching merged state without intervention. ✅ Shipped as `scripts/atelier-measure-merge-rate` + [docs/measurements/autonomous-merge-rate.md](docs/measurements/autonomous-merge-rate.md).

**Done when:** ≥ 80% of a sample of 10 real tasks complete to a merged PR autonomously.

---

## 13. Next step

Start **Phase 1**. First piece: repo skeleton + `install.sh` Phase A (dependencies).

---

## 14. Release policy ✅

Captured 2026-05-23 as the outcome of M5.0.4. Authoritative for atelier, `claude-roadmap-tools`, and `git-wt` (all three repos under `AkaLab-Tech`).

### 14.1 Release trigger ✅

**Per-PR merge to main.** Each PR that lands on `main` produces exactly one release. The PR itself **must** include the appropriate bump of `plugin.json:version` (or the equivalent version reference for `git-wt`) coherent with the change it ships, per the SemVer mapping in §14.2. Releases are tagged + cut as part of the same PR's effects — manually for now (M5.0.5 may automate later via a GH Actions workflow on merge).

**Why per-PR and not per-milestone**: per-milestone reads cleaner but requires defining "milestone-closing PR" precisely (the close commit is usually `chore(history): close MX.X`, separate from the feat commit). Per-PR is mechanical and unambiguous: every merged commit on main has a corresponding release. Operators always see the version that matches what's actually deployed, with no gap between "feature shipped" and "release cut".

**Tradeoff accepted**: docs-only / chore PRs (`docs(roadmap): ...`, `chore(history): backfill ...`) produce patch releases that are mostly noise. Mitigation: skip releasing when the PR's diff is purely `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` whitespace-or-link edits (no functional change). This is judgment-call territory; default to release when in doubt.

### 14.2 SemVer mapping ✅

- **`patch`** (`0.1.x`) — docs / chore / bug fix that does **not** change agent prompts, slash commands, hooks, MCP servers, or the permission model (`templates/settings.template.json`).
- **`minor`** (`0.x.0`) — new agent / skill / slash command / hook / MCP server, OR material change to an existing agent's prompt or capabilities, OR new fields/entries in `templates/settings.template.json` that are additive only.
- **`major`** (`x.0.0`) — breaking change. Specifically: reshape or shrink of the permission model (`templates/settings.template.json` deny list expansion that breaks existing workflows, `additionalDirectories` layout change), modification to the agent dispatch contract (how `task-orchestrator` invokes specialists), or anything that requires the operator to re-run `/setup-project` against already-bootstrapped projects to pick up the change.

**First major bump (`1.0.0`) is reserved for "production-ready" — separate discussion when atelier reaches that bar.** Pre-1.0, breaking changes still bump major (e.g. `0.5.0` → `1.0.0` is valid pre-production), but the canonical `1.0.0` carries production-ready semantics: stable UX, complete docs, observed operator usage across multiple real projects.

### 14.3 Tag format ✅

**`v`-prefixed** (e.g. `v0.1.0`, `v0.2.0`, `v1.0.0`). The initial three releases (`atelier`, `claude-roadmap-tools`, `git-wt`) use this format; staying consistent costs nothing and `commands/doctor.md` strips the leading `v` before comparing against `plugin.json:version`, so both formats compare equal in the drift check.

### 14.4 Release notes ✅

**PR-body-driven.** The body of the PR that ships the release is the source of truth for release notes. When cutting the release manually (e.g. `gh release create v0.X.Y --notes "..."`), copy the PR body's `## Summary` + `## Delivered` + `## Decisions captured` sections into the release notes. Operator-readable directly; zero additional drafting work per release.

For docs-only / chore PRs that still warrant a release (per §14.1), a one-line release note is sufficient: *"Tracking / housekeeping commit; no functional change since `<previous-tag>`."*

### 14.5 Cross-plugin synchronization ✅

**Independent.** `atelier` and `claude-roadmap-tools` are separate repos in the same marketplace, with no shared code today. Each plugin has its own `plugin.json:version` and its own release cadence — bumped only when *its own* repo lands a PR. `/atelier:doctor` reports two numbers, one per plugin.

**Why independent rather than lockstep**: lockstep would force a re-release of `claude-roadmap-tools` every time `atelier` lands a PR (and vice versa), even with zero code change in the unaffected repo. That distorts the version number — `claude-roadmap-tools` would jump from `0.1.0` to `0.5.0` reflecting `atelier`'s activity, not its own. Independent versioning is the truth.

### 14.6 `marketplace.json` and versions ✅

**No version pinning. Resolves to `main` HEAD (status quo).** `marketplace.json` at `AkaLab-Tech/claude-plugins` continues to list each plugin by name + source-repo, with no `version` field. When the operator runs `/plugin install <name>@akalab-tech`, Claude Code clones the source repo's `main` HEAD.

**Tradeoff accepted**: operators always get the latest `main` HEAD on install, regardless of which tag is "current". The version compared against by `/doctor` is whatever the locally-installed `plugin.json:version` says — which matches `main`'s current `plugin.json:version` because plugin installs are `main`-anchored.

**When to revisit**: if/when operators start pinning to specific atelier versions (e.g. enterprise environments wanting reproducible installs), introduce `marketplace.json:plugins[].version` per plugin (Option C in M5.0.4: pin only major version, resolve to latest minor/patch within). Until then, the simplicity of "always main" wins.

### 14.7 `git-wt` versioning ✅

**Same rules as atelier**: SemVer per §14.2, `v`-prefixed tags per §14.3, per-PR releases per §14.1, PR-body-driven notes per §14.4. Cadence is whatever PR activity `git-wt` sees — currently low (the binary is small and stable), so most months will see no `git-wt` release at all, and `/doctor` reports `up to date` against the existing `v0.1.0` tag indefinitely.

**`install.sh` continues to clone `main` HEAD shallow** (per §14.6 — no pinning). The recorded SHA at `~/.local/state/atelier/git-wt.sha` is whatever `main` HEAD was at install time; `/doctor` drift detection works against this.

### 14.8 Out of scope (future milestones)

The following are recognized as logical follow-ups to the policy in §14, but are not part of M5.0.4. Each becomes its own milestone when picked up:

- **Automation (M5.0.5 — to be captured separately)**: GH Actions workflow on merge to `main` that (a) verifies `plugin.json:version` was bumped in the PR per §14.2's criteria, (b) creates the tag + release with notes from the PR body. Replaces the manual `gh release create` step.
- **Pre-merge CI bump gate**: refuse merge of a PR that meets bump criteria in §14.2 but did not bump `plugin.json:version`. Defensive, prevents version drift between code state and release state.
- **Pre-1.0 → 1.0 transition checklist**: criteria for cutting the first `1.0.0` (production-ready). Not a versioning rule — a release-management ritual.

---

## 15. Multi-repo workspaces 🟡

Captured 2026-06-05. Lets an operator manage a "product" made of several repos (e.g. backend + frontend + CMS) without losing any single-repo guarantee. Delivered incrementally as **Phase 8** (ROADMAP M8.x).

### 15.1 Concept + the atomicity invariant ✅

A **workspace** is a thin grouping / routing / aggregation layer over N already-configured single-repo projects. It is **not** cross-repo atomicity (which stays out of scope, §11): every task still runs in exactly one git worktree of one member repo and produces exactly one PR. The only genuinely new behavioural primitive is the **sequenced cross-repo dependency** `blocked_by:<token>#id`, which *orders* single-repo tasks across members — it never merges them into one unit. An "epic across repos" is just ordinary single-repo tasks, one per member, chained by `blocked_by`.

The invariant that keeps every existing command working: **each member stays an independent entry in `projects.json`**; the workspace registry only *references* member paths. From inside a member, every single-repo command (`/next-task`, `/status`, `task`) behaves exactly as before — workspace-awareness only activates from the workspace root or when a cross-repo `blocked_by` is present.

### 15.2 Registry — `$ATELIER_CONFIG_DIR/workspaces.json` ✅

A **separate** file from `projects.json` (different cardinality and lifecycle; keeping them apart leaves every existing `projects.json` reader byte-identical). Schema:

```json
{
  "workspaces": {
    "acme-platform": {
      "name": "acme-platform",
      "root": "/Users/me/Work/acme",
      "createdAt": "2026-06-05T14:30:00Z",
      "setupVersion": "0.13.0",
      "members": [
        { "path": "/Users/me/Work/acme/backend",  "token": "backend",  "role": "member" },
        { "path": "/Users/me/Work/acme/frontend", "token": "frontend", "role": "member" }
      ]
    }
  }
}
```

- `members[].path` MUST be a key in `projects.json` (validated at setup; an unregistered member is refused with `atelier-needs-setup=<path>` markers so the command layer can configure it first).
- `members[].token` is the short name used in `blocked_by:<token>#id`. Default = `basename(path)`, overridable per member; unique within the workspace.
- **v1 constraint:** a project belongs to **at most one** workspace (so the reverse-lookup `member-path → workspace` is unambiguous). Enforced by `atelier-setup-workspace` (override with `--force`).
- `root` is the parent dir used to route `task` from the workspace root (§15.5); may be the members' longest common path prefix, or empty when they have no common parent.

### 15.3 Setup — `/setup-workspace` + `atelier-setup-workspace` 🟡

Host-OS helper `scripts/atelier-setup-workspace` (mirrors the `atelier-setup-project` conventions: logging, `--help`, jq registry merge, idempotent, `createdAt` preserved on re-run) wrapped by the `/atelier:setup-workspace` slash command. Two member-selection modes: **explicit `--members <p1,p2,…>` (primary)** and **`--discover <parent-dir>` (secondary, scans one level for git repos)**. Per member, **reuse `atelier-setup-project`** rather than re-implementing registration: members already registered are recorded as-is; unregistered members are surfaced (exit 3 + markers) so the *command* drives `/atelier:setup-project` on each (the bash/AI split of M4.19), then re-invokes the script to register the group. Reverse-lookup is exposed as `atelier-setup-workspace --which-workspace <path>` (exit 0 + slug, or exit 4 on miss).

### 15.4 Cross-repo dependencies — `atelier-resolve-dep` (offline) 🟡

Resolution is **offline via the sibling member's `HISTORY.md`** — not `gh pr` (which would need the other repo's network + auth, and `#id` is a ROADMAP task id, not necessarily a PR number). `gh` is an opt-in fallback only. The helper `scripts/atelier-resolve-dep --workspace <slug> --from <member> --token <repo> --id <#id>` returns: `0` satisfied (id is a closed entry in `<token>/HISTORY.md` with a co-located PR reference), `3` open, `4` unknown-token, `5` unknown-id, `2` usage. The `task-discovery` skill detects the `<token>#` shape, calls the helper, and treats exit≠0 as "blocker open" (same code path as today's intra-repo open `blocked_by`); `/next-task` Step 3 refuses an explicitly-named blocked task with a clear message. **Risk — id matching:** HISTORY entries reference PR numbers while `blocked_by` references task ids; the resolver matches the id in a heading/item-introducing position with a co-located PR reference, and on `unknown-id` refuses loudly rather than blocking silently (§8 discipline).

### 15.5 Routing `task` from the workspace root 🟡

`atelier-task-resolve` gains a Step 1.5 between the longest-prefix member match and the global fzf picker: when `cwd` is a workspace `root`, present a **member picker** (reusing the existing fzf block) with a cheap per-member open-task hint; the chosen member path flows into the existing `task()` → `/next-task` path unchanged. When `cwd` is exactly a workspace root that *is itself* also a registered project, the member picker takes precedence. Workspace context for the cross-repo gate is recovered by reverse-lookup (member path → workspace), so the stdout contract of `atelier-task-resolve` does not change.

### 15.6 Aggregated status — `/workspace-status` 🟡

A **new** command (does not overload `/status`, whose single-project refusal is load-bearing). Reuses `atelier-list-projects` (extended with a `--workspace <slug>` filter) to render one row per member — on-disk status, in-progress task, open-task count, cross-repo-blocked count — plus a "cross-repo blocked" section computed via `atelier-resolve-dep`. Read-only, same discipline as `/list-projects`.

### 15.7 Auxiliary commands 🟡

- `/list-workspaces` + `atelier-list-workspaces` — enumerate workspaces with per-member health (mirrors `atelier-list-projects`).
- `/remove-workspace <slug>` + `atelier-remove-workspace` — remove only the `workspaces.json` entry; members stay registered projects. `--with-members` (destructive, off by default) also runs `atelier-remove-project` per member.
- `/doctor` extension — `check_workspaces`: `root` exists, every member path is still a directory AND still in `projects.json`, tokens unique; silent skip when `workspaces.json` is absent.

## 16. External task-manager backends 🟡

Captured 2026-06-13. Lets a project keep its tasks in an **external task manager** instead of the local `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` files — **starting with GitHub Projects v2**. The backend is chosen at `/setup-project` time and the operator can switch backends **at any time, in either direction**. Delivered incrementally as **Phase 9** (ROADMAP M9.x).

This does **not** start from zero. Two foundations already exist and Phase 9 connects them:

- **`claude-roadmap-tools` (crt)** already ships a multi-backend architecture (its `TASK_001`, closed): a `.roadmap.json` config (`backend: files|linear`), a `RoadmapBackend` interface (`listTasks` / `getTask` / `addTask` / `moveTask` / `appendHistoryEntry` / `isAvailable`, spec in crt's `docs/RoadmapBackend.md`), `FilesBackend` + `LinearBackend`, and `/create-roadmap --backend` / `/migrate-roadmap --to`.
- **atelier** already frames `next-task`'s backlog source + claim registry as a pluggable **task provider** (§7 / `commands/next-task.md` step 2), explicitly "Linear-ready".

The gap Phase 9 closes: **the two are not wired together.** atelier's `task-discovery` / `next-task` read the backlog straight from `origin/<base>:ROADMAP.md` (git), bypassing crt's `RoadmapBackend` entirely — so *no* remote backend, not even the Linear one crt already implements, drives atelier's autonomous cycle today.

### 16.1 The two-layer split + the coupling decision ✅

Two layers across two repos:

1. **crt — the backend.** Owns the `RoadmapBackend` contract and each concrete backend (`FilesBackend`, `LinearBackend`, new `GitHubProjectBackend`), plus the operator-facing `/create-roadmap` / `/migrate-roadmap` and the `roadmap-tracking-flow` skill.
2. **atelier — the consumer.** Its task provider (`task-discovery` + `next-task`), `setup-project`, and the worktree/PR cycle.

**Coupling decision (✅): atelier aligns to crt's `RoadmapBackend` contract rather than re-implementing its own provider.** crt is the tracking layer; atelier is its consumer. This avoids two divergent backend implementations and makes GitHub Projects the *second* consumer of a now-real abstraction rather than a one-off. The contract — not crt's internals — is the dependency surface; atelier already requires crt installed (for `/adopt-roadmap`), so this formalizes an existing relationship.

### 16.2 Wire the abstraction first — Phase 9.1 🟡

The first slice is backend-agnostic and ships value on its own. atelier's task provider stops reading `origin/<base>:ROADMAP.md` directly and instead routes through `RoadmapBackend` (selected by the project's `.roadmap.json`, defaulting to `files`):

- **No behaviour change for `files`** — the file-/git-backed path is preserved as `FilesBackend` semantics; existing projects see no difference.
- **Validation target: Linear.** With the provider wired, the existing `LinearBackend` becomes the first remote backend that actually drives atelier's cycle — discover next task, honour the planning gate, move buckets — proving the seam before GitHub exists.
- **Claim registry stays git.** §16.4 keeps open `task/*` PRs as the concurrency/claim signal; only the *backlog + state surface* moves behind the abstraction.

### 16.3 `GitHubProjectBackend` — Phase 9.2 🟡

A third `RoadmapBackend` implementation in crt, mirroring the `LinearBackend` shape.

- **Target: GitHub Projects v2** (GraphQL Projects API), not raw Issues + labels. The Project's **Status** single-select field maps to the three buckets via a configurable `stateMap` (e.g. `Backlog`/`Todo` → roadmap, `In Progress` → in_progress, `Done` → history), exactly like `linear.stateMap`.
- **Auth via a GitHub MCP** (OAuth), mirroring the `LinearBackend` MCP pattern — **not** `gh`. `isAvailable()` checks the GitHub MCP is registered without making an API call (no premature OAuth). `/create-roadmap` runs the MCP-registration one-liner when missing (confirm the GitHub hosted-MCP endpoint, analogous to `claude mcp add --transport http … https://mcp.linear.app/mcp`).
- **Field mapping** onto Projects v2 fields:
  - `#id` → a **custom field** (e.g. `Atelier ID`), *not* the Project item number (uncontrollable, non-stable across moves). Preserves §5 `#NN` ids.
  - type tag → a single-select `Type` custom field; estimate → a `Estimate` text/number custom field.
  - `[ready]` → a dedicated **`Ready`** field (boolean/single-select), **separate from Status** so readiness is orthogonal to the bucket (§16.5).
  - `blocked_by` → a text custom field, parsed with the same grammar as today (`#id`, `<token>#id`).
  - `backendId` (the Project item node id) is written into each task file's frontmatter when the offline mirror is on (crt's existing coherence scheme).

### 16.4 `setup-project` selection + `next-task` on GitHub Projects — Phase 9.3 🟡

- **`setup-project` backend choice.** Today the helper only writes the `files` layout. It gains a backend prompt that **delegates to `/create-roadmap --backend github-project`** (reusing crt, never re-implementing the `.roadmap.json` write or MCP registration). Headless: `files` stays the safe default; a remote backend requires the operator to pick it interactively or pass it explicitly (a remote backend needs OAuth, which can't be auto-resolved).
- **`next-task` runs against the Project.** With §16.2's provider in place, selection, the planning gate, and the `ROADMAP → IN_PROGRESS → HISTORY` moves run against `GitHubProjectBackend`.
- **Claim registry = open `task/*` PRs (✅).** Concurrency stays anchored on atelier's open `task/*` PRs, not on the Project's "In Progress" column — the git/worktree/PR mechanics of `next-task` steps 3–8 are untouched. The Project is the backlog + state surface; the PR is the unit of claim.

### 16.5 The planning gate against a Project — Phase 9.3 🟡

The §5 planning gate (M4.30) splits cleanly across the two surfaces:

- **`.plan/<id>.md` stays a tracked repo file.** The implementer needs the approved plan in the worktree; it is spec + evidence and belongs in git regardless of backend.
- **`[ready]` becomes the Project's `Ready` field.** `/plan-task` flips that field (via the backend) on approval instead of editing a `ROADMAP.md` line. The gate is satisfied iff `Ready` is set **and** `.plan/<id>.md` is committed — a `Ready` item without its plan file is surfaced as the same inconsistency §5 already defines. Approval remains interactive-only (never headless).

**Plan storage — two contracts (`planStorage`, TASK_027).** The default above (`planStorage=committed`) assumes the plan file is a **tracked, committed** artifact that lands on `origin/<base>`. That is what makes the plan-on-base guard in `/next-task` and the orchestrator's second-backstop abort correct: the worktree, cut from `origin/<base>`, carries the committed plan. `.atelier.json` → `planStorage` selects between two contracts:

- **`committed`** (default, unchanged): `/plan-task` commits `.plan/<id>.md` alongside the readiness flip; it rides the worktree and appears in the task PR (the "what was approved" audit trail).
- **`local`**: `.plan/<id>.md` is a **gitignored, never-committed** file in the operator's main checkout. `git worktree add` does a clean checkout of the tree and does **not** copy gitignored/untracked files, so the plan is deliberately absent from the worktree. Because `/plan-task`, `/next-task`, and `/resume-task` all execute in the main checkout (cwd = repo toplevel, `git rev-parse --show-toplevel`), the plan is read there at claim/resume time and carried **inline** in the `task-orchestrator` briefing (Approach / Affected areas / Acceptance criteria) — the worktree never needs the file. The plan-on-base guard is dropped for this mode, and the orchestrator's committed-mode abort ("plan absent on the worktree base") is suppressed. The `files`-backend `[ready]` flip (and any epic decomposition) still rides `ROADMAP.md` and still must land on `origin/<base>`; only the `.plan` file is local. **Known trade-off:** a local plan does not appear in the task PR, so reviewers lose the approved-plan record — this is an accepted cost of the mode, documented for operators, not a bug. This is the **follow-up to TASK_027** (which resolved "plan commit dropped when unpushed" by *adding* the plan-on-base guard): `planStorage=local` offers the "carry the local plan" contract as the alternative to forcing the plan onto `origin/<base>`, for operators who would rather keep plans off the repo entirely.

### 16.6 Two-way migration — Phase 9.4 🟡

The operator asked to switch backends "at any time, in either direction." crt's v1 only does `files → linear` (and `single → indexed`); `remote → files` is "not yet implemented."

- Add **`files ↔ github-project` in both directions** to `/migrate-roadmap`.
- **Generalize the reverse path** as `backend → files` driven by `RoadmapBackend.listTasks` across the three buckets, so it is not GitHub-specific — it also unlocks `linear → files`. Preserve crt's ID-based coherence (`backendId`) and its partial-failure / orphan-state guards.

### 16.7 Workspaces — Phase 9.5 🟡

- **One backend per repo** in v1 (crt's current rule): one GitHub Project per member repo. A single Project shared across a multi-repo workspace is deferred — it complicates `blocked_by:<token>#id` resolution and breaks one-backend-per-repo.
- **Cross-repo `blocked_by:<token>#id`** keeps resolving as in §15.4, but the sibling member's task state is read through *its* backend (its `HISTORY` bucket via `RoadmapBackend`) instead of assuming a local `HISTORY.md`. `atelier-resolve-dep` gains a backend-aware path; the offline-`HISTORY.md` route stays the `files` case.
- e2e validation across a real 2–3 repo workspace closes Phase 9.

### 16.8 Sequencing

`9.1` (wire the abstraction; validate with Linear) → `9.2` (`GitHubProjectBackend` in crt) → `9.3` (`setup-project` selection + `next-task` + planning gate on Projects) → `9.4` (two-way migration) → `9.5` (workspaces + e2e). 9.1 is the keystone and ships standalone value (any remote backend starts driving the cycle); everything after it layers on a now-real seam.

### 16.9 SessionStart offline-mirror refresh ✅

**Problem.** crt's "Mirror auto-refresh on activation" procedure (SKILL.md §"Mirror auto-refresh on activation") only fires when the `roadmap-tracking-flow` skill activates — i.e. when the prompt touches tracking. Sessions that never mention tracking keep a stale mirror for the whole session; the orientation surface (`orient-session.sh`, `/atelier:status`) drifts from the board.

**Fix (TASK_034).** A fourth `SessionStart` hook (`hooks/refresh-mirror.sh` → `scripts/atelier-refresh-mirror`) surfaces a one-line instruction telling the session to run crt's **EXISTING** mirror auto-refresh **before** answering the operator's first prompt, without requiring the prompt to mention tracking.

**Bash / AI split (the load-bearing design decision).** The board read needs the GitHub MCP/OAuth, which a bash `SessionStart` hook cannot drive — the existing hooks deliberately touch no `gh` / remote `git`. So the work is split:

- **Bash half** (`scripts/atelier-refresh-mirror`): cheap gating (filesystem + `jq` only) + a one-line surfaced instruction when due. NEVER calls `git fetch`, reads `origin`, drives the GitHub MCP/OAuth, performs board reads, or references `/migrate-roadmap`. Fail-open (exit 0 always).
- **AI half**: acting on the surfaced instruction, the session activates `roadmap-tracking-flow` and runs its existing auto-refresh — `listTasks` across the `roadmap` / `in_progress` / `history` buckets via the GitHub MCP/OAuth — regenerating the local mirror **without** removing `.roadmap.json` or flipping the backend.

**Gating.** The helper resolves the backend via `scripts/atelier-task-backend` and reads `.offlineMirror` from `.roadmap.json` with `jq`. It is a silent no-op (no output, exit 0) for the `files` backend, for `offlineMirror: false` / absent, and for linked worktrees (`.git` is a file gitdir-pointer). A once-per-day stamp under `$ATELIER_CONFIG_DIR` bounds the cost to at most one refresh instruction per calendar day.

**What this is NOT.** This never drives `/migrate-roadmap --to files` (crt step 5d — the authority-flipping, `.roadmap.json`-removing reverse path). The `github-project` backend stays the source of truth; only the read-only mirror files are regenerated from the board by crt's existing engine.
