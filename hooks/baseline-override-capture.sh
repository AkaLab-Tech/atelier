#!/usr/bin/env bash
#
# atelier hook: baseline-override-capture (#746, #744 part 1), PostToolUse / AskUserQuestion.
# Records an affirmative main-session answer to a marked baseline-override question as an
# HMAC-signed record (hooks/lib/baseline-override-record.sh). Never blocks: always exit 0.

set -uo pipefail
trap 'exit 0' ERR

PLUGIN_HOOKS="${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks"
# shellcheck source=lib/log-decision.sh
source "$PLUGIN_HOOKS/lib/log-decision.sh"
# shellcheck source=lib/baseline-override-record.sh
source "$PLUGIN_HOOKS/lib/baseline-override-record.sh"

input="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0
[ "$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" = "AskUserQuestion" ] || exit 0

sid="$(consent_session_token "$input")"
agent="$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)"
msgs=""

while IFS= read -r b64; do
  q="$(printf '%s' "$b64" | base64 -d 2>/dev/null)" || continue
  repo="" branch="" base_sha="" n="" h=""
  bor_parse_marker "$q" || continue
  tag="$repo $branch @${base_sha:0:12} n=$n"
  if [ -n "$agent" ]; then
    consent_log baseline-override-reject baseline-override-capture "$tag (subagent selector)" "" "$sid"
    continue
  fi
  ids=()
  while IFS= read -r line; do [ -n "$line" ] && ids+=("$line"); done < <(bor_parse_ids "$q")
  if [ "${#ids[@]}" -eq 0 ] || [ "$(printf '%s\n' "${ids[@]}" | LC_ALL=C sort -u | wc -l | tr -d ' ')" != "$n" ] \
    || [ "$(bor_digest "${ids[@]}" | cut -c1-16)" != "$h" ]; then
    consent_log baseline-override-reject baseline-override-capture "$tag (identifier count or digest mismatch)" "" "$sid"
    continue
  fi
  ans="$(printf '%s' "$input" | jq -r --arg q "$q" '.tool_response.answers[$q] // empty' 2>/dev/null)"
  if ! bor_is_affirmative "$ans"; then
    consent_log baseline-override-decline baseline-override-capture "$tag" "" "$sid"
    continue
  fi
  waived="$(printf '%s\n' "${ids[@]}" | LC_ALL=C sort -u)"
  if bor_write "$repo" "$branch" "$base_sha" "$waived" "$q" "$ans" "$sid" "$(date -u +%FT%TZ)"; then
    consent_log baseline-override-capture baseline-override-capture "$tag" "" "$sid"
    msgs="${msgs}atelier recorded baseline override for $repo $branch ($n tests). "
  else
    consent_log baseline-override-error baseline-override-capture "$tag (record not written)" "" "$sid"
  fi
done < <(printf '%s' "$input" | jq -r '.tool_input.questions[]?.question // empty | @base64' 2>/dev/null)

[ -n "$msgs" ] && jq -cn --arg m "$msgs" '{systemMessage:$m}'
exit 0
