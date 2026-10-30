#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Bash (#666). Keeps chain subagents from writing
# to the real project memory store ($ATELIER_CONFIG_DIR/atelier/memory.db or
# ~/.claude-work/atelier/memory.db). Top-level sessions own real-store writes;
# subagents may run read-only subcommands or write to an isolated config dir.

# shellcheck disable=SC2016,SC2088,SC1003
set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"

HOOK_NAME="block-subagent-memory-write"
input="$(cat 2>/dev/null || true)"

if ! command -v jq >/dev/null 2>&1; then
  printf '⚠️  atelier:%s — jq missing; hook safety layer degraded, failing open (allow)\n' "$HOOK_NAME" >&2
  log_decision "$HOOK_NAME" "?" "" "allow" "jq missing — hook degraded to allow"
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ "$tool_name" = "Bash" ] || exit 0
command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
case "$command_str" in *atelier-memory*) ;; *) exit 0 ;; esac

agent_id="$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null || true)"
agent_type="$(printf '%s' "$input" | jq -r '.agent_type // empty' 2>/dev/null || true)"
[ -z "$agent_id" ] && [ -z "$agent_type" ] && [ "${CLAUDE_CODE_CHILD_SESSION:-}" != "1" ] && exit 0

HOME_DIR="${HOME:-}"
DEF_ACD="$HOME_DIR/.claude-work"
REAL_ACD="${ATELIER_CONFIG_DIR:-$DEF_ACD}"
# shellcheck source=lib/shell-lex.sh
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/shell-lex.sh"

ASSIGN_RE='^[A-Za-z_][A-Za-z0-9_]*='
REDIR_RE='^([0-9]*>>?|[0-9]*<<?|&>>?|[0-9]*<>&?[0-9-]*)'
S_CFG_STATE=""; S_CFG_VAL=""; S_CFG_LOCAL=""; S_CFG_LOCAL_VAL=""
S_ALLOW="${ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE:-}"
E_CFG_STATE=""; E_CFG_VAL=""; E_ALLOW=""; E_UNK=""; ENV_UNK_IN=""; CUR_SEG_TEXT=""

vmap_set() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && printf -v "V__$1" '%s' "$2" || true; }
vmap_unset() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && unset "V__$1" || true; }

apply_assign() { # P name value
  case "$2" in
    ATELIER_CONFIG_DIR) printf -v "$1_CFG_STATE" '%s' "set"; printf -v "$1_CFG_VAL" '%s' "$3" ;;
    ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE) printf -v "$1_ALLOW" '%s' "$3" ;;
  esac
}

shell_assign() { # name value exported
  vmap_set "$1" "$2"
  [ "$1" = "ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE" ] && { S_ALLOW="$2"; return; }
  [ "$1" = "ATELIER_CONFIG_DIR" ] || return 0
  if [ "$3" = "1" ] || [ "$S_CFG_STATE" = "set" ] || { [ -z "$S_CFG_STATE" ] && [ -n "${ATELIER_CONFIG_DIR+x}" ]; }; then
    S_CFG_STATE="set"; S_CFG_VAL="$2"
  else
    S_CFG_LOCAL="set"; S_CFG_LOCAL_VAL="$2"
  fi
}

shell_export_bare() {
  [ "$1" = "ATELIER_CONFIG_DIR" ] && [ -n "$S_CFG_LOCAL" ] && { S_CFG_STATE="set"; S_CFG_VAL="$S_CFG_LOCAL_VAL"; }
}

apply_unset() { # P name
  [ "$1" = "S" ] && { vmap_unset "$2"; [ "$2" = "ATELIER_CONFIG_DIR" ] && { S_CFG_LOCAL=""; S_CFG_LOCAL_VAL=""; }; }
  case "$2" in
    ATELIER_CONFIG_DIR) printf -v "$1_CFG_STATE" '%s' "cleared"; printf -v "$1_CFG_VAL" '%s' "" ;;
    ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE) printf -v "$1_ALLOW" '%s' "" ;;
  esac
}

block() { # reason detail
  cat >&2 <<MSG
🚫 atelier:block-subagent-memory-write BLOCKED
   Tool:    Bash
   Command: ${CUR_SEG_TEXT:0:300}
   Reason:  $1
   Detail:  $2
   Rule:    PLAN.md §3 & §17 / operator-rules.md — chain subagents never write to the real project memory store; top-level sessions own real-store writes (add, supersede, close, import).
   Action:  For tests, pass an isolated ATELIER_CONFIG_DIR (e.g. ATELIER_CONFIG_DIR="\$(mktemp -d)" or /tmp/...). For real memory capture, report the item in your hand-back so the top-level session records it.
MSG
  log_decision "$HOOK_NAME" "Bash" "$1" "block" "$2"
  exit 2
}

_realpath_lenient() { # path [depth]
  local p="$1" depth="${2:-0}" rest="" d b t
  while [[ "$p" == *//* ]]; do p="${p//\/\///}"; done
  while [[ "$p" == */./* ]]; do p="${p//\/.\///}"; done
  [ "${#p}" -gt 1 ] && p="${p%/}"
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
  if [ -d "$p" ]; then p="$(cd -P "$p" 2>/dev/null && pwd -P)" || true
  else d="${p%/*}"; [ -z "$d" ] && d=/; b="${p##*/}"; d="$(cd -P "$d" 2>/dev/null && pwd -P)" || d="${p%/*}"; p="${d%/}/$b"; fi
  printf '%s' "$p$rest"
}

EXP_CFG=""
expand_cfg() {
  local v="$1" pass=0 re1='^(.*)\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$' re2='^(.*)\$([A-Za-z_][A-Za-z0-9_]*)(.*)$' pre vn post vk
  v="${v//\$\{TMPDIR:-\/tmp\}/${TMPDIR:-/tmp}}"; v="${v//\$\{TMPDIR-\/tmp\}/${TMPDIR:-/tmp}}"
  v="${v//\$\$/0}"; v="${v//\$RANDOM/0}"
  while [ "$pass" -lt 6 ]; do
    pass=$((pass + 1))
    case "$v" in "~") v="$HOME_DIR" ;; "~/"*) v="$HOME_DIR/${v#\~/}" ;; esac
    if [[ "$v" =~ $re1 ]] || [[ "$v" =~ $re2 ]]; then
      pre="${BASH_REMATCH[1]}"; vn="${BASH_REMATCH[2]}"; post="${BASH_REMATCH[3]}"; vk="V__$vn"
      if [ -n "${!vk+x}" ]; then v="$pre${!vk}$post"; continue
      elif [ "$vn" = "HOME" ]; then v="$pre$HOME_DIR$post"; continue
      elif [ "$vn" = "ATELIER_CONFIG_DIR" ]; then v="$pre$REAL_ACD$post"; continue
      elif [ "$vn" = "TMPDIR" ]; then v="$pre${TMPDIR:-/tmp}$post"; continue; fi
    fi
    break
  done
  case "$v" in "~") v="$HOME_DIR" ;; "~/"*) v="$HOME_DIR/${v#\~/}" ;; esac
  EXP_CFG="$v"
}

CFG_WHY=""
cfg_isolated() {
  local raw="$1" p cv cr cd_ ch mk_re='^(\$\(mktemp|`mktemp)([[:space:])`]|$)' dot_re='(^|/)\.\.(/|$)'
  [ -z "$raw" ] && { CFG_WHY="ATELIER_CONFIG_DIR is set to an empty string"; return 1; }
  expand_cfg "$raw"; p="$EXP_CFG"
  [ -z "$p" ] && { CFG_WHY="ATELIER_CONFIG_DIR='$raw' resolves to an empty string"; return 1; }
  [[ "$p" =~ $dot_re ]] && { CFG_WHY="ATELIER_CONFIG_DIR='$raw' contains '..' path traversal"; return 1; }
  [[ "$p" =~ $mk_re ]] && return 0
  case "$p" in *'$'*|*'`'*) CFG_WHY="ATELIER_CONFIG_DIR='$raw' uses a dynamic value that cannot be proven isolated"; return 1 ;; esac
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  cv="$(_realpath_lenient "$p")"; cr="$(_realpath_lenient "$REAL_ACD")"; cd_="$(_realpath_lenient "$DEF_ACD")"; ch="$(_realpath_lenient "$HOME_DIR")"
  if [ "$cv" = "$cr" ] || [[ "$cv" == "$cr"/* ]] || [ "$cv" = "$cd_" ] || [[ "$cv" == "$cd_"/* ]]; then
    CFG_WHY="ATELIER_CONFIG_DIR resolves to the real config dir ($cv)"; return 1
  fi
  [ "$cv" = "/" ] || [ "$cv" = "$ch" ] && { CFG_WHY="ATELIER_CONFIG_DIR resolves to '$cv', which is not an isolated directory"; return 1; }
  return 0
}

check_write() { # label
  [ -n "${E_UNK:-}" ] && block "$1 behind an unrecognised env option ($E_UNK)" "env $E_UNK may alter ATELIER_CONFIG_DIR"
  [ "$E_ALLOW" = "1" ] && { log_decision "$HOOK_NAME" "Bash" "$1" "allow" "ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE=1"; return 0; }
  case "$E_CFG_STATE" in
    cleared) block "$1 with ATELIER_CONFIG_DIR unset" "unsetting ATELIER_CONFIG_DIR makes atelier-memory fall back to ~/.claude-work (the real store)" ;;
    set) ;;
    *) [ -n "$S_CFG_LOCAL" ] && block "$1 with unexported ATELIER_CONFIG_DIR" "ATELIER_CONFIG_DIR was assigned without export"
       block "$1 against the real project memory store" "ATELIER_CONFIG_DIR is not overridden to an isolated directory" ;;
  esac
  cfg_isolated "$E_CFG_VAL" || block "$1 with non-isolated ATELIER_CONFIG_DIR" "$CFG_WHY"
  log_decision "$HOOK_NAME" "Bash" "$1" "allow" "isolated ATELIER_CONFIG_DIR"
}

analyze_memory() { # args after atelier-memory
  local a sub="" has_dry=0 end_opts=0 skip_redir=0
  for a in "$@"; do
    [ "$skip_redir" = 1 ] && { skip_redir=0; continue; }
    [[ "$a" =~ ^([0-9]*>>?|[0-9]*<<?|&>>?)$ ]] && { skip_redir=1; continue; }
    [[ "$a" =~ $REDIR_RE ]] && continue
    if [ "$end_opts" = 0 ]; then
      case "$a" in --) end_opts=1; continue ;; -h|--help) return 0 ;; --dry-run) has_dry=1 ;; esac
    fi
    [ -z "$sub" ] && sub="$a"
  done
  [ -z "$sub" ] && return 0
  case "$sub" in *'$'*) expand_cfg "$sub"; sub="$EXP_CFG" ;; esac
  case "$sub" in
    list|show|search|brief|path|render|-h|--help) return 0 ;;
    import) [ "$has_dry" = 1 ] && return 0; check_write "atelier-memory import" ;;
    add|supersede|close|*'$'*|*'`'*) check_write "atelier-memory $sub" ;;
  esac
}

scan_subst() { # token depth
  local tok="$1" depth="$2" rest kind len inner
  while :; do
    case "$tok" in
      *'$('*) rest="${tok#*'$('}"; rest='$('"$rest"; kind='$' ;;
      *'`'*) rest="${tok#*\`}"; rest='`'"$rest"; kind='`' ;;
      *) return 0 ;;
    esac
    len="$(_subst_len "$kind" "$rest")"
    if [ "$len" -eq 0 ]; then inner="${rest:1}"; tok=""
    elif [ "$kind" = '`' ]; then inner="${rest:1:$((len - 2))}"; tok="${rest:$len}"
    else inner="${rest:2:$((len - 3))}"; tok="${rest:$len}"; fi
    ( process_script "$inner" $((depth + 1)) ) || exit $?
    [ "$len" -eq 0 ] && return 0
  done
}

process_script() { # script depth
  local script="$1" depth="$2" out seg nt i j k c rest t base sub do_split env_split E_UNK xflag has_c
  [ "$depth" -gt 4 ] && return 0
  local -a toks
  lex "$script"; out="$LEX_OUT"
  while [ -n "$out" ]; do
    seg="${out%%"$RS"*}"; out="${out:$((${#seg} + 1))}"
    [ -z "$seg" ] && continue
    split_tokens "$seg"; toks=(${TOKS[@]+"${TOKS[@]}"}); nt=${#toks[@]}
    [ "$nt" -eq 0 ] && continue
    CUR_SEG_TEXT="${toks[*]}"
    E_UNK="$ENV_UNK_IN"; ENV_UNK_IN=""
    E_CFG_STATE="$S_CFG_STATE"; E_CFG_VAL="$S_CFG_VAL"; E_ALLOW="$S_ALLOW"
    for t in "${toks[@]}"; do case "$t" in *'$('*|*'`'*) scan_subst "$t" "$depth" ;; esac; done
    i=0
    while [ "$i" -lt "$nt" ]; do
      t="${toks[$i]}"
      case "$t" in *'$'*) expand_cfg "$t"; base="${EXP_CFG##*/}" ;; *) base="${t##*/}" ;; esac
      if [[ "$t" =~ $ASSIGN_RE ]]; then apply_assign E "${t%%=*}" "${t#*=}"; i=$((i + 1)); continue; fi
      case "$base" in
        if|then|do|else|elif|while|until|'{'|'!') i=$((i + 1)); continue ;;
        env)
          i=$((i + 1))
          while [ "$i" -lt "$nt" ]; do
            t="${toks[$i]}"; do_split=0
            if [[ "$t" =~ $ASSIGN_RE ]]; then apply_assign E "${t%%=*}" "${t#*=}"; i=$((i + 1))
            elif [ "$t" = "-" ] || [ "$t" = "--ignore-environment" ]; then
              apply_unset E ATELIER_CONFIG_DIR; apply_unset E ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE; i=$((i + 1))
            elif { [ "$t" = "--unset" ] || [ "$t" = "--split-string" ] || [ "$t" = "--chdir" ] || [ "$t" = "--path" ] || [ "$t" = "--argv0" ]; }; then
              [ "$t" = "--unset" ] && [ $((i + 1)) -lt "$nt" ] && apply_unset E "${toks[$((i + 1))]}"
              [ "$t" = "--split-string" ] && { sub="${toks[$((i + 1))]:-}"; do_split=1; }
              i=$((i + 2))
            elif [[ "$t" == --unset=* ]]; then apply_unset E "${t#--unset=}"; i=$((i + 1))
            elif [[ "$t" == --split-string=* ]]; then sub="${t#--split-string=}"; do_split=1; i=$((i + 1))
            elif [[ "$t" == --chdir=* || "$t" == --path=* || "$t" == --argv0=* || "$t" == --block-signal* || "$t" == --default-signal* || "$t" == --ignore-signal* ]] \
              || [ "$t" = "--null" ] || [ "$t" = "--debug" ] || [ "$t" = "--list-signal-handling" ]; then i=$((i + 1))
            elif [[ "$t" == -[!-]* ]]; then
              i=$((i + 1)); k=1
              while [ "$k" -lt "${#t}" ]; do
                c="${t:$k:1}"; k=$((k + 1))
                case "$c" in
                  i) apply_unset E ATELIER_CONFIG_DIR; apply_unset E ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE ;;
                  0|v) ;;
                  u|S|C|P|a)
                    rest="${t:$k}"; k=${#t}; [ -z "$rest" ] && [ "$i" -lt "$nt" ] && { rest="${toks[$i]}"; i=$((i + 1)); }
                    [ "$c" = "u" ] && [ -n "$rest" ] && apply_unset E "$rest"
                    [ "$c" = "S" ] && { sub="$rest"; do_split=1; } ;;
                  *) E_UNK="-$c" ;;
                esac
              done
            elif [ "${t:0:1}" = "-" ]; then E_UNK="$t"; i=$((i + 1))
            else break; fi
            if [ "$do_split" = 1 ]; then
              for ((j = i; j < nt; j++)); do sub+=" ${toks[$j]}"; done
              case "$sub" in -*) sub="env $sub" ;; esac
              ( S_CFG_STATE="$E_CFG_STATE"; S_CFG_VAL="$E_CFG_VAL"; S_CFG_LOCAL=""; S_ALLOW="$E_ALLOW"; ENV_UNK_IN="$E_UNK"; process_script "$sub" $((depth + 1)) ) || exit $?
              env_split=1; i=$nt
            fi
          done
          continue ;;
        command|exec|nohup|time|builtin|sudo|nice|stdbuf|timeout|setsid|caffeinate|xargs|ionice|coproc)
          i=$((i + 1)); while [ "$i" -lt "$nt" ]; do case "${toks[$i]}" in -*|[0-9]*) i=$((i + 1)) ;; *) break ;; esac; done; continue ;;
        bash|sh|zsh|dash|ksh|source|.)
          has_c=0
          for ((j = i + 1; j < nt; j++)); do
            [[ "${toks[$j]}" =~ ^-[A-Za-z]*c[A-Za-z]*$ ]] && { has_c=1; break; }
            [[ "${toks[$j]}" == -* ]] || break
          done
          [ "$has_c" = 0 ] && [ "$j" -lt "$nt" ] && { i=$j; continue; } ;;
      esac
      break
    done
    [ "${env_split:-}" = 1 ] && { env_split=""; continue; }
    if [ "$i" -ge "$nt" ]; then
      for t in "${toks[@]}"; do [[ "$t" =~ $ASSIGN_RE ]] && shell_assign "${t%%=*}" "${t#*=}" 0; done
      continue
    fi
    t="${toks[$i]}"
    case "$t" in *'$'*) expand_cfg "$t"; base="${EXP_CFG##*/}" ;; *) base="${t##*/}" ;; esac
    case "$base" in
      export|declare|typeset|readonly|local)
        xflag=0; [ "$base" = "export" ] && xflag=1
        for ((j = i + 1; j < nt; j++)); do
          t="${toks[$j]}"
          if [[ "$t" =~ ^-[A-Za-z]*x ]]; then xflag=1
          elif [[ "$t" =~ ^\+[A-Za-z]*x ]]; then xflag=0
          elif [[ "$t" =~ $ASSIGN_RE ]]; then shell_assign "${t%%=*}" "${t#*=}" "$xflag"
          elif [ "$xflag" = 1 ] && [ "${t:0:1}" != "-" ]; then shell_export_bare "$t"; fi
        done ;;
      unset) for ((j = i + 1; j < nt; j++)); do t="${toks[$j]}"; [ "${t:0:1}" = "-" ] || apply_unset S "$t"; done ;;
      atelier-memory) analyze_memory "${toks[@]:$((i + 1))}" ;;
      bash|sh|zsh|dash|ksh)
        for ((j = i + 1; j < nt; j++)); do
          if [[ "${toks[$j]}" =~ ^-[A-Za-z]*c[A-Za-z]*$ ]] && [ $((j + 1)) -lt "$nt" ]; then
            ( S_CFG_STATE="$E_CFG_STATE"; S_CFG_VAL="$E_CFG_VAL"; S_CFG_LOCAL=""; S_ALLOW="$E_ALLOW"; ENV_UNK_IN="$E_UNK"; process_script "${toks[$((j + 1))]}" $((depth + 1)) ) || exit $?
            break
          fi
        done ;;
      eval)
        sub="${toks[*]:$((i + 1))}"
        if [ -n "$sub" ]; then
          if [ "$i" -gt 0 ]; then ( S_CFG_STATE="$E_CFG_STATE"; S_CFG_VAL="$E_CFG_VAL"; S_ALLOW="$E_ALLOW"; ENV_UNK_IN="$E_UNK"; process_script "$sub" $((depth + 1)) ) || exit $?
          else process_script "$sub" $((depth + 1)); fi
        fi ;;
    esac
  done
}

scan_str="$(strip_heredocs "$command_str")"
process_script "$scan_str" 0
exit 0
