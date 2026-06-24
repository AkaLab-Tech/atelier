# Manual E2E Test — GitHub Project-backed Member + Mixed-backend Workspace

**Who this test plays.** A **non-technical operator** — a product owner or project lead who talks to atelier, clicks the GitHub **Merge** button, and reads the GitHub Projects board. They don't branch, merge, or run git by hand. Their job is to follow every step below exactly as written and note any divergence in the findings log.

**What it proves.** That:

1. **A full autonomous cycle runs against a real `github-project`-backed member.** `/next-task` reads the backlog from the GitHub Project (not a local `ROADMAP.md`), honours the planning gate via the Project's **Ready** field + a committed `.plan/<id>.md`, claims a task, runs the implementer → tester → pr-author chain, opens a PR on `task/<id>-<slug>`, fires the reviewer + auto-merge gate, and on merge calls `appendHistoryEntry` so the Project item moves through the Status field transitions (`roadmap → in_progress → history`) — entirely via the backend, never via local file edits.

2. **A mixed-backend workspace aggregates status honestly and resolves cross-repo `blocked_by` through each member's own backend.** `atelier-workspace-status` renders one accurate row per member — the `files` member from its `ROADMAP.md`, the `github-project` member showing `backend:github-project` with no false `0`/`absent`/drift signals. `atelier-resolve-dep` returns the correct verdict for each direction of cross-repo dependency, including `backend-deferred` (exit 6) when the blocker lives in a `github-project` member.

This closes **M9 (Phase 9: external task-manager backends)** by proving the `github-project` backend (M9.1–M9.4) and the workspace layer (M9.5a #22a / M9.5b #22b) work end-to-end against real OAuth and real repos. See PLAN.md §16.7 for the design.

**How to run it.** Follow top to bottom. Each step has four beats: **What you do** / **What you say to atelier** / **What you should see** / **How you know it worked**. When reality differs from "what you should see", write it down in the findings log (`docs/manual-e2e-workspaces-backends-results.md`). That log is the deliverable.

> The live findings are intentionally deferred — the runbook is authored against named-but-to-be-provisioned fixtures. The operator fills in `docs/manual-e2e-workspaces-backends-results.md` during the manual OAuth pass. Divergences discovered during the live run may surface new tasks; record them in the findings log, not here.

---

## Fixtures — what you need before you start

You need the following in place before Stage A Step 1. Mark them off as you provision them.

- [ ] **A GitHub MCP OAuth session.** Run `claude mcp add --transport http github https://api.githubcopilot.com/mcp/` (or confirm it is already registered with the `projects` toolset). atelier uses hosted GitHub MCP for all GitHub Projects API calls — never `gh` CLI.
- [ ] **Repo `<gp-repo>` — the `github-project`-backed member.** A real GitHub repository you own or admin (or can get an admin to configure). It must have a real **GitHub Project (v2)** attached, with at least these custom fields configured via `/atelier:setup-project` + `/atelier:create-roadmap --backend github-project`:
  - `Atelier ID` — single-line text, e.g. `#1`
  - `Ready` — boolean/single-select (the planning-gate field, PLAN.md §16.5)
  - `Status` — single-select with your chosen `stateMap` values (e.g. `Backlog` → roadmap bucket, `In Progress` → in_progress bucket, `Done` → history bucket)
  - `Type`, `Estimate` — single-line text (optional but recommended)
  - At least **two backlog items** in the Project (Status = roadmap bucket), one of which has `Ready` unset and one of which you will set to `Ready` during the test.
- [ ] **Repo `<files-repo>` — the `files`-backend member.** A second real GitHub repository with a standard atelier `ROADMAP.md` (files backend, `backend: files` in `.roadmap.json` or no `.roadmap.json`). Needs at least two tasks in its roadmap, one of which will carry a `blocked_by:<gp-token>#id` cross-repo dependency pointing into `<gp-repo>`.
- [ ] **A second GitHub account** (`<reviewer-account>`) already added as a collaborator on both repos. This is the `AtelierReviewer` account that approves PRs.
- [ ] **Workspace `<ws-slug>` configured** via `/atelier:setup-workspace`, grouping both repos with tokens `<gp-token>` (for `<gp-repo>`) and `<files-token>` (for `<files-repo>`). Confirm with `/atelier:list-workspaces`.

Where you see `<gp-repo>`, `<files-repo>`, `<gp-token>`, `<files-token>`, `<ws-slug>`, substitute your actual names throughout.

---

## Stage A — Full autonomous cycle on a `github-project`-backed member

This stage drives a complete atelier cycle on `<gp-repo>` — discover, plan, implement, PR, merge — and verifies the GitHub Project board reflects each state transition via the backend.

### Step A.1 — Confirm the GitHub MCP is registered

**What you do.**

```bash
atelier
```

**What you say to atelier.**

```
Is the GitHub MCP registered? Show me which MCP servers are active.
```

**What you should see.** atelier lists the registered MCP servers and confirms the GitHub hosted MCP (`https://api.githubcopilot.com/mcp/`) is present and showing the `projects` toolset.

**How you know it worked.** No "GitHub MCP not found" warning. The Projects API is reachable.

> If the MCP is missing, run `claude mcp add --transport http github https://api.githubcopilot.com/mcp/` then restart atelier. Record in the findings log if setup was unexpectedly required.

---

### Step A.2 — Confirm the Project's backlog is readable

**What you do.**

```bash
cd ~/Work/<gp-repo>
atelier
```

**What you say to atelier.**

```
List the open tasks in this project's backlog from the GitHub Project.
```

**What you should see.** atelier calls `listTasks("roadmap")` via the `github-project` backend and returns your backlog items. Each item should show its `Atelier ID` value, title, `Ready` field state, and Status.

**How you know it worked.** The items you put in the Project's roadmap bucket appear. None come from a local `ROADMAP.md` read (there should be no `ROADMAP.md`, or atelier explicitly says it is reading from the backend).

> **Expected GitHub Projects board state at this point:** your items in the `Backlog`/`Todo` column (whatever your stateMap maps to the roadmap bucket), `Ready` unset on at least one item.

---

### Step A.3 — Approve a plan and set the Ready field

**What you do.** Still in the `<gp-repo>` atelier session.

**What you say to atelier.**

```
/atelier:plan-task #1
```

(Replace `#1` with whichever task you want to drive through the cycle.)

Then, before approving:

```
Explain the plan in plain language: what will you change and how will you verify it?
```

**What you should see.** atelier writes a short plan and waits for your approval. It will not start work and will not set `Ready` by itself.

**What you say next.**

```
Save the approved plan so the task is ready to run.
```

**What you should see.** atelier:
1. Commits `.plan/<id>.md` to the repo's base branch (or opens a PR for it — record which).
2. Calls `RoadmapBackend.setReady(id, true)` which flips the Project item's `Ready` field to `true` via the GitHub MCP.

**How you know it worked.** Check the GitHub Projects board: the item now shows `Ready = true` (or the equivalent value in your field). The `.plan/<id>.md` file is committed. The task's Status is still in the roadmap bucket — `Ready` does not move Status.

> **Expected board state:** item still in `Backlog` column, `Ready` field = true.

---

### Step A.4 — Run the autonomous cycle

**What you do.**

```bash
cd ~/Work/<gp-repo>
ATELIER_AUTO=1 atelier -p "/atelier:next-task"
```

**What you should see, in order:**

1. **Backlog read via backend.** atelier calls `listTasks("roadmap")` — no local `ROADMAP.md` open. It shows the task list sourced from the Project.
2. **Planning gate.** atelier checks `Ready = true` AND `.plan/<id>.md` committed. The task you planned in Step A.3 is the only eligible one; any task with `Ready = false` is silently skipped.
3. **Claim.** atelier calls `moveTask(id, "roadmap", "in_progress")` via the backend — the Project item's Status changes to your `in_progress` stateMap value (e.g. `In Progress`). A `task/<id>-<slug>` branch is opened.

> **Expected board state:** item moves from `Backlog` to `In Progress` column on the GitHub Projects board. Check the board while the cycle runs.

4. **Implementer → tester → pr-author chain runs.** atelier works in its own private worktree; it does not touch your checked-out copy of the repo.
5. **PR opens on `task/<id>-<slug>`.** The PR summary references the task's Atelier ID and title.
6. **Reviewer fires.** The `<reviewer-account>` reviews and approves the PR. Record if auto-merge holds for any guardrail reason.
7. **Auto-merge.** The PR is squash-merged. atelier then calls `appendHistoryEntry(id, prMetadata)` via the backend — the Project item's Status changes to your `history` stateMap value (e.g. `Done`).

**How you know it worked.** The GitHub Projects board shows the item in the `Done`/history column. No local `HISTORY.md` or `IN_PROGRESS.md` was edited (there is none for this backend — only `.plan/<id>.md` in git). The merged PR is on `main`. The worktree is cleaned up.

> **Expected board state:** item in `Done` column, `Ready` field still true, `Status = Done`.

> **Watch for:** atelier falling back to reading a local `ROADMAP.md` instead of the backend — note this in the findings log. Also watch for the `appendHistoryEntry` call missing, which would leave the item in `In Progress` after the PR merges.

---

### Step A.5 — Verify the Project board state end-to-end

**What you do.** Open the GitHub Projects board for `<gp-repo>` in your browser.

**What you should see.**

| Field | Expected value |
|---|---|
| Status (column) | your `history` stateMap value (e.g. `Done`) |
| `Ready` | true |
| `Atelier ID` | `#<id>` matching the task you ran |

**How you know it worked.** The board reflects all three transitions: roadmap → in_progress (Step A.4 claim) → history (Step A.4 appendHistoryEntry). Every transition happened via the backend, not local file edits.

---

## Stage B — Mixed-backend workspace aggregation + cross-repo `blocked_by`

This stage exercises the two-repo workspace where `<gp-repo>` uses `github-project` and `<files-repo>` uses `files`. It proves `atelier-workspace-status` aggregates both members honestly and that `atelier-resolve-dep` returns the correct verdict in both dependency directions.

### Step B.1 — Confirm workspace configuration

**What you do.**

```bash
atelier
```

**What you say to atelier.**

```
/atelier:list-workspaces
```

**What you should see.** The workspace `<ws-slug>` appears, listing both members: `<gp-token>` (path to `<gp-repo>`) and `<files-token>` (path to `<files-repo>`), both **configured**.

**How you know it worked.** Both members show as configured. If either shows **partial**, ask atelier to finish its setup before continuing.

---

### Step B.2 — Run workspace status (human-readable)

**What you do.**

```bash
cd ~/Work   # any directory that resolves the workspace, or use the slug
atelier
```

**What you say to atelier.**

```
/atelier:workspace-status <ws-slug>
```

Or run directly:

```bash
atelier-workspace-status <ws-slug>
```

**What you should see.** One row per member in the dashboard:

| Member token | Status column | Open tasks column | Notes |
|---|---|---|---|
| `<files-token>` | configured | a number (e.g. `2`) | read from `ROADMAP.md` |
| `<gp-token>` | configured | `backend:github-project` | not `0`, not a count |

The `<gp-token>` member must **not** show `0` open tasks — it shows the backend indicator instead. This is the correct #22b behaviour: a backend-tracked member cannot report a local file count.

**How you know it worked.** Both rows appear. The `<gp-token>` row shows `backend:github-project` in the open-tasks column, not a number. There are no false drift signals for the `<gp-token>` member (drift detection is excluded for non-files backends per #22b).

---

### Step B.3 — Run workspace status (JSON)

**What you do.**

```bash
atelier-workspace-status <ws-slug> --json
```

**What you should see.** A JSON object with a `members` array. Each member object should include a `backend` field:

```json
{
  "workspace": "<ws-slug>",
  "members": [
    {
      "token": "<files-token>",
      "backend": "files",
      "openTasks": 2,
      ...
    },
    {
      "token": "<gp-token>",
      "backend": "github-project",
      "openTasks": null,
      ...
    }
  ]
}
```

The `<gp-token>` member must have `"openTasks": null` — `null` is the explicit signal distinguishing "unknown because backend-tracked" from `0` (which would mean "zero open tasks in a files member"). The `<files-token>` member has a numeric count.

**How you know it worked.** The JSON is valid (pipe through `jq .` to confirm). The `openTasks` field is `null` for the backend-tracked member and a number for the files member.

---

### Step B.4 — Cross-repo `blocked_by`: `files → github-project`

Set up a cross-repo dependency where a task in `<files-repo>` is blocked by a task in `<gp-repo>`. The blocking task must still be **open** (in the `github-project` member's roadmap or in_progress bucket, not history).

**What you do.** Edit the blocking task's entry in `<files-repo>`'s `ROADMAP.md` so it carries:

```
blocked_by:<gp-token>#<blocker-id>
```

Where `<blocker-id>` is a task that is still open in the GitHub Project. Commit this change.

Then run:

```bash
atelier-resolve-dep \
  --workspace <ws-slug> \
  --from ~/Work/<files-repo> \
  --token <gp-token> \
  --id <blocker-id>
```

**What you should see.** stdout prints:

```
backend-deferred
```

Exit code: `6`.

This is the correct verdict from #22a: `<gp-token>` uses a non-files backend, so the bash resolver cannot scan a local `HISTORY.md`. It defers to the AI layer.

**What you say to atelier** (to exercise the AI-layer resolution path):

```
In workspace <ws-slug>, check whether task <blocker-id> in <gp-token> is satisfied
(merged into history). Use the github-project backend to check its Status.
```

**What you should see.** atelier calls `getTask(<blocker-id>)` on the `<gp-token>` member's backend. Because the task is still open, it reports the task is **not in the history bucket** — the dependent task in `<files-repo>` remains blocked.

**How you know it worked.** `atelier-resolve-dep` exit code is `6` and stdout is `backend-deferred`. atelier's AI layer reads the backend and confirms the dependent is still blocked. Record both the exit code and the AI layer's verdict in the findings log.

---

### Step B.5 — The blocker reaches the `history` bucket — dependent becomes eligible

**What you do.** Complete the blocking task in `<gp-repo>` — either run another autonomous cycle through it (Step A.4), or manually set its Status to your `history` stateMap value in the GitHub Projects board.

Then re-run the AI-layer resolution:

**What you say to atelier.**

```
In workspace <ws-slug>, check again whether task <blocker-id> in <gp-token>
is now satisfied.
```

**What you should see.** atelier calls `getTask(<blocker-id>)` again. This time the task's Status maps to the history bucket — atelier reports the blocker is **satisfied** and the dependent task in `<files-repo>` is now eligible.

**How you know it worked.** The AI layer returns `satisfied`. If you now run `atelier-workspace-status <ws-slug>`, the previously blocked task should no longer appear in the cross-repo-blocked section. Record this in the findings log.

---

### Step B.6 — Cross-repo `blocked_by`: `github-project → files`

Now exercise the reverse direction: a task in `<gp-repo>` (github-project backend) blocked by a task in `<files-repo>` (files backend).

**What you do.** In the GitHub Project for `<gp-repo>`, set the `blocked_by` custom-field value on a backlog item to:

```
<files-token>#<files-task-id>
```

Where `<files-task-id>` is a task still **open** in `<files-repo>`'s `ROADMAP.md`.

Then run (from the `<gp-repo>` member's perspective):

```bash
atelier-resolve-dep \
  --workspace <ws-slug> \
  --from ~/Work/<gp-repo> \
  --token <files-token> \
  --id <files-task-id>
```

**What you should see.** Because `<files-token>` uses the `files` backend, `atelier-resolve-dep` can scan its `HISTORY.md` directly. stdout prints:

```
open
```

Exit code: `3`.

**How you know it worked.** Exit code is `3` and stdout is `open`. The `files`-backend path is used (no `backend-deferred`). When `<files-task-id>` is merged (appears in `<files-repo>`'s `HISTORY.md` with a PR reference), re-running gives exit `0` / `satisfied`. Record both verdicts in the findings log.

---

### Step B.7 — Full verdict table for the findings log

Record the following in `docs/manual-e2e-workspaces-backends-results.md`:

| Direction | `atelier-resolve-dep` args | Expected stdout | Expected exit | AI-layer follow-up |
|---|---|---|---|---|
| `files → github-project` (blocker open) | `--token <gp-token> --id <open-id>` | `backend-deferred` | `6` | backend call returns open → blocked |
| `files → github-project` (blocker in history) | `--token <gp-token> --id <closed-id>` | `backend-deferred` | `6` | backend call returns history → satisfied |
| `github-project → files` (blocker open) | `--token <files-token> --id <open-id>` | `open` | `3` | n/a (files offline) |
| `github-project → files` (blocker in HISTORY.md) | `--token <files-token> --id <closed-id>` | `satisfied` | `0` | n/a |

---

## §16.7 v1 constraint — one backend per repo

> **This constraint is by design and is not a bug.**

In v1, atelier enforces **one backend per repo**: each member repo is either `files` (local `ROADMAP.md`/`HISTORY.md`) or `github-project` (a single GitHub Project v2). **A single GitHub Project shared across multiple repos in a workspace is deferred** — it complicates `blocked_by:<token>#id` resolution and breaks the one-backend-per-repo invariant.

If during the live run you observe atelier attempting to read a shared Project for multiple members, record it in the findings log as a divergence. The correct behaviour is for each member to operate against its own independently-configured backend.

See PLAN.md §16.7 for the full rationale and the deferred shared-Project workspaces design.

---

## Write down what you found

Record results in `docs/manual-e2e-workspaces-backends-results.md`. For each thing that did not match "what you should see":

1. **Which step** it happened in.
2. **What you did or said** to atelier (copy-paste the command or message).
3. **What you expected vs. what actually happened** — copy the relevant atelier output.
4. **Where things ended up** — e.g. "the Project item stayed in In Progress after merge", or a screenshot of the board.

For Stage A, also record the GitHub Projects board column for each state transition (roadmap → in_progress after Step A.4 claim; in_progress → history after Step A.4 merge). A screenshot of the board is the clearest evidence.

For Stage B, record the exact exit code and stdout for each `atelier-resolve-dep` invocation, and the AI layer's verdict for each `backend-deferred` case.

---

## You're done when

- [ ] GitHub MCP is registered and the Projects API is reachable (Step A.1).
- [ ] `/next-task` on `<gp-repo>` reads the backlog from the GitHub Project, not a local file (Step A.2).
- [ ] Planning gate: `.plan/<id>.md` committed and Project item `Ready = true` after `/atelier:plan-task` (Step A.3).
- [ ] Full autonomous cycle runs: task claimed (Status → `in_progress`), PR opens on `task/<id>-<slug>`, reviewer approves, PR merges, Status → `history` via `appendHistoryEntry` — all via the backend (Step A.4).
- [ ] GitHub Projects board shows all three Status transitions confirmed in the UI (Step A.5).
- [ ] `atelier-workspace-status <ws-slug>` renders one honest row per member: files member shows a count, `github-project` member shows `backend:github-project` with no false `0`/drift (Steps B.2–B.3).
- [ ] `--json` output: `<gp-token>` member has `"openTasks": null` (Step B.3).
- [ ] `atelier-resolve-dep` returns `backend-deferred` / exit `6` for the `files → github-project` direction (Step B.4).
- [ ] AI layer resolves `backend-deferred` correctly: blocked while the task is open, satisfied once it reaches the history bucket (Steps B.4–B.5).
- [ ] `atelier-resolve-dep` returns `open` / exit `3` (then `satisfied` / exit `0`) for the `github-project → files` direction (Step B.6).
- [ ] All observations recorded in `docs/manual-e2e-workspaces-backends-results.md`.
