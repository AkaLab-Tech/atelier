# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M6.2 — Operator guide

`[docs]` · Source: PLAN.md §12 Phase 6, M6.2

Junior-friendly walkthrough: clone → install → first task. No git/branching/PR jargon. Acceptance per PLAN.md: "a Jr following only the operator guide can clone, install, and run a full task cycle on a pre-configured project."

**Scope:**

- [ ] Create `docs/operator-guide.md` covering the full path from zero to first task:
  - What atelier is (one paragraph, plain language)
  - What you need (Mac/Linux, internet, two GitHub accounts)
  - Step 1: Download atelier (one command)
  - Step 2: Run installer (one command, two browser prompts)
  - Step 3: Set up your first project (one slash command)
  - Step 4: Run your first task (one shell command)
  - What to do if something goes wrong (forward-reference to M6.4 troubleshooting doc, which is not landed yet)
- [ ] Update `README.md` to point new users at the operator guide as the primary entry point; keep the existing terse install snippet for already-configured users.
- [ ] Read the result as if I were a Jr who never used atelier — verify no unexplained jargon, every step's "expected output" is described, and every "if X breaks" path has a recovery hint.

**Acceptance:** `docs/operator-guide.md` exists with all four numbered steps + a "what is atelier" intro + a "what you need" prerequisites section + a "things to know" honest-friction section (two GitHub accounts, ~2-3 hour first install). `README.md` links to it prominently. No occurrence of `branch`, `worktree`, `PR`, `commit`, `merge`, `lint`, `typecheck` in the guide body (these are AI-internal concepts the operator never sees).

**Out of scope:**

- M6.3 (product owner guide on how to write ROADMAP.md format) — separate milestone, separate PR.
- M6.4 (troubleshooting doc) — separate PR, but cross-referenced from the operator guide.
- Updating PLAN.md or any agent prompts — pure docs work.
- A video tutorial or screen-by-screen screenshots — text-only for v1.
