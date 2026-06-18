# TASK_016 — Session orientation: context-aware next-steps when the operator opens atelier

**Requested 2026-06-18.** When the operator opens atelier in a directory, atelier
should greet them with a **single, prioritized "what to do next"** derived from the
project's actual state — instead of the operator having to remember which command
applies. Not configured → suggest setup; multi-repo parent → suggest workspace;
configured-but-inconsistent → suggest align; open PRs → review/merge; in-progress
task → resume; otherwise → the next task to take or to plan.

## Mechanism (validated against the existing hook contract)

atelier already ships `SessionStart` hooks (`load-operator-rules.sh`,
`daily-housekeeping.sh`) whose **stdout becomes session context**, which the model
surfaces in its first reply (that is how the housekeeping nudge works today). Two
delivery vehicles, to be combined:

- **B — `SessionStart` hook (cheap, no network).** A new hook prints a prioritized
  orientation derived from **filesystem/jq only** (no `gh`, no remote `git` — same
  discipline as `daily-housekeeping.sh`, to avoid adding latency or permission
  prompts to every session). The model presents it in its first response.
- **A — `/atelier:orient` command + `atelier()` opens with it.** The bare `atelier`
  shell entry point launches the session with `/atelier:orient` (the way `task`
  launches `/atelier:next-task`), giving a literal first assistant message and the
  fuller picture that needs `gh` (open PRs) / remote state. Requires editing the
  `atelier()` block in `install.sh` (host layer → re-run install / shellrc refresh
  to take effect).

**Honest limit:** Claude Code does not let the assistant speak before the operator's
first input. With **A** the orientation is literally the first message (because
`atelier` starts with the command); with **B** it lands in the first response. There
is no third mode — do not promise an unprompted greeting beyond these.

## Priority decision tree (first match = the headline suggestion)

Lead with ONE protagonist action + a compact summary of the rest. Never dump a wall.

1. **Not a git repo** → offer `git init` (atelier needs git).
2. **Multi-repo parent** (several child `.git` dirs, cwd not itself configured) → `/atelier:setup-workspace --discover .`
3. **Git repo, not atelier-configured** → `/atelier:setup-project`
4. **Configured but inconsistent** (see matrix) → align
5. **Workspace root** → `atelier-workspace-status` + `task` (member picker) / onboard pending members
6. **In-progress or blocked task** → `/atelier:resume-task` (or unblock)
7. **Open PRs** → review / merge / address change-requests
8. **Clean + a `[ready]` task exists** → `/atelier:next-task` (name it)
9. **Backlog exists but nothing `[ready]`** → `/atelier:plan-task <id>` (ranked shortlist)
10. **Empty backlog** → write / adopt tasks

### "Inconsistent" sub-cases (case 4)
- `partial` (missing `.atelier.json` or `.claude/settings.json`) → re-run `setup-project`.
- **Version drift** (`setupVersion` < installed plugin — the `↻` from `list-projects`) → re-run `setup-project` to resync.
- pre-atelier `.claude/settings.json` (unmanaged) → `setup-project --override`.
- **ROADMAP not §5** → `/adopt-roadmap --format atelier` (or `/atelier:onboard-workspace`).
- **Legacy `IN_PROGRESS`** → adopt.
- **Policy still `ask`** → suggest `auto` (`/atelier:set-policy` or `--policy`).
- **Non-§5 task ids** (TASK_001 / M7.4) → migrate.

### Cross-cutting cases also covered
- **atelier itself out of date** (installed plugin < latest release) → `atelier-update`.
- **Onboarding PR not yet merged** → nothing claimable until it lands on base.
- **Unsatisfied cross-repo `blocked_by`** (workspace) → name the blocker.
- **Orphan worktrees / merged `task/*` branches** → `/atelier:housekeeping`.
- **`.plan/<id>.md` exists but task not `[ready]`** (planning interrupted) → resume / mark ready.
- **Multiple tasks in flight** (`taskConcurrency.max > 1`) → list them, suggest which to resume.
- **Opened a workspace MEMBER (not the root)** → member-scoped suggestions + note it can be driven from the root.
- **Auth/identity gaps** (reviewer can't see repo, `gh` not logged in) → defer to `/atelier:doctor`.
- **Base branch behind origin / dirty working tree** → informational (tasks isolate in worktrees regardless).
- **Docker services for the in-progress task down** → informational.

## Proposed build (phased)

**Phase 1 (B — value without touching the operator's shellrc):**
- `scripts/atelier-orient <dir>` — cheap helper (filesystem + jq only, no network),
  reusing `compute_status` / `roadmap_format` / `workspace_of` / `IN_PROGRESS`
  parsing. Emits a prioritized orientation block + the recommended command, with a
  clear "run /atelier:status or /atelier:orient for open PRs / in-progress detail"
  pointer for the network-dependent cases.
- `hooks/orient-session.sh` — `SessionStart` hook that runs the helper against
  `$CLAUDE_PROJECT_DIR` and prints the block (fail-open, like the other hooks).
  Register in `hooks/hooks.json`.
- Hermetic test (`hooks/tests/orient-*.test.sh`) covering the decision tree on
  synthetic dirs; wired into `structural.yml`.

**Phase 2 (A — the literal first message + full picture):**
- `commands/orient.md` (`/atelier:orient`) — model-driven: runs `atelier-orient`
  for the cheap signals, then layers the network checks (open `task/*` PRs via `gh`,
  in-progress/blocked, cross-repo deps — largely reusing `/atelier:status`), and
  presents the prioritized next step, offering to act.
- `install.sh` — make the bare `atelier()` entry open with `/atelier:orient` (or a
  `--no-orient` escape hatch). Host-layer change; document the shellrc refresh.

## Acceptance criteria
- Opening a session in each state yields the **correct single headline** suggestion
  per the decision tree, plus a compact summary of secondary items.
- The `SessionStart` hook adds **no network calls** and no measurable session-start
  latency regression (parity with `daily-housekeeping.sh`); fail-open when atelier is
  not installed / cwd is unrelated.
- `/atelier:orient` reflects open PRs and in-progress/blocked state accurately.
- Decision-tree logic is unit-tested hermetically (synthetic project/workspace dirs).
- No false alarms on a clean, fully-aligned, up-to-date project (it should say so and
  point at `next-task`).

## Open questions (resolve when planned/taken)
- **Noise control:** orient every session vs. gate (e.g. once/day like housekeeping, or
  only when state ≠ "clean & ready"). Leaning: always show, but make it one headline.
- **Latency budget** for the cheap hook; hard timeout + fail-open.
- **Where the network checks live** — `/atelier:orient` reusing `/atelier:status`
  vs. duplicating. Prefer reuse.
- Interaction with **headless** (`ATELIER_AUTO`) sessions — orient should print but
  never auto-act.
