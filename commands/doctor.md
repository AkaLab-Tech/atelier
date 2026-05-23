---
description: Health check for atelier — detects drift against upstream for `atelier`, `claude-roadmap-tools`, and `git-wt`, plus auxiliary host checks (legacy hooks, shellrc, .npmrc, .atelier-config.json). Reports findings and prints the exact commands the operator must run; never applies updates automatically.
---

You are running the `/doctor` health check for atelier.

Your job is to produce a single structured report with `✓`/`✗` per check, followed by **exact commands** the operator must run to fix anything that's `✗`. **Never run an update or fix yourself** — print the commands and stop. The operator decides what to apply.

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

1. Read the recorded SHA: `cat ~/.local/state/atelier/git-wt.sha`. If the file is missing or empty: `✗ git-wt SHA not recorded` with the message "re-run `install.sh` to record it".
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
c. **`fnm env --use-on-cd` active in the operator's shell.** Look for the sentinel `# >>> atelier hooks (managed by install.sh) >>>` in `~/.zshrc` and `~/.bashrc` (whichever exists). `✓` if found in the operator's default shell rc; `✗` with "re-run `install.sh`" otherwise.
d. **Current project's `.npmrc` guardrails present** (only if a `.npmrc` exists in `$CLAUDE_PROJECT_DIR` or the cwd). Confirm all three of `ignore-scripts=true`, `minimum-release-age=10080`, `audit-level=moderate` are present. `✓` if all three; `✗` listing which are missing, with the suggestion to re-run `/setup-project`.
e. **Per-project `~/.claude/.atelier-config.json` consistency** (only if the file exists). Confirm it parses as JSON and contains both `setupCompleted` (ISO timestamp) and `setupVersion` (string). `✓` if both; `✗` with "re-run `/setup-project --reconfigure`".
f. **System Chrome present (required by `mcp__plugin_atelier_playwright`).** The playwright MCP that atelier ships uses the operator's system Chrome by default; first call fails with an actionable error if Chrome is missing. Detect platform via `uname -s` and check accordingly:
   - **macOS** (`Darwin`): `[ -d "/Applications/Google Chrome.app" ] || [ -d "$HOME/Applications/Google Chrome.app" ]`.
   - **Linux**: `command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1`.
   - Any other OS: skip the check with `–` and a one-line note ("Chrome presence check not implemented for <os>").

   `✓ system Chrome detected` if found. `✗ system Chrome not found — mcp__plugin_atelier_playwright will fail on first call` with this fix command block:
   ```bash
   npx @playwright/mcp@latest install-browser chrome
   # alternatively (macOS): brew install --cask google-chrome
   # alternatively (Linux): use your distro's package manager (apt install google-chrome-stable, etc.)
   ```

g. **`docker compose` (v2 plugin) reachable (required by `docker-env` skill + `docker-runner` agent).** atelier's docker-env skill issues `docker compose -p <project> up/down/...` with v2 syntax. Detect via `docker compose version`:
   - `✓ docker compose v<version> detected` if exit 0 + stdout contains a version string.
   - `–` (skipped) if `docker info` fails first (no daemon running — no point checking the plugin if the runtime is offline; suggest starting the runtime as the prerequisite step).
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
