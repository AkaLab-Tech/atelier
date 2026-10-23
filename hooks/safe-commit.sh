#!/usr/bin/env bash
#
# atelier — PreToolUse hook on Bash. Runs the push gate (lint → typecheck
# → tests) before every `git commit` and blocks the commit when any of
# the three is red.
#
# Layered defence (PLAN.md §3 "Defense-in-depth", §6 push gate):
#   - Operators reach the push gate two ways:
#       1. Deliberately, via the `atelier:safe-commit` skill —
#          invoked by `pr-author` agent / `/atelier:finish-task` slash command.
#       2. Reflexively, when an agent just runs `git commit` without
#          first invoking the skill.
#   - This hook is the runtime safety net for case (2). It re-runs the
#     gate even when the skill already ran a moment ago — the cost is
#     duplicated work in the green path, but the alternative is a
#     skip-marker scheme that would be easy to spoof.
#
# Performance / timeout:
#   Lint + typecheck + tests can take minutes in real projects. Claude
#   Code's default hook timeout is 60s; this hook's hooks.json entry
#   bumps it to 600 s (10 minutes) to fit medium-sized projects.
#   For very long suites, the operator has three escape hatches:
#     - Override the timeout in the operator's own settings.local.json.
#     - Export `ATELIER_SKIP_SAFE_COMMIT=1` for a single shell session
#       (e.g. when the operator has just run the gate manually and wants
#       to commit a docs-only follow-up without re-running it).
#     - Use `git commit --no-verify` — already covered by the global
#       no-verify guardrail in operator-rules.md; that requires explicit
#       operator confirmation.
#
# Test scope (#399):
#   The agent chain commits two or three times per PR (implementer WIP,
#   pr-author, review-fix), and the full suite also runs in the deliberate
#   gate (`safe-commit` skill, run by pr-author before the push and by
#   tester) and in CI — so this reflexive net alone charges a project
#   several full suites per PR. A project may scope the `test` step of
#   THIS hook via `.atelier.json`:
#       "safeCommit": { "testScope": "full" | "changed" }
#   "full" (default, absent key, unknown value) runs `<pm> run test` as
#   before. "changed" runs `<pm> run test:changed` when package.json
#   defines that script (e.g. `vitest run --changed`, `jest --onlyChanged`)
#   and falls back to `test` — logged — when it does not. `lint` and
#   `typecheck` are never scoped. The push precondition in PLAN.md §6
#   is unchanged: the full suite still gates the push and the PR.
#
# Contract per Claude Code hooks reference (PreToolUse):
#   stdin  — JSON: { tool_name, tool_input: { command } }
#   exit 0 — allow the commit
#   exit 2 — block (stderr goes to Claude's context with the explanation)

# shellcheck disable=SC1003,SC2016 # the #504 lexer matches literal `\`, `$(` and backtick
set -uo pipefail

# shellcheck source=lib/log-decision.sh
source "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by Claude Code}/hooks/lib/log-decision.sh"

HOOK_NAME="safe-commit"

# Escape hatch — operator-only, out-of-band affordance. This checks the
# hook's *environment* (a var the operator exported before invoking
# Claude Code, or set for a single shell session — see the header
# comment). It is NOT a substitute for the in-command bypass-signature
# refusal below: an inline `ATELIER_SKIP_SAFE_COMMIT=1 git commit …` never
# reaches this check (the hook runs as a separate process and receives
# the command as JSON on stdin — the Bash-tool shell's env does not
# persist into the hook), so an agent cannot smuggle the flag through
# here. Logged so a post-mortem can show every skip event.
if [ "${ATELIER_SKIP_SAFE_COMMIT:-0}" = "1" ]; then
  log_decision "$HOOK_NAME" "?" "" "allow" "skipped via ATELIER_SKIP_SAFE_COMMIT=1"
  exit 0
fi

# Read the payload.
input="$(cat 2>/dev/null || true)"

if ! command -v jq >/dev/null 2>&1; then
  log_decision "$HOOK_NAME" "?" "" "allow" "jq missing — hook degraded to allow"
  exit 0
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"

# Only inspect Bash.
if [ "$tool_name" != "Bash" ]; then
  exit 0
fi
if [ -z "$command_str" ]; then
  exit 0
fi

# #504 — decide whether this command REALLY invokes `git … commit`, and
# which tree it commits to.
#
# History: the matcher used to be a glob over the whole command string
# (`*"git -C "*"commit"*` and friends), which fired on any text that merely
# contained those words — a `--jq '.commit_id'` filter, a heredoc, an
# `echo "git commit"` — and then guessed the target tree with regexes that
# silently fell back to `$PWD` whenever the path was unexpanded (`"$W"`,
# `~/wt`, `$(pwd)/wt`) or missing. The gate then validated the wrong tree and
# a red branch could be committed. Both halves are replaced:
#
#   1. A small pure-bash (3.2-compatible) lexer, `lx_*`, splits the command
#      into segments (`;` `&&` `||` `|` `&` newline, `(` `)`, `$(` and
#      backticks), honouring quotes and backslashes, dropping heredoc bodies,
#      and emitting dequoted words with an "expansion" flag (unquoted or
#      double-quoted `$`, a backtick, or a leading `~`). `bash|sh|zsh -c`
#      payloads and `eval` strings are lexed again, up to a small depth.
#   2. A segment is a commit when it has a word `git` (or `…/git`) and the
#      first non-option word after it is exactly `commit`; the git global
#      options that take an argument (-C, -c, --git-dir, --work-tree,
#      --namespace, --config-env, plus =value forms) are consumed so they can
#      sit in between. `git` need not be first (`FOO=1 git commit`, `env`,
#      `xargs`, `nohup`). Quoted text, heredoc bodies and `--jq` arguments
#      are single words / dropped, so they never match.
#   3. When the lexer is unsure (unbalanced quote, unterminated heredoc or
#      `$(`, nesting too deep) the old glob (`legacy_matches`) decides, so a
#      real commit is never skipped — running the gate needlessly is accepted.
#
# The target tree is resolved from the matched segment and FAILS CLOSED: a
# value carrying an expansion, or a literal path that is not a directory, is
# "unresolved" and the commit is refused (see the `target-unresolved` block
# below) instead of validating `$PWD`. Commits in one command that resolve to
# different trees are refused the same way. A plain `git commit` (no -C, no
# `cd`) still targets `$PWD`.
legacy_matches() {
  case "$command_str" in
    *"git commit "*|*"git commit"|*"git commit;"*|*"git commit&"*) return 0 ;;
    *"git -C "*"commit "*|*"git -C "*"commit"|*"git -C "*"commit;"*|*"git -C "*"commit&"*) return 0 ;;
    *"--git-dir"*"commit "*|*"--git-dir"*"commit"|*"--git-dir"*"commit;"*|*"--git-dir"*"commit&"*) return 0 ;;
    *"--work-tree"*"commit "*|*"--work-tree"*"commit"|*"--work-tree"*"commit;"*|*"--work-tree"*"commit&"*) return 0 ;;
  esac
  return 1
}

US=$'\001'
TAB=$'\t'
SQ=$'\047'
LX_S=""
LX_I=0
LX_FAIL=0
LX_DEPTH=0
LX_OUT=()
LX_HD=()

# lx_word_end / lx_seg_end act on the calling lx_body frame's locals
# (w wf winw seg) through bash's dynamic scoping.
# shellcheck disable=SC2154
lx_word_end() {
  if [ "$winw" = 1 ]; then
    if [ -n "$seg" ]; then seg="$seg$US$wf$w"; else seg="$wf$w"; fi
  fi
  w=""
  wf=0
  winw=0
}

lx_seg_end() {
  lx_word_end
  if [ -n "$seg" ]; then LX_OUT[${#LX_OUT[@]}]="S$seg"; fi
  seg=""
}

# Substitution `$( … )` / `` ` … ` ``: its body becomes its own segments
# (bracketed by "(" ")" markers); the raw source text is kept in the word so
# an unresolved value can be shown as written.
lx_subst() {
  local kind="$1" start="$LX_I"
  LX_OUT[${#LX_OUT[@]}]="("
  if [ "$kind" = paren ]; then
    LX_I=$((LX_I + 2))
    lx_body paren
  else
    LX_I=$((LX_I + 1))
    lx_body btick
  fi
  LX_OUT[${#LX_OUT[@]}]=")"
  w="$w${LX_S:start:LX_I-start}"
  wf=1
  winw=1
}

# Consume the bodies of the heredocs registered on the line just finished.
lx_heredocs() {
  local n=${#LX_HD[@]} k spec strip quoted delim line rest cmp found
  for ((k = 0; k < n; k++)); do
    spec="${LX_HD[k]}"
    strip="${spec%%|*}"
    spec="${spec#*|}"
    quoted="${spec%%|*}"
    delim="${spec#*|}"
    found=0
    while [ "$LX_I" -lt "${#LX_S}" ]; do
      rest="${LX_S:LX_I}"
      case "$rest" in
        *$'\n'*)
          line="${rest%%$'\n'*}"
          LX_I=$((LX_I + ${#line} + 1))
          ;;
        *)
          line="$rest"
          LX_I=${#LX_S}
          ;;
      esac
      cmp="$line"
      if [ "$strip" = 1 ]; then
        while [ "${cmp#"$TAB"}" != "$cmp" ]; do cmp="${cmp#"$TAB"}"; done
      fi
      if [ "$cmp" = "$delim" ]; then
        found=1
        break
      fi
      if [ "$quoted" = 0 ]; then
        case "$line" in
          *'$('* | *'`'*) LX_FAIL=1 ;;
        esac
      fi
    done
    [ "$found" = 1 ] || LX_FAIL=1
  done
  LX_HD=()
}

# At `<<` (not `<<<`): read the delimiter word and register the heredoc.
lx_heredoc_start() {
  local p=$((LX_I + 2)) len=${#LX_S} strip=0 quoted=0 delim="" ch rest inner
  if [ "${LX_S:p:1}" = "-" ]; then
    strip=1
    p=$((p + 1))
  fi
  while [ "$p" -lt "$len" ]; do
    case "${LX_S:p:1}" in ' ' | "$TAB") p=$((p + 1)) ;; *) break ;; esac
  done
  while [ "$p" -lt "$len" ]; do
    ch="${LX_S:p:1}"
    case "$ch" in
      ' ' | "$TAB" | $'\n' | ';' | '|' | '&' | '(' | ')' | '<' | '>') break ;;
      "$SQ" | '"')
        rest="${LX_S:p+1}"
        case "$rest" in
          *"$ch"*) inner="${rest%%"$ch"*}" ;;
          *)
            LX_FAIL=1
            return 0
            ;;
        esac
        delim="$delim$inner"
        quoted=1
        p=$((p + ${#inner} + 2))
        ;;
      '\')
        delim="$delim${LX_S:p+1:1}"
        quoted=1
        p=$((p + 2))
        ;;
      *)
        delim="$delim$ch"
        p=$((p + 1))
        ;;
    esac
  done
  if [ -z "$delim" ]; then
    LX_FAIL=1
    return 0
  fi
  LX_HD[${#LX_HD[@]}]="$strip|$quoted|$delim"
  LX_I=$p
}

# lx_body <top|paren|btick> — lex from LX_I until EOF / the closing `)` /
# the closing backtick, appending segment records to LX_OUT.
lx_body() {
  local mode="$1" w="" wf=0 winw=0 seg="" c n rest inner len=${#LX_S}
  LX_DEPTH=$((LX_DEPTH + 1))
  if [ "$LX_DEPTH" -gt 8 ]; then
    LX_FAIL=1
    return 0
  fi
  while :; do
    [ "$LX_FAIL" = 1 ] && return 0
    if [ "$LX_I" -ge "$len" ]; then
      [ "$mode" = top ] || LX_FAIL=1
      break
    fi
    c="${LX_S:LX_I:1}"
    case "$c" in
      '\')
        n="${LX_S:LX_I+1:1}"
        if [ -z "$n" ]; then
          LX_I=$((LX_I + 1))
        elif [ "$n" = $'\n' ]; then
          LX_I=$((LX_I + 2))
        else
          w="$w$n"
          winw=1
          LX_I=$((LX_I + 2))
        fi
        ;;
      "$SQ")
        rest="${LX_S:LX_I+1}"
        case "$rest" in
          *"$SQ"*)
            inner="${rest%%"$SQ"*}"
            w="$w$inner"
            winw=1
            LX_I=$((LX_I + ${#inner} + 2))
            ;;
          *)
            LX_FAIL=1
            return 0
            ;;
        esac
        ;;
      '"')
        winw=1
        LX_I=$((LX_I + 1))
        while :; do
          [ "$LX_FAIL" = 1 ] && return 0
          if [ "$LX_I" -ge "$len" ]; then
            LX_FAIL=1
            return 0
          fi
          c="${LX_S:LX_I:1}"
          case "$c" in
            '"')
              LX_I=$((LX_I + 1))
              break
              ;;
            '\')
              n="${LX_S:LX_I+1:1}"
              case "$n" in
                '$' | '"' | '\' | '`')
                  w="$w$n"
                  LX_I=$((LX_I + 2))
                  ;;
                $'\n') LX_I=$((LX_I + 2)) ;;
                *)
                  w="$w\\"
                  LX_I=$((LX_I + 1))
                  ;;
              esac
              ;;
            '$')
              if [ "${LX_S:LX_I+1:1}" = "(" ]; then
                lx_subst paren
              else
                w="$w\$"
                wf=1
                LX_I=$((LX_I + 1))
              fi
              ;;
            '`') lx_subst btick ;;
            *)
              w="$w$c"
              LX_I=$((LX_I + 1))
              ;;
          esac
        done
        ;;
      '$')
        n="${LX_S:LX_I+1:1}"
        if [ "$n" = "(" ]; then
          lx_subst paren
        elif [ "$n" = "{" ]; then
          rest="${LX_S:LX_I}"
          case "$rest" in
            *'}'*)
              inner="${rest%%\}*}}"
              w="$w$inner"
              wf=1
              winw=1
              LX_I=$((LX_I + ${#inner}))
              ;;
            *)
              LX_FAIL=1
              return 0
              ;;
          esac
        else
          w="$w\$"
          wf=1
          winw=1
          LX_I=$((LX_I + 1))
        fi
        ;;
      '`')
        if [ "$mode" = btick ]; then
          LX_I=$((LX_I + 1))
          break
        fi
        lx_subst btick
        ;;
      '~')
        if [ "$winw" = 0 ]; then wf=1; fi
        w="$w~"
        winw=1
        LX_I=$((LX_I + 1))
        ;;
      '#')
        if [ "$winw" = 0 ]; then
          rest="${LX_S:LX_I}"
          case "$rest" in
            *$'\n'*)
              inner="${rest%%$'\n'*}"
              LX_I=$((LX_I + ${#inner}))
              ;;
            *) LX_I=$len ;;
          esac
        else
          w="$w#"
          LX_I=$((LX_I + 1))
        fi
        ;;
      ' ' | "$TAB")
        lx_word_end
        LX_I=$((LX_I + 1))
        ;;
      $'\n')
        lx_seg_end
        LX_I=$((LX_I + 1))
        if [ "${#LX_HD[@]}" -gt 0 ]; then lx_heredocs; fi
        ;;
      ';' | '|' | '&')
        lx_seg_end
        LX_I=$((LX_I + 1))
        ;;
      '(')
        lx_seg_end
        LX_OUT[${#LX_OUT[@]}]="("
        LX_I=$((LX_I + 1))
        lx_body paren
        LX_OUT[${#LX_OUT[@]}]=")"
        ;;
      ')')
        if [ "$mode" = paren ]; then
          LX_I=$((LX_I + 1))
          break
        fi
        LX_FAIL=1
        return 0
        ;;
      '<')
        if [ "${LX_S:LX_I:3}" = "<<<" ]; then
          w="$w<<<"
          winw=1
          LX_I=$((LX_I + 3))
        elif [ "${LX_S:LX_I:2}" = "<<" ]; then
          lx_word_end
          lx_heredoc_start
        else
          w="$w<"
          winw=1
          LX_I=$((LX_I + 1))
        fi
        ;;
      *)
        w="$w$c"
        winw=1
        LX_I=$((LX_I + 1))
        ;;
    esac
  done
  lx_seg_end
  LX_DEPTH=$((LX_DEPTH - 1))
}

lx_run() {
  LX_S="$1"
  LX_I=0
  LX_FAIL=0
  LX_DEPTH=0
  LX_OUT=()
  LX_HD=()
  lx_body top
  if [ "${#LX_HD[@]}" -gt 0 ]; then LX_FAIL=1; fi
}

# Split one "S" record body into SW_T (dequoted text) / SW_F (expansion flag).
SW_N=0
SW_T=()
SW_F=()
cf_split() {
  local s="$1" word
  SW_N=0
  SW_T=()
  SW_F=()
  [ -n "$s" ] || return 0
  while :; do
    case "$s" in
      *"$US"*)
        word="${s%%"$US"*}"
        s="${s#*"$US"}"
        ;;
      *)
        word="$s"
        s=""
        ;;
    esac
    SW_F[SW_N]="${word:0:1}"
    SW_T[SW_N]="${word:1}"
    SW_N=$((SW_N + 1))
    [ -n "$s" ] || break
  done
}

# If the split segment runs `bash|sh|zsh … -c <payload>` or `eval …`, set
# CF_PAYLOAD to the string to lex again and return 0.
CF_PAYLOAD=""
cf_shell_payload() {
  local k j t rest
  for ((k = 0; k < SW_N; k++)); do
    t="${SW_T[k]##*/}"
    case "$t" in
      bash | sh | zsh | dash | ksh)
        for ((j = k + 1; j < SW_N; j++)); do
          case "${SW_T[j]}" in
            -c | -[!-]*c*)
              if [ $((j + 1)) -lt "$SW_N" ]; then
                CF_PAYLOAD="${SW_T[j+1]}"
                return 0
              fi
              return 1
              ;;
            -*) ;;
            *) return 1 ;;
          esac
        done
        return 1
        ;;
      eval)
        rest=""
        for ((j = k + 1; j < SW_N; j++)); do rest="$rest ${SW_T[j]}"; done
        CF_PAYLOAD="$rest"
        return 0
        ;;
    esac
  done
  return 1
}

# Does the split segment run a shell that reads its script from stdin (a
# heredoc, a pipe, `-s`, `-`, `< file`, `source /dev/stdin`)? The script text
# is then not visible to the lexer, so the caller treats the command as
# "unsure" (legacy matcher + fail-closed target). Over-triggering is fine.
cf_reads_stdin_shell() {
  local k j t o
  for ((k = 0; k < SW_N; k++)); do
    case "${SW_T[k]}" in
      /dev/stdin | /dev/fd/0 | /proc/self/fd/0) return 0 ;;
    esac
  done
  for ((k = 0; k < SW_N; k++)); do
    t="${SW_T[k]##*/}"
    case "$t" in
      bash | sh | zsh | dash | ksh)
        for ((j = k + 1; j < SW_N; j++)); do
          o="${SW_T[j]}"
          case "$o" in
            -c | -[!-]*c*) continue 2 ;;
            -s | -[!-]*s* | -) return 0 ;;
            -o | +o | -O | +O | --rcfile | --init-file) j=$((j + 1)) ;;
            -* | +*) ;;
            '<' | '>' | '<<<' | '>>' | [0-9]'<' | [0-9]'>') j=$((j + 1)) ;;
            [0-9]*[\<\>]* | \<* | \>*) ;;
            *) continue 2 ;;
          esac
        done
        return 0
        ;;
    esac
  done
  return 1
}

# Lex <string> and append its records to CF_REC, re-lexing shell payloads.
# Sets CF_FAIL=1 when unsure.
CF_FAIL=0
CF_REC=()
cf_collect() {
  local str="$1" depth="$2" recs=() n i rec payload
  if [ "$depth" -gt 3 ]; then
    CF_FAIL=1
    return 0
  fi
  lx_run "$str"
  if [ "$LX_FAIL" = 1 ]; then
    CF_FAIL=1
    return 0
  fi
  n=${#LX_OUT[@]}
  for ((i = 0; i < n; i++)); do recs[i]="${LX_OUT[i]}"; done
  for ((i = 0; i < n; i++)); do
    rec="${recs[i]}"
    CF_REC[${#CF_REC[@]}]="$rec"
    case "$rec" in
      S*)
        cf_split "${rec#S}"
        if cf_shell_payload; then
          payload="$CF_PAYLOAD"
          CF_REC[${#CF_REC[@]}]="("
          cf_collect "$payload" $((depth + 1))
          CF_REC[${#CF_REC[@]}]=")"
          [ "$CF_FAIL" = 1 ] && return 0
        elif cf_reads_stdin_shell; then
          CF_FAIL=1
          return 0
        fi
        ;;
    esac
  done
}

# Is the split segment (SW_*) a `git … commit`? Fills CM_* with the path
# options found between `git` and `commit`, in order.
CM_CN=0
CM_CV=()
CM_CF=()
CM_WT=""
CM_WTF=0
CM_GD=""
CM_GDF=0
cf_find_commit() {
  local k j t
  for ((k = 0; k < SW_N; k++)); do
    case "${SW_T[k]}" in git | */git) ;; *) continue ;; esac
    CM_CN=0
    CM_CV=()
    CM_CF=()
    CM_WT=""
    CM_WTF=0
    CM_GD=""
    CM_GDF=0
    j=$((k + 1))
    while [ "$j" -lt "$SW_N" ]; do
      t="${SW_T[j]}"
      case "$t" in
        -C)
          [ $((j + 1)) -lt "$SW_N" ] || break
          CM_CV[CM_CN]="${SW_T[j+1]}"
          CM_CF[CM_CN]="${SW_F[j+1]}"
          CM_CN=$((CM_CN + 1))
          j=$((j + 2))
          ;;
        --work-tree)
          [ $((j + 1)) -lt "$SW_N" ] || break
          CM_WT="${SW_T[j+1]}"
          CM_WTF="${SW_F[j+1]}"
          j=$((j + 2))
          ;;
        --git-dir)
          [ $((j + 1)) -lt "$SW_N" ] || break
          CM_GD="${SW_T[j+1]}"
          CM_GDF="${SW_F[j+1]}"
          j=$((j + 2))
          ;;
        -c | --namespace | --config-env)
          [ $((j + 1)) -lt "$SW_N" ] || break
          j=$((j + 2))
          ;;
        --work-tree=*)
          CM_WT="${t#*=}"
          CM_WTF="${SW_F[j]}"
          j=$((j + 1))
          ;;
        --git-dir=*)
          CM_GD="${t#*=}"
          CM_GDF="${SW_F[j]}"
          j=$((j + 1))
          ;;
        -*) j=$((j + 1)) ;;
        [0-9]*[\<\>]* | \<* | \>*) j=$((j + 1)) ;;
        commit) return 0 ;;
        *) break ;;
      esac
    done
  done
  return 1
}

# rp_resolve <base> <value> <expansion-flag> — canonical directory in RP_OUT,
# or return 1 when the value is unresolvable (expansion, relative to an
# unknown base, or not an existing directory).
RP_OUT=""
rp_resolve() {
  local b="$1" v="$2" f="$3" p
  [ "$f" = 0 ] || return 1
  if [ -z "$v" ]; then
    RP_OUT="$b"
    [ -n "$b" ]
    return
  fi
  case "$v" in
    /*) p="$v" ;;
    *)
      [ -n "$b" ] || return 1
      p="$b/$v"
      ;;
  esac
  [ -d "$p" ] || return 1
  RP_OUT="$(cd "$p" 2>/dev/null && pwd)" || return 1
  [ -n "$RP_OUT" ]
}

TGT_DIR=""
TGT_UNRES=0
TGT_RAW=""
TGT_N=0
tgt_note() {
  # <dir> — record a resolved target; differing trees are unresolved.
  if [ "$TGT_N" -eq 0 ]; then
    TGT_DIR="$1"
  elif [ "$TGT_UNRES" = 0 ] && [ "$TGT_DIR" != "$1" ]; then
    TGT_UNRES=1
    TGT_RAW="commits in one command target different trees: $TGT_DIR, $1"
  fi
  TGT_N=$((TGT_N + 1))
}
tgt_fail() {
  # <raw> — record an unresolved target (first raw wins).
  if [ "$TGT_UNRES" = 0 ]; then
    TGT_UNRES=1
    TGT_RAW="$1"
  fi
  TGT_N=$((TGT_N + 1))
}

# Walk the lexed records: track `cd` (scoped by subshell markers) and resolve
# each commit segment's target.
resolve_commit_targets() {
  local base braw rec i n j v f ok cur raw
  local bstack=() rstack=() sp=0
  base="$(cd "$PWD" 2>/dev/null && pwd)" || base="$PWD"
  braw=""
  TGT_DIR=""
  TGT_UNRES=0
  TGT_RAW=""
  TGT_N=0
  n=${#CF_REC[@]}
  for ((i = 0; i < n; i++)); do
    rec="${CF_REC[i]}"
    case "$rec" in
      "(")
        bstack[sp]="$base"
        rstack[sp]="$braw"
        sp=$((sp + 1))
        continue
        ;;
      ")")
        if [ "$sp" -gt 0 ]; then
          sp=$((sp - 1))
          base="${bstack[sp]}"
          braw="${rstack[sp]}"
        fi
        continue
        ;;
    esac
    cf_split "${rec#S}"
    if [ "$SW_N" -gt 0 ] && [ "${SW_T[0]}" = "cd" ]; then
      j=1
      while [ "$j" -lt "$SW_N" ]; do
        case "${SW_T[j]}" in -?*) j=$((j + 1)) ;; *) break ;; esac
      done
      if [ "$j" -ge "$SW_N" ]; then
        base=""
        braw="cd (no argument)"
      elif [ "${SW_T[j]}" = "-" ]; then
        base=""
        braw="cd -"
      elif rp_resolve "$base" "${SW_T[j]}" "${SW_F[j]}"; then
        base="$RP_OUT"
        braw=""
      else
        base=""
        braw="${SW_T[j]}"
      fi
      continue
    fi
    cf_find_commit || continue
    cur="$base"
    raw="$braw"
    ok=1
    if [ "$CM_CN" -gt 0 ]; then
      for ((j = 0; j < CM_CN; j++)); do
        v="${CM_CV[j]}"
        f="${CM_CF[j]}"
        if rp_resolve "$cur" "$v" "$f"; then
          cur="$RP_OUT"
        else
          ok=0
          raw="$v"
          break
        fi
      done
    elif [ -n "$CM_WT" ]; then
      if rp_resolve "$cur" "$CM_WT" "$CM_WTF"; then cur="$RP_OUT"; else ok=0; raw="$CM_WT"; fi
    elif [ -n "$CM_GD" ]; then
      if rp_resolve "$cur" "$CM_GD" "$CM_GDF"; then cur="$RP_OUT"; else ok=0; raw="$CM_GD"; fi
    elif [ -z "$cur" ]; then
      ok=0
    fi
    if [ "$ok" = 1 ] && [ -n "$cur" ]; then
      tgt_note "$cur"
    else
      tgt_fail "${raw:-$cur}"
    fi
  done
}

# Fallback target resolution for the "lexer unsure" path: the historical
# regex extraction, but fail-closed instead of falling back to $PWD.
legacy_target() {
  local v="" f=0
  TGT_DIR="$(cd "$PWD" 2>/dev/null && pwd)" || TGT_DIR="$PWD"
  TGT_UNRES=0
  TGT_RAW=""
  TGT_N=1
  if printf '%s' "$command_str" | grep -qE 'git[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-C[[:space:]]'; then
    v="$(printf '%s' "$command_str" | sed -nE "s/.*git[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-C[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:]]+)).*/\3\4\5/p")"
  elif printf '%s' "$command_str" | grep -qE -- '--work-tree(=|[[:space:]])'; then
    v="$(printf '%s' "$command_str" | sed -nE "s/.*--work-tree(=|[[:space:]]+)(\"([^\"]+)\"|'([^']+)'|([^[:space:]]+)).*/\3\4\5/p")"
  elif printf '%s' "$command_str" | grep -qE -- '--git-dir(=|[[:space:]])'; then
    v="$(printf '%s' "$command_str" | sed -nE "s/.*--git-dir(=|[[:space:]]+)(\"([^\"]+)\"|'([^']+)'|([^[:space:]]+)).*/\3\4\5/p")"
  elif printf '%s' "$command_str" | grep -qE '^[[:space:]]*cd[[:space:]]'; then
    v="$(printf '%s' "$command_str" | sed -nE "s/^[[:space:]]*cd[[:space:]]+(\"([^\"]+)\"|'([^']+)'|([^[:space:]&;|]+)).*/\2\3\4/p")"
  fi
  [ -n "$v" ] || return 0
  case "$v" in *'$'* | *'`'* | '~'*) f=1 ;; esac
  if rp_resolve "$TGT_DIR" "$v" "$f"; then
    TGT_DIR="$RP_OUT"
  else
    TGT_UNRES=1
    TGT_RAW="$v"
  fi
}

cf_collect "$command_str" 0
if [ "$CF_FAIL" = 1 ]; then
  legacy_matches || exit 0
  legacy_target
else
  resolve_commit_targets
  [ "$TGT_N" -gt 0 ] || exit 0
fi

if [ "$TGT_UNRES" = 1 ]; then
  target_dir="$PWD"
  target_label="(unresolved: $TGT_RAW)"
else
  target_dir="$TGT_DIR"
  target_label="$target_dir"
fi

# #277 review-fix cycle 1 — strip the commit-message PAYLOAD before the
# signature scan below. The scan must run on command SHAPE (option
# tokens), not on arbitrary text a developer typed into `-m`/`--message`
# (or `-F`/`--file`): a message like `-m "explain --git-dir redirection"`
# is legitimate content, not an attempt to redirect the commit. Without
# this, the grep-over-the-whole-string scan false-blocked any commit
# whose message happened to mention a bypass-flag spelling.
#
# `strip_message_payload` removes only the flag+value pair for -m /
# --message / -F / --file, requiring a real separator (`=`, whitespace,
# or a directly-attached quote — i.e. `-m"msg"` / `-m'msg'`) right after
# the flag so an unrelated option that merely starts with the same
# letters (e.g. a hypothetical `-max`) is never mistaken for `-m`. This
# deliberately does NOT touch `-c`/`-C` reuse-message forms on the
# `commit` subcommand — that flag spelling collides with the top-level
# `git -C <path>` worktree-selection flag resolved above, and
# disambiguating the two positionally is not worth the risk of breaking
# that resolution for this fix.
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
      # #277 cycle 2 — quote BASH_REMATCH[0] so the pattern operand of
      # ${var/pat/repl} is a literal string, not a glob. Unquoted, any
      # matched text containing glob metacharacters (`[core]`, `*`, `?`,
      # parens) fails to match as a glob, so `out` never shrinks and the
      # loop spins forever. Quoting forces literal substring replacement,
      # which always removes the matched text.
      out="${out/"${BASH_REMATCH[0]}"/ }"
      # Belt-and-braces anti-hang guard: bail if an iteration ever fails
      # to shrink $out, so no future non-progress bug in this loop can
      # hang the hook regardless of input.
      if [ "${#out}" -ge "$prev_len" ]; then
        break
      fi
    done
  done
  printf '%s' "$out"
}
scan_str="$(strip_message_payload "$command_str")"

# gate-bypass signature refusal, placed BEFORE every green-path allow
# below (including the F48 docs-only and no-package-json N/A
# short-circuits). The bypass check runs on command SHAPE, not content:
# an agent smuggling a skip flag, a redirected git-dir/work-tree, or
# `--no-verify` into the commit command itself must never reach a path
# that reports N/A or green — those checks are orthogonal and must stay
# unaffected for legitimate commits. This is distinct from the
# operator's out-of-band `ATELIER_SKIP_SAFE_COMMIT=1` escape hatch above
# (set in the hook's *environment*, never inside the command).
bypass_signature=""
if printf '%s' "$scan_str" | grep -qE '(^|[;&|[:space:]])ATELIER_SKIP_SAFE_COMMIT[[:space:]]*='; then
  bypass_signature="inline ATELIER_SKIP_SAFE_COMMIT= assignment"
elif printf '%s' "$scan_str" | grep -qE -- '--git-dir(=|[[:space:]])'; then
  bypass_signature="--git-dir"
elif printf '%s' "$scan_str" | grep -qE -- '--work-tree(=|[[:space:]])'; then
  bypass_signature="--work-tree"
elif printf '%s' "$scan_str" | grep -qE -- '(^|[[:space:]])--no-verify([[:space:]]|;|&|$)'; then
  bypass_signature="--no-verify"
fi

if [ -n "$bypass_signature" ]; then
  cat >&2 <<MSG
🚫 atelier:safe-commit BLOCKED
   Tool:   Bash(git commit)
   Reason: gate-bypass attempt refused — the push gate cannot be routed around; fix the red gate or hand back to tester
   Signature: $bypass_signature
   Target: $target_label
   Rule:   PLAN.md §6 push gate — lint + typecheck + tests must pass before every commit; this signature would route the commit around that gate.
   Action: fix the underlying red check, or hand back to tester. The operator's out-of-band ATELIER_SKIP_SAFE_COMMIT=1 escape hatch must be set in the shell environment — never inline it in the commit command.
MSG

  log_decision "$HOOK_NAME" "Bash" "bypass-attempt" "block" "gate-bypass signature: $bypass_signature"
  exit 2
fi

# #504 — fail closed when the target tree could not be determined. Placed
# after the bypass refusal (so #277 output is unchanged) and BEFORE the F48
# docs-only and no-package-json N/A allows, which would otherwise judge the
# wrong tree.
if [ "$TGT_UNRES" = 1 ]; then
  cat >&2 <<MSG
🚫 atelier:safe-commit BLOCKED
   Tool:   Bash(git commit)
   Reason: could not determine the target tree; pass the literal absolute path
   Value:  $TGT_RAW
   Rule:   PLAN.md §6 push gate — the gate must validate the tree being committed, never \$PWD by default.
   Action: re-run with the literal absolute worktree path, e.g. git -C /abs/path/to/worktree commit …
MSG

  log_decision "$HOOK_NAME" "Bash" "target-unresolved" "block" "could not resolve the commit target tree: $TGT_RAW"
  exit 2
fi

# M7.1.F48 — docs-only short-circuit.
#
# If every file the commit will touch is documentation, the push gate
# (lint + typecheck + tests) has nothing to validate. Running it under a
# worktree with missing deps produces the F48 symptom: the gate fails
# with `turbo: command not found` (or similar), the operator gets asked
# whether to skip — but the gate would not have rejected anything even
# if it could run.
#
# Detection rule: every staged file matches at least one of
#   - extension in {.md, .markdown, .txt, .rst, .adoc, .asciidoc}
#   - path prefix docs/ or documentation/
#   - basename in {LICENSE, NOTICE, CHANGELOG, AUTHORS, CONTRIBUTORS, README}
#     with or without an extension
#
# If even one staged file falls outside those patterns, the gate runs as
# before. This is intentionally conservative: a commit that touches both
# README.md and src/index.ts must validate.
#
# `git diff --cached --name-only` lists the staged files. For `git commit
# -a` / `--all` the index is not updated yet at hook time, so we also
# include `git diff --name-only` (modified-tracked files) when the
# command carries `-a` or `--all`.
staged_files="$(git -C "$target_dir" diff --cached --name-only 2>/dev/null || true)"
if printf '%s' "$command_str" | grep -qE '\bcommit\b[^|;&]*( -a\b| --all\b)'; then
  modified_files="$(git -C "$target_dir" diff --name-only 2>/dev/null || true)"
  all_files="$(printf '%s\n%s\n' "$staged_files" "$modified_files" | sort -u | sed '/^$/d')"
else
  all_files="$staged_files"
fi

# When there's nothing staged, we have nothing to short-circuit; fall
# through to the gate (it will surface the empty-commit case in its own
# voice).
if [ -n "$all_files" ]; then
  is_docs_only=true
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    matched=false
    # Extension match
    case "$f" in
      *.md|*.markdown|*.txt|*.rst|*.adoc|*.asciidoc) matched=true ;;
    esac
    # Path prefix match
    if ! $matched; then
      case "$f" in
        docs/*|documentation/*) matched=true ;;
      esac
    fi
    # Exact filename match (with or without trailing extension)
    if ! $matched; then
      base="$(basename "$f")"
      case "$base" in
        LICENSE|LICENSE.*|NOTICE|NOTICE.*|CHANGELOG|CHANGELOG.*|AUTHORS|AUTHORS.*|CONTRIBUTORS|CONTRIBUTORS.*|README|README.*) matched=true ;;
      esac
    fi
    if ! $matched; then
      is_docs_only=false
      break
    fi
  done <<EOF
$all_files
EOF

  if $is_docs_only; then
    file_count="$(printf '%s\n' "$all_files" | wc -l | tr -d ' ')"
    log_decision "$HOOK_NAME" "Bash" "docs-only" "allow" "all $file_count staged file(s) are documentation — push gate N/A (F48)"
    exit 0
  fi
fi

# Find the project root by walking up from the commit's target worktree
# (NOT $PWD — see F57 above) looking for package.json. If we never find
# one, this is not a JS/TS project — allow.
project_root="$target_dir"
while [ "$project_root" != "/" ] && [ ! -f "$project_root/package.json" ]; do
  project_root="$(dirname "$project_root")"
done

if [ ! -f "$project_root/package.json" ]; then
  log_decision "$HOOK_NAME" "Bash" "no-package-json" "allow" "no package.json in target worktree tree — push gate N/A"
  exit 0
fi

# M7.1.F57 — detect the package manager by lockfile instead of assuming
# pnpm. pnpm is the atelier default (PLAN.md §2) when no lockfile is
# present, but a workspace member on npm/yarn/bun must be gated with its
# own tool or the scripts mis-run / fail.
detect_pm() {
  if   [ -f "$project_root/pnpm-lock.yaml" ];   then echo pnpm
  elif [ -f "$project_root/yarn.lock" ];        then echo yarn
  elif [ -f "$project_root/bun.lockb" ] || [ -f "$project_root/bun.lock" ]; then echo bun
  elif [ -f "$project_root/package-lock.json" ]; then echo npm
  else echo pnpm
  fi
}
pm="$(detect_pm)"

# Helper: returns 0 if `scripts.<name>` exists in package.json.
has_script() {
  jq -e --arg s "$1" '.scripts[$s] // empty' "$project_root/package.json" >/dev/null 2>&1
}

# Helper: run a script, return 0 on success, non-zero on failure.
# Captures combined stdout/stderr into a variable so we can show the
# tail to Claude. The caller decides what to do with the exit code.
run_pm_step() {
  local script="$1"
  ( cd "$project_root" && "$pm" run "$script" 2>&1 )
}

# #399 — per-project scope for the `test` step (see the header). Reads
# `safeCommit.testScope` from the project's `.atelier.json`: the one next
# to package.json first, else the one at the git toplevel of the commit's
# target worktree (a `git -C <subdir> commit` inside a workspace member).
# Anything other than "full" / "changed" — missing file, unreadable JSON,
# absent key, unknown value — resolves to "full"; an unknown value is
# also logged so a typo never silently widens or narrows the gate.
resolve_test_scope() {
  local cfg="" top="" raw=""
  if [ -f "$project_root/.atelier.json" ]; then
    cfg="$project_root/.atelier.json"
  else
    top="$(git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$top" ] && [ -f "$top/.atelier.json" ]; then
      cfg="$top/.atelier.json"
    fi
  fi
  if [ -z "$cfg" ]; then
    echo full
    return 0
  fi
  raw="$(jq -r '.safeCommit.testScope // "full"' "$cfg" 2>/dev/null || true)"
  case "$raw" in
    full|changed)
      echo "$raw"
      ;;
    "")
      echo full
      ;;
    *)
      log_decision "$HOOK_NAME" "Bash" "test-scope-invalid" "allow" "safeCommit.testScope \"$raw\" is neither \"full\" nor \"changed\" — treating as full"
      echo full
      ;;
  esac
}
test_scope="$(resolve_test_scope)"

# Walk the three steps in order, stopping (blocking) on the first red.
# A step is N/A if `scripts.<name>` doesn't exist in package.json — we
# log it and continue, which mirrors the `safe-commit` skill. Under
# `testScope: "changed"` the `test` step runs `test:changed` instead,
# falling back to `test` (logged) when the project does not define it.
for step in lint typecheck test; do
  script="$step"
  if [ "$step" = "test" ] && [ "$test_scope" = "changed" ]; then
    if has_script "test:changed"; then
      script="test:changed"
    else
      log_decision "$HOOK_NAME" "Bash" "test-changed-na" "allow" "scripts.test:changed not defined in package.json — falling back to scripts.test"
    fi
  fi

  if ! has_script "$script"; then
    log_decision "$HOOK_NAME" "Bash" "${script}-na" "allow" "scripts.${script} not defined in package.json — step N/A"
    continue
  fi

  output="$(run_pm_step "$script" || printf '__EXIT_%d__' "$?")"
  # Detect our sentinel for failure. We can't capture $? cleanly through
  # a subshell + assignment without losing the output, so we encode it.
  if printf '%s' "$output" | tail -c 80 | grep -qE '__EXIT_[0-9]+__$'; then
    exit_code="$(printf '%s' "$output" | tail -c 80 | grep -oE '__EXIT_[0-9]+__' | grep -oE '[0-9]+')"
    output="$(printf '%s' "$output" | sed -E 's/__EXIT_[0-9]+__$//')"

    cat >&2 <<MSG
🚫 atelier:safe-commit BLOCKED
   Tool:   Bash(git commit)
   Reason: \`$pm run $script\` failed with exit $exit_code
   Output (last 30 lines):
$(printf '%s' "$output" | tail -n 30)
   Rule:   PLAN.md §6 push gate — lint + typecheck + tests must pass before commit.
   Action: fix the failing $script, then commit again. The hook re-runs automatically.
   Override: set ATELIER_SKIP_SAFE_COMMIT=1 only when the operator confirms the gate has been validated another way.
MSG

    log_decision "$HOOK_NAME" "Bash" "${script}-red" "block" "$pm run $script failed (exit $exit_code)"
    exit 2
  fi

  log_decision "$HOOK_NAME" "Bash" "${script}-green" "allow" "$pm run $script passed"
done

log_decision "$HOOK_NAME" "Bash" "push-gate-green" "allow" "push gate green — commit allowed"
exit 0
