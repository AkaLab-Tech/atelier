---
backend: github-project
backendId: PVTI_lADOCSHEDc4Bbr7mzgw8i3M
---
# TASK_031 — feat: /setup-project detects missing branch protection + offers an autonomous fix

- **Type / priority / estimate:** feat · P1 · ~3h
- **blocked_by:** none

## Why

On a repo whose default branch has **no branch-protection rule requiring approving
reviews**, GitHub never computes a net `reviewDecision`, so it stays **empty** even
after a genuine `APPROVED` review. atelier's auto-merge **guardrail #2** reads
`reviewDecision == APPROVED`, so it holds **forever** despite a real approval —
silently breaking autonomous merge on every task in that repo.

Observed repeatedly on AkaLab-Tech member repos: auto-merge held on PRs
#246 / #247 / #251 / #252 and a human had to finish each merge. On a freshly
configured project this defeats the entire autonomous cycle, and the failure mode
is invisible (looks like "waiting for review" forever, not a misconfiguration).

## What

When atelier is configured in a project for the **first time**
(`/atelier:setup-project`; also surface in `/atelier:doctor`), **detect** the gap,
**explain** it to the operator, and offer a fix that atelier can **execute
autonomously** — not just advice.

## Acceptance criteria

- [ ] `/atelier:setup-project` (and `/atelier:doctor`) probe the default branch's
      protection via `gh api repos/{owner}/{repo}/branches/{branch}/protection` and
      classify it: protected-sufficient / protected-insufficient (no required
      approving reviews) / unprotected / no-admin (the API returns 403 without
      repo-admin).
- [ ] When insufficient or unprotected, surface a clear explanation that ties the
      gap to the auto-merge guardrail-#2 hold (empty `reviewDecision`), and offer to
      apply the minimal rule.
- [ ] The offered path is **executable by atelier**: apply via
      `gh api -X PUT repos/{owner}/{repo}/branches/{branch}/protection` with
      `required_pull_request_reviews.required_approving_review_count=1`, **no**
      required status checks that do not exist, and configured so the atelier
      author/reviewer dual-identity flow still satisfies it — the `AtelierReviewer`
      APPROVED review must yield `reviewDecision: APPROVED`, and the `AtelierAuthor`
      push/merge path must not be locked out. Idempotent.
- [ ] Honor the decision-broker policy: under `auto`, apply autonomously; under
      `ask`, present the change and wait for the operator. (Aligns with the
      operator's full auto-merge autonomy preference.)
- [ ] **No-admin case** (token lacks repo-admin): do **not** fail setup — explain
      and print the exact manual steps / the `gh` command for the operator to run
      with an admin-scoped token.
- [ ] Idempotent + safe: never weaken an already-stronger existing rule; never
      enable protection that would block the bot author from merging its own
      approved PRs.

## Notes / risks

- Needs the `gh` token to carry **repo-admin** for the autonomous apply. On
  org-owned member repos the operator's own account has it; the `AtelierAuthor`
  bot identity may not — detect this and route to the no-admin path rather than
  erroring.
- Sibling of **#5** (`/setup-project detects CI/CD and offers to scaffold it`) —
  same detect-and-offer shape; consider sharing the detection/offer scaffolding.
- Root cause is documented in the operator's memory note
  `auto-merge-needs-branch-protection`.
