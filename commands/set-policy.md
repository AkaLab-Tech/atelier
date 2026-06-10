---
description: Configure or revise the per-project decision-broker policy. Walks through each catalogued category and asks the operator how atelier should handle it — auto, ask, or fix to the catalog default. Writes the result to `<project>/.atelier.json` under `decisionPolicy.byCategory`. Use this command after `/atelier:setup-project` if the operator skipped the interactive policy step (or used `--skip-policy`), or any time the operator wants to revise their answers without re-running the full setup.
argument-hint: "[category]"
allowed-tools: Read, Edit, AskUserQuestion, Bash(jq:*), Bash(cat:*), Bash(ls:*)
---

You are running the `/atelier:set-policy` slash command. Your job is to walk the operator through the **decision-broker catalog** one category at a time and capture their per-category policy in the project's `.atelier.json` under `decisionPolicy.byCategory`. You do NOT run any task work yourself — you only edit configuration.

If the operator provided an argument (`$ARGUMENTS`), it is a single category id (e.g. `baseline-conflict`). Walk only that category. If empty, walk every category in the catalog.

## Pre-flight

1. Resolve the catalog path: `$CLAUDE_PLUGIN_ROOT/agents/decision-broker/catalog.json`. If the env var is not set in this session, fall back to a `Glob` over `agents/decision-broker/catalog.json` from the plugin checkout (the only place it lives). If neither path resolves, surface clearly: *"decision-broker catalog not found. Re-run install.sh and try again."* and stop.

2. Read `$ARGUMENTS`. If non-empty, validate it against the catalog's `.categories` keys. If unknown, surface available categories and stop without writing anything.

3. Locate `.atelier.json` for the current project. The Read tool against `./.atelier.json` (cwd is the project root inside an atelier session). If the file does not exist, surface: *"`.atelier.json` is missing — run `/atelier:setup-project` first."* and stop. **Do NOT create the file from this command** — `setup-project` owns its creation.

4. Read the file's current `decisionPolicy.byCategory.<category>` value for context. The current value is one of: a fixed option id (e.g. `"fix-first"`), `"auto"`, `"ask"`, or missing (which means "fall back to decisionPolicy.default"). Show this current value to the operator when asking — it makes "keep current" the obvious choice when they don't want to change it.

## Per-category prompt

For each category you walk:

1. **Read the catalog entry** for that category: `description`, `options[]`, `default`, `riskLevel`, `model`.

2. **Use `AskUserQuestion`** with a single question of multi-select=false, presenting these options in this order:

   - **Auto** — atelier decides per-case using the catalog-defined evaluator agent (Haiku for `low`, Sonnet for `medium`, Opus for `high`). Description should say *"Atelier picks one of the catalog options every time the situation arises. Logged in the PR body so you can review and challenge any decision."*

   - **Fix to default** — always pick the catalog's `default` option (e.g. `fix-first`) without thinking. The option label includes the default id so the operator sees exactly what they're committing to. Description should say *"No evaluator is invoked; atelier always picks the same option. Cheapest mode — zero LLM cost per decision — but inflexible to context."*

   - **Ask** — atelier asks you through `AskUserQuestion` every time the situation arises. Current behaviour for unconfigured categories. Description should say *"Maximum control; you make every call. Costs you wall-clock time during long tasks."*

   - **Keep current** — only show this option if the operator already has a non-default value set for this category. The label includes the current value so the operator sees what would persist if they pick this.

3. **Translate the choice to a JSON value:**

   - "Auto"     → `"auto"`
   - "Fix to default" → the catalog's `default` value (the literal option id, e.g. `"fix-first"`)
   - "Ask"      → `"ask"`. **Special case**: if `decisionPolicy.default` in `.atelier.json` is also `"ask"` (the template default), you may DELETE the `byCategory.<category>` entry instead of writing `"ask"` — equivalent semantics, less noise in the file. Prefer the delete for the common case.
   - "Keep current" → no change.

4. **Update `.atelier.json`** via `Edit`. Use `jq` semantically through `Bash(jq:*)` to merge the new value into `decisionPolicy.byCategory.<category>`, then read the result back and write it via `Edit`. The `Edit` tool ensures the file change goes through atelier's standard write path (including the safety hooks).

   Pattern (illustrative):

   ```bash
   tmp="$(mktemp)"
   jq --arg c "<category>" --arg v "<choice>" \
     '.decisionPolicy.byCategory[$c] = $v' \
     .atelier.json > "$tmp" && cat "$tmp"
   ```

   Then `Edit` the file with the new content. Never write directly with `Bash`; always go through `Edit`.

## Final report

After walking all requested categories, print a compact summary the operator can scan:

```text
Decision policy updated in .atelier.json:

  baseline-conflict:           auto       (was: ask)
  oversize-handling:           slice-task (was: ask)
  scope-creep-detected:        ask        (unchanged)
  merge-conflict-tracking:     auto-resolve (was: ask)
  merge-conflict-substantive:  ask        (unchanged)

Default for unlisted categories: ask
```

Categories the operator did not visit (when `$ARGUMENTS` was a single category) are not listed in the summary.

## Hard refusals

- **Never** create `.atelier.json` from this command. If the file is missing, point at `/atelier:setup-project` and stop.
- **Never** edit the catalog. If the operator wants a new category, surface a friendly: *"The catalog is atelier-managed; report this case at github.com/AkaLab-Tech/atelier/issues and a future version will add it. Falling back to `ask` for now."*
- **Never** invoke `task-orchestrator`, the broker skill, or any specialist agent from this command. `/atelier:set-policy` is configuration-only.
- **Never** write any field of `.atelier.json` other than `decisionPolicy.byCategory.<category>` — leave the rest of the file untouched.

## Edge cases

- **Operator runs the command inside a task worktree** (branch starts with `task/`): refuse with *"`.atelier.json` belongs on `main`. Run `/atelier:set-policy` from the main worktree."* — same hard rule the `/atelier:slice-task` command uses for the same reason.
- **Catalog has a category not yet in `.atelier.json`**: write the new entry on first answer. Normal case for fresh installs that ran `--skip-policy` during setup.
- **`.atelier.json` is missing `decisionPolicy.byCategory`** (operator manually pruned it): create the object on first answer with `jq '.decisionPolicy.byCategory //= {}'` semantics.
- **Operator pressed Esc / cancelled `AskUserQuestion`** mid-walk: stop walking, do NOT write partial state, surface *"Stopped at `<category>`. Already-answered categories were saved. Run `/atelier:set-policy` again to continue."*
