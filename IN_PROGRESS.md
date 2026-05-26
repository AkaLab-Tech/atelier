# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### Docs follow-up — README "Daily use" manual

`[docs]` · Source: operator request mid-session, 2026-05-26, prep for the M7.3 observational measurement on dogfood-4

The operator-guide.md covers the full path from zero to first task (M6.2). What was missing was a condensed reference inside README itself — for someone who already has atelier set up and is about to dogfood. Captured as a follow-up to the ship-path sweep, not a numbered milestone.

**Scope:**

- [ ] Add a `## Daily use` section to README between "First time?" and "Already have Claude Code + GitHub set up?". Five numbered steps: (1) `/atelier:setup-project`, (2) write a task, (3) run `task`, (4) inspect results, (5) measure with `atelier-measure-merge-rate`. Plus a "When something doesn't work" cross-link to `troubleshooting.md` and a "Pause / abandon / reset" section.
- [ ] Step 5 prominently calls out the `--sample 10 --threshold 80` defaults + the auto-detection of repo/author/reviewer so the operator can copy-paste it as-is during the M7.3 observational run.

**Out of scope:**

- Restructuring the operator-guide.md — it stays as the long-form reference.
- Tests / scripts — pure README work.
