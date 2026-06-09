---
description: Unregister a workspace. By default removes ONLY the grouping from `$ATELIER_CONFIG_DIR/workspaces.json` — the member projects stay registered and configured. `--with-members` also deconfigures each member via `atelier-remove-project` (destructive, off by default). Wraps `atelier-remove-workspace`.
argument-hint: "<slug> [--with-members] [--yes|-y]"
allowed-tools: Bash(atelier-remove-workspace:*)
---

You are running the `/atelier:remove-workspace` slash command — the front for the `atelier-remove-workspace` host-OS helper.

## What to do

Pass the operator's arguments through to the binary verbatim:

```bash
atelier-remove-workspace $ARGUMENTS
```

The binary handles everything: it validates the slug, lists what will happen, asks for confirmation (interactive) unless `--yes`/`-y`/`$ATELIER_AUTO`, removes the workspace entry, and — only with `--with-members` — runs `atelier-remove-project` on each member. Relay its stdout/stderr verbatim.

## Decision rules

- **Default is non-destructive to members.** Without `--with-members`, only the grouping is removed; the member projects remain registered (`/atelier:list-projects` still shows them). Do not add `--with-members` unless the operator explicitly asks to also deconfigure the member projects.
- **Never** edit `workspaces.json` or `projects.json` yourself — only the helper touches them.
- **Confirmation belongs to the binary.** In an interactive session let the binary prompt; do not pre-confirm on the operator's behalf. Pass `--yes` only when the operator already said so or `$ATELIER_AUTO` is set.
- Exit codes: `0` removed (or slug not registered — nothing to do), `2` operator declined, `1` error. Surface the binary's message verbatim and stop.
