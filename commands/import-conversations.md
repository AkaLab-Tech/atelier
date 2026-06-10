---
description: Import your prior Claude Code conversation transcripts from your personal `~/.claude` into atelier's separate config root, so `claude --resume` inside an atelier session can see them. Copies transcripts only — never your personal CLAUDE.md / memory / settings, never overwrites an existing atelier transcript, never touches the personal root.
argument-hint: "[--all] [--list] [--dry-run] [--yes|-y] [project-path ...]"
allowed-tools: Bash(atelier-import-conversations:*)
---

You are running the `/atelier:import-conversations` slash command. This is a thin wrapper around the `atelier-import-conversations` bash binary, which copies prior conversation transcripts from the operator's personal config root (`~/.claude`) into atelier's separate `$ATELIER_CONFIG_DIR`.

## What to do

Run the binary, forwarding `$ARGUMENTS` verbatim, and pass its stdout to the operator unchanged. The binary handles enumeration, the interactive picker, the copy, and all reporting.

```bash
atelier-import-conversations $ARGUMENTS
```

Then output whatever the binary printed, unchanged.

## Stop rule

Your turn ends when you finish emitting the binary's last line. No commentary, no "everything looks good", no follow-up suggestions. Same rule as `/atelier:doctor`: the binary already produced the report the operator wants; anything you add is noise.

## Decision rules

- **Never** invoke any tool other than `Bash(atelier-import-conversations)`. The binary already reads `~/.claude/projects/`, computes new-vs-existing counts, and copies — do not duplicate any of it inline.
- **Never** auto-add `--all` or `--yes` to `$ARGUMENTS`. With no arguments the binary shows an interactive picker so the operator chooses which projects to bring over; defaulting to all-without-asking would import personal conversations the operator may not want inside atelier.
- **Never** read, copy, or move any file yourself. The binary is the single point of writes; it imports only `*.jsonl` transcripts and is non-destructive (it never overwrites an existing atelier transcript and never modifies the personal root).
- If the operator only wants to see what's available, suggest they pass `--list` (read-only) or `--dry-run` — but only invoke flags they actually asked for.

## Edge cases

- **No prior history**: the binary reports `No importable conversations found` and exits 0. Pass that through verbatim — it's the normal result on a machine with no earlier Claude Code use.
- **Non-interactive context (no TTY) with no selection**: the binary refuses and tells the operator to pass `--all` or specific project path(s). Relay that message; do not retry with `--all` on your own.
