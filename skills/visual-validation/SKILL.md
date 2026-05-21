---
name: visual-validation
description: >-
  Run Playwright end-to-end tests on the current project, capture screenshots
  for every test, upload them as GitHub secret gists, and return a
  markdown block ready to paste into a PR description. ALWAYS load this
  skill when about to run any of `pnpm exec playwright`, `npx playwright`,
  `playwright test`, or `playwright install`, or when the user asks for
  "e2e", "Playwright", "visual tests", "screenshots for the PR", or
  "browser tests". Also load it when the `e2e-runner` agent is
  driving the chain. The skill carries the executable detail
  `operator-rules.md` and other skills cannot — lazy-install recipe for
  `@playwright/test` (so operators who never run e2e never pay the
  ~250 MB browser download), screenshot upload via `gh gist create
  --secret`, and the exact markdown shape `pr-author` expects.
  Refuses to install the deprecated `playwright` package (use
  `@playwright/test` instead), refuses public gists for screenshots,
  refuses to overwrite an existing `playwright.config.ts`. Trigger even
  when keywords are absent — any phrasing about e2e validation belongs
  here.
---

# visual-validation

The executable recipe for the e2e validation step of the agent chain. Drives Playwright, captures screenshots, uploads them to GitHub gists so they embed cleanly into the PR description.

## Preconditions

The skill assumes:

- Current cwd is inside a pnpm-managed project (the worktree the agent is operating in).
- The operator has authenticated `gh` (`gh auth status` returns OK). Without it, gist upload fails — the skill surfaces that and falls back to *paths-only* (lists local screenshot paths in the PR markdown block instead of embedding URLs).
- `pnpm` and `git` are on PATH (installed by `install.sh` Phase A).

If `pnpm` is missing, **stop** and report — this is not a pnpm project, e2e via Playwright is out of scope here.

## The flow

### Step 1 — Lazy install of `@playwright/test`

Detect whether `@playwright/test` is already a dependency:

```bash
pnpm ls @playwright/test --depth 0 --json 2>/dev/null | jq -e '.[].devDependencies."@playwright/test" // .[].dependencies."@playwright/test"' >/dev/null 2>&1
```

If not present:

1. Surface to the operator: *"This is the first e2e run in this project. About to install `@playwright/test` (devDep) + browsers (~250 MB cached at `~/.cache/ms-playwright`)."* Wait for confirmation if running interactively.
2. Run `pnpm add -D @playwright/test`. The `safe-package-change` hook intercepts this; `@playwright/test` is on the lifecycle-script allowlist, so it allows the install (lifecycle scripts of `@playwright/test` are part of legitimate native-build).
3. Run `pnpm exec playwright install`. This downloads chromium, firefox, and webkit into `~/.cache/ms-playwright`. Honour any `PLAYWRIGHT_BROWSERS_PATH` the operator has set; do not pass `--with-deps` unless the operator confirms — it can sudo-install OS packages.

If `@playwright/test` is already present, skip both installs and continue with step 2. Surface `existing install reused` in the report.

### Step 2 — Detect or scaffold the config

Check for `playwright.config.ts`, `playwright.config.js`, or `playwright.config.mjs` at the project root. If one exists, use it as-is — **do not overwrite**.

If none exists, scaffold a minimal one at `playwright.config.ts`:

```ts
import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: [["list"], ["html", { open: "never" }]],
  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL ?? "http://localhost:3000",
    trace: "on-first-retry",
    screenshot: "on",
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
});
```

Justify the choice in the agent's report (this is a config change that lands in the PR — see the dependency-justification rule from PLAN.md §4 applied to e2e scaffolding).

### Step 3 — Run the suite

Run Playwright in list-reporter mode so output is parsable:

```bash
mkdir -p .task-log/screenshots
pnpm exec playwright test --reporter=list 2>&1 | tee .task-log/playwright-output.txt
suite_rc=${PIPESTATUS[0]}
```

The `--screenshot=on` flag from the config (or `--screenshot=on` on the CLI as a fallback) ensures every test, pass or fail, produces a PNG under `test-results/`.

Move all screenshots to a stable location for upload:

```bash
find test-results -type f -name '*.png' -exec cp -- {} .task-log/screenshots/ \;
```

(Use `cp` rather than `mv` so Playwright's own HTML report still references them.)

### Step 4 — Upload screenshots as secret gists

For each PNG in `.task-log/screenshots/`:

```bash
url=$(gh gist create --secret "<path>" 2>/dev/null | tail -n1)
# url is the gist URL, e.g. https://gist.github.com/<user>/<id>
# Extract the raw image URL:
raw_url=$(gh gist view <id> --raw 2>/dev/null | head -n1)
# Or, easier: GitHub serves the raw blob at <gist-url>/raw/<file>
```

Track each `(test-name, raw-url)` pair. If `gh gist create` fails (no auth, no network), fall back to *paths-only* mode: collect the local file paths and use them in the markdown block instead of URLs. Surface the fallback in the report so the operator knows the embedded images are not live.

**Always `--secret`.** Public gists are search-indexed; even a screenshot of an internal admin UI is too much to leak.

### Step 5 — Assemble the markdown block

Produce a single markdown block the `pr-author` agent pastes verbatim into the PR description's `## E2E validation` section:

```markdown
## E2E validation

Playwright suite: <N passed, M failed, K skipped> (<duration>s).

<if any failed>
### Failures
- `<test-file>:<test-name>` — <first error line, truncated to 100 chars>
</if>

### Screenshots
![<test-scenario-1>](<gist-raw-url-1>)
![<test-scenario-2>](<gist-raw-url-2>)
…

<if any paths-only fallback>
> Some screenshots could not be uploaded to GitHub gists (gh auth failed). Local paths kept in `.task-log/screenshots/`:
> - `.task-log/screenshots/<file>.png`
</if>
```

## Hard refusals

- **Public gists.** Always `--secret`. If the operator explicitly insists on public gists for a specific case (rare), they can edit the gist visibility after upload.
- **Installing `playwright` (deprecated).** Only `@playwright/test` is supported.
- **Overwriting an existing `playwright.config.*`.** The project's config is owned by the operator. Append-only is not a thing for ESM configs.
- **`--with-deps`** for `playwright install`. This runs `apt-get install` (Linux) or equivalent — invasive system change. Operator must confirm.
- **Committing screenshots to the repository.** They live in `.task-log/screenshots/` (already gitignored by `/setup-project`) and on the gist server. Never under version control.
- **Modifying test files** to mask flakes. Flakes are surfaced; the operator decides what to do.

