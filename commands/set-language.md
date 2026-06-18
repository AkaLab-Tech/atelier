---
description: Set the operator's chat language — the language atelier uses to address you in sessions (chat, status, questions). Persisted in $ATELIER_CONFIG_DIR/operator.json and injected into every session by the SessionStart hook. Separate from .atelier.json deliverableLanguage (commits / PRs / code / docs), which it does not change.
argument-hint: "<language> | --show | --clear"
allowed-tools: Bash(atelier-set-language:*)
---

You are running `/atelier:set-language`. Persist (or show/clear) the operator's
**chat** language — how atelier talks to the operator — without touching
deliverable language (commits / PRs / code / docs stay in `deliverableLanguage`).

Run the helper, passing `$ARGUMENTS` through verbatim:

```bash
atelier-set-language $ARGUMENTS
```

- No arguments → run `atelier-set-language --help` and ask the operator which
  language they want (then re-run with it). Accept a language name in any form
  (e.g. `Spanish`, `español`, `Brazilian Portuguese`).
- Relay the helper's stdout verbatim.

After a successful set, tell the operator (in their language) that it takes
effect in **new** sessions — the current session already has its context loaded,
so it applies from the next `atelier` / `task` session (or they can ask you to
switch for the rest of this one). Do **not** edit `operator.json` yourself — the
helper owns that write.
