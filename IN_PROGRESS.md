# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M7.1.F14 — `/atelier:doctor` drift checks should fall back to unauthenticated GitHub API

`[correctness]` · Source: M7.1 dogfood-3 first `/atelier:doctor` run (2026-05-25)

The plugin-drift checks in `scripts/atelier-doctor` query `gh api repos/AkaLab-Tech/atelier/releases/latest` (and same for `claude-roadmap-tools`) to detect upstream drift. This fails with 404 when the source repo is private *or* when the authenticated identity (`atelier-author`) lacks org access — exactly the dogfood-3 starting state.

**Scope (revised after inspection — see "Why not marketplace-first" below):**

- [ ] Add an `fetch_upstream_version` helper to `scripts/atelier-doctor` with a four-step probe chain: (1) `gh api releases/latest`, (2) `gh api tags`, (3) unauthenticated `curl https://api.github.com/.../releases/latest`, (4) unauthenticated `curl https://api.github.com/.../tags`. First non-empty wins.
- [ ] Refactor `check_plugin_drift` to use the helper. Replace the vague "(upstream check failed)" with an informative SKIP message that lists what was tried.
- [ ] Update `commands/doctor.md` to document the fallback chain so operators understand why the check might SKIP and what to do.

**Why not marketplace-first (original scope rejected):**

The ROADMAP entry proposed reading the upstream version from `$ATELIER_CONFIG_DIR/plugins/marketplaces/akalab-tech/atelier/.claude-plugin/plugin.json`. Inspection of the actual marketplace clone layout shows this path **does not exist**: the `akalab-tech` marketplace only contains `marketplace.json` (catalog with `name` + `source.repo` per entry — no `version` field). Per-plugin manifests are only present in marketplaces that vendor plugins inside themselves (e.g. `claude-plugins-official`), not in pointer-style marketplaces like `akalab-tech`. So the marketplace catalog cannot be the source of truth for version — the source repo's GitHub API still has to be hit, just more robustly.

The original acceptance ("still reports ✓") is **rejected** as inhonest — we cannot claim "up to date" without evidence. The revised acceptance is below.

**Acceptance:** running `/atelier:doctor` on a system where the authenticated `gh` identity returns 404 for `gh api repos/AkaLab-Tech/atelier/releases/latest` but the repo is public still reports `✓ atelier <version> (up to date)` — because the unauth `curl` fallback succeeds. If the repo is genuinely private (no unauth access), doctor reports `↷ atelier <version> (upstream check failed — tried gh + unauth; repo may be private or rate-limited)` with no cascade.

**Trigger to revisit:** captured 2026-05-25 immediately after F14 was bypassed by flipping `AkaLab-Tech/atelier` to public — the underlying robustness gap remains.
