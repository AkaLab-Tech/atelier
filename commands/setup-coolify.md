---
description: Install and configure the optional coolify-integration plugin so atelier agents can deploy and manage apps on a VPS-hosted Coolify instance. Wraps `atelier-setup-coolify`, adding the per-project `.env` capture that the non-TTY terminal invocation cannot offer.
allowed-tools: Bash(atelier-setup-coolify:*), Bash(atelier-coolify:*), Read(.env), Edit(.env), Write(.env)
---

You are running the `/atelier:setup-coolify` slash command — the interactive
front for the `atelier-setup-coolify` host-OS helper (M4.23). Use it to set up
Coolify at install time or any time afterward.

## Steps

1. **Machine-wide setup.** Run:

   ```sh
   atelier-setup-coolify --non-interactive
   ```

   This installs `coolify-integration` from the `akalab-tech` catalog (if not
   already present), links its `atelier-coolify` CLI onto `PATH`, and merges the
   Coolify allowlist into atelier's user-level `settings.json` (never the
   per-task template).

2. **Per-project auth.** Coolify auth is per project so one operator can deploy
   different projects to different instances. If the current directory is a
   project, wire its `.env`:
   - Read `.env` (create it if missing).
   - If `COOLIFY_BASE_URL` is absent, ask the operator for this project's
     Coolify instance URL (e.g. `https://coolify.example.com`) and add it.
   - If `COOLIFY_API_TOKEN` is absent, ask for this project's Coolify API token
     and add it. Never echo the token back.
   - `.env` stays gitignored by atelier's `.env*` guardrail — never `git add` it.
   - If not inside a project, tell the operator to re-run this command from the
     project they want to deploy.

3. **Verify** the connection if both are set: `atelier-coolify version`.

## Report

PATH link status, permissions merged, whether this project's `.env` now has
`COOLIFY_BASE_URL` + `COOLIFY_API_TOKEN` (token presence only — never the
value), and the connection check result. Mention that gated operations
(`create-app-public`, `delete-app`) always ask for confirmation.
