# Reloading atelier in a running Claude Code session (#486)

Question: after `atelier-update`, can an open session pick up the new atelier version without a restart, and what still needs one?

Docs fetched 2026-10-15 from `code.claude.com/docs/en/*.md`; local Claude Code 2.1.300. Each claim is marked **verified** (with its source page) or **not verified**.

## Findings

| # | Claim | Status | Source |
|---|-------|--------|--------|
| 1 | Built-in `/reload-plugins [--force]` exists. Pending changes include plugins "installed, updated ... since the session started", including a `claude plugin` command run in another terminal. | Verified | `commands`; `plugins/cli-reference#reload-plugins` |
| 2 | It reloads plugin skills, commands, agents, hooks, plugin MCP servers and LSP servers. | Verified | `plugins/cli-reference` "Reload summary" |
| 3 | After an update, hooks keep the old version's path until `/reload-plugins`; monitors need a restart. atelier ships no monitors. | Verified | `plugins/loading` |
| 4 | Old version directories stay 14 days, so stale sessions' hooks keep working. | Verified | `plugins/loading` |
| 5 | A reload that changes plugin MCP tools needs `--force` (prompt-cache invalidation). atelier ships `playwright` in `.mcp.json`. | Verified (rule); not verified whether a version bump with an unchanged `.mcp.json` triggers it | `plugins/cli-reference` |
| 6 | In `-p`, SDK and desktop sessions, `/reload-plugins` runs only when typed into the session and does not (dis)connect plugin MCP servers. | Verified | `plugins/cli-reference` |
| 7 | Settings files reload live, including `permissions` and `hooks`; some keys are read only at session start. | Verified | `settings` "When edits take effect" |
| 8 | Command/skill/agent Markdown can use `${CLAUDE_PLUGIN_ROOT}`. | Verified | `plugins-reference` |
| 9 | `/reload-skills` and SessionStart `reloadSkills` only rescan skill/command dirs. | Verified | `commands`, `hooks` |
| 10 | `UserPromptSubmit` hooks can add context; any hook can return `systemMessage`. | Verified | `hooks` |
| 11 | `/reload-plugins` re-runs SessionStart hooks (re-injecting `operator-rules.md`). | Not verified; assumed no | n/a |
| 12 | A session notices a `claude plugin update` run from another terminal. | Not verified for this marketplace | n/a |
| 13 | The model can run `/reload-plugins` itself. | Not verified; assumed the operator types it | n/a |
| 14 | Still needs a restart: plugin monitors; plugin MCP changes in non-interactive sessions; settings keys read only at start; a new Claude Code binary. SessionStart-injected context is not replaced by a reload (follows from 11). | Verified (first four); the last follows from 11 | `plugins/loading`, `plugins/cli-reference`, `settings` |

## Step 1: empirical check

**Status: not run.** It needs an interactive Claude Code session where someone types `/reload-plugins`; the agent chain that implemented #486 cannot type slash commands. Items 11 and 13 were assumed false, so `/atelier:refresh` re-injects the session context itself and the operator types `/reload-plugins`.

What to observe, in a scratch session on the installed version, to close each open item:

- **Item 5:** bump the installed version (or run `claude plugin update` against a newer cache) with `.mcp.json` unchanged, type `/reload-plugins` without `--force`, and note whether it asks for `--force` because of `playwright`.
- **Item 11:** type `/reload-plugins` and note whether SessionStart hook output comes back (the operator-rules text, the "Operator chat language" block, the orient line). If yes, the re-injection in `/atelier:refresh` step 3 can shrink to the language line and notification reconcile.
- **Item 12:** run `claude plugin update atelier@akalab-tech` (with `CLAUDE_CONFIG_DIR` set to atelier's config root) in another terminal and watch the open session for any notice before the operator does anything. If it notices on its own, the nudge hook is partly redundant.
- **Item 13:** ask the model in the session to run `/reload-plugins` (including via the `SlashCommand` tool) and note whether it executes or is refused. If it can, `/atelier:refresh` could trigger the reload itself instead of telling the operator to type it.

Record the outcomes here and amend `commands/refresh.md`, `hooks/version-drift-nudge.sh` and the troubleshooting section if any answer changes the assumption above.
