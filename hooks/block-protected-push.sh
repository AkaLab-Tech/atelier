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
# Hardened in #808:
#   - the command is parsed with the shared quote-aware lexer
#     (hooks/lib/shell-lex.sh), recursing into $(...) / backtick
#     substitutions and `bash -c` / `eval` bodies, instead of word-splitting;
#   - git invocations are resolved by hooks/lib/git-invocation.sh: global
#     options with their value arity, in-invocation and persistent aliases,
#     push-related config, push plumbing commands — so an invocation with no
#     literal `push` subcommand is still recognised;
#   - destinations are normalised the way git's ref lookup reads them, and a
#     non-tag destination whose last path component is protected is blocked;
#   - unresolved shell expansion in a push's command word, refspecs or options
#     fails closed (only for segments that could be a push).
#   - a command word outside the recognised set that is not data-only is a
#     possible runner: later git / shell tokens are scanned as commands and
#     whitespace-bearing tokens are rescanned as scripts; a shell reading stdin
#     has its statically known payload (here-string, heredoc, echo/printf args)
#     rescanned.
# Residual gaps (PLAN.md §3): scripts written first and run later, obfuscation
# through files or encoded payloads, text fed to a shell that is not in the
# command itself, and server-side protection (a separate control).
#
# Contract per Claude Code hooks reference (PreToolUse):
#   stdin  — JSON: { tool_name, tool_input: { command } }
#   exit 0 — allow the tool call
#   exit 2 — block (stderr goes to Claude's context with the explanation)
#   jq missing — fail OPEN (exit 0): a missing hook dependency must never
#   turn into a blanket block of every Bash call.

# shellcheck disable=SC2016,SC2088,SC1003,SC2018,SC2019,SC2153,SC2020
# (literal $ / backtick / backslash in patterns are intentional: lexer-level matching)
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

# Fast path. Every route to a push goes through a git binary, so the only
# pre-filter is the word `git` on a normalised copy of the command (quotes,
# backslashes and line continuations removed, any letter case — the filesystem
# may fold case), so `g\it`, `"g"it` and `GIT` still reach the parser. The old
# literal `*git*push*` filter missed forms with no `push` subcommand
# (aliases, plumbing) and obfuscated names.
# (tr, not ${var//x/}: bash 3.2 substitution is quadratic on long commands)
norm="$(printf '%s' "$command_str" | tr -d "\\\\\"'\n")"
case "$norm" in
  *[gG][iI][tT]*) ;;
  # no literal git, but a variable / substitution could supply the command word
  *push*'$'*|*push*'`'*|*'$'*push*|*'`'*push*) ;;
  # a glob-spelled command word (`/usr/bin/g?t`) can resolve to git
  *'*'*|*'?'*|*'['*)
    case "$(printf '%s' "$norm" | LC_ALL=C tr 'A-Z' 'a-z')" in
      *push*|*send-pack*) ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac

# Analysis cost is linear in command size and segment count (the bash lexer and
# per-segment resolver cost milliseconds per segment, several times that on a
# loaded host); an input past these bounds that names git fails closed instead
# of risking the hook timeout (which Claude Code treats as a non-blocking error,
# i.e. fail open). Every bound is checked before any lexing. The bounds sit well
# below what a legitimate Bash call needs; ANALYSIS_BUDGET_S is the backstop for
# inputs under the bounds that are still slow to analyse.
MAX_CMD_BYTES=100000
MAX_SEGMENTS=1500
ANALYSIS_BUDGET_S=5
DEADLINE=$((SECONDS + ANALYSIS_BUDGET_S))
oversize() { # reason detail
  printf '🚫 atelier:%s BLOCKED — %s (failing closed). Split it into smaller commands.\n' "$HOOK_NAME" "$1" >&2
  log_decision "$HOOK_NAME" "Bash" "$1" "block" "$2"
  exit 2
}
if [ "${#command_str}" -gt "$MAX_CMD_BYTES" ]; then
  oversize "command is ${#command_str} bytes and names git; too large to analyse for a push" "failing closed past $MAX_CMD_BYTES bytes"
fi

ORIG_COMMAND_STR="$command_str"

# Drop lines that are provably not a push before any lexing: a whole line that
# is `git <builtin non-push subcommand> <plain words>` — no quote, escape,
# expansion, glob, separator or redirection characters, no global option (so no
# -c alias / -C repo selection), and not the continuation of a backslash line.
# Git never lets an alias shadow these builtins, and a line with none of those
# characters cannot change how the surrounding text parses, so removing it
# changes neither the quoting nor the segmentation of the lines that remain.
IFS= read -r -d '' AWK_BENIGN <<'AWK' || true
BEGIN {
  ORS = "\n"; cont = 0
  re = "^[ \t]*git[ \t]+(status|log|diff|show|add|commit|fetch|pull|checkout|switch|branch|stash|rev-parse|ls-files|merge|reset|tag|remote|describe|blame|clean|restore|rm|mv|rev-list|cat-file|show-ref|for-each-ref|worktree|ls-remote|shortlog|cherry-pick|revert)([ \t]+[A-Za-z0-9_./=:@%,+-]+)*[ \t]*$"
}
{
  if (!cont && $0 ~ re) { cont = 0; next }
  print $0
  cont = ($0 ~ /\\$/)
}
AWK
command_str="$(printf '%s\n' "$command_str" | awk "$AWK_BENIGN")"
[ -n "$command_str" ] || exit 0
# the separators that start a new segment, counted without the bash lexer
# (newlines are not counted: quoted prose has many and costs little to lex)
seps="$(printf '%s' "$command_str" | tr -cd ';&|()`' | wc -c)"
if [ "${seps// /}" -gt "$MAX_SEGMENTS" ]; then
  oversize "command has about ${seps// /} segments and names git; too many to analyse for a push" "failing closed past $MAX_SEGMENTS segments"
fi

# shellcheck source=lib/shell-lex.sh
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/shell-lex.sh"
# shellcheck source=lib/git-invocation.sh
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/git-invocation.sh"

CUR_SEG_TEXT=""
MAX_DEPTH=4
ASSIGN_RE='^[A-Za-z_][A-Za-z0-9_]*='
REDIR_RE='^[0-9]*(>>|>\||&>|>|<)(.*)$'

block() {
  local reason="$1" detail="$2" segment="${3:-$CUR_SEG_TEXT}"
  segment="${segment:0:300}"
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

# --- single-quote masking ----------------------------------------------------
# The lexer drops quote information, so a `$(...)` or backtick that sat inside
# single quotes (a commit/PR body quoting `git push origin main` in backticks)
# would be rescanned as code. Mask `$` and backtick inside single quotes first
# (\002 / \003); bodies handed to a nested shell are unmasked before rescanning.
# Comments are skipped so an apostrophe in a comment cannot open a quote.
IFS= read -r -d '' AWK_MASK <<'AWK' || true
BEGIN { RS = "\001"; ORS = "" }
{
  s = $0; n = length(s); sq = 0; dq = 0; out = ""; prev = "\n"
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (sq) {
      if (c == "\047") { sq = 0; out = out c }
      else if (c == "$") out = out "\002"
      else if (c == "`") out = out "\003"
      else out = out c
      continue
    }
    if (dq) {
      if (c == "\\") { out = out c substr(s, i + 1, 1); i++ }
      else { if (c == "\"") dq = 0; out = out c }
      continue
    }
    if (c == "\\") { out = out c substr(s, i + 1, 1); i++; prev = "x"; continue }
    if (c == "\047") { sq = 1; out = out c; continue }
    if (c == "\"") { dq = 1; out = out c; continue }
    if (c == "#" && (prev == " " || prev == "\t" || prev == "\n" || prev == ";" || prev == "&" || prev == "|" || prev == "(")) {
      j = index(substr(s, i), "\n")
      if (j == 0) { out = out substr(s, i); i = n } else { out = out substr(s, i, j - 1); i = i + j - 2 }
      prev = "x"; continue
    }
    out = out c; prev = c
  }
  printf "%s", out
}
AWK

mask_sq() { printf '%s' "$1" | awk "$AWK_MASK"; }

unmask() { # echoes text with the masked $ / backtick restored
  local s="$1"
  s="${s//$'\002'/\$}"
  s="${s//$'\003'/\`}"
  printf '%s' "$s"
}

# Could this text be (part of) a git push? Used where recursion stops.
could_be_push() {
  local s
  s="${1//\\/}"; s="${s//\"/}"; s="${s//\'/}"
  gi_lc "$s"; s="$GI_LC"
  case "$s" in *push*|*send-pack*) return 0 ;; esac
  return 1
}

# --- push classification ------------------------------------------------------
check_dest() { # refspec-side value (already stripped of '+'), label
  local d="$1" label="$2" nm
  if gi_has_expansion "$d"; then
    block "unresolved shell expansion in push refspec" "$label '$d' still contains a variable, substitution or brace expansion, so its destination cannot be resolved (failing closed)"
  fi
  gi_norm_dest "$d"
  [ "$GI_DST_TAG" -eq 1 ] && return 0
  if nm="$(gi_dest_protected "$GI_DST")"; then
    block "push targets protected branch '$nm'" "$label resolved destination ref to '$nm' (normalised from '$d')"
  fi
  return 0
}

check_refspec() { # refspec, label
  local r="${1#+}" label="$2" dst src cur
  case "$r" in "^"*) return 0 ;; esac
  case "$r" in
    *:*)
      src="${r%%:*}"; dst="${r#*:}"
      if [ -z "$src" ] && [ -z "$dst" ]; then
        block "matching push" "refspec ':' pushes every matching branch, protected ones included"
      fi
      [ -z "$dst" ] && dst="$src"
      ;;
    *) dst="$r" ;;
  esac
  case "$r" in
    HEAD|@)
      cur="$(gi_cur_branch)"
      [ -n "$cur" ] && dst="$cur"
      [ -z "$cur" ] && return 0
      ;;
  esac
  check_dest "$dst" "$label"
}

check_push() {
  local -a args=() pos=() refspecs=()
  local x i n t name hasval body c rest
  local hard=0 bulk=0 plus=0 prune=0 tags=0 delete=0 has_repo=0 endopt=0
  for x in ${GI_REST[@]+"${GI_REST[@]}"}; do args+=("$x"); done
  n=${#args[@]}; i=0
  while [ "$i" -lt "$n" ]; do
    t="${args[$i]}"; i=$((i + 1))
    if [ "$endopt" -eq 1 ]; then pos+=("$t"); continue; fi
    case "$t" in
      --) endopt=1 ;;
      --*)
        name="${t#--}"; hasval=0
        case "$name" in *=*) hasval=1; name="${name%%=*}" ;; esac
        if gi_has_expansion "$name"; then
          block "unresolved shell expansion in push option" "option '$t' still contains a variable, substitution or brace expansion (failing closed)"
        fi
        gi_push_long_opt "$name"
        case "$GI_OPT" in
          force) hard=1 ;;
          lease) : ;;
          all) bulk=1 ;;
          prune) prune=1 ;;
          tags) tags=1 ;;
          delete) delete=1 ;;
          receive-pack)
            # Decision (#808): blocked. It swaps the program that applies the
            # ref updates (a local path runs it through the shell), so no
            # destination reasoning about the push holds any more; no
            # sanctioned flow uses it.
            block "push --receive-pack/--exec override" "the remote-side receive program is replaced, so the resulting ref updates cannot be resolved" ;;
          repo) has_repo=1; [ "$hasval" -eq 0 ] && i=$((i + 1)) ;;
          push-option|recurse) [ "$hasval" -eq 0 ] && i=$((i + 1)) ;;
        esac
        ;;
      -?*)
        body="${t#-}"
        if gi_has_expansion "$body"; then
          block "unresolved shell expansion in push option" "option '$t' still contains a variable, substitution or brace expansion (failing closed)"
        fi
        rest="$body"
        while [ -n "$rest" ]; do
          c="${rest:0:1}"; rest="${rest:1}"
          case "$c" in
            f) hard=1 ;;
            d) delete=1 ;;
            o) [ -z "$rest" ] && i=$((i + 1)); break ;;
          esac
        done
        ;;
      +*) plus=1; pos+=("$t") ;;
      *) pos+=("$t") ;;
    esac
  done

  # Positionals: <remote> <refspec>... (with --repo the remote is not positional).
  for x in ${pos[@]+"${pos[@]}"}; do
    if gi_has_expansion "$x"; then
      block "unresolved shell expansion in push argument" "argument '$x' still contains a variable, substitution or brace expansion (failing closed)"
    fi
  done
  if [ "$has_repo" -eq 1 ]; then
    for x in ${pos[@]+"${pos[@]}"}; do refspecs+=("$x"); done
  elif [ "${#pos[@]}" -ge 2 ]; then
    refspecs=("${pos[@]:1}")
  fi

  for x in ${refspecs[@]+"${refspecs[@]}"}; do check_refspec "$x" "refspec"; done

  # Refspecs supplied by -c remote.<name>.push=... apply whenever git needs them.
  local e
  for e in ${GI_CFG[@]+"${GI_CFG[@]}"}; do
    case "${e%%=*}" in
      remote.*.push) check_refspec "${e#*=}" "config refspec" ;;
      remote.*.receivepack)
        # same decision as --receive-pack: the program that applies the ref updates is replaced
        block "remote receive-program override through -c" "the remote-side receive program is replaced, so the resulting ref updates cannot be resolved" ;;
    esac
  done

  if [ "${#refspecs[@]}" -eq 0 ] && [ "$tags" -eq 0 ] && [ "$delete" -eq 0 ] && [ "$bulk" -eq 0 ]; then
    # Decision (#808): --prune with no explicit refspec is blocked — it deletes
    # remote branches absent locally, protected ones included. With explicit
    # refspecs it is scoped to their destinations, already checked above
    # (a wildcard destination that could match a protected name blocks).
    if [ "$prune" -eq 1 ]; then
      block "push --prune without an explicit refspec" "--prune removes remote branches with no local counterpart, protected ones included"
    fi
    resolve_implicit_push
  fi

  if [ "$bulk" -eq 1 ]; then
    block "bulk push (--all/--mirror)" "bulk push updates every remote ref, including protected branches, without naming one (--mirror additionally deletes remote refs absent locally)"
  fi
  if [ "$hard" -eq 1 ] || [ "$plus" -eq 1 ]; then
    block "hard force push" "segment carries a hard --force/-f flag or a '+' hard-force refspec (--force-with-lease is the only sanctioned force form)"
  fi
}

# `git push` with no refspec: what git pushes comes from push configuration and
# the current branch, resolved read-only in the invocation's repository. An
# unresolvable repository (not a repo, detached HEAD) is tolerated: the push
# itself cannot succeed there.
resolve_implicit_push() {
  local cur pd merge line
  cur="$(gi_cur_branch)"
  if gi_cfg_lookup push.default; then pd="$GI_VAL"; elif gi_config_get push.default; then pd="$GI_VAL"; else pd=""; fi
  gi_lc "$pd"; pd="$GI_LC"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    check_refspec "${line#* }" "configured push refspec"
  done < <(gi_git config --get-regexp '^remote\..*\.push$')

  case "$pd" in
    matching) block "matching push (push.default=matching)" "pushes every branch that exists on both sides, protected ones included" ;;
    upstream|tracking)
      if [ -n "$cur" ] && gi_config_get "branch.$cur.merge"; then
        merge="$GI_VAL"
        check_dest "$merge" "upstream of '$cur'"
      fi ;;
  esac
  if [ -n "$cur" ] && gi_is_protected_name "${cur##*/}"; then
    block "push targets protected branch '${cur##*/}'" "no refspec given and the current branch '$cur' is protected"
  fi
  return 0
}

# in-command write of alias or push configuration
check_config_write() {
  local -a args=()
  local x key readonly_flag=0 npos=0 keyseen="" add=0
  for x in ${GI_REST[@]+"${GI_REST[@]}"}; do args+=("$x"); done
  for x in ${args[@]+"${args[@]}"}; do
    case "$x" in
      --get|--get-all|--get-regexp|--get-urlmatch|-l|--list|--unset|--unset-all|--remove-section|--rename-section|--show-origin|--get-color|--get-colorbool)
        readonly_flag=1 ;;
      --add|--replace-all) add=1 ;;
      -*) ;;
      *)
        npos=$((npos + 1))
        if [ -z "$keyseen" ]; then
          gi_lc "$x"; key="$GI_LC"
          gi_key_is_push_risk "$key" && keyseen="$key"
        fi ;;
    esac
  done
  if [ "$readonly_flag" -eq 0 ] && [ -n "$keyseen" ] && { [ "$npos" -ge 2 ] || [ "$add" -eq 1 ]; }; then
    block "write of git alias / push configuration" "setting '$keyseen' can turn an innocuous command into a push or redirect where a push lands; agents never write alias or remote-push config"
  fi
  return 0
}

# External git subcommands (git-subtree and friends) can push internally, and
# their argument layout is not known here. Mirror the pre-#808 rule: every
# `push` argument starts a push-shaped tail that gets the same destination
# checks as `git push`; arguments with no `push` token stay allowed.
check_external_push() {
  local -a all=() tail=()
  local x i n lx
  for x in ${GI_REST[@]+"${GI_REST[@]}"}; do all+=("$x"); done
  n=${#all[@]}
  for ((i = 0; i < n; i++)); do
    gi_lc "${all[$i]}"; lx="$GI_LC"
    [ "$lx" = "push" ] || continue
    tail=()
    if [ "$((i + 1))" -lt "$n" ]; then tail=("${all[@]:$((i + 1))}"); fi
    GI_REST=(${tail[@]+"${tail[@]}"})
    check_push
  done
  return 0
}

# Builtins that run a user-supplied command line (submodule foreach, rebase
# --exec, bisect run): rescan it, so a nested push there is judged like a
# top-level one (the pre-#808 hook saw it because it split on `push` tokens).
check_exec_builtin() { # depth
  local depth="$1" i n x lx
  local -a all=()
  for x in ${GI_REST[@]+"${GI_REST[@]}"}; do all+=("$x"); done
  n=${#all[@]}
  for ((i = 0; i < n; i++)); do
    x="${all[$i]}"
    x="${x#--exec=}"
    case "$x" in -x?*) x="${x#-x}" ;; esac
    case "$x" in
      *[[:space:]]*) scan_script "$(unmask "$x")" $((depth + 1)) ;;
      *)
        gi_lc "${x##*/}"; lx="$GI_LC"
        # `git` and the dashed entry points (git-push, git-send-pack, ...) are on
        # PATH for exec children, so they start a command like bare `git` does
        if [ "$lx" = "git" ] || [[ "$lx" == git-* ]]; then
          scan_segment $((depth + 1)) "$x" "${all[@]:$((i + 1))}"
          return 0
        fi ;;
    esac
  done
  return 0
}

# Exec-capable option / config value class: git runs some option values, config
# values and environment values as shell command lines (remote-side program
# options, helper / editor / transport commands). Whitespace-bearing values of
# those are rescanned as scripts, so a nested push there is judged like a
# top-level one. -c values are rescanned whatever their key (the key set that
# runs commands is open-ended); option values only for the program options
# (matched on any prefix git accepts) and the short -u form.
scan_exec_values() { # depth first-cfg-index
  local depth="$1" from="$2" i n t name val hasval e x m pn
  local -a svr=(${GI_REST[@]+"${GI_REST[@]}"}) svo=(${GI_OPTS[@]+"${GI_OPTS[@]}"}) svc=(${GI_CFG[@]+"${GI_CFG[@]}"}) sva=(${SEG_ASSIGNS[@]+"${SEG_ASSIGNS[@]}"})
  local svs="$GI_SUB" sve="$GI_CFG_ENV_RISK" svt="$CUR_SEG_TEXT"
  local -a vals=()
  for ((i = from; i < ${#svc[@]}; i++)); do
    e="${svc[$i]}"; vals+=("${e#*=}")
  done
  if [ "$from" -eq 0 ]; then
    for x in ${sva[@]+"${sva[@]}"}; do
      case "${x%%=*}" in GIT_*|EDITOR|VISUAL|PAGER|SSH_ASKPASS) vals+=("${x#*=}") ;; esac
    done
  fi
  n=${#svr[@]}; i=0
  while [ "$i" -lt "$n" ]; do
    t="${svr[$i]}"; i=$((i + 1))
    case "$t" in
      --) break ;;
      --*)
        name="${t#--}"; hasval=0; val=""
        case "$name" in *=*) hasval=1; val="${name#*=}"; name="${name%%=*}" ;; esac
        [ -n "$name" ] || continue
        m=0
        for pn in upload-pack receive-pack exec; do
          case "$pn" in "$name"*) m=1 ;; esac
        done
        [ "$m" -eq 1 ] || continue
        if [ "$hasval" -eq 0 ]; then val="${svr[$i]:-}"; i=$((i + 1)); fi
        vals+=("$val") ;;
      -u?*) vals+=("${t#-u}") ;;
      -u) vals+=("${svr[$i]:-}"); i=$((i + 1)) ;;
    esac
  done
  for x in ${vals[@]+"${vals[@]}"}; do
    x="${x#!}"
    case "$x" in *[[:space:]]*|*'$('*|*'`'*|*$'\002'*|*$'\003'*) scan_script "$(unmask "$x")" $((depth + 1)) ;; esac
  done
  GI_REST=(${svr[@]+"${svr[@]}"}); GI_OPTS=(${svo[@]+"${svo[@]}"}); GI_CFG=(${svc[@]+"${svc[@]}"})
  SEG_ASSIGNS=(${sva[@]+"${sva[@]}"}); GI_SUB="$svs"; GI_CFG_ENV_RISK="$sve"; CUR_SEG_TEXT="$svt"
  return 0
}

# Resolve the git subcommand (expanding aliases) and classify.
gi_process() { # depth args...
  local depth="$1"; shift
  local hops=0 sub lsub val a x alias_key cfg_done=0
  local -a cur=("$@") rest=()
  gi_reset
  # GIT_DIR / GIT_WORK_TREE assignments select the repository like the options do
  for x in ${SEG_ASSIGNS[@]+"${SEG_ASSIGNS[@]}"}; do
    case "$x" in
      GIT_DIR=*) GI_OPTS+=("--git-dir=${x#*=}") ;;
      GIT_WORK_TREE=*) GI_OPTS+=("--work-tree=${x#*=}") ;;
      GIT_CONFIG_KEY_*=*|GIT_CONFIG_PARAMETERS=*|GIT_CONFIG_COUNT=*)
        gi_lc "${x#*=}"; a="$GI_LC"
        case "$a" in *alias.*|*push.default*|*.push*|*receivepack*|*uploadpack*) block "alias / push configuration through the environment" "$x injects git configuration that can turn a command into a push (failing closed)" ;; esac ;;
    esac
  done
  while :; do
    gi_walk ${cur[@]+"${cur[@]}"}
    if [ "$GI_CFG_ENV_RISK" -eq 1 ]; then
      block "alias / push configuration through --config-env" "the value comes from the environment and cannot be resolved (failing closed)"
    fi
    sub="$GI_SUB"
    [ -n "$sub" ] || return 0
    if gi_has_expansion "$sub"; then
      block "unresolved git subcommand" "git subcommand '$sub' still contains a variable, substitution or brace expansion (failing closed)"
    fi
    gi_lc "$sub"; lsub="$GI_LC"
    scan_exec_values "$depth" "$cfg_done"; cfg_done=${#GI_CFG[@]}
    case "$lsub" in
      push) check_push; return 0 ;;
      send-pack|http-push)
        block "push plumbing command (git $lsub)" "git $lsub updates remote refs directly and bypasses the push destination checks; it is blocked categorically" ;;
      config) check_config_write; return 0 ;;
    esac
    case "$lsub" in submodule|rebase|bisect) check_exec_builtin "$depth"; return 0 ;; esac
    gi_is_builtin_nonpush "$lsub" && return 0

    # alias: in-invocation -c first, then persistent config
    alias_key="alias.$lsub"
    val=""
    if gi_cfg_lookup "$alias_key"; then val="$GI_VAL"
    elif gi_config_get "$alias_key"; then val="$GI_VAL"
    else check_exec_builtin "$depth"; check_external_push; return 0
    fi
    hops=$((hops + 1))
    rest=()
    for x in ${GI_REST[@]+"${GI_REST[@]}"}; do rest+=("$x"); done
    if [ "$hops" -gt "$MAX_DEPTH" ]; then
      block "git alias expansion too deep" "alias chain '$sub' exceeds the recursion bound (failing closed)"
    fi
    case "$val" in
      '!'*)
        # shell alias: the body is re-lexed and rescanned with the arguments appended
        a="$(unmask "${val#!}")"
        for x in ${rest[@]+"${rest[@]}"}; do a+=" $(printf '%q' "$x")"; done
        scan_script "$a" $((depth + 1))
        return 0 ;;
    esac
    mask_and_lex_alias "$val"
    cur=()
    for x in ${TOKS[@]+"${TOKS[@]}"} ${rest[@]+"${rest[@]}"}; do cur+=("$x"); done
    # keep -c/-C collected so far: gi_walk appends, so only reset the sub/rest
  done
}

mask_and_lex_alias() { # alias value → TOKS (first segment only; aliases are one command)
  local v
  v="$(mask_sq "$1")"
  lex "$v"
  local -a segs=()
  IFS="$RS" read -r -d '' -a segs <<< "$LEX_OUT" || true
  split_tokens "${segs[0]:-}"
  local i
  # (index loop, not ${!TOKS[@]+...}: bash 4.4+ reads that as an indirect expansion)
  for ((i = 0; i < ${#TOKS[@]}; i++)); do TOKS[i]="$(unmask "${TOKS[$i]}")"; done
}

# --- segment scan --------------------------------------------------------------
SEG_ASSIGNS=()

# Skip the options of a wrapper command; echoes how many tokens to skip.
wrapper_skip() { # wrapper-name, tokens after it...
  local w="$1"; shift
  local k=0 t
  for t in "$@"; do
    case "$t" in
      --) k=$((k + 1)); break ;;
      -*)
        k=$((k + 1))
        case "$w:$t" in
          env:-u|env:-C|env:-S|nice:-n|sudo:-u|sudo:-g|sudo:-h|sudo:-p|sudo:-C|sudo:-D|sudo:-R|timeout:-s|timeout:-k|xargs:-I|xargs:-n|xargs:-P|xargs:-L|xargs:-s|xargs:-d|xargs:-E|setsid:-x|command:-x)
            k=$((k + 1)) ;;
        esac ;;
      *) break ;;
    esac
  done
  printf '%d' "$k"
}

# Text a shell could later read from stdin, collected from literal producers in
# the current script (echo/printf args, here-string words) regardless of order, so
# `echo X | bash`, `bash <<< X` and `bash <(echo X)` are all judged the same way.
# It is rescanned as a script only when the script also has a shell reading stdin
# (STDIN_SHELL=1). A payload that is not statically known (a file, another
# command's output) stays in the documented residual gaps.
PAYLOAD=""
STDIN_SHELL=0

payload_add() { # text — add literal producer text, with printf/echo \n escapes honoured
  local txt="$1"
  if [ "${#txt}" -lt 20000 ]; then
    txt="${txt//\\n/$'\n'}"; txt="${txt//\\t/ }"; txt="${txt//\\r/ }"
  fi
  PAYLOAD+="$txt"$'\n'
}

# Commands whose arguments are data, never executed: a protected-push shape in
# their words is prose (a search pattern, a message, a path) and stays allowed.
# Every other command word is treated as a possible command runner: its remaining
# tokens are scanned for an embedded command (see scan_segment).
is_data_command() { # lowercased basename
  case "$1" in
    echo|printf|cat|gh|rg|grep|egrep|fgrep|ag|ack|head|tail|wc|sort|uniq|tee|ls|diff|cmp|less|more|tr|cut|jq|yq|column|true|false|:|test|'['|'[['|read|cd|pwd|mkdir|rmdir|touch|rm|cp|mv|ln|chmod|chown|stat|file|basename|dirname|realpath|readlink|date|sleep|which|type|whereis|open|pbcopy|pbpaste|curl|wget|mktemp|tar|unzip|zip|gzip|gunzip|shasum|md5|md5sum|sha256sum|base64|printenv|export|unset|alias) return 0 ;;
  esac
  return 1
}

is_shell_name() { # lowercased basename
  case "$1" in bash|sh|zsh|dash|ksh|ash) return 0 ;; esac
  return 1
}

# Unknown command word (caffeinate, stdbuf, arch, script, watch, flock, parallel,
# ssh, pnpm exec, ...): any later token that starts a command is scanned like a
# command of its own, and a token with whitespace that mentions git is rescanned
# as a script (`ssh host 'git push ...'`, `watch 'git push ...'`).
scan_runner_tokens() { # depth tokens... (command word included)
  local depth="$1"; shift
  local -a tk=("$@")
  local n=${#tk[@]} j x nb lx hasexp=0 haspush=0
  for ((j = 0; j < n; j++)); do
    x="${tk[$j]}"
    # a huge argument is not rescanned (per-character lexing is the cost): it
    # fails closed when it names both git and push, and is otherwise skipped
    if [ "${#x}" -ge 4000 ]; then
      # two linear scans: a single `*git*push*` glob is quadratic on long input
      nb="$(printf '%s' "$x" | tr -d "\\\\\"'")"
      case "$nb" in
        *[pP][uU][sS][hH]*)
          case "$nb" in
            *[gG][iI][tT]*) block "oversized command-runner argument that names git push" "a ${#x}-byte argument of an unlisted command runner mentions git and push; too large to analyse (failing closed)" "${tk[0]}" ;;
          esac ;;
      esac
      continue
    fi
    if gi_has_expansion "$x"; then hasexp=1; fi
    gi_lc "$x"; case "$GI_LC" in *push*) haspush=1 ;; esac
    case "$x" in
      *[[:space:]]*)
        scan_script "$(unmask "$x")" $((depth + 1))
        # `NAME=cmd args` / `--exec=cmd args`: the value is a command line too
        case "$x" in [-A-Za-z_]*=*) scan_script "$(unmask "${x#*=}")" $((depth + 1)) ;; esac
        CUR_SEG_TEXT="${tk[*]-}" ;;
      *)
        nb="${x##*/}"; gi_lc "$nb"; lx="$GI_LC"
        if [ "$lx" = "git" ] || [[ "$lx" == git-* ]] || is_shell_name "$lx" || [ "$lx" = "eval" ]; then
          scan_segment $((depth + 1)) "$x" ${tk[@]+"${tk[@]:$((j + 1))}"}
          return 0
        fi ;;
    esac
  done
  if [ "$hasexp" -eq 1 ] && [ "$haspush" -eq 1 ]; then
    block "unresolved command word in a push" "an unlisted command runner has an argument naming push and another that still contains shell expansion, so the command it runs cannot be resolved (failing closed)"
  fi
  return 0
}

scan_segment() { # depth tokens...
  local depth="$1"; shift
  local -a raw=("$@") t=()
  local x i n skip w base lbase body k nxt
  CUR_SEG_TEXT="${raw[*]-}"
  [ "${#raw[@]}" -gt 0 ] || return 0

  for x in "${raw[@]}"; do
    case "$x" in *'$('*|*'`'*) scan_subst "$x" "$depth" ;; esac
  done

  # a here-string word is literal stdin text for whatever reads it
  n=${#raw[@]}
  for ((i = 0; i < n; i++)); do
    x="${raw[$i]}"
    case "$x" in
      '<<<') payload_add "$(unmask "${raw[$((i + 1))]:-}")" ;;
      '<<<'?*) payload_add "$(unmask "${x#<<<}")" ;;
    esac
  done

  # drop redirections (`> file`, `2>&1`, `< in`, `<<< word`, `<< EOF`)
  i=0
  while [ "$i" -lt "$n" ]; do
    x="${raw[$i]}"; i=$((i + 1))
    case "$x" in '<<<'|'<<'|'<<-') i=$((i + 1)); continue ;; esac
    if [[ "$x" =~ $REDIR_RE ]]; then
      [ -z "${BASH_REMATCH[2]}" ] && i=$((i + 1))
      continue
    fi
    t+=("$x")
  done
  n=${#t[@]}
  [ "$n" -gt 0 ] || return 0

  SEG_ASSIGNS=()
  i=0
  while [ "$i" -lt "$n" ]; do
    w="${t[$i]}"
    if [[ "$w" =~ $ASSIGN_RE ]]; then SEG_ASSIGNS+=("$w"); i=$((i + 1)); continue; fi
    base="${w##*/}"
    gi_lc "$base"; lbase="$GI_LC"
    case "$lbase" in
      '{'|'}'|'!'|if|then|else|elif|do|while|until|time|coproc|exec|nohup|builtin|command|setsid)
        i=$((i + 1))
        skip="$(wrapper_skip "$lbase" ${t[@]+"${t[@]:$i}"})"; i=$((i + skip))
        continue ;;
      nice|sudo|timeout|xargs)
        i=$((i + 1))
        skip="$(wrapper_skip "$lbase" ${t[@]+"${t[@]:$i}"})"; i=$((i + skip))
        [ "$lbase" = "timeout" ] && i=$((i + 1))
        continue ;;
      env)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          x="${t[$i]}"
          if [[ "$x" =~ $ASSIGN_RE ]]; then SEG_ASSIGNS+=("$x"); i=$((i + 1))
          else
            skip="$(wrapper_skip env "${t[@]:$i}")"
            [ "$skip" -gt 0 ] && { i=$((i + skip)); continue; }
            break
          fi
        done
        continue ;;
    esac
    break
  done
  [ "$i" -lt "$n" ] || return 0
  w="${t[$i]}"
  base="${w##*/}"
  gi_lc "$base"; lbase="$GI_LC"
  local -a after=()
  if [ "$((i + 1))" -lt "$n" ]; then after=("${t[@]:$((i + 1))}"); fi

  # unresolved command word: block only when the segment could be a push
  if gi_has_expansion "$w" || case "$w" in *'*'*|*'?'*|*'['*) true ;; *) false ;; esac; then
    gi_lc "$w"
    case "$GI_LC" in *push*|*send-pack*) block "unresolved command word in a push" "command word '$w' still contains shell expansion and the segment mentions push (failing closed)" ;; esac
    for x in ${after[@]+"${after[@]}"}; do
      if could_be_push "$x"; then
        block "unresolved command word in a push" "command word '$w' still contains shell expansion and an argument names push (failing closed)"
      fi
    done
    return 0
  fi

  case "$lbase" in
    git) gi_process "$depth" ${after[@]+"${after[@]}"} ;;
    git-push)
      gi_reset
      for x in ${after[@]+"${after[@]}"}; do GI_REST+=("$x"); done
      check_push ;;
    git-send-pack|git-http-push)
      block "push plumbing command ($lbase)" "$lbase updates remote refs directly and bypasses the push destination checks; it is blocked categorically" ;;
    git-*)
      gi_reset
      for x in ${after[@]+"${after[@]}"}; do GI_REST+=("$x"); done
      check_exec_builtin "$depth"; check_external_push ;;
    bash|sh|zsh|dash|ksh|ash)
      k=0; body=""; local sflag=0 file=""
      while [ "$k" -lt "${#after[@]}" ]; do
        x="${after[$k]}"; k=$((k + 1))
        case "$x" in
          --) file="${after[$k]:-}"; break ;;
          -o|+o|-O|+O|--rcfile|--init-file) k=$((k + 1)) ;;
          --*) ;;
          -*c*) body="${after[$k]:-}"; break ;;
          -*s*) sflag=1 ;;
          -*|+*) ;;
          *) file="$x"; break ;;
        esac
      done
      [ -n "$body" ] && scan_script "$(unmask "$body")" $((depth + 1))
      # no script file (or -s, or a stdin path): the shell reads its script from
      # stdin, so the literal text feeding it is rescanned when the script ends
      if [ -z "$body" ]; then
        case "$file" in ''|-|/dev/stdin|/dev/fd/*|/proc/self/fd/*) STDIN_SHELL=1 ;; esac
        [ "$sflag" -eq 1 ] && STDIN_SHELL=1
      fi
      ;;
    source|.)
      case "${after[0]:-}" in ''|/dev/*|/proc/*) STDIN_SHELL=1 ;; esac
      ;;
    eval)
      body=""
      for x in ${after[@]+"${after[@]}"}; do body+="$x "; done
      [ -n "$body" ] && scan_script "$(unmask "$body")" $((depth + 1))
      ;;
    find)
      k=0
      while [ "$k" -lt "${#after[@]}" ]; do
        case "${after[$k]}" in
          -exec|-execdir|-ok|-okdir)
            nxt=("${after[@]:$((k + 1))}")
            scan_segment "$depth" ${nxt[@]+"${nxt[@]}"}
            CUR_SEG_TEXT="${raw[*]-}"
            break ;;
        esac
        k=$((k + 1))
      done ;;
    echo)
      body=""
      for x in ${after[@]+"${after[@]}"}; do
        case "$x" in -n|-e|-E|-ne|-en|-nE|-En|-eE|-Ee) continue ;; esac
        body+="$x "
      done
      payload_add "$(unmask "$body")" ;;
    printf)
      local -a pa=()
      local rest acc ai=0 guard=0 pn pre1 arg
      for x in ${after[@]+"${after[@]}"}; do pa+=("$x"); done
      pn=$((${#pa[@]} - 1))
      if [ "$pn" -ge 0 ] && [ "${pa[0]}" != "-v" ]; then
        rest="${pa[0]}"; acc=""
        while [ "$guard" -lt 64 ]; do
          guard=$((guard + 1))
          case "$rest" in *%[sbq]*) ;; *) break ;; esac
          pre1="${rest%%%[sbq]*}"
          rest="${rest#*%[sbq]}"
          arg=""; [ "$pn" -ge 1 ] && arg="${pa[$((1 + ai % pn))]}"
          ai=$((ai + 1))
          acc+="$pre1$arg"
        done
        payload_add "$(unmask "$acc$rest")"
        for x in "${pa[@]:1}"; do payload_add "$(unmask "$x")"; done
      fi ;;
    *)
      is_data_command "$lbase" || scan_runner_tokens "$depth" "${t[@]:$i}" ;;
  esac
  return 0
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

# strip_heredocs drops heredoc bodies as prose, but the shell expands $(...) and
# backticks in a body whose delimiter is unquoted: rescan those substitutions.
# Quoted-delimiter bodies stay literal and unscanned; bodies feeding a shell are
# kept by strip_heredocs and scanned as script text.
# A heredoc body is prose (inert) unless the line hands it to something that can
# execute stdin: a shell, `source`/`eval`, a remote/container runner, an
# interpreter, or a pipeline whose downstream names one (`cat <<EOF | bash`).
# The delimiter quoting is irrelevant to that: the consumer executes the text
# either way. Words are matched anywhere on the line (conservative: a title that
# says "bash" keeps the body scanned, which only costs a scan).
HD_RUNNER_RE='(^|[[:space:];&|(/])(bash|sh|zsh|dash|ksh|ash|source|eval|ssh|su|docker|podman|kubectl|nsenter|chroot|xargs|parallel|expect|python[0-9.]*|perl|ruby|node|php)([[:space:]]|$)'
hd_feeds_runner() { # line
  local line="$1" pre post g=0
  local mre='^(.*[[:space:]])(--title|--message|--subject|--body|-m|-t|-b)[= ]+("[^"]*"|'"'"'[^'"'"']*'"'"')(.*)$'
  pre="${line%%<<*}"
  # a quoted message/title value is prose: `--title "fix bash eval"` is not a shell
  while [ "$g" -lt 20 ] && [[ "$pre" =~ $mre ]]; do
    pre="${BASH_REMATCH[1]}${BASH_REMATCH[2]} ${BASH_REMATCH[4]}"; g=$((g + 1))
  done
  if [[ "$pre" =~ $HD_RUNNER_RE ]]; then return 0; fi
  post="${line#*<<}"
  case "$post" in
    *'|'*) post="${post#*|}"; if [[ "$post" =~ $HD_RUNNER_RE ]]; then return 0; fi ;;
  esac
  return 1
}

# Like lib strip_heredocs (drop prose bodies) but with the runner predicate above.
strip_heredocs_bpp() { # script
  local line delim="" dash=0 out="" t hd_dash hd_delim
  local re='(^|[^<])<<(-?)[[:space:]]*\\?["'"'"']?([A-Za-z_][A-Za-z0-9_]*)'
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$delim" ]; then
      t="$line"
      if [ "$dash" = 1 ]; then t="${t#"${t%%[!	]*}"}"; fi
      [ "$t" = "$delim" ] && delim=""
      continue
    fi
    out+="$line"$'\n'
    if [[ "$line" =~ $re ]]; then
      hd_dash="${BASH_REMATCH[2]:-}"; hd_delim="${BASH_REMATCH[3]:-}"
      if ! hd_feeds_runner "$line"; then
        delim="$hd_delim"
        if [ -n "$hd_dash" ]; then dash=1; else dash=0; fi
      fi
    fi
  done <<< "$1"
  printf '%s' "$out"
}

scan_heredoc_bodies() { # script depth
  local line delim="" dash=0 t hd_dash hd_delim hd_q body="" collect=0
  local re='(^|[^<])<<(-?)[[:space:]]*(\\?["'"'"']?)([A-Za-z_][A-Za-z0-9_]*)'
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$delim" ]; then
      t="$line"
      if [ "$dash" = 1 ]; then t="${t#"${t%%[!	]*}"}"; fi
      if [ "$t" = "$delim" ]; then
        delim=""
        if [ "$collect" -eq 1 ] && [ -n "$body" ]; then scan_subst "$body" "$2"; fi
        body=""; collect=0
      elif [ "$collect" -eq 1 ]; then
        body+="$line"$'\n'
      fi
      continue
    fi
    if [[ "$line" =~ $re ]]; then
      hd_dash="${BASH_REMATCH[2]:-}"; hd_q="${BASH_REMATCH[3]:-}"; hd_delim="${BASH_REMATCH[4]:-}"
      if ! hd_feeds_runner "$line"; then
        delim="$hd_delim"
        if [ -n "$hd_dash" ]; then dash=1; else dash=0; fi
        if [ -z "$hd_q" ]; then collect=1; else collect=0; fi
        body=""
      fi
    fi
  done <<< "$1"
  [ "$collect" -eq 1 ] && [ -n "$body" ] && scan_subst "$body" "$2"
  return 0
}

scan_script() { # script depth
  local script="$1" depth="$2" seg stripped lx
  local -a segs=()
  if [ "$depth" -gt "$MAX_DEPTH" ]; then
    if could_be_push "$script"; then
      block "nested shell construct too deep" "substitution / eval nesting exceeds the recursion bound and the remaining text could be a git push (failing closed)" "$script"
    fi
    return 0
  fi
  local saved_payload="$PAYLOAD" saved_stdin="$STDIN_SHELL"
  PAYLOAD=""; STDIN_SHELL=0
  case "$script" in *'<<'*) scan_heredoc_bodies "$script" "$depth" ;; esac
  stripped="$(strip_heredocs_bpp "$script")" || stripped=""
  if [ -z "$stripped" ] && [ -n "$script" ]; then
    if could_be_push "$script"; then
      block "heredoc stripping failed on a command that could be a push" "failing closed" "$script"
    fi
  fi
  script="$(mask_sq "$stripped")"
  lex "$script"
  IFS="$RS" read -r -d '' -a segs <<< "$LEX_OUT" || true
  if [ "${#segs[@]}" -gt "$MAX_SEGMENTS" ]; then
    block "command has too many segments to analyse" "${#segs[@]} segments exceed the bound of $MAX_SEGMENTS and the command names git (failing closed)" "${script:0:200}"
  fi
  for seg in ${segs[@]+"${segs[@]}"}; do
    [ -n "$seg" ] || continue
    if [ "$SECONDS" -ge "$DEADLINE" ]; then
      block "analysis time budget exceeded" "the command could not be analysed within ${ANALYSIS_BUDGET_S}s (failing closed)" "${script:0:200}"
    fi
    split_tokens "$seg"
    scan_segment "$depth" ${TOKS[@]+"${TOKS[@]}"}
  done
  if [ "$STDIN_SHELL" -eq 1 ] && [ -n "$PAYLOAD" ]; then
    seg="$PAYLOAD"
    PAYLOAD="$saved_payload"; STDIN_SHELL="$saved_stdin"
    if [ "${#seg}" -ge 20000 ]; then
      lx="$(printf '%s' "$seg" | tr -d "\\\\\"'")"
      case "$lx" in
        *[pP][uU][sS][hH]*)
          case "$lx" in
            *[gG][iI][tT]*) block "oversized text piped into a shell names git push" "${#seg} bytes of literal text feed a shell reading stdin and mention git and push; too large to analyse (failing closed)" "${script:0:200}" ;;
          esac ;;
      esac
    else
      scan_script "$seg" $((depth + 1))
    fi
    PAYLOAD="$saved_payload"; STDIN_SHELL="$saved_stdin"
    return 0
  fi
  # a stdin-reading shell inside a nested script (`ssh h "bash -s"`) reads the
  # caller's stdin, so the flag propagates up; the payload does not
  PAYLOAD="$saved_payload"; STDIN_SHELL=$((saved_stdin | STDIN_SHELL))
  return 0
}

# --- layer 1: the pre-#808 detection, kept as an independent floor ------------
# The detection that shipped before #808, carried over unchanged in what it
# blocks (it is deliberately broad: any `git ... push` word sequence anywhere in
# a segment, commit/PR message payloads stripped first). The lexer / resolver
# below (layer 2) can only add blocks on top of it; a command is allowed only
# when both layers allow it. Only the per-segment trimming is done in pure bash
# instead of a sed fork per segment, which does not change the result.
legacy_strip_message_payload() {
  local s="$1" sq out pat prev_len flag_pair
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

legacy_is_protected_name() {
  local name="$1" b
  for b in main master develop staging; do
    [ "$name" = "$b" ] && return 0
  done
  return 1
}

legacy_layer1() { # command
  case "$1" in
    *git*push*) ;;
    *) return 0 ;;
  esac
  local scan_str seg raw raw_tokens push_idx i args hard_force plus_refspec bulk_refspec
  local tok body protected_name ref dst
  local -a push_segments=() tokens=() positionals=()
  scan_str="$(legacy_strip_message_payload "$1")"
  while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"
    seg="${seg%"${seg##*[![:space:]]}"}"
    [ -z "$seg" ] && continue
    case "$seg" in
      *git*push*) push_segments+=("$seg") ;;
    esac
  done < <(printf '%s\n' "$scan_str" | tr ';&|' '\n\n\n')
  [ "${#push_segments[@]}" -eq 0 ] && return 0

  for seg in "${push_segments[@]}"; do
    read -ra raw_tokens <<< "$seg"
    tokens=()
    for raw in ${raw_tokens[@]+"${raw_tokens[@]}"}; do
      raw="${raw//\"/}"
      raw="${raw//\'/}"
      raw="${raw#\\}"
      tokens+=("$raw")
    done
    [ "${#tokens[@]}" -eq 0 ] && continue

    push_idx=-1
    for i in "${!tokens[@]}"; do
      if [ "${tokens[$i]}" = "push" ]; then
        push_idx="$i"
        break
      fi
    done
    [ "$push_idx" -lt 0 ] && continue

    args=()
    if [ "$((push_idx + 1))" -lt "${#tokens[@]}" ]; then
      args=("${tokens[@]:$((push_idx + 1))}")
    fi

    hard_force=0; plus_refspec=0; bulk_refspec=0
    positionals=()

    for tok in ${args[@]+"${args[@]}"}; do
      case "$tok" in
        --force-with-lease*|--force-if-includes*) : ;;
        --force|--force=*) hard_force=1 ;;
        --all|--mirror) bulk_refspec=1 ;;
        +*) plus_refspec=1; positionals+=("$tok") ;;
        --*) : ;;
        -*)
          body="${tok#-}"
          if [[ "$body" =~ ^[a-zA-Z]+$ ]] && [[ "$body" == *f* ]]; then
            hard_force=1
          fi
          ;;
        *) positionals+=("$tok") ;;
      esac
    done

    protected_name=""
    if [ "${#positionals[@]}" -ge 2 ]; then
      for ref in "${positionals[@]:1}"; do
        dst="$ref"
        dst="${dst#+}"
        case "$dst" in
          *:*) dst="${dst#*:}" ;;
        esac
        dst="${dst#refs/heads/}"
        if legacy_is_protected_name "$dst"; then
          protected_name="$dst"
          break
        fi
      done
    fi

    if [ -n "$protected_name" ]; then
      block "push targets protected branch '$protected_name'" "segment resolved destination ref to '$protected_name'" "$seg"
    fi
    if [ "$bulk_refspec" -eq 1 ]; then
      block "bulk push (--all/--mirror)" "bulk push updates every remote ref, including protected branches, without naming one (--mirror additionally deletes remote refs absent locally)" "$seg"
    fi
    if [ "$hard_force" -eq 1 ] || [ "$plus_refspec" -eq 1 ]; then
      block "hard force push" "segment carries a hard --force/-f flag or a '+' hard-force refspec (--force-with-lease is the only sanctioned force form)" "$seg"
    fi
  done
  return 0
}

legacy_layer1 "$ORIG_COMMAND_STR"
scan_script "$command_str" 0
exit 0
