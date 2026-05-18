# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

<!-- Single-file layout: paste the task block from ROADMAP.md here. -->
<!-- Indexed layout: link to roadmap/TASK_NNN_<slug>.md and write progress notes inside that file, not here. -->

### M1.6 — `claude-roadmap-tools` extraction + shared catalog + `install.sh`/`/doctor` integration

Promote the ROADMAP-tracking tooling out of the maintainer's `~/.claude-personal/` into a dedicated public plugin, register every AkaLab-Tech plugin in a shared `akalab-tech` marketplace catalog repo, install both atelier + claude-roadmap-tools via that catalog from `install.sh`, and teach `/doctor` to detect drift for the three artefacts the operator depends on.

- [x] Publish `AkaLab-Tech/claude-roadmap-tools` as a standalone Claude Code plugin. _(Done: [`AkaLab-Tech/claude-roadmap-tools`](https://github.com/AkaLab-Tech/claude-roadmap-tools), [PR #1](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/1).)_
- [x] Create the shared marketplace catalog repo [`AkaLab-Tech/claude-plugins`](https://github.com/AkaLab-Tech/claude-plugins). _(Done: [PR #1](https://github.com/AkaLab-Tech/claude-plugins/pull/1).)_
- [x] Remove the redundant per-plugin `.claude-plugin/marketplace.json` from `AkaLab-Tech/atelier` and `AkaLab-Tech/claude-roadmap-tools`. _(Done: atelier PR #11; claude-roadmap-tools [PR #2](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/2).)_
- [x] Extend `install.sh` Phase C.2 with steps 11–12 (marketplace add + both plugin installs). _(Already shipped in PR #14, this milestone retroactively recognises it: `ATELIER_PLUGIN_IDS=("atelier@akalab-tech" "claude-roadmap-tools@akalab-tech")` and the install loop drives both via the shared catalog.)_
- [x] Extend `/doctor` to report version drift for the three artefacts plus the auxiliary health checks PLAN.md §7 calls for (no legacy hooks leaking into `~/.claude/settings.json`, `git-wt` binary present, `fnm` shellrc hook active, current project's `.npmrc` guardrails present, per-project `.atelier-config.json` consistency). Implemented as a pure-markdown slash command at `commands/doctor.md` — Claude follows the prompt and runs the checks via its own tools.
- [x] `/doctor` reports findings and prints the exact commands the operator must run; never applies updates automatically.

**Out of scope (deferred):** migrating `git-wt` itself to the native plugin system.

**Acceptance:** `/doctor` invoked from a Claude Code session inside an atelier-managed project produces a structured `✓`/`✗` report covering the three artefacts plus the auxiliary checks, and (when any update is available) prints the exact command the operator must run.

**Bundled in the same PR:**
- Threat-model addendum to `PLAN.md` §3 listing the exact pattern catalogue each M2.4 content-scanning hook checks (`scan-edit-write`, `scan-git-add`, `safe-package-change`). Required before any matcher code in M2.4 lands. (Carryover from PR #16/#17 follow-up.)
- `templates/settings.template.json` allow list extended with 12 narrow patterns that cover exactly the commands `/doctor` invokes (`claude plugin list --json`; specific `gh api repos/<owner>/<repo>/{releases/latest,tags,commits/main}*` endpoints; `command -v git-wt`; targeted Read access to `~/.local/state/atelier/git-wt.sha`, `~/.claude/settings.json`, `~/.zshrc`, `~/.bashrc`, `~/.claude/.atelier-config.json`). Each pattern is as narrow as practical so no broader Bash/Read surface piggy-backs on them — `Bash(gh api *)` is deliberately **not** allowed; only the specific endpoints `/doctor` actually hits. Activates per-task once M2.3 `/setup-project` instantiates the template; outside a task the operator's personal settings apply.

**Branch (current sub-PR):** `setup/m1.6-doctor-plus-addendum` — single-sub-PR milestone; closes M1.6 by moving this block to `HISTORY.md` in an atomic follow-up commit on this same branch.
