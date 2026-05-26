# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M7.1.F15 — `/atelier:doctor` parallel checks should fail independently, not cascade-cancel

`[ux-blocking]` · Source: M7.1 dogfood-3 first `/atelier:doctor` run (2026-05-25)

When doctor launches its checks in parallel and one fails (e.g. the F14 404), the Claude Code session cancels every other in-flight parallel call with `Cancelled: parallel tool call Bash(gh api repos/AkaLab-Tech/atelier/release…) errored`. The operator sees a partial report — no plugin versions, no git-wt SHA, no host checks — and the session enters an uncertain state trying to "recover" from the failure rather than completing all the *other* checks that would have worked fine.

**Scope (revised after inspection of post-F23 code):** F23's architectural refactor moved all checks into `scripts/atelier-doctor` — a single bash binary invoked once via `Bash(atelier-doctor:*)`. By construction this already eliminates F15's root cause: checks are sequential function calls, `set -e` is intentionally off, and every check handles its own errors internally (verified empirically with `env -i PATH=/usr/bin:/bin atelier-doctor` — produced a complete report even with `gh`/`jq`/`claude`/`docker` absent). The remaining work is documentary, not functional:

- [ ] Add a "Per-check independence" section to `commands/doctor.md` that states the contract explicitly: an `✗` or `–` on one row never affects the others. The operator gets an explicit guarantee; future maintainers get an invariant.
- [ ] Reinforce the defensive comment in `scripts/atelier-doctor` near the checks block — anchor for whoever adds a new check to follow the per-function error-handling discipline.

**Acceptance:** the new `doctor.md` section describes the per-check independence contract. The bash binary's checks section has a comment block explaining why each function uses internal `2>/dev/null` + conditional logic instead of relying on `set -e`. The empirical test (`env -i PATH=/usr/bin:/bin scripts/atelier-doctor`) still produces a complete report.

**Trigger to revisit:** captured 2026-05-25 alongside F14. F23 (merged 2026-05-25) implicitly fixed the functional behavior; this PR documents the invariant so it does not regress.
