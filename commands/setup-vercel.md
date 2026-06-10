---
description: Install and configure the optional vercel-integration plugin so atelier agents can deploy and manage apps on Vercel. Wraps `atelier-setup-vercel`, adding the per-project `.env` capture that the non-TTY terminal invocation cannot offer.
allowed-tools: Bash(atelier-setup-vercel:*), Bash(atelier-vercel:*), Read(.env), Edit(.env), Write(.env)
---

You are running the `/atelier:setup-vercel` slash command — the interactive
front for the `atelier-setup-vercel` host-OS helper. Use it to set up
Vercel at install time or any time afterward.

## Steps

1. **Machine-wide setup.** Run:

   ```sh
   atelier-setup-vercel --non-interactive
   ```

   This installs `vercel-integration` from the `akalab-tech` catalog (if not
   already present), links its `atelier-vercel` CLI onto `PATH`, and merges the
   Vercel allowlist into atelier's user-level `settings.json` (never the
   per-task template).

2. **Per-project auth.** Vercel auth is per project. If the current directory is
   a project, wire its `.env`:
   - Read `.env` (create it if missing).
   - If `VERCEL_TOKEN` is absent, ask the operator for a Vercel access token
     (https://vercel.com/account/tokens) and add `VERCEL_TOKEN=<token>`. Never
     echo the token back.
   - Optionally add `VERCEL_ORG_ID` / `VERCEL_PROJECT_ID` for a fixed scope.
   - `.env` stays gitignored by atelier's `.env*` guardrail — never `git add` it.
   - If not inside a project, tell the operator to re-run from the project they
     want to deploy.

3. **Verify**: `atelier-vercel whoami`.

## Report

PATH link status, permissions merged, whether this project's `.env` now has
`VERCEL_TOKEN` (presence only — never the value), whether `vercel` is on PATH
(or runs via `pnpm dlx`), and the `whoami` result. Mention that `remove` /
`env-rm` / `project-rm` always ask for confirmation.
