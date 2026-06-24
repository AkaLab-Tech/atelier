# TASK_029 — `atelier-update` hangs at the plugin-cache refresh (`claude plugin update` missing `</dev/null`)

**Type:** `bug` · **Priority:** P2 · **Estimate:** `~TODO`

**Problem.** `refresh_plugin_cache()` in `scripts/atelier-update` runs, for each plugin:

```sh
CLAUDE_CONFIG_DIR="$cfg" claude plugin update atelier@akalab-tech 2>/dev/null
CLAUDE_CONFIG_DIR="$cfg" claude plugin update claude-roadmap-tools@akalab-tech 2>/dev/null
```

`claude plugin update` emits an interactive confirmation. Because the call sends stderr to `/dev/null` (hiding the prompt) but leaves **stdin attached to the terminal**, the command blocks forever waiting on input the operator can't see they owe it. Surfaced 2026-06-24: a manual `atelier-update` reached `==> refreshing Claude Code plugin cache` → `Checking for updates for plugin "atelier@akalab-tech" at user scope…` and hung with a blinking cursor. Running the exact same command with `</dev/null` completed in seconds (`Plugin "atelier" updated from 0.34.0 to 0.35.0`).

**Impact.** Every `atelier-update` run (and the `/atelier:update` command that wraps it) hangs at the **final** step on any host where `claude plugin update` prompts. The clone pull and artifact resync have already succeeded by then, so the on-disk clone is correct — but the Claude Code plugin cache never lands on the new version, so open and future sessions keep loading the **old** plugin until the operator Ctrl-Cs and re-runs the update by hand. This silently defeats the whole point of the update flow (landing the new agents/skills/commands in the plugin cache).

**Root cause.** Missing `</dev/null` stdin redirect on the `claude plugin update` invocations. The sibling `scripts/atelier-uninstall` already guards its `claude plugin uninstall` with `</dev/null` for exactly this reason (see its subshell comment); `refresh_plugin_cache()` omitted the same guard.

**Scope (sketch).**
- Add `</dev/null` to both `claude plugin update` calls in `refresh_plugin_cache()` (`atelier@akalab-tech` and `claude-roadmap-tools@akalab-tech`).
- Audit sibling helpers for the same hazard: `atelier-setup-coolify`, `atelier-setup-neon`, `atelier-setup-vercel` each run `claude plugin install` / `claude plugin marketplace add` without `</dev/null`; harden consistently so a prompt can't hang a non-interactive run.
- Add a regression guard — a structural `hooks/tests/*.test.sh` asserting every `claude plugin (update|install|uninstall)` mutation under `scripts/` is invoked with stdin redirected from `/dev/null`.

**Acceptance.** `atelier-update` (and `/atelier:update`) completes the plugin-cache refresh **non-interactively** — no hang — landing the Claude Code plugin cache on the clone's version, with the run reaching `claude plugin update …: OK` without operator input. Covered by a structural test that fails if any `claude plugin` mutation under `scripts/` lacks `</dev/null`.
