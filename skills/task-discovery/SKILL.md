---
name: task-discovery
description: Parse a project's `ROADMAP.md` and pick the next task to work on. Use this skill whenever the user wants to start work, asks "what's next?", invokes `/atelier:next-task`, asks the orchestrator to plan a task, or you need to identify the highest-priority unblocked item from a `ROADMAP.md` formatted per PLAN.md §5 (P0/P1/P2 sections with `bug`/`feat`/`chore`/`docs`/`refactor` type tags, `#id`, `~estimate`, `blocked_by:` metadata). Returns the chosen task's id, title, type, priority, estimate, and acceptance criteria so the caller can route the task through the agent chain. Trigger this even if the user does not say "ROADMAP" explicitly — any phrasing about picking up the next thing to ship belongs here.
---

# task-discovery

A skill for picking the next task to work on from a project's `ROADMAP.md`.

> **Bash output handling — never retry on success.** When you query the filesystem or git state (`git wt list`, `git -C <path> status --porcelain`, `Read` against `ROADMAP.md`), a single successful invocation per question is enough. The Bash tool's UI may collapse long output with `… +N lines (ctrl+o to expand)` — that ellipsis is cosmetic; the full output is already in your context. Do **not** re-invoke the same command "to see the rest" — there is no rest, and repeated identical invocations create a loop the operator has to interrupt. If you need different data, run a *different* command.

## What this skill produces

A single structured result describing the chosen task, in this shape:

```text
id:          <#NN>            (e.g. "#42" or "#42a" for a sub-task)
title:       <imperative title from the line, no metadata>
type:        bug | feat | chore | docs | refactor
priority:    P0 | P1 | P2
estimate:    <as written, e.g. "~2h">   (may be empty)
blocked_by:  <as written, e.g. "#23">   (may be empty)
worktree:    task/<id-without-#>-<kebab-slug-of-title>
ready:       true | false           (whether the line carries the [ready] marker)
plan_path:   .plan/<id-without-#>.md  (the approved plan artifact; present when ready)
acceptance:  <bullet list extracted from the sub-bullets>
context:     <any "Repro:", "Notes:", or other sub-bullets that aren't the
              acceptance line — verbatim, so the implementer keeps the wording>
epic_parent: <#NN-of-parent-epic>  (present only when the picked task is a sub-task)
epic_siblings: [<#id>, ...]         (present only when the picked task is a sub-task —
                                     full list of sibling sub-tasks for orchestrator context)
```

When no eligible task exists (everything is `[x]`, or every unchecked item has an open `blocked_by`), return that explicitly — do **not** invent a task.

## ROADMAP.md format (PLAN.md §5, summary)

The roadmap is grouped by priority. The agent picks **the first unchecked item of the highest-priority section with no open `blocked_by` dependency**.

```markdown
# Roadmap — <project>

## 🔥 P0 — Blockers

- [ ] `bug` Login redirects to 404 after OAuth `#23` `~2h`
  - Repro: Chrome, new account, click "Login with Google" → 404.
  - Acceptance: redirects to dashboard + e2e test covers flow.

## 🎯 P1 — Next

- [ ] `feat` Export reports to CSV `#42` `~4h` `blocked_by:#23`
  - Button "Export" at `/reports`, downloads CSV with active filters applied.

## 💭 P2 — Backlog

- [ ] `chore` Upgrade Vite to v6 `#48` `~1h`
```

Line conventions:
- `- [ ]` or `- [x]` checkbox at the start.
- A backtick-quoted **type tag**: `` `bug` `` / `` `feat` `` / `` `chore` `` / `` `docs` `` / `` `refactor` ``.
- An imperative **title** (free text, until the next backtick group).
- A backtick-quoted **id**: `` `#NN` ``.
- Optional **estimate**: `` `~Nh` `` or `` `~Nd` ``.
- Optional **blocked_by**: `` `blocked_by:#NN` `` (single id) or `` `blocked_by:#NN,#MM` `` (multiple). An id may carry a **member token** for a cross-repo dependency: `` `blocked_by:backend#23` `` means task `#23` in the workspace sibling `backend` (see "Cross-repo `blocked_by`" below). Intra- and cross-repo ids may be mixed: `` `blocked_by:#5,backend#23` ``.
- Sub-bullets below the line are context: `Repro:`, `Acceptance:`, free-form notes.

Sections are headed `## 🔥 P0 — …`, `## 🎯 P1 — …`, `## 💭 P2 — …` (the emoji is not load-bearing — match on the `P0`/`P1`/`P2` token, which is what determines priority).

## Selection algorithm

1. **Parse top-to-bottom.** Walk sections in declared order; the order of `P0 → P1 → P2` is the priority order.
2. **Within each section**, walk items top-to-bottom. The first unchecked (`- [ ]`) item is the candidate. **If the item is an epic** (title starts with the literal `Epic:` token — see PLAN.md §5), descend into its sub-tasks before considering the epic itself; the candidate becomes the first unchecked sub-task. The epic line is never claimed directly — it is a container, not a unit of work.
3. **Filter `blocked_by`.** A candidate is eligible only if **every** blocker — intra-repo and cross-repo — is satisfied. If any blocker is unsatisfied, skip the candidate and look at the next item in the same section.
   - **Intra-repo** (`#NN`, no token): satisfied only if that id is already `[x]` somewhere in the same `ROADMAP.md`. For sub-tasks, resolve against **sibling sub-tasks first** (`#42b blocked_by:#42a` looks within the same epic), then fall back to the global scope.
   - **Cross-repo** (`<token>#NN`): resolve **offline** with the `atelier-resolve-dep` helper instead of reading the local file. Run, with `<project-root>` being the directory that contains this `ROADMAP.md`:
     ```bash
     atelier-resolve-dep --from <project-root> --token <token> --id <#NN>
     ```
     Exit `0` → blocker merged in the sibling member → satisfied. Any non-zero exit → **not** satisfied, skip the candidate. The verdict word on stdout (`open` / `unknown-token` / `unknown-id`) explains why; carry it into the "no eligible task" report so the operator can act (a typo'd id or a token that is not a workspace member is a roadmap bug, not just an open dependency). If the helper is unavailable or `<project-root>` is not part of any workspace, a `<token>#id` blocker is unresolvable — treat the candidate as blocked and surface that the project is not in a workspace.
4. **Filter `[ready]` (planning gate).** For the **autonomous flow** (the skill invoked by `task-orchestrator` or `/atelier:next-task`), a candidate is eligible only if its line carries the literal `[ready]` marker **and** a committed `.plan/<id>.md` exists in the project root. An unchecked task without `[ready]` is **silently skipped** the same way a `blocked_by`-gated task is — it is backlog the product lead has not planned yet via `/atelier:plan-task`. A line marked `[ready]` whose `.plan/<id>.md` is missing is an **inconsistency**: surface it (`ready-without-plan: <#id>`) and treat the candidate as not eligible. See "When is the `[ready]` gate in effect?" below — it does **not** apply to atelier's own dev roadmap.
5. **Filter `[OVERSIZE]` and `[BLOCKED]` markers.** A candidate whose heading line contains either marker is **silently skipped** (the operator owns the resolution). Same rule applies to sub-tasks.
6. **Move on to the next section** only when the current one has no eligible candidates left.
7. **No eligible task anywhere** → return the reason precisely: *"no planned tasks to claim — every unchecked item is unplanned (run `/atelier:plan-task <id>`), blocked by another open item, or everything is done"*. Do not pick an unplanned or blocked item just to keep busy.

### When is the `[ready]` gate in effect?

The `[ready]` filter (step 4) governs the **autonomous selection path** on operator-managed projects (PLAN.md §5 P0/P1/P2 roadmaps): the orchestrator and `/atelier:next-task` only ever claim planned, approved tasks. It does **not** apply to:

- **Atelier's own dev roadmap** (this repo's `## High / Medium / Low Priority` layout — see Edge cases below). That roadmap is maintained by the human maintainer and uses no `[ready]` markers; treat every unchecked item as selectable.
- **Direct operator queries** ("what's next?") — see "How the caller should use the result": there you *show* unplanned items too, flagged as `unplanned — run /plan-task`, rather than hiding them. Hiding is only for the autonomous auto-pick.

### Epic-aware parsing

An epic block is recognised by **both** conditions:

- The title starts with `Epic:` (case-sensitive, with the colon).
- The next line is indented **two spaces** and starts with `- [ ]` or `- [x]` (a sub-task line).

When parsing:

- **Sub-task ids**: epic id `#42` may have sub-task ids `#42a`, `#42b`, ... (single letter suffix). Numeric suffixes (`#42-1`) are also valid; the parser accepts `^#<digits>[a-z]?(-\d+)?$`.
- **Auto-derived epic checkbox**: the epic line's `[ ]` / `[x]` is **computed from sub-tasks at read time** — every sub-task `[x]` → epic `[x]`, otherwise `[ ]`. Tooling never writes the epic checkbox manually; if the operator has done so and the derived state differs, surface the inconsistency and trust the derived value for selection.
- **Marker on the epic line vs sub-task**: a marker on the epic line (`[OVERSIZE]` / `[BLOCKED]`) applies to the whole epic (skip all sub-tasks). A marker on a single sub-task applies only to that sub-task.
- **Indentation tolerance**: accept 2 or 4 spaces of indentation for sub-tasks. Tabs are tolerated but normalised to 2 spaces. More than one level of nesting (sub-sub-tasks) is **not** part of v1 — surface as a warning and treat the line as a flat sibling of its parent.

## Cross-repo `blocked_by` (workspaces)

When the current project is a member of a workspace (see PLAN.md §15), a task may depend on a task in a **sibling** member via `blocked_by:<token>#id`. This never makes the task itself cross-repo — it is still one task in this repo, one worktree, one PR. The token only **orders** it after the sibling's task is merged.

- Resolution is **offline** via `atelier-resolve-dep` (selection step 3), which reads the sibling member's `HISTORY.md`; the `<id>` matches the sibling repo's own task-id convention, not a GitHub PR number.
- A cross-repo blocker is **satisfied** only when the helper exits `0` (the id is closed in the sibling's `HISTORY.md`). `open` (exit 3) keeps the candidate blocked; `unknown-token` (exit 4) and `unknown-id` (exit 5) are roadmap bugs — surface them rather than silently skipping forever.
- The skill never reaches into another repo's files directly; the helper is the only bridge, so this stays within the single-repo permission scope.

## Edge cases

- **Two repos worth of layout.** This repo (atelier itself) uses the simpler `## High / Medium / Low Priority` layout from the `roadmap-tracking-flow` skill, **not** the operator-facing P0/P1/P2 format. If the `ROADMAP.md` heading style is `## High Priority` etc., treat `High → P0`, `Medium → P1`, `Low → P2` for selection purposes but record the priority as written in the output. Both layouts use the same `- [ ]` / `- [x]` semantics.
- **No id on a line.** If a line lacks `` `#NN` ``, fall back to a slug-derived synthetic id (e.g. `#auto-csv-export`) and flag it in the output as `id-synthesized: true`. The product owner should add a real id.
- **`blocked_by:` references an id not present in the file.** Treat the referenced id as `unknown` and refuse the candidate. Surface the missing id so the operator can fix the roadmap. (For a cross-repo `<token>#id`, the equivalent signal is `atelier-resolve-dep` exiting `5 unknown-id` — same treatment: refuse and surface.)
- **Cross-repo `<token>` is not a workspace member** (`atelier-resolve-dep` exits `4 unknown-token`) or **the project is in no workspace.** Refuse the candidate and surface the misconfiguration — never treat an unresolvable cross-repo blocker as satisfied.
- **Multiple type tags on one line.** Keep the first one; warn about the extra.
- **Tabs vs spaces, em-dash vs hyphen.** Be tolerant. Use a permissive parser, not a strict regex from hell.

## Backend-aware backlog source (M9.1)

The selection algorithm above is **backend-agnostic**: it operates on a list of tasks regardless of where that list originates. The source differs by backend:

**Default `files` backend** — everything in this skill's "Selection algorithm" section applies as written. The backlog is `ROADMAP.md` as it exists on `origin/<base>` (read via `git show origin/<base>:ROADMAP.md` by `/next-task`). The indexed layout variant is also `FilesBackend` — `/next-task` expands the index links before passing the list to this skill.

**Non-`files` backend** — resolved via `atelier-task-backend <project-root>` (see `scripts/atelier-task-backend`). When the result is not `files`:

1. The caller (`/next-task`) obtains the backlog by calling `listTasks("roadmap")` per the `RoadmapBackend` contract (`docs/RoadmapBackend.md`). The returned list is passed to this skill in place of the ROADMAP.md content.
2. This skill applies **the same selection rules** (P0→P1→P2 order, `blocked_by`, planning gate, `[OVERSIZE]`/`[BLOCKED]` filters) to the returned list — the selection algorithm is **backend-agnostic and unchanged**. The `priority` field on each task maps to P0/P1/P2 using the backend's declared priority convention:
   - `LinearBackend`: Linear's numeric urgency field — `1` (Urgent) → P0, `2` (High) → P0, `3` (Medium) → P1, `4` (Low) → P2, `0` (No priority) → P2.
   - `GitHubProjectBackend`: the Project's `Priority` single-select custom field, whose option labels follow the P0/P1/P2 convention — options map to P0/P1/P2 by identity (P0 → P0, P1 → P1, P2 → P2), with absent or unrecognised values treated as P2.
3. **Planning gate for non-`files` backends.** In selection step 4, instead of checking a literal `[ready]` marker on a markdown line, this skill reads the backend's **Ready** field from the task record returned by `listTasks` (both `listTasks` and `getTask` fulfil their contract via the project-detail operation, which fetches each item with all its field values — so `Ready` rides along in the same record, no dedicated extra read is required). The `.plan/<id>.md` committed-file check is **identical across all backends**: the plan file is always a tracked repo file (§16.5). A task whose `Ready` field is set but whose `.plan/<id>.md` is absent is an inconsistency — surface it as `ready-without-plan: <id>` and treat the candidate as not eligible, the same way the `files` backend handles `[ready]` without a committed plan.
4. After selection, the caller enriches the chosen task by calling `getTask(id)`, which returns the full `body`, `priority`, `Ready` field value, and backend-specific metadata. The enriched result is merged into this skill's standard output shape.
5. The `roadmap-tracking-flow` skill is the execution layer for these calls; see that skill's SKILL.md for how `listTasks` and `getTask` are driven for each backend (`LinearBackend`'s Linear MCP path; `GitHubProjectBackend`'s hosted GitHub MCP path).

The claim registry (open `task/*` PRs) and the collision-avoidance logic are **identical for all backends** — only the backlog source changes.

## How the caller should use the result

The orchestrator (`task-orchestrator` agent) takes the returned record and:
1. Moves the task block from `ROADMAP.md` to `IN_PROGRESS.md` (files backend) or calls `moveTask(id, "roadmap", "in_progress")` (non-files backend).
2. Invokes `git-wt` with the `worktree` field to create the per-task worktree.
3. Hands `acceptance` and `context` to `implementer` as the spec.

When this skill is invoked **directly by the operator** ("what's next?"), present the result in a short table — id, title, type, priority, estimate, and a **planned?** column (`[ready]` vs `unplanned — run /plan-task`). Show unplanned high-priority items too, so the operator sees what to plan next; do not hide them the way the autonomous auto-pick does. Then ask whether to plan or claim, rather than auto-claiming. A task can only be claimed once it is `[ready]`.

