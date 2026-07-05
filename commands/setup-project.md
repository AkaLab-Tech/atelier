---
description: Initialise a project so the operator can run atelier tasks in it — delegates to the `atelier-setup-project` bash helper installed by `install.sh`, then dispatches `project-profiler` to draft the root `CLAUDE.md`. Idempotent — re-running preserves all existing files. Typical usage is just `/atelier:setup-project` from inside the project directory; passing a path is only for the uncommon case of configuring a project from outside it.
argument-hint: "[--yes|-y] [--mode=new|existing] [--apply-branch-protection] [--backend <files|linear|github-project>] [--scaffold-ci] [project-path-if-not-cwd]"
allowed-tools: Read, Glob, Grep, Write, Bash(atelier-setup-project:*), Bash(git -C * remote get-url origin:*), Bash(git remote get-url origin:*), AskUserQuestion, Task
---

You are running the `/setup-project` slash command. This command has two phases: (1) delegate mechanical scaffolding to the `atelier-setup-project` bash binary on `$PATH`, then (2) dispatch the `project-profiler` agent to draft the root `CLAUDE.md` based on the mode the bash helper detected.

**Typical invocation is `$ARGUMENTS = empty`** — the operator runs `/atelier:setup-project` from inside the project directory they want to configure, and the helper resolves the project path to `pwd` automatically. A positional `<project-path>` is only used when configuring a project from outside it; the argument-hint puts it last so operators don't reflexively pass `.` as a "required" path.

## Phase 1 — bash helper

Invoke the bash helper, passing through the operator's arguments verbatim. **Do NOT pass `--plugin-root` from the slash command**: `$CLAUDE_PLUGIN_ROOT` is only auto-set by Claude Code for hook invocations, not for Bash tool calls inside slash commands. Passing `--plugin-root ""` (the empty expansion of an unset env var) used to make the helper die with `"--plugin-root requires a path"`. The helper now auto-discovers its own plugin root via the symlink chain (`~/.local/bin/atelier-setup-project` → `<dotfiles>/scripts/atelier-setup-project`, parent dir is the atelier checkout containing `templates/` + `.claude-plugin/`), so the slash command just calls:

```bash
atelier-setup-project $ARGUMENTS
```

That single command does **all** of the mechanical work:

1. Resolves the project path — **defaults to the current working directory** when `$ARGUMENTS` is empty (the typical case: operator is inside the project they want to configure). Only resolves to an explicit `<project-path>` when one is passed. Refuses dangerous targets: `$HOME`, `/`, `/etc`, `/usr`, `/Applications`, `/bin`, `/sbin`, `/var`, `/opt`, `/private`, and the plugin root itself.
2. Detects non-interactive mode via `--yes` / `-y` in `$ARGUMENTS`, or `$ATELIER_AUTO`.
3. Reads `$ATELIER_CONFIG_DIR/projects.json` (atelier's project registry). If the project is already configured: interactive → ask to reconfigure; non-interactive → refuse with exit code 2.
4. Writes `<path>/.claude/settings.json` from `$ATELIER_CONFIG_DIR/templates/settings.template.json` with `<worktree>` substituted. Validates the result parses with `jq empty` and that no literal `<worktree>` token remains.
5. Writes `<path>/.atelier.json` from `$ATELIER_CONFIG_DIR/templates/atelier.template.json` **only when missing**. This file is operator-owned after creation — it carries per-project overrides for `prSize.{maxLines,maxFiles,exempt}` (the auto-merge size budget enforced by `atelier-pr-size-check`) and `taskDecomposer.enabled` (set to `false` to disable the automatic epic-decomposition pass that runs before delegating to `implementer`; the `/atelier:slice-task` manual override stays available regardless), and `taskConcurrency.max` (how many `task/*` tasks `/atelier:next-task` may have in flight at once; default `1`, raise to parallelise non-colliding work), and `deliverableLanguage` (the language atelier writes commits / PRs / code comments / generated docs in — default `"English"`, regardless of the project's own content language; see `operator-rules.md` § Deliverable language). To reset to defaults, delete the file and re-run setup-project.
6. Creates `<path>/ROADMAP.md`, `<path>/IN_PROGRESS.md`, `<path>/HISTORY.md`, `<path>/.claude/CLAUDE.md` only when missing (the latter from `$CLAUDE_PLUGIN_ROOT/templates/project-claude.md.template`).
7. Creates or appends to `<path>/.npmrc` the three PLAN.md §4 guardrails (`ignore-scripts=true`, `minimum-release-age=10080`, `audit-level=moderate`); never weakens existing values.
8. Creates or appends to `<path>/.gitignore` the four required entries (`.task-log/`, `.claude/settings.json`, `.claude/settings.local.json`, `.DS_Store`). `.claude/settings.json` is gitignored because the helper substitutes `<worktree>` with the operator's absolute path; committing it would propagate that path to every clone. Note `.atelier.json` is **not** gitignored — it's part of the project's source of truth (per-project size budget belongs in version control).
9. Records the setup in `$ATELIER_CONFIG_DIR/projects.json` with `setupCompleted` and `setupVersion`.
10. Probes the default branch's protection rule via `gh api repos/{owner}/{repo}/branches/{branch}/protection` (M7.1.F31) and classifies it: `protected-sufficient` (≥1 required approving review — auto-merge ready), `protected-insufficient` (rule exists but no required reviews — auto-merge guardrail #2 holds forever), `unprotected` (no rule), or `no-admin` (token lacks repo-admin; cannot read). On a gap, explains the guardrail-#2 link (empty `reviewDecision`) and offers to apply an idempotent minimal rule (`required_approving_review_count=1`, `enforce_admins=false`, `restrictions=null`). Decision policy: applies autonomously when `decisionPolicy["branch-protection"] == "auto"` in `.atelier.json`, or when `--apply-branch-protection` is passed; otherwise prompts interactively. On `no-admin`, prints the exact `gh api -X PUT` command the operator can run manually. Never fails setup.

The helper also emits these `atelier-*=...` marker lines that later phases parse:

- `atelier-detected-mode=new|existing` — the heuristic result (or `--mode=...` override).
- `atelier-root-claude-md=present|missing` — whether `<path>/CLAUDE.md` already exists.
- `atelier-tracking-layout=created|preserved-empty|preserved-nonempty` — whether `IN_PROGRESS.md` was created fresh (canonical empty slot), pre-existed and is empty, or pre-existed with task-like content. `preserved-nonempty` triggers Phase 3.
- `atelier-roadmap-format=absent|conforming|non-conforming` — whether an existing `ROADMAP.md` already uses atelier's §5 layout. `non-conforming` triggers Phase 3b.
- `atelier-backend=files|linear|github-project|…` — the backend resolved from an existing `<path>/.roadmap.json` (`.backend` field via `jq`), defaulting to `files` when the file is absent or `jq` is unavailable. Phase 4 uses this to decide whether to delegate to `/create-roadmap --backend`.
- `atelier-ci-status=present|absent` — read-only CI/CD detection (GitHub Actions or another recognised provider config). Phase 5 uses this to decide whether to offer a baseline pipeline scaffold. The helper never writes a workflow file itself.

Relay the helper's stdout back to the operator verbatim. If the helper exits non-zero, surface the error and stop — do NOT run Phase 2.

## Phase 2 — root `CLAUDE.md` draft

After the bash helper completes, parse its stdout for the two marker lines (`atelier-detected-mode=...` and `atelier-root-claude-md=...`). The split:

- **`project-profiler` (read-only)** scans the repo and **returns a drafted `CLAUDE.md` content block** in its report. It does NOT write the file itself — its tools list excludes `Write` by design.
- **This slash command** takes the drafted content from the agent's report and writes it to `<project>/CLAUDE.md` using the `Write` tool. The session's initial permissions cover this path; the agent's sub-scope does not.

### Decision table (which action this slash command takes)

| `atelier-root-claude-md` | `atelier-detected-mode` | Action |
| --- | --- | --- |
| `present` | (ignored) | **Skip Phase 2 entirely.** Print: *"Root CLAUDE.md already exists — preserved."* Do not dispatch any agent, do not write anything. The operator's customizations are sacred. |
| `missing` | `existing` | **Invoke `Task` with `subagent_type: "project-profiler"`.** Briefing payload: `{ mode: "existing", project_path: "<abs>" }`. The agent scans manifests / src layout / CI configs / README and **returns drafted content in its report**. After it returns, **extract the inner content of the agent's `## Drafted content` fenced block and Write it to `<abs>/CLAUDE.md`.** |
| `missing` | `new` | **Ask the operator** via `AskUserQuestion`: *"What is this project about? Describe in your own words — purpose, intended stack if you know, anything else useful."* (free-form, no preset options). Then **invoke `Task` with `subagent_type: "project-profiler"`** and briefing `{ mode: "new", project_path: "<abs>", operator_answer: "<the answer>" }`. After it returns, same extract + Write as above. |

After the Write completes, surface the agent's report **verbatim** to the operator (including the `## Drafted content` block) so they can see what was written. Then proceed to Phase 3.

(When the decision table's `present` row applies and Phase 2 is skipped, go straight to Phase 3.)

### Non-interactive mode in Phase 2

If `$ARGUMENTS` carries `--yes` / `-y` or `$ATELIER_AUTO` is set:

- `existing` mode: dispatch `project-profiler` immediately via `Task` — no operator input needed for the scan. **The `--yes` does NOT change this code path; it is the same dispatch as the interactive case.**
- `new` mode: **stop and report** — the `AskUserQuestion` for the interview cannot run non-interactively. Print: *"Non-interactive setup of a new project requires `--mode=existing` to skip the interview, or re-run interactively."*

This rule prevents an autonomous chain from drafting a fabricated `CLAUDE.md` from a fabricated answer.

### Mandatory dispatch + Write path

When the decision table says "dispatch `project-profiler`", the **only** correct implementation is:

```text
1. Task(subagent_type: "project-profiler", description: "Draft root CLAUDE.md", prompt: <briefing>)
2. Parse agent's report: locate the ` ```markdown ... ``` ` fenced block under `## Drafted content`.
3. If status == "drafted": Write(<abs>/CLAUDE.md, <extracted content>).
4. If status == "kept-existing": skip Write, print preservation note.
```

The agent's report carries the drafted content as a literal markdown fenced block. Extract the inner markdown (between `` ```markdown `` and `` ``` ``), trim no whitespace, and call `Write(<abs>/CLAUDE.md, <content>)`. The Write succeeds because this slash command's session is the one with `Write` on the project path in its allowed-tools.

If `Task` returns an error (agent not found, dispatch refused, etc.), surface it and stop. Do **not** fall back to inventing CLAUDE.md content from scratch — without the agent's scan, the content would be fabricated.

If the agent's report is missing the `## Drafted content` block (and status is not `kept-existing`), the agent malformed its output: surface the report verbatim and stop. The slash command should not try to "recover" by inventing content.

## Phase 3 — tracking adoption checks

Two **independent** checks run here, off two separate bash signals. Evaluate **both** — a project can trip either, both, or neither. Both only ever *offer* `/adopt-roadmap`; this phase is read-only on the operator's tracking files. The only write that can happen is `/adopt-roadmap`'s own — invoked through its command, with its own confirmation — never an inline edit from `/setup-project`.

### Phase 3a — legacy `IN_PROGRESS.md` tracker

Parse the helper's stdout for `atelier-tracking-layout=...`. This check only does something when the value is `preserved-nonempty`; for `created` and `preserved-empty` there is nothing to check.

When `atelier-tracking-layout=preserved-nonempty`, `IN_PROGRESS.md` pre-existed and carries task-like content. That content is one of two things, and the bash signal cannot tell them apart — **you** decide by reading the file:

1. **`Read` `<project>/IN_PROGRESS.md`.**
2. **Classify it:**
   - **A legit single active task** — one task block (one checkbox or one heading), no completed (`[x]`) items mixed in, no multiple phase/section headings. This is the normal occupied-slot state. **Do nothing** — print a one-line note that an active task is already in the slot.
   - **A legacy multi-phase tracker** — multiple `##`/`###` section headings (e.g. `RLS`, `ADMIN`, `WEB`, `i18n`), and/or several checkboxes including done (`[x]`) items. This is the layout that predates the single-active-task slot and blocks tools like `/next-task`. Continue.
3. **For the legacy case, offer normalization — do not transform anything yourself.** The transformation logic is sovereign in `claude-roadmap-tools`'s `/adopt-roadmap`; `/setup-project` only detects and delegates. It must never rewrite tracking files directly.
   - **Interactive mode:** use `AskUserQuestion` — *"`IN_PROGRESS.md` looks like a multi-phase tracker, not a single active-task slot. Tools like `/next-task` will treat it as permanently occupied. Normalize it now with `/adopt-roadmap` (done items → `HISTORY.md`, open items → `ROADMAP.md`, slot reset to empty; nothing is dropped)?"* — options: run `/adopt-roadmap` now / skip for now. If the operator agrees and the `claude-roadmap-tools` plugin is installed (the `/adopt-roadmap` command resolves), run it **with `--format atelier`** so the adopted `ROADMAP.md` lands in the PLAN.md §5 layout that `task-discovery` / `/next-task` parse (`P0`/`P1`/`P2` + type tags; the operator then fills any `` `TODO-type` `` / `` `~TODO` `` placeholders and runs `/atelier:plan-task <id>` per task). If the plugin is not installed, point the operator at it (`claude plugin install claude-roadmap-tools@akalab-tech`) and stop — do not attempt the adoption manually.
   - **Non-interactive mode** (`--yes` / `-y` / `$ATELIER_AUTO`): **do not** run the adoption automatically — it is a judgment-heavy content rewrite. Print the recommendation (*"Detected a legacy phase-tracker `IN_PROGRESS.md`; run `/adopt-roadmap --format atelier` interactively to normalize it"*) and stop.

### Phase 3b — non-§5 `ROADMAP.md` (M7.1.F74)

Parse the helper's stdout for `atelier-roadmap-format=...`. This check only does something when the value is `non-conforming`; for `conforming` and `absent` there is nothing to do.

`non-conforming` means `ROADMAP.md` pre-existed but does **not** use the PLAN.md §5 layout (no `P0`/`P1`/`P2` priority sections — e.g. a foreign format with `## Backlog`, `TASK-NN` ids, "Prioridad Alta"). This is **independent of `IN_PROGRESS.md`**: F74 was the gap where a non-§5 ROADMAP onboarded silently — zero tasks plannable or claimable by `task-discovery` / `/next-task` — because the adoption offer keyed only off `IN_PROGRESS.md` (Phase 3a), which a "(no tasks in progress)" file passes as `preserved-empty`.

Offer normalization — do not transform anything yourself (same delegation rule as 3a):
- **Interactive mode:** use `AskUserQuestion` — *"`ROADMAP.md` doesn't use atelier's §5 layout (no P0/P1/P2 priority sections), so `/atelier:next-task` can't claim any of its tasks. Normalize it now with `/adopt-roadmap --format atelier` (emits the `P0`/`P1`/`P2` + type-tag + `#id` layout with `TODO` placeholders; nothing is dropped)?"* — options: run `/adopt-roadmap --format atelier` now / skip for now. If the operator agrees and `claude-roadmap-tools` is installed, run it **with `--format atelier`**; the operator then fills any `` `TODO-type` `` / `` `~TODO` `` placeholders and runs `/atelier:plan-task <id>` per task. If the plugin is not installed, point them at it (`claude plugin install claude-roadmap-tools@akalab-tech`) and stop. Note: atelier's own repo and any project intentionally using the `High`/`Medium`/`Low` layout will also trip this — the operator simply declines.
- **Non-interactive mode** (`--yes` / `-y` / `$ATELIER_AUTO`): **do not** run the adoption automatically. Print the recommendation (*"`ROADMAP.md` is not §5 (no P0/P1/P2 sections); run `/adopt-roadmap --format atelier` interactively to make its tasks claimable"*) and stop.

## Phase 4 — backend selection (M9.3a)

After Phases 1–3 complete, determine and apply the operator's chosen roadmap backend. Parse the helper's stdout for `atelier-backend=...` to learn what backend the project already has.

### Step 4a — determine the chosen backend

Evaluate in order:

1. **Explicit flag (`--backend <value>` in `$ARGUMENTS`)**: parse `--backend` from `$ARGUMENTS`, mirroring the `--yes`/`-y`/`--mode=` parsing in Phase 1. Accept exactly `files`, `linear`, or `github-project`; for any other value print a usage error and stop:
   > `Unknown --backend value: '<value>'. Valid options: files | linear | github-project`

2. **Interactive (no `--backend` flag and not headless)**: use `AskUserQuestion` to offer the three options:
   - `files` *(default — local markdown files; ROADMAP.md / IN_PROGRESS.md / HISTORY.md)*
   - `linear` *(Linear.app — issues and projects via claude-roadmap-tools)*
   - `github-project` *(GitHub Projects — board items via claude-roadmap-tools)*

3. **Headless with no `--backend` flag** (`--yes`/`-y`/`$ATELIER_AUTO` and no explicit flag): **default to `files` silently.** A remote backend requires interactive OAuth (PLAN.md §16.4) that cannot auto-resolve; never silently select one. If a headless run *does* pass an explicit `--backend github-project` or `--backend linear`, print a clear note before delegating:
   > `Note: crt's /create-roadmap --backend <choice> may still require interactive OAuth on the first backend call. Proceeding with delegation.`

### Step 4b — idempotency check

Compare the chosen backend against the `atelier-backend=` marker from the helper's stdout:

- If `atelier-backend=<chosen>` already matches the chosen backend, **skip step 4c** (the project is already configured for that backend). Print: *"Backend already configured as `<chosen>` — nothing to do."*
- If the chosen backend is `files` and no `.roadmap.json` exists (the normal fresh-files case): also **skip step 4c** — the `files` layout is already complete from Phase 1's `step_roadmap_files()`. Print: *"Backend: `files` — local markdown layout complete."*

### Step 4c — delegate to `/create-roadmap --backend <choice>` (non-`files` only)

When the chosen backend is `linear` or `github-project`:

1. **Check `claude-roadmap-tools` is installed.** The `/create-roadmap` command must resolve. If it does not, print:
   > `claude-roadmap-tools is not installed. Run: claude plugin install claude-roadmap-tools@akalab-tech`
   Then stop — do **not** write `.roadmap.json` inline.

2. **Invoke `/create-roadmap --backend <choice>`.** This is exactly the same delegation mechanism Phase 3 uses to invoke `/adopt-roadmap` — a prose-instruction invocation of the slash command, not a `Bash` or `Write` call. crt owns writing `.roadmap.json` and registering any MCP hooks; this slash command does neither inline.

3. **Interactive vs headless**: mirror Phase 3's handling:
   - *Interactive*: invoke `/create-roadmap --backend <choice>` and relay its output to the operator.
   - *Headless (`--yes`/`-y`/`$ATELIER_AUTO`)* with explicit `--backend`: same invocation — print the headless-OAuth note first (Step 4a rule 3 above), then invoke.

4. After the delegation completes (or is skipped), surface the final `atelier-backend=` value to the operator so they can see the configured state.

## Phase 5 — CI/CD scaffold offer

Parse the helper's stdout for `atelier-ci-status=...`. The helper's detection is **read-only** — it never writes a workflow file; this phase is the only place a workflow can be written, and only under explicit confirmation.

Stack detection here **must not drift** from `/validate`'s "Fast layer" (`commands/validate.md`) — both read the same manifest / config files to infer the linter, typechecker, and test runner. This is a documented contract, not a shared code path: if you change one, update the other.

### Step 5a — gating

Act only when **all** of the following hold; otherwise do nothing (no output, no offer):

1. `atelier-ci-status=absent` (when `present`, print *"CI already configured — preserved."* and stop — never touch an existing workflow).
2. `atelier-detected-mode=existing` (from Phase 1's marker). A brand-new (`new`-mode) project has nothing yet to run lint/typecheck/test against — skip silently.
3. `<project>/package.json` exists. The baseline pipeline runs `pnpm install` + `pnpm`-driven steps (per the pnpm-only rule); a non-Node project has no pnpm surface to scaffold against — skip silently.
4. The project has a GitHub remote: run `git -C <project> remote get-url origin` and check the URL contains `github.com`. If there is no `origin` remote, or it points elsewhere (GitLab, Bitbucket, self-hosted), print a short note — *"CI/CD scaffold only supports GitHub Actions; `origin` is not a GitHub remote — skipping the offer."* — and stop. Do not attempt to scaffold a non-GitHub-Actions pipeline.

### Step 5b — detect steps (mirrors `/validate`'s Fast layer)

Using `Read`/`Glob` against `<project>` (never `Bash`, this is pure file inspection):

- **Lint**: `eslint.config.*` or `.eslintrc.*` → `pnpm exec eslint .` (or `pnpm run lint` if `package.json` has a `lint` script — prefer the script). `.prettierrc.*` / `prettier.config.*` → `pnpm exec prettier --check .`. `biome.json` → `pnpm exec biome check .`. Else, a bare `lint` script in `package.json` → `pnpm run lint`. If none match, omit the lint step entirely (do not scaffold a no-op step).
- **Typecheck**: `tsconfig.json` → `pnpm exec tsc --noEmit`. Else a `typecheck` script in `package.json` → `pnpm run typecheck`. If neither, omit the step.
- **Tests**: `vitest.config.*` or `devDependencies.vitest` → `pnpm exec vitest run`. `jest.config.*` or `devDependencies.jest` → `pnpm exec jest`. Else a `test` script in `package.json` → `pnpm test`. If none match, omit the step (do not fabricate a placeholder test step).

If **none** of lint/typecheck/test resolve to a real step, stop and print: *"No detectable lint/typecheck/test tooling — nothing to scaffold a pipeline around."* Do not write an empty-shell workflow.

### Step 5c — compose the workflow

Read the skeleton at `$CLAUDE_PLUGIN_ROOT/templates/ci-baseline.yml.template`. It provides the name, `on:` triggers, checkout/pnpm/Node setup, and `pnpm install --frozen-lockfile` steps already wired for `node-version-file: .nvmrc` and pnpm via `pnpm/action-setup@v4`. Substitute `__DEFAULT_BRANCH__` with the project's default branch (`git -C <project> remote show origin` or simply `main`/`master` — whichever the repo's `HEAD` resolves to; do not hardcode `main` blindly). Replace the `__INLINE_STEPS__` placeholder with one `- name: ...` / `run: ...` step per tool resolved in Step 5b, in the order lint → typecheck → test. This is inline composition, not pure token substitution — conditional steps can't be expressed by the skeleton alone.

### Step 5d — confirmation gate (never write without it)

- **Interactive**: use `AskUserQuestion` — show the composed workflow content and the detected steps, options *"Write `.github/workflows/atelier-ci.yml`"* / *"Skip"*. On confirm, `Write(<project>/.github/workflows/atelier-ci.yml, <composed content>)`. On skip, print a one-line note and do nothing.
- **Headless (`--yes`/`-y`/`$ATELIER_AUTO`) WITHOUT `--scaffold-ci`**: never write. Print the composed workflow's step summary as a recommendation — *"CI/CD absent; run with `--scaffold-ci` (headless) or interactively to write a baseline GitHub Actions pipeline: <detected steps>."*
- **Headless WITH `--scaffold-ci`**: the flag itself is the confirmation — `Write(<project>/.github/workflows/atelier-ci.yml, <composed content>)` directly, no further prompt.

Note on the `.github/workflows/**` write-deny in `templates/settings.template.json`: that deny list is instantiated into **per-task worktrees** (`<worktree>/.claude/settings.json`, written by `--per-task-settings`) so that agents implementing a *task* never touch CI config autonomously. It does not apply to this slash command's own session — `/setup-project` runs in the operator's main session against the target project's root, not inside a task worktree, so its `Write` (already granted generically in this command's `allowed-tools`) covers the workflow path here without needing a scoped grant.

## Hard refusals

These all live in the bash helper; documented here so the operator knows what to expect when reading the `/setup-project` contract:

- **Never overwrite** `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` / `.claude/CLAUDE.md` / root `CLAUDE.md` if they already exist (the root file is `project-profiler`'s own refusal, but the rule is the same).
- **Never normalize a legacy `IN_PROGRESS.md` inline**. Phase 3 detects and offers `/adopt-roadmap`; the rewrite is that command's job, not `/setup-project`'s.
- **Never weaken** an existing `.npmrc` (no `audit-level` downgrade, no `minimum-release-age` reduction).
- **Never reconfigure under `--yes` / `ATELIER_AUTO`**: re-running on a configured project in non-interactive mode exits with code 2.
- **Never run `git init`** or any git write — `/setup-project` is for atelier scaffolding only.
- **Never draft `CLAUDE.md` content inline from this slash command**, even when the project is "obviously simple". Drafting is `project-profiler`'s job — the agent returns the content; this slash command writes it. The `Write` call from here uses the agent-returned content verbatim; no editorial pass, no embellishment.
- **Never write `CLAUDE.md` without first dispatching `project-profiler`.** If the agent dispatch fails or returns a malformed report (no `## Drafted content` block when status is `drafted`), surface the failure and stop. Do not fabricate content to "rescue" the flow.
- **Never invoke `Edit`, `mkdir`, `sed`, or `jq` directly from this slash command.** Phase 1's file work happens inside the bash helper. Phase 2's only allowed writes are: (a) `Write(<abs>/CLAUDE.md, <agent-returned-content>)` and (b) nothing else.
- **Never dispatch `project-profiler` in `new` mode without an explicit operator answer.** The agent's prompt enforces this defensively but the slash command should refuse to even invoke it (the briefing would carry an empty `operator_answer` field).
- **Never write `.roadmap.json` inline** — delegate the backend write to crt's `/create-roadmap --backend …`. atelier never re-implements the `.roadmap.json` write or any MCP registration that crt owns.
- **Never write a CI/CD workflow headlessly without `--scaffold-ci`.** Plain `--yes` / `-y` / `$ATELIER_AUTO` prints a recommendation only; the flag is the explicit headless opt-in.
- **Never overwrite an existing workflow.** `atelier-ci-status=present` produces no offer and no write, regardless of mode or flags.
- **CI/CD detection is read-only.** `detect_ci_status()` in the bash helper never writes; the only write in Phase 5 is the operator- or flag-confirmed `Write(<project>/.github/workflows/atelier-ci.yml, ...)`.

## Where to look if something breaks

- `atelier-setup-project --help` prints the full CLI contract.
- `which atelier-setup-project` should resolve to `~/.local/bin/atelier-setup-project` (a symlink installed by `install.sh`).
- If `which` is empty: re-run `install.sh`, or check that `~/.local/bin` is on `$PATH`.
- If the helper reports "cannot locate the atelier plugin root", `$CLAUDE_PLUGIN_ROOT` is not set (you are probably running ad-hoc via `claude --plugin-dir`). Run `atelier-setup-project --plugin-root /abs/path/to/atelier-checkout <path>` directly from your terminal, or export `ATELIER_PLUGIN_ROOT` in your shell.
