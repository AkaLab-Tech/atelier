#!/usr/bin/env bash
#
# atelier — shared helper for PreToolUse / PostToolUse hooks to record
# their decisions to <worktree>/.task-log/hook-decisions.jsonl.
#
# Sourced from each hook script, e.g.:
#   # shellcheck source=lib/log-decision.sh
#   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/log-decision.sh"
#   log_decision "block-env-commit" "Bash" ".env-staged" "block" "refusing .env*"
#
# The hooks/safe-* / scan-* / block-* scripts call log_decision() before
# they exit. The unblocker agent (M4.2) reads the JSONL when escalating
# to a blocked issue, and the operator can post-mortem it after any task.
#
# Failure mode: this helper MUST never abort the calling hook. If the
# log directory cannot be written, swallow the error and return 0 — a
# missing log line is acceptable; a hook that aborts on logging failure
# would block legitimate tool calls and defeat the purpose.

# Resolve the per-task log path. Priority:
#   1. CLAUDE_PROJECT_DIR (set by Claude Code when a project is active)
#   2. the cwd of the hook process (the worktree the agent is operating in)
# Either way, the JSONL ends up at <worktree>/.task-log/hook-decisions.jsonl.
_atelier_log_path() {
  local root="${CLAUDE_PROJECT_DIR:-$PWD}"
  printf '%s/.task-log/hook-decisions.jsonl' "$root"
}

# Append one JSON object to the log. Fields:
#   timestamp     — UTC ISO-8601 with millisecond precision
#   hook          — name of the calling hook (e.g. "block-env-commit")
#   tool          — the tool the hook was matching (e.g. "Bash", "Edit")
#   pattern       — short id of the rule that fired (e.g. ".env-staged",
#                   "eval-unsanitised-input"); empty when the hook allowed
#   action        — "allow" | "block" | "warn" | "ask"
#   message       — short human-readable explanation
#
# All arguments are passed through `jq -Rn --arg ...` so they're escaped
# safely; no shell-injection vector even if the hook is fed wild input.
log_decision() {
  local hook="${1:-}"
  local tool="${2:-}"
  local pattern="${3:-}"
  local action="${4:-}"
  local message="${5:-}"

  local log_file
  log_file="$(_atelier_log_path)"
  local log_dir
  log_dir="$(dirname "$log_file")"

  # Make the dir; fail-soft.
  mkdir -p "$log_dir" 2>/dev/null || return 0

  # ISO-8601 UTC. Try millisecond precision (GNU date supports %3N), fall
  # back to second precision on BSD date (macOS) which leaves "%3N" literal
  # in the output as ".3N" — detect that and drop to seconds.
  local ts
  ts="$(date -u +%FT%T.%3NZ 2>/dev/null || date -u +%FT%TZ)"
  case "$ts" in
    *.3NZ) ts="$(date -u +%FT%TZ)" ;;
  esac

  if command -v jq >/dev/null 2>&1; then
    jq -cn \
      --arg ts "$ts" \
      --arg hook "$hook" \
      --arg tool "$tool" \
      --arg pattern "$pattern" \
      --arg action "$action" \
      --arg message "$message" \
      '{timestamp: $ts, hook: $hook, tool: $tool, pattern: $pattern, action: $action, message: $message}' \
      >> "$log_file" 2>/dev/null || return 0
  else
    # jq not available — emit a hand-rolled JSON line. We only allow
    # this fallback path; jq is in the install.sh Phase A deps so it
    # should always be present, but staying robust costs us 8 lines.
    local esc_hook esc_tool esc_pattern esc_action esc_message
    esc_hook="$(printf '%s' "$hook" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    esc_tool="$(printf '%s' "$tool" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    esc_pattern="$(printf '%s' "$pattern" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    esc_action="$(printf '%s' "$action" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    esc_message="$(printf '%s' "$message" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    printf '{"timestamp":"%s","hook":"%s","tool":"%s","pattern":"%s","action":"%s","message":"%s"}\n' \
      "$ts" "$esc_hook" "$esc_tool" "$esc_pattern" "$esc_action" "$esc_message" \
      >> "$log_file" 2>/dev/null || return 0
  fi

  return 0
}
