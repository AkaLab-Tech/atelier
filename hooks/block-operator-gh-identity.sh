#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Bash. Stops an agent from posting a PR review,
# review comment, approval or PR conversation comment under the OPERATOR's
# GitHub identity (the personal `gh` config, an inherited/inline token), and
# from grabbing the operator's GitHub credentials.
#
# Why this hook exists (#544):
#   atelier runs two isolated gh identities ($ATELIER_CONFIG_DIR/gh/author and
#   gh/reviewer). The operator's own login lives in ~/.config/gh and must never
#   be used by an agent. Nothing in the static permission matrix stops an agent
#   from `GH_CONFIG_DIR=~/.config/gh gh pr review --approve`, from unsetting
#   GH_CONFIG_DIR, from exporting a leaked GH_TOKEN, or from lifting the token
#   (gh auth token, hosts.yml, the macOS keychain) and calling the REST API.
#   This is the categorical mechanism (PLAN.md §3), in the style of
#   block-protected-push.sh.
#
# Rule: a review-like GitHub write may only run when its effective identity
# resolves to $ATELIER_CONFIG_DIR/gh/author or $ATELIER_CONFIG_DIR/gh/reviewer
# and no GH_TOKEN / GITHUB_TOKEN / GH_ENTERPRISE_TOKEN overrides it. Review-like
# writes are exactly: `gh pr review`, `gh pr comment`, `gh api` writes to the
# PR review/comment REST endpoints, and `gh api graphql` review/comment
# mutations. Everything else (reads, board mutations, ...) is untouched.
# A GH_CONFIG_DIR assignment counts only if it reaches gh's environment: inline
# (`GH_CONFIG_DIR=x gh ...`), `env`, `export`, `declare -x` / `typeset -x`, or a
# plain assignment / `declare` without -x when GH_CONFIG_DIR is already exported
# (inherited, or an earlier export in the same command). Otherwise the value is
# shell-local, gh still uses the personal ~/.config/gh, and the call is blocked
# (until a later bare `export GH_CONFIG_DIR` promotes it).
# Credential-exfiltration shapes are blocked whatever the subcommand.
#
# Contract per Claude Code hooks reference (PreToolUse):
#   stdin  — JSON: { tool_name, tool_input: { command } }
#   exit 0 — allow the tool call
#   exit 2 — block (stderr goes to Claude's context with the explanation)
#   jq missing — fail OPEN (exit 0).
#
# Residual gaps (documented in PLAN.md §3): script files written first and run
# later, obfuscation (base64, piecewise strings, variable indirection),
# `python -c` / `node -e` using an already-leaked token.

# shellcheck disable=SC2016,SC2088,SC1003
# (literal $ / ~ / backslash in patterns are intentional: lexer and path matching)
set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"

HOOK_NAME="block-operator-gh-identity"

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

# Fast path: nothing that could touch GitHub identity or credentials.
# `gh` must be a whole word (not "high", "right", "github") so ordinary commit
# messages skip the lexer.
GH_WORD_RE='(^|[^A-Za-z0-9_])gh([^A-Za-z0-9_-]|$)'
if ! [[ "$command_str" =~ $GH_WORD_RE ]]; then
  case "$command_str" in
    *api.github.com*|*.config/gh*|*GH_TOKEN*|*GITHUB_TOKEN*|*GH_ENTERPRISE_TOKEN*|*security*|*osascript*) ;;
    *) exit 0 ;;
  esac
fi

HOME_DIR="${HOME:-}"
ACD="${ATELIER_CONFIG_DIR:-$HOME_DIR/.claude-work}"
US=$'\x1f'
RS=$'\x1e'
TOKEN_VARS="GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN"
ASSIGN_RE='^[A-Za-z_][A-Za-z0-9_]*='
MUTATIONS="addpullrequestreview|submitpullrequestreview|updatepullrequestreview|addpullrequestreviewcomment|addpullrequestreviewthread|addcomment|dismisspullrequestreview"

# ---------------------------------------------------------------------------
# Env state. S_* = what persists in the shell across segments (exports, bare
# assignments, unset); E_* = the effective env of the segment being examined
# (S_* plus its inline / `env` assignments). *_STATE: "" untouched, "set",
# "cleared"; token vars: "" untouched, "SET", "CLEARED".
S_CFG_STATE=""; S_CFG_VAL=""; S_CFG_LOCAL=""; S_CFG_LOCAL_VAL=""; S_TS_GH_TOKEN=""; S_TS_GITHUB_TOKEN=""; S_TS_GH_ENTERPRISE_TOKEN=""
E_CFG_STATE=""; E_CFG_VAL=""; E_TS_GH_TOKEN=""; E_TS_GITHUB_TOKEN=""; E_TS_GH_ENTERPRISE_TOKEN=""
CUR_SEG_TEXT=""

apply_assign() { # P name value
  case "$2" in
    GH_CONFIG_DIR) printf -v "$1_CFG_STATE" '%s' "set"; printf -v "$1_CFG_VAL" '%s' "$3" ;;
    GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN)
      if [ -n "$3" ]; then printf -v "$1_TS_$2" '%s' "SET"; else printf -v "$1_TS_$2" '%s' "CLEARED"; fi ;;
  esac
}

# Shell-level assignment (bare `NAME=v`, export, declare, ...). `exported` is
# 1 for export / declare -x / typeset -x, 0 otherwise. A GH_CONFIG_DIR that is
# not exported never reaches gh, so a non-exporting assignment only takes effect
# when the variable is already exported (inherited, or an earlier export in
# this command); otherwise it is remembered as shell-local (S_CFG_LOCAL) and
# only a later `export GH_CONFIG_DIR` promotes it.
shell_assign() { # name value exported
  if [ "$1" != "GH_CONFIG_DIR" ]; then apply_assign S "$1" "$2"; return; fi
  if [ "$3" = "1" ] || [ "$S_CFG_STATE" = "set" ] || { [ -z "$S_CFG_STATE" ] && [ -n "${GH_CONFIG_DIR+x}" ]; }; then
    S_CFG_STATE="set"; S_CFG_VAL="$2"
  else
    S_CFG_LOCAL="set"; S_CFG_LOCAL_VAL="$2"
  fi
}

# `export GH_CONFIG_DIR` / `declare -x GH_CONFIG_DIR` with no value: exports
# the shell-local value if there is one.
shell_export_bare() { # name
  if [ "$1" = "GH_CONFIG_DIR" ] && [ -n "$S_CFG_LOCAL" ]; then
    S_CFG_STATE="set"; S_CFG_VAL="$S_CFG_LOCAL_VAL"
  fi
}

apply_unset() { # P name
  [ "$1" = "S" ] && [ "$2" = "GH_CONFIG_DIR" ] && { S_CFG_LOCAL=""; S_CFG_LOCAL_VAL=""; }
  case "$2" in
    GH_CONFIG_DIR) printf -v "$1_CFG_STATE" '%s' "cleared"; printf -v "$1_CFG_VAL" '%s' "" ;;
    GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN) printf -v "$1_TS_$2" '%s' "CLEARED" ;;
  esac
}

mask() {
  printf '%s' "$1" | sed -E \
    -e 's/(GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN)=[^ ]*/\1=***/g' \
    -e 's/([Aa]uthorization:? *)([Bb]earer|[Tt]oken|[Bb]asic)? *[^ ]+/\1***/g' \
    -e 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]+/***/g'
}

block() { # reason detail action
  local seg
  seg="$(mask "$CUR_SEG_TEXT")"
  seg="${seg:0:300}"
  cat >&2 <<MSG
🚫 atelier:block-operator-gh-identity BLOCKED
   Tool:    Bash
   Command: $seg
   Reason:  $1
   Detail:  $2
   Rule:    PLAN.md §3 / operator-rules.md — agents never act under the operator's GitHub identity: review-like GitHub writes run only under \$ATELIER_CONFIG_DIR/gh/author or gh/reviewer with no token override, and the operator's GitHub credentials are never read.
   Action:  $3
   Override: none from inside this session.
MSG
  log_decision "$HOOK_NAME" "Bash" "$1" "block" "$(mask "$2")"
  exit 2
}

# --- lexer ------------------------------------------------------------------
# Minimal shell lexer: quote-aware, splits segments on ; & | ( ) newline and
# backtick, drops comments. Output in LEX_OUT: tokens end with US, segments
# with RS. Variable text ($HOME, $(...)) is kept verbatim for later expansion.
# Length of the balanced substitution at the start of $2 ($1 is `$` for
# `$(...)`, a backtick for `...`), or 0 when it is not closed in $2.
_subst_len() {
  local LC_ALL=C kind="$1" r="$2" k m=${#2} ch d=1 sq=0 dq=0
  if [ "$kind" = '`' ]; then
    for ((k = 1; k < m; k++)); do
      ch="${r:k:1}"
      if [ "$ch" = '\' ]; then k=$((k + 1))
      elif [ "$ch" = '`' ]; then echo $((k + 1)); return; fi
    done
    echo 0; return
  fi
  for ((k = 2; k < m; k++)); do
    ch="${r:k:1}"
    if [ "$sq" = 1 ]; then [ "$ch" = "'" ] && sq=0
    elif [ "$dq" = 1 ]; then
      if [ "$ch" = '\' ]; then k=$((k + 1)); elif [ "$ch" = '"' ]; then dq=0; fi
    else
      case "$ch" in
        '\') k=$((k + 1)) ;;
        "'") sq=1 ;;
        '"') dq=1 ;;
        '(') d=$((d + 1)) ;;
        ')') d=$((d - 1)); if [ "$d" -eq 0 ]; then echo $((k + 1)); return; fi ;;
      esac
    fi
  done
  echo 0
}

LEX_OUT=""
lex() {
  # bash 3.2 copies the string tail on every ${s:$i:1}, so a per-character walk
  # is quadratic. Index a small sliding window instead and jump quoted runs.
  local LC_ALL=C
  local s="$1" n i=0 c nx sub_end cur="" have=0 q="" rest run win="" b=-1000 o
  n=${#s}
  LEX_OUT=""
  _flush() {
    if [ -n "$cur" ] || [ "$have" -eq 1 ]; then LEX_OUT+="$cur$US"; fi
    cur=""; have=0
  }
  while [ "$i" -lt "$n" ]; do
    if [ $((i - b)) -ge 400 ]; then b=$i; win="${s:$i:512}"; fi
    o=$((i - b))
    c="${win:$o:1}"
    if [ "$q" = "'" ]; then
      if [ "$c" = "'" ]; then q=""
      else
        # Jump over the whole literal run in one step.
        rest="${win:$o}"; run="${rest%%\'*}"
        [ ${#run} -eq ${#rest} ] && { rest="${s:$i}"; run="${rest%%\'*}"; }
        cur+="$run"; i=$((i + ${#run} - 1))
      fi
    elif [ "$q" = '"' ]; then
      if [ "$c" != '\' ] && [ "$c" != '"' ]; then
        rest="${win:$o}"; run="${rest%%[\"\\]*}"
        [ ${#run} -eq ${#rest} ] && { rest="${s:$i}"; run="${rest%%[\"\\]*}"; }
        cur+="$run"; i=$((i + ${#run} - 1))
      elif [ "$c" = '\' ]; then
        nx="${win:$((o + 1)):1}"
        case "$nx" in
          '"'|'\'|'$'|'`') cur+="$nx"; i=$((i + 1)) ;;
          $'\n') i=$((i + 1)) ;;
          *) cur+="$c" ;;
        esac
      elif [ "$c" = '"' ]; then q=""
      else cur+="$c"; fi
    else
      case "$c" in
        '\')
          nx="${win:$((o + 1)):1}"
          if [ "$nx" != $'\n' ] && [ -n "$nx" ]; then cur+="$nx"; have=1; fi
          i=$((i + 1)) ;;
        "'") q="'"; have=1 ;;
        '"') q='"'; have=1 ;;
        '#')
          if [ -z "$cur" ] && [ "$have" -eq 0 ]; then
            rest="${s:$i}"; run="${rest%%$'\n'*}"; i=$((i + ${#run} - 1))
          else
            cur+="$c"
          fi ;;
        '$'|'`')
          # A balanced $(...) / `...` stays inside the current word, so
          # `VAR=$(cmd)/x gh ...` is not cut at the substitution.
          nx="${win:$((o + 1)):1}"
          if [ "$c" = '`' ] || [ "$nx" = '(' ]; then
            rest="${s:$i:2048}"; sub_end=$(_subst_len "$c" "$rest")
            [ "$sub_end" -eq 0 ] && { rest="${s:$i}"; sub_end=$(_subst_len "$c" "$rest"); }
            if [ "$sub_end" -gt 0 ]; then
              cur+="${rest:0:$sub_end}"; have=1; i=$((i + sub_end - 1))
            else
              # Unbalanced: keep the rest as one word (still analysed).
              rest="${s:$i}"; cur+="$rest"; have=1; i=$((n - 1))
            fi
          else
            cur+="$c"; have=1
          fi ;;
        ' '|$'\t') _flush ;;
        $'\n'|';'|'&'|'|'|'('|')') _flush; LEX_OUT+="$RS" ;;
        *) cur+="$c"; have=1 ;;
      esac
    fi
    i=$((i + 1))
  done
  _flush
  LEX_OUT+="$RS"
}

TOKS=()
split_tokens() {
  # One read call: the other ways to peel tokens off a long string rescan it
  # per token. The here-string newline lands in a final extra field; drop it.
  TOKS=()
  IFS="$US" read -r -d '' -a TOKS <<< "$1" || true
  unset "TOKS[$((${#TOKS[@]} - 1))]"
}

# Drop heredoc bodies (prose that is not code) unless the heredoc feeds a shell.
strip_heredocs() {
  local line delim="" dash=0 out="" t pre
  local re='(^|[^<])<<(-?)[[:space:]]*\\?["'"'"']?([A-Za-z_][A-Za-z0-9_]*)'
  local shre='(^|[[:space:];&|(])(bash|sh|zsh|dash|ksh|source|eval)([[:space:]]|$)'
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$delim" ]; then
      t="$line"
      if [ "$dash" = 1 ]; then t="${t#"${t%%[!	]*}"}"; fi
      [ "$t" = "$delim" ] && delim=""
      continue
    fi
    out+="$line"$'\n'
    if [[ "$line" =~ $re ]]; then
      pre="${line%%<<*}"
      if ! [[ "$pre" =~ $shre ]]; then
        delim="${BASH_REMATCH[3]}"
        if [ -n "${BASH_REMATCH[2]}" ]; then dash=1; else dash=0; fi
      fi
    fi
  done <<< "$1"
  printf '%s' "$out"
}

# --- identity resolution ----------------------------------------------------
EXPANDED=""
expand_val() {
  local v="$1" h="$HOME_DIR" a="$ACD"
  case "$v" in
    "~") v="$h" ;;
    "~/"*) v="$h/${v#\~/}" ;;
  esac
  v="${v//\$\{HOME\}/$h}"
  v="${v//\$HOME/$h}"
  v="${v//\$\{ATELIER_CONFIG_DIR\}/$a}"
  v="${v//\$ATELIER_CONFIG_DIR/$a}"
  EXPANDED="$v"
  case "$v" in
    *'$'*|*'`'*) return 1 ;;
  esac
  return 0
}

canon() {
  local p="$1" d
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  if [ -d "$p" ]; then
    d="$(cd "$p" 2>/dev/null && pwd -P)"
    if [ -n "$d" ]; then printf '%s' "$d"; return 0; fi
  fi
  printf '%s' "$p"
}

IDENT_WHY=""
identity_allowed() { # value of the effective GH_CONFIG_DIR
  local v="$1" cv pp px aa ar
  if [ -z "$v" ]; then
    IDENT_WHY="GH_CONFIG_DIR is unset/empty, so gh falls back to the operator's personal config (~/.config/gh)"
    return 1
  fi
  if ! expand_val "$v"; then
    IDENT_WHY="GH_CONFIG_DIR='$v' is dynamic (command substitution / unknown variable) and cannot be proven to be an atelier identity"
    return 1
  fi
  cv="$(canon "$EXPANDED")"
  pp="$(canon "$HOME_DIR/.config/gh")"
  if [ "$cv" = "$pp" ]; then
    IDENT_WHY="GH_CONFIG_DIR resolves to the operator's personal gh config ($pp)"
    return 1
  fi
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    px="$(canon "$XDG_CONFIG_HOME/gh")"
    if [ "$cv" = "$px" ]; then
      IDENT_WHY="GH_CONFIG_DIR resolves to the operator's personal gh config ($px)"
      return 1
    fi
  fi
  aa="$(canon "$ACD/gh/author")"
  ar="$(canon "$ACD/gh/reviewer")"
  if [ "$cv" = "$aa" ] || [ "$cv" = "$ar" ]; then
    return 0
  fi
  IDENT_WHY="GH_CONFIG_DIR resolves to '$cv', which is neither $ACD/gh/author nor $ACD/gh/reviewer"
  return 1
}

ENV_UNK_IN=""
# An env option this hook cannot model might change gh's environment: fail closed.
block_env_unknown() { # label
  [ -z "${E_UNK:-}" ] && return 0
  block "$1 behind an env option the guard cannot model ($E_UNK)" \
    "env $E_UNK may alter the environment gh runs under (config dir / token), so the identity cannot be verified" \
    "drop the unrecognised env option (supported: -i, -u NAME, -S STR, -C DIR, -P PATH, -a ARG, -0, -v and NAME=value) and retry."
}

# Allowed only under an atelier identity with no token override.
check_identity() { # label
  local n st stvar cfgval
  block_env_unknown "$1"
  for n in $TOKEN_VARS; do
    stvar="E_TS_$n"; st="${!stvar}"
    if [ "$st" = "SET" ]; then
      block "$1 with a token override ($n set in this command)" \
        "$n replaces whatever gh config is selected, so the call would run as the token's owner (potentially the operator)" \
        "remove $n from the command (or run \`unset $n\` first) and use the session's gh identity: author by default, GH_CONFIG_DIR=\"\$ATELIER_CONFIG_DIR/gh/reviewer\" for reviews."
    elif [ -z "$st" ] && [ -n "${!n:-}" ]; then
      block "$1 with a token override ($n inherited from the environment)" \
        "the session environment carries a non-empty $n, which overrides GH_CONFIG_DIR, so the call would run as the token's owner (potentially the operator)" \
        "run \`unset $n\` (or prefix the command with \`env -u $n\`) and retry; ask the operator to launch the session without $n exported."
    fi
  done
  case "$E_CFG_STATE" in
    set) cfgval="$E_CFG_VAL" ;;
    cleared) cfgval="" ;;
    *) cfgval="${GH_CONFIG_DIR:-}" ;;
  esac
  if ! identity_allowed "$cfgval"; then
    block "$1 under a non-atelier GitHub identity" "$IDENT_WHY" \
      "run it as the session's author identity (inherited GH_CONFIG_DIR=\$ATELIER_CONFIG_DIR/gh/author) or, for reviews, prefix \`GH_CONFIG_DIR=\"\$ATELIER_CONFIG_DIR/gh/reviewer\"\`. Never use the operator's personal config."
  fi
  log_decision "$HOOK_NAME" "Bash" "$1" "allow" "identity resolves to an atelier gh config dir"
}

# --- shapes ------------------------------------------------------------------
is_review_endpoint() { # lowercased endpoint/text
  case "$1" in
    *pulls/*/reviews*|*pulls/*/comments*|*pulls/comments/*|*issues/*/comments*|*issues/comments/*) return 0 ;;
  esac
  return 1
}

is_personal_cfg_path() {
  local t="$1" h="$HOME_DIR" x="${XDG_CONFIG_HOME:-}"
  case "$t" in --*=*) t="${t#*=}" ;; esac
  local re1='^(~|\$HOME|\$\{HOME\})/\.config/gh(/|$)'
  local re2='^(\$XDG_CONFIG_HOME|\$\{XDG_CONFIG_HOME\})/gh(/|$)'
  local re3='^/.+/\.config/gh(/|$)'
  [[ "$t" =~ $re1 ]] && return 0
  [[ "$t" =~ $re2 ]] && return 0
  [[ "$t" =~ $re3 ]] && return 0
  if [ -n "$h" ]; then
    case "$t" in "$h"/.config/gh|"$h"/.config/gh/*) return 0 ;; esac
  fi
  if [ -n "$x" ]; then
    case "$t" in "$x"/gh|"$x"/gh/*) return 0 ;; esac
  fi
  return 1
}

analyze_gh() { # args after `gh` live in GH_ARGS
  local a prev_kind="" p1="" p2="" seen_api=0 endpoint="" method="" fields=0
  local unverifiable=0 show_token=0 alltext lc
  for a in ${GH_ARGS[@]+"${GH_ARGS[@]}"}; do
    if [ -n "$prev_kind" ]; then
      case "$prev_kind" in
        method) method="$a" ;;
        field) case "$a" in query=@*) unverifiable=1 ;; esac ;;
      esac
      prev_kind=""
      continue
    fi
    case "$a" in
      -X|--method) prev_kind="method" ;;
      --method=*) method="${a#--method=}" ;;
      -X?*) method="${a#-X}" ;;
      -f|-F|--field|--raw-field) fields=1; prev_kind="field" ;;
      --input) fields=1; unverifiable=1; prev_kind="other" ;;
      --input=*) fields=1; unverifiable=1 ;;
      --field=*|--raw-field=*) fields=1; case "${a#*=}" in query=@*) unverifiable=1 ;; esac ;;
      -f?*|-F?*) fields=1; case "${a:2}" in query=@*) unverifiable=1 ;; esac ;;
      --show-token|-t) show_token=1 ;;
      -H|--header|-q|--jq|--template|--cache|--hostname|-p|--preview|-R|--repo|-b|--body) prev_kind="other" ;;
      -*) : ;;
      *)
        if [ -z "$p1" ]; then p1="$a"
        elif [ -z "$p2" ]; then p2="$a"
        fi
        if [ "$p1" = "api" ]; then
          if [ "$seen_api" -eq 0 ]; then seen_api=1
          elif [ -z "$endpoint" ]; then endpoint="$a"
          fi
        fi ;;
    esac
  done

  alltext="${GH_ARGS[*]-}"
  lc="$(printf '%s' "$alltext" | tr '[:upper:]' '[:lower:]')"

  case "$p1/$p2" in
    pr/review|pr/comment)
      check_identity "gh pr $p2" ;;
    auth/token)
      check_exfil_identity "gh auth token" ;;
    auth/status)
      if [ "$show_token" -eq 1 ]; then check_exfil_identity "gh auth status --show-token"; fi ;;
  esac

  if [ "$p1" = "api" ]; then
    local write=0 m
    m="$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')"
    if [ -n "$m" ]; then
      [ "$m" != "GET" ] && write=1
    elif [ "$fields" -eq 1 ]; then
      write=1
    fi
    local ep
    ep="$(printf '%s' "$endpoint" | tr '[:upper:]' '[:lower:]')"
    if [ "$ep" = "graphql" ]; then
      local mre="($MUTATIONS)"
      if [[ "$lc" =~ $mre ]]; then
        check_identity "gh api graphql review/comment mutation (${BASH_REMATCH[1]})"
      elif [ "$unverifiable" -eq 1 ]; then
        check_identity "gh api graphql with a query body that cannot be inspected (--input / query=@file)"
      fi
    elif [ "$write" -eq 1 ] && is_review_endpoint "$ep"; then
      check_identity "gh api ${m:-POST} write to a PR review/comment endpoint ($endpoint)"
    fi
  fi
}

check_exfil_identity() { # label — credential read under a non-atelier config
  local cfgval
  block_env_unknown "credential grab: $1"
  case "$E_CFG_STATE" in
    set) cfgval="$E_CFG_VAL" ;;
    cleared) cfgval="" ;;
    *) cfgval="${GH_CONFIG_DIR:-}" ;;
  esac
  if ! identity_allowed "$cfgval"; then
    block "credential grab: $1 under a non-atelier GitHub identity" "$IDENT_WHY" \
      "never print or read the operator's GitHub token. Use the session's gh identity through gh itself."
  fi
}

# --- main walk ---------------------------------------------------------------
process_script() { # script depth
  local script="$1" depth="$2"
  [ "$depth" -gt 4 ] && return 0
  local out seg toks nt i t base j sub skip_next prev a lc cmd_idx
  local sv1 sv2 sv3 sv4 sv5 sv6 sv7 env_split E_UNK k c rest do_split
  lex "$script"
  out="$LEX_OUT"
  while [ -n "$out" ]; do
    seg="${out%%"$RS"*}"
    out="${out:$((${#seg} + 1))}"
    [ -z "$seg" ] && continue
    split_tokens "$seg"
    toks=("${TOKS[@]}")
    nt=${#toks[@]}
    CUR_SEG_TEXT=""
    for t in "${toks[@]}"; do CUR_SEG_TEXT+="$t "; done
    E_UNK="$ENV_UNK_IN"; ENV_UNK_IN=""

    E_CFG_STATE="$S_CFG_STATE"; E_CFG_VAL="$S_CFG_VAL"
    E_TS_GH_TOKEN="$S_TS_GH_TOKEN"; E_TS_GITHUB_TOKEN="$S_TS_GITHUB_TOKEN"; E_TS_GH_ENTERPRISE_TOKEN="$S_TS_GH_ENTERPRISE_TOKEN"

    # Command substitutions / backticks inside quoted tokens run code too.
    for t in "${toks[@]}"; do
      case "$t" in
        *'$('*|*'`'*)
          sub="${t//\$\(/ ; }"; sub="${sub//\`/ ; }"; sub="${sub//)/ ; }"
          sv1="$S_CFG_STATE"; sv2="$S_CFG_VAL"; sv6="$S_CFG_LOCAL"; sv7="$S_CFG_LOCAL_VAL"; sv3="$S_TS_GH_TOKEN"; sv4="$S_TS_GITHUB_TOKEN"; sv5="$S_TS_GH_ENTERPRISE_TOKEN"
          S_CFG_STATE="$E_CFG_STATE"; S_CFG_VAL="$E_CFG_VAL"
          S_TS_GH_TOKEN="$E_TS_GH_TOKEN"; S_TS_GITHUB_TOKEN="$E_TS_GITHUB_TOKEN"; S_TS_GH_ENTERPRISE_TOKEN="$E_TS_GH_ENTERPRISE_TOKEN"
          process_script "$sub" $((depth + 1))
          S_CFG_STATE="$sv1"; S_CFG_VAL="$sv2"; S_CFG_LOCAL="$sv6"; S_CFG_LOCAL_VAL="$sv7"; S_TS_GH_TOKEN="$sv3"; S_TS_GITHUB_TOKEN="$sv4"; S_TS_GH_ENTERPRISE_TOKEN="$sv5"
          ;;
      esac
    done
    # (restoring E_* — the recursion above clobbered them)
    E_CFG_STATE="$S_CFG_STATE"; E_CFG_VAL="$S_CFG_VAL"
    E_TS_GH_TOKEN="$S_TS_GH_TOKEN"; E_TS_GITHUB_TOKEN="$S_TS_GITHUB_TOKEN"; E_TS_GH_ENTERPRISE_TOKEN="$S_TS_GH_ENTERPRISE_TOKEN"
    CUR_SEG_TEXT=""
    for t in "${toks[@]}"; do CUR_SEG_TEXT+="$t "; done

    # Prefix: inline assignments and command wrappers.
    i=0
    while [ "$i" -lt "$nt" ]; do
      t="${toks[$i]}"
      base="${t##*/}"
      if [[ "$t" =~ $ASSIGN_RE ]]; then
        apply_assign E "${t%%=*}" "${t#*=}"
        i=$((i + 1)); continue
      fi
      case "$base" in
        if|then|do|else|elif|while|until|'{'|'!')
          # Reserved words / grouping tokens: the real command follows.
          i=$((i + 1)); continue ;;
        env)
          i=$((i + 1))
          while [ "$i" -lt "$nt" ]; do
            t="${toks[$i]}"
            do_split=0
            if [[ "$t" =~ $ASSIGN_RE ]]; then
              apply_assign E "${t%%=*}" "${t#*=}"; i=$((i + 1))
            elif [ "$t" = "-" ] || [ "$t" = "--ignore-environment" ]; then
              # Starts from an empty environment: nothing inherited reaches gh.
              apply_unset E GH_CONFIG_DIR; apply_unset E GH_TOKEN; apply_unset E GITHUB_TOKEN; apply_unset E GH_ENTERPRISE_TOKEN
              i=$((i + 1))
            elif { [ "$t" = "--unset" ] || [ "$t" = "--split-string" ] || [ "$t" = "--chdir" ] || [ "$t" = "--path" ] || [ "$t" = "--argv0" ]; }; then
              if [ "$t" = "--unset" ]; then [ $((i + 1)) -lt "$nt" ] && apply_unset E "${toks[$((i + 1))]}"
              elif [ "$t" = "--split-string" ]; then sub="${toks[$((i + 1))]:-}"; do_split=1; fi
              i=$((i + 2))
            elif [[ "$t" == --unset=* ]]; then
              apply_unset E "${t#--unset=}"; i=$((i + 1))
            elif [[ "$t" == --split-string=* ]]; then
              sub="${t#--split-string=}"; do_split=1; i=$((i + 1))
            elif [[ "$t" == --chdir=* || "$t" == --path=* || "$t" == --argv0=* || "$t" == --block-signal* || "$t" == --default-signal* || "$t" == --ignore-signal* ]] \
              || [ "$t" = "--null" ] || [ "$t" = "--debug" ] || [ "$t" = "--list-signal-handling" ]; then
              i=$((i + 1))
            elif [[ "$t" == -[!-]* ]]; then
              # Short-option cluster (-i, -iu NAME, -vi, -0i, -iS'...'): walk it.
              i=$((i + 1)); k=1
              while [ "$k" -lt "${#t}" ]; do
                c="${t:$k:1}"; k=$((k + 1))
                case "$c" in
                  i) apply_unset E GH_CONFIG_DIR; apply_unset E GH_TOKEN; apply_unset E GITHUB_TOKEN; apply_unset E GH_ENTERPRISE_TOKEN ;;
                  0|v) : ;;
                  u|S|C|P|a)
                    rest="${t:$k}"; k=${#t}
                    if [ -z "$rest" ] && [ "$i" -lt "$nt" ]; then rest="${toks[$i]}"; i=$((i + 1)); fi
                    case "$c" in
                      u) [ -n "$rest" ] && apply_unset E "$rest" ;;
                      S) sub="$rest"; do_split=1 ;;
                    esac ;;
                  *) E_UNK="-$c" ;;
                esac
              done
            elif [ "${t:0:1}" = "-" ]; then
              E_UNK="$t"; i=$((i + 1))
            else
              break
            fi
            if [ "$do_split" = 1 ]; then
              # The split string is a command line env will run: analyse it
              # (plus the remaining words) under the env built so far.
              for ((j = i; j < nt; j++)); do sub+=" ${toks[$j]}"; done
              case "$sub" in -*) sub="env $sub" ;; esac
              sv1="$S_CFG_STATE"; sv2="$S_CFG_VAL"; sv6="$S_CFG_LOCAL"; sv7="$S_CFG_LOCAL_VAL"; sv3="$S_TS_GH_TOKEN"; sv4="$S_TS_GITHUB_TOKEN"; sv5="$S_TS_GH_ENTERPRISE_TOKEN"
              S_CFG_STATE="$E_CFG_STATE"; S_CFG_VAL="$E_CFG_VAL"; S_CFG_LOCAL=""; S_CFG_LOCAL_VAL=""
              S_TS_GH_TOKEN="$E_TS_GH_TOKEN"; S_TS_GITHUB_TOKEN="$E_TS_GITHUB_TOKEN"; S_TS_GH_ENTERPRISE_TOKEN="$E_TS_GH_ENTERPRISE_TOKEN"
              ENV_UNK_IN="$E_UNK"
              process_script "$sub" $((depth + 1))
              S_CFG_STATE="$sv1"; S_CFG_VAL="$sv2"; S_CFG_LOCAL="$sv6"; S_CFG_LOCAL_VAL="$sv7"; S_TS_GH_TOKEN="$sv3"; S_TS_GITHUB_TOKEN="$sv4"; S_TS_GH_ENTERPRISE_TOKEN="$sv5"
              env_split=1; i=$nt
            fi
          done
          continue ;;
        arch)
          i=$((i + 1))
          while [ "$i" -lt "$nt" ]; do
            t="${toks[$i]}"
            case "$t" in
              -arch) i=$((i + 2)) ;;
              -*) i=$((i + 1)) ;;
              *) break ;;
            esac
          done
          continue ;;
        command|exec|nohup|time|builtin|sudo|nice|stdbuf|timeout|setsid|caffeinate|xargs|ionice|coproc)
          i=$((i + 1))
          while [ "$i" -lt "$nt" ]; do
            t="${toks[$i]}"
            case "$t" in -*|[0-9]*) i=$((i + 1)) ;; *) break ;; esac
          done
          continue ;;
      esac
      break
    done

    [ "${env_split:-}" = 1 ] && { env_split=""; continue; }

    if [ "$i" -ge "$nt" ]; then
      # Bare assignments persist in the shell.
      for t in "${toks[@]}"; do
        if [[ "$t" =~ $ASSIGN_RE ]]; then shell_assign "${t%%=*}" "${t#*=}" 0; fi
      done
      continue
    fi

    cmd_idx=$i
    t="${toks[$i]}"
    base="${t##*/}"

    case "$base" in
      export|declare|typeset|readonly|local)
        # Only export and declare/typeset -x put the variable in gh's env.
        xflag=0; [ "$base" = "export" ] && xflag=1
        for ((j = i + 1; j < nt; j++)); do
          t="${toks[$j]}"
          if [[ "$t" =~ ^-[A-Za-z]*x ]]; then xflag=1
          elif [[ "$t" =~ ^\+[A-Za-z]*x ]]; then xflag=0
          elif [[ "$t" =~ $ASSIGN_RE ]]; then shell_assign "${t%%=*}" "${t#*=}" "$xflag"
          elif [ "$xflag" = 1 ] && [ "${t:0:1}" != "-" ]; then shell_export_bare "$t"
          fi
        done
        continue ;;
      unset)
        for ((j = i + 1; j < nt; j++)); do
          t="${toks[$j]}"
          [ "${t:0:1}" = "-" ] || apply_unset S "$t"
        done
        continue ;;
      gh)
        GH_ARGS=()
        for ((j = i + 1; j < nt; j++)); do GH_ARGS+=("${toks[$j]}"); done
        analyze_gh ;;
      bash|sh|zsh|dash|ksh)
        sub=""
        for ((j = i + 1; j < nt; j++)); do
          if [[ "${toks[$j]}" =~ ^-[A-Za-z]*c[A-Za-z]*$ ]] && [ $((j + 1)) -lt "$nt" ]; then
            sub="${toks[$((j + 1))]}"; break
          fi
        done
        if [ -n "$sub" ]; then
          sv1="$S_CFG_STATE"; sv2="$S_CFG_VAL"; sv6="$S_CFG_LOCAL"; sv7="$S_CFG_LOCAL_VAL"; sv3="$S_TS_GH_TOKEN"; sv4="$S_TS_GITHUB_TOKEN"; sv5="$S_TS_GH_ENTERPRISE_TOKEN"
          S_CFG_STATE="$E_CFG_STATE"; S_CFG_VAL="$E_CFG_VAL"; S_CFG_LOCAL=""; S_CFG_LOCAL_VAL=""
          S_TS_GH_TOKEN="$E_TS_GH_TOKEN"; S_TS_GITHUB_TOKEN="$E_TS_GITHUB_TOKEN"; S_TS_GH_ENTERPRISE_TOKEN="$E_TS_GH_ENTERPRISE_TOKEN"
          process_script "$sub" $((depth + 1))
          S_CFG_STATE="$sv1"; S_CFG_VAL="$sv2"; S_CFG_LOCAL="$sv6"; S_CFG_LOCAL_VAL="$sv7"; S_TS_GH_TOKEN="$sv3"; S_TS_GITHUB_TOKEN="$sv4"; S_TS_GH_ENTERPRISE_TOKEN="$sv5"
        fi ;;
      eval)
        sub=""
        for ((j = i + 1; j < nt; j++)); do sub+="${toks[$j]} "; done
        if [ -n "$sub" ]; then
          sv1="$S_CFG_STATE"; sv2="$S_CFG_VAL"; sv6="$S_CFG_LOCAL"; sv7="$S_CFG_LOCAL_VAL"; sv3="$S_TS_GH_TOKEN"; sv4="$S_TS_GITHUB_TOKEN"; sv5="$S_TS_GH_ENTERPRISE_TOKEN"
          S_CFG_STATE="$E_CFG_STATE"; S_CFG_VAL="$E_CFG_VAL"
          S_TS_GH_TOKEN="$E_TS_GH_TOKEN"; S_TS_GITHUB_TOKEN="$E_TS_GITHUB_TOKEN"; S_TS_GH_ENTERPRISE_TOKEN="$E_TS_GH_ENTERPRISE_TOKEN"
          process_script "$sub" $((depth + 1))
          S_CFG_STATE="$sv1"; S_CFG_VAL="$sv2"; S_CFG_LOCAL="$sv6"; S_CFG_LOCAL_VAL="$sv7"; S_TS_GH_TOKEN="$sv3"; S_TS_GITHUB_TOKEN="$sv4"; S_TS_GH_ENTERPRISE_TOKEN="$sv5"
        fi ;;
    esac

    # Segment text (lowercase) for the credential-exfiltration shapes.
    lc=""
    case "$base" in
      security|osascript|curl|wget) lc="$(printf '%s' "${toks[*]:$cmd_idx}" | tr '[:upper:]' '[:lower:]')" ;;
    esac

    case "$base" in
      security)
        case "$lc" in
          *find-generic-password*|*find-internet-password*)
            case "$lc" in
              *github.com*) block "credential grab: macOS keychain lookup of the GitHub token" \
                "security find-*-password names github.com / gh:github.com, which is where gh stores the operator's token" \
                "never read the operator's GitHub credentials; use gh under the atelier identity." ;;
            esac ;;
        esac ;;
      osascript)
        case "$lc" in
          *chrome*|*chromium*|*safari*)
            case "$lc" in
              *execute*|*javascript*|*github.com*) block "credential grab: osascript driving the operator's browser" \
                "osascript aimed at Chrome/Chromium/Safari with execute/javascript or a github.com URL would act inside the operator's logged-in GitHub session" \
                "agents use gh under the atelier identity for GitHub; they never script the operator's browser." ;;
            esac ;;
        esac ;;
      curl|wget)
        case "$lc" in
          *api.github.com*)
            local has_auth=0 has_write=0 m2
            case "$lc" in *authorization*|*--oauth2-bearer*|*x-access-token*) has_auth=1 ;; esac
            prev=""
            for a in "${toks[@]:$cmd_idx}"; do
              if [ -n "$prev" ]; then
                m2="$(printf '%s' "$a" | tr '[:lower:]' '[:upper:]')"
                [ "$m2" != "GET" ] && [ "$m2" != "HEAD" ] && has_write=1
                prev=""; continue
              fi
              case "$a" in
                -X|--request|--method) prev="m" ;;
                -X?*) m2="$(printf '%s' "${a#-X}" | tr '[:lower:]' '[:upper:]')"; [ "$m2" != "GET" ] && [ "$m2" != "HEAD" ] && has_write=1 ;;
                --request=*|--method=*) m2="$(printf '%s' "${a#*=}" | tr '[:lower:]' '[:upper:]')"; [ "$m2" != "GET" ] && [ "$m2" != "HEAD" ] && has_write=1 ;;
                -d|-d?*|--data*|--json|--json=*|-F|--form*|-T|--upload-file*|--post-data*|--post-file*|--body-data*|--body-file*) has_write=1 ;;
                -u|--user|--user=*|-u?*|-n|--netrc*) has_auth=1 ;;
              esac
            done
            local gre="($MUTATIONS)"
            if [ "$has_auth" -eq 1 ] && { [ "$has_write" -eq 1 ] || is_review_endpoint "$lc" || { [[ "$lc" =~ $gre ]] && [[ "$lc" == *graphql* ]]; }; }; then
              block "credential use: authorized ${base} to api.github.com with a write method or a review/comment endpoint" \
                "an Authorization header toward api.github.com carries a token that is not provably an atelier identity's" \
                "use gh under the atelier identity (gh api ...) instead of hand-built authenticated requests."
            fi ;;
        esac ;;
    esac

    # Any command that reads the operator's personal gh config dir.
    if [ "$base" != "git" ]; then
      skip_next=0
      for ((j = cmd_idx; j < nt; j++)); do
        t="${toks[$j]}"
        if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
        case "$t" in
          -m|--message|-b|--body|--title) skip_next=1; continue ;;
          --body=*|--message=*|--title=*) continue ;;
        esac
        if is_personal_cfg_path "$t"; then
          block "credential grab: touching the operator's personal gh config (~/.config/gh)" \
            "'$t' is inside the personal gh config dir, which holds the operator's token (hosts.yml)" \
            "never read the operator's gh config; use gh under the atelier identity through GH_CONFIG_DIR=\$ATELIER_CONFIG_DIR/gh/author or gh/reviewer."
        fi
      done
    fi
  done
}

GH_ARGS=()
scan_str="$(strip_heredocs "$command_str")"
process_script "$scan_str" 0
exit 0
