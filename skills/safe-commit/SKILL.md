---
name: safe-commit
description: Run the project's full lint + typecheck + unit + integration test pipeline BEFORE allowing a commit. Use this skill whenever the user is about to commit a change, you are running the `pr-author` agent, you are about to push to a `task/*` branch, or anyone needs to validate the push gate defined in PLAN.md §6. Refuses to allow the commit when any pipeline step is red and surfaces the exact failing command + output so the caller can decide whether to fix-forward or hand back to `tester`. Required before every push from an atelier-managed worktree. Trigger this even when the user does not say "lint" or "tests" — any phrasing about getting ready to commit or push triggers it.
---

# safe-commit

A skill that runs the push gate from PLAN.md §6 — lint + typecheck + unit + integration tests — and reports the result the same way every time. Callers (`pr-author`, `/atelier:finish-task`, manual `git commit` via the operator) rely on this skill to decide whether the commit can proceed.

## What "the push gate" means

Per PLAN.md §6, push to `origin task/<id>-<slug>` is allowed **only** when all of the following are green:

1. Lint.
2. Type-check.
3. Unit + integration tests.

(e2e/Playwright belongs to a separate gate — the **PR gate** — and is handled by `e2e-runner` / `visual-validation`, not here.)

When any of the three is red, the commit must not happen. Skipping the gate (`--no-verify`) is denied by the global rules unless the operator explicitly authorises it for a one-off reason.

## Detecting the project's scripts

This skill assumes a pnpm-based project (npm is denied per PLAN.md §2 step 2). Open `package.json` and look for the standard script names. Variations exist; here's how to map them.

| Step | Preferred script name | Common alternatives |
|---|---|---|
| Lint | `lint` | `eslint`, `lint:fix` (run without `:fix` if available) |
| Type-check | `typecheck` | `type-check`, `tsc`, `tsc:noEmit` |
| Unit + integration | `test` | `test:unit && test:integration`, `vitest run`, `jest --ci` |

Discovery rule: read `package.json#scripts` and pick the script whose name best matches the step. If a project has both `test` and `test:integration` defined, run them in sequence (`pnpm run test && pnpm run test:integration`). If a step has **no matching script**, treat that step as `N/A` and continue — surface it in the report so reviewers know coverage is partial, **not** as a failure.

## How to run

Run the steps in order. Stop on the first red step — do not waste time running typecheck if lint already failed; the caller probably wants to fix lint first.

```sh
pnpm run lint
pnpm run typecheck
pnpm run test
```

For each command:

- Capture the exit code (`echo $?` immediately after, or use the bash `if`-style).
- Capture the **tail** of stdout/stderr (the last ~40 lines is plenty; full output bloats the report and slows the agent).
- If a step is N/A (no matching script), record it as such — do not infer green from absence.

## Report format

Always return this exact structure so callers can parse it deterministically:

```text
== safe-commit report ==

lint:        ✓ pass                 (pnpm run lint)
typecheck:   ✗ fail                 (pnpm run typecheck)
  → first error:
    src/reports/export.ts(42,7): error TS2532: Object is possibly 'undefined'.
tests:       (skipped — typecheck failed)

Result:      RED — commit blocked.
Next step:   fix typecheck error in src/reports/export.ts:42, then re-run safe-commit.
```

Or, when everything is green:

```text
== safe-commit report ==

lint:        ✓ pass                 (pnpm run lint)
typecheck:   ✓ pass                 (pnpm run typecheck)
tests:       ✓ pass — 142 passed, 0 failed, 3 skipped (pnpm run test)

Result:      GREEN — commit allowed.
Next step:   the gate is a precondition, not the deliverable — the caller must now proceed to commit → push → PR. A green gate is never a stopping point.
```

The `✓ / ✗` symbols and the `Result: GREEN | RED` line are the parser's anchor. Keep them stable. The `Next step:` line on a green report is mandatory: it exists to stop callers — `pr-author` especially — from reading `GREEN` as "done" and ending their turn at the gate (M7.1.F55).

## Decision rules

- **Never** soften a red. If a flake is suspected, run the failing test command **once more**; if it goes green on retry, surface `tests: ✓ pass (RETRIED — flake suspected: <test-name>)`. Don't silently retry forever — one retry, then trust the result.
- **Never** quarantine or skip a test to make a red go green. That belongs in `tester` after the operator confirms the test is genuinely flaky.
- **Never** add a `--passWithNoTests` flag, `--bail=false`, or any other shape-changing flag to the test command. Use what `package.json` defines.
- When a step is N/A (no script defined), **say so explicitly**. The push gate cannot be "green" if a project has no test script — it has to be "yellow" / "partial" so the operator can decide.
- **Never** let a caller read `GREEN` as "task done". This skill *authorises* the commit; it does not perform the commit, the push, or the PR. The `Next step:` line on a green report is the guard against that misread (M7.1.F55) — keep it on every green report.

