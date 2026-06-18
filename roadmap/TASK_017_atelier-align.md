# TASK_017 — `atelier-align`: one command to align every project/workspace to the installed atelier

**Requested 2026-06-18.** Aligning projects after an atelier upgrade is a
multi-step, per-repo slog (resync each project's config, set policy per
workspace, adopt non-§5 roadmaps, commit each to base). The operator keeps
asking for "do it from one place." This is that capstone: a single entry point
that surveys all registered projects/workspaces and converges them to the
installed atelier — applying the safe mechanical fixes itself and guiding the
judgment-/network-bearing ones.

## What "aligned" means (the dimensions)
Per registered project (`$ATELIER_CONFIG_DIR/projects.json`) and workspace
(`workspaces.json`):

1. **Version drift** — `setupVersion` < installed plugin version (the `↻` from
   `atelier-list-projects`). Fix: re-sync `.claude/settings.json` + `.atelier.json`
   to the current template (`atelier-setup-project --reconfigure`).
2. **Decision policy** — `.atelier.json → decisionPolicy.default` not the desired
   value (e.g. operator wants `auto`). Fix: `atelier-setup-workspace --policy`
   (workspace) or set per project.
3. **ROADMAP §5** — non-§5 / foreign layout → tasks not claimable. Fix:
   `/adopt-roadmap --format atelier` (or `/atelier:onboard-workspace`). The
   sanctioned High/Med/Low layout is NOT flagged (reuse `atelier-orient`'s
   3-way `roadmap_layout`).
4. **Legacy `IN_PROGRESS`** — multi-item tracker, not a single slot. Fix: adopt.
5. **Partial / missing config** — `atelier-setup-project` to restore; missing
   directory → `atelier-remove-project` to unregister.
6. **Commit-to-base** — every working-file change above (settings, `.atelier.json`,
   adopted ROADMAP) must land on each repo's base branch (`dev`/`main`) to take
   effect in the autonomous cycle (`next-task` reads `origin/<base>`; the broker
   reads `.atelier.json` from the per-task worktree).

## Design

A **tiered** model, because the dimensions differ sharply in risk:

- **Tier 1 — mechanical, safe, no content rewrite** (version-drift resync, policy
  default): `atelier-align` can apply these directly to working files (reusing
  `atelier-setup-project --reconfigure` and the `--policy` writer). Idempotent.
- **Tier 2 — content rewrite, judgment** (§5 adoption, IN_PROGRESS reset):
  delegate to `/adopt-roadmap` / `/atelier:onboard-workspace`, interactive,
  per project — `atelier-align` orchestrates and confirms; never rewrites
  tracking files itself.
- **Tier 3 — outward-facing** (commit + PR to base): `atelier-align` LISTS the
  repos whose working files changed and need a base PR; optionally opens one PR
  per repo via a temp worktree (operator-confirmed), or just prints the exact
  commands. Never pushes to base directly.

**Shape:** a read-only surveyor first, then apply.
- `atelier-align --plan` (read-only, default): a cross-project/workspace report —
  one row per project with its drift/policy/§5/tracking state and the tier of fix
  needed. Reuses the detectors already shipped: `compute_status`,
  `roadmap_layout` (orient), `setup_version_of` + `older_than` (list-projects),
  `workspace_of`, `roadmap_format` (workspace-status). `--json` for tooling.
- `atelier-align --apply` (or `/atelier:align`): walks the plan, applies Tier 1
  with a summary, drives Tier 2 interactively, and presents the Tier 3 base-PR
  list (open-now? per repo).

**Where the logic lives:** a bash helper `scripts/atelier-align` owns the survey
(`--plan`/`--json`) and the Tier-1 mechanical apply (pure file ops, testable). A
slash command `/atelier:align` owns the Tier-2/Tier-3 orchestration (model-driven:
runs the helper, then drives `/adopt-roadmap` / `/atelier:onboard-workspace` /
the base-PR flow). This mirrors the orient split (cheap bash + model command).

## Build phases
1. **Survey (read-only):** `atelier-align --plan [--json]` — the cross-project
   report. High value on its own ("what's misaligned everywhere"). Hermetic test.
2. **Tier-1 apply:** `atelier-align --apply` does version-drift resync + policy
   across all (working-file writes), with a dry-run default and per-project
   independence. Hermetic test.
3. **`/atelier:align` command:** orchestrate Tier 2 (§5 adoption) + Tier 3
   (base-PR list / open) on top of the helper. Headless prints the plan only.

## Acceptance criteria
- `atelier-align --plan` lists every registered project + workspace with its
  misalignment (version `↻`, policy, §5, legacy IN_PROGRESS, partial/missing) and
  the recommended fix; `--json` is machine-clean. Read-only.
- `atelier-align --apply` clears version drift and sets policy across all targets,
  idempotently, one project's failure not aborting the rest; dry-run by default.
- `/atelier:align` drives §5 adoption (only for genuinely non-§5 / foreign
  roadmaps — never the sanctioned High/Med/Low) and surfaces the base-PR list;
  never rewrites tracking inline; never pushes to base; headless never auto-acts.
- The whole thing is offline-cheap where it can be (survey), and reuses existing
  detectors/helpers rather than reimplementing them.

## Open questions (resolve when taken)
- **Base PRs:** should `/atelier:align` open one PR per repo (via temp worktree,
  as done manually for the deminut policy PRs), or only print the commands?
  Leaning: offer per-repo, operator-confirmed.
- **Confirmation granularity:** one upfront confirm vs per-project vs per-tier.
- **Desired policy:** `--policy auto|ask` flag, or read an operator default?
- **Internal vs operator projects:** atelier's own ecosystem repos (High/Med/Low)
  should be aligned for version/policy but NOT nagged for §5 — already handled by
  `roadmap_layout`, but confirm the survey labels them clearly.
- **Scope filter:** `atelier-align <workspace-slug>` / `--workspace` to align just
  one workspace vs everything.
