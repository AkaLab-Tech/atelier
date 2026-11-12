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
