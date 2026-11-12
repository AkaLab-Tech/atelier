#!/usr/bin/env bash
#
# atelier — shared `.env*` file-name classification for the env hooks
# (block-env-read, block-env-commit, scan-git-add). The template-suffix list
# lives ONLY here; a hook that hardcodes the alternation fails the drift guard
# in hooks/tests/env-template-exemption.test.sh.
#
# Sourced from each hook script, e.g.:
#   # shellcheck source=lib/env-names.sh
#   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/env-names.sh"
#
# A template is a `.env*` name whose FINAL dot-component is one of the
# suffixes: `.env.example`, `.env.catalog.example` pass; `.env.example.local`,
# `.env.prod`, `.envrc` do not. Matching is case-insensitive.

export ENV_TEMPLATE_SUFFIXES="example sample template dist"
export ENV_TEMPLATE_SUFFIX_ERE='\.('"${ENV_TEMPLATE_SUFFIXES// /|}"')$'

# 0 when the basename of $1 is `.env` or starts with `.env`.
env_is_env_name() {
  local b="${1##*/}"
  case "$b" in
    .[eE][nN][vV]|.[eE][nN][vV]*) return 0 ;;
  esac
  return 1
}

# 0 when $1 is an env name whose final suffix is a template suffix.
env_is_template_name() {
  local b="${1##*/}" lb s
  env_is_env_name "$b" || return 1
  lb="$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')"
  for s in $ENV_TEMPLATE_SUFFIXES; do
    case "$lb" in
      *."$s") return 0 ;;
    esac
  done
  return 1
}

# 0 when $1 is an env name that is not a template (a real secret file).
env_is_protected_name() {
  env_is_env_name "$1" && ! env_is_template_name "$1"
}

# Replaces `;`, `|`, `&` inside quoted strings with \001/\002/\003 so the
# segment split below keeps a quoted `sed 's|a|b|'` script in one piece. Only
# for a single-line command whose quotes balance (a multi-line or unbalanced
# command is returned untouched and split as before, so a stray quote can never
# hide a real separator).
env_mask_quoted_separators() {
  case "$1" in *$'\n'*) printf '%s' "$1"; return 0 ;; esac
  printf '%s' "$1" | awk '{
    n = length($0); out = ""; q = ""
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (q == "") {
        if (c == "\\") { out = out c substr($0, i + 1, 1); i++; continue }
        if (c == "\"" || c == "\047") q = c
        out = out c
        continue
      }
      if (c == q) { q = ""; out = out c; continue }
      if (q == "\"" && c == "\\") { out = out c substr($0, i + 1, 1); i++; continue }
      if (c == ";") c = "\001"
      else if (c == "|") c = "\002"
      else if (c == "&") c = "\003"
      out = out c
    }
    if (q != "") print $0; else print out
  }'
}

# ---- `git add|commit --pathspec-from-file` helpers -----------------------

# Recognises git's `--pathspec-from-file` in every spelling parse-options
# accepts: the full name or an unambiguous abbreviation (`--pathspec-fr` ..
# `--pathspec-from-file`), with `=value` or the value as the next word.
# `--pathspec-f`/`--pathspec-fi..` are ambiguous or the NUL flag: not this option.
#   $1 = word, $2 = next word (optional)
#   prints the value ("-" = stdin); exit 0 value inline, exit 2 value taken
#   from $2 (the caller skips it), exit 1 not this option.
env_pathspec_file_opt() {
  local w="$1" next="${2-}" name full="--pathspec-from-file"
  case "$w" in --pathspec-fr*) ;; *) return 1 ;; esac
  name="${w%%=*}"
  case "$full" in "$name"*) ;; *) return 1 ;; esac
  case "$w" in
    *=*) printf '%s\n' "${w#*=}"; return 0 ;;
    *) printf '%s\n' "$next"; return 2 ;;
  esac
}

# 0 when $1 is `--pathspec-file-nul` or an abbreviation of it (`--pathspec-fi`..).
env_pathspec_nul_opt() {
  local name="${1%%=*}" full="--pathspec-file-nul"
  case "$1" in --pathspec-fi*) ;; *) return 1 ;; esac
  case "$full" in "$name"*) return 0 ;; esac
  return 1
}

# Prints the entries of the pathspec file $2, resolved against dir $1 (git
# resolves the file after -C), splitting on NUL ($3 = 1) or newline and
# removing the C-style quotes git accepts in newline mode. Returns 1
# (unresolvable, callers fail closed) for stdin, /dev/fd, process
# substitution, a value with `$`, a glob or a backtick, an env-named file, a
# missing or unreadable file, or a FIFO or other non-regular file.
env_pathspec_entries() {
  local dir="$1" f="$2" nul="${3:-0}" full line
  case "$f" in
    ''|-|/dev/stdin|/dev/fd/*|/proc/*|*'<('*|*'>('*|*\$*|*\`*|*[\*\?\[]*) return 1 ;;
  esac
  env_is_env_name "$f" && return 1
  case "$f" in /*) full="$f" ;; *) full="$dir/$f" ;; esac
  [ -f "$full" ] && [ -r "$full" ] || return 1
  if [ "$nul" = 1 ]; then
    tr '\0' '\n' < "$full"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [ -n "$line" ] || continue
    case "$line" in
      \"*\")
        line="${line#\"}"; line="${line%\"}"
        line="$(printf '%s' "$line" | sed -E 's/\\([0-7]{3})/\\0\1/g')"
        line="$(printf '%b' "$line")"
        ;;
    esac
    printf '%s\n' "$line"
  done < "$full"
}

# Prints every env-named path git could stage or commit in dir $1, deletions
# left out: untracked INCLUDING ignored files (no --exclude-standard: install.sh
# puts the env globs in the global excludes, which would hide exactly these),
# plus modified and staged ones.
env_dirty_env_files() {
  local d="$1" p
  {
    git -C "$d" ls-files --others -- ':(glob,icase)**/.env*' 2>/dev/null || true
    git -C "$d" diff --name-only --diff-filter=d 2>/dev/null || true
    git -C "$d" diff --cached --name-only --diff-filter=d 2>/dev/null || true
  } | while IFS= read -r p; do
    env_is_env_name "$p" && printf '%s\n' "$p"
  done
  return 0
}
