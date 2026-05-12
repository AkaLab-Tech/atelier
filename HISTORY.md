# History

Completed work log. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Newest first. Each entry references the PR(s) that delivered the work.

---

## 2026-05

### M1.1 — Repo skeleton — 2026-05-12
**PR:** [#4](https://github.com/AkaLab-Tech/atelier/pull/4)

First Phase 1 milestone: prepare the on-disk layout the plugin and host-OS layers will populate in M1.2–M1.5.

**Delivered:**
- Created `.claude-plugin/`, `agents/`, `skills/`, `commands/`, `hooks/`, `templates/`, `scripts/` at the repo root.
- Added a one-line `README.md` to each, naming its purpose.
- Tracking: removed M1.1 from `ROADMAP.md` and routed it through `IN_PROGRESS.md` to this entry.

**Tests:** `ls` shows the seven directories at the repo root; each contains a `README.md` whose first line names its purpose.

<!-- ## YYYY-MM

### Example title — YYYY-MM-DD
**PR:** [#N](https://github.com/<org>/<repo>/pull/N)

One- or two-sentence framing of why this PR existed.

**Delivered:**
- Bullet 1
- Bullet 2

**Tests:** one line on the validation done.

**Follow-ups:** (optional)
- Bullet
-->
