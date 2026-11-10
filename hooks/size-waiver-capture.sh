#!/usr/bin/env bash
#
# atelier hook: size-waiver-capture (#735), PostToolUse / AskUserQuestion.
# Records an affirmative main-session answer to a marked size-waiver question as an
# HMAC-signed record (hooks/lib/size-waiver-record.sh). Never blocks: always exit 0.

set -uo pipefail
trap 'exit 0' ERR

PLUGIN_HOOKS="${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks"
# shellcheck source=lib/log-decision.sh
source "$PLUGIN_HOOKS/lib/log-decision.sh"
# shellcheck source=lib/size-waiver-record.sh
source "$PLUGIN_HOOKS/lib/size-waiver-record.sh"

input="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0
[ "$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" = "AskUserQuestion" ] || exit 0

sid="$(consent_session_token "$input")"
agent="$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)"
msgs=""

while IFS= read -r b64; do
  q="$(printf '%s' "$b64" | base64 -d 2>/dev/null)" || continue
  repo="" pr="" sha="" lines="" files=""
  swr_parse_marker "$q" || continue
  tag="$repo#$pr @${sha:0:12} ${lines}L/${files}F"
  if [ -n "$agent" ]; then
    consent_log size-waiver-reject size-waiver-capture "$tag (subagent selector)" "" "$sid"
    continue
  fi
  ans="$(printf '%s' "$input" | jq -r --arg q "$q" '.tool_response.answers[$q] // empty' 2>/dev/null)"
  if ! swr_is_affirmative "$ans"; then
    consent_log size-waiver-decline size-waiver-capture "$tag" "" "$sid"
    continue
  fi
  if swr_write "$repo" "$pr" "$sha" "$lines" "$files" "$q" "$ans" "$sid" "$(date -u +%FT%TZ)"; then
    consent_log size-waiver-capture size-waiver-capture "$tag" "" "$sid"
    msgs="${msgs}atelier recorded size waiver for $tag. "
  else
    consent_log size-waiver-error size-waiver-capture "$tag (record not written)" "" "$sid"
  fi
done < <(printf '%s' "$input" | jq -r '.tool_input.questions[]?.question // empty | @base64' 2>/dev/null)

[ -n "$msgs" ] && jq -cn --arg m "$msgs" '{systemMessage:$m}'
exit 0
