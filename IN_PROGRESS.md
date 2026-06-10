# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M4.29 — Import an existing operator's Claude conversations on first atelier use

`[onboarding]` · Source: operator request (2026-06-05) · Related: [operator-rules.md:166](operator-rules.md#L166) (`CLAUDE_CONFIG_DIR` separation), M7.1.F53

Atelier runs under a config root (`$ATELIER_CONFIG_DIR`, default `~/.claude-work/`) **separate** from the operator's personal `~/.claude/`. A side effect for someone who already uses Claude Code: their existing conversation history lives under the personal root (`~/.claude/projects/<cwd-hash>/*.jsonl`) and does **not** appear in atelier sessions — `claude --resume` / `--continue` inside an `atelier()` session sees an empty history. This makes adopting atelier feel like starting from scratch. Give the operator a way to bring their prior conversations across so they are not lost.

**Scope:**

- [ ] Decide the import mechanism: copy vs symlink the per-project transcript dirs (`projects/<cwd-hash>/`) from `~/.claude/` into `$ATELIER_CONFIG_DIR/`. Weigh that `<cwd-hash>` is path-derived — same working dir hashes the same under both roots, so transcripts map 1:1.
- [ ] Make it opt-in and selectable: import all projects, or pick specific project dirs (the operator may not want every personal conversation inside atelier).
- [ ] Decide the entry point: a step in `install.sh` onboarding and/or a dedicated `atelier-import-conversations` helper + `/atelier:import-conversations` command for later runs.
- [ ] Be non-destructive: never move or delete from the personal root; never overwrite an atelier transcript that already exists.
- [ ] Scope to conversation transcripts only — do **not** import personal `CLAUDE.md`, memory, or settings (those must stay isolated; importing them would re-introduce the leak M7.1.F53 fixes).
- [ ] Document in the operator guide what is and isn't imported, and that it is a one-time/opt-in convenience.

**Acceptance:** an operator with prior `~/.claude/` conversations runs the import (at install or via the command) and, inside an `atelier()` session for the same project, `claude --resume` lists those prior conversations; the personal root is untouched and no personal `CLAUDE.md` / settings cross over.

**Decisions taken (during implementation):**

- **Mechanism = copy, not symlink.** A directory symlink would route atelier's *new* per-project transcripts back into the personal root (`~/.claude/projects/<dir>/`), mixing atelier history into the personal config — violating "personal root is untouched". A per-file copy of existing `*.jsonl` snapshots prior history and lets atelier diverge cleanly. The `<cwd-hash>` is the project path with non-alphanumerics → `-` (e.g. `-Users-mike-Work-storefront`), identical under both roots, so dirs map 1:1.
- **Entry point = both.** Durable: `scripts/atelier-import-conversations` helper + `/atelier:import-conversations` command (symlinked into `~/.local/bin`). First-use: a guarded, opt-in, fail-open step in `install.sh` Phase C.1 (`phase_c_1_import_conversations`) that only prompts when importable personal transcripts exist and a TTY is present; defaults to "no".
- **Selectivity:** default interactive numbered menu (all / pick); `--all`, positional project paths, `--yes`, `--dry-run`, `--list`.
- **Transcripts only:** copies `*.jsonl` files; never `CLAUDE.md`, memory, settings, or `.claude.json`.

**Trigger to revisit:** requested by the operator 2026-06-05 while reasoning about the personal-vs-atelier config split. Natural companion to M7.1.F53 — same separation boundary, opposite direction (F53 keeps personal *rules* out; this lets personal *history* in, deliberately and scoped).
