# History

Completed work log. Tasks flow: `ROADMAP.md` → `IN_PROGRESS.md` → `HISTORY.md`.

Newest first. Each entry references the PR(s) that delivered the work.

---

## 2026-05

### M2.2 — Phase 2 skills (`task-discovery`, `pr-flow`, `safe-commit`, `safe-install`) — 2026-05-18
**PR:** [#20](https://github.com/AkaLab-Tech/atelier/pull/20)

Second Phase 2 milestone. Materialises the four skills the orchestrator and specialist agents from M2.1 invoke via the `Skill` tool, per [PLAN.md §7](PLAN.md). The `git-wt` skill is **not** in this PR — it ships from the external [Miguelslo27/git-wt](https://github.com/Miguelslo27/git-wt) package (installed by `install.sh` Phase C.1, not maintained here).

**Delivered:**
- `skills/task-discovery/SKILL.md` — parses the operator-facing `ROADMAP.md` format from [PLAN.md §5](PLAN.md) (P0/P1/P2 sections with `bug`/`feat`/`chore`/`docs`/`refactor` type tags, `#id`, `~estimate`, `blocked_by:` metadata) and picks the highest-priority unblocked item. Returns a structured record (`id`, `title`, `type`, `priority`, `estimate`, `blocked_by`, `worktree` slug, `acceptance`, `context`) so the orchestrator can route the task. Handles the dual layout — operator-facing P0/P1/P2 in target projects, simpler High/Medium/Low in atelier's own repo — and refuses to pick a task when every unchecked item is blocked.
- `skills/pr-flow/SKILL.md` — branch → commit → push → PR recipe, executable form of [PLAN.md §6](PLAN.md). Step-by-step: stage explicit paths (never `-A`), Conventional Commits message via HEREDOC, push only to `origin task/<id>-<slug>`, move `IN_PROGRESS.md` → `HISTORY.md` in the same PR, open the PR with the standard description shape (Summary / Test plan / Tracking). Hard refusals listed explicitly: no push to protected branches, no `--force`, no `--no-verify`, no `Co-Authored-By` attribution, no marking the PR auto-merge-ready (that gate needs `reviewer` from M3.2), no touching `package.json` / lockfile / workflows / Docker from this flow.
- `skills/safe-commit/SKILL.md` — executable form of the push gate from [PLAN.md §6](PLAN.md). Detects the project's pnpm scripts (`lint`, `typecheck`, `test`) with fallback name conventions, runs them in order, stops on first red, returns a structured report (`✓` / `✗` per step + `Result: GREEN | RED`) so callers can parse it deterministically. Allows exactly one retry for suspected flakes; never softens reds, never `--passWithNoTests`, never quarantines tests to make a red go green.
- `skills/safe-install/SKILL.md` — executable form of [PLAN.md §4](PLAN.md). Five-step recipe: (1) self-question whether stdlib / existing utility suffices (lists common false-needs: `Intl.DateTimeFormat`, `fetch`, `crypto.randomUUID`, `structuredClone`, `URLSearchParams`), (2) `pnpm view` to compare ≥ 2 alternatives by downloads / last publish / dep tree, (3) hard-fail if `now - published < 7 days`, (4) `pnpm add --lockfile-only` + `pnpm audit --audit-level=moderate`, revert lockfile on any moderate+ finding, (5) install + write justification to commit / PR body. Belt-and-braces with the per-project `.npmrc` written by `/setup-project` (M2.3) — never relies on `.npmrc` alone, so the reasoning lives in the PR where reviewers see it.

**Tests:**
- YAML frontmatter parses cleanly for all four files (`ruby -ryaml`).
- `description` block scalars use `>-` (folded, strip) where the prose contains `:` characters — initial attempt with plain inline `description: <text>` failed YAML parsing for `pr-flow` and `safe-install` because of unquoted colons after "PLAN.md §6" / "§4"; fixed in the same PR.
- Each skill: name + description well-formed, body 86–156 lines (well under the 500-line ideal from `skill-creator`'s guidance), description 680–857 chars (well above the 10-char minimum, below the 5000-char ceiling), each starting with the action verb and explicitly listing trigger phrases per skill-creator's "pushy description" guidance.
- Plugin loader picks them up via auto-discovery (no entry needed in `plugin.json`, same auto-scan behaviour as `agents/` confirmed in M2.1 and `skills/` confirmed since M1.2).

**Decisions captured:**
- **No `references/` or `scripts/` directories yet.** Each SKILL.md is a single self-contained markdown file. The `skill-creator` recommends progressive disclosure (split into `references/<topic>.md` for larger reference material, `scripts/<task>.py` for deterministic helpers), but all four skills fit comfortably under 500 lines — adding hierarchy now would be premature.
- **`safe-install` writes the justification into the commit/PR body, not into a separate file.** The reasoning is the audit trail; burying it in a metadata file makes it invisible to reviewers. PLAN.md §4 step 3 says "justify in commit / PR description" — this skill enforces that literal interpretation.
- **`pr-flow` keeps the PR description schema explicit.** Reviewers should not have to guess which template a PR follows. Future skills (`/finish-task`, `pr-author`) will be added; the schema lives in one place so all callers produce the same shape.

**Follow-ups:**
- Acceptance criterion *"exercised by at least one slash command"* — blocked on M2.3 (`/next-task`, `/finish-task` will be the canonical callers for `task-discovery` and `pr-flow` respectively).
- `safe-install` step 4 needs validation against a real `pnpm audit` output. Will be exercised when the first toy-repo dependency install happens during M7.1 dogfooding.

### M2.1 — Phase 2 agents (`task-orchestrator`, `implementer`, `tester`, `pr-author`) — 2026-05-18
**PR:** [#19](https://github.com/AkaLab-Tech/atelier/pull/19)

First Phase 2 milestone. Materialises the four agents that drive an atelier task through the chain `task-orchestrator` (Opus) → `implementer` (Sonnet) → `tester` (Sonnet) → `pr-author` (Sonnet), per [PLAN.md §7](PLAN.md). e2e-runner, reviewer, and unblocker are out of scope here (M3.1, M3.2, M4.2).

**Delivered:**
- `agents/task-orchestrator.md` (opus, color `blue`, tools: `Read`, `Grep`, `Glob`, `Edit`, `Bash`, `TodoWrite`, `Task`, `Skill`). Owns the chain: picks the next ROADMAP item via the `task-discovery` skill (when M2.2 lands; fallback today is manual), invokes `git-wt` for isolation, moves the block from `ROADMAP.md` → `IN_PROGRESS.md`, then delegates to the three specialists sequentially. Enforces the 6-attempt retry budget from [PLAN.md §8](PLAN.md). Does not write code or tests itself.
- `agents/implementer.md` (sonnet, color `green`, tools: `Read`, `Grep`, `Glob`, `Edit`, `Write`, `Bash`, `TodoWrite`, `Skill`). Writes the minimum-viable change against the task's acceptance criteria inside the per-task worktree. Refuses to touch `package.json` / `pnpm-lock.yaml` / `.github/workflows/**` / `Dockerfile` / `docker-compose*` — those route back to the orchestrator and ultimately a human. Reports `Changes / Verification done locally / Unresolved / Next` back.
- `agents/tester.md` (sonnet, color `yellow`, tools: `Read`, `Grep`, `Glob`, `Edit`, `Write`, `Bash`, `TodoWrite`). Authors unit + integration tests in the project's existing framework, runs the full lint + typecheck + test push gate from [PLAN.md §6](PLAN.md), and surfaces flakes rather than masking them. e2e/Playwright explicitly deferred to `e2e-runner` (M3.1).
- `agents/pr-author.md` (sonnet, color `cyan`, tools: `Read`, `Grep`, `Glob`, `Bash`, `TodoWrite`, `Skill`). Re-runs the push gate one more time, composes a Conventional Commits message, pushes only to `origin task/<id>-<slug>`, opens the PR via `gh pr create` with the standard description (roadmap ref, summary, validation checklist, screenshots placeholder), and moves the block from `IN_PROGRESS.md` → `HISTORY.md` in the same PR. Explicitly does **not** mark the PR auto-merge-ready (that gate requires `reviewer` from M3.2).

**Tests:** YAML frontmatter parses cleanly for all four files (`ruby -ryaml`). The official `plugin-dev` plugin's `validate-agent.sh` script passes on all four with only 3 cosmetic warnings — those are a false-positive from the script extracting only the first line of `description:` block scalars (`description: |`), the same shape used by Claude's own canonical `agent-creator.md` example. Tools list contains only known Claude Code tool names (`Read`, `Grep`, `Glob`, `Edit`, `Write`, `Bash`, `TodoWrite`, `Task`, `Skill`). End-to-end agent invocation will be exercised when M2.3 `/next-task` lands and the orchestrator can be reached from a slash command.

**Decisions captured:**
- **Operator rules not duplicated in each agent prompt.** PLAN.md §4 / §6 / §8 already load globally via the M1.5 `SessionStart` hook (`operator-rules.md`). Each agent's system prompt cites those sections by reference rather than re-stating them, so updates to the operator rules propagate without touching every agent file.
- **`Skill` and `Task` in the orchestrator's tool list, not `Agent`.** Claude Code's documented agent-invocation tool name inside an agent definition is `Task`; `Agent` is only the SDK-facing name. The `Skill` tool is what lets the orchestrator invoke `git-wt`, `task-discovery`, `safe-install`, etc.
- **Tester does not get `Skill`.** It does not need to invoke any skill — it operates entirely via `Bash` against the project's `pnpm` scripts. Least privilege.
- **Skeleton `README.md` files from M1.1 removed.** Manual smoke test surfaced that `agents/README.md` was being loaded as a phantom agent (`atelier:README · inherit`) in `/agents`. Same risk applied to `commands/README.md` (slash commands) and `skills/README.md` (skills). All six skeleton READMEs (`agents/`, `commands/`, `skills/`, `hooks/`, `templates/`, `scripts/`) deleted in the same PR — each directory now has real content that documents itself, so the one-line organizational note from M1.1 is no longer needed. Lesson for future skeleton scaffolding: do **not** drop a `README.md` inside a Claude Code auto-discovery directory (`agents/`, `commands/`, `skills/`) — it will be parsed as a definition.

**Follow-ups:**
- Real end-to-end smoke test (orchestrator routes implementer → tester → pr-author against a toy ROADMAP item) blocked on M2.2 (skills `task-discovery`, `pr-flow`, `safe-commit`) and M2.3 (`/next-task` slash command). Acceptance criterion "invoked from a slash command" is fully achievable only after M2.3 lands.
- `safe-install` mentions in the implementer/orchestrator prompts are forward references — the actual skill arrives in M2.2.

### M1.6 — `claude-roadmap-tools` extraction + shared catalog + `/doctor` — 2026-05-17
**PRs:** [#1 claude-roadmap-tools](https://github.com/AkaLab-Tech/claude-roadmap-tools/pull/1) (plugin published) · [#1 claude-plugins](https://github.com/AkaLab-Tech/claude-plugins/pull/1) (shared catalog) · [#11](https://github.com/AkaLab-Tech/atelier/pull/11) (atelier marketplace.json removed) · [#14](https://github.com/AkaLab-Tech/atelier/pull/14) (install.sh Phase C.2 already installed both plugins via shared catalog) · [#18](https://github.com/AkaLab-Tech/atelier/pull/18) (`/atelier:doctor` + M2.4 threat-model addendum + narrow doctor allows + this closure)

Final Phase 1 milestone. Promotes the ROADMAP/IN_PROGRESS/HISTORY tooling out of the maintainer's `~/.claude-personal/` into a public plugin (`AkaLab-Tech/claude-roadmap-tools`), registers every AkaLab-Tech plugin in a dedicated shared marketplace catalog repo (`AkaLab-Tech/claude-plugins`), drives both installs from `install.sh` Phase C.2, and ships the `/atelier:doctor` health check so operators can detect drift across the three artefacts they depend on (`atelier`, `claude-roadmap-tools`, `git-wt`).

**Delivered:**
- `AkaLab-Tech/claude-roadmap-tools` plugin and `AkaLab-Tech/claude-plugins` catalog repo (done in their own repos; this repo only references them).
- `install.sh` Phase C.2 already installs both plugins via the shared `akalab-tech` catalog (recognised retroactively — actually shipped in PR #14).
- `commands/doctor.md` (~140 lines) — pure-markdown slash command. Invoked as `/atelier:doctor` because Claude Code's built-in `/doctor` (CLI diagnostics) shadows the bare name. Six structured checks: two plugin-drift, one git-wt SHA, three host (legacy hooks / git-wt PATH / shellrc / `.npmrc` / `.atelier-config.json`). Reports `✓`/`✗`/`–` and prints exact remediation commands but never applies them.
- `templates/settings.template.json` allow list extended with 12 narrow patterns covering exactly the commands `/doctor` invokes. `Bash(gh api *)` is deliberately not allowed — only the specific endpoints (`releases/latest`, `tags`, `commits/main`) for the three known repos. Allow count: 50 → 62.
- `PLAN.md` §3 threat-model addendum (~76 lines) listing the exact pattern catalogue each M2.4 `PreToolUse` content-scanning hook checks (`scan-edit-write`, `scan-git-add`, `safe-package-change`) — match heuristic, action (Block/Warn/Ask), known false-positive surfaces per pattern. Implementation guardrails: pattern catalogues live in `hooks/patterns/<hook>.json`; every hook decision logs to `<worktree>/.task-log/hook-decisions.jsonl`. Carryover requirement from PR #16/#17 closed here.

**Tests:** `/atelier:doctor` run end-to-end on the maintainer's mac via `claude --plugin-dir <worktree>`. Produced the expected `✓`/`✗`/`–` report. Detected a real git-wt SHA drift (`ac88a32 → 8a734bc`, the maintainer's own upstream fix to `git wt rm`'s cwd-orphan bug). Plugin checks correctly emitted `–` because AkaLab-Tech/atelier and AkaLab-Tech/claude-roadmap-tools have no published releases/tags yet. Auxiliary checks resolved as expected for the maintainer's environment (`–` for `.npmrc` and `.atelier-config.json` since the maintainer's view is the atelier repo itself, not an operator-managed project).

**Decision captured during the PR:** the bare `/doctor` name collides with Claude Code's built-in `/doctor` (CLI install diagnostics). Plugin slash commands are namespaced as `<plugin-name>:<command-name>`, so `commands/doctor.md` in the atelier plugin is invoked as `/atelier:doctor`. The first end-to-end smoke test surfaced this — the user got the built-in's output instead. Documented in the command's intro paragraph and the PR description.

**Phase 1 (Foundation) closed with this PR.** All six M1.x milestones merged: M1.1 (#4), M1.2 (#5 + #11), M1.3 (six sub-PRs #7/#8/#12/#13/#14/#15), M1.4 (#16), M1.5 (#17), M1.6 (#18). The plugin now installs end-to-end on a clean Mac VM, both plugins coexist via the shared `akalab-tech` catalog, operator rules load via `SessionStart` hook, and `/atelier:doctor` reports drift. Next: Phase 2 (M2.1 agents, M2.2 skills, M2.3 slash commands, M2.4 content-scanning hooks).

**Follow-ups (carried forward):**
- Publish initial `v0.1.0` releases / tags on `AkaLab-Tech/atelier` and `AkaLab-Tech/claude-roadmap-tools` so the plugin drift checks can resolve to `✓`/`✗` instead of `–`. Not blocking — `/doctor` correctly handles the no-releases case today.
- M2.4 implementation will use the threat-model addendum as the authoritative pattern catalogue. The catalogue is reviewable as-is; tuning happens during the per-hook implementation sub-PRs.

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
