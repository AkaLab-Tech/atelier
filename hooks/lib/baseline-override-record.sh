#!/usr/bin/env bash
#
# atelier — baseline-override record (#746, #744 part 1). Sourced by
# hooks/baseline-override-capture.sh. Marker + fixed-delimiter identifier list in
# the question text, exact affirmative labels, HMAC-signed record under
# state/consent/baseline-overrides/ (key: state/consent/baseline-override.key,
# 0600). Fails closed (return 1) on any error. Identifiers are compared byte-exact.

# shellcheck source=consent.sh
source "$(dirname "${BASH_SOURCE[0]}")/consent.sh"

BOR_AFFIRMATIVE=("Yes, waive these tests for this branch" "Sí, dispenso estos tests para esta rama")

# bor_digest <ids...>: sha256 of the sorted unique identifiers joined by \n.
bor_digest() {
  local s; s="$(printf '%s\n' "$@" | LC_ALL=C sort -u)"
  if command -v shasum >/dev/null 2>&1; then printf '%s' "$s" | shasum -a 256 | awk '{print $1}'
  else printf '%s' "$s" | sha256sum | awk '{print $1}'; fi
}

# bor_marker <owner/repo> <branch> <base_sha> <N> <h>
bor_marker() { printf '[atelier baseline-override %s %s @%s n=%s h=%s]' "$1" "$2" "$3" "$4" "${5:0:16}"; }

# shellcheck disable=SC2034
# bor_parse_marker <text> -> sets repo branch base_sha n h
bor_parse_marker() {
  local re='\[atelier baseline-override ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+) ([A-Za-z0-9_./-]+) @([0-9a-f]{40}) n=([0-9]+) h=([0-9a-f]{16})\]'
  [[ "${1:-}" =~ $re ]] || return 1
  repo="${BASH_REMATCH[1]}" branch="${BASH_REMATCH[2]}" base_sha="${BASH_REMATCH[3]}"
  n="${BASH_REMATCH[4]}" h="${BASH_REMATCH[5]}"
}

# bor_parse_ids <text>: identifier lines between the fixed delimiters.
bor_parse_ids() {
  printf '%s\n' "${1:-}" | awk '/^--- end ---$/{f=0} f{print} /^--- waived ---$/{f=1}'
}

# bor_is_affirmative <label>: exact match (whitespace-trimmed) on the closed set.
bor_is_affirmative() {
  local l="${1:-}" a
  l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"
  for a in "${BOR_AFFIRMATIVE[@]}"; do [ "$l" = "$a" ] && return 0; done
  return 1
}

# bor_question <owner/repo> <branch> <base_sha> [es|en] <ids...> -> questions[] JSON
bor_question() {
  local repo="$1" br="$2" sha="$3" lang="${4:-en}" m yes no q d ids; shift 4
  m="$(bor_marker "$repo" "$br" "$sha" "$#" "$(bor_digest "$@")")"
  ids="$(printf '%s\n' "$@" | LC_ALL=C sort -u)"
  if [ "$lang" = es ]; then
    yes="${BOR_AFFIRMATIVE[1]}"; no="No"
    q="¿Dispensás estos $# tests que ya fallaban en la base de $repo $br? $m"$'\n--- waived ---\n'"$ids"$'\n--- end ---'
    d="Registra la dispensa para esta rama."
  else
    yes="${BOR_AFFIRMATIVE[0]}"; no="No"
    q="Waive these $# tests that already fail on the base of $repo $br? $m"$'\n--- waived ---\n'"$ids"$'\n--- end ---'
    d="Records the override for this branch."
  fi
  jq -cn --arg q "$q" --arg y "$yes" --arg n "$no" --arg d "$d" \
    '[{question:$q,header:"Baseline override",multiSelect:false,options:[{label:$y,description:$d},{label:$n,description:"No override."}]}]'
}

# bor_record_path <owner/repo> <branch>
bor_record_path() { local r="${1/\//__}" b="${2//\//__}"; printf '%s/baseline-overrides/%s__%s.json' "$(_consent_root)" "$r" "$b"; }

# bor_key: print the key, creating it on first use (atomic no-clobber, 0600).
bor_key() {
  local f t k; f="$(_consent_root)/baseline-override.key"
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

# bor_hmac <canonical>
bor_hmac() {
  local k h; command -v openssl >/dev/null 2>&1 || return 1
  k="$(bor_key)" || return 1
  h="$(printf '%s' "$1" | openssl dgst -sha256 -hmac "$k" 2>/dev/null | awk '{print $NF}')" || return 1
  [ "${#h}" -eq 64 ] || return 1
  printf '%s' "$h"
}

# bor_canonical <repo> <branch> <base_sha> <waived \n-joined> <question> <answer> <sid> <ts>
bor_canonical() { printf '1\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s' "$@"; }

# bor_write <repo> <branch> <base_sha> <waived \n-joined> <question> <answer> <sid> <ts>
bor_write() {
  local p d t h; p="$(bor_record_path "$1" "$2")"; d="${p%/*}"
  h="$(bor_hmac "$(bor_canonical "$@")")" || return 1
  (umask 077; mkdir -p "$d" && t="$(mktemp "$d/.tmp.XXXXXX")" \
    && jq -n --arg repo "$1" --arg br "$2" --arg sha "$3" --arg w "$4" \
      --arg q "$5" --arg a "$6" --arg sid "$7" --arg ts "$8" --arg h "$h" \
      '{v:1,repo:$repo,branch:$br,base_sha:$sha,waived:($w|split("\n")),question:$q,answer:$a,session_id:$sid,captured_at:$ts,source:"askuserquestion-posttooluse",hmac:$h}' >"$t" \
    && mv "$t" "$p") 2>/dev/null || return 1
}

# bor_verify <record.json>: recompute the HMAC.
bor_verify() {
  local c h
  c="$(jq -j '"1\u001f"+([.repo,.branch,.base_sha,(.waived|join("\n")),.question,.answer,.session_id,.captured_at]|map(tostring)|join("\u001f"))' "$1" 2>/dev/null)" || return 1
  h="$(bor_hmac "$c")" || return 1
  [ "$h" = "$(jq -r '.hmac' "$1" 2>/dev/null)" ]
}

# bor_lookup <owner/repo> <branch>: print the record path; 0 only for a verified match.
bor_lookup() {
  local p; p="$(bor_record_path "$1" "$2")"
  [ -f "$p" ] && [ ! -L "$p" ] || return 1
  [ "$(jq -r '.repo' "$p" 2>/dev/null)" = "$1" ] && [ "$(jq -r '.branch' "$p" 2>/dev/null)" = "$2" ] || return 1
  bor_verify "$p" || return 1
  printf '%s' "$p"
}
