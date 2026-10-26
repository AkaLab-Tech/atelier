#!/usr/bin/env bash
#
# atelier — UserPromptSubmit hook (#638 / #639): the ONLY place operator
# consent is minted. Matches `atelier permitir <CODE>` / `atelier allow <CODE>`
# at the start of the operator's typed prompt, where CODE is the 8-char base32
# challenge shown to the operator in a guard's systemMessage, and turns the
# matching pending record into a single-use, 10-minute grant for that one exact
# action (see hooks/lib/consent.sh).
#
# UserPromptSubmit fires only for what the operator submits, so tool output,
# files, and the agent's own text cannot reach this path.
#
# Contract: stdin JSON { session_id, prompt, permission_mode, ... }; stdout JSON
# (hookSpecificOutput.additionalContext for the model on grant, systemMessage
# for the operator); always exit 0. A wrong/expired code grants nothing.

set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"
# shellcheck source=lib/consent.sh
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/consent.sh"

input="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0

prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null || true)"
[ -n "$prompt" ] || exit 0

re='^[[:space:]]*atelier (permitir|allow) ([A-Z2-7]{8})([^A-Za-z0-9]|$)'
[[ "$prompt" =~ $re ]] || exit 0
code="${BASH_REMATCH[2]}"

CONSENT_PERMISSION_MODE="$(printf '%s' "$input" | jq -r '.permission_mode // empty' 2>/dev/null || true)"
export CONSENT_PERMISSION_MODE
sid="$(consent_session_token "$input")"

result="$(consent_grant "$code" "$sid")"
status="${result%%$'\t'*}"
detail="${result#*$'\t'}"

if [ "$status" = "granted" ]; then
  jq -n --arg ctx "The operator authorized this exact action once, within 10 minutes: $detail. Retry that same call unchanged; any other call is not covered." \
    --arg sys "atelier consent granted once for: $detail (valid 10 minutes)" \
    '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx},systemMessage:$sys}'
else
  jq -n --arg sys "atelier consent NOT granted: $detail" '{systemMessage:$sys}'
fi
exit 0
