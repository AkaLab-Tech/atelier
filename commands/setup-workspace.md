---
description: Group several already-configured atelier projects into a workspace so the operator can route tasks, see aggregated status, and express cross-repo `blocked_by:<token>#id` dependencies. Wraps the `atelier-setup-workspace` host-OS helper, adding interactive member confirmation and driving `/atelier:setup-project` for any member that is not yet a registered project.
argument-hint: "<name> (--members <p1,p2,...> | --discover <parent-dir>) [--policy <auto|ask>] [--yes|-y]"
allowed-tools: Bash(atelier-setup-workspace:*), AskUserQuestion, SlashCommand(/atelier:setup-project)
---

You are running the `/atelier:setup-workspace` slash command — the interactive front for the `atelier-setup-workspace` host-OS helper. A workspace is a thin grouping over single-repo projects: every task still runs in one worktree of one member and produces one PR. The helper does all registry writes; this command only selects/confirms members and configures any that are not yet atelier projects.

## Interaction mode (read once)

You are **non-interactive** if `$ARGUMENTS` contains `--yes` or `-y` (as a whole token), or `$ATELIER_AUTO` is set (probe with `env | grep -E '^ATELIER_AUTO='`). Otherwise you are **interactive**. In non-interactive mode never use `AskUserQuestion`; auto-resolve per the inline rule, preferring a clear stop over a guess.

## Step 1 — parse arguments

From `$ARGUMENTS` extract: the workspace `<name>` (the first non-flag token), and exactly one selection mode — `--members <p1,p2,...>` or `--discover <parent-dir>`. Strip `--yes`/`-y` before parsing.

- If `<name>` is missing → stop and ask for it (interactive) or error (non-interactive).
- If **both** `--members` and `--discover` are present → stop with an error; they are mutually exclusive.
- If **neither** is present:
  - Interactive: ask the operator via `AskUserQuestion` whether to **list explicit member paths** (primary) or **auto-discover under a parent folder**, then collect the paths or the parent dir.
  - Non-interactive: stop with an error naming both forms.

## Step 2 — resolve the member set

**Explicit (`--members`):** use the paths as given.

**Discover (`--discover <parent>`):** enumerate candidates read-only, then confirm:

```bash
atelier-setup-workspace --list-discoverable <parent>
```

Each line is `<path>\t<registered|unregistered>`.
- Interactive: present the candidates with `AskUserQuestion` (multi-select) so the operator confirms or prunes. Skip nothing silently.
- Non-interactive: take every discovered repo.

## Step 2.5 — decision policy (one prompt for the whole workspace)

A workspace groups projects so the operator configures them together — that includes the decision-broker policy. Capture it ONCE here and let the helper propagate it to every member's `.atelier.json`, instead of making the operator run `/atelier:set-policy` per repo (and instead of every member silently defaulting to `ask` because the cascaded `/atelier:setup-project` ran headless).

- **Interactive:** before registering, ask via `AskUserQuestion` — *"Decision-broker policy for the whole workspace? `auto` = atelier decides strategic calls itself (most autonomous); `ask` = atelier asks you each time; or skip and set it per project later."* Map the answer to a `--policy` value (`auto` / `ask`), or omit `--policy` entirely if the operator chooses "set later".
- **Non-interactive:** if `$ARGUMENTS` carries `--policy <value>`, forward it verbatim. Otherwise omit `--policy` — do NOT guess; preserve each member's existing policy.

`--policy` sets `decisionPolicy.default` in each member's working `.atelier.json` (preserving `_comment` / `byCategory`). Because the decision broker reads `.atelier.json` from each task's **worktree** (branched from the base), remind the operator the change must be **committed to each member's base branch** to take effect in the autonomous cycle — the helper writes the working file; committing is theirs.

## Step 3 — register the workspace

Invoke the helper once with the resolved selection (pass `--discover <parent>` straight through when the operator did not prune; otherwise pass the confirmed paths as `--members`). Forward `--yes` when non-interactive, and `--policy <value>` when Step 2.5 resolved one.

```bash
atelier-setup-workspace --name <name> --members <p1,p2,...> [--policy <auto|ask>]
```

Handle the exit code:

- **0** → success. Relay the helper's stdout verbatim and stop.
- **3** → one or more members are not registered projects. The helper printed `atelier-needs-setup=<path>` lines. For **each** such path, run `/atelier:setup-project <path>` to configure it, then re-invoke the same `atelier-setup-workspace` command. In non-interactive mode, `/atelier:setup-project` of a brand-new project requires `--mode=existing` (it cannot interview); pass it through, and if a member genuinely needs the new-project interview, stop and tell the operator to run `/atelier:setup-project <path>` manually first. If a member carries a pre-atelier (non-atelier-managed) `.claude/settings.json`, `/atelier:setup-project` preserves it and warns — atelier's permission model never reaches disk, so the autonomous flow would stall. Confirm with the operator, then re-run that member's `/atelier:setup-project <path> --override` to replace it (the existing file is backed up with a timestamp). Never pass `--override` without operator confirmation — it overwrites their file.
- **2** → refusal (duplicate token, member already in another workspace, name collision). Surface the helper's message verbatim and stop. For a token collision, tell the operator to re-run with `--token-for <path>=<token>`.
- **1** → unrecoverable error. Surface stderr verbatim and stop.

## Output

End with the helper's final success block (workspace name, root, member→token list). One status line is enough; no extra commentary.

## Hard refusals

- **Never** write `workspaces.json` or `projects.json` yourself — only the helper and `/atelier:setup-project` touch the registries.
- **Never** invent member paths or auto-confirm a discovered set in interactive mode; the operator confirms.
- **Never** reconfigure or modify an existing member project beyond what `/atelier:setup-project` does on an unregistered one.
- **Never** pass both `--members` and `--discover` to the helper.
