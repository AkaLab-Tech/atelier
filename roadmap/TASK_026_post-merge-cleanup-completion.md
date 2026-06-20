# TASK_026 — Auto post-merge cleanup completion (base pull + orphan sweep)

**Type:** `feat` · **Priority:** P2 · **Estimate:** `~TODO`

**Problem.** `auto-merge`'s per-task cleanup already removes the merged task's worktree (`git wt rm`), its local branch, and the remote branch (`--delete-branch`), and moves the roadmap entry. Two things are missing that the operator wants at task completion:
1. **Pull/ff the base branch** after merge so the local base reflects the just-merged commit (today the next `/next-task` re-fetches, but the local base is left stale in the meantime).
2. **Sweep orphan `task/*` branches** (local + remote) left by prior cycles — this exists as `/atelier:housekeeping` but it is **operator-invoked**, not automatic at task end.

**Scope (sketch).**
- Extend the post-merge step to fast-forward the base branch (`git fetch origin <base> && git -C <main-worktree> merge --ff-only`) — guarded against a dirty/diverged base.
- Optionally run the `housekeeping` orphan-sweep for the project automatically after a successful merge (still enumerate-then-act; never touch active/blocked tasks, open PRs, dirty worktrees, protected branches).
- Keep it idempotent and safe; surface what was swept.

**Acceptance.** After a successful auto-merge, the base branch is fast-forwarded locally and orphan `task/*` branches (local + remote) are cleaned without a separate manual `/atelier:housekeeping` run. Decompose at `/atelier:plan-task`.
