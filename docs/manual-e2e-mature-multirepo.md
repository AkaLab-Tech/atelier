# Manual E2E Test — A Non-Technical Operator Joins a Mature Multi-Repo Project

**Who this test plays.** A **non-technical operator** — think a product owner or project lead, **not a developer** — who is **joining a project that already exists**: a codebase a development team has been building for a while, spread across several repositories. This person didn't write the code and can't read most of it. They don't branch, merge, or run git by hand. Their job is to **direct the work by talking to atelier**. The only tools they touch directly are: one installer, a few one-word commands (`task`, `atelier`, `atelier-doctor`), some copy-paste lines to fetch the code, and the GitHub website's **Merge** button.

**What it proves.** That a newcomer like this can go from **nothing installed and no code on their machine** to **atelier shipping a real change** in a mature, actively-developed, **multi-repo** project — installing atelier, getting the code, configuring everything, and running the agents — without needing to understand git, branches, or the terminal beyond copy-paste.

**How to run it.** Follow it top to bottom, doing exactly what a non-technical newcomer would do (no shortcuts a developer would take). Each step says: **what you do**, **what you say to atelier**, **what you should see**, and **how you know it worked**. When reality differs from "what you should see", write it down in the findings log — that's the deliverable.

> There are **no prerequisites to arrange in advance**. Everything — installing atelier, the second GitHub account, even getting the project's code onto your machine — happens *inside* the steps below. That is the point: this is the complete journey from zero.

---

## The project in this test

The project you're joining is **three repositories that ship together** — a backend, a web app, and a CMS — that the team has been developing for years. In this plan they're called:

- **acme-api** — the backend.
- **acme-web** — the web app.
- **acme-cms** — the content manager.

Wherever you see `acme`, substitute the real project's name and repositories. The flow is identical.

Because the project is **mature, not new**, three things will be true that a brand-new project never has — and this test deliberately checks atelier handles each one gracefully, so you don't have to:

- One repo (**acme-api**) already has Claude Code settings from a developer's earlier experiments.
- One repo (**acme-web**) already has a to-do list (`ROADMAP.md`) written in the team's own style, not atelier's.
- One repo (**acme-cms**) has no to-do list at all yet.

You don't need to know which is which or do anything about it up front — atelier detects and walks you through each case.

**About access.** You'll need enough permission on the repos to approve changes (the **Merge** button). Granting the review account access (Stage 4) needs admin rights; if you're not an admin, the step tells you what to ask the project's administrator for. If you have neither, line that up before Stage 4 — it's the one thing a true newcomer might not start with.

---

## Stage 1 — Install atelier

### Step 1.1 — Get atelier and run the installer

**What you do.** Open the Terminal app, then copy-paste this one line (it downloads and starts the installer — there's nothing to clone):

```bash
curl -fsSL https://raw.githubusercontent.com/AkaLab-Tech/atelier/main/bootstrap.sh | bash
```

**What you should see.** The installer runs in clearly labelled phases and tells you what it's doing at each one:

- **Installing tools** — it sets up the building blocks atelier needs (a package manager, Node, the GitHub tool, Claude Code). Anything already on your machine is skipped. You don't choose anything here.
- **Signing you in** — three sign-ins, in order:
  1. **Claude** — a browser window opens; log in. The installer confirms it can actually reach Claude, not just that you clicked "allow".
  2. **GitHub — your main account** — log in with your own GitHub account (the one that will be a member of the project).
  3. **GitHub — a second, separate account** — atelier uses a *different* GitHub account to **review** its own work, so approvals are independent. **If you don't have a second account, create one now (it's free) and log in with it.** The installer checks the two accounts are genuinely different and won't let you use the same one twice.
- **Optional extras** — it may offer Chrome (for screenshots) and a few integrations (Coolify/Vercel/Neon). For this test, **say no** to the integrations unless the project already uses them.

It finishes with a short "what's next" message.

**How you know it worked.** The installer ends without errors and tells you to reload your terminal (next step).

> **Watch for:** the installer asking you to sign in to GitHub and you accidentally using your *main* account both times — it should stop you and ask for a different one. Note it if it doesn't.

### Step 1.2 — Reload the terminal

**What you do.** Close the Terminal window and open a fresh one. (This makes the new `task` and `atelier` commands available.)

Then type:

```bash
atelier --help
```

**What you should see.** A short cheat-sheet listing the atelier commands. If instead you see "command not found", the reload didn't take — close and reopen Terminal once more.

**How you know it worked.** `atelier --help` prints the cheat-sheet.

---

## Stage 2 — Check the install is healthy

### Step 2.1 — Run the doctor

**What you do.**

```bash
atelier-doctor
```

**What you should see.** A checklist where every line starts with a green check (✓): atelier's configuration is in place, **both** GitHub accounts are signed in and confirmed different, Claude is reachable, and the atelier plugin is installed.

**How you know it worked.** Every line is ✓. If any line shows a ⚠ or ✗, run `atelier-doctor --fix`, then `atelier-doctor` again — it repairs the common issues itself.

> Don't continue past a red doctor. If `--fix` doesn't clear it, that's a finding for the log.

---

## Stage 3 — Get the project's code onto your machine

As a newcomer you don't have the project yet. Put all three repos **together inside one folder**, so atelier can find them as one product.

### Step 3.1 — Create a home for the project and clone the repos

**What you do.** Copy-paste these lines, replacing the org name and repo names with the real ones (ask a teammate for the exact GitHub links if you're unsure):

```bash
mkdir -p ~/Work/acme && cd ~/Work/acme
git clone https://github.com/acme-org/acme-api.git
git clone https://github.com/acme-org/acme-web.git
git clone https://github.com/acme-org/acme-cms.git
```

If a repo is private, your browser or GitHub may ask you to confirm it's you — use your **main** GitHub account.

**What you should see.** Three folders appear inside `~/Work/acme`: `acme-api`, `acme-web`, `acme-cms`.

**How you know it worked.**

```bash
ls ~/Work/acme
```

lists exactly your three repos.

> **A note on connection types (only if a clone fails with a key/SSH error):** always use the `https://github.com/...` links shown above, not `git@github.com:...` ones. atelier only works over HTTPS. If a teammate gave you an SSH link, swap it for the HTTPS one from the repo's GitHub page.

---

## Stage 4 — Connect the whole project (one command)

This is the big one — and it's a **single command**. atelier finds your three repos, sets each one up, and groups them together as one "workspace". You do **not** set them up one by one; atelier does the whole cascade and pauses to ask you whenever a decision is yours.

### Step 4.1 — Start the setup

**What you do.** Open an atelier session:

```bash
atelier
```

**What you say to atelier.** Type this and press enter:

```
/atelier:setup-workspace acme --discover ~/Work/acme
```

(Replace `acme` and `~/Work/acme` with the project's name and the folder that holds the three repos.)

**What you should see, and the questions atelier asks you:**

1. **"Here are the repositories I found — confirm the list."** atelier shows the repos it discovered inside your folder and asks you to confirm or uncheck any. You should see exactly your three repos.

2. **"acme-api already has Claude settings — replace them?"** Because acme-api has old settings from a developer, atelier won't overwrite them silently. It explains that its safety rules can't take effect until the settings are replaced, and asks permission. **If you're unsure, you can ask atelier:**

   ```
   What exactly will change if I let you replace acme-api's old settings,
   and is the old version saved somewhere?
   ```

   atelier should explain it backs up the old file with a timestamp before replacing it. Say yes.

3. **"Give the reviewer account access to the private repos?"** The second GitHub account can't see private repos yet. If you have admin rights, atelier can grant it read access for you — say yes. **If you're not an admin**, atelier will tell you; ask the project's administrator to either add the second account as a read-only collaborator on each repo, or make you an admin so atelier can.

**How you know it worked.** atelier ends with a summary: the workspace `acme`, the folder it lives in, and your three repos each with a short nickname (its "token"). You can double-check any time by asking, in an atelier session:

```
/atelier:list-workspaces
```

You should see `acme` with all three repos marked **configured** (not "partial").

> **Watch for:** a repo marked **partial** (setup didn't finish for it) — tell atelier "finish setting up acme-cms" (or whichever).

### Step 4.2 — Approve atelier's setup changes (GitHub Merge button)

atelier prepared some setup files for each repo, but — by design — it never saves changes to the project without your say-so. It opens a **pull request** (GitHub's "please approve this change" page) for each repo. This is the one kind of change atelier will **not** approve on its own: **you** approve it.

**What you say to atelier** (still in the session):

```
Open a pull request for each repo with its atelier setup files.
```

**What you do.** atelier gives you three links. Open each one in your browser, read the short summary (it's just configuration files), and click **Merge** (then confirm). That's it — no terminal.

**What you should see.** Three pull requests, each small, each merged.

**How you know it worked, and why it matters.** Until you merge these, atelier sees an *empty* project — it reads the to-do lists from the approved (merged) version on GitHub, not from your computer. After merging, the project is officially connected.

---

## Stage 5 — Put the to-do lists in atelier's format

atelier picks tasks from each repo's `ROADMAP.md`, but only understands its own simple format. Your three repos are each in a different starting state — handle all three. You never edit files by hand; you ask atelier.

### Step 5.1 — acme-web: convert the existing to-do list

acme-web already has a to-do list in the team's own style. atelier can keep every item but needs to restyle it.

**What you do.** Open an atelier session *in that repo's folder*:

```bash
cd ~/Work/acme/acme-web
atelier
```

**What you say to atelier.**

```
/adopt-roadmap --format atelier
```

then, before approving:

```
Show me the full plan first. Confirm you're not dropping any task, and tell me
which items you couldn't fully fill in so I can complete them.
```

**What you should see.** atelier shows a complete before/after plan **without changing anything yet**: every existing task is kept, the team's existing task numbers are preserved, finished items are moved to a "history" list, and anything it couldn't infer (like a task's type or size estimate) is clearly marked as "TODO" for you to fill. Approve only when you're happy.

**How you know it worked.** atelier confirms the to-do list is now in its format and gives you a short list of "TODO" spots to fill in.

> **Watch for (known issue):** atelier did **not** offer this conversion automatically back in Stage 4. That's a known gap (its auto-detection looks at the wrong file when the "in progress" list is empty). Running `/adopt-roadmap --format atelier` yourself, as here, is the correct workaround — note in the log if you'd have expected the offer.

### Step 5.2 — acme-cms: create a to-do list from scratch

acme-cms has no to-do list. Just describe a couple of small real tasks and let atelier write them in the right format. (As a non-technical operator, you decide *what* needs doing; atelier handles *how* it's written.)

**What you do.**

```bash
cd ~/Work/acme/acme-cms
atelier
```

**What you say to atelier.**

```
This repo has no atelier to-do list yet. Create one and add these two small tasks
in your format: (1) a chore to add a CONTRIBUTING file with local setup steps,
and (2) a bug fix for the broken favicon in the admin panel. Then show me the result.
```

**What you should see.** atelier creates the to-do list with your two tasks, each with a number, a type (chore/bug), and a placeholder size estimate.

**How you know it worked.** The new to-do list exists with your two tasks in atelier's format.

### Step 5.3 — Finish and save the lists

**What you say to atelier** (in each repo where you adopted or created a list):

```
Fill in the TODO spots with sensible values, then save these to-do list changes
the same way as the setup — open a pull request I can approve.
```

**What you do.** Approve (Merge) each pull request in your browser, just like Stage 4.2.

**How you know it worked.** All three repos now have an atelier-format to-do list approved on GitHub.

---

## Stage 6 — Approve a plan for one task

atelier only starts work on a task **after you've approved a plan for it**. This is your safety switch: nothing runs that you haven't okayed. Pick one small task to drive all the way through — say the acme-cms favicon bug.

**What you do.**

```bash
cd ~/Work/acme/acme-cms
atelier
```

**What you say to atelier.**

```
/atelier:plan-task #2
```

then:

```
Explain the plan in plain language: what will you change, and how will you check
it actually fixed the favicon?
```

**What you should see.** atelier writes a short plan — what it understood, what it'll change, how it'll verify — and **waits for your approval**. It will not start the work, and it will **never** approve its own plan (not even when running unattended). When you approve, it records the plan and marks the task as **ready**.

**What you say next.**

```
Save the approved plan so the task is ready to run.
```

(atelier will get the plan onto GitHub the same approve-in-browser way.)

**How you know it worked.** The favicon task is now marked **ready**. Tasks that aren't "ready" are skipped on purpose — that's the safety switch doing its job.

---

## Stage 7 — Let atelier do the work

### Step 7.1 — Start a task from the project folder

**What you do.** Go to the **project folder** (the one holding all three repos) and run the one-word command:

```bash
cd ~/Work/acme
task
```

**What you should see.** Because you're in the multi-repo project folder, atelier shows a **menu of your three repos** with how many open tasks each has. Choose acme-cms.

**How you know it worked.** atelier picks up the favicon task and starts working — without you choosing branches or typing git anything.

> If you run `task` from *inside* a single repo, atelier skips the menu and goes straight to that repo.

### Step 7.2 — Watch the cycle (and ask questions)

atelier now does the whole job on its own. While it runs, you can ask:

```
Which task are you doing, and which repo?
Show me the pull request and the test results before you finalize it.
```

**What you should see, in order.** atelier: reads the to-do list from GitHub and picks the **ready** favicon task; works in its own private copy (**it never touches the code you have open**); makes the change; runs the project's checks; opens a pull request with a written summary; has the **reviewer** account (your second GitHub account) review it; and, if the review passes and nothing looks risky, **approves and saves it automatically**. Afterwards it cleans up and records the finished task in the repo's history.

**How you know it worked.** The favicon task ends up in acme-cms's "history", the change is merged on GitHub, and you did **zero** git work.

> **Watch for:** atelier asking *you* to approve the final merge of a normal small task (it should auto-approve once the reviewer is happy); the reviewer step failing because the second account never got access (Stage 4.1); any written output (the summary, code comments) coming out in a language other than English when the project's content is in another language. Note any of these in the log.

### Step 7.3 — (Optional) Let it run unattended

**What you do.** To let atelier pick up the next ready task with nobody watching:

```bash
cd ~/Work/acme/acme-cms
ATELIER_AUTO=1 atelier -p "/atelier:next-task"
```

**What you should see.** The same cycle, but it answers its own routine questions with the safe default and never pauses — **except** it still won't approve a *plan* by itself (that's why Stage 6 is always a hands-on step). `ATELIER_AUTO=1` is the part that tells it "go unattended"; without it, an unwatched run just waits forever at the first question.

---

## Stage 8 — See the whole project at a glance

**What you do.**

```bash
cd ~/Work/acme
atelier
```

**What you say to atelier.**

```
/atelier:workspace-status
```

**What you should see.** One tidy row per repo — its setup state, what's in progress, how many tasks are open, and how many are waiting on another repo — even if some task titles are long or use accents.

**How you know it worked.** All three repos appear, neatly lined up.

> **Optional — "do this after that":** you can make a task in one repo wait for a task in another. Ask atelier: `In acme-web, add a task to use the new orders endpoint, but make it wait until acme-api task #42 is done.` atelier won't start it until acme-api #42 is finished, and will tell you exactly what it's waiting for. (It's still one change per repo — atelier never spans repos in a single change.)

---

## Stage 9 — Spot-check the safety boundaries (optional)

These confirm atelier stops where it should. For each, note what you triggered and whether the boundary held.

- **Stuck task:** ask atelier to do something whose checks can't pass. It should give up after a fixed number of tries, then open a clearly-labelled "blocked" issue on GitHub instead of trying forever.
- **Risky change:** a change that touches sensitive plumbing (dependency lists, build/deploy config) or that's very large should **not** auto-approve — atelier should hand it to you to merge.
- **Secrets:** if a change would include a secrets file (a `.env`), atelier should refuse to save it.

---

## Stage 10 — Write down what you found

This log is the deliverable. For each thing that didn't match "what you should see":

1. **Which step** it happened in.
2. **What you did or said** to atelier.
3. **What you expected vs. what actually happened** — copy the relevant message atelier showed you.
4. **Where things ended up** — e.g. "the favicon task never moved to history", or a screenshot.

**Already known — just confirm whether still true, don't re-report as new:**

- atelier doesn't offer the to-do list conversion automatically when the "in progress" list is empty (Step 5.1).
- atelier expects HTTPS repo links, not SSH, and doesn't convert them for you (end of Stage 3).
- The setup and to-do list changes need you to click **Merge** yourself (Steps 4.2 and 5.3) — atelier never auto-approves those.

---

## You're done when

- [ ] `atelier-doctor` is all green after install (Stage 2).
- [ ] All three repos are cloned together under one folder (Stage 3).
- [ ] The project `acme` is connected, with all three repos shown as **configured** (Stage 4).
- [ ] You've merged the setup pull requests for all three repos (Step 4.2).
- [ ] All three repos have an atelier-format to-do list approved on GitHub (Stage 5).
- [ ] One task is **ready** and has been **finished end-to-end automatically** — change merged, task in history — with no git work from you (Stages 6–7).
- [ ] `task` from the project folder shows the three-repo menu (Step 7.1).
- [ ] `/atelier:workspace-status` shows all three repos cleanly (Stage 8).
- [ ] Everything that surprised you is written down (Stage 10).
