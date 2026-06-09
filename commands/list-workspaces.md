---
description: List every workspace registered with atelier in `$ATELIER_CONFIG_DIR/workspaces.json`, with each member's on-disk status. Read-only — never modifies state.
allowed-tools: Bash(atelier-list-workspaces:*)
---

You are running the `/atelier:list-workspaces` slash command.

## What to do

Run the `atelier-list-workspaces` bash binary in its default mode and pass its stdout to the operator verbatim. The binary handles formatting; do not rewrap, summarize, or commentate.

```bash
atelier-list-workspaces
```

Then output whatever the binary printed, unchanged.

## Stop rule

Your turn ends when you finish emitting the binary's last line. No commentary, no follow-up suggestions — same rule as `/atelier:list-projects` and `/atelier:doctor`: the binary already produced the structured report; anything you add is noise.

## Decision rules

- **Never** invoke any tool other than `Bash(atelier-list-workspaces)`. The binary already reads `$ATELIER_CONFIG_DIR/workspaces.json` and computes each member's on-disk status; do not duplicate.
- **Never** modify any file — this is read-only by design.
- **Never** suggest fixes inline. For the aggregated per-workspace task/blocked view use `/atelier:workspace-status`; to drop a workspace use `/atelier:remove-workspace`.
