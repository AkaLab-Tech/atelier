---
description: Health check for atelier — detects drift against upstream for `atelier`, `claude-roadmap-tools`, and `git-wt`, plus auxiliary host checks (legacy hooks, shellrc, .npmrc, .atelier-config.json). Reports findings and prints the exact commands the operator must run; never applies updates automatically.
allowed-tools: Read, Glob, Grep, Bash(claude plugin list:*), Bash(claude plugin marketplace list:*), Bash(gh api:*), Bash(env:*), Bash(echo:*), Bash(printenv:*), Bash(cat:*), Bash(grep:*), Bash(jq:*), Bash(command -v:*), Bash(awk:*), Bash(docker compose version:*), Bash(docker info:*), Bash(uname:*), Bash(test:*), Bash(head:*), Bash(tail:*), Bash(wc:*)
---

You are running the `/doctor` health check for atelier.

Your job is to produce a single structured report with `✓`/`✗` per check, followed by **exact commands** the operator must run to fix anything that's `✗`. **Never run an update or fix yourself** — print the commands and stop. The operator decides what to apply.

## Tool guidance (M7.1.F16b)

To run prompt-free under the `allowed-tools` list above:

- **For reading any file contents** (markers, configs, SHAs, JSON files): use the `Read` tool, NOT `cat`. Claude Code routes `cat <path>` through a path-scoped read-approval check that bypasses the `Bash(cat:*)` allow; the `Read` tool is the canonical read path with its own pre-approved scope.
- **For checking file existence**: use `Bash(test -f <path>)` or `Bash(test -d <path>)` — both allowlisted as `Bash(test:*)`.
- **For binary presence**: `Bash(command -v <binary>)` is allowlisted as `Bash(command -v:*)`.
- **Avoid compound shell expressions with `cat`** like `cat X 2>/dev/null || echo "MISSING"`. Instead: (1) check existence with `test -f`, (2) if exists, use `Read` to get content, (3) otherwise emit the `✗` row directly in the report. The compound form triggers a permission prompt even though `Bash(cat:*)` is listed.
- **For all other Bash invocations**: prefer single-command form. Compound shell operators (`&&`, `||`, `()`, `2>/dev/null` redirection) **trigger Claude Code's "shell operators require approval for safety" gate (M7.1.F22) even when every individual command in the compound is allowlisted.** Use one Bash call per intent and let the LLM interpret exit codes between calls; do NOT chain commands with shell operators just to provide a fallback string.

When a check needs file contents, prefer the sequence: `test -f path` → if ✓ → `Read` tool → parse content. Never wrap `Read` calls in shell pipelines.

### Avoid compound shell expressions (M7.1.F22)

This is the most surprising gotcha — even with every individual command in an allowlist, a compound shell expression triggers a separate safety gate. Examples that **DO prompt** despite proper allow-list coverage:

- ✗ `test -d X && echo "FOUND" || echo "NOTFOUND"` — even with `Bash(test:*)` + `Bash(echo:*)`.
- ✗ `docker compose version 2>/dev/null || echo "MISSING"` — even with `Bash(docker compose version:*)`.
- ✗ `gh api ... || gh api ...` — fallback chain across two `gh api` calls.
- ✗ `grep X file 2>/dev/null || echo "0"` — counting matches with a fallback.

Pattern: any `&&`, `||`, `(...)` subshell, or non-trivial redirection in the same Bash invocation. The safety gate's prompt reads "This command uses shell operators that require approval for safety".

**Canonical fix**: split into sequential single-command Bash calls, and let YOU (the LLM running doctor) interpret each command's exit code / output between calls to decide the next step. Example for the Chrome check:

```
Step 1: Bash `test -d /Applications/Google Chrome.app`
   → Exit 0: Chrome found in /Applications. Emit ✓ row. Skip step 2.
   → Exit non-0: continue.
Step 2: Bash `test -d $HOME/Applications/Google Chrome.app`
   → Exit 0: Chrome found in $HOME/Applications. Emit ✓ row.
   → Exit non-0: emit ✗ row with the install hint.
```

For commands that may not exist (`docker compose version`): run the simple form once. If exit non-0, emit `✗` directly — no `|| echo "MISSING"` shell fallback needed because YOUR turn handles the missing case via the exit code.

For grep over operator-config files like `~/.zshrc`: use the `Read` tool to load the file content, then count matches with the LLM's own pattern matching. `grep -c X ~/.zshrc` triggers BOTH the file-read path-scope check (like `cat`) AND, when combined with `|| echo "0"`, the compound-operator gate.

### Env-var prefix invocations (M7.1.F20)

Claude Code's Bash pattern matcher inspects the first word of a command. Shell-form env-var prefixes (`GH_CONFIG_DIR=value gh api ...`) make the first word `GH_CONFIG_DIR=value` — not `gh` — so `Bash(gh api:*)` does NOT match and the operator gets a permission prompt. To run prompt-free, **always use the `env` form** when an invocation needs custom env vars:

- ✗ `GH_CONFIG_DIR=/path gh api user` — prompts (first word is the assignment)
- ✓ `env GH_CONFIG_DIR=/path gh api user` — clean (first word is `env`, matched by `Bash(env:*)`)

Similarly:

- For inspecting an env var's value, use `printenv VAR` (matched by `Bash(printenv:*)`), not `echo "${VAR:-…}"` — `echo "${...}"` triggers a "Contains expansion" prompt even with `Bash(echo:*)` allowed.

## Checks to run (in this order)

### 1. Plugin drift — `atelier`

1. Read the installed version: run `claude plugin list --json` and find the entry whose `id` is exactly `atelier@akalab-tech`. Take its `version` field. If the entry is missing entirely, the check is `✗` with the message "atelier plugin not installed — re-run `install.sh`".
2. Read the latest upstream tag: run `gh api repos/AkaLab-Tech/atelier/releases/latest --jq '.tag_name'` (fall back to `gh api repos/AkaLab-Tech/atelier/tags --jq '.[0].name'` if there are no releases). Strip any leading `v`.
3. Compare. If equal: `✓ atelier <version> (up to date)`. If different: `✗ atelier <local> → <upstream>` and add this command block to the "to apply" section at the end:
   ```bash
   claude plugin marketplace update akalab-tech
   claude plugin update atelier@akalab-tech
   ```

### 2. Plugin drift — `claude-roadmap-tools`

Identical procedure as check 1, but against `claude-roadmap-tools@akalab-tech` and `gh api repos/AkaLab-Tech/claude-roadmap-tools/releases/latest`. The remediation command block reuses the same `marketplace update` line:
```bash
claude plugin marketplace update akalab-tech   # only print once if both plugins are stale
claude plugin update claude-roadmap-tools@akalab-tech
```

### 3. SHA drift — `git-wt`

`git-wt` is not a native Claude Code plugin, so it has its own mechanism:

1. Read the recorded SHA: check `test -f ~/.local/state/atelier/git-wt.sha` first; if it exists, use the `Read` tool on that path (do NOT `cat` it — see the Tool guidance above). If the file is missing or empty: `✗ git-wt SHA not recorded` with the message "re-run `install.sh` to record it".
2. Read the upstream HEAD SHA: `gh api repos/AkaLab-Tech/git-wt/commits/main --jq '.sha'`.
3. Compare full SHAs. If equal: `✓ git-wt <short-sha> (up to date)`. If different: `✗ git-wt <local-short> → <upstream-short>` and add this command block:
   ```bash
   git clone --depth 1 https://github.com/AkaLab-Tech/git-wt.git /tmp/git-wt
   /tmp/git-wt/install.sh --skill-for=claude
   git -C /tmp/git-wt rev-parse HEAD > ~/.local/state/atelier/git-wt.sha
   rm -rf /tmp/git-wt
   ```

### 4. Auxiliary host checks (each independent)

For each of the following, report `✓` (everything is fine) or `✗` (with the exact fix command). These are reporting-only — never modify anything yourself.

a. **No legacy atelier hooks leaking into `~/.claude/settings.json`.** Read that file (if it exists) and check that nothing under `hooks` references a path matching `*/atelier/*` or `*/.claude-personal/atelier/*`. If found, report `✗` and suggest opening the file to remove the stale entries (the live hooks now ship via the plugin's `hooks/hooks.json`, not via the user's `settings.json`).
b. **`git-wt` binary on PATH.** Run `command -v git-wt`. `✓` if exit 0; `✗` with "re-run `install.sh`" otherwise.
c. **`fnm env --use-on-cd` active in the operator's shell.** Look for the sentinel `# >>> atelier hooks (managed by install.sh) >>>` in `~/.zshrc` and `~/.bashrc`. **Use the `Read` tool, NOT `grep` with shell pipes** (M7.1.F22 — grep over operator-config files triggers both the file-read path-scope check AND the compound-operator gate if combined with `|| echo "0"`). Sequence: (1) `Bash test -f ~/.zshrc`; if exit 0, use `Read` on `~/.zshrc` and search for the sentinel substring in-memory. (2) Same for `~/.bashrc` if needed. `✓` if found in the operator's default shell rc; `✗` with "re-run `install.sh`" otherwise.
d. **Current project's `.npmrc` guardrails present** (only if a `.npmrc` exists in `$CLAUDE_PROJECT_DIR` or the cwd). Confirm all three of `ignore-scripts=true`, `minimum-release-age=10080`, `audit-level=moderate` are present. `✓` if all three; `✗` listing which are missing, with the suggestion to re-run `/setup-project`.
e. **Per-project `~/.claude/.atelier-config.json` consistency** (only if the file exists). Confirm it parses as JSON and contains both `setupCompleted` (ISO timestamp) and `setupVersion` (string). `✓` if both; `✗` with "re-run `/setup-project --reconfigure`".
f. **System Chrome present (required by `mcp__plugin_atelier_playwright`).** The playwright MCP that atelier ships uses the operator's system Chrome by default; first call fails with an actionable error if Chrome is missing. Detect platform via `uname -s`, then run sequential single-command checks (M7.1.F22 — never combine with `||`):
   - **macOS** (`Darwin`): run `Bash test -d "/Applications/Google Chrome.app"`. If exit 0, Chrome is found; emit `✓` and stop. If exit non-0, run `Bash test -d "$HOME/Applications/Google Chrome.app"`. If exit 0, emit `✓`. If non-0, emit `✗`.
   - **Linux**: run `Bash command -v google-chrome`. If exit 0, emit `✓`. If non-0, run `Bash command -v google-chrome-stable`. If exit 0, emit `✓`. If non-0, emit `✗`.
   - Any other OS: skip the check with `–` and a one-line note ("Chrome presence check not implemented for <os>").

   `✓ system Chrome detected` if found. `✗ system Chrome not found — mcp__plugin_atelier_playwright will fail on first call` with this fix command block:
   ```bash
   npx @playwright/mcp@latest install-browser chrome
   # alternatively (macOS): brew install --cask google-chrome
   # alternatively (Linux): use your distro's package manager (apt install google-chrome-stable, etc.)
   ```

g. **`docker compose` (v2 plugin) reachable (required by `docker-env` skill + `docker-runner` agent).** atelier's docker-env skill issues `docker compose -p <project> up/down/...` with v2 syntax. Use **two sequential single-command Bash calls** (M7.1.F22 — never `docker info >/dev/null && docker compose version || echo …`):
   - Step 1: `Bash docker info` (suppress stderr only if you must, but do NOT add `&&` or `||`). If exit non-0, daemon is offline → emit `–` (skipped) with the prerequisite hint.
   - Step 2 (only if step 1 succeeded): `Bash docker compose version`. If exit 0 + stdout has a version: emit `✓ docker compose v<version> detected`. If exit non-0: emit `✗` with the fix command block.
   - `✗ docker compose plugin not found — docker-env skill will fail on first lifecycle call` with this fix command block:
   ```bash
   # macOS (homebrew): the plugin ships with `docker-compose` formula but the
   # docker client only discovers it from ~/.docker/cli-plugins/. Symlink it:
   brew install docker-compose  # if not already installed
   mkdir -p ~/.docker/cli-plugins
   ln -sf /opt/homebrew/lib/docker/cli-plugins/docker-compose ~/.docker/cli-plugins/docker-compose

   # Linux (Debian/Ubuntu): docker-compose-plugin from Docker's apt repo
   sudo apt-get install docker-compose-plugin

   # Verify:
   docker compose version
   ```
   The skill probes `docker compose version` at first lifecycle call too — this `/doctor` check is purely informational, surfaced before the operator hits the failure during a task.

h. **`$ATELIER_CONFIG_DIR` resolves to an atelier-managed install (M7.1.F11).** The chosen path (default `~/.claude-work/`, or whatever the operator picked in Phase 0 of the last `install.sh` run) is persisted via the shellrc hook block as `export ATELIER_CONFIG_DIR=...`. Downstream tools (`atelier-uninstall`, `atelier-setup-project`) read this env var. Verify the resolution is intact:
   - `$ATELIER_CONFIG_DIR` is set and the directory exists.
   - `$ATELIER_CONFIG_DIR/.atelier-managed` exists and JSON-parses.
   - The marker's `installStatus` field is `complete` (an `in_progress` value means the previous `install.sh` did not finish — see M7.1.F6).

   `✓ atelier config dir <path> (installStatus: complete)` if all three pass. `✗` with the specific failure and one of these fix commands:
   ```bash
   # If $ATELIER_CONFIG_DIR is unset: shellrc hook block missing or not sourced.
   source ~/.zshrc   # or ~/.bashrc

   # If the directory or marker is missing: re-run install.sh to recreate them.
   /path/to/atelier/install.sh

   # If installStatus is in_progress: a previous install crashed. Re-run
   # install.sh; Phase 0 will offer to resume (M7.1.F6).
   /path/to/atelier/install.sh
   ```

i. **`$ATELIER_CONFIG_DIR/git-identity.conf` matches the atelier-author GitHub account (M7.1.F7a + F7b).** install.sh Phase B writes a `[user]` block to this file from `gh api user` under the atelier-author config dir; orchestrator-driven commits read it via `GIT_CONFIG_GLOBAL` so the commit's Author / Committer fields match the atelier-author GitHub identity (not the operator's personal global git config). Run the gh query with the env-prefix form to avoid the M7.1.F20 prompt: `env GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author" gh api user --jq '.email // empty, .id, .login'`. Then verify:
   - `$ATELIER_CONFIG_DIR/git-identity.conf` exists and is readable.
   - The file has a `[user]` section with non-empty `name = …` and `email = …` lines.
   - The `email` matches **either** of these valid forms (M7.1.F21 — accept any representation of the SAME account):
     - **Form A — public email**: literal equality with `gh api user .email` (when gh returns a non-empty `.email`).
     - **Form B — GitHub no-reply pattern**: `<id>+<login>@users.noreply.github.com`, derived from `gh api user .id` + `.login`. install.sh falls back to this form when `gh api user .email` is null/empty at install time (operator's email visibility may be hidden, or the gh token's scopes don't expose `.email`).

     The check passes if EITHER form matches. Reporting drift requires that the stored email matches NEITHER — i.e. the file points at a different account entirely (e.g. the operator re-authenticated with a new gh login but never re-ran install.sh to refresh the conf).

   `✓ atelier-author git identity captured: <name> <<email>>` when all three pass. `✗` with one of these fix commands:
   ```bash
   # If git-identity.conf is missing: re-run install.sh — Phase B
   # (phase_b_capture_atelier_git_identity) writes it after the gh logins.
   /path/to/atelier/install.sh

   # If the [user] block drifted from gh (e.g. atelier-author renamed the
   # GitHub account or changed its public email): re-run install.sh to
   # rewrite the file from the current `gh api user` output.
   /path/to/atelier/install.sh
   ```

## Output format

Print exactly this structure (one section per group, blank line between groups). Use only ASCII `✓` (`✓`) and `✗` (`✗`) — no emojis.

```
atelier /doctor — health check

Plugins (compared against AkaLab-Tech/claude-plugins marketplace)
    ✓ atelier <version>
    ✗ claude-roadmap-tools <local> → <upstream>

External tooling
    ✗ git-wt <local-short> → <upstream-short>

Host checks
    ✓ no legacy atelier hooks in ~/.claude/settings.json
    ✓ git-wt on PATH
    ✓ atelier shellrc hooks active
    ✓ project .npmrc guardrails present
    ✓ ~/.claude/.atelier-config.json consistent
    ✓ system Chrome detected
    ✓ docker compose v2 plugin detected
    ✓ atelier config dir <path> (installStatus: complete)
    ✓ atelier-author git identity captured: <name> <<email>>

To apply pending updates, run:
    claude plugin marketplace update akalab-tech
    claude plugin update claude-roadmap-tools@akalab-tech
    git clone --depth 1 https://github.com/AkaLab-Tech/git-wt.git /tmp/git-wt
    /tmp/git-wt/install.sh --skill-for=claude
    git -C /tmp/git-wt rev-parse HEAD > ~/.local/state/atelier/git-wt.sha
    rm -rf /tmp/git-wt
```

If everything is `✓`, replace the final block with the single line:

```
All checks passed. atelier is up to date.
```

If a check is skipped because its precondition isn't met (e.g. no `.npmrc` in the project, no `~/.claude/.atelier-config.json`), use `–` (an em-dash) in place of `✓`/`✗` and add a one-line note in parentheses explaining why.

## Hard rules

- **Never** run any of the printed "to apply" commands yourself. The operator runs them.
- **Never** modify files based on a check result. Reporting only.
- **Never** invent a check that isn't listed above. If you discover something that looks off but isn't in this list, mention it as a single trailing note after the structured report.
- Run the checks **in the listed order**. The plugin drift checks share a `claude plugin marketplace update akalab-tech` line — print it once, not twice, if both plugins are stale.
