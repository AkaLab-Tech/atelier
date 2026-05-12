# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

<!-- Single-file layout: paste the task block from ROADMAP.md here. -->
<!-- Indexed layout: link to roadmap/TASK_NNN_<slug>.md and write progress notes inside that file, not here. -->

### M1.2 — Plugin manifest and marketplace

Author `.claude-plugin/plugin.json` (name `atelier`, version, description, author) and `.claude-plugin/marketplace.json` (marketplace name `akalab-tech`) so the plugin can be installed via `/plugin marketplace add <local-path>` → `/plugin install atelier@akalab-tech`.

> **Decisions made during M1.2:**
>
> 1. The `skills: "./skills/"` field originally mentioned in the M1.2 description was dropped from `plugin.json`. The Claude Code plugin schema scans `skills/` automatically and any `skills` entry is *added* to the default, so listing it explicitly is redundant. PLAN.md §12 updated in the same PR.
> 2. The marketplace name was changed from `atelier` to `akalab-tech` (vendor-scoped). With `atelier@atelier`, `/plugin install` returned `Plugin "atelier" not found in any marketplace` — colliding name confused the resolver. Renaming the marketplace fixed the install end-to-end while keeping the plugin name `atelier` and the flat-root layout (plugin source `"./"`). Forward-compatible: future AkaLab-Tech plugins can be added to the same marketplace without renaming.

- [x] Write `plugin.json` with semver and required fields.
- [x] Write `marketplace.json` exposing this repo as a marketplace entry.
- [x] Validate end-to-end in a clean Claude Code install: `marketplace add` succeeds → `install` reports `✓ Installed atelier. Run /reload-plugins to apply.`
- [ ] Final check: `/reload-plugins` in an operator session loads the plugin without errors (deferred until session reload).

**Acceptance:** a new Claude Code session can install the plugin from a local checkout without errors and the plugin appears in `~/.claude/plugins/` (or equivalent cache).

**Branch:** `setup/m1.2-plugin-manifest`
