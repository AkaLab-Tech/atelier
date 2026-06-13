# Manual E2E Test — Onboarding a Mature Multi-Repo Project

**What this exercises.** Installing atelier from scratch on the operator's own machine and onboarding a **real, years-old, actively-developed, multi-repo product** — not a fresh toy repo. The hard parts of this scenario are exactly the ones a greenfield walkthrough never hits: pre-existing `.claude/` settings, a roadmap written in the team's own (non-atelier) format, active feature branches, a non-`main` base branch, and three repos that ship together.

**How to use it.** Run top to bottom. Every step lists: the **command(s)**, any **questions to ask atelier** in the session, the **expected output**, and the **expected end state**. When something diverges, capture it in the findings log (Stage 9) — that is the point of the run.

**This is a manual test plan, not automation.** It assumes a human at the keyboard who can read atelier's prompts and answer them. Headless variants are called out where they exist.

---

## Scenario & conventions

A made-up but representative product, **`acme`**, living under one parent folder, three repos that release together:

```
~/Work/acme/
  acme-api/        # backend  — base branch: dev   — has a hand-grown .claude/settings.json from prior Claude Code use
  acme-web/        # frontend — base branch: dev   — ROADMAP.md in the team's own format (TASK-NN ids, localized headings)
  acme-cms/        # CMS      — base branch: main  — no roadmap at all yet
```

Properties that make this a *mature* project (and that the plan deliberately stresses):

- **Not new**: each repo has years of history and many contributors → atelier's new-vs-existing heuristic must resolve to **existing**.
- **Active branches**: your working checkout may be on a feature branch with uncommitted changes. atelier must never touch it (post-F66).
- **Non-`main` base**: two repos ship from `dev`. atelier must read each repo's *own* base branch.
- **Legacy artifacts**: a pre-atelier `.claude/settings.json` (acme-api) and a non-atelier `ROADMAP.md` (acme-web).
- **Private repos**: the independent reviewer account cannot see them until granted.

Set these once per shell so the commands below are copy-paste:

```bash
export PRODUCT_DIR=~/Work/acme
export REPO_A="$PRODUCT_DIR/acme-api"      # legacy settings.json
export REPO_B="$PRODUCT_DIR/acme-web"      # legacy ROADMAP.md
export REPO_C="$PRODUCT_DIR/acme-cms"      # no roadmap
export ATELIER_CHECKOUT=/Users/mike/Work/work-setup/dotfiles
```

> Substitute your real product/repo paths. The plan is written against `acme` so it reads as a template; the same flow was validated on the `deminut` product during M7.1.

**Prerequisites (have these ready before Stage 0):**

- **Two GitHub accounts**: a primary *author* account (admin on all three repos) and a separate *reviewer* account. atelier uses the second one so PR approvals are independent.
- All three repos already cloned under `$PRODUCT_DIR`, **one level deep** (worktree dirs like `*-worktrees/` are fine — discovery skips them).
- macOS or apt-based Linux, with a terminal you can leave running for a couple of hours.

---

## Stage 0 — Pre-flight snapshot

Capture the starting state so findings have a baseline and rollback is clean.

### TC-0.1 — Snapshot shell + atelier footprint

**Command**

```bash
cp ~/.zshrc ~/.zshrc.pre-atelier && echo "  ✓ shellrc backed up"
echo "=== existing atelier footprint ==="
ls ~/.local/bin/atelier-* 2>/dev/null || echo "  ✓ no atelier binaries on PATH"
ls -d ~/.claude-work 2>/dev/null && echo "  ⚠ ~/.claude-work exists" || echo "  ✓ no ~/.claude-work"
grep -q ">>> atelier hooks" ~/.zshrc && echo "  ⚠ shellrc already has atelier block" || echo "  ✓ shellrc clean"
```

**Expected output**: mostly `✓`. Any `⚠` is fine (install is idempotent) but note it.

**Expected end state**: a `~/.zshrc.pre-atelier` backup exists; you know whether this is a first install or a re-install.

### TC-0.2 — Confirm the multi-repo shape atelier will see

**Command**

```bash
ls -d "$PRODUCT_DIR"/*/ 2>/dev/null
for r in "$REPO_A" "$REPO_B" "$REPO_C"; do
  echo "=== $(basename "$r") ==="
  git -C "$r" remote get-url origin
  echo "  base candidates: $(git -C "$r" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@.*/@@')"
  git -C "$r" status -sb | head -1
done
```

**Expected output**: each `origin` is an **HTTPS** URL (`https://github.com/...`). The base branch prints (`dev` for A/B, `main` for C). Working-tree state can be anything.

**Expected end state**: you have confirmed (a) all remotes are HTTPS — atelier is HTTPS-only and will not work over SSH — and (b) each repo's base branch.

> **Known friction (capture if hit):** if any remote is `git@github.com:...`, atelier will fail later. Convert now: `git -C <repo> remote set-url origin https://github.com/<org>/<repo>.git`. atelier does **not** yet auto-detect/convert SSH remotes — note it as a finding.

---

## Stage 1 — Install atelier

### TC-1.1 — Read the installer's contract

**Command**

```bash
cd "$ATELIER_CHECKOUT"
./install.sh --help
```

**Expected output**: usage text listing `--config-dir <path>`, `--yes/-y`, `--help`. Default config root is `~/.claude-work/`.

**Expected end state**: you know the config dir you'll use. **Recommended: the default `~/.claude-work/`** — it isolates atelier from your personal `~/.claude*` config so uninstall is clean.

### TC-1.2 — Run the installer (interactive, first time)

**Command**

```bash
cd "$ATELIER_CHECKOUT"
./install.sh
```

**What happens, by phase:**

- **Phase A — system deps.** Installs/verifies `pnpm`, `fnm`, `gh`, Node, Claude Code; optional Chrome (for Playwright) and Docker Compose v2. Already-present tools are skipped.
- **Phase B — logins (the two-account part).** Three logins, in order:
  1. **Claude** — finishes with a real API ping, not just "logged in".
  2. **GitHub author** — your primary account.
  3. **GitHub reviewer** — your *second* account. The installer verifies the two identities are **distinct** and refuses if you logged in with the same account twice.
  Then it captures your git identity (name/email) for commits.
- **Phase C.1 — host wiring.** Writes the shellrc hook block (`task`, `atelier`, `task-status`), installs the external `git-wt`, adds `.env*` to git's global excludes, installs the atelier plugin from the AkaLab-Tech marketplace, and writes the `atelier --help` cheatsheet.

**Questions atelier will ask you** (interactive): which accounts to log in as (it opens browser device-login flows); whether to install the optional Chrome / Docker Compose pieces; optional integrations (Coolify/Vercel/Neon) — **decline these for this run** unless your product uses them.

**Expected output**: each phase prints `✓` lines; ends with a "next steps" block telling you to reload the shell.

**Expected end state**: atelier installed under `~/.claude-work/`; two distinct GitHub identities authenticated; shellrc hook block present.

> **Watch for (capture):** the installer prompting for the *same* GitHub account twice in a loop (you must log the reviewer into a different account); any phase exiting non-zero.

### TC-1.3 — Reload shell + verify the wrappers exist

**Command**

```bash
source ~/.zshrc
type task; type atelier; type task-status
atelier --help | head -5
echo "ATELIER_CONFIG_DIR=$ATELIER_CONFIG_DIR"
```

**Expected output**: `task`, `atelier`, `task-status` are all shell functions/aliases; `atelier --help` prints the cheatsheet; `ATELIER_CONFIG_DIR` points at `~/.claude-work`.

**Expected end state**: the three entry points resolve in a fresh shell.

### TC-1.4 — Verify the config root + helper surface

**Command**

```bash
ls "$ATELIER_CONFIG_DIR"/{settings.json,templates,gh} 2>&1
ls "$ATELIER_CONFIG_DIR"/gh/author "$ATELIER_CONFIG_DIR"/gh/reviewer 2>&1
ls ~/.local/bin/atelier-* | sed 's@.*/@@'
```

**Expected output**: a session `settings.json` (with `defaultMode` = `auto`), a `templates/` dir, and **two** gh config dirs (`author`, `reviewer`). A dozen-plus `atelier-*` helpers on `PATH`.

**Expected end state**: the isolated config root is fully populated; author/reviewer identities are separated on disk.

---

## Stage 2 — Doctor (verify the integrated install)

### TC-2.1 — Run the health check

**Command**

```bash
atelier-doctor
```

**Expected output**: a checklist, each line `✓`/`⚠`/`✗`. On a clean install every line is `✓`: config dir present, both gh identities authenticated and distinct, Claude reachable, plugin installed at the expected version, marketplace registered, shellrc block current.

**Expected end state**: doctor is all-green (or you have an explicit list of what isn't).

### TC-2.2 — Apply auto-fixes if needed

**Command (only if TC-2.1 showed fixable `⚠`/`✗`)**

```bash
atelier-doctor --fix
atelier-doctor   # re-run to confirm
```

**Expected output**: `--fix` repairs the auto-fixable items (missing symlinks, stale shellrc block, unregistered marketplace) and the re-run is green.

**Expected end state**: doctor green before touching any project.

---

## Stage 3 — Configure the multi-repo workspace

This is the **one command** that onboards the whole product. atelier discovers the member repos, configures any that aren't atelier projects yet (cascading into per-repo setup), and registers the workspace. Do **not** set up each repo by hand first — let the workspace command drive it.

### TC-3.1 — Dry-run the discovery (read-only)

**Command**

```bash
atelier-setup-workspace --list-discoverable "$PRODUCT_DIR"
```

**Expected output**: one line per git repo found one level under `$PRODUCT_DIR`, each tagged `unregistered` (none are atelier projects yet). `*-worktrees/` dirs are skipped.

**Expected end state**: you've confirmed atelier sees exactly the three repos you expect — no more, no fewer.

### TC-3.2 — Run setup-workspace

**Command**

```bash
atelier   # opens a Claude session under atelier's config
```

**Question to ask atelier (in the session):**

```
/atelier:setup-workspace acme --discover ~/Work/acme
```

**What atelier does** (and where it pauses for you):

1. Lists the discovered repos and asks you to **confirm/prune** the set (interactive multi-select).
2. For each repo that isn't a registered project, it runs `/atelier:setup-project` on it — creating `.claude/settings.json`, `.atelier.json`, the three tracking files (only if missing), `.gitignore` entries, and `.npmrc` for Node repos.
3. Registers the workspace `acme` with one short **token** per member (default: the repo's folder name).

**Two pauses you should expect on a mature project:**

- **acme-api has a legacy `.claude/settings.json`.** atelier will **not** overwrite it silently — it warns and preserves it. atelier's permission model then never reaches disk, so the autonomous flow would stall. **Ask atelier:**

  ```
  acme-api already has a settings.json from before atelier. Replace it with the
  atelier template (back up the old one) so the flow works?
  ```

  On your confirmation it re-runs that member's setup with `--override` (the old file is backed up with a timestamp). Never approve `--override` without understanding it overwrites your file.

- **Reviewer access on private repos.** The reviewer account can't see private repos yet. If you are admin (you are), atelier can grant read access headlessly via the `--grant-reviewer` path (invite from author, accept as reviewer). Approve it, or grant access on GitHub manually before the first task.

**Expected output**: ends with a success block — workspace name `acme`, root `~/Work/acme`, and the member→token map (`acme-api`, `acme-web`, `acme-cms`).

**Expected end state**: `workspaces.json` has `acme` with three members + tokens; each repo now has `.claude/settings.json` + `.atelier.json` on disk.

### TC-3.3 — Verify registration

**Command**

```bash
atelier-list-workspaces
atelier-list-workspaces --json | jq '.workspaces.acme.members[] | {token, status}'
```

**Expected output**: `acme` listed with three members. Each member `status` is `configured` (both `.claude/settings.json` and `.atelier.json` present). `setupVersion` is a real version string, **not** `"unknown"`.

**Expected end state**: workspace fully registered, every member `configured`.

> **Watch for (capture):** a member showing `partial` (only one of the two files present) → that repo's setup didn't finish; re-run `/atelier:setup-project` on it. `setupVersion: "unknown"` would be a regression of F71.

### TC-3.4 — Merge the per-member onboarding PRs (operator step)

Setup's version-controlled artifacts (`.atelier.json`, the tracking files, `.gitignore`/`.npmrc` edits — but **not** `.claude/settings.json`, which is gitignored) must land on each repo's **base branch**. atelier opens a PR per member but **does not merge it** — this is the one PR class atelier never auto-merges.

**Question to ask atelier (in the session):**

```
Commit each repo's atelier setup files on a branch and open a PR against that
repo's base branch (dev for acme-api/acme-web, main for acme-cms).
```

**Command (review + merge each, as the author identity):**

```bash
export GH_CONFIG_DIR="$ATELIER_CONFIG_DIR/gh/author"
gh pr list --repo <org>/acme-api --state open
gh pr view <N> --repo <org>/acme-api --web    # review, then merge (squash)
# repeat for acme-web, acme-cms
```

**Expected output**: three onboarding PRs, each small (config + tracking files), each merged into its repo's base branch.

**Expected end state**: every repo's base branch now carries its atelier config. **This matters**: the task picker reads the roadmap from `origin/<base>`, so until these merge, atelier sees nothing.

---

## Stage 4 — Adopt the existing roadmaps

Each repo is in a different roadmap state — handle all three, because the task picker only understands the atelier (PLAN.md §5) format.

### TC-4.1 — acme-web: convert a legacy roadmap

acme-web has a `ROADMAP.md` in the team's own format (`TASK-NN` ids, localized priority headings, nested checklists). atelier can't claim any of it. Convert it — do **not** hand-edit.

**Command**

```bash
cd "$REPO_B"
git switch dev && git pull --ff-only   # adopt edits the current branch in place
atelier
```

**Question to ask atelier (in the session):**

```
/adopt-roadmap --format atelier
```

then, before approving:

```
Show me the full conversion plan first. Which legacy ids are preserved and
which get fresh #NN ids? List every item left as TODO-type or ~TODO.
```

**What atelier does**: shows the conversion plan **before writing anything** (nothing is ever dropped); preserves legacy numeric ids (`TASK-68` → `#68`), assigns fresh sequential `#NN` only to items with no id; maps priority words to `P0`/`P1`/`P2` (`P0` never auto-assigned); inserts explicit `` `TODO-type` `` / `` `~TODO` `` placeholders where it can't safely infer; moves done items to `HISTORY.md`; resets `IN_PROGRESS.md` to an empty slot.

**Expected output**: a reviewable plan, then (on approval) a rewritten `ROADMAP.md` in §5 layout + a normalized `IN_PROGRESS.md`/`HISTORY.md`. A list of `TODO` placeholders to fill.

**Expected end state**: acme-web's roadmap is in the format the picker parses, with every legacy item preserved.

> **Watch for (capture):** atelier did **not** offer adoption during Stage 3 even though the roadmap was non-atelier. That's expected today if `IN_PROGRESS.md` was empty (the detection is anchored on `IN_PROGRESS.md`, not `ROADMAP.md`) — this is finding **F74**. Run `/adopt-roadmap --format atelier` yourself, as above.

### TC-4.2 — acme-cms: create a roadmap from scratch

acme-cms has no roadmap. Write a couple of small real tasks directly in the atelier format.

**Command**

```bash
cd "$REPO_C" && git switch main && git pull --ff-only
```

Edit `ROADMAP.md` to add, under `## 🎯 P1 — Next`:

```markdown
- [ ] `chore` Add a CONTRIBUTING.md with local-dev setup steps `#1` `~1h`
- [ ] `bug` Fix the broken admin-panel favicon path `#2` `~30m`
```

Each line needs: checkbox, backtick **type tag**, title, backtick `` `#id` ``, optional `` `~estimate` ``.

**Expected end state**: acme-cms has a parseable backlog.

### TC-4.3 — Fill placeholders + land all roadmaps on base

**Command (per repo where you adopted/edited):**

Fill in any `` `TODO-type` `` / `` `~estimate` `` placeholders, then get the result onto the base branch (push the change, or a small PR — your call). The picker reads `origin/<base>`, so unmerged roadmap edits are invisible.

**Expected end state**: all three repos have an atelier-format roadmap **on their base branch**.

---

## Stage 5 — Plan a task (the [ready] gate)

The autonomous flow only claims tasks you've approved a plan for. Pick one small task to drive end-to-end — say acme-cms `#2` (the favicon bug).

**Command**

```bash
cd "$REPO_C"
atelier
```

**Question to ask atelier (in the session):**

```
/atelier:plan-task #2
```

then:

```
Walk me through the plan: which files will it touch and how will it verify the fix?
```

**What atelier does**: dispatches the planner, drafts a short plan (understanding, files to touch, how it'll self-check), and waits for your approval. On approval it commits `.plan/2.md` and flips the task line to `[ready]` in `ROADMAP.md`, in one commit. It does **not** push that commit, and it **never** auto-approves (not even headless).

**Command (land the plan on base):**

```bash
git log --oneline -1          # the plan commit
git push                      # or open a small PR — must reach origin/<base>
```

**Expected output**: `.plan/2.md` exists; the `#2` line in `ROADMAP.md` carries `[ready]`.

**Expected end state**: exactly one `[ready]` task on acme-cms's base branch, with its committed plan. Tasks without `[ready]` are silently skipped — that's the gate working.

> **Watch for (capture):** the planner inventing acceptance criteria not in the task; approval being accepted non-interactively (it must not).

---

## Stage 6 — Run the task cycle

### TC-6.1 — Route a task from the product root (multi-repo picker)

**Command**

```bash
cd "$PRODUCT_DIR"   # the parent folder, not a single repo
task
```

**Expected output**: a **picker of the member repos** with each one's open-task count. Choosing acme-cms routes you into it and starts the normal cycle on `#2`.

**Expected end state**: you're in acme-cms's task flow without having `cd`'d into it.

> Running `task` from *inside* a repo skips the picker and goes straight to that repo.

### TC-6.2 — Watch the autonomous cycle

Once routed (or run `task` from inside `$REPO_C`), atelier:

1. Reads `ROADMAP.md` from `origin/<base>` and claims the highest-priority `[ready]` task (`#2`). **Your checkout is never touched** — it works in its own worktree, regardless of your current branch or uncommitted changes.
2. Creates an isolated worktree, moves `#2` `ROADMAP.md → IN_PROGRESS.md` *inside* that worktree.
3. The author agent implements the fix per the approved plan.
4. Runs lint/typecheck/tests (the push gate).
5. Opens a PR with an auto-generated description.
6. The **reviewer** agent (second account) reviews; if it approves and nothing is risky, atelier auto-merges.
7. Post-merge: deletes the remote branch, removes the worktree, and the same PR records `#2` in `HISTORY.md`.

**Questions to ask atelier (while it runs):**

```
Which task did you claim, and from which base branch?
Show me the PR URL and the validation results before you merge.
```

**Expected output**: a `task/2-*` PR that merges autonomously; `#2` ends up in acme-cms's `HISTORY.md`; the worktree is gone afterward.

**Expected end state**: one shipped change, end-to-end, with zero manual git work from you.

> **Watch for (capture):** atelier doing specialist work inline instead of delegating (F52); the cycle complaining about your checkout's branch/dirtiness (should not, post-F66); auto-merge stalling because reviewer access was never granted (Stage 3); deliverables (commit/PR/comments) **not in English** when the repo's content is another language (F73 — `deliverableLanguage` defaults to English).

### TC-6.3 — Headless variant (optional)

**Command**

```bash
cd "$REPO_C"
ATELIER_AUTO=1 atelier -p "/atelier:next-task"
```

**Expected output**: the same cycle with no interactive prompts — every decision takes its documented safe default. (Plan approval is the one thing that never happens headless; that's why Stage 5 is a separate, interactive step.)

**Expected end state**: a task shipped unattended. Without `ATELIER_AUTO=1` a headless run stalls silently at the first question — confirm that failure mode too if you want.

### TC-6.4 — Concurrency limit

**Command**

```bash
# with the #2 PR still open, try to start another task in the same repo
cd "$REPO_C" && task
```

**Expected output**: atelier counts its open `task/*` PRs against `.atelier.json → taskConcurrency.max` and tells you the limit is reached instead of starting a second one.

**Expected end state**: no runaway parallel tasks; the cap is enforced.

---

## Stage 7 — Multi-repo behaviors

### TC-7.1 — Aggregated status

**Command**

```bash
cd "$PRODUCT_DIR"
atelier
```

```
/atelier:workspace-status
```

**Expected output**: one row per repo — setup status, what's in progress, open-task count, and how many tasks wait on another repo — plus any cross-repo blocked items. Rows are aligned even with long/accented in-progress titles (F72).

**Expected end state**: a single view of all three repos.

### TC-7.2 — Cross-repo dependency (optional but recommended)

Add a task in acme-web that waits on an acme-api task, to exercise sequenced cross-repo ordering (never cross-repo atomicity — still one task / one worktree / one PR each).

In `acme-web/ROADMAP.md`:

```markdown
- [ ] `feat` Use the new orders endpoint `#80` `~3h` `blocked_by:acme-api#42`
```

**Command**

```bash
cd "$REPO_B" && task
```

**Expected output**: atelier refuses to start `acme-web#80` until `acme-api#42` is merged (it checks acme-api's `HISTORY.md`), and names exactly what it's waiting for. The token `acme-api` is the one from the workspace registry (`atelier-list-workspaces`).

**Expected end state**: the dependency is enforced offline; the moment `acme-api#42` merges, `#80` becomes claimable.

> **Watch for (capture):** an unknown token or id in `blocked_by:` should be surfaced as a roadmap bug, not silently skipped.

---

## Stage 8 — Failure & recovery spot-checks (optional)

- **Blocked task**: force a task whose tests can't pass; confirm atelier stops after its retry budget (3 → reset worktree → 3) and opens a GitHub issue tagged `blocked` with the `.task-log/*.md` attached — it does **not** retry forever.
- **Non-auto-mergeable PR**: confirm a PR that touches `package.json`/lockfile, a Dockerfile, `.github/workflows/**`, or is oversize (> `.atelier.json` budget) falls back to **human merge** instead of auto-merging.
- **Secret guard**: confirm a commit that touches a `.env` file is blocked by the pre-commit hook.

For each, capture: what you triggered, what atelier did, and whether the boundary held.

---

## Stage 9 — Findings log

Record findings as you go — this is the deliverable of the run.

For each finding:

1. **Stage / TC** where it surfaced.
2. **Command run** + interaction mode (interactive / headless).
3. **Expected vs actual** — paste the last ~20 lines of output.
4. **Resulting state**: `git -C <repo> status -sb`, `atelier-list-workspaces`, open PRs (`task-status`).
5. If a worktree was created: contents of `<worktree>/.task-log/` (attempts + hook decisions).

**Already-known — don't re-file, just confirm whether still present:**

- **F74** — setup doesn't flag a non-§5 `ROADMAP.md` when `IN_PROGRESS.md` is empty (TC-4.1).
- SSH remotes aren't auto-detected/converted (TC-0.2).
- Onboarding PRs have no auto-merge path; the operator merges them (Stage 3.4).

---

## Definition of done

The run passes when:

- [ ] `atelier-doctor` is green after install (Stage 2).
- [ ] The workspace `acme` is registered with all three members `configured` and a real `setupVersion` (Stage 3).
- [ ] All three onboarding PRs are merged to their base branches (Stage 3.4).
- [ ] All three repos have an atelier-format roadmap on their base branch (Stage 4).
- [ ] At least one task is planned to `[ready]` and **shipped end-to-end with auto-merge** (Stages 5–6).
- [ ] `task` from the product root shows the member picker (Stage 6.1).
- [ ] `/atelier:workspace-status` renders all three repos cleanly (Stage 7.1).
- [ ] Findings (new and confirmed-known) are logged (Stage 9).
