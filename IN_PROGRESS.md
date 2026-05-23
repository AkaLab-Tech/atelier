# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M5.0.4 — Release policy + versioning convention for atelier plugins

`/atelier:doctor`'s drift check for `atelier`, `claude-roadmap-tools`, and `git-wt` compares the local `plugin.json:version` (or installed CLI version) against the upstream's `releases/latest` tag (with fallback to `tags[0]`). For that comparison to mean anything, releases / tags must actually be created — and the convention for **when** and **how** has not been written down anywhere. The initial `v0.1.0` releases were cut ad-hoc on 2026-05-22 to recover `/doctor`'s functionality; this milestone captures the policy so future releases stop being ad-hoc.

**Open questions to answer (in order):** see ROADMAP entry for the 7 questions.

**Acceptance:** decisions captured in `PLAN.md` as a new §N marked `✅ agreed`; `/doctor` continues to report `up to date` after.

**Progress notes:** worktree `docs/m5.0.4-release-policy` created 2026-05-23 from `c378bb4` (post-#63 merge). Pending operator input on 7 questions.
