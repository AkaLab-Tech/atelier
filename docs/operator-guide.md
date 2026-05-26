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

## Step 1 — Download atelier

Open a terminal and run:

```bash
git clone https://github.com/AkaLab-Tech/atelier ~/atelier
cd ~/atelier
```

This copies atelier's code to a folder called `atelier` inside your home directory. The `cd` moves you into it.

You should see `install.sh` and `README.md` if you run `ls`.

---

## Step 2 — Run the installer

From inside the `~/atelier` folder, run:

```bash
./install.sh
```

Here's what will happen, in order:

1. **System tools** — atelier installs anything it needs (Homebrew packages on Mac, apt packages on Linux). You may see lots of output; this is normal.
2. **Claude Code** — installs the Claude Code command-line tool.
3. **Log in to Claude** — your browser opens a tab. Sign in with your Claude account, then come back to the terminal.
4. **Log in to GitHub (first account, the "author")** — browser opens again. Sign in with your **primary** GitHub account.
5. **Log in to GitHub (second account, the "reviewer")** — browser opens again. Sign in with your **second** GitHub account. atelier will complain if it's the same account as step 4.
6. **Plugin install** — atelier configures Claude Code with the atelier plugin.

When it's done, you'll see a section titled `Install complete` followed by `Next steps:`. The terminal will print copy-pasteable commands for the next steps below.

If something fails partway through, atelier remembers where it stopped. You can re-run `./install.sh` and it will pick up where it left off.

---

## Step 3 — Reload your shell

```bash
source ~/.zshrc
```

(Use `~/.bashrc` if you're on bash.) This loads the new `atelier` and `task` commands into your current terminal. You can also open a brand new terminal — same effect.

To check the install worked:

```bash
atelier /atelier:doctor
```

This runs atelier's health check. You should see a list of items each marked `✓`. If you see a `✗` (red X), the line tells you what to fix.

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

You can run `atelier /atelier:setup-project .` on as many projects as you like — atelier will remember each one.

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

- [ ] feat Add a "Contact Us" link to the footer that opens a mailto link
- [ ] bug Fix the typo on the homepage where it says "Welcom" instead of "Welcome"
- [ ] chore Add a README section explaining how to run the test suite
```

The `[ ]` is an empty checkbox — atelier marks it as `[x]` when the task is done. The word right after the checkbox (`feat`, `bug`, `chore`) tells atelier what kind of work this is.

Save the file.

---

## Step 6 — Run the task

From anywhere on your computer, run:

```bash
task
```

atelier will figure out which project you mean based on the folder you're in. (If you're not inside a registered project, atelier shows a picker to choose one.)

A Claude session opens and starts working on the top task in your `ROADMAP.md`. You can watch what it does — atelier shows every step on screen. Here's roughly what happens:

1. atelier picks the first item from `ROADMAP.md` and moves it to `IN_PROGRESS.md`.
2. The author agent reads the task, then writes the code change.
3. atelier runs your project's tests (if you have any) to make sure nothing broke.
4. The author shares the change on GitHub as a pull request.
5. The reviewer agent (the second GitHub account!) reads the change and gives it a thumbs-up or asks for fixes.
6. If the reviewer approves and nothing is risky, atelier saves the change to your project and marks the task `[x]` in `HISTORY.md`.

Time per task varies: a typo fix might take 5 minutes; adding a new feature might take an hour or more. You can leave it running and come back.

If atelier gets stuck (e.g. a test keeps failing), it stops and creates an issue on GitHub tagged `blocked` so you know to look at it. It doesn't keep retrying forever.

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

## If something goes wrong

First stop: run the health check.

```bash
atelier /atelier:doctor
```

Any `✗` line tells you what's broken and the command to fix it. Copy-paste the suggested command and re-run the doctor.

If you're still stuck:

- Look in `HISTORY.md` — the most recent entry tells you what was last working.
- Check GitHub for issues with the `blocked` label — atelier creates those when it can't finish.
- Re-run the installer: `cd ~/atelier && ./install.sh`. It's safe to re-run; it picks up where it left off.

For symptom-indexed common problems (`task: command not found`, a hook blocked an edit, auto-merge skipped a PR, reviewer's approval shows as a comment, etc.) see [troubleshooting.md](troubleshooting.md).

---

## Uninstall

If you decide atelier isn't for you:

```bash
atelier-uninstall
```

This removes the atelier plugin and the shell shortcuts but **keeps your chat history**.

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
| `atelier /atelier:setup-project .` | Set up the current folder as an atelier project |
| `atelier /atelier:doctor` | Run a health check |
| `atelier-uninstall` | Remove atelier (preserves history) |
| `atelier-uninstall --purge` | Remove atelier and wipe all settings |

**Files atelier creates in each project**:

- `ROADMAP.md` — work waiting to be done.
- `IN_PROGRESS.md` — work being done right now.
- `HISTORY.md` — work that's done, with links to the saved changes.
- `.claude/settings.json` — per-project permissions (auto-regenerated each task).
- `.npmrc` (Node.js projects only) — safety settings for installing packages.

**Files atelier stores outside your projects**:

- `~/.claude-work/` — atelier's own configuration, separate from your personal Claude config.
- `~/.local/bin/atelier-*` — the `atelier-setup-project`, `atelier-uninstall`, `atelier-doctor`, and `atelier-task-resolve` commands.
