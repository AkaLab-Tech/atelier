#!/usr/bin/env bash
#
# atelier — UserPromptSubmit hook that nudges once per session when the
# atelier version this session loaded (the plugin root the hook runs from)
# differs from the version Claude Code has installed since (#486).
#
# After `atelier-update` / `claude plugin update`, open sessions keep running
# the old version until `/reload-plugins`. This hook runs from the session's
# loaded root, so once the operator reloads, CLAUDE_PLUGIN_ROOT points at the
# new version, the two versions match, and the nudge stops by itself.
#
# Cheap + FAIL-OPEN: jq and two local files only — no network, no git. Missing
# jq / files / unparsable JSON -> silent exit 0. Stamped once per
# (session_id, installed version) under $ATELIER_CONFIG_DIR/state/version-nudge/.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

ATELIER_CONFIG_DIR="${ATELIER_CONFIG_DIR:-$HOME/.claude-work}"
manifest="$ATELIER_CONFIG_DIR/plugins/installed_plugins.json"
loaded_manifest="${CLAUDE_PLUGIN_ROOT:-}/.claude-plugin/plugin.json"
[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$manifest" ] && [ -f "$loaded_manifest" ] || exit 0

installed="$(jq -r '.plugins["atelier@akalab-tech"][0].version // empty' "$manifest" 2>/dev/null || true)"
loaded="$(jq -r '.version // empty' "$loaded_manifest" 2>/dev/null || true)"
[ -n "$installed" ] && [ -n "$loaded" ] && [ "$installed" != "$loaded" ] || exit 0

session_id="$(jq -r '.session_id // empty' 2>/dev/null || true)"
[ -n "$session_id" ] || exit 0

# Keep the stamp filename filesystem-safe whatever the ids contain.
safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
stamp_dir="$ATELIER_CONFIG_DIR/state/version-nudge"
stamp="$stamp_dir/$(safe "$session_id")--$(safe "$installed")"
[ -e "$stamp" ] && exit 0
mkdir -p "$stamp_dir" 2>/dev/null && : >"$stamp" 2>/dev/null || exit 0

msg="atelier $installed is installed; this session runs $loaded. Type /reload-plugins, then /atelier:refresh."
jq -n --arg m "$msg" '{
  systemMessage: $m,
  hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: $m }
}'
exit 0
