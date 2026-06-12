---
description: Import your prior Claude Code conversation transcripts from your personal `~/.claude` into atelier's separate config root, so `claude --resume` inside an atelier session can see them. Copies transcripts only — never your personal CLAUDE.md / memory / settings, never overwrites an existing atelier transcript, never touches the personal root.
argument-hint: "[--all] [--list] [--dry-run] [--yes|-y] [project-path ...]"
allowed-tools: Bash(atelier-import-conversations:*), AskUserQuestion
---

You are running the `/atelier:import-conversations` slash command. This is a thin wrapper around the `atelier-import-conversations` bash binary, which copies prior conversation transcripts from the operator's personal config root (`~/.claude`) into atelier's separate `$ATELIER_CONFIG_DIR`.

## What to do

Run the binary, forwarding `$ARGUMENTS` verbatim, and pass its stdout to the operator unchanged. The binary handles enumeration, the copy, and all reporting — and the interactive picker when a TTY exists (see the no-TTY fallback below for when it doesn't).

```bash
atelier-import-conversations $ARGUMENTS
```

Then output whatever the binary printed, unchanged.

## No-TTY fallback (conversational picker)

The binary's interactive picker needs a TTY, which slash-command `Bash` calls do not have. When the binary exits with the `no TTY for the interactive picker` error, the picker becomes **your** job — do not relay the refusal or suggest terminal commands to the operator. Instead:

1. Run `atelier-import-conversations --list` (read-only) and show the catalog it prints, unchanged.
2. If the catalog is empty, stop — there is nothing to import.
3. Ask which projects to import with `AskUserQuestion` (multi-select): one option per project when they fit, plus an "All projects" option. With more projects than options fit, offer "All projects" and "Pick by name" (names arrive via the free-text reply). Option labels use the project names exactly as `--list` printed them.
4. Re-invoke the binary with the selection: the chosen project names verbatim as positional selectors, or `--all` when the operator chose "All projects". Carry over any flags from the original `$ARGUMENTS` (e.g. `--dry-run`).
5. Output the binary's report unchanged.

In non-interactive runs (`claude -p`, `$ATELIER_AUTO`) `AskUserQuestion` would hang the session: print the catalog plus a one-line recommendation to re-run `/atelier:import-conversations` interactively (or with `--all` / explicit paths), and stop.

## Stop rule

Your turn ends when you finish emitting the binary's last line. No commentary, no "everything looks good", no follow-up suggestions. Same rule as `/atelier:doctor`: the binary already produced the report the operator wants; anything you add is noise.

## Decision rules

- **Never** invoke any tool other than `Bash(atelier-import-conversations)` and, in the no-TTY fallback only, `AskUserQuestion`. The binary already reads `~/.claude/projects/`, computes new-vs-existing counts, and copies — do not duplicate any of it inline.
- **Never** auto-add `--all` or `--yes` to `$ARGUMENTS`. Defaulting to all-without-asking would import personal conversations the operator may not want inside atelier. A selection made through the no-TTY conversational picker **is** the operator choosing — forward it verbatim, including `--all` when they picked "All projects".
- **Never** bounce the operator to raw terminal commands (`!`-prefixed or otherwise) to work around a missing TTY. The conversational picker above is this command's job.
- **Never** read, copy, or move any file yourself. The binary is the single point of writes; it imports only `*.jsonl` transcripts and is non-destructive (it never overwrites an existing atelier transcript and never modifies the personal root).
- If the operator only wants to see what's available, suggest they pass `--list` (read-only) or `--dry-run` — but only invoke flags they actually asked for.

## Edge cases

- **No prior history**: the binary reports `No importable conversations found` and exits 0. Pass that through verbatim — it's the normal result on a machine with no earlier Claude Code use.
- **No TTY with no selection**: the binary refuses with `no TTY for the interactive picker`. Do not relay that message — switch to the **No-TTY fallback** above.
