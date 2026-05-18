# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

<!-- Single-file layout: paste the task block from ROADMAP.md here. -->
<!-- Indexed layout: link to roadmap/TASK_NNN_<slug>.md and write progress notes inside that file, not here. -->

### M1.5 — Plugin-shipped operator rules (`SessionStart` hook + `operator-rules.md`)

Ship the rules atelier's agents must follow on every task in an atelier-managed project. **Mechanism revised during this PR** based on the [Claude Code plugins reference](https://code.claude.com/docs/en/plugins-reference): a `CLAUDE.md` at the plugin root is **not** loaded as project context ("Plugins contribute context through skills, agents, and hooks rather than CLAUDE.md"). The official path for unconditional context injection is a `SessionStart` hook whose stdout becomes context for the whole session.

- [x] **Resolved mechanism**: `SessionStart` hook in `hooks/hooks.json` runs `hooks/load-operator-rules.sh`, which `cat`s `operator-rules.md` (a clean markdown file at the plugin root). stdout is auto-attached as context per the hook's official output contract. Distinct from the repo-root `CLAUDE.md` (maintainer-facing) and from the operator's personal `~/.claude/CLAUDE.md` (untouched by the plugin).
- [x] **operator-rules.md** written with dep install rules (PLAN.md §4), push/PR/merge gates (§6), failure-recovery retry budget (§8), and a brief routing pointer to the agents in §7.
- [x] **Hook wiring**: `hooks/hooks.json` registers a `SessionStart` hook that invokes `${CLAUDE_PLUGIN_ROOT}/hooks/load-operator-rules.sh` (uses the documented `${CLAUDE_PLUGIN_ROOT}` variable per the plugin reference's "Environment variables" section).
- [x] **Non-collision verified**: the plugin's hook only adds content to the session via stdout; it never writes to or sources the operator's personal `~/.claude/CLAUDE.md`. The two coexist in context (Claude Code merges them) without either overriding the other.

**Acceptance:** in a Claude Code session inside any project where the atelier plugin is enabled, the contents of `operator-rules.md` are present in Claude's context from the first message — verifiable by asking Claude "what are the atelier operator rules?" and getting a faithful summary back. The operator's personal `~/.claude/CLAUDE.md` continues to apply unmodified.

**Branch (current sub-PR):** `setup/m1.5-operator-rules` — single-sub-PR milestone; closes M1.5 by moving this block to `HISTORY.md` in an atomic follow-up commit on this same branch.
