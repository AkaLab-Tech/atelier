#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Bash. Lets a `gh api` call through only when it
# can prove the call is a read, or a GraphQL mutation confined to the board-item
# operations the github-project tracking backend uses (#812).
#
# Closed allowlist, fail closed. Nothing here lists bypass spellings: a `gh api`
# call is treated as a write unless every word that decides the request is read
# and understood. The lexed command (hooks/lib/shell-lex.sh; quotes removed,
# heredoc prose dropped, tokens carrying a live expansion marked) is split into
# segments. In each non-inert segment the command word is found after leading
# NAME=value assignments and a closed set of transparent wrappers (env,
# command, exec, time, nice, nohup, timeout). A segment that holds a `gh` word
# and an `api` word is blocked when the command word holds an expansion, sits
# behind an unknown wrapper or program, or is an interpreter body that cannot be
# re-lexed; `-c`/eval bodies and `$(...)` substitutions are re-lexed (bounded
# depth). Echo/printf, commit messages, searches, heredoc prose and the like
# are inert, unless that text is piped into an interpreter.
#
# When `gh` is the command word its arguments are read with a closed grammar
# (the documented `gh api` flags and their arity, short clusters and `=` forms
# resolved the way the CLI's flag parser resolves them). The call passes when:
#   * every method value is GET (case-insensitive), or none is given and no
#     field/raw-field/input flag is present (those make the CLI send a POST);
#   * the endpoint word has no live expansion;
#   * every header is a read-neutral one (Accept, X-GitHub-Api-Version);
#   * for the GraphQL endpoint (any spelling that ends in /graphql), each query
#     is given inline with no live expansion, and either holds no `mutation`
#     name token (a document cannot mutate without that keyword) or parses as a
#     single mutation operation whose top-level fields are all board-item
#     operations (addProjectV2DraftIssue, addProjectV2ItemById,
#     updateProjectV2ItemFieldValue, clearProjectV2ItemFieldValue,
#     updateProjectV2DraftIssue) plus updateIssue and addComment.
# Any other flag, a repeated or missing endpoint, an unreadable body, a live
# expansion in a load-bearing word, or input over the size cap is blocked.
# `gh alias set` / `gh alias import` are blocked too (an alias can stand for an
# api call); aliases that already exist are not resolved.
#
# Exit 0 allow, exit 2 block (stderr goes to Claude). Like the sibling hooks it
# fails open, with a warning, when jq is missing.
#
# Defense in depth, not a sandbox: a script written first and run later, indirect
# runs (package scripts, Makefiles), obfuscated invocations and other code-
# execution primitives are not covered. Server-side controls own the final
# boundary (PLAN.md §3).
#
# Contract (PreToolUse): stdin JSON { tool_name, tool_input: { command }, cwd }.

# shellcheck disable=SC2016,SC2088,SC1003
set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"
# shellcheck source=lib/shell-lex.sh
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/shell-lex.sh"

HOOK_NAME="block-gh-api-write"
MAX_LEN=40000
MAX_DEPTH=3
MAX_QUERY=8000
MAX_SCRIPTS=40
SCRIPTS=0

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

# Fast path: a `gh` word next to `api`/`alias` or an expansion, or an `api` word
# next to an expansion. Quotes are dropped first so a word split by quoting still counts.
plain="$(printf '%s' "$command_str" | tr -d "'\"\\\\")"
need=0
shopt -s nocasematch
case "$plain" in
  *gh*) case "$plain" in *api*|*alias*|*'$'*|*'`'*) need=1 ;; esac ;;
esac
case "$plain" in
  *api*) case "$plain" in *'$'*|*'`'*) need=1 ;; esac ;;
esac
shopt -u nocasematch
[ "$need" -eq 1 ] || exit 0

# --- verdicts ---------------------------------------------------------------
deny() { # tag, reason, hint
  log_decision "$HOOK_NAME" "Bash" "$1" "block" "$2"
  cat >&2 <<MSG
🛑 atelier:${HOOK_NAME} — blocked a \`gh api\` call: ${2}.
   ${3}
   Reads (GET requests, GraphQL queries) pass. Writes go through the matching \`gh\`
   subcommand (gh pr, gh issue, gh release, ...) or the atelier helper for the job
   (atelier-project-item for board items). See docs/troubleshooting.md.
MSG
  exit 2
}
deny_unread() { deny "unreadable-shape" "$1" "The call cannot be shown to be read-only from the command text."; }
deny_write() { deny "write" "$1" "It would change state on GitHub."; }

# --- helpers ----------------------------------------------------------------
LC=""
lcase() { LC="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"; }

RE_ASSIGN='^[A-Za-z_][A-Za-z0-9_]*='
RE_GH='(^|[^[:alnum:]_.-])gh(\.exe)?($|[^[:alnum:]_.-])'
RE_API='(^|[^[:alnum:]_.-])api($|[^[:alnum:]_.-])'
RE_ALIAS='(^|[^[:alnum:]_.-])alias($|[^[:alnum:]_.-])'
RE_MUT='(^|[^[:alnum:]_])mutation($|[^[:alnum:]_])'
RE_REDIR='^[0-9]*(>>|>\||>|<<<|<<-?|<>|<)(.*)$'
RE_PIPE_SHELL='\|[[:space:]]*(sudo[[:space:]]+)?(bash|sh|zsh|dash|ksh|xargs|eval|source)([^[:alnum:]_.-]|$)'

# Text names `gh` together with `api` or `alias` (case-insensitive).
mentions() {
  lcase "$1"
  [[ "$LC" =~ $RE_GH ]] && { [[ "$LC" =~ $RE_API ]] || [[ "$LC" =~ $RE_ALIAS ]]; }
}

REDIR=0
is_redir() { # sets REDIR: 0 not a redirection, 1 this token, 2 this token and its target
  REDIR=0
  if [[ "$1" =~ $RE_REDIR ]]; then
    if [ -z "${BASH_REMATCH[2]}" ]; then REDIR=2; else REDIR=1; fi
  fi
  [ "$REDIR" -ne 0 ]
}

# Brace expansion that could rewrite a flag or endpoint word.
braced() { case "$1" in *'{'*,*'}'*|*'{'*..*'}'*) return 0 ;; esac; return 1; }

# --- GraphQL document scanner ---------------------------------------------
GQL_T=()
GQL_FIELDS=()
GQL_P=0

gql_tokenize() {
  local LC_ALL=C r="$1" rest pre m
  local nl=$'\n'
  local re_ws='^[[:space:],]+' re_com="^#[^$nl]*" re_name='^[_A-Za-z][_0-9A-Za-z]*'
  local re_num='^-?[0-9][-+._0-9A-Za-z]*' re_str='^"([^"\\]|\\.)*"'
  GQL_T=()
  r="${r#$'\xef\xbb\xbf'}"
  while [ -n "$r" ]; do
    if [[ "$r" =~ $re_ws ]]; then r="${r:${#BASH_REMATCH[0]}}"; continue; fi
    if [[ "$r" =~ $re_com ]]; then r="${r:${#BASH_REMATCH[0]}}"; continue; fi
    if [[ "$r" == '"""'* ]]; then
      rest="${r:3}"
      while :; do
        pre="${rest%%'"""'*}"
        [ "${#pre}" -ne "${#rest}" ] || return 1
        rest="${rest:$((${#pre} + 3))}"
        case "$pre" in *'\') ;; *) break ;; esac
      done
      GQL_T+=('"'); r="$rest"; continue
    fi
    if [[ "$r" =~ $re_str ]]; then GQL_T+=('"'); r="${r:${#BASH_REMATCH[0]}}"; continue; fi
    if [[ "$r" =~ $re_name ]]; then m="${BASH_REMATCH[0]}"; GQL_T+=("$m"); r="${r:${#m}}"; continue; fi
    if [[ "$r" =~ $re_num ]]; then GQL_T+=('#'); r="${r:${#BASH_REMATCH[0]}}"; continue; fi
    case "$r" in
      '...'*) GQL_T+=('...'); r="${r:3}" ;;
      '{'*|'}'*|'('*|')'*|'['*|']'*|':'*|'='*|'!'*|'@'*|'$'*|'&'*|'|'*) GQL_T+=("${r:0:1}"); r="${r:1}" ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# GQL_P is at an opening token; advance past its balanced close.
gql_skip() { # open close
  local d=0 t
  while [ "$GQL_P" -lt "${#GQL_T[@]}" ]; do
    t="${GQL_T[GQL_P]}"; GQL_P=$((GQL_P + 1))
    if [ "$t" = "$1" ]; then d=$((d + 1))
    elif [ "$t" = "$2" ]; then d=$((d - 1)); [ "$d" -gt 0 ] || return 0; fi
  done
  return 1
}

# Advance to the selection set `{` (outside parentheses) and past its balanced close.
gql_to_selection() {
  local t
  while [ "$GQL_P" -lt "${#GQL_T[@]}" ]; do
    t="${GQL_T[GQL_P]}"
    case "$t" in
      '(') gql_skip '(' ')' || return 1 ;;
      '{') gql_skip '{' '}'; return ;;
      '}'|')') return 1 ;;
      *) GQL_P=$((GQL_P + 1)) ;;
    esac
  done
  return 1
}

# After `mutation`: header up to the selection set, then each top-level field.
gql_mutation() {
  local t f
  while [ "$GQL_P" -lt "${#GQL_T[@]}" ]; do
    t="${GQL_T[GQL_P]}"
    case "$t" in
      '(') gql_skip '(' ')' || return 1 ;;
      '{') break ;;
      '}'|')') return 1 ;;
      *) GQL_P=$((GQL_P + 1)) ;;
    esac
  done
  [ "${GQL_T[GQL_P]:-}" = '{' ] || return 1
  GQL_P=$((GQL_P + 1))
  local count=0
  while [ "${GQL_T[GQL_P]:-}" != '}' ]; do
    [ "$GQL_P" -lt "${#GQL_T[@]}" ] || return 1
    t="${GQL_T[GQL_P]}"
    [[ "$t" =~ ^[_A-Za-z][_0-9A-Za-z]*$ ]] || return 1
    f="$t"; GQL_P=$((GQL_P + 1))
    if [ "${GQL_T[GQL_P]:-}" = ':' ]; then
      GQL_P=$((GQL_P + 1)); f="${GQL_T[GQL_P]:-}"
      [[ "$f" =~ ^[_A-Za-z][_0-9A-Za-z]*$ ]] || return 1
      GQL_P=$((GQL_P + 1))
    fi
    [ "${GQL_T[GQL_P]:-}" != '(' ] || gql_skip '(' ')' || return 1
    while [ "${GQL_T[GQL_P]:-}" = '@' ]; do
      GQL_P=$((GQL_P + 2))
      [ "${GQL_T[GQL_P]:-}" != '(' ] || gql_skip '(' ')' || return 1
    done
    [ "${GQL_T[GQL_P]:-}" != '{' ] || gql_skip '{' '}' || return 1
    GQL_FIELDS+=("$f"); count=$((count + 1))
  done
  GQL_P=$((GQL_P + 1))
  [ "$count" -gt 0 ]
}

# 0 when the document holds no mutation, or one mutation operation whose
# top-level fields are all allowlisted; 1 otherwise (including parse failures).
gql_allowed() {
  local ops=0 muts=0 t f a ok
  GQL_FIELDS=(); GQL_P=0
  gql_tokenize "$1" || return 1
  while [ "$GQL_P" -lt "${#GQL_T[@]}" ]; do
    t="${GQL_T[GQL_P]}"
    case "$t" in
      '{') ops=$((ops + 1)); gql_skip '{' '}' || return 1 ;;
      query|subscription) ops=$((ops + 1)); GQL_P=$((GQL_P + 1)); gql_to_selection || return 1 ;;
      fragment) GQL_P=$((GQL_P + 1)); gql_to_selection || return 1 ;;
      mutation) ops=$((ops + 1)); muts=$((muts + 1)); GQL_P=$((GQL_P + 1)); gql_mutation || return 1 ;;
      *) return 1 ;;
    esac
  done
  [ "$muts" -eq 0 ] && return 0
  [ "$ops" -eq 1 ] || return 1
  for f in ${GQL_FIELDS[@]+"${GQL_FIELDS[@]}"}; do
    ok=0
    for a in addProjectV2DraftIssue addProjectV2ItemById updateProjectV2ItemFieldValue \
             clearProjectV2ItemFieldValue updateProjectV2DraftIssue updateIssue addComment; do
      [ "$f" = "$a" ] && ok=1
    done
    [ "$ok" -eq 1 ] || return 1
  done
  return 0
}

# --- command-position resolution ---------------------------------------------
T=(); F=""; N=0
CI=-1; CSTAT=ok

# Sets CI (index of the command word, -1 when only assignments), CSTAT
# (ok | exp: the word holds an expansion | unreadable: unknown wrapper grammar).
resolve_cmd() {
  local i=0 t b
  CI=-1; CSTAT=ok
  while [ "$i" -lt "$N" ]; do
    t="${T[i]}"
    if [[ "$t" =~ $RE_ASSIGN ]]; then i=$((i + 1)); continue; fi
    if [ "${F:i:1}" = 1 ]; then CSTAT=exp; CI=$i; return; fi
    lcase "${t##*/}"; b="$LC"
    case "$b" in
      if|then|elif|else|do|while|until|'!'|'{'|nohup|builtin) i=$((i + 1)); continue ;;
      command|exec|time)
        i=$((i + 1))
        while [ "$i" -lt "$N" ]; do
          case "${T[i]}" in
            --) i=$((i + 1)); break ;;
            -p) i=$((i + 1)) ;;
            -c|-l) [ "$b" = exec ] || { CSTAT=unreadable; return; }; i=$((i + 1)) ;;
            -a) [ "$b" = exec ] || { CSTAT=unreadable; return; }; i=$((i + 2)) ;;
            -*) CSTAT=unreadable; return ;;
            *) break ;;
          esac
        done
        continue ;;
      env)
        i=$((i + 1))
        while [ "$i" -lt "$N" ]; do
          case "${T[i]}" in
            --) i=$((i + 1)); break ;;
            -i|-|-0|--null|--ignore-environment) i=$((i + 1)) ;;
            -u|--unset|-C|--chdir) i=$((i + 2)) ;;
            --unset=*|--chdir=*|-u?*|-C?*) i=$((i + 1)) ;;
            -*) CSTAT=unreadable; return ;;
            *) if [[ "${T[i]}" =~ $RE_ASSIGN ]]; then i=$((i + 1)); else break; fi ;;
          esac
        done
        continue ;;
      nice)
        i=$((i + 1))
        while [ "$i" -lt "$N" ]; do
          case "${T[i]}" in
            --) i=$((i + 1)); break ;;
            -n|--adjustment) i=$((i + 2)) ;;
            --adjustment=*|-n?*|-[0-9]*|--[0-9]*) i=$((i + 1)) ;;
            -*) CSTAT=unreadable; return ;;
            *) break ;;
          esac
        done
        continue ;;
      timeout)
        i=$((i + 1))
        while [ "$i" -lt "$N" ]; do
          case "${T[i]}" in
            --) i=$((i + 1)); break ;;
            --preserve-status|--foreground|-v|--verbose) i=$((i + 1)) ;;
            -s|--signal|-k|--kill-after) i=$((i + 2)) ;;
            --signal=*|--kill-after=*|-s?*|-k?*) i=$((i + 1)) ;;
            -*) CSTAT=unreadable; return ;;
            *) break ;;
          esac
        done
        i=$((i + 1))   # the duration
        continue ;;
    esac
    CI=$i; return
  done
}

is_shell_word() { case "$1" in bash|sh|zsh|dash|ksh|eval|source|.) return 0 ;; esac; return 1; }

# Commands whose arguments are data, not code. $1 = lowercase basename of the
# command word; arguments are T[CI+1..].
is_inert() {
  local b="$1" k t sub
  case "$b" in
    echo|printf|cat|head|tail|wc|ls|sed|jq|sort|uniq|cut|tr|less|tee|diff|true|false|:|test|'[') return 0 ;;
    rg|grep)
      for ((k = CI + 1; k < N; k++)); do
        case "${T[k]}" in --pre|--pre=*|--hostname-bin|--hostname-bin=*) return 1 ;; esac
      done
      return 0 ;;
    git)
      k=$((CI + 1))
      while [ "$k" -lt "$N" ]; do
        t="${T[k]}"
        case "$t" in
          -C|--git-dir|--work-tree|--namespace) k=$((k + 2)) ;;
          -c*|--config-env*|--exec-path*) return 1 ;;
          -*) k=$((k + 1)) ;;
          *) break ;;
        esac
      done
      sub="${T[k]:-}"
      case "$sub" in commit|log|show|diff|status|add|tag|branch|stash|grep|blame|notes) return 0 ;; esac
      return 1 ;;
  esac
  return 1
}

# --- gh api ---------------------------------------------------------------
API_SEEN=0

api_check() { # $1: index of the first word after `api`
  local j="$1" posonly=0 t f name val vf hasval c rest r2
  local npos=0 endpoint="" endf=0 nmeth=0 methbad=0 have_field=0 have_input=0 help=0
  local hdrbad=0 q k
  local -a qv=() qfl=()
  API_SEEN=1
  while [ "$j" -lt "$N" ]; do
    t="${T[j]}"; f="${F:j:1}"
    if [ "$posonly" -eq 0 ] && [ "$t" = -- ]; then posonly=1; j=$((j + 1)); continue; fi
    if [ "$posonly" -eq 0 ] && [[ "$t" == -?* ]]; then
      [ "$f" = 0 ] || deny_unread "a flag word holds an expansion"
      case "${t:0:3}" in *'{'*) deny_unread "a flag word holds a brace expansion" ;; esac
      j=$((j + 1))
      if [[ "$t" == --* ]]; then
        name="${t%%=*}"; hasval=0; val=""; vf=0
        braced "$name" && deny_unread "a flag word holds a brace expansion"
        if [[ "$t" == *=* ]]; then hasval=1; val="${t#*=}"; vf="$f"; fi
        case "$name" in
          --paginate|--slurp|--include|--silent|--verbose) [ "$hasval" -eq 0 ] || deny_unread "unexpected value on a switch" ;;
          --help) help=1 ;;
          --method|--field|--raw-field|--input|--header|--jq|--template|--cache|--preview|--hostname)
            if [ "$hasval" -eq 0 ]; then
              [ "$j" -lt "$N" ] || deny_unread "a flag is missing its value"
              val="${T[j]}"; vf="${F:j:1}"; j=$((j + 1))
            fi
            rec_flag "$name" "$val" "$vf" ;;
          *) deny_unread "a flag outside the supported set" ;;
        esac
      else
        rest="${t#-}"
        while [ -n "$rest" ]; do
          c="${rest:0:1}"
          case "$c" in
            i) rest="${rest:1}" ;;
            h) help=1; rest="${rest:1}" ;;
            X|f|F|H|q|t|p)
              r2="${rest:1}"; vf="$f"
              if [ -z "$r2" ]; then
                [ "$j" -lt "$N" ] || deny_unread "a flag is missing its value"
                val="${T[j]}"; vf="${F:j:1}"; j=$((j + 1))
              elif [ "${#r2}" -ge 2 ] && [ "${r2:0:1}" = "=" ]; then val="${r2:1}"
              else val="$r2"; fi
              case "$c" in
                X) rec_flag --method "$val" "$vf" ;;
                f) rec_flag --raw-field "$val" "$vf" ;;
                F) rec_flag --field "$val" "$vf" ;;
                H) rec_flag --header "$val" "$vf" ;;
                *) : ;;
              esac
              rest="" ;;
            *) deny_unread "a flag outside the supported set" ;;
          esac
        done
      fi
      continue
    fi
    if is_redir "$t"; then j=$((j + REDIR)); continue; fi
    npos=$((npos + 1)); endpoint="$t"; endf="$f"; j=$((j + 1))
  done
  [ "$help" -eq 1 ] && return 0
  [ "$npos" -ne 0 ] || return 0   # the CLI rejects a call without an endpoint before sending anything
  [ "$npos" -eq 1 ] || deny_unread "the endpoint is repeated"
  [ "$endf" = 0 ] || deny_unread "the endpoint holds an expansion"
  braced "$endpoint" && deny_unread "the endpoint holds a brace expansion"
  [ "$hdrbad" -eq 0 ] || deny_unread "a header outside the read-neutral set"
  [ "$methbad" -eq 0 ] || deny_write "a non-GET method"

  lcase "$endpoint"; name="$LC"
  name="${name%%[?#]*}"
  while [ "${name%/}" != "$name" ]; do name="${name%/}"; done
  if [ "$name" = graphql ] || [[ "$name" == */graphql ]]; then
    [ "$have_input" -eq 0 ] || deny_unread "the GraphQL body comes from an input source"
    [ "${#qv[@]}" -gt 0 ] || deny_unread "no inline GraphQL query"
    for ((k = 0; k < ${#qv[@]}; k++)); do
      q="${qv[k]}"
      [ "${qfl[k]}" = 0 ] || deny_unread "the GraphQL query holds an expansion"
      [[ "$q" != @* ]] || deny_unread "the GraphQL query is read from a file"
      [ "${#q}" -le "$MAX_QUERY" ] || deny_unread "the GraphQL query is over the size cap"
      lcase "$q"
      if [[ "$LC" =~ $RE_MUT ]]; then
        gql_allowed "$q" || deny "graphql-mutation" "a GraphQL mutation outside the board-item operations" \
          "Only project-item mutations (add/update/clear items and fields), updateIssue and addComment pass."
      fi
    done
    return 0
  fi
  if [ "$nmeth" -eq 0 ] && { [ "$have_field" -eq 1 ] || [ "$have_input" -eq 1 ]; }; then
    deny_write "fields or an input body without a method make the CLI send a POST"
  fi
  return 0
}

# Records one api flag (canonical long name). Uses api_check's locals.
rec_flag() {
  local name="$1" val="$2" vf="$3" hname
  case "$name" in
    --method)
      nmeth=$((nmeth + 1))
      [ "$vf" = 0 ] || deny_unread "the method holds an expansion"
      braced "$val" && deny_unread "the method holds a brace expansion"
      shopt -s nocasematch
      [[ "$val" == GET ]] || methbad=1
      shopt -u nocasematch ;;
    --field|--raw-field)
      have_field=1
      if [[ "$val" == *=* ]] && [ "${val%%=*}" = query ]; then qv+=("${val#*=}"); qfl+=("$vf"); fi ;;
    --input) have_input=1 ;;
    --header)
      [ "$vf" = 0 ] || { hdrbad=1; return 0; }
      if [[ "$val" != *:* ]]; then hdrbad=1; return 0; fi
      hname="${val%%:*}"
      hname="${hname#"${hname%%[![:space:]]*}"}"; hname="${hname%"${hname##*[![:space:]]}"}"
      shopt -s nocasematch
      case "$hname" in Accept|X-GitHub-Api-Version) ;; *) hdrbad=1 ;; esac
      shopt -u nocasematch ;;
  esac
  return 0
}

handle_gh() { # command word is gh at T[CI]
  local j=$((CI + 1)) t sub
  while [ "$j" -lt "$N" ]; do
    t="${T[j]}"
    if is_redir "$t"; then j=$((j + REDIR)); continue; fi
    [ "${F:j:1}" = 0 ] || deny_unread "a word before the subcommand holds an expansion"
    case "$t" in
      -R|--repo) j=$((j + 2)) ;;
      -R?*|--repo=*|-h|--help|--version) j=$((j + 1)) ;;
      -*) deny_unread "a global flag outside the supported set" ;;
      *) break ;;
    esac
  done
  [ "$j" -lt "$N" ] || return 0
  sub="${T[j]}"
  case "$sub" in
    api) api_check $((j + 1)) ;;
    alias)
      j=$((j + 1))
      while [ "$j" -lt "$N" ]; do
        case "${T[j]}" in
          -*) j=$((j + 1)) ;;
          set|import) deny_write "an alias can stand for an api call" ;;
          *) break ;;
        esac
      done ;;
  esac
  return 0
}

# --- segment / script analysis ----------------------------------------------
analyze_segment() { # segment, flags, previous connector, depth
  local seg="$1" flags="$2" prev="$3" depth="$4" x tok inner b k rest ltxt ghx=0
  split_tokens "$seg"
  T=(${TOKS[@]+"${TOKS[@]}"}); F="${flags//[^01]/}"; N=${#T[@]}
  [ "$N" -gt 0 ] || return 0
  local -a LT=(${T[@]+"${T[@]}"})
  local LF="$F" LN="$N" txt=" ${T[*]} "

  # Substitutions that sit inside any word are analysed as commands of their own.
  for ((x = 0; x < LN; x++)); do
    [ "${LF:x:1}" = 1 ] || continue
    tok="${LT[x]}"
    case "$tok" in *'$('*|*'`'*) ;; *) continue ;; esac
    mentions "$tok" || continue
    rest="$tok"
    while [[ "$rest" == *'$('* ]]; do
      rest="${rest#*'$('}"; inner="$rest"
      case "$inner" in *')'*) inner="${inner%')'*}" ;; esac
      analyze_script "$inner" $((depth + 1))
    done
    rest="$tok"
    while [[ "$rest" == *'`'* ]]; do
      rest="${rest#*'`'}"; inner="${rest%%'`'*}"
      analyze_script "$inner" $((depth + 1))
      case "$rest" in *'`'*) rest="${rest#*'`'}" ;; *) break ;; esac
    done
  done
  T=(${LT[@]+"${LT[@]}"}); F="$LF"; N="$LN"

  lcase "$txt"; ltxt="$LC"
  if [[ "$ltxt" =~ $RE_GH ]] && [[ "$LF" == *1* ]]; then ghx=1; fi
  [[ "$ltxt" =~ $RE_API ]] || [[ "$ltxt" =~ $RE_ALIAS ]] || [ "$ghx" -eq 1 ] || { sink_check "$prev"; return 0; }
  resolve_cmd
  if [ "$CSTAT" = exp ]; then
    [[ "$ltxt" =~ $RE_API ]] && deny_unread "the command word holds an expansion"
    return 0
  fi
  if ! mentions "$txt"; then
    if [ "$CSTAT" = ok ] && [ "$CI" -ge 0 ]; then
      lcase "${T[CI]##*/}"
      case "$LC" in gh|gh.exe) handle_gh; return 0 ;; esac
    fi
    sink_check "$prev"; return 0
  fi
  [ "$CSTAT" = ok ] || deny_unread "an unrecognised wrapper stands before the command"
  [ "$CI" -ge 0 ] || return 0
  lcase "${T[CI]##*/}"; b="$LC"
  case "$b" in
    gh|gh.exe) handle_gh; return 0 ;;
  esac
  if is_inert "$b"; then MENTION=1; return 0; fi
  if is_shell_word "$b"; then
    local ci="$CI"
    for ((k = ci + 1; k < LN; k++)); do
      [ "${LF:k:1}" = 0 ] || deny_unread "an interpreter body holds an expansion"
    done
    for ((k = ci + 1; k < LN; k++)); do
      mentions "${LT[k]}" || continue
      [ "${LF:k:1}" = 0 ] || deny_unread "an interpreter body holds an expansion"
      analyze_script "${LT[k]}" $((depth + 1))
    done
    if [ "$b" = eval ]; then
      inner=""
      for ((k = ci + 1; k < LN; k++)); do inner+="${LT[k]} "; done
      analyze_script "$inner" $((depth + 1))
    fi
    return 0
  fi
  deny_unread "gh is not in a command position the hook can read"
}

# A segment fed by a pipe that runs its input as code, after text that names
# `gh api`: the text is the program.
sink_check() { # previous connector
  local b
  [ "$MENTION" -eq 1 ] && [ "$1" = "|" ] || return 0
  resolve_cmd
  [ "$CI" -ge 0 ] || return 0
  lcase "${T[CI]##*/}"; b="$LC"
  if is_shell_word "$b" || [ "$b" = xargs ]; then deny_unread "text naming gh api is piped into an interpreter"; fi
  return 0
}

# A segment opened by `(` right after a `<` word is a process substitution; when
# the segment before it runs its output as code, text naming gh api in the body is
# the program.
ps_check() { # previous segment, its flags, this segment
  local p="${1//$'\n'/}" b
  [[ "$p" == *"<$US" ]] || return 0
  mentions "$3" || return 0
  split_tokens "$p"
  T=(${TOKS[@]+"${TOKS[@]}"}); F="${2//[^01]/}"; N=${#T[@]}
  resolve_cmd
  if [ "$CSTAT" != ok ]; then deny_unread "a process substitution body feeds a command the hook cannot read"; fi
  [ "$CI" -ge 0 ] || return 0
  lcase "${T[CI]##*/}"; b="$LC"
  if is_shell_word "$b" || [ "$b" = xargs ]; then deny_unread "text naming gh api is fed into an interpreter"; fi
  return 0
}

MENTION=0
analyze_script() { # text, depth
  local text="$1" depth="$2" stripped lo lx lc k prev
  local -a segs=() xs=()
  [ "$depth" -le "$MAX_DEPTH" ] || deny_unread "substitutions are nested too deeply"
  SCRIPTS=$((SCRIPTS + 1))
  [ "$SCRIPTS" -le "$MAX_SCRIPTS" ] || deny_unread "too many nested substitutions"
  local MENTION=0
  stripped="$(strip_heredocs "$text")" || stripped="$text"
  [ "${#stripped}" -le "$MAX_LEN" ] || deny_unread "the command is over the size cap"
  lex "$stripped"
  lo="$LEX_OUT"; lx="$LEX_EXP"; lc="$LEX_CONN"
  IFS="$RS" read -r -d '' -a segs <<< "$lo" || true
  IFS="$RS" read -r -d '' -a xs <<< "$lx" || true
  for ((k = 0; k < ${#segs[@]}; k++)); do
    [ -n "${segs[k]//$'\n'/}" ] || continue
    prev=""; [ "$k" -gt 0 ] && prev="${lc:$((k - 1)):1}"
    if [ "$prev" = "(" ]; then ps_check "${segs[k - 1]}" "${xs[k - 1]:-}" "${segs[k]}"; fi
    analyze_segment "${segs[k]}" "${xs[k]:-}" "$prev" "$depth"
  done
  return 0
}

# Heredoc prose is stripped before lexing, so text piped from a heredoc into an
# interpreter is checked on the raw command.
if [[ "$command_str" == *'<<'* ]] && [[ "$command_str" =~ $RE_PIPE_SHELL ]] && mentions "$command_str"; then
  deny_unread "text naming gh api is piped into an interpreter"
fi

# shellcheck disable=SC2034  # read by lex() in lib/shell-lex.sh
LEX_MARK=1
analyze_script "$command_str" 0
if [ "$API_SEEN" -eq 1 ]; then
  log_decision "$HOOK_NAME" "Bash" "" "allow" "gh api call proven read-only or a board-item mutation"
fi
exit 0
