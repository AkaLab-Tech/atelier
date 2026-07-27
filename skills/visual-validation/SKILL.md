---
name: visual-validation
description: >-
  Run Playwright end-to-end tests on the current project, capture screenshots
  for every test, keep them as local artifacts, and return a
  markdown block ready to paste into a PR description. ALWAYS load this
  skill when about to run any of `pnpm exec playwright`, `npx playwright`,
  `playwright test`, or `playwright install`, or when the user asks for
  "e2e", "Playwright", "visual tests", "screenshots for the PR", or
  "browser tests". Also load it when the `e2e-runner` agent is
  driving the chain. The skill carries the executable detail
  `operator-rules.md` and other skills cannot — lazy-install recipe for
  `@playwright/test` (so operators who never run e2e never pay the
  ~250 MB browser download), a text index of the screenshots uploaded via
  `gh gist create` (secret by default — the Gists API cannot hold binary
  images, so PNGs stay local and only the index is a gist), and the exact
  markdown shape `pr-author` expects.
  Refuses to install the deprecated `playwright` package (use
  `@playwright/test` instead), refuses to pass `--public` to `gh gist
  create`, refuses to overwrite an existing `playwright.config.ts`. Trigger
  even when keywords are absent — any phrasing about e2e validation belongs
  here.
---

# visual-validation

The executable recipe for the e2e validation step of the agent chain. Drives Playwright, captures screenshots, and keeps them as local artifacts under `.task-log/screenshots/` — the GitHub Gists API is text-only and cannot hold a PNG, so screenshots are never "uploaded" as images. A text index (test name → local path) is uploaded as a secret gist so the PR description has one stable link back to the run.

## Preconditions

The skill assumes:

- Current cwd is inside a pnpm-managed project (the worktree the agent is operating in).
- The operator has authenticated `gh` (`gh auth status` returns OK). Without it, the index-gist upload fails — the skill surfaces that and falls back to *paths-only* (lists local screenshot paths in the PR markdown block instead of a gist index link).
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

### Step 4 — Index the screenshots (they stay local; only a text index goes to a gist)

The GitHub Gists API stores text files only — it cannot hold a PNG. Screenshots are **not** uploaded anywhere; they stay under `.task-log/screenshots/` (already gitignored). What gets uploaded is a small **text index** — a markdown file mapping test name → local screenshot path → run metadata — so the PR description has one stable link back to the run instead of a wall of file paths.

Build the index file:

```bash
index_file=.task-log/screenshots/INDEX.md
{
  echo "# Playwright screenshot index"
  echo
  echo "Run: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  for f in .task-log/screenshots/*.png; do
    printf -- '- `%s`\n' "$f"
  done
} > "$index_file"
```

Upload it as a gist — `gh gist create` is **secret by default** (per `gh gist create --help`: *"By default, gists are secret; use `--public` to make publicly listed ones."*). There is no `--secret` flag; passing one is an error (`unknown flag: --secret`). Do not pass `--public` either — the default is what you want:

```bash
gist_url=$(gh gist create "$index_file" 2>/dev/null)
# gh gist create prints the created gist's URL to stdout, e.g.
# https://gist.github.com/<user>/<id>
```

If `gh gist create` fails (no auth, no network), fall back to *paths-only* mode: skip the gist link and list the local screenshot paths directly in the markdown block. Surface the fallback in the report.

Note there is no equivalent of a "raw image URL" here — `gh gist view <id> --raw` prints the raw *contents* of a gist file (text), not a URL, and there is nothing to point an `![]()` embed at. Do not use it as a URL source.

### Step 5 — Assemble the markdown block

Produce a single markdown block the `pr-author` agent pastes verbatim into the PR description's `## E2E validation` section. It must be honest that screenshots are local artifacts, not embedded images — no `![](...)` tags pointing at fabricated URLs:

```markdown
## E2E validation

Playwright suite: <N passed, M failed, K skipped> (<duration>s).

<if any failed>
### Failures
- `<test-file>:<test-name>` — <first error line, truncated to 100 chars>
</if>

### Screenshots
Screenshots are local artifacts (the GitHub Gists API cannot host images) — an index is at <gist-url>, and the files themselves are kept under `.task-log/screenshots/` in this worktree:
- `<test-scenario-1>` → `.task-log/screenshots/<file-1>.png`
- `<test-scenario-2>` → `.task-log/screenshots/<file-2>.png`
…

<if any paths-only fallback>
> The screenshot index could not be uploaded to a gist (gh auth failed). Local paths kept in `.task-log/screenshots/`:
> - `.task-log/screenshots/<file>.png`
</if>
```

## Hard refusals

- **`--public` on `gh gist create`.** Gists default to secret already — never pass `--public`. (There is no `--secret` flag; it does not exist on the real `gh` CLI.)
- **Installing `playwright` (deprecated).** Only `@playwright/test` is supported.
- **Overwriting an existing `playwright.config.*`.** The project's config is owned by the operator. Append-only is not a thing for ESM configs.
- **`--with-deps`** for `playwright install`. This runs `apt-get install` (Linux) or equivalent — invasive system change. Operator must confirm.
- **Committing screenshots to the repository.** They live in `.task-log/screenshots/` (already gitignored by `/atelier:setup-project`) — local only, never under version control, and never uploaded anywhere as binary content (only the text index gist).
- **Modifying test files** to mask flakes. Flakes are surfaced; the operator decides what to do.

