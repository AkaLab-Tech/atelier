# Validation Findings — GitHub Project-backed Member + Mixed-backend Workspace

> **RESULTS: PENDING LIVE RUN**
>
> This file is the merge-closing evidence skeleton for M9 / task #22c. Every `Observed`, `Divergence`, and `Pass/Fail` cell below is an explicit placeholder — `— (pending live run)` — for the operator to complete during the manual OAuth pass described in `docs/manual-e2e-workspaces-backends.md`.
>
> The runbook and this findings log are shipped together in the same PR so the acceptance-criteria skeleton is in place at merge time. The operator fills in the live findings in a subsequent manual pass. Any divergences discovered during the live run that indicate a real bug should be opened as new tasks — they are not blockers for closing M9 (per the task #22c plan and risk register).

**Runbook:** `docs/manual-e2e-workspaces-backends.md`
**Date of live run:** — (pending)
**Operator:** — (pending)
**Fixtures used:**
- `<gp-repo>` (github-project backend): — (pending)
- `<files-repo>` (files backend): — (pending)
- Workspace slug `<ws-slug>`: — (pending)
- Reviewer account: — (pending)

---

## Stage A — Full autonomous cycle on a `github-project`-backed member

### A.1 — GitHub MCP registration

| Step | Expected | Observed | Divergence | Pass/Fail |
|---|---|---|---|---|
| A.1: GitHub MCP is registered and `projects` toolset is active | MCP listed with `https://api.githubcopilot.com/mcp/` endpoint; no "not found" warning | — (pending live run) | — (pending live run) | — (pending live run) |

---

### A.2 — Backlog readable via backend

| Step | Expected | Observed | Divergence | Pass/Fail |
|---|---|---|---|---|
| A.2: `listTasks("roadmap")` returns Project items | Items from the GitHub Project appear with `Atelier ID`, title, `Ready`, `Status`; no local `ROADMAP.md` read | — (pending live run) | — (pending live run) | — (pending live run) |
| A.2: No false read of local `ROADMAP.md` | atelier explicitly reads from the backend, or no `ROADMAP.md` exists | — (pending live run) | — (pending live run) | — (pending live run) |

**GitHub Projects board state at this point (operator to fill in):**

Items observed in roadmap/backlog bucket: — (pending live run)

---

### A.3 — Planning gate: `Ready` field + `.plan/<id>.md`

| Step | Expected | Observed | Divergence | Pass/Fail |
|---|---|---|---|---|
| A.3: `/atelier:plan-task #<id>` writes `.plan/<id>.md` | `.plan/<id>.md` committed to base branch (or PR opened for it) | — (pending live run) | — (pending live run) | — (pending live run) |
| A.3: `Ready` field set on Project item | GitHub Projects board shows `Ready = true` for the planned item | — (pending live run) | — (pending live run) | — (pending live run) |
| A.3: Status not changed by planning | Item still in roadmap/backlog bucket — `Ready` is orthogonal to `Status` | — (pending live run) | — (pending live run) | — (pending live run) |

**GitHub Projects board state screenshot / notes:** — (pending live run)

---

### A.4 — Autonomous cycle: claim → implement → PR → merge → history

| Step | Expected | Observed | Divergence | Pass/Fail |
|---|---|---|---|---|
| A.4: Backlog read without local file | `listTasks("roadmap")` called; no local ROADMAP.md open | — (pending live run) | — (pending live run) | — (pending live run) |
| A.4: Planning gate enforced | Only tasks with `Ready = true` AND `.plan/<id>.md` committed are eligible | — (pending live run) | — (pending live run) | — (pending live run) |
| A.4: Claim — `moveTask` sets Status to `in_progress` | GitHub Projects board shows item in `In Progress` column during the cycle | — (pending live run) | — (pending live run) | — (pending live run) |
| A.4: PR opens on `task/<id>-<slug>` | PR branch matches the pattern; PR summary references Atelier ID and title | — (pending live run) | — (pending live run) | — (pending live run) |
| A.4: Reviewer fires and approves | `<reviewer-account>` leaves an APPROVED review; auto-merge proceeds | — (pending live run) | — (pending live run) | — (pending live run) |
| A.4: `appendHistoryEntry` sets Status to history bucket | After merge, GitHub Projects board shows item in `Done`/history column | — (pending live run) | — (pending live run) | — (pending live run) |
| A.4: No local HISTORY.md or IN_PROGRESS.md edited | No tracking file edits in the merged PR diff | — (pending live run) | — (pending live run) | — (pending live run) |
| A.4: Worktree cleaned up | `git wt list` shows no leftover `task/<id>-<slug>` worktree after merge | — (pending live run) | — (pending live run) | — (pending live run) |

---

### A.5 — GitHub Projects board state end-to-end

| Field | Expected after merge | Observed | Pass/Fail |
|---|---|---|---|
| Status (column) | history stateMap value (e.g. `Done`) | — (pending live run) | — (pending live run) |
| `Ready` field | true | — (pending live run) | — (pending live run) |
| `Atelier ID` | `#<id>` matching the task run | — (pending live run) | — (pending live run) |

**Board screenshot attached:** — (pending live run)

---

### Stage A — Overall verdict

| Thread | Pass/Fail | Notes |
|---|---|---|
| A — Full autonomous cycle on `github-project`-backed member (discover → plan → claim → implement → PR → merge → history via backend) | — (pending live run) | — |

---

## Stage B — Mixed-backend workspace aggregation + cross-repo `blocked_by`

### B.1 — Workspace configuration

| Step | Expected | Observed | Divergence | Pass/Fail |
|---|---|---|---|---|
| B.1: `/atelier:list-workspaces` shows `<ws-slug>` | Both `<gp-token>` and `<files-token>` listed as **configured** | — (pending live run) | — (pending live run) | — (pending live run) |

---

### B.2 — Workspace status (human-readable)

| Step | Expected | Observed | Divergence | Pass/Fail |
|---|---|---|---|---|
| B.2: `<files-token>` row | Shows a numeric open-task count (read from `ROADMAP.md`) | — (pending live run) | — (pending live run) | — (pending live run) |
| B.2: `<gp-token>` row — open-tasks column | Shows `backend:github-project`, not `0` and not a number | — (pending live run) | — (pending live run) | — (pending live run) |
| B.2: No false drift signal for `<gp-token>` | No drift warning/alert for the backend-tracked member | — (pending live run) | — (pending live run) | — (pending live run) |

**Exact `atelier-workspace-status` output (operator to paste):** — (pending live run)

---

### B.3 — Workspace status (JSON)

| Step | Expected | Observed | Divergence | Pass/Fail |
|---|---|---|---|---|
| B.3: JSON is valid | `atelier-workspace-status <ws-slug> --json \| jq .` exits 0 | — (pending live run) | — (pending live run) | — (pending live run) |
| B.3: `<files-token>` member has numeric `openTasks` | `"openTasks": <N>` (integer) | — (pending live run) | — (pending live run) | — (pending live run) |
| B.3: `<gp-token>` member has `"openTasks": null` | `"openTasks": null` — distinguishes "unknown (backend)" from `0` | — (pending live run) | — (pending live run) | — (pending live run) |
| B.3: `<gp-token>` member has `"backend": "github-project"` | `"backend": "github-project"` field present | — (pending live run) | — (pending live run) | — (pending live run) |

**Exact JSON snippet (operator to paste):** — (pending live run)

---

### B.4 — `atelier-resolve-dep`: `files → github-project` (blocker open)

| Step | Expected | Observed | Divergence | Pass/Fail |
|---|---|---|---|---|
| B.4: stdout | `backend-deferred` | — (pending live run) | — (pending live run) | — (pending live run) |
| B.4: exit code | `6` | — (pending live run) | — (pending live run) | — (pending live run) |
| B.4: AI-layer follow-up — `getTask` via backend | AI layer calls backend, task is open → reports dependent still **blocked** | — (pending live run) | — (pending live run) | — (pending live run) |

**Command run (operator to fill in):**
```bash
atelier-resolve-dep --workspace <ws-slug> --from ~/Work/<files-repo> --token <gp-token> --id <blocker-id>
```

**Actual stdout:** — (pending live run)
**Actual exit code:** — (pending live run)
**AI-layer verdict:** — (pending live run)

---

### B.5 — `files → github-project` blocker reaches history — dependent becomes eligible

| Step | Expected | Observed | Divergence | Pass/Fail |
|---|---|---|---|---|
| B.5: AI-layer follow-up after blocker moved to history | AI layer calls backend, task is in history bucket → reports dependent **satisfied** | — (pending live run) | — (pending live run) | — (pending live run) |
| B.5: Cross-repo-blocked section in workspace-status clears | Task no longer appears as cross-repo-blocked after blocker lands in history | — (pending live run) | — (pending live run) | — (pending live run) |

**AI-layer verdict (2nd check):** — (pending live run)

---

### B.6 — `atelier-resolve-dep`: `github-project → files` (blocker open)

| Step | Expected | Observed | Divergence | Pass/Fail |
|---|---|---|---|---|
| B.6: stdout (blocker open in `<files-repo>`) | `open` | — (pending live run) | — (pending live run) | — (pending live run) |
| B.6: exit code (blocker open) | `3` | — (pending live run) | — (pending live run) | — (pending live run) |
| B.6: stdout (blocker in `HISTORY.md`) | `satisfied` | — (pending live run) | — (pending live run) | — (pending live run) |
| B.6: exit code (blocker in `HISTORY.md`) | `0` | — (pending live run) | — (pending live run) | — (pending live run) |

**Command run (blocker open):**
```bash
atelier-resolve-dep --workspace <ws-slug> --from ~/Work/<gp-repo> --token <files-token> --id <files-task-id>
```

**Actual stdout (open):** — (pending live run)
**Actual exit code (open):** — (pending live run)
**Actual stdout (satisfied):** — (pending live run)
**Actual exit code (satisfied):** — (pending live run)

---

### B.7 — Full `atelier-resolve-dep` verdict summary

| Direction | Args | Expected stdout | Expected exit | Observed stdout | Observed exit | AI-layer verdict | Pass/Fail |
|---|---|---|---|---|---|---|---|
| `files → github-project` (blocker open) | `--token <gp-token> --id <open-id>` | `backend-deferred` | `6` | — (pending) | — (pending) | blocked | — (pending) |
| `files → github-project` (blocker in history) | `--token <gp-token> --id <closed-id>` | `backend-deferred` | `6` | — (pending) | — (pending) | satisfied | — (pending) |
| `github-project → files` (blocker open) | `--token <files-token> --id <open-id>` | `open` | `3` | — (pending) | — (pending) | n/a | — (pending) |
| `github-project → files` (blocker in HISTORY.md) | `--token <files-token> --id <closed-id>` | `satisfied` | `0` | — (pending) | — (pending) | n/a | — (pending) |

---

### Stage B — Overall verdict

| Thread | Pass/Fail | Notes |
|---|---|---|
| B — Mixed-backend workspace-status aggregation (no false 0/absent/drift) | — (pending live run) | — |
| B — Cross-repo `blocked_by` `files → github-project` (backend-deferred + AI-layer resolution) | — (pending live run) | — |
| B — Cross-repo `blocked_by` `github-project → files` (offline HISTORY.md resolution) | — (pending live run) | — |
| B — Dependent eligible only after blocker reaches history bucket | — (pending live run) | — |

---

## Overall M9 verdict

| Stage | Pass/Fail |
|---|---|
| Stage A — Full autonomous cycle on `github-project`-backed member | — (pending live run) |
| Stage B — Mixed-backend workspace aggregation + cross-repo `blocked_by` | — (pending live run) |
| **M9 closes (both stages pass)** | — (pending live run) |

---

## Unexpected findings / new bugs discovered

Record anything unexpected here — things not covered by the step tables above. Each finding should get a new bug or task opened.

| # | Step | What happened | New task opened? |
|---|---|---|---|
| — | — | — (pending live run) | — |

---

## Sign-off

**Live run completed by:** — (pending)
**Date:** — (pending)
**Conclusion:** — (pending)
