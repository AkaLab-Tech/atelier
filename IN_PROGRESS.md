# In Progress

Active tasks for the current development cycle.

Workflow: `ROADMAP.md` → start a task → move here → finish → move to `HISTORY.md`.

When a PR closes a task, the **same PR** must update both `IN_PROGRESS.md` (remove) and `HISTORY.md` (add). Do not defer either to a follow-up commit on the protected branch after merge.

---

### M7.1.F54 — Coolify skill assumes manual deploy; must detect GitHub App auto-deploy

`[coolify-integration]` · Source: dogfood (2026-06-05) · **Change lands in the `coolify-integration` repo** ([skills/coolify/SKILL.md](../coolify-integration/skills/coolify/SKILL.md)), tracked here per the operator's decision.

**Status:** implemented — PR open at [coolify-integration#2](https://github.com/AkaLab-Tech/coolify-integration/pull/2). Move this entry to `HISTORY.md` once that PR merges. (Cross-repo: the closing PR lives in `coolify-integration`, so it cannot carry this repo's tracking update.)

The coolify skill's validate-and-fix flow assumes a deploy is always triggered manually via `atelier-coolify deploy <uuid>`. In practice the apps are wired through Coolify's GitHub App so that a push to `main` (or the per-env branch) **auto-deploys** — assuming a manual deploy is wrong, can double-trigger, and misleads diagnosis. The skill should read the app's deployment configuration (connected git source, auto-deploy flag, watched branch) and remember that a push already deploys, instead of assuming.

**Scope:**

- [x] Add a way to read an app's git/auto-deploy config via `atelier-coolify` (git source connected, auto-deploy enabled, watched branch) — new `deploy-mode` subcommand; auto-deploy flag also surfaced in `status`.
- [x] Update the skill flow: before suggesting a manual `deploy`, check whether the app auto-deploys on push; if so, a `git push` to the watched branch *is* the deploy — say so rather than calling `deploy`.
- [x] Persist / record the per-app deploy mode so the skill does not re-assume on every run — cached per project in `.coolify-deploy-mode.json` (`COOLIFY_DEPLOY_MODE_FILE`); `--refresh` re-queries.
- [x] Keep the manual `deploy <uuid>` path for apps that genuinely lack auto-deploy.

**Acceptance:** on an app configured with the GitHub App + auto-deploy on a branch, the skill reports that pushing the watched branch deploys (and does not propose a redundant manual `deploy`); on an app without auto-deploy, the manual flow is unchanged.
