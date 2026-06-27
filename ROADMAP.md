# Roadmap

Backlog of atelier's own development. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Indexed layout: each item links to its detail file under `roadmap/TASK_NNN_<slug>.md` (acceptance criteria, design notes, sub-tasks). Milestone IDs (M1.1, M4.4, M9.1, …) trace to [PLAN.md §12](PLAN.md) — read the referenced section before starting a task.

---

## 🔥 P0 — Blockers

> Phase 1 install hardening (F1–F16), orchestrator/personal-CLAUDE.md bugs (F52, F53), and reviewer-access-on-fresh-private-repos (F56) are all resolved — see [HISTORY.md](HISTORY.md). No open blockers.

## 🎯 P1 — Next

> **M9 — External task-manager backends: GitHub Projects** (epic `#2`, sliced — [detail](roadmap/TASK_002_m9-github-projects-backend.md)) is **complete**: the keystone M9.1 (`#18`) merged 2026-06-20 and every sub-epic (#19–#22) is closed — see [HISTORY.md](HISTORY.md). The only remaining step is the operator's live OAuth/MCP end-to-end run (runbook: [docs/manual-e2e-workspaces-backends.md](docs/manual-e2e-workspaces-backends.md)); divergences found there become new tasks, not closure blockers. `/atelier:align` autonomy bug `#30` closed (PR [#257](https://github.com/AkaLab-Tech/atelier/pull/257)). Bug `#33` (`pr-author` destructive remote-branch delete) **closed** — `pr-author` now reconciles a diverged task branch with `--force-with-lease`. Active P1 bugs: `#32` (task-closing PR doesn't regenerate the ROADMAP/HISTORY mirror under the github-project backend) and `#34` (mirror reconciliation reads the local checkout, missing the worktree→PR→merge flow).

- [ ] `bug` task-closing PR doesn't regenerate the `ROADMAP.md`/`HISTORY.md` mirror under the github-project backend (board `Status=Done` but mirror unchanged — e.g. `#24` via PR #252) `#32` `~TODO` — [detail](roadmap/TASK_032_closing-pr-mirror-regen-gate.md)
- [x] `bug` `pr-author` force-deletes the remote task branch (`git push origin --delete`) to clean a dirty branch — the auto-mode classifier blocks it as `[Git Destructive]`, stalling the chain `#33` `~TODO` — [detail](roadmap/TASK_033_pr-author-destructive-remote-delete.md)
- [ ] `bug` github-project mirror reconciliation reads the local checkout (and a non-worktree path filter) — misses the real `worktree → PR → merge` flow; must reconcile from `origin/<base>` and on `SessionStart` `#34` `~TODO` — [detail](roadmap/TASK_034_mirror-sync-from-origin-base.md)
- [x] `bug` `/atelier:align` Tier 3 ignores `decisionPolicy=auto` — stops to ask (off-spec reviewer prompt, merge prompt + spurious `gh pr merge` permission deflection, manual post-merge pull) instead of running autonomously `#30` `~TODO` — [detail](roadmap/TASK_030_align-tier3-ignores-auto-policy.md)
- [x] `feat` `/setup-project` detects a missing branch-protection rule (no required approving reviews → empty `reviewDecision` → auto-merge guardrail #2 holds forever) and offers an atelier-executable autonomous fix `#31` `~3h` — [detail](roadmap/TASK_031_setup-detect-branch-protection.md)
- [x] `feat` Epic: M9.2 GitHubProjectBackend in claude-roadmap-tools `#19` `~TODO` `blocked_by:#18` — [detail](roadmap/TASK_019_m9-2-github-project-backend.md)
  - Deliverable lands in `claude-roadmap-tools` (100%-markdown plugin), not atelier-dev; split mirrors the existing LinearBackend file-by-file so each PR is one reviewable prose slice under the 200-line budget.
  - [x] `feat` M9.2a Contract groundwork: docs/RoadmapBackend.md + GitHub MCP isAvailable pattern `#19a` `~TODO` `blocked_by:#18` — [detail](roadmap/TASK_019_m9-2-github-project-backend.md#19a)
  - [x] `feat` M9.2b Core operations: Operations (GitHubProjectBackend) section in SKILL.md `#19b` `~TODO` `blocked_by:#19a` — [detail](roadmap/TASK_019_m9-2-github-project-backend.md#19b)
  - [x] `feat` M9.2c Command extensions + routing: /create-roadmap + /migrate-roadmap + activation `#19c` `~TODO` `blocked_by:#19b` — [detail](roadmap/TASK_019_m9-2-github-project-backend.md#19c)
  - [x] `feat` M9.2d Optional offline mirror + backend/backendId frontmatter parity `#19d` `~TODO` `blocked_by:#19b` — [detail](roadmap/TASK_019_m9-2-github-project-backend.md#19d)
- [x] `feat` Epic: M9.3 setup-project + next-task + planning gate on Projects `#20` `~TODO` `blocked_by:#18` — [detail](roadmap/TASK_020_m9-3-setup-nexttask-on-projects.md)
  - Three independently-shippable atelier-side integration slices (all native to atelier-dev, extending the #18 keystone); split file-by-command so each PR fits the 200-line/10-file budget, mirroring the #19 epic pattern.
- [x] `feat` Epic: M9.4 two-way migration files ↔ github-project `#21` `~TODO` `blocked_by:#18` — [detail](roadmap/TASK_021_m9-4-two-way-migration.md)
  - Reverse path is one mechanism (`backend → files` via `listTasks` across 3 buckets, parameterized by backend); split engine-vs-consumer so each PR is a single reviewable prose slice under the 200-line budget. Deliverables land in `claude-roadmap-tools`, not atelier-dev (mirrors #19).
  - [x] `feat` M9.4a Generalized `backend → files` reverse engine + RoadmapBackend reverse-read contract `#21a` `~TODO` `blocked_by:#18` — [detail](roadmap/TASK_021_m9-4-two-way-migration.md#21a--generalized-backend--files-reverse-engine--contract)
  - [x] `feat` M9.4b `github-project ↔ files` matrix flip + `--to files` wiring + round-trip fidelity contract `#21b` `~TODO` `blocked_by:#21a` — [detail](roadmap/TASK_021_m9-4-two-way-migration.md#21b--github-project--files-matrix--wiring)
  - [x] `feat` M9.4c `linear → files` unlock + round-trip validation `#21c` `~TODO` `blocked_by:#21a` — [detail](roadmap/TASK_021_m9-4-two-way-migration.md#21c--linear--files-unlock--validation)
- [x] `feat` Epic: M9.5 workspaces + e2e `#22` — COMPLETE — [detail](roadmap/TASK_022_m9-5-workspaces-e2e.md)

## 💭 P2 — Backlog

> **Autonomous cycle hardening (2026-06-20).** Close the orchestrator loop end-to-end: wait for CI, iterate on review, babysit open PRs, and clean up on completion. Operator-requested after the cycle stopped short of merge on real tasks.

- [ ] `bug` permission matrix: colon-refspec `git push origin task/x:main` bypasses the protected-branch deny (pre-existing; the `task/*` allow matches a `:`-separated protected destination) `#35` `~TODO` — [detail](roadmap/TASK_035_push-matrix-colon-refspec-hardening.md)
- [ ] `feat` auto review-fix loop: re-dispatch implementer/tester on `request-changes`, bounded, then escalate `#24` `~TODO` — [detail](roadmap/TASK_024_review-fix-loop.md)
- [ ] `feat` `/atelier:babysit-prs` — watch open `task/*` PRs and drive CI→review→merge `#25` `~TODO` — [detail](roadmap/TASK_025_babysit-prs.md)
- [ ] `feat` auto post-merge cleanup completion: base pull + orphan branch sweep `#26` `~TODO` — [detail](roadmap/TASK_026_post-merge-cleanup-completion.md)
- [ ] `feat` first-class High/Medium/Low ROADMAP layout for operator projects (M7.1.F68 option B) `#3` `~TODO` — [detail](roadmap/TASK_003_first-class-high-med-low-layout.md)
- [ ] `feat` actionable "nothing planned" dead-end: surface plan candidates `#4` `~TODO` — [detail](roadmap/TASK_004_nothing-planned-dead-end.md)
- [ ] `feat` /setup-project detects CI/CD and offers to scaffold it per stack `#5` `~TODO` — [detail](roadmap/TASK_005_setup-project-detects-cicd.md)
- [ ] `feat` M4.4 blocked-task visibility in /status `#6` `~TODO` — [detail](roadmap/TASK_006_m4-4-blocked-task-visibility.md)
- [ ] `feat` M4.5 /abandon-task <id> `#7` `~TODO` — [detail](roadmap/TASK_007_m4-5-abandon-task.md)
- [ ] `chore` M4.21 /validate Python toolchain in allowed-tools frontmatter `#8` `~TODO` — [detail](roadmap/TASK_008_m4-21-validate-python-toolchain.md)
- [ ] `feat` M4.15 Stop-hook auto-reprompt on validation failure (exceptional path) `#9` `~TODO` — [detail](roadmap/TASK_009_m4-15-stop-hook-auto-reprompt.md)
- [ ] `docs` M6.3 product owner guide (ROADMAP.md format) `#10` `~TODO` — [detail](roadmap/TASK_010_m6-3-product-owner-guide.md)
- [ ] `chore` M7.2 iterate the network allowlist `#11` `~TODO` — [detail](roadmap/TASK_011_m7-2-iterate-network-allowlist.md)
- [ ] `TODO-type` v2 ideas (deferred) `#12` `~TODO` — [detail](roadmap/TASK_012_v2-ideas-deferred.md)
- [ ] `feat` cost monitoring / per-task budget caps (v2) `#14` `~TODO` — [detail](roadmap/TASK_014_cost-monitoring-budget-caps.md)
- [ ] `feat` visual regression (baseline diff) (v2) `#15` `~TODO` — [detail](roadmap/TASK_015_visual-regression-baseline-diff.md)

### Out of scope for v1

Per [PLAN.md §11](PLAN.md). Listed so they are not picked up by accident: **atomic** cross-repo changes (one task/PR spanning multiple repos — note that multi-repo *workspaces* with sequenced cross-repo dependencies are now in scope and complete, Phase 8 / [PLAN.md §15](PLAN.md)), deployment/release management, ROADMAP ↔ Issues bidirectional sync. (Cost monitoring `#14` and visual regression `#15` are tracked above as deferred v2 backlog items.)
