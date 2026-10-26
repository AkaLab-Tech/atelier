#!/usr/bin/env bash
#
# atelier — hook that surfaces a permission-mode drift (#635). Registered on
# UserPromptSubmit.
#
# Auto mode is the supported default for atelier sessions (PLAN.md §3). A
# session can leave it silently (Shift+Tab, a project/local `defaultMode`
# override, a --permission-mode flag) and the chain then hits prompts the
# classifier would have settled. Claude Code 2.1.309 carries `permission_mode`
# in UserPromptSubmit / PreToolUse input (docs/research/), not in SessionStart.
#
# In a registered atelier project (cwd is the project, a subdirectory, or one
# of its `<project>-worktrees/*` task worktrees):
#   - first prompt of a session in a mode other than `auto`: one notice;
#   - the mode changes between prompts: one notice per change.
# Otherwise silent. Informational only: never blocks, always exits 0.
#
# Cheap + FAIL-OPEN: jq and local files only. Missing jq / registry / fields
# -> silent exit 0. State: $ATELIER_CONFIG_DIR/state/mode-nudge/<sid>.mode.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

ATELIER_CONFIG_DIR="${ATELIER_CONFIG_DIR:-$HOME/.claude-work}"
registry="$ATELIER_CONFIG_DIR/projects.json"
[ -f "$registry" ] || exit 0

input="$(cat 2>/dev/null || true)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
mode="$(printf '%s' "$input" | jq -r '.permission_mode // empty' 2>/dev/null || true)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$session_id" ] && [ -n "$mode" ] && [ -n "$cwd" ] || exit 0

registered=0
while IFS= read -r proj; do
  [ -n "$proj" ] || continue
  proj="${proj%/}"
  case "$cwd" in
    "$proj"|"$proj"/*|"$proj"-worktrees/*) registered=1; break ;;
  esac
done < <(jq -r '.projects // {} | keys[]' "$registry" 2>/dev/null)
[ "$registered" -eq 1 ] || exit 0

state_dir="$ATELIER_CONFIG_DIR/state/mode-nudge"
state="$state_dir/$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9._-' '_').mode"
prev=""
[ -f "$state" ] && prev="$(head -n 1 "$state" 2>/dev/null || true)"

[ "$prev" = "$mode" ] && exit 0
mkdir -p "$state_dir" 2>/dev/null && printf '%s\n' "$mode" >"$state" 2>/dev/null || exit 0

if [ -z "$prev" ]; then
  [ "$mode" = "auto" ] && exit 0
  msg="This atelier session is in permission mode \"$mode\", not auto. Auto mode is the supported default: the chain can hit prompts it would not hit in auto. Switch back with Shift+Tab, or check /status and any project/local defaultMode override (atelier-doctor flags those)."
else
  msg="Permission mode changed from \"$prev\" to \"$mode\" in this atelier session. Auto mode is the supported default; Shift+Tab returns to it."
fi

jq -n --arg m "$msg" '{
  systemMessage: $m,
  hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: $m }
}'
exit 0
