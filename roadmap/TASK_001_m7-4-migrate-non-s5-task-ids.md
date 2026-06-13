# TASK_001 — M7.4 — Detect + migrate non-§5 task ids in a project's ROADMAP

**Found during M7.1 dogfood (storefront, 2026-06-10).** A real project's `ROADMAP.md` used a hierarchical, phase-prefixed id scheme (`RLS.2`, `WEB.5g`, `BUG-RESILIENCE.2`) instead of the numeric `#NN` / `#NNa` convention PLAN.md §5 defines. The planning gate (M4.30) enforces §5 via `plan-task` (`^#?\d+[a-z]?$`) and `slice-task` (`^#?\d+$`), so **no task in such a project is plannable → none is claimable by the orchestrator**. RLS.2 only shipped because it predated M4.30. This is **not** a bug in `plan-task` (§5 is numeric by design); it is a project whose ids drifted from the convention, which atelier should detect and migrate — the same way the operator migrated tracking layouts via `migrate-roadmap`.

**Design (two parts):**

1. **Detection — `atelier-doctor` per-project check.** Doctor already iterates `projects.json`. Add a check that parses each registered project's `ROADMAP.md` and flags task ids that do not match §5 (`#NN` / `#NNa`). Emit `✗` with the count and a pointer to the migration. Same per-check-independence contract as the rest of the binary.
2. **Migration — `atelier-migrate-task-ids <project>`** (analogous to `migrate-roadmap`). Assign sequential `#NN` ids preserving section/priority order and epic structure (epic `#NN` + sub-tasks `#NNa`/`#NNb`), rewrite `ROADMAP.md` + `IN_PROGRESS.md`, rewrite `blocked_by:` references through the same mapping, and emit a traceability map (`RLS.2 → #5`).

**Open design questions to resolve when planned:**
- **`HISTORY.md` is an immutable log** of merged PRs. Decide whether to rewrite historical ids or preserve them with a forward-mapping table (leaning preserve + map).
- **Live branches / open PRs** (`task/RLS.2-rls-policies`, PR #132) carry the old id. Decide whether the migration re-maps them or leaves them as legacy with a recorded mapping.
- Interaction with the **`[ready]` / `.plan/<id>.md`** artifacts already on disk for a partially-planned project.

**Acceptance:** `atelier-doctor` flags a project whose ROADMAP uses non-§5 ids; `atelier-migrate-task-ids <project>` converts them to §5 ids across `ROADMAP.md` + `IN_PROGRESS.md` with `blocked_by:` updated and a printed mapping, leaving `HISTORY.md` handled per the resolved design question. Idempotent: a second run on an already-§5 ROADMAP is a no-op.

**Note:** this task should itself be planned via `/atelier:plan-task` once it carries a §5 id — a small irony worth preserving as the first dogfood of the very gate it unblocks.
