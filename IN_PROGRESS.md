# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M7.1.F7c — Shellrc block needs versioning + auto re-injection on install.sh re-run

`[ux-blocking]` · Source: M7.1 PR-E ([#75](https://github.com/AkaLab-Tech/atelier/pull/75)) live validation (2026-05-25)

`phase_c_1_shellrc_hooks` is idempotent by sentinel detection: it greps for `# >>> atelier hooks (managed by install.sh) >>>` and short-circuits with `step_skip` when found. Operators upgrading from one atelier version to a later one (e.g. v0.4.2 → v0.5.0, where F7b added `GIT_CONFIG_GLOBAL` to `task()`) will NOT get the new shellrc block automatically — they have to manually strip the block between sentinels and re-run `install.sh`. The block's docstring already mentions this manual procedure, but it's a real UX gap for plugin upgrades.

**Scope:**

- [ ] Embed a `# atelier-hooks-version: N` line inside the heredoc block, incremented each time the block contents change.
- [ ] `phase_c_1_shellrc_hooks` parses the existing block's version line; if missing or older than the current script's version, strip + re-inject instead of skipping.
- [ ] Print a clear `→ refreshing atelier shellrc block (vX → vY)` message when the upgrade path triggers, so operators understand why their shellrc changed.
- [ ] Document the contract inside the block (one-line header comment) so future maintainers know to bump the version when they edit the block contents.

**Acceptance:** running `./install.sh` against a `~/.zshrc` with an older-version atelier block re-injects the current block, replacing the old one in place. The sentinels stay stable so block discovery still works; only the body changes.

**Trigger to revisit:** captured 2026-05-25 during the F7b live validation, when the operator's existing shellrc block lacked the new `GIT_CONFIG_GLOBAL` export and `step_skip "atelier hooks already present in .zshrc"` silently swallowed the upgrade. Manual workaround documented in v0.5.0 release notes; a code fix should land before M7.2 (network allowlist iteration) so subsequent install.sh changes propagate automatically.
