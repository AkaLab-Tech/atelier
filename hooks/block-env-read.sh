#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Bash. Blocks shell commands that read, copy,
# move, delete or otherwise touch the CONTENTS of a protected `.env*` file.
#
# Before this hook nothing blocked these reads: block-env-commit.sh only
# covers `git add`/`git commit`, and semantic-risk-judge.sh only greps `.env`
# out of a commit message. `.env*` contents are operator-only secrets.
#
# Detection (deny-by-default on any command token naming a protected file):
#   - The command is split into segments on `;`, `&&`, `||`, `|`, newlines,
#     `$(` and backticks. Each segment is inspected on its own.
#   - Protected token: a name starting with `.env` (`.env`, `.env.local`,
#     `.env*`, `.env.*`, `.envrc`) whose preceding char is start/space/`/`/
#     quote/`<`/`>`/`=`/`(`/`:`. `process.env`, `import.meta.env` do not match.
#   - Exempt templates: names ending `.example`, `.sample`, `.template`, `.dist`.
#   - A segment naming a protected file is ALLOWED only when its command is
#     name-only: `ls`, `test`, `[`, `[[`, `find` (no -exec/-execdir/-ok/
#     -delete/-fprint*), `git status`, `git check-ignore`.
#   - A name-only step is allowed only as a plain top-level segment whose output
#     is not consumed. It is BLOCKED when followed by `|`/`|&` (`ls .env | xargs
#     cat`) or when nested in `$(`...`)`, backticks or `<(`/`>(` (`cat $(ls .env)`).
#   - `git add` / `git commit` segments are allowed: block-env-commit.sh owns
#     them, and a `.env` mentioned inside a commit message is not a read.
#     Exception: a commit message/template FILE option (-F/--file/-t/--template)
#     naming a protected file is blocked.
#   - Everything else is BLOCKED: cat/head/tail/grep/awk/sed/source/`.`/cp/mv/
#     rm, `< .env` redirection, interpreter one-liners, even `echo ".env"`.
#     Blocking rm/mv is deliberate: deleting these files is an operator action.
#
# Known limits: defense in depth, not a sandbox. Obfuscated access
# (`cat $(echo .e)nv`) is not caught. An app loading `.env` at runtime
# (dotenv) is not a shell token and keeps working. Other tools that merely
# mention `.env` in prose (e.g. `gh pr create --body "... .env ..."`) are
# false positives; use `--body-file`. `.envrc` (direnv) is blocked too.
#
# Contract (PreToolUse): stdin JSON; exit 0 allow; exit 2 block (stderr to
# Claude). Unparseable or missing input exits 0 (fail open).

set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"

HOOK_NAME="block-env-read"

input="$(cat 2>/dev/null || true)"

if ! command -v jq >/dev/null 2>&1; then
  printf '⚠️  atelier:%s — jq missing; hook safety layer degraded, failing open (allow)\n' "$HOOK_NAME" >&2
  log_decision "$HOOK_NAME" "?" "" "allow" "jq missing — hook degraded to allow"
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

[ "$tool_name" = "Bash" ] || exit 0
[ -n "$command_str" ] || exit 0

# Cheap pre-filter: nothing to do unless `.env` appears at all.
case "$command_str" in
  *.env*) ;;
  *) exit 0 ;;
esac

# Protected names in a segment, one per line.
protected_tokens() {
  printf '%s\n' "$1" \
    | grep -Eo "(^|[[:space:]/'\"<>=(:{,])\\.env[^[:space:]/'\"<>;|&)\`{},]*" \
    | sed -E 's/^[^.]*//' \
    | grep -Ev '\.(example|sample|template|dist)$' || true
  # Attached short option on a commit (`git commit -F.env`, `-aF.env`).
  case "$1" in
    *commit*)
      printf '%s\n' "$1" \
        | grep -Eo "(^|[[:space:]])-[A-Za-z]*[Ft]\\.env[^[:space:]'\"<>;|&)\`]*" \
        | sed -E 's/^[^.]*//' \
        | grep -Ev '\.(example|sample|template|dist)$' || true ;;
  esac
}

# First command word of a segment, skipping leading `VAR=val` assignments,
# `sudo`/`command`/`builtin`/`exec`, and leading `(`/`{`/`!`.
first_words() {
  local seg="$1" w
  set -f
  # shellcheck disable=SC2086
  set -- $seg
  set +f
  while [ $# -gt 0 ]; do
    w="${1#[(\{!]}"
    case "$w" in
      "") shift ;;
      [A-Za-z_]*=*) shift ;;
      sudo|command|builtin|exec) shift ;;
      *) break ;;
    esac
  done
  printf '%s %s' "${w:-}" "${2:-}"
}

# 0 when the segment is allowed to name a protected file.
segment_is_name_only() {
  local seg="$1" words cmd sub
  words="$(first_words "$seg")"
  cmd="${words%% *}"
  sub="${words#* }"
  cmd="${cmd##*/}"
  case "$cmd" in
    ls|test|"["|"[[") return 0 ;;
    find)
      printf '%s' "$seg" | grep -Eq '(^|[[:space:]])-(exec|execdir|ok|okdir|delete|fprint[0a-z]*|fls)([[:space:]]|$)' && return 1
      return 0 ;;
    git)
      # Subcommand after optional `-C <path>` / `-c k=v` options.
      sub="$(printf '%s' "$seg" | sed -E 's/^.*(^|[[:space:]])git[[:space:]]+((-C|-c)[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)[[:space:]]+)*//' | awk '{print $1}')"
      case "$sub" in
        status|check-ignore|add) return 0 ;;
        commit)
          # `-m` text merely mentioning the name is fine; a message/template
          # FILE that is a protected env file puts its contents in history.
          printf '%s' "$seg" \
            | grep -Eo "(^|[[:space:]])(-[A-Za-z]*[Ft]|--file|--template)(=|[[:space:]]+)?['\"]?([^[:space:]'\"]*/)?\.env[^[:space:]'\"<>;|&)\`]*" \
            | grep -Evq '\.(example|sample|template|dist)$' && return 1
          return 0 ;;
      esac
      return 1 ;;
  esac
  return 1
}

PIPE_MARK="@@PIPE@@"
SUB_MARK="@@SUB@@"
blocked_token=""
allowed_token=""
prev_listing_token=""
while IFS= read -r seg; do
  # A name-only listing step whose output feeds a pipe is a read in disguise
  # (`ls .env | xargs cat`, `find . -name .env -print0 | xargs -0 cat`).
  piped=0
  nested=0
  case "$seg" in "$PIPE_MARK"*) piped=1; seg="${seg#"$PIPE_MARK"}" ;; esac
  case "$seg" in "$SUB_MARK"*) nested=1; seg="${seg#"$SUB_MARK"}" ;; esac
  if [ "$piped" = 1 ] && [ -n "$prev_listing_token" ]; then
    blocked_token="$prev_listing_token"
    break
  fi
  [ "$nested" = 1 ] || prev_listing_token=""
  tokens="$(protected_tokens "$seg")"
  [ -n "$tokens" ] || continue
  # Inside `$(`, backticks or `<(`/`>(`: the output is consumed by something
  # else, so naming a protected file there is never a plain name-only check.
  if [ "$nested" = 1 ]; then
    blocked_token="$(printf '%s' "$tokens" | head -n1)"
    break
  fi
  if segment_is_name_only "$seg"; then
    allowed_token="$(printf '%s' "$tokens" | head -n1)"
    prev_listing_token="$allowed_token"
  else
    blocked_token="$(printf '%s' "$tokens" | head -n1)"
    break
  fi
done < <(printf '%s\n' "$command_str" \
  | sed -E -e 's/&&|\|\||;/\
/g' \
        -e 's/(^|[^|<>&])&($|[^>&])/\1\
\2/g' \
        -e 's/\$\(|<\(|>\(|`/\
'"$SUB_MARK"'/g' \
  | sed -E 's/\|/\
'"$PIPE_MARK"'/g')

if [ -z "$blocked_token" ]; then
  if [ -n "$allowed_token" ]; then
    log_decision "$HOOK_NAME" "Bash" ".env-name-only" "allow" "name-only use of $allowed_token"
  fi
  exit 0
fi

cat >&2 <<MSG
🚫 atelier:block-env-read BLOCKED
   Tool:    Bash
   Reason:  the command names a protected env file: $blocked_token
   Rule:    PLAN.md §3 — .env* contents are operator-only; agents must not read, copy, move or delete them.
   Action:  ask the operator for the specific variable names you need. Name-only checks (ls, test -f, find -name) and .env.example/.sample/.template/.dist templates are allowed.
MSG

log_decision "$HOOK_NAME" "Bash" ".env-read" "block" "blocked command naming $blocked_token"

exit 2
