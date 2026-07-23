---
description: Run atelier's validation checks against the current worktree. Default (fast) layer runs lint + typecheck + unit/integration tests; `--full` adds Playwright e2e + screenshots.
argument-hint: "[--full]"
allowed-tools: Read, Glob, Grep, Bash(git status:*), Bash(pnpm:*), Bash(npx:*), Bash(eslint:*), Bash(prettier:*), Bash(tsc:*), Bash(biome:*), Bash(vitest:*), Bash(jest:*), Bash(ruff:*), Bash(mypy:*), Bash(pyright:*), Bash(pytest:*), Bash(playwright:*), Bash(env:*), mcp__plugin_atelier_playwright
---

You are running the `/validate` slash command. Execute the project's validation gate against the current worktree and print a **structured, machine-readable pass/fail summary**. Do not write code, fix issues, or invoke specialist agents — this command is a read-only execution of existing checks.

User input: `$ARGUMENTS` (optional — accepts the literal token `--full` to additionally run the slow validation layer).

## Mode (read once at the start)

- **Default mode (fast layer):** lint + typecheck + unit / integration tests. Suitable for the inner implementer↔validate loop driven by `task-orchestrator` (cheap, runs on every implementer iteration).
- **`--full` mode (fast + slow layers):** also runs Playwright e2e and captures screenshots. Runs **once before `pr-author`**, never inside the inner loop. Slow layer is the PR-gate equivalent of [PLAN.md §6](PLAN.md).

If `$ARGUMENTS` contains the literal token `--full` (surrounded by whitespace or string boundaries), run the full mode. Otherwise run the fast mode.

## Worktree resolution

This command operates against the **current worktree** — the cwd of the invoking session, or if `task-orchestrator` invokes it as part of the inner loop, the worktree path explicitly passed in the briefing.

Per `operator-rules.md` § *Operating against the task worktree*, use `pnpm --dir <worktree-path>`, `cd <worktree-path> && ...`, or analogous flags for every `Bash` invocation that targets the worktree. Read/Edit/Write on absolute paths are unaffected by cwd.

If the worktree path is ambiguous (no briefing, cwd is the main repo), **stop and report** rather than guessing.

## Fast layer (always runs)

Run the following checks in order. Each check is independent — a failing check does **not** short-circuit the rest; report every check's result so the implementer (or operator) sees the full picture.

Note: `/setup-project` Phase 5 (CI/CD scaffold offer) infers the same lint/typecheck/test steps from this Fast layer's detection rules to compose a baseline GitHub Actions pipeline. The two are a documented contract, not a shared code path — if you change the detection rules here, update `commands/setup-project.md` Phase 5 to match.

### 1. Lint

Detect the project's linter from manifest / config files:

- **`eslint`** — if `eslint.config.*` or `.eslintrc.*` exists at the worktree root, run `pnpm --dir <wt> exec eslint .` (or `pnpm --dir <wt> run lint` if `package.json` has a `lint` script). Use the script if present — operator may have wrapped eslint with extra flags.
- **`prettier`** (format check) — if `.prettierrc.*` or `prettier.config.*` exists, run `pnpm --dir <wt> exec prettier --check .`. Reports format drift, not just syntax.
- **`biome`** — if `biome.json` exists, run `pnpm --dir <wt> exec biome check .` (biome bundles lint + format).
- **`ruff`** — if `pyproject.toml` has `[tool.ruff]` or `ruff.toml` exists, run `ruff check`.
- **Other** — if the project's `package.json` has a `lint` script and none of the above matched, run it.

If no linter is detectable, record `lint: skipped (no linter configured)` — do not fail the check.

### 2. Typecheck

Detect the project's typecheck command:

- **`tsc`** — if `tsconfig.json` exists, run `pnpm --dir <wt> exec tsc --noEmit`.
- **`mypy`** — if `pyproject.toml` has `[tool.mypy]` or `mypy.ini` exists, run `mypy .`.
- **`pyright`** — if `pyrightconfig.json` exists, run `pyright`.
- **Project's `typecheck` script** — if `package.json` has a `typecheck` script and none of the above matched, run it.

If no typechecker is detectable, record `typecheck: skipped (no typechecker configured)`.

### 3. Unit + integration tests

Detect the project's test command:

- **`vitest`** — if `vitest.config.*` exists or `package.json:devDependencies.vitest` is present, run `pnpm --dir <wt> exec vitest run` (the `run` flag disables watch mode).
- **`jest`** — if `jest.config.*` exists or `package.json:devDependencies.jest` is present, run `pnpm --dir <wt> exec jest`.
- **`pytest`** — if `pyproject.toml` has `[tool.pytest]` or `pytest.ini` exists, run `pytest -q`.
- **Project's `test` script** — fallback: `pnpm --dir <wt> test` if `package.json:scripts.test` is set.

If no tests are configured, record `tests: skipped (no test runner configured)` and **mark the overall validation as failed** — a project with no tests should not pass the validation gate. (Operator can override by explicitly setting a `test` script that is a no-op, like `echo 'no tests yet'`, with the understanding that this is a deliberate exemption.)

## Slow layer (only with `--full`)

### 4. Playwright e2e + screenshots

Run only when `$ARGUMENTS` contains `--full`. Otherwise skip and report `e2e: skipped (fast mode)`.

Delegates to the `visual-validation` skill (the same skill `e2e-runner` invokes during the PR gate). The skill discovers the project's Playwright config, runs the e2e suite headless, captures screenshots on success and on failure, and stores them at `<worktree>/.task-log/screenshots/<iso-timestamp>/`.

The slow layer is the PR-gate equivalent — run it **once** before `pr-author` opens the PR, never inside the inner implement↔validate loop (it is too slow to iterate against, and screenshots from intermediate failed iterations are noise).

## Output

Print a structured summary in this exact format (the `task-orchestrator` parses it to decide the inner loop's next action):

> Render the labels below in the operator's chatLanguage — the English is illustrative structure, not literal output.

```text
== /validate report ==

Worktree:  <abs-path>
Mode:      fast | full

Fast layer:
  lint:       pass | fail | skipped (<reason>)
  typecheck:  pass | fail | skipped (<reason>)
  tests:      pass | fail | skipped (<reason>)

Slow layer (only when --full):
  e2e:        pass | fail | skipped (<reason>)

Overall:     pass | fail

<if any check failed>
Failures:
  <check-name>: <first 5–20 lines of the failure output verbatim>
  <check-name>: <first 5–20 lines of the failure output verbatim>
</if>
```

The orchestrator consumes this verbatim. The `task-orchestrator` agent's inner loop (see `agents/task-orchestrator.md` step 5) is the authoritative consumer.

## Hard refusals

- **Never** fix issues — `/validate` is read-only execution of existing checks. If a lint error is real, the implementer (re-invoked by the orchestrator on the next iteration) fixes it.
- **Never** write tests — that is `tester`'s job. `/validate` only runs what already exists.
- **Never** install dependencies. If a check fails because the linter / typechecker / test runner is not installed, report it as `<check>: fail (<tool> not installed — run pnpm install)` and let the orchestrator surface that to the operator.
- **Never** silently skip a check that has the tooling configured. A real failure must always show up in the summary, even when subsequent checks pass.
- **Never** invoke `pnpm install`, `pnpm add`, or any package-mutating command. This command is read-only with respect to project state.
- **Never** run the slow layer (Playwright) without the explicit `--full` flag — the inner loop calls this command repeatedly, and an unexpected slow layer would explode the iteration cost.
