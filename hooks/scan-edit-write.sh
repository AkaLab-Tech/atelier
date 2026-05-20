#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Edit / Write / MultiEdit. Scans the
# PROPOSED file contents (not the file currently on disk) for the
# security-gap patterns catalogued in PLAN.md §3 threat-model addendum.
# The catalogue lives in hooks/patterns/scan-edit-write.json so adding
# or tuning a pattern does not require touching this script.
#
# Each pattern has an action:
#   - "block" → exit 2, the Edit/Write is rejected, Claude sees the
#               message on stderr.
#   - "warn"  → exit 0, the Edit/Write proceeds, the operator and
#               Claude see a warning. Use for shape-only matches that
#               have legitimate uses (SQL templates, CSP relaxation).
#
# Layered defence: this hook is the runtime content-validator. The
# static permissions matrix decides WHICH paths agents can Edit; this
# hook decides WHAT can be written into those paths.

set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"

HOOK_NAME="scan-edit-write"
PATTERNS_FILE="${CLAUDE_PLUGIN_ROOT}/hooks/patterns/scan-edit-write.json"

# Catalogue missing → hook degrades to allow. Better to let edits
# through than to lock the operator out of every Edit when the plugin
# is partially installed.
if [ ! -f "$PATTERNS_FILE" ]; then
  log_decision "$HOOK_NAME" "?" "" "allow" "patterns file missing at $PATTERNS_FILE — hook degraded"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  log_decision "$HOOK_NAME" "?" "" "allow" "jq missing — hook degraded"
  exit 0
fi

input="$(cat 2>/dev/null || true)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"

case "$tool_name" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
if [ -z "$file_path" ]; then
  exit 0
fi

# Extract the PROPOSED content (what Claude wants to write), not the
# file as it exists on disk.
case "$tool_name" in
  Write)
    content="$(printf '%s' "$input" | jq -r '.tool_input.content // ""' 2>/dev/null || true)"
    ;;
  Edit)
    content="$(printf '%s' "$input" | jq -r '.tool_input.new_string // ""' 2>/dev/null || true)"
    ;;
  MultiEdit)
    # Concatenate every edit's new_string with newlines so multi-edit
    # patches are scanned as a whole.
    content="$(printf '%s' "$input" | jq -r '[.tool_input.edits[]?.new_string // ""] | join("\n")' 2>/dev/null || true)"
    ;;
esac

# Empty content → nothing to scan.
if [ -z "$content" ]; then
  exit 0
fi

# ---- Skip rules --------------------------------------------------------
# Path-substring skips (test fixtures, docs).
skip_subs="$(jq -r '.skips.path_substrings[]?' "$PATTERNS_FILE" 2>/dev/null)"
if [ -n "$skip_subs" ]; then
  while IFS= read -r sub; do
    [ -z "$sub" ] && continue
    case "$file_path" in
      *"$sub"*)
        log_decision "$HOOK_NAME" "$tool_name" "skip:path-substring:$sub" "allow" "skipped — $file_path matches $sub"
        exit 0
        ;;
    esac
  done <<< "$skip_subs"
fi

# Basename-prefix skips (README*).
basename_path="$(basename "$file_path")"
skip_prefixes="$(jq -r '.skips.basename_prefixes[]?' "$PATTERNS_FILE" 2>/dev/null)"
if [ -n "$skip_prefixes" ]; then
  while IFS= read -r prefix; do
    [ -z "$prefix" ] && continue
    case "$basename_path" in
      "$prefix"*)
        log_decision "$HOOK_NAME" "$tool_name" "skip:basename:$prefix" "allow" "skipped — basename starts with $prefix"
        exit 0
        ;;
    esac
  done <<< "$skip_prefixes"
fi

# Content directive: any of the first 5 lines mentions the opt-out
# token (e.g. "scan-edit-write: skip"). Lets a deliberate test fixture
# bypass without renaming the file.
directive="$(jq -r '.skips.content_directive // empty' "$PATTERNS_FILE" 2>/dev/null || true)"
if [ -n "$directive" ]; then
  if printf '%s\n' "$content" | head -n 5 | grep -qF -- "$directive"; then
    log_decision "$HOOK_NAME" "$tool_name" "skip:directive" "allow" "skipped — content opt-out directive"
    exit 0
  fi
fi

# ---- Pattern scan ------------------------------------------------------
# Collect warnings so we can print them all together at the end. Blocks
# exit immediately.
declare -a warnings=()

while IFS= read -r pat_json; do
  [ -z "$pat_json" ] && continue
  name="$(printf '%s' "$pat_json" | jq -r '.name // empty')"
  match_type="$(printf '%s' "$pat_json" | jq -r '.match_type // empty')"
  action="$(printf '%s' "$pat_json" | jq -r '.action // empty')"
  rationale="$(printf '%s' "$pat_json" | jq -r '.rationale // empty')"
  case_insensitive="$(printf '%s' "$pat_json" | jq -r '.case_insensitive // false')"

  matched=0
  matched_text=""

  case "$match_type" in
    regex)
      regex="$(printf '%s' "$pat_json" | jq -r '.pattern // empty')"
      [ -z "$regex" ] && continue
      grep_flags=("-E")
      [ "$case_insensitive" = "true" ] && grep_flags+=("-i")
      if matched_text="$(printf '%s' "$content" | grep "${grep_flags[@]}" -m1 -o -- "$regex" 2>/dev/null)"; then
        if [ -n "$matched_text" ]; then
          matched=1
        fi
      fi
      ;;
    substring_any)
      while IFS= read -r sub; do
        [ -z "$sub" ] && continue
        case "$content" in
          *"$sub"*)
            matched=1
            matched_text="$sub"
            break
            ;;
        esac
      done < <(printf '%s' "$pat_json" | jq -r '.patterns[]?')
      ;;
    *)
      # Unknown match_type — skip rather than fail.
      continue
      ;;
  esac

  [ "$matched" -eq 0 ] && continue

  if [ "$action" = "block" ]; then
    # Truncate matched_text to a reasonable preview (don't dump entire
    # multi-KB strings into Claude's context).
    preview="${matched_text:0:120}"
    [ "${#matched_text}" -gt 120 ] && preview="$preview…"

    cat >&2 <<MSG
🚫 atelier:scan-edit-write BLOCKED
   Tool:    $tool_name $file_path
   Pattern: $name
   Match:   $preview
   Why:     $rationale
   Rule:    PLAN.md §3 threat-model addendum (scan-edit-write catalogue).
   Action:  remove the offending content; if this is a deliberate test fixture, add a comment with "scan-edit-write: skip" in the first 5 lines of the file.
MSG

    log_decision "$HOOK_NAME" "$tool_name" "$name" "block" "matched $preview in $file_path"
    exit 2
  fi

  if [ "$action" = "warn" ]; then
    preview="${matched_text:0:120}"
    [ "${#matched_text}" -gt 120 ] && preview="$preview…"
    warnings+=("$name|$preview|$rationale")
  fi
done < <(jq -c '.patterns[]?' "$PATTERNS_FILE")

# Emit collected warnings (if any). The tool call still proceeds.
if [ "${#warnings[@]}" -gt 0 ]; then
  {
    printf '⚠️  atelier:scan-edit-write WARNING\n'
    printf '   Tool: %s %s\n' "$tool_name" "$file_path"
    printf '   The following pattern(s) matched but only warn; the edit is allowed:\n'
    for w in "${warnings[@]}"; do
      IFS='|' read -r wname wmatch wrationale <<< "$w"
      printf '   - %s\n     match: %s\n     why:   %s\n' "$wname" "$wmatch" "$wrationale"
      log_decision "$HOOK_NAME" "$tool_name" "$wname" "warn" "matched $wmatch in $file_path"
    done
  } >&2
fi

exit 0
