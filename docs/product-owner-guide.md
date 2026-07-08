# Product Owner Guide — Writing `ROADMAP.md`

A reference for whoever owns the backlog — deciding *what* gets built and *why* — even if you've never written code. This doc is about the file, not the tool: it explains the exact grammar `ROADMAP.md` uses so atelier can parse your intent correctly.

If you haven't set up atelier yet, start with the [Operator Guide](operator-guide.md) instead — it covers install, your first task, and the day-to-day flow. Come back here whenever you're adding or editing tasks and want the format rules in one place.

---

## The three sections

`ROADMAP.md` has exactly three headings, always in this order:

```markdown
## 🔥 P0 — Blockers

## 🎯 P1 — Next

## 💭 P2 — Backlog
```

- **P0 — Blockers.** Things that block shipping right now: a bug users are hitting, a broken build, a security hole. **Keep this list small.** If P0 grows past a handful of items, it stops meaning "blocker" and starts meaning "everything is urgent," which helps no one — including atelier, which always works P0 before P1 before P2.
- **P1 — Next.** The work you want done soon — this sprint, this month. Most new tasks land here.
- **P2 — Backlog.** Ideas and nice-to-haves you don't want to lose track of, but nobody's waiting on. atelier only picks these up once P0 and P1 are empty (or blocked).

atelier always works top-down: every P0 item before any P1 item, every P1 item before any P2 item.

---

## Writing one task — the item line

Every task is one checkbox line with this shape:

```
- [ ] [ready] `type` Title `#id` `~estimate` `blocked_by:#NN`
```

Reading it left to right:

| Part | Meaning |
|---|---|
| `- [ ]` | An empty checkbox. atelier flips it to `[x]` when the task ships. **You never write `[x]` yourself.** |
| `[ready]` | A marker that says "this task has an approved plan and can be picked up." **You never add this yourself either** — see [The `[ready]` gate](#the-ready-gate) below. When you write a new task, just leave it out. |
| `` `type` `` | What kind of work this is, in backticks. One of five values — see the next section. |
| Title | A plain sentence describing what you want. No special punctuation needed. |
| `` `#id` `` | The task's identifier, in backticks, e.g. `` `#23` ``. Pick the next number you haven't used yet, and never reuse an old one — other tasks may refer back to it via `blocked_by`. |
| `` `~estimate` `` | Optional. Your rough size guess — `` `~30m` ``, `` `~2h` ``, `` `~1d` ``. Leave it off if you have no idea; nothing breaks. |
| `` `blocked_by:...` `` | Optional. Says this task can't start until another one is finished. Covered in [Blocking one task on another](#blocking-one-task-on-another). |

Only `- [ ]`, the type, the title, and `#id` are required. `[ready]`, the estimate, and `blocked_by` are optional (and `[ready]` is one you should never add by hand).

### The five type tags, one worked example each

```markdown
- [ ] `bug` Login redirects to 404 after OAuth `#23` `~2h`
  - Repro: Chrome, new account, click "Login with Google" → 404.
  - Acceptance: redirects to dashboard + e2e test covers flow.

- [ ] `feat` Export reports to CSV `#24` `~4h`
  - Button "Export" at `/reports`, downloads CSV with active filters applied.

- [ ] `chore` Upgrade Vite to v6 `#25` `~1h`

- [ ] `docs` Add a "getting started" page for new API consumers `#26` `~2h`
  - Acceptance: page lives at `/docs/getting-started`, covers auth + first request + rate limits, with a copy-pasteable curl example.

- [ ] `refactor` Extract the duplicated invoice-tax logic into one shared function `#27` `~3h`
  - Acceptance: `computeTax()` used by both the checkout and the admin invoice screens; no behavior change; existing tests still pass.
```

- `bug` — something is broken that used to work, or never worked as intended.
- `feat` — new capability that didn't exist before.
- `chore` — maintenance work with no user-visible behavior change (upgrades, cleanup, config).
- `docs` — documentation only — no application code changes.
- `refactor` — restructuring existing code without changing what it does (usually invisible to users, but real work).

If you're not sure which tag fits, pick the closest one — atelier's planning step will flag it if it's clearly wrong, and getting it perfect isn't critical to how the task gets done.

---

## Acceptance criteria and other sub-bullets

Indent extra context two spaces under the item line. Three common shapes:

- **`Repro:`** — for bugs, the exact steps to see the problem. The more precise, the less atelier has to guess.
- **`Acceptance:`** — what "done" looks like, in terms someone can actually check. This is the most important sub-bullet you'll write.
- **Free-form notes** — anything else worth knowing: a design decision, a link to a mockup, a constraint ("must work without JavaScript").

**What makes a good acceptance bullet:** concrete and testable — something a reviewer (human or AI) can check off as true or false without asking you a follow-up question.

```markdown
Acceptance: redirects to dashboard + e2e test covers flow.        ✅ testable
Acceptance: page lives at `/docs/getting-started`, covers auth
  + first request + rate limits, with a copy-pasteable curl
  example.                                                        ✅ testable, specific

Acceptance: login should work better.                             ❌ not testable — "better" how?
Acceptance: make the export feature good.                         ❌ vague — good by what measure?
```

A useful test: if two different people could read your acceptance bullet and disagree about whether the finished work satisfies it, rewrite it with more specifics — a URL, a button label, a measurable limit, an example input/output.

---

## Blocking one task on another

Use `blocked_by` when one task genuinely cannot start until another one is finished — not just "related to," but "depends on."

**Same project (intra-repo):** reference the other task's id directly.

```markdown
- [ ] `feat` Export reports to CSV `#24` `~4h` `blocked_by:#23`
```

Task `#24` won't be picked up until task `#23` has shipped.

**A different repo in the same workspace (cross-repo):** if your product is split across several repos grouped into a workspace (see the Operator Guide's [Working with multi-repo projects](operator-guide.md#working-with-multi-repo-projects-workspaces) section), reference the sibling repo's short name (its **workspace token**) before the `#`:

```markdown
- [ ] `feat` Use the new orders API `#10` `blocked_by:backend#23`
```

Task `#10` here (in, say, `frontend/ROADMAP.md`) waits until task `#23` in the `backend` repo is finished. `/atelier:list-workspaces` shows you the token assigned to each repo.

You can combine both: `blocked_by:#23,backend#5`.

---

## The `[ready]` gate

`[ready]` is the one part of the item line you should **never** add by hand.

Here's why: atelier refuses to start work on any task that doesn't have an approved plan behind it. A plan is what you get by running `/atelier:plan-task <id>` — atelier reads the task, studies the codebase, and drafts a short plan (approach, what it'll touch, how it'll check its own work). You read that plan and approve it. Only on your explicit approval does atelier write `.plan/<id>.md` and add the `[ready]` marker to the item line, in one commit.

So the flow is: **you write the task → you run `/atelier:plan-task <id>` → you approve the draft plan → atelier marks it `[ready]`.** If you hand-write `[ready]` on a task with no approved plan behind it, atelier's tooling treats that as an inconsistency (a `[ready]` marker without a matching plan file) and skips the task anyway — so there's no shortcut to gain by adding it yourself. Just write the task without `[ready]` and let the planning step add it.

---

## Epics — when one task is really several

Sometimes a task is too big for one pull request. atelier caps how large a single change can be (roughly: over 200 lines *and* over 10 files starts requiring human review instead of auto-merging) — if your task sounds like it needs several unrelated pieces of work, or your acceptance bullet is turning into a paragraph, it's a sign to split it.

Write it as an **epic**: a container line prefixed `Epic:`, with sub-tasks indented two spaces underneath, each sub-task using a letter suffix on the parent's id.

```markdown
- [ ] `feat` Epic: Landing page editor `#42` `~6h`
  - [ ] `feat` schema + API endpoints `#42a` `~2h`
  - [ ] `feat` admin form UI `#42b` `~2h` `blocked_by:#42a`
  - [ ] `feat` public landing renderer `#42c` `~2h` `blocked_by:#42a`
```

- Each sub-task is planned, claimed, and shipped as its own independent pull request.
- Sub-tasks can `blocked_by` each other (e.g. the UI needs the API endpoints to exist first).
- The epic line's checkbox is **derived** — it flips to `[x]` automatically once every sub-task is done. Don't check it yourself.
- Sub-tasks are `[ready]`-gated individually, same as top-level tasks; the epic line itself is never marked `[ready]` (it's a container, not a claimable unit).

If you're unsure whether to split: a task that's naturally "and" ("build the schema *and* the admin UI *and* the public page") is usually an epic; a task that's one contiguous piece of work, even a large one, can often stay a single item with a generous `~estimate`.

---

## A full worked example

Copy this as a starting template for a new project's `ROADMAP.md`:

```markdown
# Roadmap — acme-storefront

Backlog of work for this project. Tasks flow: ROADMAP.md → IN_PROGRESS.md → HISTORY.md.

## 🔥 P0 — Blockers

- [ ] `bug` Checkout fails for orders over $500 `#101` `~2h`
  - Repro: add 3+ items totaling >$500, click "Place order" → spinner never resolves.
  - Acceptance: order completes normally regardless of total; e2e test covers an over-$500 cart.

## 🎯 P1 — Next

- [ ] `feat` Add a "Save for later" button on cart items `#102` `~3h`
  - Button next to "Remove" on each cart line. Clicking it moves the item to a
    "Saved for later" list below the cart and removes it from the order total.
  - Acceptance: saved items persist across a page reload; moving an item back
    to the cart restores its quantity.

- [ ] `feat` Epic: Order history page `#103` `~5h`
  - [ ] `feat` API endpoint returning a customer's past orders `#103a` `~2h`
  - [ ] `feat` order history UI at `/account/orders` `#103b` `~3h` `blocked_by:#103a`

- [ ] `chore` Upgrade the payment SDK to the latest major version `#104` `~2h` `blocked_by:#101`
```

Notice:
- No item carries `[ready]` — that gets added later, one task at a time, by `/atelier:plan-task <id>`.
- `#104` waits on `#101` (you don't want to touch the payment SDK before the checkout bug behind it is understood and fixed).
- `#103` is an epic because "a whole new page backed by a new API" is naturally two pieces of work with a dependency between them.
- P2 is simply empty here — that's fine; add it only when you have backlog ideas worth keeping.

---

## See also

- [Operator Guide](operator-guide.md) — install, first task, and the day-to-day loop.
- [PLAN.md §5](../PLAN.md) — the authoritative format specification this guide is a friendlier walkthrough of.
