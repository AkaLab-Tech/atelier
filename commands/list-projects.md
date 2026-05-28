---
description: List every project registered with atelier in `$ATELIER_CONFIG_DIR/projects.json`, with a per-project on-disk status (configured / partial / missing-directory). Read-only — never modifies state.
allowed-tools: Bash(atelier-list-projects:*)
---

You are running the `/atelier:list-projects` slash command.

## What to do

Run the `atelier-list-projects` bash binary in its default mode and pass its stdout to the operator verbatim. The binary handles formatting; do not rewrap, summarize, or commentate.

```bash
atelier-list-projects
```

Then output whatever the binary printed, unchanged.

## Stop rule

Your turn ends when you finish emitting the binary's last line. No commentary, no "everything looks good", no follow-up suggestions. Same rule as `/atelier:doctor` (M7.1.F25): the binary already produced the structured report the operator wants; anything you add is noise.

## Decision rules

- **Never** invoke any tool other than `Bash(atelier-list-projects)`. The binary already reads `$ATELIER_CONFIG_DIR/projects.json` and computes the per-project status; do not duplicate.
- **Never** modify any file — this is read-only by design.
- **Never** suggest fixes inline. If a project shows `⚠ partial` or `✗ missing-directory`, the binary's own status line already tells the operator what to do (`re-run setup-project` or `atelier-remove-project`).
