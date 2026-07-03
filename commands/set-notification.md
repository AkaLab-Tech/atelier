---
description: Toggle the operator's notification sound — an audible cue atelier plays on Notification hook events (questions / permission prompts). Persisted in $ATELIER_CONFIG_DIR/operator.json under a nested .notification.{enabled,sound} object, alongside (never clobbering) chat language or other keys. Off by default; the plugin never forces sound on.
argument-hint: "on [--sound <name|path>] | off | --show | --clear"
allowed-tools: Bash(atelier-set-notification:*)
---

You are running `/atelier:set-notification`. Persist (or show/clear) the
operator's notification-sound preference — whether atelier plays an audible
cue on Notification hook events (questions / permission prompts) — without
touching any other `operator.json` key.

Run the helper, passing `$ARGUMENTS` through verbatim:

```bash
atelier-set-notification $ARGUMENTS
```

- No arguments → run `atelier-set-notification --help` and ask the operator
  whether they want it on or off (then re-run with their answer). Accept an
  optional `--sound <name|path>` hint when turning it on — a bare name
  resolves against the platform's built-in sounds, a path is used as-is, and
  either falls back silently to the platform default if unresolvable.
- Relay the helper's stdout verbatim.

After a successful `on`/`off`/`--clear`, tell the operator that it takes
effect in **new** sessions — the current session's hooks are already loaded,
so it applies from the next `atelier` / `task` session. Do **not** edit
`operator.json` yourself — the helper owns that write and also reconciles
the Notification hook in `settings.json` immediately.
