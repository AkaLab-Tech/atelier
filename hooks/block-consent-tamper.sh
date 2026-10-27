#!/usr/bin/env bash
#
# atelier — PreToolUse tamper guard for the operator-consent state (#638 / #639,
# narrowed in #651). Blocks Bash / Edit / Write / MultiEdit / NotebookEdit / Read
# calls that address $ATELIER_CONFIG_DIR/state/consent as a PATH, so an agent
# cannot read pending records, forge a grant, or rewrite the ledger. Not
# consent-eligible itself.
#
# What is inspected (free-text mentions are NOT blocked):
#   - File tools: only .tool_input.file_path / .path / .notebook_path. `content`,
#     `old_string`, `new_string`, `edits[]`, `new_source` are ignored.
#   - Bash: the command is lexed (hooks/lib/shell-lex.sh) into segments and
#     tokens. Redirection targets are always checked. Per command word:
#       echo/printf/:/true   operands are prose, only redirections are checked;
#       grep family          the search pattern is dropped, `-f FILE` and the
#                            remaining operands are checked as paths;
#       git                  values of -m/-S/-G/--grep/--format/--pretty are
#                            dropped; -F/--file/-t/--template values are paths;
#       gh                   --title/--body/-f/-F/--field values are dropped;
#                            --body-file/--input values are paths;
#       anything else        deny by default: any token that is a consent path
#                            or merely contains `state/consent` blocks (inline
#                            scripts such as `bash -c` / `python -c` are code).
#     `$(...)` / backtick substitutions are re-scanned recursively (depth 4) in
#     every command class. Heredoc bodies that do not feed a shell are dropped.
#   A path counts as consent state when, lower-cased with `//` and `/./`
#   collapsed and a leading `~` / $HOME / $ATELIER_CONFIG_DIR expanded, it has
#   `state/consent` as path components or lies under the resolved root; absolute
#   paths whose deepest existing ancestor resolves (symlinks) into the root count.
#
# Residual gaps (documented in PLAN.md §3): hooks run as the same OS user, so an
# obfuscated reference (string pieces built by a subshell, variable indirection,
# encoding), a Bash path that only reaches the root through a symlink, or a
# script written first and run later can evade this lexical check. The
# template's Edit/Write(**/state/consent/**) deny is a second layer, not a
# closure.
#
# Contract: stdin JSON { tool_name, tool_input }; exit 0 allow, exit 2 block.
# jq missing -> fail open (like the other block-* hooks).

# shellcheck disable=SC2016,SC2088,SC1003
set -uo pipefail

PLUGIN_HOOKS="${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks"
# shellcheck source=lib/log-decision.sh
source "$PLUGIN_HOOKS/lib/log-decision.sh"
# shellcheck source=lib/consent.sh
source "$PLUGIN_HOOKS/lib/consent.sh"
# shellcheck source=lib/shell-lex.sh
source "$PLUGIN_HOOKS/lib/shell-lex.sh"

HOOK_NAME="block-consent-tamper"

input="$(cat 2>/dev/null || true)"

if ! command -v jq >/dev/null 2>&1; then
  printf '⚠️  atelier:%s — jq missing; hook safety layer degraded, failing open (allow)\n' "$HOOK_NAME" >&2
  log_decision "$HOOK_NAME" "?" "" "allow" "jq missing — hook degraded to allow"
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$tool_name" in
  Bash|Edit|Write|MultiEdit|NotebookEdit|Read) ;;
  *) exit 0 ;;
esac

HOME_DIR="${HOME:-}"
ACD="${ATELIER_CONFIG_DIR:-$HOME_DIR/.claude-work}"
ROOT="$(_consent_root)"
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
HOME_L="$(lower "$HOME_DIR")"
ACD_L="$(lower "$ACD")"
ROOT_L="$(lower "$ROOT")"

deny() { # detail
  cat >&2 <<MSG
🚫 atelier:block-consent-tamper BLOCKED
   Tool:    $tool_name
   Reason:  the call addresses the operator-consent state directory (state/consent) as a path
   Rule:    PLAN.md §3 "Operator consent override (#638)" — consent state is written only by atelier's hooks, never by tool calls.
   Override: none from inside this session.
MSG
  log_decision "$HOOK_NAME" "$tool_name" "consent-state" "block" "$1"
  exit 2
}

# Prefix expansion: ~, $HOME, ${HOME}, $ATELIER_CONFIG_DIR, ${ATELIER_CONFIG_DIR}
# (either case). Args: string, home, config dir.
_expand() {
  local s="$1" pat
  case "$s" in
    '~'|'~/'*) printf '%s' "$2${s#\~}"; return ;;
  esac
  for pat in '${HOME}' '${home}' '$HOME' '$home'; do
    case "$s" in "$pat"*) printf '%s' "$2${s#"$pat"}"; return ;; esac
  done
  for pat in '${ATELIER_CONFIG_DIR}' '${atelier_config_dir}' '$ATELIER_CONFIG_DIR' '$atelier_config_dir'; do
    case "$s" in "$pat"*) printf '%s' "$3${s#"$pat"}"; return ;; esac
  done
  printf '%s' "$s"
}

# Resolve the deepest existing ancestor (and any final symlink) physically,
# then re-append the non-existing remainder.
_realpath_lenient() { # path [depth]
  local p="$1" depth="${2:-0}" rest="" d b t
  [ "$depth" -gt 8 ] && { printf '%s' "$p"; return; }
  while [ -n "$p" ] && [ "$p" != / ] && [ ! -e "$p" ] && [ ! -L "$p" ]; do
    rest="/${p##*/}$rest"; p="${p%/*}"
  done
  [ -z "$p" ] && p=/
  if [ -L "$p" ]; then
    t="$(readlink "$p" 2>/dev/null || true)"
    case "$t" in /*) ;; *) t="${p%/*}/$t" ;; esac
    _realpath_lenient "$t$rest" $((depth + 1)); return
  fi
  if [ -d "$p" ]; then
    p="$(cd -P "$p" 2>/dev/null && pwd -P)" || true
  else
    d="${p%/*}"; [ -z "$d" ] && d=/
    b="${p##*/}"
    d="$(cd -P "$d" 2>/dev/null && pwd -P)" || d="${p%/*}"
    p="${d%/}/$b"
  fi
  printf '%s' "$p$rest"
}

_resolves_into_root() { # absolute path
  local rp rr
  rp="$(_realpath_lenient "$1")"; rr="$(_realpath_lenient "$ROOT")"
  [ "$rp" = "$rr" ] || [[ "$rp" == "$rr"/* ]]
}

COMP_RE='(^|/)state/consent(/|$)'
is_consent_path() {
  local o p
  [ -n "$1" ] || return 1
  o="$(_expand "$1" "$HOME_DIR" "$ACD")"
  p="$(lower "$(_expand "$1" "$HOME_L" "$ACD_L")")"
  while [[ "$p" == *//* ]]; do p="${p//\/\///}"; done
  while [[ "$p" == */./* ]]; do p="${p//\/.\///}"; done
  [[ "$p" =~ $COMP_RE ]] && return 0
  [ "$p" = "$ROOT_L" ] && return 0
  [[ "$p" == "$ROOT_L"/* ]] && return 0
  case "$o" in /*) _resolves_into_root "$o" && return 0 ;; esac
  return 1
}

check_tok() { # token — path-shaped check, including the value of --opt=value
  local t="$1"
  if is_consent_path "$t"; then deny "path argument resolves into state/consent"; fi
  case "$t" in -*=*) if is_consent_path "${t#*=}"; then deny "option value resolves into state/consent"; fi ;; esac
  return 0
}

scan_script() { # script depth
  local script="$1" depth="$2" seg t lc
  local -a segs
  if [ "$depth" -gt 4 ]; then
    lc="$(lower "$script")"
    case "$lc" in *state/consent*) deny "nested substitution too deep, mentions state/consent" ;; esac
    return 0
  fi
  script="$(strip_heredocs "$script")"
  lex "$script"
  IFS="$RS" read -r -d '' -a segs <<< "$LEX_OUT" || true
  for seg in ${segs[@]+"${segs[@]}"}; do
    [ -n "$seg" ] || continue
    split_tokens "$seg"
    scan_segment "$depth" ${TOKS[@]+"${TOKS[@]}"}
  done
}

scan_subst() { # token depth — re-scan every $(...) / `...` inside the token
  local tok="$1" depth="$2" rest kind len inner
  while :; do
    case "$tok" in
      *'$('*) rest="${tok#*'$('}"; rest='$('"$rest"; kind='$' ;;
      *'`'*) rest="${tok#*\`}"; rest='`'"$rest"; kind='`' ;;
      *) return 0 ;;
    esac
    len="$(_subst_len "$kind" "$rest")"
    if [ "$len" -eq 0 ]; then inner="${rest:1}"; tok=""
    else
      if [ "$kind" = '`' ]; then inner="${rest:1:$((len - 2))}"; else inner="${rest:2:$((len - 3))}"; fi
      tok="${rest:$len}"
    fi
    scan_script "$inner" $((depth + 1))
    [ "$len" -eq 0 ] && return 0
  done
}

REDIR_RE='^[0-9]*(>>|>\||&>|>|<)(.*)$'
ASSIGN_RE='^[A-Za-z_][A-Za-z0-9_]*=(.*)$'

scan_grep() {
  local -a a=("$@"); local n=${#a[@]} j=0 t pat=0 endo=0
  while [ "$j" -lt "$n" ]; do
    t="${a[$j]}"; j=$((j + 1))
    if [ "$endo" = 0 ]; then
      case "$t" in
        --) endo=1; continue ;;
        --regexp|-e) pat=1; j=$((j + 1)); continue ;;
        --regexp=*) pat=1; continue ;;
        --file|-f) pat=1; [ "$j" -lt "$n" ] && check_tok "${a[$j]}"; j=$((j + 1)); continue ;;
        --file=*) pat=1; check_tok "${t#*=}"; continue ;;
        --exclude-from|--ignore-file|--pre|--hostname-bin)
          [ "$j" -lt "$n" ] && check_tok "${a[$j]}"; j=$((j + 1)); continue ;;
        --*) check_tok "$t"; continue ;;
        -*[ef]) pat=1; if [ "${t: -1}" = f ]; then [ "$j" -lt "$n" ] && check_tok "${a[$j]}"; fi
                j=$((j + 1)); continue ;;
        -e?*) pat=1; continue ;;
        -f?*) pat=1; check_tok "${t#-f}"; check_tok "$t"; continue ;;
        -*) check_tok "$t"; continue ;;
      esac
    fi
    if [ "$pat" = 0 ]; then pat=1; else check_tok "$t"; fi
  done
}

scan_git() {
  local -a a=("$@"); local n=${#a[@]} j=0 t sub=""
  while [ "$j" -lt "$n" ]; do
    t="${a[$j]}"; j=$((j + 1))
    if [ -z "$sub" ]; then
      case "$t" in
        -C) [ "$j" -lt "$n" ] && check_tok "${a[$j]}"; j=$((j + 1)); continue ;;
        -c) [ "$j" -lt "$n" ] && check_tok "x=${a[$j]#*=}"; j=$((j + 1)); continue ;;
        --work-tree|--git-dir|--namespace|--super-prefix|--config-env|--exec-path)
          [ "$j" -lt "$n" ] && check_tok "${a[$j]}"; j=$((j + 1)); continue ;;
        -*) check_tok "$t"; continue ;;
      esac
      sub="$t"
      if [ "$sub" = grep ]; then scan_grep "${a[@]:$j}"; return 0; fi
      continue
    fi
    case "$t" in
      --message|--grep|--format|--pretty|-S|-G) j=$((j + 1)) ;;
      --message=*|--grep=*|--format=*|--pretty=*) ;;
      -F|--file|-t|--template) [ "$j" -lt "$n" ] && check_tok "${a[$j]}"; j=$((j + 1)) ;;
      --*) check_tok "$t" ;;
      -*m) j=$((j + 1)) ;;
      -m*|-S?*|-G?*) ;;
      *) check_tok "$t" ;;
    esac
  done
}

gh_field() { # key=@path makes gh read the file; -F is also --body-file/--notes-file
  case "$1" in *=@*) check_tok "${1#*=@}" ;; esac
  [ "$1" = "-" ] || check_tok "$1"
  return 0
}

scan_gh() {
  local -a a=("$@"); local n=${#a[@]} j=0 t
  while [ "$j" -lt "$n" ]; do
    t="${a[$j]}"; j=$((j + 1))
    case "$t" in
      --title|-t|--body|-b|-f|--raw-field|-H|--header) j=$((j + 1)) ;;
      --title=*|--body=*|--raw-field=*|--header=*) ;;
      -F|--field) [ "$j" -lt "$n" ] && gh_field "${a[$j]}"; j=$((j + 1)) ;;
      --field=*) gh_field "${t#*=}" ;;
      -F?*) gh_field "${t#-F}" ;;
      --body-file|--input) [ "$j" -lt "$n" ] && [ "${a[$j]}" != "-" ] && check_tok "${a[$j]}"; j=$((j + 1)) ;;
      --body-file=*|--input=*) check_tok "${t#*=}" ;;
      *) check_tok "$t" ;;
    esac
  done
}

scan_segment() { # depth tokens...
  local depth="$1"; shift
  local -a a=("$@") words=(); local n=${#a[@]} i=0 t target lc
  local rr_target rr_rest
  while [ "$i" -lt "$n" ]; do
    t="${a[$i]}"; i=$((i + 1))
    case "$t" in *'$('*|*'`'*) scan_subst "$t" "$depth" ;; esac
    if [[ "$t" =~ $REDIR_RE ]]; then
      rr_rest="${BASH_REMATCH[2]}"
      if [ -n "$rr_rest" ]; then target="$rr_rest"
      elif [ "$i" -lt "$n" ]; then
        target="${a[$i]}"; i=$((i + 1))
        case "$target" in *'$('*|*'`'*) scan_subst "$target" "$depth" ;; esac
      else target=""; fi
      rr_target="$target"
      if is_consent_path "$rr_target"; then deny "redirection target resolves into state/consent"; fi
      continue
    fi
    words+=("$t")
  done
  n=${#words[@]}; i=0
  while [ "$i" -lt "$n" ]; do
    t="${words[$i]}"
    if [[ "$t" =~ $ASSIGN_RE ]]; then
      if is_consent_path "${BASH_REMATCH[1]}"; then deny "assignment value resolves into state/consent"; fi
      i=$((i + 1)); continue
    fi
    case "${t##*/}" in
      sudo|command|env|exec) i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${words[$i]}" in -*) i=$((i + 1)) ;; *) break ;; esac
        done
        continue ;;
    esac
    break
  done
  [ "$i" -lt "$n" ] || return 0
  local cmd="${words[$i]}" base="${words[$i]##*/}"
  check_tok "$cmd"
  local -a ops=()
  [ $((i + 1)) -lt "$n" ] && ops=("${words[@]:$((i + 1))}")
  case "$base" in
    echo|printf|:|true) ;;
    grep|egrep|fgrep|rg|ag) scan_grep ${ops[@]+"${ops[@]}"} ;;
    git) scan_git ${ops[@]+"${ops[@]}"} ;;
    gh) scan_gh ${ops[@]+"${ops[@]}"} ;;
    *)
      for t in ${ops[@]+"${ops[@]}"}; do
        lc="$(lower "$t")"
        case "$lc" in *state/consent*) deny "command argument mentions state/consent" ;; esac
        check_tok "$t"
      done ;;
  esac
}

case "$tool_name" in
  Bash)
    cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
    [ -n "$cmd" ] || exit 0
    # Fast path: no "consent" even once quotes/backslashes are removed.
    flat="$(lower "$cmd" | tr -d "'\"\\\\")"
    case "$flat" in *consent*) ;; *) exit 0 ;; esac
    scan_script "$cmd" 0
    ;;
  *)
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if is_consent_path "$p"; then deny "tool path field resolves into state/consent"; fi
    done < <(printf '%s' "$input" | jq -r '[(.tool_input // {}) | objects | .file_path, .path, .notebook_path] | map(select(type == "string")) | .[]' 2>/dev/null || true)
    ;;
esac

exit 0
