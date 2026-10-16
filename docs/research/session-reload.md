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
| 11 | `/reload-plugins` re-runs SessionStart hooks (re-injecting `operator-rules.md`). | Not verified; assumed no (doc evidence only: no doc says a reload re-runs SessionStart; #505 follow-up finding F) | n/a |
| 12 | A session notices a `claude plugin update` run from another terminal. | Not verified for this marketplace | n/a |
| 13 | The model can run `/reload-plugins` itself. | Verified: not possible (see "#505 follow-up", findings A-C) | skills, plugins/cli-reference |
| 14 | Still needs a restart: plugin monitors; plugin MCP changes in non-interactive sessions; settings keys read only at start; a new Claude Code binary. SessionStart-injected context is not replaced by a reload (follows from 11). | Verified (first four); the last follows from 11 | `plugins/loading`, `plugins/cli-reference`, `settings` |

## Step 1: empirical check

**Status: not run.** It needs an interactive Claude Code session where someone types `/reload-plugins`; the agent chain that implemented #486 cannot type slash commands. Items 11 and 13 were assumed false, so `/atelier:refresh` re-injects the session context itself and the operator types `/reload-plugins`.

What to observe, in a scratch session on the installed version, to close each open item:

- **Item 5:** bump the installed version (or run `claude plugin update` against a newer cache) with `.mcp.json` unchanged, type `/reload-plugins` without `--force`, and note whether it asks for `--force` because of `playwright`.
- **Item 11:** type `/reload-plugins` and note whether SessionStart hook output comes back (the operator-rules text, the "Operator chat language" block, the orient line). If yes, the re-injection in `/atelier:refresh` step 3 can shrink to the language line and notification reconcile.
- **Item 12:** run `claude plugin update atelier@akalab-tech` (with `CLAUDE_CONFIG_DIR` set to atelier's config root) in another terminal and watch the open session for any notice before the operator does anything. If it notices on its own, the nudge hook is partly redundant.
- **Item 13:** ask the model in the session to run `/reload-plugins` (including via the `SlashCommand` tool) and note whether it executes or is refused. If it can, `/atelier:refresh` could trigger the reload itself instead of telling the operator to type it.

Record the outcomes here and amend `commands/refresh.md`, `hooks/version-drift-nudge.sh` and the troubleshooting section if any answer changes the assumption above.

## #505 follow-up: can atelier trigger `/reload-plugins`?

Docs fetched 2026-10-16 from `code.claude.com/docs/en/*.md`; local Claude Code 2.1.301. This settles finding 13.

| # | Claim | Status | Source |
|---|---|---|---|
| A | The model can call only "a few built-in commands" through the Skill tool, "including /init and /security-review. Other built-in commands such as /compact are not." `/reload-plugins` is not named. | Verified (docs) | skills § "Restrict Claude's skill access" |
| B | In a Claude Code 2.1.301 session, the Skill tool's list of invocable names includes `init` and `security-review` but not `reload-plugins`. | Verified (seen directly in the planner's session on 2026-10-16) | live Skill tool listing |
| C | `/reload-plugins` runs only when the user types it in non-interactive sessions (`-p`, Agent SDK, desktop). Arriving by Remote Control or a relayed message, it replies "isn't available over a remote connection" and reloads nothing. It never (dis)connects plugin MCP servers in those sessions. | Verified | plugins/cli-reference § reload-plugins; commands table |
| D | Claude Code runs `/reload-plugins` on its own only when the `/plugin` panel closes with pending changes, and for command-source plugins whose output hash changed. The atelier marketplace uses neither. | Verified | plugins/cli-reference; plugins/loading § "When a command source re-runs" |
| E | No hook output field reloads plugins. The only reload field is SessionStart `reloadSkills`, which only rescans skill/command directories (finding 9). | Verified | hooks § SessionStart decision control |
| F | SessionStart `source` values are `startup`, `resume`, `clear`, `compact`, `fork`. No reload value. | Verified (doc absence); not verified by observation | hooks |
| G | No CLI flag, subcommand or IPC entry point reloads plugins in a running interactive session. `claude plugin update` only says "Restart to apply" / "Run /reload-plugins". | Verified (none documented) | cli-reference, plugins/cli-reference, plugins/loading |
| H | Hook `additionalContext` / `systemMessage` are capped at 10,000 characters; `operator-rules.md` (718 lines) cannot be injected whole by a hook. | Verified | hooks § output limits |
| I | `session_id` stays the same across `/reload-plugins`. | Not verified (assumed; the design fails safe) | n/a |
| J | `UserPromptSubmit` fires when the operator types a plugin slash command. | Not verified (`UserPromptExpansion` is documented for that path) | hooks |

**Conclusion:** there is no supported way for a plugin command, skill, hook or the model to trigger `/reload-plugins`. No undocumented workaround (keystroke injection, send-keys) is used.

**Design that follows:** the operator types `/reload-plugins`; `hooks/version-drift-nudge.sh` (now also registered on SessionStart) records the version whose context was injected, and on the first prompt after the reload tells the model to finish the refresh (the `/atelier:reload` steps) once, unless the prompt is `/atelier:reload` or `/atelier:refresh`. `/atelier:refresh` stays as a deprecated alias. If I or J turns out false, the hook stays silent (fail-open) and `/atelier:reload` still works by hand.
