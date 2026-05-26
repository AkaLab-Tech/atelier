# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M6.4 — Troubleshooting doc

`[docs]` · Source: PLAN.md §12 Phase 6, M6.4

Common failure modes + recovery, indexed for fast lookup by an operator under stress. Includes the two specific items captured in dogfood-1 (same-identity self-approval limitation; permission-cache mis-alignment post worktree reset) plus the failure modes derivable from the system's design (auth expiry, plugin not loading, hooks blocking, `.npmrc` guardrail false-positives, `git-wt` misconfigured).

**Scope:**

- [ ] Create `docs/troubleshooting.md` with sections: "first step: run the doctor", "setup-time problems", "runtime problems", "when all else fails", "reset everything".
- [ ] Cross-link from `docs/operator-guide.md` (replace the "coming soon" placeholder).
- [ ] Cross-link from `README.md`'s "Other docs" section.

**Acceptance:**

- `docs/troubleshooting.md` exists with at least 10 named failure modes, each with: symptom, cause, fix. Includes both dogfood-1 findings (#11 + B) verbatim per ROADMAP.
- Every section starts with the symptom the operator sees, not the underlying cause — operators search for symptoms, not internals.
- The "first step: run the doctor" section appears first.
- Final section documents the nuclear reset path (`atelier-uninstall --purge` + re-clone + re-install) for unrecoverable states.

**Out of scope:**

- Code changes: pure docs work.
- Screenshots / video.
- A bug-reporting CLI tool — the "all else fails" section points operators at the GitHub issues URL.
