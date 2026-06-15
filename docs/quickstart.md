# Quickstart — update, verify, and use atelier

A command-first runbook for the recurring operations. For the long-form,
Jr-friendly walkthrough see the [Operator Guide](operator-guide.md); for
symptom-indexed fixes see [troubleshooting.md](troubleshooting.md).

Mental model for everything below:

```
setup(-project | -workspace)  →  onboard-workspace / adopt-roadmap  →  commit to base  →  plan-task  →  task
   (register / scaffold)            (tracking content → §5)            (so next-task sees it)   (mark ready)  (run)
```

Two delivery channels matter when updating:

- **Helpers** (`atelier-*` CLIs: `list-projects`, `workspace-status`,
  `setup-project`, …) update via the `git pull` inside `atelier-update`.
  No release needed.
- **Plugin commands** (`/atelier:*`, agents, skills) are served from the
  marketplace, which resolves the repo's latest **GitHub release**. They need a
  version bump + tag (see [§4](#4-cut-a-release-plugin-command-changes-only)),
  after which `atelier-update` pulls them.

---

## 0. Update atelier locally

```bash
atelier-update        # git pull origin/main + refresh templates + `claude plugin update`
atelier-doctor        # expect: ✓ atelier@akalab-tech <version> (up to date)
```

Restart any open Claude Code sessions — they keep the previous plugin version
until they restart.

---

## 1. Verify configuration

```bash
atelier-doctor                      # global health: plugins, hooks, identities, auto-mode
atelier-list-projects               # registry with workspace labels, version-drift (↻), suggested commands
atelier-workspace-status <slug>     # per-workspace: members + "roadmap §5: no" where adoption is needed
```

`atelier-list-projects` flags projects whose `setupVersion` is older than the
installed plugin with a `↻` hint — re-run `/atelier:setup-project` in those to
resync their `.claude/settings.json` to the current template.

---

## 2. A project that is ALREADY set up — resolve gaps from older versions

Typical gaps from earlier versions: decision policy left at `ask` (atelier asks
on every strategic step), a `ROADMAP.md` that is not PLAN.md §5 (so no task is
claimable), or a legacy multi-item `IN_PROGRESS.md`.

Open a session in the project (or at the workspace root):

```bash
cd <project-or-workspace-root> && atelier
```

Inside the session / from the right directory:

```
/atelier:setup-project          # idempotent: resyncs settings to the current template,
                                # and now flags a non-§5 ROADMAP or a legacy IN_PROGRESS
```

- **Decision policy** (stop the constant questions):
  - Whole workspace, one command:
    `atelier-setup-workspace --name <slug> --force --policy auto --members <p1,p2,...>`
  - Single project: `/atelier:set-policy` → choose `auto`.
- **ROADMAP → §5** (so tasks become claimable):
  - Whole workspace: `/atelier:onboard-workspace <slug>`
  - Single project: `/adopt-roadmap --format atelier`
- **Commit to base** — `.atelier.json` (policy) and the adopted tracking files
  must be committed and merged to each repo's **base branch** (`dev`/`main`),
  one PR per repo. This is required: `/atelier:next-task` reads the ROADMAP from
  `origin/<base>`, and the decision broker reads `.atelier.json` from each
  task's worktree (branched from base).
- **Run:**
  ```
  /atelier:plan-task <id>     # approve the plan → marks the task [ready]
  /atelier:next-task          # or `task` from the workspace root (member picker)
  ```

---

## 3. A NEW project

```bash
cd <project> && atelier
```

```
/atelier:setup-project
```

`setup-project` handles both cases:

- **Had a tracking mechanism already** (a `ROADMAP.md` in any format): it creates
  the atelier config, drafts `CLAUDE.md`, and **preserves** your tracking files.
  - If that ROADMAP is **not §5** → it offers `/adopt-roadmap --format atelier`
    (accept it → fill the `` `TODO-type` `` / `` `~TODO` `` placeholders → commit to base).
  - If `IN_PROGRESS.md` is a legacy tracker → it offers `/adopt-roadmap`.
- **Had none** → it creates `ROADMAP.md` / `IN_PROGRESS.md` / `HISTORY.md` in the
  §5 layout; just write tasks in §5.

Answer the **decision policy** prompt when `setup-project` asks (or run
`/atelier:set-policy` afterwards), then `/atelier:plan-task <id>` →
`/atelier:next-task`.

**A new workspace of several repos:**

```
/atelier:setup-workspace <slug> --discover <parent-dir>   # or --members <p1,p2,...>
                                                          # asks the policy once and propagates it
/atelier:onboard-workspace <slug>                          # adopt any member whose ROADMAP isn't §5
```

---

## 4. Cut a release (plugin-command changes ONLY)

Only needed when you change `commands/`, `agents/`, `skills/`, `hooks/`, or
`CLAUDE.md` — i.e. content Claude loads. Pure helper-script changes ship via
`atelier-update` without a release.

```bash
# 1) bump .claude-plugin/plugin.json → open a PR to main → merge it, then:
cd <atelier-checkout> && git checkout main && git pull --ff-only origin main
git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z
gh release create vX.Y.Z --title "vX.Y.Z" --notes "..."

# 2) deliver it
atelier-update && atelier-doctor    # doctor should show vX.Y.Z (up to date)
```

The marketplace (`AkaLab-Tech/claude-plugins`) points at this repo with no
version pin, so it serves the latest GitHub release; the tag is what publishes
the change.

---

## Shortcuts & rules

- **Headless / autonomous** (`claude -p "/atelier:next-task"`): export
  `ATELIER_AUTO=1` (or pass `--yes`), otherwise the command stops at the first
  question.
- **A task going sideways under `auto`:** `/atelier:abort-auto` routes every
  remaining decision back to you; `/atelier:resume-auto` hands control back to
  the broker.
- **Only `task/*` PRs** go through the review + auto-merge chain — claim work
  with `/atelier:next-task` (or `task`), not with manual `feature-*` branches.

---

## See also

- [Operator Guide](operator-guide.md) — full zero-to-first-task walkthrough.
- [troubleshooting.md](troubleshooting.md) — symptom-indexed fixes.
- [operator-rules.md](../operator-rules.md) — the rules loaded into every session.
