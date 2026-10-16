---
description: "Deprecated alias of /atelier:reload (renamed in #505) — delegates to it."
argument-hint: ""
allowed-tools: Bash(jq:*), Bash(readlink:*), Bash(claude --version), Bash(atelier-orient:*), Bash("${CLAUDE_PLUGIN_ROOT}"/hooks/sync-notification-hook.sh), Read, AskUserQuestion
---

You are running `/atelier:refresh`, a deprecated alias.

Tell the operator once, in their language: "`/atelier:refresh` was renamed to `/atelier:reload`." Then `Read` `${CLAUDE_PLUGIN_ROOT}/commands/reload.md` and follow it exactly, as if the operator had run `/atelier:reload`.
