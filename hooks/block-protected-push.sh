#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Bash. Blocks any `git push` that targets a
# protected branch (main/master/develop/staging) or carries a hard force,
# in any refspec/flag form the static permission globs cannot express.
#
# Why this hook exists (#194 / #195 board findings):
#   Claude Code's Bash permission globs are prefix/suffix-anchored string
#   matches. `Bash(git push * main)` and `Bash(git push --force*)` in
#   settings.template.json genuinely CANNOT express "protected branch
#   named anywhere in the refspec" or "force flag anywhere in the args" —
#   `git push origin HEAD:main`, `git push origin +HEAD:main`,
#   `git push origin main --force`, and `git push origin refs/heads/main`
#   all slip past those globs untouched. This hook is the categorical
#   mechanism (Layer 2, PLAN.md §3 defense-in-depth); the static globs in
#   the template are belt-and-suspenders for the common literal shapes.
#
# Contract per Claude Code hooks reference (PreToolUse):
#   stdin  — JSON: { tool_name, tool_input: { command } }
#   exit 0 — allow the tool call
#   exit 2 — block (stderr goes to Claude's context with the explanation)
#   jq missing — fail OPEN (exit 0): a missing hook dependency must never
#   turn into a blanket block of every Bash call.

set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"

HOOK_NAME="block-protected-push"

input="$(cat 2>/dev/null || true)"

if ! command -v jq >/dev/null 2>&1; then
  printf '⚠️  atelier:%s — jq missing; hook safety layer degraded, failing open (allow)\n' "$HOOK_NAME" >&2
  log_decision "$HOOK_NAME" "?" "" "allow" "jq missing — hook degraded to allow"
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

if [ "$tool_name" != "Bash" ]; then
  exit 0
fi
if [ -z "$command_str" ]; then
  exit 0
fi

# Fast path: nothing resembling `git push` anywhere in the raw command —
# skip without paying for the message-payload strip below.
case "$command_str" in
  *"git push"*) ;;
  *) exit 0 ;;
esac

# Strip -m/--message/-F/--file payloads before scanning, ported verbatim
# from safe-commit.sh. Without this, a commit message that merely mentions
# "git push origin main" (e.g. `git commit -m "explain git push origin main
# is denied"`) would be scanned as if it were an actual push invocation.
strip_message_payload() {
  local s="$1" sq out pat prev_len
  sq=$'\047'
  local value_any="(\"[^\"]*\"|${sq}[^${sq}]*${sq}|[^[:space:]]*)"
  local value_quoted="(\"[^\"]*\"|${sq}[^${sq}]*${sq})"
  out="$s"
  for flag_pair in '-m|--message' '-F|--file'; do
    pat="(^|[[:space:]])(${flag_pair})(=${value_any}|[[:space:]]+${value_any}|${value_quoted})"
    while [[ "$out" =~ $pat ]]; do
      prev_len=${#out}
      out="${out/"${BASH_REMATCH[0]}"/ }"
      if [ "${#out}" -ge "$prev_len" ]; then
        break
      fi
    done
  done
  printf '%s' "$out"
}
scan_str="$(strip_message_payload "$command_str")"

# Isolate every `git push …` segment from chained commands. Splitting on
# `&&` / `;` / `|` is enough here: we only need to find the segments that
# actually invoke `git push` — we are not trying to parse arbitrary shell.
push_segments=()
while IFS= read -r seg; do
  seg="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  [ -z "$seg" ] && continue
  case "$seg" in
    *"git push"*) push_segments+=("$seg") ;;
  esac
done < <(printf '%s\n' "$scan_str" | tr ';&|' '\n\n\n')

if [ "${#push_segments[@]}" -eq 0 ]; then
  # The only "git push" substring lived inside a stripped commit message.
  exit 0
fi

PROTECTED_BRANCHES="main master develop staging"

is_protected_name() {
  local name="$1"
  local b
  for b in $PROTECTED_BRANCHES; do
    [ "$name" = "$b" ] && return 0
  done
  return 1
}

block() {
  local reason="$1" detail="$2" segment="$3"
  cat >&2 <<MSG
🚫 atelier:block-protected-push BLOCKED
   Tool:    Bash(git push)
   Command: $segment
   Reason:  $reason
   Detail:  $detail
   Rule:    PLAN.md §3 / operator-rules.md — pushes to main/master/develop/staging and any hard-force push are denied categorically, regardless of the refspec or flag form used to express them.
   Action:  push only to \`origin task/<id>-<slug>\`; use \`--force-with-lease origin task/<id>-<slug>\` (never a plain \`+refspec\` or \`--force\`) to reconcile a diverged task branch.
   Override: none from inside this session — a genuine protected-branch or force push is the operator's call, made manually outside Claude Code.
MSG
  log_decision "$HOOK_NAME" "Bash" "$reason" "block" "$detail"
  exit 2
}

for seg in "${push_segments[@]}"; do
  # Tokenize. Push args are unquoted in the overwhelming majority of real
  # invocations; this mirrors the tokenisation approach the other hooks in
  # this repo use (word-splitting, not a full shell parser).
  read -ra tokens <<< "$seg"

  # Find the `push` token (git subcommand). There may be flags/options
  # between `git` and `push` (e.g. `git -C <path> push`), so search for
  # the literal token rather than assuming a fixed position.
  push_idx=-1
  for i in "${!tokens[@]}"; do
    if [ "${tokens[$i]}" = "push" ]; then
      push_idx="$i"
      break
    fi
  done
  [ "$push_idx" -lt 0 ] && continue

  args=("${tokens[@]:$((push_idx + 1))}")

  hard_force=0
  plus_refspec=0
  positionals=()

  for tok in "${args[@]}"; do
    case "$tok" in
      --force-with-lease*|--force-if-includes*)
        : # sanctioned lease form — never a hard force by itself
        ;;
      --force|--force=*)
        hard_force=1
        ;;
      +*)
        plus_refspec=1
        positionals+=("$tok")
        ;;
      --*)
        : # other long options — not force-relevant
        ;;
      -*)
        body="${tok#-}"
        if [[ "$body" =~ ^[a-zA-Z]+$ ]] && [[ "$body" == *f* ]]; then
          hard_force=1
        fi
        ;;
      *)
        positionals+=("$tok")
        ;;
    esac
  done

  # PROTECTED-TARGET detection — regardless of force. `positionals[0]` is
  # the remote (e.g. `origin`); everything after it is a refspec.
  protected_name=""
  if [ "${#positionals[@]}" -ge 2 ]; then
    for ref in "${positionals[@]:1}"; do
      dst="$ref"
      dst="${dst#+}"
      case "$dst" in
        *:*) dst="${dst#*:}" ;;
      esac
      dst="${dst#refs/heads/}"
      if is_protected_name "$dst"; then
        protected_name="$dst"
        break
      fi
    done
  fi

  if [ -n "$protected_name" ]; then
    block "push targets protected branch '$protected_name'" "segment resolved destination ref to '$protected_name'" "$seg"
  fi

  if [ "$hard_force" -eq 1 ] || [ "$plus_refspec" -eq 1 ]; then
    block "hard force push" "segment carries a hard --force/-f flag or a '+' hard-force refspec (--force-with-lease is the only sanctioned force form)" "$seg"
  fi
done

exit 0
