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

## Scoping the test run (pnpm workspaces)

Before choosing the test command, check whether this is a pnpm workspace: does a `pnpm-workspace.yaml` exist at the repo root?

- **No `pnpm-workspace.yaml`** — single-package project. Run the full root suite exactly as documented above; nothing changes.
- **`pnpm-workspace.yaml` present** — map every staged path (`git diff --cached --name-only`) to the workspace package root it falls under (the nearest ancestor directory containing that package's own `package.json`).
  - If every touched path resolves to a single package (or a small set of packages) **and** none of the touched paths is a root/shared/config path — `pnpm-workspace.yaml` itself, the root `package.json`, `turbo.json`, root `tsconfig*`, anything under `.github/`, or a shared `packages/*` that other packages depend on — run the **scoped** test command instead of the full suite:
    - `pnpm --filter <pkg>... run test` — the `...` suffix means "and its dependents"; never scope to the touched package alone, dependents must be exercised too, or
    - `turbo run test --filter=<pkg>...` when `turbo.json` exists (prefer turbo when present — it already knows the dependency graph).
  - Otherwise — touched paths span multiple unrelated packages, touch a root/shared/config path, or the package mapping can't be determined with confidence — run the **full root suite** exactly as today. When the scope is ambiguous, run more, not less.
- **Lint and typecheck stay root-level always**, scoped or not — a package-local change can still break cross-package type contracts, and scoping only ever applies to the test step.
- **Scoping is a pre-check, not a substitute for CI.** The PR's full CI run (all packages) remains the authoritative §6 gate. Scoping here only saves the implementer's local iteration time — it never lets a cross-package regression merge, because CI re-runs the complete suite regardless of what safe-commit scoped locally.
- Record which mode ran (scoped vs. full, and which package(s) if scoped) in the report — see below.

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

## Detecting an absent service (vs. a genuine test failure)

Some test suites depend on a running service (Postgres, Redis, Mongo, etc.) that simply isn't up in the current environment. That's not a code failure — treat it as its own outcome, not a plain red and not a green.

After the test command exits non-zero, check its captured output (case-insensitive) for a connection-failure signature:

- `ECONNREFUSED`
- `connection refused`
- `could not connect to server`
- `could not translate host`
- `no pg_hba`
- a DB-port `ETIMEDOUT`
- `Redis.*(ECONNREFUSED|connect)`
- `MongoNetworkError`
- `getaddrinfo`

These signatures are deliberately narrow — they match *connection/network* failures, not assertion failures or logic bugs that happen to mention a database. **When in doubt, do not classify as `service unreachable`** — fall back to a normal red. A missed classification just costs a less-actionable report; a false-positive one would let a real code failure masquerade as an infra problem, which is the worse mistake — fail-safe toward blocking as a normal red.

When a signature matches, classify the outcome as **`service unreachable`** — distinct from both `GREEN` and a plain `RED` — and surface three things:

1. **What looks unreachable** — the service name/host/port inferred from the matched line.
2. **The remedy** — if a `docker-compose*.y*ml` exists in the repo, the remedy is `docker compose up -d` (point at the `docker-env` skill for the exact lifecycle commands); otherwise, "start the required service" (no compose file to point at, so there's no docker command to hand back).
3. **The scope option** — if the change qualifies for package-scoped testing (see above) and the scoped package's suite doesn't need this service, say so — re-running scoped may avoid the dependency entirely.

This outcome is still **BLOCKED**: the commit does not proceed. It differs from a plain red only in that the report tells the caller *why* it's red and what to do about it, instead of surfacing a raw connection-refused stack trace.

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

When the test step ran scoped (see "Scoping the test run" above), say so on the `tests:` line — e.g. `tests: ✓ pass — 18 passed, 0 failed (pnpm --filter @acme/billing... run test — SCOPED, root CI still runs full suite)`.

Or, when the tests fail because a dependency service isn't reachable (see "Detecting an absent service" above) — not a code failure:

```text
== safe-commit report ==

lint:        ✓ pass                 (pnpm run lint)
typecheck:   ✓ pass                 (pnpm run typecheck)
tests:       ✗ fail                 (pnpm run test)
  → matched signature: ECONNREFUSED 127.0.0.1:5432

Result:      SERVICE-UNREACHABLE — commit blocked (service down, not a code failure).
Next step:   Postgres on 5432 looks unreachable. Run `docker compose up -d` (see the `docker-env` skill) and re-run safe-commit; or, if this change is package-local and the scoped suite (see "Scoping the test run") doesn't touch Postgres, re-run scoped instead.
```

The `✓ / ✗` symbols and the `Result:` line (`GREEN`, `RED`, or `SERVICE-UNREACHABLE`) are the parser's anchors. Keep them stable. The `Next step:` line on a green report is mandatory: it exists to stop callers — `pr-author` especially — from reading `GREEN` as "done" and ending their turn at the gate. The `Next step:` line on a `SERVICE-UNREACHABLE` report is equally mandatory — it's what makes the outcome actionable instead of an opaque red.

## Decision rules

- **Never** soften a red. If a flake is suspected, run the failing test command **once more**; if it goes green on retry, surface `tests: ✓ pass (RETRIED — flake suspected: <test-name>)`. Don't silently retry forever — one retry, then trust the result.
- **Never** quarantine or skip a test to make a red go green. That belongs in `tester` after the operator confirms the test is genuinely flaky.
- **Never** add a `--passWithNoTests` flag, `--bail=false`, or any other shape-changing flag to the test command. Use what `package.json` defines.
- When a step is N/A (no script defined), **say so explicitly**. The push gate cannot be "green" if a project has no test script — it has to be "yellow" / "partial" so the operator can decide.
- **`service unreachable` is a distinct BLOCKED outcome, never a bypass.** It exists purely to make an infra-down red actionable (what's down, how to start it, whether scoping avoids it) — it never authorises the commit. When the connection-failure signature doesn't clearly match, classify as a normal red instead; false positives here are worse than false negatives.
- **Scoped test runs never replace CI.** Running `pnpm --filter <pkg>...` (or `turbo run test --filter=<pkg>...`) locally is a pre-check for iteration speed only. The PR's full CI still runs every package's tests — that remains the authoritative §6 gate. If the workspace mapping is ambiguous, run the full root suite; never guess toward less coverage.
- **Never** let a caller read `GREEN` as "task done". This skill *authorises* the commit; it does not perform the commit, the push, or the PR. The `Next step:` line on a green report is the guard against that misread — keep it on every green report.
- **The gate cannot be bypassed.** Not via a skip flag (`ATELIER_SKIP_SAFE_COMMIT` set inline in the commit command — the operator's out-of-band environment variable is a separate, legitimate affordance), not via a redirected `--git-dir`/`--work-tree`, and not via `--no-verify`. `hooks/safe-commit.sh` refuses all three signatures at runtime (`exit 2`, logged) — this skill's contract matches that behaviour: a red gate is resolved by fixing the failure or handing back to `tester`, never by routing around it.

