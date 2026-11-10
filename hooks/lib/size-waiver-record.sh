#!/usr/bin/env bash
#
# atelier — size-waiver record (#735, #726 part 1). Sourced by
# hooks/size-waiver-capture.sh. Marker in the question text, exact affirmative
# labels, HMAC-signed record under state/consent/size-waivers/ (key:
# state/consent/size-waiver.key, 0600). Fails closed (return 1) on any error.

# shellcheck source=consent.sh
source "$(dirname "${BASH_SOURCE[0]}")/consent.sh"

SWR_AFFIRMATIVE=("Yes, waive the size limit" "Yes, the waiver covers it" "Sí, dispenso el tamaño" "Sí, la dispensa lo cubre")

# swr_marker <owner/repo> <NN> <sha> <lines> <files>
swr_marker() { printf '[atelier size-waiver %s#%s @%s %sL/%sF]' "$1" "$2" "$3" "$4" "$5"; }

# shellcheck disable=SC2034
# swr_parse_marker <text> -> sets repo pr sha lines files
swr_parse_marker() {
  local re='\[atelier size-waiver ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+) @([0-9a-f]{40}) ([0-9]+)L/([0-9]+)F\]'
  [[ "${1:-}" =~ $re ]] || return 1
  repo="${BASH_REMATCH[1]}" pr="${BASH_REMATCH[2]}" sha="${BASH_REMATCH[3]}"
  lines="${BASH_REMATCH[4]}" files="${BASH_REMATCH[5]}"
}

# swr_is_affirmative <label>: exact match (whitespace-trimmed) on the closed set.
swr_is_affirmative() {
  local l="${1:-}" a
  l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"
  for a in "${SWR_AFFIRMATIVE[@]}"; do [ "$l" = "$a" ] && return 0; done
  return 1
}

# swr_question <owner/repo> <NN> <sha> <lines> <files> [es|en] -> questions[] JSON
swr_question() {
  local m yes no q d
  m="$(swr_marker "$1" "$2" "$3" "$4" "$5")"
  if [ "${6:-en}" = es ]; then
    yes="${SWR_AFFIRMATIVE[2]}"; no="No"
    q="¿Dispensás el límite de tamaño de $1#$2 ($4 líneas, $5 archivos)? $m"
    d="Registra la dispensa para este commit exacto."
  else
    yes="${SWR_AFFIRMATIVE[0]}"; no="No"
    q="Waive the size limit for $1#$2 ($4 lines, $5 files)? $m"
    d="Records the waiver for this exact commit."
  fi
  jq -cn --arg q "$q" --arg y "$yes" --arg n "$no" --arg d "$d" \
    '[{question:$q,header:"Size waiver",multiSelect:false,options:[{label:$y,description:$d},{label:$n,description:"No waiver."}]}]'
}

# swr_record_path <owner/repo> <NN>
swr_record_path() { local r="${1/\//__}"; printf '%s/size-waivers/%s__%s.json' "$(_consent_root)" "$r" "$2"; }

# swr_key: print the key, creating it on first use (atomic no-clobber, 0600).
swr_key() {
  local f t k; f="$(_consent_root)/size-waiver.key"
  if [ ! -s "$f" ]; then
    k="$(LC_ALL=C head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" || return 1
    [ "${#k}" -eq 64 ] || return 1
    (umask 077; mkdir -p "${f%/*}" && t="$(mktemp "$f.XXXXXX")" && printf '%s' "$k" >"$t" \
      && { ln "$t" "$f" 2>/dev/null; rm -f "$t"; }) 2>/dev/null || return 1
  fi
  k="$(cat "$f" 2>/dev/null)" || return 1
  [ "${#k}" -eq 64 ] || return 1
  printf '%s' "$k"
}

# swr_hmac <canonical>
swr_hmac() {
  local k h; command -v openssl >/dev/null 2>&1 || return 1
  k="$(swr_key)" || return 1
  h="$(printf '%s' "$1" | openssl dgst -sha256 -hmac "$k" 2>/dev/null | awk '{print $NF}')" || return 1
  [ "${#h}" -eq 64 ] || return 1
  printf '%s' "$h"
}

# swr_canonical <repo> <pr> <sha> <lines> <files> <question> <answer> <sid> <ts>
swr_canonical() {
  printf '1\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s' "$@"
}

# swr_write <repo> <pr> <sha> <lines> <files> <question> <answer> <sid> <ts>
swr_write() {
  local p d t h; p="$(swr_record_path "$1" "$2")"; d="${p%/*}"
  h="$(swr_hmac "$(swr_canonical "$@")")" || return 1
  (umask 077; mkdir -p "$d" && t="$(mktemp "$d/.tmp.XXXXXX")" \
    && jq -n --arg repo "$1" --argjson pr "$2" --arg sha "$3" --argjson lines "$4" --argjson files "$5" \
      --arg q "$6" --arg a "$7" --arg sid "$8" --arg ts "$9" --arg h "$h" \
      '{v:1,repo:$repo,pr:$pr,head_sha:$sha,lines:$lines,files:$files,question:$q,answer:$a,session_id:$sid,captured_at:$ts,source:"askuserquestion-posttooluse",hmac:$h}' >"$t" \
    && mv "$t" "$p") 2>/dev/null || return 1
}

# swr_verify <record.json>: recompute the HMAC.
swr_verify() {
  local c h
  c="$(jq -j '"1\u001f"+([.repo,.pr,.head_sha,.lines,.files,.question,.answer,.session_id,.captured_at]|map(tostring)|join("\u001f"))' "$1" 2>/dev/null)" || return 1
  h="$(swr_hmac "$c")" || return 1
  [ "$h" = "$(jq -r '.hmac' "$1" 2>/dev/null)" ]
}
