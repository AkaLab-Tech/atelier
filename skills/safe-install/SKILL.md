---
name: safe-install
description: >-
  Audit and validate a dependency BEFORE running `pnpm add`. Use this skill
  whenever the user (or any agent) wants to install/add a package, mentions a
  new dependency, runs `pnpm add` / `pnpm install <pkg>`, edits `package.json`
  to add a dep, or any phrasing about adding a library. Applies PLAN.md §4 in
  order — self-question whether stdlib or an existing utility already solves
  the problem, compare ≥2 alternatives, justify the choice, reject packages
  younger than 7 days, reject packages with moderate-or-higher vulnerabilities.
  Refuses the install when any guardrail fails and surfaces the exact reason
  so the operator can decide whether to override. Trigger this even when the
  user does not say "audit" or "safe" — any phrasing about adding a new
  package belongs here.
---

# safe-install

A skill that wraps every `pnpm add` with the dependency-install rules from PLAN.md §4. The per-project `.npmrc` (`minimum-release-age=10080`, `audit-level=moderate`) is a silent backstop, but this skill makes the reasoning explicit so the **why** lives in the commit/PR, not just in a config file the reviewer might not check.

## The rule, restated

Before any new dependency lands in `package.json`:

1. **Self-question.** Does the standard library (Node `node:` modules, browser APIs), an existing project utility, or a transitive dep already solve the problem?
2. **Compare ≥ 2 alternatives.** Prefer: more weekly downloads, maintained in the last 6 months, minimal transitive deps, no native build step unless required.
3. **Justify** the choice in the commit message or PR description (1–2 sentences).
4. **Reject** packages younger than 7 days (also enforced by `.npmrc minimum-release-age=10080`).
5. **Reject** packages with reported moderate-or-higher vulnerabilities (also enforced by `.npmrc audit-level=moderate`).

Steps 4–5 are belt-and-braces with the per-project `.npmrc`, but **never** rely on the npmrc alone — the operator should see the explicit decision in the PR, and CI on a future fork of the project might not have the same `.npmrc`.

## How to run

Apply the steps in order. Stop and report at the first failure.

### Step 1 — Self-question (~30 seconds, not skippable)

Ask: *"Can I solve this with what we already have?"* Common false-needs:

- **Date / time formatting** → `Intl.DateTimeFormat` (built-in) instead of `dayjs`/`moment`.
- **HTTP requests** → `fetch` (built-in, both Node ≥ 18 and browsers) instead of `axios`/`got`/`node-fetch`.
- **UUIDs** → `crypto.randomUUID()` instead of `uuid`.
- **Deep-clone** → `structuredClone()` instead of `lodash.clonedeep`.
- **Querystring** → `URLSearchParams` instead of `qs`.
- **Small utilities** (debounce, throttle, group-by) → often a 5-line internal helper instead of `lodash`.

Record the answer in the report. *"Yes, stdlib suffices"* short-circuits the whole skill — refuse the install and suggest the stdlib path.

### Step 2 — Compare ≥ 2 alternatives

Use `pnpm view <pkg>` to gather facts. For each candidate:

```sh
pnpm view <pkg> name version time.modified deprecated repository.url
pnpm view <pkg> dependencies
```

Cross-check on npm (or via `pnpm view <pkg> downloads`) for **weekly downloads**. Prefer:

- More downloads (rough proxy for ecosystem trust — not a strict rule).
- Last publish ≤ 6 months ago.
- No `deprecated` field set.
- Minimal transitive dependency tree (e.g., `pnpm view <pkg> dependencies` returns ≤ 5 direct deps for utility libs).
- No native build step unless required.

Two candidates is the minimum; three is fine; ten is procrastination.

### Step 3 — Age check (hard fail < 7 days)

```sh
pnpm view <pkg>@<version> time
```

`time` is a JSON-like map of `version → ISO-timestamp`. Compare the chosen version's timestamp to *now*. If `now - published < 7 days`, refuse and report:

```text
✗ safe-install — package age check FAILED
  package:     <pkg>@<version>
  published:   <ISO> (<N days ago>)
  requirement: ≥ 7 days old (PLAN.md §4 step 4)
  action:      wait, pick an older version, or pick a different package
```

### Step 4 — Vulnerability check (hard fail moderate+)

Run `pnpm audit` against a dry-run install — there's no built-in "audit before install" verb, so the practical recipe is:

1. Note the current `pnpm-lock.yaml` hash (so we can verify nothing changed).
2. Add the package with `--lockfile-only` (this updates the lockfile but does not install to `node_modules`):

   ```sh
   pnpm add --lockfile-only <pkg>@<version>
   ```

3. Run `pnpm audit --audit-level=moderate`.
4. If audit reports any **moderate / high / critical** advisories for the new package or its transitive closure, **revert the lockfile** (`git checkout -- pnpm-lock.yaml`) and refuse:

   ```text
   ✗ safe-install — vulnerability check FAILED
     package:     <pkg>@<version>
     advisories:  2 high, 1 critical (via <transitive-path>)
     requirement: no moderate+ vulnerabilities (PLAN.md §4 step 5)
     action:      pick a newer version that patches the CVEs, or pick a different package
   ```

5. If audit is clean, proceed.

### Step 5 — The actual install + justification

```sh
pnpm add <pkg>@<version>          # for runtime deps
pnpm add -D <pkg>@<version>       # for devDeps
```

Then **immediately write the justification into the commit or PR body**:

```markdown
**Dependency added:** `<pkg>@<version>`

- *Stdlib check:* <one sentence — why this can't be stdlib>
- *Alternatives compared:* `<alt-a>` (downloads: X, last publish: Y) vs `<chosen>` (downloads: X, last publish: Y) vs `<alt-b>` (downloads: X, last publish: Y).
- *Why this one:* <one sentence>.
- *Age:* published <N days ago> (≥ 7 ✓).
- *Audit:* `pnpm audit --audit-level=moderate` clean ✓.
```

This text belongs in the commit body **or** the PR description, but it must exist somewhere reviewers will see it.

## Report format

When the install succeeds, return:

```text
== safe-install report ==

stdlib check:   ✓ stdlib insufficient — <reason>
alternatives:   ✓ compared <alt-a>, <chosen>, <alt-b>
age check:      ✓ <pkg>@<version> published <N days ago>
audit check:    ✓ clean (pnpm audit --audit-level=moderate)
install:        ✓ pnpm add <pkg>@<version>
justification:  written to <commit body | PR description>

Result:         GREEN — dependency added safely.
```

When the install is refused, return:

```text
== safe-install report ==

stdlib check:   ✗ stdlib suffices via <built-in / existing util>
  → suggestion: use <built-in / existing util> instead of <pkg>
  → install:    REFUSED

Result:         RED — install refused.
```

(Or any of the other refusal shapes from steps 3–4.)

## Decision rules

- **Never** silently fall back to `npm` or `yarn`. pnpm only (PLAN.md §2 step 2).
- **Never** install `<pkg>@latest` without resolving it to a concrete version first — the version pinned in the lockfile is what the operator reviews.
- **Never** edit `package.json` directly to add a dependency; always go through `pnpm add` so the lockfile updates correctly.
- **Never** suppress audit findings by passing `--audit-level=high` to dodge moderate advisories. The bar is moderate; that's the rule.
- When the operator explicitly overrides a refusal ("I know this package is 3 days old, install it anyway"), proceed — but record the override in the commit/PR body so it's visible at merge time.

## Why this skill exists

Supply-chain attacks (`event-stream`, `colors.js` sabotage, `node-ipc` wiper, ongoing typosquats) all entered projects through casual `npm install` / `pnpm add`. PLAN.md §4 is the rule; `safe-install` is the rule made executable. Without it, agents will add deps reflexively, the per-project `.npmrc` will quietly stop them, and the operator will never know why — or the operator will weaken the `.npmrc` once it gets in the way, and the rule will rot.
