# TASK_021 — M9.4 — Two-way migration: files ↔ github-project (+ generalized backend → files)

**Sub-task of [TASK_002 / M9](TASK_002_m9-github-projects-backend.md).** Extend `/migrate-roadmap` for `files ↔ github-project` **both** directions, and implement the **generalized `backend → files` reverse path** (which also finally unlocks `linear → files`, currently "not yet implemented") — §16.6.

**Acceptance:** migrate a `files` project to `github-project` and back losslessly (tasks, buckets, ids, history preserved per the field mapping); `linear → files` also works via the generalized reverse path. Orphan/partial-migration guards mirror the existing `files → linear` safety rules.

---

**Decomposed into 3 sub-tasks (M9.4) — 2026-06-23.** The reverse path is a single mechanism (`backend → files`) driven by `RoadmapBackend.listTasks` across the three buckets, parameterized by backend so `github-project → files` and `linear → files` are the same code path. Splitting along the engine-vs-consumer seam keeps every PR a single reviewable prose slice under the 200-line budget (binding constraint: line count, since the deliverables are pure-prose markdown). **Every sub-task's deliverable lands in `claude-roadmap-tools` (not atelier-dev)** — this task is tracked here but built there, mirroring the #19 epic. Order: 21a is the engine (dependency); 21b and 21c are thin consumers that layer on it and can land in either order once 21a is merged.

### #21a — Generalized `backend → files` reverse engine + contract

**Deliverable repo:** `claude-roadmap-tools`. Files: `commands/migrate-roadmap.md` (new `### 5d. <remote backend> → files (indexed)` step, sibling to 5b/5c) + `docs/RoadmapBackend.md` (reverse-read contract addition).

- Add a new step `5d` to `migrate-roadmap.md`: reconstruct the full `files` (indexed) layout from any remote backend via `listTasks` across all three buckets (`roadmap` / `in_progress` / `history`), parameterized by source backend (works for both `linear` and `github-project` — one path).
- Map remote Status / labels back to §5 priority sections + `[ready]` marker + `blocked_by:` on the local side, inverting the forward field mapping in `RoadmapBackend.md`.
- Preserve the `TASK_NNN` human handle and `backendId` when reconstructing each `roadmap/TASK_NNN_*.md`; match by `backendId`, not title/slug (same coherence rule as `## Mirror auto-refresh on activation` in `SKILL.md`).
- Atomic write to a clean tree; **remove `.roadmap.json` as the inverse atomic checkpoint** (its absence after a successful reverse migration means the local `files` layout is now authoritative). Mirror the existing `files → linear` safety template: partial-failure / orphan guards, per-bucket safe-failure, and **never destroy the remote source** on partial failure.
- Add the matching reverse-read contract notes to `docs/RoadmapBackend.md` (how `listTasks` is consumed in reverse to rebuild the local tree; backendId coherence; per-bucket safe-failure).
- This is the heart; 21b and 21c are thin consumers. Matrix rows stay ❌ until their consumer sub-task flips them.

### #21b — `github-project ↔ files` matrix + wiring

**Deliverable repo:** `claude-roadmap-tools`. File: `commands/migrate-roadmap.md`.

- Flip the `github-project → files` Direction-matrix row (currently ❌ "out of scope for v1") to ✅, pointing at step 5d.
- Wire `--to files` from a `github-project` source through the reverse engine (steps 2/3/4 routing + the source-backend refusal at step 1 no longer blanket-refuses migrating away from `github-project`).
- Document the lossless round-trip fidelity contract (`files → github-project → files`: what is preserved vs inherently lossy) and update the args / report / safety prose.
- Decide and document that `linear ↔ github-project` stays ❌ (route via `files`); leave matrix row 177 as ❌ with that rationale.

### #21c — `linear → files` unlock + validation

**Deliverable repo:** `claude-roadmap-tools`. Files: `commands/migrate-roadmap.md` + (if needed) `skills/roadmap-tracking-flow/SKILL.md`.

- Flip the `linear → files` Direction-matrix row (currently ❌ "out of scope for v1") to ✅, reusing the same reverse engine with `backend = linear` (no new engine code — pure unlock + routing).
- Validate the round-trip (`files → linear → files`) and document any backend-specific fidelity notes.
- Update the `SKILL.md` cross-reference if the reverse path changes the Mirror auto-refresh prose's neighbouring claims.
