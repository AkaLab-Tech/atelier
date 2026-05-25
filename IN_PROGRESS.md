# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M2.5 — Extend static permission matrix with destructive-command synonyms

`[security-hardening]` · Source: design conversation (2026-05-25)

[templates/settings.template.json](templates/settings.template.json) covers the obvious destructive commands (`rm -rf`, `git push --force`, edits to `.github/workflows/**`) but misses semantically-equivalent synonyms an agent might emit: low-level destructive utilities (`dd`, `shred`), find-based deletion (`find ... -delete`), `gh api --method <verb>` (parallel to the existing `-X <verb>` deny), and arbitrary-code interpreters used as a re-packaging vector (`node -e`, `python -c`, `bash -c`).

Refines [PLAN.md §11 v2.3](PLAN.md) (`PermissionRequest` Bash hook) — that deferred hook is now scoped as **layer 3** of a three-layer defense: (1) the static matrix in `settings.template.json`, (2) the M2.4 pattern hooks, (3) an LLM-backed evaluator (native auto-mode, custom hook, or both — decided in M2.6) for commands layers 1+2 don't enumerate. Layer 3 is last resort, not first responder.

**Scope:**

- [ ] Add to `templates/settings.template.json` `deny`: `dd if=*`, `shred*`, `truncate -s 0 *`, `truncate --size=0 *`, `find * -delete`, `find * -exec rm *`, `find * -exec rm -rf *`, fork-bomb literal, `gh api --method POST/PATCH/DELETE/PUT*`, `gh api -X PUT*`.
- [ ] Add to `templates/settings.template.json` `ask`: `node -e *`, `python -c *`, `python3 -c *`, `perl -e *`, `ruby -e *`, `bash -c *`, `sh -c *`, `zsh -c *`, `* | sudo *`.
- [ ] Refine [PLAN.md §11 v2.3](PLAN.md) to reflect the three-layer framing and defer the A/B/C choice to M2.6. Add a one-line forward-reference in [PLAN.md §3](PLAN.md) noting layer 3 is deferred.
- [ ] Document explicitly which destructive shapes are **intentionally not** matched by the static matrix (shell redirections, `xargs ... rm`, context-dependent `mv` destinations) so the rationale for layer 3 is preserved.

**Acceptance:** `grep -E "Bash\\(dd|shred|node -e|bash -c" templates/settings.template.json` returns the new patterns. [PLAN.md §11](PLAN.md) v2.3 entry mentions "layer 3 of three" and references M2.6 for the option decision.

**Out of scope:** implementing layer 3 itself (deferred to M2.6 + v2.3). Modifying the M2.4 pattern catalogues (separate work; this task only touches the static matrix + PLAN docs).

**Trigger to revisit:** captured during the design conversation that converged on the three-layer architecture. Lands before M2.6's spike so the static layer carries its full weight and layer 3's perceived value is calibrated against what patterns already filter.
