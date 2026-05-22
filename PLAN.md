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

### Phase A — Preparation (no interaction)
1. Detect OS (macOS/Linux) and architecture.
2. Verify / install base dependencies via Homebrew (mac) or apt (linux):
   - `git`, `gh`, `fnm`, `pnpm`, `jq`, `fzf`. (Playwright moved to M3.1 / `e2e-runner`: only operators running e2e tasks need the ~250 MB browser bundle.)
   - **Node** is managed by `fnm` (Rust-based, fast startup, native `.nvmrc` support). Each project pins its Node version in a `.nvmrc` file at its root; `fnm` auto-switches on `cd` via `eval "$(fnm env --use-on-cd)"` (added to the operator's shellrc in Phase C). If a project has no `.nvmrc`, `fnm` falls back to the latest LTS installed at provisioning time.
   - **`pnpm`** is the package manager of choice — never fall back to `npm`. Installed via `corepack enable` once Node is available.
   - **`fzf`** enables the interactive picker for `git wt switch` (see Phase C, `git-wt` install).
3. Install Claude Code if not present via the official native installer: `curl -fsSL https://claude.ai/install.sh | bash`. Lands the signed native binary at `~/.local/bin/claude` and self-updates in the background. The `curl|sh` pattern is in the agent-level deny-list (PLAN.md §3), but `install.sh` runs in the operator's terminal before atelier's agent layer is active, so it is out of that scope.

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

6. Install **`git-wt`** (external, [Miguelslo27/git-wt](https://github.com/Miguelslo27/git-wt)) non-interactively for Claude:
   ```bash
   git clone https://github.com/Miguelslo27/git-wt.git /tmp/git-wt
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

12. Install the **`claude-roadmap-tools`** plugin (separate repo, [AkaLab-Tech/claude-roadmap-tools](https://github.com/AkaLab-Tech/claude-roadmap-tools); see ROADMAP.md M1.6). Provides `/create-roadmap`, `/migrate-roadmap` and the `roadmap-tracking-flow` skill — kept sovereign in its own repo so projects that do not use the full atelier stack can install it standalone. Step 11 already added the `akalab-tech` marketplace, so only the install command is needed here:
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

**Defense-in-depth.** This matrix is the **first** security layer: it gates *which tool* an agent can invoke. It does **not** inspect the *content* the tool would act on — `Edit(<worktree>/**)` is allowed for any file in the worktree regardless of what is being written to it. The **second** layer is the `PreToolUse` hook suite delivered in M2.4 (`scan-edit-write`, `scan-git-add`, `safe-package-change`, `block-env-commit`, `safe-commit`): those hooks intercept allowed tool calls and validate intent (proposed file contents, staged git diff, `package.json` changes before `pnpm install`/`add`/`update`/`run`). Neither layer alone is enough — a leaky static matrix would let through forbidden tools, and a leaky hook layer would miss tools that should never have been invoked. Both must hold for a real attack to land.

**`defaultMode`: `acceptEdits`**

### 🟢 Allow
- Read: `Read(<worktree>/**)`, Glob, Grep.
- Edit / Write: restricted to the current task's worktree (including docs).
- Git read: `status`, `diff`, `log`, `show`, `branch`, `blame`, `fetch`, `ls-files`.
- Git write: `add`, `commit`, `checkout -b`, `switch`, `worktree`, `stash`.
- Git push: `git push origin task/*` **only**. Deny everything else.
- GitHub CLI: `gh issue *`, `gh pr create/view/list/comment`, `gh pr merge` (only under §6 conditions), `gh project *`, `gh repo clone/view`, `gh auth status` (read-only identity check). Also `Bash(GH_CONFIG_DIR=* gh ...)` for the reviewer's atelier-isolated identity override (M5.0.1): `gh auth status`, `gh api user`, `gh pr view/list/diff/review/comment`.
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

### MCP servers ✅

Declared in `.mcp.json` at the plugin root and auto-loaded when atelier is active. Connections are stdio (lazy: the server process spawns on first tool call, not at session start).

**Namespace convention.** Claude Code namespaces MCP servers loaded via a plugin's `.mcp.json` as `plugin_<pluginname>_<servername>` to avoid collisions with project-level `.mcp.json` servers of the same name. So a server declared as `playwright` in `atelier`'s plugin `.mcp.json` exposes its tools as `mcp__plugin_atelier_playwright__<tool>` (not `mcp__playwright__<tool>`). `settings.template.json` allow/deny entries and agent `tools:` frontmatter must use the prefixed name.

- `playwright` — official `@playwright/mcp` server, started via `npx -y @playwright/mcp@latest`. Provides a controllable browser as an agent tool (`mcp__plugin_atelier_playwright__*`) so `implementer` can validate UI work as it builds and `reviewer` can independently exercise the flow during PR review. Distinct from M3.1's `visual-validation` skill, which drives the project's own `@playwright/test` suite for the PR gate (§6).

  **Scope by agent.** `mcp__plugin_atelier_playwright__*` is in the allow list of `settings.template.json`; only `implementer` and `reviewer` list `mcp__plugin_atelier_playwright` in their agent `tools:` frontmatter, so no other agent can invoke it.

  **First-call cost.** `@playwright/mcp` uses the operator's system Chrome by default — no full browser-bundle download. First call materializes only a profile directory: ~9 MB on macOS at `~/Library/Caches/ms-playwright/mcp-chrome-<hash>/`, equivalent on Linux at `~/.cache/ms-playwright/mcp-chrome-<hash>/`. Distinct from M3.1's `visual-validation` skill which runs `pnpm exec playwright install` and downloads the full ~250 MB chromium/firefox/webkit bundles.

  **Chrome-missing failure mode.** If the operator has no system Chrome installed, the first tool call returns a structured MCP error: `Error: Browser "chrome" is not installed. Run \`npx @playwright/mcp install-browser chrome\` to install`. Recoverable in one command (Playwright's channel install supports `chrome` since v1.30 — on macOS it triggers the Chrome installer, on Linux it goes through apt/yum). On macOS Chrome is near-universal so this is rare; on Linux dev workstations it may not be present. The error is actionable enough that an `implementer` subagent reading the structured response can surface it to the operator with the install command. Pre-flighted by `/doctor` check 4.f, which detects Chrome on macOS via `/Applications/Google Chrome.app` and on Linux via `command -v google-chrome[-stable]` — surfaces the install command before the operator hits the error in a real task.

  **Hard deny: `mcp__plugin_atelier_playwright__browser_run_code_unsafe`.** The MCP server exposes 23 tools; 22 are sandboxed to the browser (navigate, click, snapshot, evaluate-in-page, etc.). The 23rd — `browser_run_code_unsafe` — is documented by the server itself as "Run a Playwright code snippet. Unsafe: executes arbitrary JavaScript in the Playwright server process and is RCE-equivalent." That executes against the operator's host as the operator's user, breaking the read-only contract of `reviewer` and giving `implementer` an unbounded escape hatch. `settings.template.json` denies this single tool by name; the other 22 stay covered by the wildcard.

### Slash commands (global)

- `/next-task` — full pickup-to-PR flow.
- `/resume-task <id>` — continue after interruption.
- `/finish-task` — finalize PR.
- `/status` — what's in progress, blocked, awaiting review.
- `/setup-project <path>` — initialize a new project with `.claude/settings.json`, `ROADMAP.md`, `.npmrc` (pnpm guardrails — see §4), `.gitignore` entries. **Idempotent**: writes `~/.claude/.atelier-config.json` with `setupCompleted` (ISO timestamp) + `setupVersion`. Re-running on a configured project skips the wizard and offers a "reconfigure" flow instead. Pattern borrowed from [`omc-setup`](https://github.com/Yeachan-Heo/oh-my-claudecode/blob/main/skills/omc-setup/SKILL.md).
- `/doctor` — health check. Verifies: update status for the three artefacts the operator depends on — `atelier` and `claude-roadmap-tools` via local `plugin.json:version` vs latest release/tag (both live in the shared `akalab-tech` marketplace, so a single `/plugin marketplace update akalab-tech` followed by `/plugin update <name>@akalab-tech` refreshes whichever is stale), and `git-wt` via locally installed SHA (recorded by `install.sh` Phase C.1) vs `gh api repos/Miguelslo27/git-wt/commits/main` (re-run external `install.sh --skill-for=claude` to apply, since `git-wt` is **not** a native plugin); no legacy hooks leaking into `~/.claude/settings.json`; `git-wt` binary present; `fnm` hook active in shellrc; current project's `.npmrc` guardrails in place; per-project `.atelier-config.json` consistency. When an update is available, `/doctor` prints the exact command for the operator to apply it — it does **not** apply updates automatically. Borrowed from [`omc-doctor`](https://github.com/Yeachan-Heo/oh-my-claudecode/tree/main/skills/omc-doctor).

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
3. Apply only the deltas (re-symlink changed files, patch the per-project `.npmrc` template if changed, etc.).
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
