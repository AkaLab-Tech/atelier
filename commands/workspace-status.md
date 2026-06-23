---
description: Show an aggregated, read-only status dashboard for one atelier workspace — one row per member (on-disk status, in-progress task, open-task count, cross-repo-blocked count) plus a list of every member task whose cross-repo `blocked_by:<token>#id` is not yet satisfied. Wraps `atelier-workspace-status`. Read-only — never modifies state.
argument-hint: "[workspace-slug]"
allowed-tools: Bash(atelier-workspace-status:*)
---

You are running the `/atelier:workspace-status` slash command.

## What to do

Run the `atelier-workspace-status` bash binary and pass its stdout to the operator verbatim. The binary computes the dashboard (member rows + cross-repo-blocked section); do not rewrap, summarize, or commentate.

```bash
atelier-workspace-status $ARGUMENTS
```

When `$ARGUMENTS` is empty the binary resolves the workspace from the current directory (a workspace root or a registered member). Pass a `<workspace-slug>` through verbatim when the operator gives one. Then output whatever the binary printed, unchanged.

## Stop rule

Your turn ends when you finish emitting the binary's last line. No commentary, no "everything looks good", no follow-up suggestions — same rule as `/atelier:list-projects` and `/atelier:doctor`: the binary already produced the structured report the operator wants; anything you add is noise.

## Decision rules

- **Never** invoke any tool other than `Bash(atelier-workspace-status)`. The binary already reads `$ATELIER_CONFIG_DIR/workspaces.json`, each member's tracking files, and resolves cross-repo dependencies via `atelier-resolve-dep`; do not duplicate.
- **Never** modify any file — this is read-only by design (it does not touch the registries, the members, or any worktree).
- **Never** suggest fixes inline. If the binary exits non-zero (exit 2 = could not resolve a workspace), surface its stderr verbatim; its message already tells the operator what to do (pass a slug, or run from a workspace root/member).
- **`/status` vs `/workspace-status`**: `/status` is single-project (the current repo). `/workspace-status` is the cross-member roll-up. Do not substitute one for the other.
- **Mixed-backend cells**: when a workspace member uses a non-`files` backend (e.g. `github-project`, `linear`), the open-task count shows `backend:<name>` and the roadmap-format cell shows `backend:<name>` — the backlog lives remotely and is not counted offline. A `backend-deferred` verdict in the cross-repo-blocked section means the blocking member's backend must be consulted by the AI layer (via `RoadmapBackend.getTask`/`listTasks`); treat it as unsatisfied until the AI layer confirms otherwise.
