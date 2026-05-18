# History

Completed work log. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Newest first. Each entry references the PR(s) that delivered the work.

---

## 2026-05

### M1.5 — Plugin-shipped operator rules (`SessionStart` hook) — 2026-05-17
**PR:** [#17](https://github.com/AkaLab-Tech/atelier/pull/17)

Single-sub-PR Phase 1 milestone: ship the rules atelier's agents must follow on every task in an atelier-managed project. Mechanism revised mid-PR after re-reading the [Claude Code plugins reference](https://code.claude.com/docs/en/plugins-reference): a `CLAUDE.md` at the plugin root is **not** loaded as project context — the official path for unconditional context injection is a `SessionStart` hook whose stdout becomes context.

**Delivered:**
- `operator-rules.md` (plugin root) — clean markdown that condenses PLAN.md §4 (dep installs), §6 (push/PR/merge gates), §7 (agent chain), §8 (failure-recovery retry budget) into operator-facing prose (no maintainer content). ~95 lines.
- `hooks/load-operator-rules.sh` — bash script that `cat`s `operator-rules.md` to stdout. Path resolved via `${CLAUDE_PLUGIN_ROOT}` per the plugins reference. Fails soft on missing file (stderr note + exit 0) so a corrupted plugin never locks the operator out of a session.
- `hooks/hooks.json` — registers the `SessionStart` hook. Uses the documented exec-form command quoting around `${CLAUDE_PLUGIN_ROOT}`.

**Tests:** end-to-end validated by running `claude --plugin-dir <worktree>` and asking "What are the atelier operator rules?" — Claude responded with a faithful summary of all four sections, including verbatim phrases from `operator-rules.md`, which confirms hook discovery → SessionStart firing → stdout-to-context pipe → on-demand retrieval all work as designed. Also: `bash -n`, `shellcheck` (0.11.0), `jq empty hooks/hooks.json`, direct hook invocation with `CLAUDE_PLUGIN_ROOT=<worktree>`, missing-file fallback exit code.

**Decision captured during the PR:** the ROADMAP M1.5 entry literally said "ship a CLAUDE.md". The investigation surfaced that this approach does not actually load context (per the plugins reference, plugins contribute context via skills / agents / hooks, not CLAUDE.md). The implemented `SessionStart` hook is the official mechanism. Cost: ~500-800 tokens of context per session. Trade-off: token cost for autonomy guarantee accepted, since the rules apply to every atelier task and operators should never have to re-run install.sh to opt in to them.

**Follow-ups:**
- Threat-model addendum for M2.4 content-scanning hooks (carryover from PR #16) — still required before any matcher code in M2.4 lands.

### M1.4 — `settings.template.json` (static permissions matrix) — 2026-05-17
**PR:** [#16](https://github.com/AkaLab-Tech/atelier/pull/16)

Single-sub-PR Phase 1 milestone: materialize the allow / deny / ask permissions matrix from PLAN.md §3 at `templates/settings.template.json`. The template stays a template until M2.3 `/setup-project` / `/next-task` instantiate it per-task with the worktree path injected.

**Delivered:**
- `templates/settings.template.json` — 87 permission rules total: 33 deny, 4 ask, 50 allow. `defaultMode: acceptEdits`. `additionalDirectories: ["<worktree>"]` as the substitution placeholder. Faithful 1-to-1 mapping against PLAN.md §3.
- `PLAN.md` §3 gains a **"Defense-in-depth"** note: this matrix is the static layer (gates *which tool* can be called); the M2.4 hook suite is the dynamic layer (validates *content* of allowed tool calls). Neither alone is enough.
- `ROADMAP.md` M2.4 expanded from 2 hooks to 5 with three new content-scanning hooks — `scan-edit-write`, `scan-git-add`, `safe-package-change` — plus a pre-implementation note requiring a threat-model addendum in PLAN.md §3 before any matcher code lands.

**Tests:** `jq empty` validates the template parses as JSON; a sample instantiation (`sed 's|<worktree>|/tmp/sample|g' …`) substitutes the placeholder in every spot (additionalDirectories, Read/Edit/Write patterns) and the result re-parses cleanly. Real per-task instantiation by Claude Code is exercised when M2.3 `/next-task` lands.

**Decision captured during the PR:** the user pushed back on shipping a static-only permissions model — defense-in-perimeter is not defense-in-depth. The static template ships now; the dynamic content-validation hooks land with M2.4 (scope expanded in the same PR). Both layers must hold for a real attack to land.

**Follow-ups:**
- Threat-model addendum to PLAN.md §3 listing the exact pattern catalogue each M2.4 content-scanning hook checks — required before any matcher code in M2.4 lands.
- Real per-task instantiation validation by `/next-task` (M2.3) — confirms Claude Code accepts the substituted file.

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
