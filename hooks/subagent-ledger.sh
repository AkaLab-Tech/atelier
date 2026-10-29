#!/usr/bin/env bash
#
# atelier hook: subagent-ledger (#577)
#
# Two events, one script (registered in hooks.json):
#
#   SubagentStop           records an interim stop (`atelier-subagent-ledger stop`); it fires
#                          on every turn end, so it never closes the entry. Never blocks.
#   PreToolUse/SubagentHandback
#                          the final hand-back closes the handing-back agent's own entry
#                          (a task-orchestrator's only when the hand-back is allowed). When the
#                          agent is a task-orchestrator, denies a report that leaves a fresh
#                          live child in the worktree's ledger without a stop attempt: a
#                          `Live sub-agents:` line naming every live agent id with `stopped` or
#                          `TaskStop failed`. Disclosure with a stop attempt always unblocks.
#
# Fails open everywhere: jq missing, no `Worktree:` line in the report, a different agent type,
# or an unreadable ledger all allow. Nothing here waits or polls.

set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"

HOOK_NAME="subagent-ledger"
LEDGER="${CLAUDE_PLUGIN_ROOT}/scripts/atelier-subagent-ledger"

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"
event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
agent_id="$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null || true)"
agent_type="$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null || true)"

case "$event" in
  SubagentStop)
    [ -n "$agent_id" ] && [ -x "$LEDGER" ] && "$LEDGER" stop --agent-id "$agent_id" >/dev/null 2>&1
    exit 0
    ;;
  PreToolUse) ;;
  *) exit 0 ;;
esac

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ "$tool_name" = "SubagentHandback" ] || exit 0

if [ -n "$agent_id" ]; then
  log_decision "$HOOK_NAME" "SubagentHandback" "" "info" "agent_id present"
else
  log_decision "$HOOK_NAME" "SubagentHandback" "" "info" "agent_id absent in payload"
fi

close_own() {
  [ -n "$agent_id" ] && "$LEDGER" finish --agent-id "$agent_id" --state "done" --reason "final hand-back" >/dev/null 2>&1
  return 0
}

if ! printf '%s' "$agent_type" | grep -Eq '(^|:)task-orchestrator$'; then
  [ -x "$LEDGER" ] && close_own
  exit 0
fi

message="$(printf '%s' "$input" | jq -r '.tool_input.message // empty' 2>/dev/null || true)"
wt="$(printf '%s\n' "$message" | sed -n 's/^[[:space:]]*[-*]*[[:space:]]*\**Worktree:\**[[:space:]]*//p' | head -n1 | awk '{print $1}' | tr -d '`')"
if ! { [ -n "$wt" ] && [ -d "$wt" ] && [ -x "$LEDGER" ]; }; then
  [ -x "$LEDGER" ] && close_own
  exit 0
fi

export CLAUDE_PROJECT_DIR="$wt"

live="$("$LEDGER" live --worktree "$wt" 2>/dev/null)"
rc=$?
if [ "$rc" -ne 3 ]; then
  log_decision "$HOOK_NAME" "SubagentHandback" "" "allow" "no live sub-agents (ledger rc=$rc)"
  close_own
  exit 0
fi

fresh_ids="$(printf '%s\n' "$live" | awk -F'\t' '$5 == "fresh" {print $1}')"
if [ -z "$fresh_ids" ]; then
  log_decision "$HOOK_NAME" "SubagentHandback" "" "allow" "only stale live entries"
  close_own
  exit 0
fi

disclosed="$(printf '%s\n' "$message" | awk 'f {print} tolower($0) ~ /live sub-agents:/ {f=1; print}')"
missing=""
for id in $fresh_ids; do
  # Disclosure needs a stop attempt: the id's own line must say `stopped` or `TaskStop failed`.
  printf '%s\n' "$disclosed" | grep -F -- "$id" | grep -Eiq 'stopped|TaskStop failed' || missing="$missing $id"
done

if [ -z "$missing" ]; then
  log_decision "$HOOK_NAME" "SubagentHandback" "" "allow" "live sub-agents disclosed with a stop attempt"
  close_own
  exit 0
fi

missing="${missing# }"
cat >&2 <<MSG
atelier:subagent-ledger BLOCKED
   Tool:     SubagentHandback
   Worktree: $wt
   Reason:   the dispatch ledger shows sub-agent(s) still running that this report does not name with a stop attempt (stopped / TaskStop failed): $missing
   Ways out (pick one):
     1. End your turn WITHOUT handing back and wait for the child's hand-back report (no sleep, no polling); an interim notification without a report means it is still live
     2. If the child's work is moot, TaskStop it and record: atelier-subagent-ledger finish --agent-id <id> --state stopped
     3. If TaskStop errors, disclose it as a last resort: add a line "Live sub-agents: <agent_id> (<type>, <step>) - still running: TaskStop failed (<error>)" naming every id above, then hand back again.
MSG
log_decision "$HOOK_NAME" "SubagentHandback" "undisclosed-live-child" "block" "undisclosed live sub-agents: $missing"
exit 2
