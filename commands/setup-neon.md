---
description: Install and configure the optional neon-integration plugin so atelier agents can manage Neon serverless Postgres (branches, connection strings, projects). Wraps `atelier-setup-neon`, adding the per-project `.env` capture that the non-TTY terminal invocation cannot offer.
allowed-tools: Bash(atelier-setup-neon:*), Bash(atelier-neon:*), Read(.env), Edit(.env), Write(.env)
---

You are running the `/atelier:setup-neon` slash command — the interactive front
for the `atelier-setup-neon` host-OS helper. Use it to set up Neon at
install time or any time afterward.

## Steps

1. **Machine-wide setup.** Run:

   ```sh
   atelier-setup-neon --non-interactive
   ```

   This installs `neon-integration` from the `akalab-tech` catalog (if not
   already present), links its `atelier-neon` CLI onto `PATH`, and merges the
   Neon allowlist into atelier's user-level `settings.json` (never the per-task
   template).

2. **Per-project auth.** Neon auth is per project. If the current directory is a
   project, wire its `.env`:
   - Read `.env` (create it if missing).
   - If `NEON_API_KEY` is absent, ask the operator for a Neon API key
     (https://console.neon.tech/app/settings/api-keys) and add
     `NEON_API_KEY=<key>`. Never echo the key back.
   - Optionally add `NEON_PROJECT_ID` to scope commands to one project.
   - `.env` stays gitignored by atelier's `.env*` guardrail — never `git add` it.
   - If not inside a project, tell the operator to re-run from the project that
     uses Neon.

3. **Verify**: `atelier-neon me`.

## Report

PATH link status, permissions merged, whether this project's `.env` now has
`NEON_API_KEY` (presence only — never the value), whether `neonctl` is on PATH
(or runs via `pnpm dlx`), and the `me` result. Mention that `branch-delete` /
`project-create` / `project-delete` always ask for confirmation.
