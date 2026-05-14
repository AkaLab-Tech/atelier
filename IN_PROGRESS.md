# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

<!-- Single-file layout: paste the task block from ROADMAP.md here. -->
<!-- Indexed layout: link to roadmap/TASK_NNN_<slug>.md and write progress notes inside that file, not here. -->

### M1.3 — `install.sh` (Phases A + B + C.1 + C.2)

Single entry-point installer. **Splits into four sub-phases per PLAN.md §2** — keep them in one script with clear sections, not four scripts. Sub-PRs land incrementally against `main`; only the final one (verification + idempotency) moves this block to `HISTORY.md`.

- [x] **npmrc strategy decided: scope to per-project (option C).** Closed in PR #7.
- [x] **Phase A** — detect OS/arch; install base deps via brew/apt: `git`, `gh`, `fnm`, `pnpm` (via `corepack enable`), `jq`, `fzf`. Install Claude Code via the official native installer (`curl -fsSL https://claude.ai/install.sh | bash`). **Playwright deferred to M3.1** (was originally listed here, but operators who never run e2e tasks shouldn't pay the ~250 MB browser download upfront).
- [ ] **Phase B** — drive `claude /login` (browser) and `gh auth login --hostname github.com --git-protocol https --web --scopes "repo,workflow,project,read:org"` + `gh auth setup-git`. **HTTPS only — never SSH.**
- [ ] **Phase C.1** — install external `git-wt` non-interactively (`/tmp/git-wt/install.sh --skill-for=claude`); add `.env*` to `core.excludesFile`; configure git identity — always prompt for global `user.name` and `user.email`, showing the currently configured values (from `git config --global --get user.name`/`user.email`) as defaults so the operator can accept with Enter or overwrite (refined in PR #9); inject shellrc hooks (`fnm env --use-on-cd`, `task`, `task-status` aliases). Note: per-project `.npmrc` guardrails are written by `/setup-project` in M2.3, not here.
- [ ] **Phase C.2** — drive Claude Code to run `/plugin marketplace add AkaLab-Tech/atelier` + `/plugin install atelier@akalab-tech`. Fallback: print the two commands for the operator to paste.
- [ ] Final verification block: `claude --version`, `gh auth status`, `git wt help`, plugin presence, `/doctor` invocation; print ✅/❌ per check.
- [ ] Idempotency: re-running on an already-configured machine must not break anything and must surface a clear status.

**Acceptance:** running `install.sh` on a clean Mac VM (and best-effort on Ubuntu) finishes with all final checks green.

**Branch (current sub-PR):** `setup/m1.3-phase-a` — Phase A scaffold + base deps + Claude Code install.
