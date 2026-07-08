# Operator Guide

A walkthrough for getting from zero to your first task. Written for someone who has never used atelier before and may not know what a "branch" or "pull request" is — you don't need to. atelier is built so you can ask Claude to do real software work without learning any of that.

If you already use atelier, skip to the [Reference](#reference) section at the bottom.

---

## What is atelier?

atelier is a plugin for Claude Code that lets you deliver software work — features, bug fixes, tests — by talking to Claude.

You write a short description of what you want done. atelier takes care of all the engineering plumbing under the hood: figuring out the change, writing the code, testing it, sharing it for review, and saving it. You stay in control: atelier never alters your saved-and-shared work without your say-so, and stops to ask whenever the decision needs a human.

The "operator" is you. You don't need to know how the plumbing works to use it.

---

## What you'll need

Before you start, have these ready:

1. **A Mac or Linux computer.** Windows is not supported in v1. (WSL on Windows usually works but is not tested.)
2. **An internet connection.** The install downloads a few hundred MB.
3. **A Claude account.** Any plan that includes Claude Code works — Pro, Max, Team, or Enterprise.
4. **Two GitHub accounts.** Yes, really. See [Why two GitHub accounts](#why-two-github-accounts) below.
5. **About 30 minutes** for the first install.

### Why two GitHub accounts?

atelier has two AI agents that take turns: one writes the code (the "author") and one reviews it (the "reviewer"). When both agents use the same GitHub identity, GitHub treats the review as a comment rather than an approval — and atelier won't auto-merge work that isn't approved. So you need two GitHub accounts so the reviewer can sign off on the author's work as a separate identity.

Creating a second GitHub account is free. A common pattern is to use your main account as the author (the work shows up under your name) and a side account as the reviewer.

---

## Step 1 — Install atelier

Open a terminal and run this one line:

```bash
curl -fsSL https://raw.githubusercontent.com/AkaLab-Tech/atelier/main/bootstrap.sh | bash
```

That's the whole download step — there is nothing to clone or unpack. The line fetches a small bootstrap script that installs Claude Code, registers atelier's plugin catalog, and then hands over to atelier's full installer.

> **Prefer to look before you run?** Download the script first, read it, then run it — it's about 130 lines and this is the only piped-to-shell step atelier ever asks for:
>
> ```bash
> curl -fsSLO https://raw.githubusercontent.com/AkaLab-Tech/atelier/main/bootstrap.sh
> less bootstrap.sh    # inspect it
> bash bootstrap.sh
> ```

> **Developing atelier itself?** Maintainers and contributors still clone the repo (`git clone https://github.com/AkaLab-Tech/atelier`) and run `./install.sh` from the checkout — that clone-based flow remains fully supported. Everyone else doesn't need a copy of the source: updates arrive through `atelier-update` (see [Keep atelier up to date](#keep-atelier-up-to-date)).

---

## Step 2 — Follow the installer prompts

The bootstrap hands over to atelier's phased installer. Here's what will happen, in order:

1. **System tools** — atelier installs anything it needs (Homebrew packages on Mac, apt packages on Linux). You may see lots of output; this is normal.
2. **Claude Code** — installs the Claude Code command-line tool (the bootstrap does this first if it's missing).
3. **Log in to Claude** — your browser opens a tab. Sign in with your Claude account, then come back to the terminal.
4. **Log in to GitHub (first account, the "author")** — browser opens again. Sign in with your **primary** GitHub account.
5. **Log in to GitHub (second account, the "reviewer")** — browser opens again. Sign in with your **second** GitHub account. atelier will complain if it's the same account as step 4.
6. **Plugin install** — atelier configures Claude Code with the atelier plugin, and copies the helper commands into a small versioned folder under `~/.local/share/atelier/` (so they keep working and can be updated atomically).

When it's done, you'll see a section titled `Install complete` followed by `Next steps:`. The terminal will print copy-pasteable commands for the next steps below.

If something fails partway through, atelier remembers where it stopped. You can re-run the one-liner from Step 1 and it will pick up where it left off.

---

## Step 3 — Reload your shell

```bash
source ~/.zshrc
```

(Use `~/.bashrc` if you're on bash.) This loads the new `atelier` and `task` commands into your current terminal. You can also open a brand new terminal — same effect.

To check the install worked:

```bash
atelier-doctor
```

This runs atelier's health check. You should see a list of items each marked `✓`. If you see a `✗` (red X), the line tells you what to fix. Many checks auto-repair if you re-run as `atelier-doctor --fix`.

> Inside a Claude session the same check is `/atelier:doctor` (or `/atelier:doctor --fix`). To see every helper that ships with atelier, run `atelier --help`.

---

## Already a Claude Code user? Bring your conversations over (optional)

atelier keeps its own configuration folder, separate from your personal Claude Code folder (`~/.claude`). That separation is deliberate — atelier's autonomous-mode rules and plugins never disturb your personal setup. One side effect: any conversation history you built up using Claude Code on your own lives in the personal folder, so inside an atelier session `claude --resume` starts out empty, as if you were brand new.

If you'd like to carry that prior history into atelier, you can copy it across:

```bash
atelier-import-conversations
```

This shows you a list of the projects you've had Claude Code conversations in and lets you pick which ones to bring over (or `--all`). The installer also offers to do this once, near the end, if it finds prior conversations.

What gets copied and what doesn't:

- **Copied:** your conversation transcripts only — the back-and-forth of each chat, per project. After importing, `claude --resume` inside an atelier session for that project lists those earlier conversations.
- **Never copied:** your personal `CLAUDE.md`, memory, or settings. Those stay isolated on purpose — mixing them in would let your personal instructions leak into atelier's autonomous work.
- **Non-destructive:** your personal `~/.claude` folder is never moved, changed, or deleted, and an already-imported conversation is never overwritten. Running it twice is safe — it just skips what's already there.

It's a one-time convenience: it copies a snapshot of what you have now. New conversations you start in your personal Claude Code later won't appear in atelier automatically — re-run the command if you want to bring more across. Inside a Claude session the equivalent is `/atelier:import-conversations`; add `--list` to preview or `--dry-run` to see what would be copied without writing anything.

---

## Step 4 — Set up your first project

Pick a software project on your computer that you want atelier to work on. It can be:

- A project you cloned from GitHub.
- A new empty folder.
- An existing project you've been working on.

`cd` into that project's folder, then run:

```bash
atelier /atelier:setup-project .
```

This is a one-time configuration step per project. atelier will:

- Create a `.claude/` folder with project-specific settings.
- Create three files at the project root: `ROADMAP.md` (what work needs doing), `IN_PROGRESS.md` (what's being worked on right now), `HISTORY.md` (what's done).
- Add a few entries to `.gitignore` so atelier's working files don't get saved to your project.
- If the project uses Node.js, add an `.npmrc` file with safety settings for installing packages.
- Check that your **reviewer** account can see the repo. This matters for **private** repos: the reviewer is a second GitHub account (see Step 1), and a brand-new private repo doesn't share access with it automatically — so the reviewer can't approve pull requests and atelier can't auto-merge. If you're the repo's admin, setup will offer to add the reviewer as a read-only collaborator for you (it asks first). If you skip it, grant the reviewer access on GitHub before running your first task, or auto-merge won't work.

**One step is yours: the onboarding pull request.** Part of what setup creates belongs in your repo's version control (`ROADMAP.md`, `IN_PROGRESS.md`, `HISTORY.md`, `.atelier.json` — but *not* `.claude/settings.json`, which stays on your machine). atelier never commits to your main branch directly, so ask the session that ran the setup to commit these files and open a pull request — then **review and merge that PR yourself**. This is the one PR atelier won't merge for you. It matters more than it looks: when atelier picks tasks, it reads your `ROADMAP.md` **from GitHub** (your base branch), not from your computer — until the onboarding PR is merged, atelier sees no roadmap and no task can start.

You can run `atelier /atelier:setup-project .` on as many projects as you like — atelier will remember each one. Run `atelier-list-projects` from any shell to see them all.

If you ever want to retire a project from atelier (no more `task` will run on it), `cd` into the project and run `atelier-remove-project .` — it deregisters the project but keeps your files. Add `--purge` to also strip the few `.gitignore` and `.npmrc` entries atelier added during setup. Both flows have a Claude-session equivalent under `/atelier:remove-project`.

### Already have a roadmap? Adopt it instead of rewriting it

If your project already tracks its work in `ROADMAP.md` — its own priority names, ids like `TASK-12`, maybe another language — atelier won't recognize those tasks: the picker only reads the exact format shown in Step 5. Don't convert it by hand. In the project folder, run:

```bash
atelier
```

and inside the session:

```
/adopt-roadmap --format atelier
```

It shows you the full conversion plan **before touching anything**: every item is kept (nothing is ever dropped), existing ids survive (`TASK-68` becomes `#68`), finished items move to `HISTORY.md`, and anything it can't safely infer is left as an explicit `TODO-type` / `~TODO` placeholder for you to fill in — it never invents a type or an estimate. After it runs: review the changes, fill in the placeholders, and get the result onto your base branch the same way as the onboarding PR above. From there every task follows the normal flow (Step 6 onwards).

Setup sometimes offers this conversion automatically (when it spots legacy content in `IN_PROGRESS.md`), but don't count on it — if your roadmap doesn't look like Step 5's format, run `/adopt-roadmap --format atelier` yourself.

---

## Step 5 — Write your first task

Open the new `ROADMAP.md` file. It looks like this:

```markdown
# Roadmap — your-project-name

Backlog of work for this project. Tasks flow: ROADMAP.md → IN_PROGRESS.md → HISTORY.md.

## 🔥 P0 — Blockers

(Non-negotiable items. Keep this list small — anything here blocks shipping.)

## 🎯 P1 — Next

## 💭 P2 — Backlog
```

Add a task under `## 🎯 P1 — Next`. For your first task, pick something small and self-contained. Examples:

```markdown
## 🎯 P1 — Next

- [ ] `feat` Add a "Contact Us" link to the footer that opens a mailto link `#1` `~1h`
- [ ] `bug` Fix the typo on the homepage where it says "Welcom" instead of "Welcome" `#2` `~30m`
- [ ] `chore` Add a README section explaining how to run the test suite `#3` `~1h`
```

Each line has four parts, and the punctuation matters — atelier parses these:

- `[ ]` — an empty checkbox. atelier marks it `[x]` when the task is done.
- `` `feat` `` — what kind of work this is (`feat`, `bug`, `chore`, `docs`, or `refactor`), **wrapped in backticks**.
- The title — one sentence saying what you want.
- `` `#1` `` — the task's id, also in backticks. Pick the next unused number; never reuse one. This is how you'll refer to the task from now on (and how one task can wait for another: `blocked_by:#1`).
- Optionally `` `~1h` `` — your rough size guess. Leave it off if you have no idea.

Save the file — and remember from Step 4 that atelier reads this file **from GitHub**, so the edit needs to land on your base branch (push it, or include it in a small PR) before atelier can see it.

For the full grammar — every type tag, writing good acceptance criteria, `blocked_by` (same-repo and cross-repo), epics, and a complete worked example — see the [Product Owner Guide](product-owner-guide.md).

---

## Step 6 — Approve a plan for the task

Writing the task down isn't enough — atelier only ever starts work on a task **you have approved a plan for**. This is deliberate: the planning gate is your control over what the autonomous flow is allowed to pick up. In the project folder, run:

```bash
atelier
```

and inside the session:

```
/atelier:plan-task #1
```

atelier studies your project and drafts a short plan: what it understood the task to be, which parts of the code it expects to touch, and how it will check its own work. Read it. If something looks off, say so and it revises. When you're happy and approve, atelier saves the plan as a file (`.plan/1.md`) and marks the task's line `[ready]` in `ROADMAP.md`, in one commit.

Two things to know about this step:

- **Approval is always a human decision.** atelier never approves a plan by itself — not even in unattended mode (it stops after drafting and waits for you to run `/atelier:plan-task` interactively).
- **atelier doesn't push that commit.** Getting it onto your base branch on GitHub is yours to do, the way you normally would (push, or a small PR). Until it lands there, the task isn't visible to the next step. Tasks without `[ready]` are silently skipped — that's the gate working as intended.

### Optional: keep plans local (`planStorage: "local"`)

By default the plan file is committed (that's the `.plan/1.md` commit above). If you'd rather **not** commit plans — for example to keep planning notes out of your history — set `planStorage` to `"local"` in your project's `.atelier.json` and add `.plan/` to `.gitignore`:

```json
{ "planStorage": "local" }
```

In this mode atelier still writes `.plan/<id>.md` and still marks the task `[ready]` (or sets the `Ready` field), but the plan file stays a gitignored, never-committed artifact in your main checkout. `task` / `resume-task` read it from there and pass it straight to the worker — you don't push anything for the plan itself (for the file-backed layout you still land the `[ready]` flip in `ROADMAP.md`).

**One trade-off to accept before you switch:** a local plan **does not appear in the task's pull request.** With committed plans, a reviewer opening the PR can see exactly what was approved; with local plans, that record isn't in the PR. If the "what was approved" audit trail matters for your review process, keep the default (`"committed"`). The default is `"committed"` — you only get local plans if you opt in.

---

## Step 7 — Run the task

From anywhere on your computer, run:

```bash
task
```

atelier will figure out which project you mean based on the folder you're in. (If you're not inside a registered project, atelier shows a picker to choose one.)

A Claude session opens and starts working. You can watch what it does — atelier shows every step on screen. Here's roughly what happens:

1. atelier reads your `ROADMAP.md` **from GitHub** and picks the highest-priority task marked `[ready]` (the one you planned in Step 6). It doesn't matter what branch your own checkout is on or what uncommitted work you have — atelier does everything in its own separate working copy and never touches yours.
2. The author agent reads the plan you approved, then writes the code change.
3. atelier runs your project's tests (if you have any) to make sure nothing broke.
4. The author shares the change on GitHub as a pull request.
5. The reviewer agent (the second GitHub account!) reads the change and gives it a thumbs-up or asks for fixes.
6. If the reviewer approves and nothing is risky, atelier saves the change to your project, and the same pull request moves the task out of `ROADMAP.md` and records it in `HISTORY.md`.

Time per task varies: a typo fix might take 5 minutes; adding a new feature might take an hour or more. You can leave it running and come back.

atelier limits how many tasks run at the same time in a project (it counts its own open `task/...` pull requests; the limit is configurable in `.atelier.json`). If you ask for a task while the limit is reached, it tells you instead of starting a second one.

If atelier gets stuck (e.g. a test keeps failing), it stops and creates an issue on GitHub tagged `blocked` so you know to look at it. It doesn't keep retrying forever.

### Running atelier unattended (headless)

Everything above assumes you're watching the session. You can also run the cycle with no one at the keyboard — from a script, a scheduled job, or just to fire-and-forget:

```bash
ATELIER_AUTO=1 atelier -p "/atelier:next-task"
```

`ATELIER_AUTO=1` is **required** for unattended runs: it tells atelier to take the documented safe default at every decision point instead of asking you. Without it, a headless run stops silently at the first question and never finishes. (The one thing that never happens unattended is plan approval — see Step 6.)

---

## Working with multi-repo projects (workspaces)

Some products are **several repositories that ship together** — for example a `backend`, a `frontend`, and a `strapi` (CMS). atelier calls a group like this a **workspace**.

> **The golden rule stays the same:** every task is still *one* task in *one* repo, producing *one* pull request. A workspace doesn't merge repos or make a single change span several of them — it just lets you **manage the group from one place** and **say "this task waits for that other repo's task"**. A change that needs both backend and frontend is simply two tasks, done in order.

You only need this if your product is made of multiple repos. A single-repo project never needs a workspace — keep using `/atelier:setup-project` and `task` as in Steps 4–7.

### Set it up once

Put the repos under a common parent folder, then from that parent folder run:

```bash
/atelier:setup-workspace my-product --discover .
```

- `--discover .` scans the parent folder for git repos and shows you the list to confirm. Any repo that isn't an atelier project yet gets set up for you (Step 4) before being added — you run one command; the per-repo setup cascades automatically.
- Prefer to be explicit? List them instead: `/atelier:setup-workspace my-product --members ./backend,./frontend,./strapi`.

Two things from Step 4 apply **per member repo**, so expect them once per repo:

- Each newly set-up member gets its own **onboarding pull request** — review and merge each one, or that repo stays invisible to the task picker.
- If a member already has a `.claude/settings.json` from earlier Claude Code use, atelier won't overwrite it silently: it asks you first, and only replaces the file (backing up the old one) with your explicit yes.

Each repo keeps its **own** `ROADMAP.md` and runs tasks exactly as before. The workspace just remembers they belong together. Inside any one repo, nothing changes — `task`, `/status`, etc. all behave as usual.

### Run a task from the product folder

From the **parent folder** (not inside a single repo), run:

```bash
task
```

atelier shows a **picker of the member repos** (with how many open tasks each has) and routes you into the one you choose — from there it's the normal Step 7 flow. Running `task` from *inside* a repo still goes straight to that repo, as always.

### See the whole product at a glance

```bash
/atelier:workspace-status
```

One row per repo — its setup status, what's in progress, how many tasks are open, and how many are waiting on another repo — plus a list of anything currently blocked across repos. (This is the multi-repo cousin of `/status`, which only ever looks at one repo.)

### "Do this only after that other repo is done" (cross-repo dependencies)

In a repo's `ROADMAP.md`, you can make a task wait for a task in a **sibling repo** by writing `blocked_by:<repo>#<id>`. For example, in `frontend/ROADMAP.md`:

```markdown
- [ ] `feat` Use the new orders API `#10` `blocked_by:backend#23`
```

atelier won't start `frontend #10` until `backend #23` has been finished (merged) — it checks the backend repo's `HISTORY.md` to know. When you try to start it too early, atelier tells you exactly what it's waiting for. The moment `backend #23` is done, `frontend #10` becomes available. This is how you do a "change that spans repos": as ordered, single-repo tasks chained with `blocked_by`.

The `<repo>` part (e.g. `backend`) is the short name atelier assigned each member when you set up the workspace — `/atelier:list-workspaces` shows them.

### Managing workspaces

- `/atelier:list-workspaces` — list your workspaces and each repo's health.
- `/atelier:remove-workspace my-product` — un-group the repos. **Your repos and their setup are left untouched** — this only forgets that they were grouped. (Add `--with-members` only if you also want to remove atelier's setup from each repo.)

If a repo gets moved or removed, `/atelier:doctor` will flag the workspace so you can fix it (re-run `/atelier:setup-workspace`, or remove the grouping).

---

## What atelier will and won't do

**Will:**
- Read and write code in the project you set up.
- Run your project's tests.
- Open pull requests on GitHub under the "author" account.
- Approve pull requests from the "reviewer" account.
- Save (merge) approved work to your project's main line.
- Install dependencies after asking — with safety guards against newly-published or suspicious packages.

**Won't:**
- Save changes directly to the main version of your project — everything goes through pull requests.
- Overwrite history or undo work that's already saved.
- Delete files outside the task at hand.
- Install dependencies less than 7 days old (a guard against supply-chain attacks).
- Edit files in `.github/workflows/` (GitHub's automation config — too risky).
- Change `package.json` directly (only through the safe install command).
- Auto-save (auto-merge) work that touches risky areas like `Dockerfile`. Those wait for you.

---

## About permission prompts (auto-mode)

Since v0.8.0, atelier-launched Claude Code sessions run with Claude Code's native **auto permission mode** enabled. This is a classifier built into Claude Code itself that decides safe Bash commands without asking you. Practical effect:

- Bash commands that *used to* prompt — a compound `cd && git fetch && gh pr view 123`, a `for p in foo bar; do …; done` loop, a `gh` subcommand the template didn't enumerate yet — are **judged by the classifier** instead. Most pass through silently.
- The categorical safety list (`git push --force`, `rm -rf /`, modifying `.github/workflows/`, etc.) **still blocks** before the classifier ever sees the command. Auto-mode adds a layer; it does not replace the existing safety net.
- You may still see the occasional permission prompt — for commands the classifier is genuinely unsure about (touching `package.json`, `Dockerfile`, deploy paths, etc.). That's working as designed.

The setting lives in `~/.claude-work/settings.json` (the atelier config dir, not your personal `~/.claude/`). Your non-atelier `claude` sessions are unaffected. `atelier-doctor` verifies the setting is in place; `atelier-doctor --fix` enables it if missing.

Full design rationale + the empirical validation that drove the adoption: [docs/research/permission-layer-3.md](research/permission-layer-3.md).

### Optional: a second opinion on high-risk commands (semantic risk judge)

Auto-mode is good but not perfect — it lets a small fraction of "overeager" actions through. For projects where that residual matters, atelier ships an **opt-in** extra gate: a hook that, for a narrow high-risk surface only — your lockfile, `Dockerfile`/`docker-compose`, `.github/workflows/`, `package.json`, and deploy/infra paths — asks a fast Haiku model whether the command looks like a routine action or something you should confirm first. Risky ones become a normal permission prompt; everything else is untouched.

It's **off by default**. To enable it for a project, set in that project's `.atelier.json`:

```json
"semanticRiskJudge": { "enabled": true }
```

What to expect when it's on:

- Only commands that touch the high-risk surface above pause briefly (a short model call); all other Bash is unaffected — there's a cheap local check first, so most commands never reach the model.
- If the model is unavailable (no network, etc.) the command is simply allowed and a note is written to the task log — the gate never blocks just because it couldn't reach the model.
- It never hard-blocks: at worst it asks you to confirm. The categorical deny list is what blocks forbidden actions.

---

## How atelier makes decisions (decision broker)

Beyond *permission prompts*, atelier sometimes hits **strategic decisions** during a task — situations where multiple legitimate options exist and one must be chosen. Classic examples:

- A pre-existing lint error on `main` (not caused by your task) blocks the gate. Options: pause and fix the baseline first, override the gate, scope the gate narrower, abort.
- The PR is about to be opened but `atelier-pr-size-check` reports it would trip the AND-gate. Options: slice the task, raise the budget, open as-is and accept human review, abort.
- The implementer's diff touches files unrelated to the stated scope. Options: keep the wider change, narrow back to scope, split into two PRs, ask.

None of these is forbidden (the permission matrix doesn't cover them) and none is unsafe (the safety hooks don't cover them either). They are **ambiguous** by construction, and historically atelier asked you about every one.

Since v0.9.0, atelier ships a **decision broker** as the configurable policy layer for this class. The broker:

- Reads a **catalog** of known strategic-decision categories (atelier-managed; you do not edit the catalog).
- Reads your **project policy** in `.atelier.json` under `decisionPolicy`: a global default (`auto` / `ask`) plus per-category overrides.
- Either decides autonomously (via a Haiku / Sonnet / Opus evaluator agent depending on the category's risk level), returns a fixed option you pre-configured, or asks you — depending on the policy.
- **Surfaces every autonomous decision in the PR body** so you and the reviewer can audit and challenge.

### Configuring the policy

The first time you run `/atelier:setup-project` on a project after v0.9.0, an interactive step walks you through each catalog category and asks how atelier should handle it. Pick one per category:

- `[a]uto` — atelier decides per-case using an evaluator agent. Logged in the PR body.
- `[f]ix` — always pick the catalog's recommended default (no LLM cost; cheapest option).
- `[s]ask` — atelier asks you each time (conservative; current pre-broker behaviour).

If you skipped the step with `--skip-policy`, every category falls back to `ask`. To configure later, run `/atelier:set-policy` from inside an atelier session on the project — same prompts, no need to re-run the full setup.

### Per-task overrides (wrapper flags)

Sometimes you want one task to behave differently than the project policy. The `task` shell wrapper accepts flags:

```bash
task --policy=auto                          # this task: every category auto
task --policy=ask                           # this task: every category ask
task --ask-for=oversize-handling,scope-creep-detected  # this task: ask only these
```

Wrapper flags **do not modify `.atelier.json`** — they are env-var overrides that die with the session. The project policy stays unchanged for future tasks.

### Panic switch (mid-session)

If you notice a task going sideways under `auto` and want every remaining decision routed back to you — without aborting the task — run inside the Claude session:

```
/atelier:abort-auto "explaining why if you want to"
```

The broker stops deciding autonomously for THIS worktree until you clear the flag:

```
/atelier:resume-auto
```

Parallel task chains in sibling worktrees are unaffected (the flag is per-worktree).

### Auditing decisions

Every PR atelier opens carries a `## Autonomous decisions taken` section in its body (when the broker fired at least once during the task). The section is a table — one row per decision — with category, choice, confidence, model, and a one-line rationale. Rows are flagged with ⚠️ when the broker's confidence was `low`, when an `auto` decision touched a high-risk category, or when the choice deviated from the catalog's default. Scan the ⚠️ rows before merging; challenge any decision that doesn't match your intent by commenting on the PR or by setting that category to `ask` in `.atelier.json` for future tasks.

### What the broker is NOT

- **Not a permission gate.** That is auto-mode. The broker handles strategic AMBIGUITY, not forbidden actions.
- **Not a safety net.** That is the safety hook suite. `safe-package-change rejected`, `block-env-commit`, etc. bypass to their own escalation.
- **Not operator-extensible.** Categories are atelier-maintained. If atelier hits a strategic decision not in the catalog, it falls back to asking you — and surfaces the missing category as a signal the catalog should grow in a future version.

---

## Keep atelier up to date

atelier ships fixes and new helpers regularly. To get the latest release:

```bash
atelier-update
```

What it does:

1. Runs `claude plugin update atelier@akalab-tech` under atelier's config root, which downloads the latest release into Claude Code's plugin cache.
2. Copies the new version into the managed runtime folder (`~/.local/share/atelier/<version>/`) and switches the `current` pointer to it — every `atelier-*` command updates at once, and the previous version stays on disk as a rollback.
3. Refreshes the templates under `$ATELIER_CONFIG_DIR/templates/` so new projects pick up the latest settings.
4. Reports the version delta and any new commands / agents / skills you now have.

(If you installed from a git clone — the maintainer/developer flow — `atelier-update` instead pulls the clone's `origin/main` first, then performs the same refresh steps from it.)

If you're inside a Claude session, `/atelier:update` does the same thing. After updating, run `atelier-doctor` to confirm everything lines up.

`atelier-doctor` will warn you when there's a version mismatch between the installed plugin and the latest released tag. That warning is your nudge to run `atelier-update`.

---

## Daily housekeeping (worktrees and branches)

When atelier saves (merges) a task, it cleans up after that one task right away. But anything that falls outside that happy path slowly piles up: a worktree from a task you abandoned, a `task/*` branch whose work merged but the branch lingered, a remote branch left behind on GitHub. atelier offers a **once-a-day, you-authorize-it** sweep to keep this tidy.

Once per day, when you start a Claude session, atelier reminds you:

> *Daily housekeeping is due. Run `/atelier:housekeeping` …*

Run it whenever you see that (or anytime you like):

```bash
/atelier:housekeeping
```

It first **shows you a categorized list** of what it *could* remove across all your projects — orphan worktrees, merged/closed local branches, merged/closed remote branches — and **why each one is removable**. Nothing is deleted until you explicitly say yes. You can narrow it to one project with `--project <path>`.

What it **never** touches, no matter what:

- A task that's still **active, blocked, or oversize** in `IN_PROGRESS.md` — that's live evidence.
- A branch or worktree with an **open pull request**.
- A worktree with **unsaved (uncommitted) changes**.
- The protected branches (`main`, `master`, `develop`, `staging`).
- **Unmerged** work with no merged PR — these are listed under "needs review" and left alone unless you opt in with `--include-unmerged`.

Want to look without being asked to delete? Run `atelier-housekeeping --report` from a terminal — it only enumerates.

---

## If something goes wrong

First stop: run the health check.

```bash
atelier-doctor
```

Any `✗` line tells you what's broken and the command to fix it. For the common cases (missing `templates/` symlink, stale shellrc block, marketplace not registered), `atelier-doctor --fix` applies the auto-fixable repairs in one pass — re-run plain `atelier-doctor` afterward to confirm.

If you're still stuck:

- Look in `HISTORY.md` — the most recent entry tells you what was last working.
- Check GitHub for issues with the `blocked` label — atelier creates those when it can't finish.
- Re-run the installer: the one-liner from [Step 1](#step-1--install-atelier). It's safe to re-run; it picks up where it left off. (Clone-based installs: `cd <your-clone> && ./install.sh`.)

For symptom-indexed common problems (`task: command not found`, a hook blocked an edit, auto-merge skipped a PR, reviewer's approval shows as a comment, etc.) see [troubleshooting.md](troubleshooting.md).

---

## Uninstall

If you decide atelier isn't for you:

```bash
atelier-uninstall
```

This removes the atelier plugin, the helper commands (including the managed runtime folder under `~/.local/share/atelier/`), and the shell shortcuts but **keeps your chat history**.

To also wipe atelier's saved settings (browser logins, configuration):

```bash
atelier-uninstall --purge
```

Your project files and `.claude/` folders are not touched. You're free to re-install later.

---

## Reference

Quick lookup once you've used atelier a few times.

| Command | What it does |
|---|---|
| `task` | Run the next task from the current project's `ROADMAP.md` |
| `atelier` | Open a Claude session under atelier's configuration |
| `atelier --help` | List every `atelier-*` helper installed on your machine |
| `atelier /atelier:setup-project .` | Set up the current folder as an atelier project |
| `/adopt-roadmap --format atelier` | Convert a project's pre-existing roadmap into the format atelier reads (keeps every item; from the `claude-roadmap-tools` plugin) |
| `/atelier:plan-task <id>` | Draft + approve the plan for one task, marking it `[ready]` so `task` can claim it |
| `atelier-list-projects` | List every project registered with atelier (`--json` for machine-readable) |
| `atelier-remove-project <path>` | Deregister a project (`--purge` also strips atelier's `.gitignore` / `.npmrc` additions) |
| `/atelier:setup-workspace <name> --discover .` | Group the repos under the current folder into a multi-repo workspace (or `--members a,b,c`) |
| `/atelier:workspace-status` | Aggregated status across a workspace's repos (run from the parent folder) |
| `atelier-list-workspaces` | List your workspaces and each repo's health |
| `/atelier:remove-workspace <name>` | Un-group a workspace (repos stay set up; `--with-members` also removes their setup) |
| `atelier-import-conversations` | Copy your prior Claude Code conversation transcripts from `~/.claude` into atelier (`--list` to preview, `--all` for every project, `--dry-run` to rehearse) |
| `/atelier:housekeeping` | Review and clean up orphan worktrees + merged/closed task branches (local + remote) across your projects — always asks first (`--project <path>` to narrow; `atelier-housekeeping --report` to only enumerate) |
| `atelier-doctor` | Run a health check |
| `atelier-doctor --fix` | Apply the auto-fixable repairs (missing symlinks, stale shellrc block, marketplace not registered) |
| `atelier-update` | Pull latest atelier release, refresh templates, update the Claude plugin |
| `atelier-measure-merge-rate` | Measure the % of recent PRs that merged autonomously (see [methodology](measurements/autonomous-merge-rate.md)) |
| `atelier-uninstall` | Remove atelier (preserves history) |
| `atelier-uninstall --purge` | Remove atelier and wipe all settings |

Each `atelier-*` helper also has a Claude-session equivalent under `/atelier:*` (`/atelier:update`, `/atelier:list-projects`, `/atelier:remove-project`, `/atelier:doctor`, etc.). Use whichever fits the moment — both go through the same scripts.

**Files atelier creates in each project**:

- `ROADMAP.md` — work waiting to be done.
- `IN_PROGRESS.md` — work being done right now.
- `HISTORY.md` — work that's done, with links to the saved changes.
- `.claude/settings.json` — per-project permissions (auto-regenerated each task).
- `.npmrc` (Node.js projects only) — safety settings for installing packages.

**Files atelier stores outside your projects**:

- `~/.claude-work/` — atelier's own configuration, separate from your personal Claude config. (This path is `$ATELIER_CONFIG_DIR`; helpers and slash commands always read/write here, never your personal `~/.claude/`.)
- `~/.claude-work/projects.json` — the registry of your atelier projects. `~/.claude-work/workspaces.json` — your multi-repo workspaces (only present once you create one).
- `~/.claude-work/atelier-help.txt` — the cheatsheet shown by `atelier --help` (written at install time, refreshed by `atelier-update`).
- `~/.local/bin/atelier-*` — the `atelier-setup-project`, `atelier-uninstall`, `atelier-doctor`, `atelier-task-resolve`, `atelier-list-projects`, `atelier-remove-project`, `atelier-import-conversations`, `atelier-setup-workspace`, `atelier-resolve-dep`, `atelier-workspace-status`, `atelier-list-workspaces`, `atelier-remove-workspace`, `atelier-update`, `atelier-permission-diff`, `atelier-pr-size-check`, `atelier-measure-merge-rate`, and `atelier-housekeeping` commands.
