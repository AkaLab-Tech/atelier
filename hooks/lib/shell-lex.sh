#!/usr/bin/env bash
# Shared minimal shell lexer (moved verbatim from block-operator-gh-identity.sh,
# #651): quote-aware segment/token splitting and heredoc-body stripping. Sourced
# by block-operator-gh-identity.sh and block-consent-tamper.sh; defines functions
# and the US/RS separators only, runs nothing.

# shellcheck disable=SC2016,SC2088,SC1003
US=$'\x1f'
RS=$'\x1e'

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
  local line delim="" dash=0 out="" t pre hd_dash hd_delim
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
      # The $shre test below clobbers BASH_REMATCH; copy what we need first.
      hd_dash="${BASH_REMATCH[2]:-}"; hd_delim="${BASH_REMATCH[3]:-}"
      pre="${line%%<<*}"
      if ! [[ "$pre" =~ $shre ]]; then
        delim="$hd_delim"
        if [ -n "$hd_dash" ]; then dash=1; else dash=0; fi
      fi
    fi
  done <<< "$1"
  printf '%s' "$out"
}
