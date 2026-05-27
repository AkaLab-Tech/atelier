---
name: task-discovery
description: Parse a project's `ROADMAP.md` and pick the next task to work on. Use this skill whenever the user wants to start work, asks "what's next?", invokes `/next-task`, asks the orchestrator to plan a task, or you need to identify the highest-priority unblocked item from a `ROADMAP.md` formatted per PLAN.md §5 (P0/P1/P2 sections with `bug`/`feat`/`chore`/`docs`/`refactor` type tags, `#id`, `~estimate`, `blocked_by:` metadata). Returns the chosen task's id, title, type, priority, estimate, and acceptance criteria so the caller can route the task through the agent chain. Trigger this even if the user does not say "ROADMAP" explicitly — any phrasing about picking up the next thing to ship belongs here.
---

# task-discovery

A skill for picking the next task to work on from a project's `ROADMAP.md`.

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
- Optional **blocked_by**: `` `blocked_by:#NN` `` (single id) or `` `blocked_by:#NN,#MM` `` (multiple).
- Sub-bullets below the line are context: `Repro:`, `Acceptance:`, free-form notes.

Sections are headed `## 🔥 P0 — …`, `## 🎯 P1 — …`, `## 💭 P2 — …` (the emoji is not load-bearing — match on the `P0`/`P1`/`P2` token, which is what determines priority).

## Selection algorithm

1. **Parse top-to-bottom.** Walk sections in declared order; the order of `P0 → P1 → P2` is the priority order.
2. **Within each section**, walk items top-to-bottom. The first unchecked (`- [ ]`) item is the candidate. **If the item is an epic** (title starts with the literal `Epic:` token — see PLAN.md §5), descend into its sub-tasks before considering the epic itself; the candidate becomes the first unchecked sub-task. The epic line is never claimed directly — it is a container, not a unit of work.
3. **Filter `blocked_by`.** A candidate is eligible only if every id in its `blocked_by:` is already `[x]` somewhere in the same `ROADMAP.md`. If any blocker is still `[ ]`, skip the candidate and look at the next item in the same section. For sub-tasks, `blocked_by` is resolved against **sibling sub-tasks first** (`#42b blocked_by:#42a` looks within the same epic), then falls back to the global scope.
4. **Filter `[OVERSIZE]` and `[BLOCKED]` markers.** A candidate whose heading line contains either marker is **silently skipped** (the operator owns the resolution — see M7.1.F26 and M7.1.F27.1). Same rule applies to sub-tasks.
5. **Move on to the next section** only when the current one has no eligible candidates left.
6. **No eligible task anywhere** → return "no work to pick up — every unchecked item is blocked by another open item, or everything is done". Do not pick a blocked item just to keep busy.

### Epic-aware parsing

An epic block is recognised by **both** conditions:

- The title starts with `Epic:` (case-sensitive, with the colon).
- The next line is indented **two spaces** and starts with `- [ ]` or `- [x]` (a sub-task line).

When parsing:

- **Sub-task ids**: epic id `#42` may have sub-task ids `#42a`, `#42b`, ... (single letter suffix). Numeric suffixes (`#42-1`) are also valid; the parser accepts `^#<digits>[a-z]?(-\d+)?$`.
- **Auto-derived epic checkbox**: the epic line's `[ ]` / `[x]` is **computed from sub-tasks at read time** — every sub-task `[x]` → epic `[x]`, otherwise `[ ]`. Tooling never writes the epic checkbox manually; if the operator has done so and the derived state differs, surface the inconsistency and trust the derived value for selection.
- **Marker on the epic line vs sub-task**: a marker on the epic line (`[OVERSIZE]` / `[BLOCKED]`) applies to the whole epic (skip all sub-tasks). A marker on a single sub-task applies only to that sub-task.
- **Indentation tolerance**: accept 2 or 4 spaces of indentation for sub-tasks. Tabs are tolerated but normalised to 2 spaces. More than one level of nesting (sub-sub-tasks) is **not** part of v1 — surface as a warning and treat the line as a flat sibling of its parent.

## Edge cases

- **Two repos worth of layout.** This repo (atelier itself) uses the simpler `## High / Medium / Low Priority` layout from the `roadmap-tracking-flow` skill, **not** the operator-facing P0/P1/P2 format. If the `ROADMAP.md` heading style is `## High Priority` etc., treat `High → P0`, `Medium → P1`, `Low → P2` for selection purposes but record the priority as written in the output. Both layouts use the same `- [ ]` / `- [x]` semantics.
- **No id on a line.** If a line lacks `` `#NN` ``, fall back to a slug-derived synthetic id (e.g. `#auto-csv-export`) and flag it in the output as `id-synthesized: true`. The product owner should add a real id.
- **`blocked_by:` references an id not present in the file.** Treat the referenced id as `unknown` and refuse the candidate. Surface the missing id so the operator can fix the roadmap.
- **Multiple type tags on one line.** Keep the first one; warn about the extra.
- **Tabs vs spaces, em-dash vs hyphen.** Be tolerant. Use a permissive parser, not a strict regex from hell.

## How the caller should use the result

The orchestrator (`task-orchestrator` agent) takes the returned record and:
1. Moves the task block from `ROADMAP.md` to `IN_PROGRESS.md`.
2. Invokes `git-wt` with the `worktree` field to create the per-task worktree.
3. Hands `acceptance` and `context` to `implementer` as the spec.

When this skill is invoked **directly by the operator** ("what's next?"), present the result in a short table — id, title, type, priority, estimate — and ask whether to claim it, rather than auto-claiming.

