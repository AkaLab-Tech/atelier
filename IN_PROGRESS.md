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
- [x] **Phase B** — drive `claude auth login` (browser) and `gh auth login --hostname github.com --git-protocol https --web --skip-ssh-key --scopes "repo,workflow,project,read:org"` + `gh auth setup-git`. **HTTPS only — never SSH.** Idempotent via `claude auth status` / `gh auth status`. Auto-skips with a clear message when no TTY is attached (CI / piped install / non-interactive SSH).
- [x] **Phase C.1** — install external `git-wt` non-interactively (`/tmp/git-wt/install.sh --skill-for=claude`) and record installed SHA in `~/.local/state/atelier/git-wt.sha` for /doctor (M1.6); add `.env*` to `core.excludesFile` (defaults to `${XDG_CONFIG_HOME:-~/.config}/git/ignore` when unset); configure git identity — always prompt for global `user.name` and `user.email` with current values as defaults (PR #9), no-TTY-safe (keeps existing if both set; warns + continues if missing); inject shellrc hooks (`fnm env --use-on-cd`, `task() { claude "/next-task $*"; }`, `task-status='gh pr list --author @me --state open'`) into `~/.zshrc` and/or `~/.bashrc` via sentinel-bounded idempotent block — when the target shellrc is not writable (e.g. owned by `root:wheel` from a prior `sudo`), the script warns with the exact `sudo chown` fix and continues instead of dying. Note: per-project `.npmrc` guardrails are written by `/setup-project` in M2.3, not here.
- [ ] **Phase C.2** — drive Claude Code to run `/plugin marketplace add AkaLab-Tech/claude-plugins` + `/plugin install atelier@akalab-tech` + `/plugin install claude-roadmap-tools@akalab-tech` (per PR #11: shared catalog repo, plugin-per-source-entry). Fallback: print the commands for the operator to paste.
- [ ] Final verification block: `claude --version`, `gh auth status`, `git wt help`, plugin presence, `/doctor` invocation; print ✅/❌ per check.
- [ ] Idempotency: re-running on an already-configured machine must not break anything and must surface a clear status.

**Acceptance:** running `install.sh` on a clean Mac VM (and best-effort on Ubuntu) finishes with all final checks green.

**Branch (current sub-PR):** `setup/m1.3-phase-c-1` — Phase C.1: git-wt + `.env*` excludes + git identity (PR #9 refinement) + shellrc hooks (fnm/task/task-status).
