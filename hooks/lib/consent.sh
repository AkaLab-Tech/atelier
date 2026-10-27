#!/usr/bin/env bash
#
# atelier — operator-consent core (#638 / #639): challenge code, single-use
# grant, ledger. Sourced by consent-eligible PreToolUse guards and by the
# UserPromptSubmit hook hooks/operator-consent.sh.
#
# Design property: the model never sees the code that unlocks an action.
#   1. A consent-eligible guard blocks a call and calls consent_challenge. The
#      code goes ONLY into the PreToolUse `systemMessage` (shown to the operator);
#      the `permissionDecisionReason` the model reads never contains it.
#   2. The operator types `atelier permitir <CODE>` (or `atelier allow <CODE>`).
#      hooks/operator-consent.sh (UserPromptSubmit) turns the pending record into
#      a grant for that ONE exact action, valid once, for 10 minutes.
#   3. The guard calls consent_consume before blocking; an unexpired grant is
#      consumed atomically and the call is allowed.
# Only sha256(code) is ever stored. State lives under
# $ATELIER_CONFIG_DIR/state/consent/{pending,grants,used,expired}/ plus
# ledger.jsonl; hooks/block-consent-tamper.sh keeps tool calls away from it.
#
# Fail closed for consent: no jq, or an unwritable state dir, means no grant
# is honoured and no challenge is issued (the calling guard blocks as before).
#
# Env: ATELIER_CONFIG_DIR (default ~/.claude-work);
#      ATELIER_CONSENT_TTL_SECONDS (default 600; for tests only).

_consent_root() {
  printf '%s/state/consent' "${ATELIER_CONFIG_DIR:-$HOME/.claude-work}"
}

_consent_ttl() {
  local t="${ATELIER_CONSENT_TTL_SECONDS:-600}"
  case "$t" in ''|*[!0-9]*) t=600 ;; esac
  printf '%s' "$t"
}

_consent_now() { date -u +%s; }

_consent_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

# Prepare the state dirs. Returns 1 (fail closed) when consent cannot work.
_consent_ready() {
  command -v jq >/dev/null 2>&1 || return 1
  local root d
  root="$(_consent_root)"
  (umask 077; for d in pending grants used expired; do mkdir -p "$root/$d"; done) 2>/dev/null || return 1
  [ -w "$root" ] || return 1
  return 0
}

# Only an explicit allowlist can be unlocked by operator consent. Everything
# else stays categorical (secrets, force/protected pushes, review-like writes or
# credential exfiltration under the operator's gh identity, safe-commit,
# safe-package-change, cross-worktree edits, the tamper guard itself).
consent_eligible() {
  case "${1:-}" in
    block-operator-browser-github|block-gh-api-mutation) return 0 ;;
    *) return 1 ;;
  esac
}

# Session token binding a grant to the operator's session. Subagents carry
# their own payload `.session_id`, so prefer CLAUDE_CODE_BRIDGE_SESSION_ID
# (inherited unchanged down the chain) when set — same rule as
# block-cross-worktree-edit.sh. Usage: consent_session_token "$input_json"
consent_session_token() {
  if [ -n "${CLAUDE_CODE_BRIDGE_SESSION_ID:-}" ]; then
    printf '%s' "$CLAUDE_CODE_BRIDGE_SESSION_ID"
  else
    printf '%s' "${1:-}" | jq -r '.session_id // empty' 2>/dev/null || true
  fi
}

# consent_fingerprint <hook> <canonical-action> — sha256(hook \x1f action).
# Bash: exact command, whitespace-trimmed. Chrome: tool name + exact URL.
consent_fingerprint() {
  local hook="$1" action="$2"
  action="${action#"${action%%[![:space:]]*}"}"
  action="${action%"${action##*[![:space:]]}"}"
  _consent_sha256 "$hook$(printf '\037')$action"
}

# consent_log <event> <hook> <summary> <fingerprint> <session_id> [permission_mode]
# Appends to the host-level ledger and to <worktree>/.task-log/hook-decisions.jsonl.
# Never aborts the caller.
consent_log() {
  local event="${1:-}" hook="${2:-}" summary="${3:-}" fp="${4:-}" sid="${5:-}" mode="${6:-${CONSENT_PERMISSION_MODE:-}}"
  local root ts
  root="$(_consent_root)"
  ts="$(date -u +%FT%TZ)"
  if command -v jq >/dev/null 2>&1 && mkdir -p "$root" 2>/dev/null; then
    jq -cn --arg ts "$ts" --arg event "$event" --arg hook "$hook" --arg summary "$summary" \
      --arg fp "$fp" --arg sid "$sid" --arg mode "$mode" \
      '{ts:$ts,event:$event,hook:$hook,summary:$summary,fingerprint:$fp,session_id:$sid,permission_mode:$mode}' \
      >> "$root/ledger.jsonl" 2>/dev/null || true
  fi
  if declare -F log_decision >/dev/null 2>&1; then
    local action
    case "$event" in
      challenge) action="consent-challenge" ;;
      consume) action="allow-consent" ;;
      *) action="consent-$event" ;;
    esac
    log_decision "${hook:-consent}" "consent" "$event" "$action" "$summary" || true
  fi
  return 0
}

# consent_challenge <hook> <fingerprint> <summary> [session_id]
# On success prints the PreToolUse deny JSON (code only in systemMessage) and
# returns 0; the caller must then exit 0. Returns 1 when no challenge can be
# issued (ineligible hook, jq/state unavailable): the caller keeps its normal
# block (exit 2).
consent_challenge() {
  local hook="${1:-}" fp="${2:-}" summary="${3:-}" sid="${4:-${CONSENT_SESSION_ID:-}}"
  consent_eligible "$hook" || return 1
  [ -n "$fp" ] && [ -n "$sid" ] || return 1
  _consent_ready || return 1
  local root code h
  root="$(_consent_root)"
  code="$(LC_ALL=C tr -dc 'A-Z2-7' </dev/urandom 2>/dev/null | head -c 8 || true)"
  [ "${#code}" -eq 8 ] || return 1
  h="$(_consent_sha256 "$code")"
  (umask 077; jq -n --arg hook "$hook" --arg fp "$fp" --arg summary "$summary" \
    --arg sid "$sid" --argjson created "$(_consent_now)" \
    '{hook:$hook,fingerprint:$fp,summary:$summary,session_id:$sid,created:$created}' \
    > "$root/pending/$h.json") 2>/dev/null || return 1
  consent_log challenge "$hook" "$summary" "$fp" "$sid"
  jq -n --arg reason "atelier:$hook blocked this call ($summary). It needs the operator's explicit consent, which can only be given by the operator typing a one-time code that is shown to them, not to you. Do not ask the operator to paste a code, do not retry this call, and continue with another approach or wait for the operator to say they authorized it." \
    --arg sys "atelier blocked: $summary. To allow this exact action once, type: atelier permitir $code" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason},systemMessage:$sys}'
  return 0
}

# consent_consume <hook> <fingerprint> <session_id>
# Returns 0 and consumes (single use) an unexpired, session-matching grant for
# exactly this hook + action; 1 otherwise.
consent_consume() {
  local hook="${1:-}" fp="${2:-}" sid="${3:-${CONSENT_SESSION_ID:-}}"
  consent_eligible "$hook" || return 1
  [ -n "$fp" ] && [ -n "$sid" ] || return 1
  _consent_ready || return 1
  local root g now expires gsid ghook summary claimed
  root="$(_consent_root)"
  g="$root/grants/$fp.json"
  [ -f "$g" ] || return 1
  now="$(_consent_now)"
  # Claim atomically first: whoever wins the mv owns the single use.
  claimed="$root/used/$fp.$now.$$.json"
  mv "$g" "$claimed" 2>/dev/null || return 1
  expires="$(jq -r '.expires // 0' "$claimed" 2>/dev/null || echo 0)"
  gsid="$(jq -r '.session_id // empty' "$claimed" 2>/dev/null || true)"
  ghook="$(jq -r '.hook // empty' "$claimed" 2>/dev/null || true)"
  summary="$(jq -r '.summary // empty' "$claimed" 2>/dev/null || true)"
  if [ "$ghook" != "$hook" ] || [ "$gsid" != "$sid" ]; then
    # Not ours: put it back untouched.
    mv "$claimed" "$g" 2>/dev/null || true
    return 1
  fi
  case "$expires" in ''|*[!0-9]*) expires=0 ;; esac
  if [ "$now" -ge "$expires" ]; then
    mv "$claimed" "$root/expired/$fp.$now.json" 2>/dev/null || true
    consent_log expire "$hook" "$summary" "$fp" "$sid"
    return 1
  fi
  consent_log consume "$hook" "$summary" "$fp" "$sid"
  export CONSENT_LAST_SUMMARY="$summary"
  return 0
}

# consent_grant <code> <session_id>
# Called by hooks/operator-consent.sh. Prints a one-line status to stdout:
# "granted\t<summary>" or "rejected\t<reason>". Returns 0 on grant, 1 otherwise.
consent_grant() {
  local code="${1:-}" sid="${2:-}"
  if ! _consent_ready; then
    printf 'rejected\tconsent state unavailable (jq missing or state dir unwritable)\n'
    return 1
  fi
  local root h p claimed now created ttl hook fp summary psid
  root="$(_consent_root)"
  now="$(_consent_now)"
  ttl="$(_consent_ttl)"
  h="$(_consent_sha256 "$code")"
  p="$root/pending/$h.json"
  claimed="$root/used/pending.$h.$now.$$.json"
  if [ ! -f "$p" ] || ! mv "$p" "$claimed" 2>/dev/null; then
    consent_log reject "" "unknown or already used code" "" "$sid"
    printf 'rejected\tunknown or already used code\n'
    return 1
  fi
  hook="$(jq -r '.hook // empty' "$claimed" 2>/dev/null || true)"
  fp="$(jq -r '.fingerprint // empty' "$claimed" 2>/dev/null || true)"
  summary="$(jq -r '.summary // empty' "$claimed" 2>/dev/null || true)"
  psid="$(jq -r '.session_id // empty' "$claimed" 2>/dev/null || true)"
  created="$(jq -r '.created // 0' "$claimed" 2>/dev/null || echo 0)"
  case "$created" in ''|*[!0-9]*) created=0 ;; esac
  if [ "$psid" != "$sid" ]; then
    consent_log reject "$hook" "session mismatch: $summary" "$fp" "$sid"
    printf 'rejected\tthat code belongs to a different session\n'
    return 1
  fi
  if [ $((now - created)) -ge "$ttl" ]; then
    mv "$claimed" "$root/expired/pending.$h.json" 2>/dev/null || true
    consent_log expire "$hook" "challenge expired: $summary" "$fp" "$sid"
    printf 'rejected\tthe code expired; repeat the action to get a new one\n'
    return 1
  fi
  if ! consent_eligible "$hook" || [ -z "$fp" ]; then
    consent_log reject "$hook" "not consent-eligible: $summary" "$fp" "$sid"
    printf 'rejected\tthat action cannot be granted by consent\n'
    return 1
  fi
  (umask 077; jq -n --arg hook "$hook" --arg fp "$fp" --arg summary "$summary" --arg sid "$sid" \
    --argjson expires "$((now + ttl))" \
    '{hook:$hook,fingerprint:$fp,summary:$summary,session_id:$sid,expires:$expires,uses_left:1}' \
    > "$root/grants/$fp.json") 2>/dev/null || {
    printf 'rejected\tcould not write the grant\n'
    return 1
  }
  consent_log grant "$hook" "$summary" "$fp" "$sid"
  printf 'granted\t%s\n' "$summary"
  return 0
}
