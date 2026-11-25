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
# (the token `gh`, or a path whose last component is `gh`) anywhere other than
# the command word is blocked, whether or not an `api` word appears (the
# subcommand can reach `gh` from outside the segment text), unless the command
# word is inert or a lookup (`command -v|-V`, `type`, `which`); so is a
# segment whose command word holds an expansion, sits behind an unknown wrapper,
# or is an interpreter body that cannot be re-lexed (a leading `{`, `then`, `do`
# and similar keyword is skipped when no `api` word is present); `-c`/eval bodies and `$(...)` substitutions are re-lexed (bounded
# depth). Echo/printf, commit messages, searches, heredoc prose and the like
# are inert, unless that text is piped into an interpreter.
# Inert is a closed rule: the command word counts only when nothing stands
# before it (no assignment, no wrapper: the environment of a command can make it
# run text), and only from a closed set of words. Some of those words are inert
# with any arguments; the rest only when every option is in that word's
# read-only set, so an option outside it makes the word non-inert. A segment of
# assignments only that names `gh` passes only when each such value is exactly
# one command substitution (its body is checked).
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
#
# The structure around the call is closed too. The operator string between
# segments is read, and a segment holding a `gh api` call passes only when it
# is standalone, joined to its neighbours by `&&`, `||`, `;` or a newline, or
# piped through a plain `|` into read-only filters (jq, head, tail, wc, sort,
# uniq, cut, tr, base64) given plain arguments with no expansion. Anything else
# around the call is blocked: a background `&`, a `|&` pipe or a pipe at the end
# of a line, input redirection, a group, subshell, process substitution, a
# keyword or compound construct such as an `if` condition or a negation, a
# pipe from another command into the call, and a pipe into any other program.
# Output redirects are allowed only to /dev/null. A help flag (`-h`/`--help`)
# given a value is not a help request and is checked as an ordinary call.
# Sibling segments joined by `&&`, `||` or `;` that mention neither `gh` nor
# `api` are ignored (a `cd` before the call passes); siblings that mention `gh`
# are checked as well.
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

# Fast path: the text holds `gh`, or an `api` word next to an expansion. Quotes
# are dropped first so a word split by quoting still counts.
plain="$(printf '%s' "$command_str" | tr -d "'\"\\\\")"
need=0
shopt -s nocasematch
case "$plain" in
  *gh*) need=1 ;;
esac
# A brace or glob can spell `gh`, `api` or `alias` without the words appearing.
case "$plain" in *'{'*|*'*'*|*'?'*|*'['*) need=1 ;; esac
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
# A gh word proper: the token `gh` or a path whose last component is `gh`; a path
# that only has a `gh` directory component is not one.
RE_GHW='(^|[^[:alnum:]_.-])gh(\.exe)?($|[^[:alnum:]_./-])'
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

# The redirection at T[$1] (is_redir just matched it) is output sent to
# /dev/null; input redirections and any other target are refused.
redir_skip() {
  local t="${T[$1]}" tgt tf="${F:$1:1}"
  [[ "$t" =~ $RE_REDIR ]] || return 0
  case "${BASH_REMATCH[1]}" in '>'|'>>'|'>|') ;; *) deny_unread "input is redirected into the command" ;; esac
  tgt="${BASH_REMATCH[2]}"
  if [ "$REDIR" -eq 2 ]; then tgt="${T[$1 + 1]:-}"; tf="${F:$(($1 + 1)):1}"; fi
  [ "$tf" = 0 ] && [ "$tgt" = /dev/null ] || deny_unread "output is redirected somewhere other than /dev/null"
}

# An operator string between two commands that only sequences them: `&&`, `||`,
# `;` or a newline, then any further newlines.
joiner() {
  local o="$1"
  case "$o" in
    '&&'*) o="${o#&&}" ;;
    '||'*) o="${o#||}" ;;
    ';'*) o="${o#;}" ;;
    $'\n'*) o="${o#$'\n'}" ;;
    *) return 1 ;;
  esac
  while [ "${o#$'\n'}" != "$o" ]; do o="${o#$'\n'}"; done
  [ -z "$o" ]
}

load_seg() { # segment, flags
  split_tokens "$1"
  T=(${TOKS[@]+"${TOKS[@]}"}); F="${2//[^01]/}"; N=${#T[@]}
}

# Brace expansion that could rewrite a flag or endpoint word.
braced() { case "$1" in *'{'*,*'}'*|*'{'*..*'}'*) return 0 ;; esac; return 1; }

# Any brace or glob metacharacter; none belongs in a word that picks the command
# or the gh subcommand.
meta() { case "$1" in *'{'*|*'*'*|*'?'*|*'['*) return 0 ;; esac; return 1; }

# 0 when the script text holds, outside quotes, a character of the kinds the
# word $1 carries that the shell would expand into more than one word: a brace
# group (`{` not followed by whitespace), `*`, `?` or `[`. Quote state is
# tracked here because the lexer drops it. Unbalanced input counts as unquoted.
unquoted_meta() {
  local LC_ALL=C w="$1" c st=0 esc=0 cm=0 pb=0 prev=" " wb=0 wg=0 wq=0 wr=0
  case "$w" in *'{'*) wb=1 ;; esac
  case "$w" in *'*'*) wg=1 ;; esac
  case "$w" in *'?'*) wq=1 ;; esac
  case "$w" in *'['*) wr=1 ;; esac
  while IFS= read -r -d '' -n 1 c; do
    if [ "$cm" = 1 ]; then [ "$c" = $'\n' ] && cm=0; prev="$c"; continue; fi
    if [ "$pb" = 1 ]; then
      pb=0
      case "$c" in ' '|$'\t'|$'\n'|$'\r') ;; *) return 0 ;; esac
    fi
    if [ "$esc" = 1 ]; then esc=0; prev="$c"; continue; fi
    case "$st" in
      1) [ "$c" = "'" ] && st=0 ;;
      2) case "$c" in '\') esc=1 ;; '"') st=0 ;; esac ;;
      3) case "$c" in '\') esc=1 ;; "'") st=0 ;; esac ;;
      0) case "$c" in
           '\') esc=1 ;;
           "'") if [ "$prev" = '$' ]; then st=3; else st=1; fi ;;
           '"') st=2 ;;
           '#') case "$prev" in ' '|$'\t'|$'\n'|';'|'&'|'|'|'('|')') cm=1 ;; esac ;;
           '{') if [ "$wb" = 1 ] && [ "$prev" != '$' ]; then pb=1; fi ;;
           '*') [ "$wg" = 0 ] || return 0 ;;
           '?') [ "$wq" = 0 ] || return 0 ;;
           '[') [ "$wr" = 0 ] || return 0 ;;
         esac ;;
    esac
    prev="$c"
  done <<< "$SRC"
  [ "$st" -eq 0 ] || return 0
  return 1
}

# --- GraphQL document scanner ---------------------------------------------
GQL_T=()
GQL_FIELDS=()
GQL_P=0

gql_tokenize() {
  local LC_ALL=C r="$1" rest pre m
  local lt=$'\n\r' tab=$'\t'
  local re_ws="^[ $tab$lt,]+" re_com="^#[^$lt]*" re_name='^[_A-Za-z][_0-9A-Za-z]*'
  local re_num='^-?[0-9][-+._0-9A-Za-z]*' re_str="^\"([^\"\\\\$lt]|\\\\[^$lt])*\""
  GQL_T=()
  r="${r#$'\xef\xbb\xbf'}"
  # Control characters other than tab and line terminators are not valid
  # anywhere in a document (strings and comments included); refuse them.
  m="${r//[$tab$lt]/}"
  case "$m" in *[[:cntrl:]]*) return 1 ;; esac
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
  local i=0 t b st=0
  CI=-1; CSTAT=ok
  while [ "$i" -lt "$N" ]; do
    t="${T[i]}"
    if [[ "$t" =~ $RE_ASSIGN ]]; then i=$((i + 1)); continue; fi
    if [ "${F:i:1}" = 1 ]; then CSTAT=exp; CI=$i; return; fi
    lcase "${t##*/}"; b="$LC"
    case "$b" in
      nohup|builtin) i=$((i + 1)); continue ;;
      command|exec|time)
        i=$((i + 1)); st=$i
        while [ "$i" -lt "$N" ]; do
          case "${T[i]}" in
            --) i=$((i + 1)); break ;;
            -p) i=$((i + 1)) ;;
            -v|-V) [ "$b" = command ] || { CSTAT=unreadable; return; }; CI=$((st - 1)); return ;;
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

# Closed option scan for the words that are inert only with read-only options.
# $1 = first index to scan. O_S0 / O_S1 = short flags without / with a value,
# O_L0 / O_L1 = long flags without / with a value (space-padded lists). A long
# flag in O_L0 given an `=` value, and any option outside the four sets, fail.
# Scanning stops at `--`; non-option words are skipped.
O_S0=""; O_S1=""; O_L0=""; O_L1=""
opts_ok() {
  local k="$1" t c rest name
  while [ "$k" -lt "$N" ]; do
    t="${T[k]}"
    case "$t" in
      --) return 0 ;;
      --*)
        name="${t%%=*}"
        if [[ "$O_L1" == *" $name "* ]]; then
          if [[ "$t" == *=* ]]; then k=$((k + 1)); else k=$((k + 2)); fi
        elif [[ "$O_L0" == *" $name "* ]] && [[ "$t" != *=* ]]; then k=$((k + 1))
        else return 1; fi ;;
      -?*)
        rest="${t#-}"; k=$((k + 1))
        while [ -n "$rest" ]; do
          c="${rest:0:1}"; rest="${rest:1}"
          if [[ "$O_S0" == *" $c "* ]]; then continue
          elif [[ "$O_S1" == *" $c "* ]]; then
            [ -n "$rest" ] || k=$((k + 1))
            break
          else return 1; fi
        done ;;
      *) k=$((k + 1)) ;;
    esac
  done
  return 0
}

# A value that is exactly one $(...) or `...` substitution.
one_subst() {
  local v="$1" n
  case "$v" in
    '$('*) n=$(_subst_len '$' "$v") ;;
    '`'*) n=$(_subst_len '`' "$v") ;;
    *) return 1 ;;
  esac
  [ "$n" -gt 0 ] && [ "$n" -eq "${#v}" ]
}

# Commands whose arguments are data, not code. $1 = lowercase basename of the
# command word; arguments are T[CI+1..]. Closed tiers: a word is inert only if
# it appears here, and tier 2 words only with options from their allowlist
# (INERT_OPT=1 marks a refusal caused by an option).
INERT_OPT=0
is_inert() {
  local b="$1" k t sub
  INERT_OPT=0
  case "$b" in
    # Tier 1: no option on macOS (BSD) or Linux (GNU) runs a program or shell
    # text; any arguments are fine. Checked against both man pages. `command`
    # reaches here only as `command -v|-V` (resolve_cmd), and type / which only
    # look names up.
    echo|cat|head|tail|wc|ls|cut|tr|uniq|tee|diff|jq|grep|true|false|:|test|'['|command|type|which) return 0 ;;
    # Tier 2 (below): inert only when every option is in the word's closed set.
    # printf takes no options: a leading -v assigns a shell variable.
    printf)
      case "${T[CI+1]:-}" in -|--|'') return 0 ;; -*) INERT_OPT=1; return 1 ;; esac
      return 0 ;;
    rg)
      O_S0=" n i l w F s S v c H h I N q u U o x r "; O_S1=" e g t T A B C m f M j "
      O_L0=" --no-heading --heading --line-number --no-line-number --ignore-case --smart-case --case-sensitive --files-with-matches --files-without-match --word-regexp --fixed-strings --invert-match --count --with-filename --no-filename --hidden --no-ignore --follow --only-matching --line-regexp --quiet --files --json --column --vimgrep --stats "
      O_L1=" --regexp --glob --iglob --type --type-not --after-context --before-context --context --max-count --max-depth --file --color --threads --max-columns --replace "
      opts_ok $((CI + 1)) || { INERT_OPT=1; return 1; }
      return 0 ;;
    less)
      O_S0=" N i I S R r F X E q Q s w m M n "; O_S1=""
      O_L0=" --line-numbers --ignore-case --IGNORE-CASE --chop-long-lines --RAW-CONTROL-CHARS --quit-if-one-screen --no-init --quit-at-eof "; O_L1=""
      opts_ok $((CI + 1)) || { INERT_OPT=1; return 1; }
      for ((k = CI + 1; k < N; k++)); do
        case "${T[k]}" in +*) INERT_OPT=1; return 1 ;; esac   # `+cmd` runs a less command
      done
      return 0 ;;
    sort)
      O_S0=" b d f g h i M n R r V u s c C m z "; O_S1=" k t "
      O_L0=" --reverse --numeric-sort --unique --ignore-case --stable --version-sort --human-numeric-sort --month-sort --general-numeric-sort --dictionary-order --ignore-leading-blanks --check --merge --zero-terminated "
      O_L1=" --key --field-separator "
      opts_ok $((CI + 1)) || { INERT_OPT=1; return 1; }
      return 0 ;;
    git)
      k=$((CI + 1))
      while [ "$k" -lt "$N" ]; do
        t="${T[k]}"
        case "$t" in
          -C|--git-dir|--work-tree|--namespace) k=$((k + 2)) ;;
          --git-dir=*|--work-tree=*|--namespace=*|-p|--paginate|-P|--no-pager|--bare|--literal-pathspecs|--no-optional-locks) k=$((k + 1)) ;;
          -*) INERT_OPT=1; return 1 ;;
          *) break ;;
        esac
      done
      sub="${T[k]:-}"
      case "$sub" in
        grep)
          # The only listed subcommand with an option that runs a program
          # (`-O` / `--open-files-in-pager`), so it gets a closed option set.
          O_S0=" 0 1 2 3 4 5 6 7 8 9 a i I w v h H E G P F n c l L o q p W z "; O_S1=" e f A B C m "
          O_L0=" --cached --untracked --no-index --exclude-standard --no-exclude-standard --recurse-submodules --text --ignore-case --word-regexp --invert-match --no-recursive --recursive --full-name --extended-regexp --basic-regexp --perl-regexp --fixed-strings --line-number --column --null --count --files-with-matches --name-only --files-without-match --only-matching --show-function --function-context --heading --break --no-heading --no-break --and --or --not --all-match --quiet --no-color --color --textconv --no-textconv "
          O_L1=" --max-depth --max-count --after-context --before-context --context --file --threads "
          opts_ok $((k + 1)) || { INERT_OPT=1; return 1; }
          return 0 ;;
        # The other listed subcommands take no option whose value is a program
        # or shell text; programs they can start come from config or the
        # environment, which a prefix or `-c` would set and both are refused.
        commit|log|show|diff|status|add|tag|branch|stash|blame|notes) return 0 ;;
      esac
      return 1 ;;
  esac
  return 1
}

# --- gh api ---------------------------------------------------------------
API_SEEN=0
SRC=""

api_check() { # $1: index of the first word after `api`
  local j="$1" posonly=0 t f name val vf hasval c rest r2
  local npos=0 endpoint="" endf=0 nmeth=0 methbad=0 have_field=0 have_input=0 help=0
  local hdrbad=0 q k fbad=0 qtyped=0
  local -a qv=() qfl=()
  API_SEEN=$((API_SEEN + 1))
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
          --help) [ "$hasval" -eq 0 ] || deny_unread "unexpected value on a switch"; help=1 ;;
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
    if is_redir "$t"; then redir_skip "$j"; j=$((j + REDIR)); continue; fi
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
    [ "$fbad" -eq 0 ] || deny_unread "a GraphQL field has a key that cannot be read or can split into more fields"
    [ "${#qv[@]}" -eq 1 ] || deny_unread "more than one GraphQL query field"
    [ "$qtyped" -eq 0 ] || deny_unread "the GraphQL query is a typed field, which the CLI rewrites before sending"
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
      if [ "$vf" != 0 ] || [[ "$val" != *=* ]] || ! [[ "${val%%=*}" =~ ^[A-Za-z0-9_.-]+$ ]]; then fbad=1
      elif [ "${val%%=*}" = query ]; then
        qv+=("${val#*=}"); qfl+=("$vf")
        [ "$name" = --raw-field ] || qtyped=1
      fi
      case "$val" in *'{'*|*'*'*|*'?'*|*'['*) ! unquoted_meta "$val" || fbad=1 ;; esac ;;
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
    if is_redir "$t"; then redir_skip "$j"; j=$((j + REDIR)); continue; fi
    [ "${F:j:1}" = 0 ] || deny_unread "a word before the subcommand holds an expansion"
    ! meta "$t" || deny_unread "a word before or at the subcommand holds a brace or glob pattern"
    case "$t" in
      -R|--repo)
        [ "${F:j+1:1}" = 0 ] && ! meta "${T[j+1]:-}" || deny_unread "the repository value holds an expansion or pattern"
        j=$((j + 2)) ;;
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
analyze_segment() { # segment, flags, operator before it, depth
  local prev="$3" depth="$4" x tok inner b k rest ltxt hasgh=0 tm
  load_seg "$1" "$2"
  [ "$N" -gt 0 ] || return 0
  local -a LT=(${T[@]+"${T[@]}"})
  local LF="$F" LN="$N" txt=" ${T[*]} " cw

  # Substitutions that sit inside any word are analysed as commands of their own.
  # A substitution that does not close, in a segment that names gh, cannot be read.
  lcase "$txt"; ltxt="$LC"
  for ((x = 0; x < LN; x++)); do
    [ "${LF:x:1}" = 1 ] || continue
    tok="${LT[x]}"
    case "$tok" in *'$('*|*'`'*) ;; *) continue ;; esac
    tm=0; ! mentions "$tok" || tm=1
    rest="$tok"
    while [[ "$rest" == *'$('* ]]; do
      rest="\$(${rest#*'$('}"
      k=$(_subst_len '$' "$rest")
      if [ "$k" -eq 0 ]; then
        ! [[ "$ltxt" =~ $RE_GH ]] || deny_unread "a command substitution is not closed"
        break
      fi
      inner="${rest:2:k-3}"; rest="${rest:k}"
      [ "$tm" -eq 0 ] || analyze_script "$inner" $((depth + 1))
    done
    rest="$tok"
    while [[ "$rest" == *'`'* ]]; do
      rest="\`${rest#*'`'}"
      k=$(_subst_len '`' "$rest")
      if [ "$k" -eq 0 ]; then
        ! [[ "$ltxt" =~ $RE_GH ]] || deny_unread "a backtick substitution is not closed"
        break
      fi
      inner="${rest:1:k-2}"; rest="${rest:k}"
      [ "$tm" -eq 0 ] || analyze_script "$inner" $((depth + 1))
    done
  done
  T=(${LT[@]+"${LT[@]}"}); F="$LF"; N="$LN"

  if [[ "$ltxt" =~ $RE_GH ]]; then hasgh=1; fi
  [[ "$ltxt" =~ $RE_API ]] || [ "$hasgh" -eq 1 ] || meta "$txt" || { sink_check "$prev"; return 0; }
  resolve_cmd
  if [ "$CSTAT" = ok ] && [ "$CI" -ge 0 ]; then
    cw="${T[CI]}"
    if braced "$cw"; then deny_unread "the command word holds a brace expansion"; fi
    if meta "$cw" && [ "$cw" != "[" ] && [ "$cw" != "[[" ]; then
      lcase "${cw##*/}"
      # shellcheck disable=SC2053  # the pattern on the right is intended
      if [[ gh == $LC ]] || [[ gh.exe == $LC ]]; then deny_unread "the command word is a pattern that can name gh"; fi
    fi
  fi
  if [ "$CSTAT" = exp ]; then
    [[ "$ltxt" =~ $RE_API ]] && deny_unread "the command word holds an expansion"
    return 0
  fi
  if [ "$hasgh" -eq 0 ]; then
    # An attached option value can hold the gh text inside one word, so the
    # word-boundary match above misses it; an option outside a closed set is
    # still refused when an api word is present.
    if [[ "$ltxt" =~ $RE_API ]] && [ "$CSTAT" = ok ] && [ "$CI" -ge 0 ] && [[ "$ltxt" == *gh* ]]; then
      lcase "${T[CI]##*/}"
      is_inert "$LC" || [ "$INERT_OPT" -eq 0 ] || deny_unread "an option outside the read-only set of a command whose arguments name gh"
    fi
    sink_check "$prev"; return 0
  fi
  # Without an api word, a leading compound-command keyword is not the command.
  if ! [[ "$ltxt" =~ $RE_API ]] && ! [[ "$ltxt" =~ $RE_ALIAS ]]; then
    while [ "$CSTAT" = ok ] && [ "$CI" -eq 0 ] && [ "$N" -gt 1 ]; do
      case "${T[0]}" in '{'|then|do|else|elif|if|while|until|'!') ;; *) break ;; esac
      T=("${T[@]:1}"); F="${F:1}"; N=$((N - 1))
      resolve_cmd
    done
  fi
  [ "$CSTAT" = ok ] || deny_unread "an unrecognised wrapper stands before the command"
  if [ "$CI" -lt 0 ]; then
    # Assignments only: a value that names gh passes only as one command
    # substitution (its body is analysed above).
    for ((k = 0; k < N; k++)); do
      [[ "${T[k]}" =~ $RE_ASSIGN ]] || continue
      lcase "${T[k]#*=}"
      [[ "$LC" =~ $RE_GH ]] || continue
      one_subst "${T[k]#*=}" || deny_unread "an assignment value names gh other than as one command substitution"
    done
    return 0
  fi
  lcase "${T[CI]##*/}"; b="$LC"
  case "$b" in
    gh|gh.exe) handle_gh; return 0 ;;
  esac
  if is_inert "$b"; then
    [ "$CI" -eq 0 ] || deny_unread "a prefix stands before a command whose arguments name gh"
    if mentions "$txt"; then MENTION=1; else sink_check "$prev"; fi
    return 0
  fi
  if is_shell_word "$b"; then
    local ci="$CI"
    for ((k = ci + 1; k < LN; k++)); do
      [ "${LF:k:1}" = 0 ] || deny_unread "an interpreter body holds an expansion"
    done
    for ((k = ci + 1; k < LN; k++)); do
      lcase "${LT[k]}"; [[ "$LC" =~ $RE_GH ]] || continue
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
  [ "$INERT_OPT" -eq 0 ] || deny_unread "an option outside the read-only set of a command whose arguments name gh"
  [[ "$ltxt" =~ $RE_GHW ]] || { sink_check "$prev"; return 0; }
  deny_unread "gh is not in a command position the hook can read"
}

# A segment fed by a pipe (`|`, `|&`, or a pipe that ends its line) that runs its
# input as code, after text that names `gh api`: the text is the program.
sink_check() { # operator before this segment
  local b
  [ "$MENTION" -eq 1 ] || return 0
  case "$1" in '||'*) return 0 ;; '|'*) ;; *) return 0 ;; esac
  resolve_cmd
  [ "$CI" -ge 0 ] || return 0
  lcase "${T[CI]##*/}"; b="$LC"
  if is_shell_word "$b" || [ "$b" = xargs ]; then deny_unread "text naming gh api is piped into an interpreter"; fi
  return 0
}

# One stage after a pipe from gh api: a closed set of read-only filters, each
# taking plain words only.
filter_check() { # segment, flags
  local b k t sawdec=0
  load_seg "$1" "$2"
  resolve_cmd
  { [ "$CSTAT" = ok ] && [ "$CI" -eq 0 ]; } || deny_unread "a stage after gh api starts with an assignment, a wrapper or an expansion"
  b="${T[0]}"
  case "$b" in
    jq|head|tail|wc|sort|uniq|cut|tr|base64) ;;
    *) deny_unread "gh api output is piped into a program outside the read-only filter set" ;;
  esac
  for ((k = 1; k < N; k++)); do
    t="${T[k]}"
    [ "${F:k:1}" = 0 ] || deny_unread "a filter argument holds an expansion"
    braced "$t" && deny_unread "a filter argument holds a brace expansion"
    if is_redir "$t"; then redir_skip "$k"; k=$((k + REDIR - 1)); continue; fi
    case "$b" in
      sort) case "$t" in --*|-*o*) deny_unread "sort is given a long option or an output option" ;; esac ;;
      uniq) case "$t" in -*|[0-9]*) ;; *) deny_unread "uniq is given an output file" ;; esac ;;
      base64) case "$t" in -d|-D|--decode) sawdec=1 ;; *) deny_unread "base64 is given more than a decode flag" ;; esac ;;
    esac
  done
  [ "$b" != base64 ] || [ "$sawdec" -eq 1 ] || deny_unread "base64 after gh api only decodes"
  return 0
}

# A segment opened by `(` right after a `<` word is a process substitution; when
# the segment before it runs its output as code, text naming gh api in the body is
# the program.
ps_check() { # previous segment, its flags, this segment
  local p="${1//$'\n'/}" b
  [[ "$p" == *"<$US" ]] || return 0
  mentions "$3" || return 0
  load_seg "$p" "$2"
  resolve_cmd
  if [ "$CSTAT" != ok ]; then deny_unread "a process substitution body feeds a command the hook cannot read"; fi
  [ "$CI" -ge 0 ] || return 0
  lcase "${T[CI]##*/}"; b="$LC"
  if is_shell_word "$b" || [ "$b" = xargs ]; then deny_unread "text naming gh api is fed into an interpreter"; fi
  return 0
}

MENTION=0
# A segment holding a gh api call (directly or in a substitution or interpreter
# body) is allowed in three shapes only: alone in its pipeline; piped with a
# plain `|` into read-only filters; or sequenced with its neighbours by `&&`,
# `||`, `;` or a newline. A grouping, background, stderr-pipe or line-end pipe
# operator, or any other consumer of its output, makes the call unreadable.
analyze_script() { # text, depth
  local text="$1" depth="$2" stripped lo lx lc k pc acc="" n0 i m
  local SRC
  local -a segs=() xs=() ne=() op=() api=()
  [ "$depth" -le "$MAX_DEPTH" ] || deny_unread "substitutions are nested too deeply"
  SCRIPTS=$((SCRIPTS + 1))
  [ "$SCRIPTS" -le "$MAX_SCRIPTS" ] || deny_unread "too many nested substitutions"
  local MENTION=0
  stripped="$(strip_heredocs "$text")" || stripped="$text"
  [ "${#stripped}" -le "$MAX_LEN" ] || deny_unread "the command is over the size cap"
  SRC="$stripped"
  lex "$stripped"
  lo="$LEX_OUT"; lx="$LEX_EXP"; lc="$LEX_CONN"
  IFS="$RS" read -r -d '' -a segs <<< "$lo" || true
  IFS="$RS" read -r -d '' -a xs <<< "$lx" || true
  for ((k = 0; k < ${#segs[@]}; k++)); do
    if [ -z "${segs[k]//$'\n'/}" ]; then acc+="${lc:k:1}"; continue; fi
    pc=""; [ "$k" -gt 0 ] && pc="${lc:$((k - 1)):1}"
    if [ "$pc" = "(" ]; then ps_check "${segs[k - 1]}" "${xs[k - 1]:-}" "${segs[k]}"; fi
    ne+=("$k"); op+=("$acc"); acc="${lc:k:1}"
    n0="$API_SEEN"
    analyze_segment "${segs[k]}" "${xs[k]:-}" "${op[${#op[@]} - 1]}" "$depth"
    if [ "$API_SEEN" -gt "$n0" ]; then api+=(1); else api+=(0); fi
  done
  op+=("$acc")
  for ((i = 0; i < ${#ne[@]}; i++)); do
    [ "${api[i]}" = 1 ] || continue
    [ -z "${op[i]}" ] || joiner "${op[i]}" || deny_unread "a gh api call follows a pipe, a grouping or a background operator"
    m=$i
    while [ "${op[m + 1]}" = "|" ]; do
      m=$((m + 1))
      [ "$m" -lt "${#ne[@]}" ] || deny_unread "a pipe after gh api has no command"
      filter_check "${segs[ne[m]]}" "${xs[ne[m]]:-}"
    done
    [ -z "${op[m + 1]}" ] || joiner "${op[m + 1]}" || deny_unread "gh api output goes through an operator the hook cannot read"
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
# shellcheck disable=SC2034  # read by lex() in lib/shell-lex.sh
LEX_NEST=1
analyze_script "$command_str" 0
if [ "$API_SEEN" -gt 0 ]; then
  log_decision "$HOOK_NAME" "Bash" "" "allow" "gh api call proven read-only or a board-item mutation"
fi
exit 0
