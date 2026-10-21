#!/usr/bin/env bash
#
# atelier — hook that keeps an open session on the installed atelier version
# (#486, #505). Registered on SessionStart and UserPromptSubmit.
#
# After `atelier-update` / `claude plugin update`, open sessions keep running
# the old version until `/reload-plugins`, and nothing can type that for the
# operator (docs/research/session-reload.md). So the flow is:
#
#   SessionStart      records the version whose context was just injected
#                     ($state/<sid>.ctx) and prints nothing.
#   UserPromptSubmit  (a) installed != loaded: one nudge per (session,
#                         installed) telling the operator to type
#                         /reload-plugins.
#                     (b) installed == loaded but the injected context is older
#                         than loaded (the operator just reloaded): one-time
#                         additionalContext telling the model to finish the
#                         refresh (the /atelier:reload steps) before answering.
#                         Skipped when the prompt is /atelier:reload or
#                         /atelier:refresh, which do the same work themselves.
#
# Cheap + FAIL-OPEN: jq and local files only — no network, no git. Missing
# jq / files / unparsable JSON / no record of the context version -> silent
# exit 0. State lives under $ATELIER_CONFIG_DIR/state/version-nudge/.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

ATELIER_CONFIG_DIR="${ATELIER_CONFIG_DIR:-$HOME/.claude-work}"
manifest="$ATELIER_CONFIG_DIR/plugins/installed_plugins.json"
loaded_manifest="${CLAUDE_PLUGIN_ROOT:-}/.claude-plugin/plugin.json"
[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$loaded_manifest" ] || exit 0

input="$(cat 2>/dev/null || true)"
event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -n "$session_id" ] || exit 0

loaded="$(jq -r '.version // empty' "$loaded_manifest" 2>/dev/null || true)"
[ -n "$loaded" ] || exit 0

# Keep state filenames filesystem-safe whatever the ids contain.
safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
stamp_dir="$ATELIER_CONFIG_DIR/state/version-nudge"
sid="$(safe "$session_id")"
ctx="$stamp_dir/$sid.ctx"

if [ "$event" = "SessionStart" ]; then
  mkdir -p "$stamp_dir" 2>/dev/null && printf '%s\n' "$loaded" >"$ctx" 2>/dev/null
  exit 0
fi

[ -f "$manifest" ] || exit 0
installed="$(jq -r '.plugins["atelier@akalab-tech"][0].version // empty' "$manifest" 2>/dev/null || true)"
[ -n "$installed" ] || exit 0

if [ "$installed" != "$loaded" ]; then
  stamp="$stamp_dir/$sid--$(safe "$installed")"
  [ -e "$stamp" ] && exit 0
  mkdir -p "$stamp_dir" 2>/dev/null && : >"$stamp" 2>/dev/null || exit 0

  msg="atelier $installed is installed; this session runs $loaded. Type /reload-plugins (or /reload-plugins --force if it warns about MCP tools); atelier finishes the refresh on your next message."
  jq -n --arg m "$msg" '{
    systemMessage: $m,
    hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: $m }
  }'
  exit 0
fi

# installed == loaded: has the injected context caught up with the loaded version?
if [ -f "$ctx" ]; then
  ctx_version="$(head -n 1 "$ctx" 2>/dev/null || true)"
  [ -n "$ctx_version" ] && [ "$ctx_version" != "$loaded" ] || exit 0
elif [ ! -e "$stamp_dir/$sid--$(safe "$loaded")" ]; then
  exit 0
fi

mkdir -p "$stamp_dir" 2>/dev/null && printf '%s\n' "$loaded" >"$ctx" 2>/dev/null || exit 0

prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null || true)"
case "$prompt" in
  /atelier:reload*|/atelier:refresh*) exit 0 ;;
esac

ctx_msg="atelier was just reloaded to $loaded; the session rules injected at start are stale. Before answering the operator's message, finish the refresh once: follow /atelier:reload Steps 3-4 (Read \${CLAUDE_PLUGIN_ROOT}/operator-rules.md in full with Read and treat it as replacing the earlier rules, re-apply the operator chat language, run atelier-orient once, reconcile the Notification hook, list what still needs a restart). Then answer the operator's message."
msg="atelier $loaded loaded; refreshing session rules."
jq -n --arg m "$msg" --arg c "$ctx_msg" '{
  systemMessage: $m,
  hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: $c }
}'
exit 0
