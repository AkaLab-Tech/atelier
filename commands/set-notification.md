---
description: Toggle atelier's audible cues — three independent opt-in cues, namely the input cue (Notification hook events — questions / permission prompts), the task-complete cue (fired on merge success), and the task-blocked cue (fired when a hard-stop issue opens). Persisted in $ATELIER_CONFIG_DIR/operator.json under a nested .notification object, alongside (never clobbering) chat language or other keys. Off by default; the plugin never forces sound on.
argument-hint: "on [--sound <name|path>] | off | task-complete on|off [--sound <name|path>] | task-blocked on|off [--sound <name|path>] | --show | --clear"
allowed-tools: Bash(atelier-set-notification:*)
---

You are running `/atelier:set-notification`. Persist (or show/clear) the
operator's audible-cue preferences — three independent cues — without
touching any other `operator.json` key:

- **input cue** (bare `on`/`off`) — Notification hook events (questions /
  permission prompts).
- **task-complete cue** (`task-complete on|off`) — fired by the auto-merge
  skill right after a PR merges successfully.
- **task-blocked cue** (`task-blocked on|off`) — fired by the unblocker agent
  right after it opens a `[blocked]` GitHub issue.

Run the helper, passing `$ARGUMENTS` through verbatim:

```bash
atelier-set-notification $ARGUMENTS
```

- No arguments → run `atelier-set-notification --help` and ask the operator
  which cue(s) they want to change and whether on or off (then re-run with
  their answer). Accept an optional `--sound <name|path>` hint when turning a
  cue on — a bare name resolves against the platform's built-in sounds, a
  path is used as-is, and either falls back silently to the platform default
  if unresolvable. Each cue has its own independent default sound and its
  own optional override.
- `--show` reports the current state of all three cues.
- `--clear` unsets all three (reverts every cue to its default: off).
- Relay the helper's stdout verbatim.

After a successful `on`/`off`/`--clear` on the **input cue**, tell the
operator that it takes effect in **new** sessions — the current session's
hooks are already loaded, so it applies from the next `atelier` / `task`
session. The **task-complete** and **task-blocked** cues have no session
dependency — they apply to the very next merge / hard-stop. Do **not** edit
`operator.json` yourself — the helper owns that write and (for the input cue
only) also reconciles the Notification hook in `settings.json` immediately.
