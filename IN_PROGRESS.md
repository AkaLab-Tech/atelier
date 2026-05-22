# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M4.18 — Rename `git-wt` source from `Miguelslo27/git-wt` to `AkaLab-Tech/git-wt`

`git-wt` moved from the maintainer's personal namespace (`Miguelslo27`) to the organization (`AkaLab-Tech`). GitHub's redirect handles `git clone` of the old URL transparently, but the `gh api repos/...` drift check used by `/doctor` references the old path explicitly, and the `Bash` allowlist entry in `settings.template.json` is pinned to that path — so even when the redirect works for cloning, `/doctor` reports drift against the wrong repo and the operator may hit a permission prompt on the new URL.

Chore — no behavior changes, just URL rewrites. No version pinning: `install.sh` keeps cloning `main` shallow as today.

- [ ] `install.sh` (around lines 618 / 622 / 624) — replace `Miguelslo27/git-wt` with `AkaLab-Tech/git-wt` in the clone URL, the `sublog` line, and the surrounding comment about the upstream `gh api` SHA check.
- [ ] `templates/settings.template.json` line 185 — update `Bash(gh api repos/Miguelslo27/git-wt/commits/main*)` to `AkaLab-Tech/git-wt`. Per-project `.claude/settings.json` files already instantiated from the template will pick this up on the next `/setup-project` reconfigure.
- [ ] `commands/doctor.md` lines 34 / 37 / 89 — update the upstream-SHA fetch (`gh api`) and the remediation clone command in the doctor recipe.
- [ ] `PLAN.md` lines 79 / 81 / 347 / 376 — design-doc references.
- [ ] `CLAUDE.md` line 30 — maintainer-guide link.
- [ ] `HISTORY.md` is **not** updated (historical text preserved as written).

**Acceptance:** `grep -rn 'Miguelslo27' . --include='*.md' --include='*.sh' --include='*.json'` returns hits only in `HISTORY.md`. `/doctor` run after the change resolves drift against `AkaLab-Tech/git-wt` without prompting for a permission grant. A fresh `install.sh` run on a clean Mac clones from the new URL successfully.

**Trigger to revisit:** open immediately — leaves drift detection silently wrong against the new repo and risks the install if GitHub's redirect ever stops working. Captured 2026-05-22 after the maintainer transferred ownership of `git-wt` to AkaLab-Tech.

**Progress notes:** worktree `chore/m4.18-rename-git-wt-source` created 2026-05-22 from `a2e9e5d` (post-#60 merge).
