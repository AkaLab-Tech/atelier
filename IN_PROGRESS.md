# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M2.4 — Phase 2 hooks (dynamic security layer)

Implement the `PreToolUse` hook suite that complements the **static** permissions matrix from M1.4 / `settings.template.json`. The static matrix decides *which tool* an agent can invoke; these hooks decide *with what content*. Neither layer alone is enough — see [PLAN.md §3](PLAN.md) "Defense-in-depth".

- [x] `block-env-commit` (`PreToolUse` on `git add`/`git commit`): blocks any path matching `.env*` with a clear message. **(sub-PR #22)**
- [x] `safe-commit` (`PreToolUse` on `git commit`): lint + typecheck + tests gate before the commit lands. **(sub-PR #23)**
- [x] `scan-edit-write` (`PreToolUse` on `Edit`/`Write`): scan the proposed file contents for security-gap patterns (`eval(` of unsanitised input, hardcoded secrets, SQL-injection-shaped templates, shell-injection-shaped templates, etc.) and block the write when a high-confidence match is found. **(sub-PR #24)**
- [ ] `scan-git-add` (`PreToolUse` on `git add`): scan the proposed staged contents (resolved via `git diff --cached` on a dry-run) for the same security-gap patterns plus secret detection (entropy heuristics + known credential prefixes).
- [ ] `safe-package-change` (`PreToolUse` on `pnpm install`/`add`/`update`/`run`): analyse the resulting `package.json` (and any new dependency's published manifest) for malicious lifecycle scripts in the `scripts` field, suspicious `bin` entries, typosquatting names, and `postinstall` hooks that fetch and execute code. Block high-confidence threats; surface a clear message and require operator confirmation for marginal cases. Complements the per-project `.npmrc` guardrails from PLAN.md §4 (which already disable lifecycle scripts wholesale; this hook catches the cases where an operator deliberately re-enables them or pulls in a transitive dep that needs running).

**Threat-model addendum:** the pattern catalogue for the three content-scanning hooks (`scan-edit-write`, `scan-git-add`, `safe-package-change`) was finalised in PLAN.md §3 as part of M1.6 (PR #18). Each catalogue file (`hooks/patterns/<hook>.json`) maps 1:1 to the table in that addendum.

**Acceptance:** `git add .env` is blocked with a clear message; `git commit` is blocked when lint or tests fail; the three content-scanning hooks reject deterministic positive cases (planted secret in a test fixture, planted `eval(stdin)` pattern in a test fixture, planted `"postinstall": "curl … | sh"` in a test `package.json`) and pass clean cases.

**Sub-PR progress:**
- [x] sub-PR 1 — `block-env-commit` + shared `hooks/lib/log-decision.sh` helper (PR #22, merged).
- [x] sub-PR 2 — `safe-commit` hook (PR #23, merged).
- [x] sub-PR 3 — `scan-edit-write` + `hooks/patterns/scan-edit-write.json` (PR #24, this PR).
- [ ] sub-PR 4 — `scan-git-add` + `hooks/patterns/scan-git-add.json`.
- [ ] sub-PR 5 — `safe-package-change` + `hooks/patterns/safe-package-change.json` + M2.4 closure (this PR moves the block from `IN_PROGRESS.md` to `HISTORY.md`).
