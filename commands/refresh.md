---
description: Pick up a new atelier version in this open session without restarting — compares the loaded, installed and helper versions, and (after /reload-plugins) re-injects operator-rules.md and the SessionStart context.
argument-hint: ""
allowed-tools: Bash(jq:*), Bash(readlink:*), Bash(claude --version), Bash(atelier-orient:*), Bash("${CLAUDE_PLUGIN_ROOT}"/hooks/sync-notification-hook.sh), Read, AskUserQuestion
---

You are running `/atelier:refresh`. Goal: make this already-open session use the atelier version Claude Code has installed, without a restart. Claude Code's built-in `/reload-plugins` reloads skills, commands, agents and hooks, but it does not replace the context injected at session start (operator rules, chat language, orientation); this command re-injects it.

`$ATELIER_CONFIG_DIR` defaults to `~/.claude-work`.

## Step 1 — Report the three versions

Run these in one Bash call and show the result as a short three-line table:

- **Loaded** (what this session runs): `jq -r .version "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json"`
- **Installed** (what Claude Code has in its plugin cache): `jq -r '.plugins["atelier@akalab-tech"][0].version // empty' "${ATELIER_CONFIG_DIR:-$HOME/.claude-work}/plugins/installed_plugins.json"`
- **Helpers** (the `atelier-*` binaries): `readlink ~/.local/share/atelier/current` (the target's basename is the version)

If a value cannot be read, show `unknown` for it and carry on.

## Step 2 — Loaded differs from installed: stop

If Loaded and Installed are both known and differ, tell the operator, in their language:

> This session still runs atelier <loaded>; <installed> is installed. Type `/reload-plugins` (or `/reload-plugins --force` if it warns about reloading MCP tools), then run `/atelier:refresh` again.

Then **stop**. Do not run any other step. You cannot type `/reload-plugins` yourself; the operator does.

## Step 3 — Loaded equals installed: re-inject the session context

1. `Read` `${CLAUDE_PLUGIN_ROOT}/operator-rules.md` in full (use `Read`, not Bash `cat`: the file exceeds the Bash output cap; page with `offset`/`limit` until the end). State plainly that these rules **replace** the operator rules injected at session start, and follow them from now on.
2. Operator chat language: `jq -r '.language // empty' "${ATELIER_CONFIG_DIR:-$HOME/.claude-work}/operator.json"` (same source as `hooks/load-operator-rules.sh`). If set, keep addressing the operator in that language for all chat, status and questions; this does not change the project's deliverable language.
3. Run `atelier-orient` once for the current directory and present its single suggested next step (one line), as at session start.
4. Run `"${CLAUDE_PLUGIN_ROOT}"/hooks/sync-notification-hook.sh` (idempotent) to reconcile the Notification hook.

## Step 4 — What still needs a restart

End with this list, short:

- Plugin monitors (atelier ships none).
- Plugin MCP server changes in non-interactive sessions (`claude -p`, SDK, desktop).
- Settings keys that Claude Code reads only at session start.
- Anything injected at session start that this command could not replace.

Also run `claude --version`; if it differs from what this session started with, add "Claude Code itself (new binary)" to the list. If nothing applies, say a restart is not needed.

## Decision rules

- Read-only apart from the idempotent notification-hook reconcile. Never run `claude plugin update` or `atelier-update` from here; that is `/atelier:update`.
- Never claim a restart is needed when the versions match and nothing in Step 4 applies.
