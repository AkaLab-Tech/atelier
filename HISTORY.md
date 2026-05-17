# History

Completed work log. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Newest first. Each entry references the PR(s) that delivered the work.

---

## 2026-05

### M1.3 — `install.sh` (Phases A + B + C.1 + C.2) — 2026-05-17
**PRs:** [#7](https://github.com/AkaLab-Tech/atelier/pull/7) (npmrc decision) · [#8](https://github.com/AkaLab-Tech/atelier/pull/8) (Phase A) · [#12](https://github.com/AkaLab-Tech/atelier/pull/12) (Phase B) · [#13](https://github.com/AkaLab-Tech/atelier/pull/13) (Phase C.1) · [#14](https://github.com/AkaLab-Tech/atelier/pull/14) (Phase C.2) · [#15](https://github.com/AkaLab-Tech/atelier/pull/15) (final verification + closure)

Phase 1 milestone: top-level installer that takes a fresh Mac (or Ubuntu best-effort) from "factory" to "ready to run atelier tasks". Implemented across 6 PRs.

**Delivered:**
- `install.sh` (548 lines) with strict mode + helpers + OS detection + 5 phases + verification block.
- **Phase A**: brew (mac) / apt (linux) installs of `git`, `gh`, `fnm`, `jq`, `fzf` + `corepack`-managed `pnpm`. Claude Code via Anthropic's official native installer (`curl -fsSL https://claude.ai/install.sh | bash`).
- **Phase B**: Claude OAuth (`claude auth login`) + GitHub HTTPS auth (`gh auth login --git-protocol https --skip-ssh-key`), idempotent via `claude auth status` / `gh auth status`, no-TTY-safe.
- **Phase C.1**: external `git-wt` install + SHA recording in `~/.local/state/atelier/git-wt.sha` for `/doctor` (M1.6); `.env*` in git global excludes; git identity prompts with current values as defaults (per PR #9), no-TTY-safe; shellrc hooks (`fnm env --use-on-cd`, `task() { claude "/next-task $*"; }`, `task-status` alias) injected into `~/.zshrc` / `~/.bashrc` via sentinel-bounded idempotent block, with unwritable-shellrc graceful fallback.
- **Phase C.2**: `claude plugin marketplace add AkaLab-Tech/claude-plugins` + `claude plugin install atelier@akalab-tech` + `claude plugin install claude-roadmap-tools@akalab-tech` (CLI verbs, not slash-commands), idempotent via `--json` + `jq`, with missing-claude / unauthed fallback that prints the manual commands and continues.
- **Verification block** (`phase_verify`): 6 `✓`/`✗` checks (`claude --version`, `claude auth status`, `gh auth status`, `git wt help`, both plugins installed) plus an inline note that `/doctor` lands in M1.6.

**Bugs discovered during testing & fixed in-flight:**
- `unzip` missing from apt deps (broke `fnm` install on a clean Ubuntu) — fixed in PR #8 commit `d40dd33`.
- git-wt SHA not recorded on idempotent re-runs (when git-wt was already on PATH from a manual install) — fixed in PR #13.
- Unwritable shellrc caused a fatal error mid-Phase-C.1 — fixed in PR #13 (warn with exact `sudo chown` command, skip, continue, exit 0).

**Decisions captured along the way:**
- npmrc supply-chain guardrails are per-project (written by `/setup-project` in M2.3), not global (PR #7).
- Marketplace name `akalab-tech` differs from plugin name `atelier` to avoid an `atelier@atelier` resolver collision (M1.2 / PR #5).
- Marketplace catalog moved to a dedicated `AkaLab-Tech/claude-plugins` repo so multiple AkaLab-Tech plugins can coexist under one marketplace (PR #11).
- `claude auth login` (CLI verb) instead of `/login` (slash command) for Phase B — slash commands only work inside an interactive `claude` session.
- `claude plugin …` (CLI verbs) instead of `/plugin …` (slash commands) for Phase C.2 — same rationale.

**Tests:** validated on macOS arm64 (Tart clean VM in PR #13 + maintainer's mac end-to-end across every sub-PR) and Ubuntu 24.04 ARM (Multipass clean VM in PR #8). `shellcheck` 0.11.0 clean across every sub-PR.

**Follow-ups:**
- `/doctor` slash command (tracked under M1.6) — turns the verification block into a callable plugin command and adds drift detection against `gh api repos/Miguelslo27/git-wt/commits/main` using the recorded SHA.
- A single clean-Mac-VM end-to-end run on squashed `main` as M7.x dogfood.
- Maintainer's `~/.zshrc` ownership keeps reverting to `root:wheel` periodically — outside atelier's scope, but worth tracking to root-cause (some installer or sudo invocation is touching it).

### M1.2 — Plugin manifest and marketplace — 2026-05-12
**PR:** [#5](https://github.com/AkaLab-Tech/atelier/pull/5)

Second Phase 1 milestone: stand up the plugin manifest and the marketplace catalog so atelier becomes installable via Claude Code's native plugin system.

**Delivered:**
- `.claude-plugin/plugin.json` — name `atelier`, version `0.1.0`, description, author (AkaLab-Tech), homepage, repository, keywords. No `skills` field (the default `skills/` scan path is sufficient; an explicit entry would only add a redundant scan).
- `.claude-plugin/marketplace.json` — vendor-scoped marketplace named `akalab-tech` with one plugin entry pointing at `source: "./"`. Plugin and marketplace names intentionally differ to avoid an `atelier@atelier` resolver collision discovered during validation.
- PLAN.md §1 step 11, §12, and ROADMAP.md M1.3 Phase C.2 updated for the new install command (`atelier@akalab-tech`).

**Tests:** end-to-end install validated in an operator Claude Code session — `/plugin marketplace add <worktree-path>` reported `Successfully added marketplace: akalab-tech`, `/plugin install atelier@akalab-tech` reported `✓ Installed atelier`, and `/reload-plugins` ran without manifest errors. `jq empty` validates both JSON files.

**Follow-ups:**
- Global `~/.npmrc` already has `ignore-scripts=true` (the guardrail PLAN.md §2 step 5 will enforce), which breaks the standalone `claude` CLI's native-binary postinstall (the user-facing `/plugin marketplace add` slash command in an existing Claude Code session works fine; only the standalone CLI does not). M1.3 (`install.sh`) must install Claude Code before applying the guardrail, or scope the guardrail to project-level npmrc instead of global.

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
