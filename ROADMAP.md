# Roadmap

Backlog of work for this project. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

This roadmap uses the **indexed** layout: each task is a one-line link below, pointing to its detail file under `roadmap/TASK_NNN_<slug>.md` (acceptance criteria, design notes, sub-tasks). When work starts, move the task's link to `IN_PROGRESS.md`; progress updates from then on go inside the `roadmap/TASK_NNN_*.md` file, not here.

Tasks are derived from the implementation plan in [PLAN.md §12](PLAN.md). Milestone IDs (M1.1, M2.3, …) refer to that plan and are kept in titles for traceability. Always read the referenced PLAN.md section before starting a task.

---

## High Priority

> **Phase 1 — Foundation.** Blocks everything else. A fresh Mac must be able to run `install.sh`, log in to Claude + GitHub, and end with the `atelier` plugin installed and `/doctor` ✅.

> **Install hardening from M7.1 dogfood-2 + dogfood-3 (2026-05-23 / 2026-05-25).** Findings F1–F12 surfaced during dogfood-2 full-wipe reinstall. F11b discovered during PR-C validation. F13 + F7c discovered during dogfood-3 setup. F14 + F15 + F16 discovered during the dogfood-3 first `/atelier:doctor` run. Closed: PR-A [#70](https://github.com/AkaLab-Tech/atelier/pull/70) (F6+F7a+F9+F11, v0.4.2), PR-B [#72](https://github.com/AkaLab-Tech/atelier/pull/72) (F2+F5+F10+F12), PR-C [#73](https://github.com/AkaLab-Tech/atelier/pull/73) (F1+F3+F4+F8), PR-D [#74](https://github.com/AkaLab-Tech/atelier/pull/74) (F11b), PR-E [#75](https://github.com/AkaLab-Tech/atelier/pull/75) (F7b, v0.5.0), PR-F [#76](https://github.com/AkaLab-Tech/atelier/pull/76) (F13 atelier() shortcut). PR-G [#77](https://github.com/AkaLab-Tech/atelier/pull/77) closes F16 (doctor.md allowed-tools, v0.5.1). F7c + F14 + F15 closed 2026-05-26 — see [HISTORY.md](HISTORY.md). **All Phase 1 hardening findings resolved.**

> **Dogfood bugs — orchestrator behavior (2026-06-05).** Two correctness bugs found while running real atelier task chains: the orchestrator doing specialist work inline instead of delegating (F52), and the operator's personal `CLAUDE.md` leaking confirmation gates into the autonomous flow (F53). Both resolved — see [HISTORY.md](HISTORY.md).

> **Reviewer access on fresh private repos (2026-06-09).** F56 — the independent `reviewer` identity could not see freshly-created private repos, so the auto-merge review step failed silently. Resolved — see [HISTORY.md](HISTORY.md).

---

## Medium Priority

> **Phases 2–5 — Single-project agent flow + robustness + multi-project foundation.** Done when the toy-repo flow can pick a task, implement it, open a reviewed PR, auto-merge it, clean up, and survive failures with retries — and when an operator can install / uninstall atelier without risking unrelated Claude state.

- [TASK_001 — M7.4 — Detect + migrate non-§5 task ids in a project's ROADMAP](roadmap/TASK_001_m7-4-migrate-non-s5-task-ids.md)
- [TASK_002 — M9 — External task-manager backends: GitHub Projects](roadmap/TASK_002_m9-github-projects-backend.md)

---

## Phase 8 — Multi-repo workspaces ✅

> **Complete (M8.1–M8.7).** Group several single-repo projects into a "workspace" (e.g. backend + frontend + CMS): the `/setup-workspace` → `/list-workspaces` → `/remove-workspace` lifecycle, aggregated `/workspace-status`, root-level `task` routing, and *sequenced* cross-repo `blocked_by:<token>#id` dependencies enforced offline — **without** ever introducing cross-repo atomicity (each task stays one worktree / one PR). Design: [PLAN.md §15](PLAN.md); delivery log (M8.1–M8.7) in [HISTORY.md](HISTORY.md).

---

## Low Priority / Ideas

> **Phases 5–7 + deferred v2 patterns.** Multi-project, docs, end-to-end validation, and the OMC-borrowed ideas from PLAN.md §11.

- [TASK_003 — Idea — first-class High/Medium/Low ROADMAP layout for operator projects (M7.1.F68 option B)](roadmap/TASK_003_first-class-high-med-low-layout.md)
- [TASK_004 — Idea — actionable "nothing planned" dead-end: surface plan candidates](roadmap/TASK_004_nothing-planned-dead-end.md)
- [TASK_005 — Idea — `/setup-project` detects CI/CD and offers to scaffold it per stack](roadmap/TASK_005_setup-project-detects-cicd.md)
- [TASK_006 — M4.4 — Blocked-task visibility in `/status`](roadmap/TASK_006_m4-4-blocked-task-visibility.md)
- [TASK_007 — M4.5 — `/abandon-task <id>`](roadmap/TASK_007_m4-5-abandon-task.md)
- [TASK_008 — M4.21 — `/validate` Python toolchain in `allowed-tools` frontmatter](roadmap/TASK_008_m4-21-validate-python-toolchain.md)
- [TASK_009 — M4.15 — `Stop`-hook auto-reprompt on validation failure (exceptional path)](roadmap/TASK_009_m4-15-stop-hook-auto-reprompt.md)
- [TASK_010 — M6.3 — Product owner guide (ROADMAP.md format)](roadmap/TASK_010_m6-3-product-owner-guide.md)
- [TASK_011 — M7.2 — Iterate the network allowlist](roadmap/TASK_011_m7-2-iterate-network-allowlist.md)
- [TASK_012 — v2 ideas (deferred)](roadmap/TASK_012_v2-ideas-deferred.md)
- [TASK_014 — Cost monitoring / per-task budget caps (v2)](roadmap/TASK_014_cost-monitoring-budget-caps.md)
- [TASK_015 — Visual regression (baseline diff) (v2)](roadmap/TASK_015_visual-regression-baseline-diff.md)

### Out of scope for v1

Per [PLAN.md §11](PLAN.md). Listed here so they are not picked up by accident: **atomic** cross-repo changes (one task/PR spanning multiple repos — note that multi-repo *workspaces* with sequenced cross-repo dependencies are now in scope, see Phase 8 / [PLAN.md §15](PLAN.md)), deployment/release management, cost monitoring / per-task budgets, visual regression baselines, ROADMAP ↔ Issues bidirectional sync.
