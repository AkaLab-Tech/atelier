#!/usr/bin/env bash
#
# Structural regression guard for #442 — every real shell invocation of
# `claude plugin (install|update|marketplace add|marketplace update)` under
# scripts/, install.sh and bootstrap.sh must carry CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1
# on the same logical command (env-var assignment before `claude`).
#
# Rationale: Claude Code clones `github`-shorthand plugin sources over SSH on
# `claude plugin update` unless that env var is set; atelier hosts are HTTPS-only
# (no SSH keys), so an unguarded call fails with "Permission denied (publickey)".
#
# "Real invocation" = `claude plugin ...` is the command token: everything
# before it on the line is only whitespace, `if `/`! `/`( `/`{ `/`&& `/`|| `
# and VAR=value assignments. Comments, quoted strings (warn/sublog/die/
# push_fix_auto text), backtick prose and heredoc prose are therefore ignored.
# This is stricter than is_real_invocation in atelier-update-plugin-stdin.test.sh,
# which would flag `warn "  claude plugin install ..."` (install.sh manual
# fallback hint) as a command.
#
# Static: pure source scan, no claude, no network.
#
# Run:  hooks/tests/claude-plugin-prefer-https.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "claude plugin invocations must set CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1 (#442)"

PREFIX_RE='^[[:space:]]*((if|!|\(|\{|&&|\|\|)[[:space:]]+)*([A-Za-z_][A-Za-z0-9_]*=("[^"]*"|[^[:space:]]*)[[:space:]]+)*$'
VERB_RE='claude plugin (install|update|marketplace add|marketplace update)([[:space:]]|$)'

# is_real_invocation LINE — 0 when `claude plugin <verb>` is the command token.
is_real_invocation() {
  local text="$1" prefix
  [[ "$text" =~ ^[[:space:]]*# ]] && return 1
  [[ "$text" =~ $VERB_RE ]] || return 1
  prefix="${text%%claude plugin *}"
  [[ "$prefix" =~ $PREFIX_RE ]]
}

# has_https_env LOGICAL — 0 when the env assignment is present.
has_https_env() { [[ "$1" == *"CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1 "* ]]; }

# ---------------------------------------------------------------------------
# Negative self-tests on synthetic lines (proves the guard can fail and that
# prose is not mistaken for a command).
# ---------------------------------------------------------------------------
bad='  CLAUDE_CONFIG_DIR="$cfg" claude plugin update "$id" </dev/null'
good='  CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1 CLAUDE_CONFIG_DIR="$cfg" claude plugin update "$id" </dev/null'
if is_real_invocation "$bad" && ! has_https_env "$bad"; then
  pass "self-test: an unguarded synthetic invocation is flagged"
else
  fail "self-test: unguarded synthetic invocation was NOT flagged"
fi
if is_real_invocation "$good" && has_https_env "$good"; then
  pass "self-test: a guarded synthetic invocation passes"
else
  fail "self-test: guarded synthetic invocation misclassified"
fi
if is_real_invocation '  if claude plugin install "$id" </dev/null; then'; then
  pass "self-test: 'if claude plugin install' is a real invocation"
else
  fail "self-test: 'if claude plugin install' not recognised as an invocation"
fi
for prose in \
  '  warn "  claude plugin install ${id}"' \
  '  local retry="claude plugin update $id"' \
  '  # claude plugin update here' \
  '  - `claude plugin update` refreshes the cache' \
  '    || die "claude plugin install ${PLUGIN_ID} failed"' \
  '  push_fix_auto "claude plugin install $plugin_id"'; do
  if is_real_invocation "$prose"; then
    fail "self-test: prose misclassified as invocation: $prose"
  else
    pass "self-test: prose ignored: ${prose# }"
  fi
done

# ---------------------------------------------------------------------------
# Real scan. Logical command = the line plus a following line while the
# current one ends in a backslash continuation.
# ---------------------------------------------------------------------------
files=("$REPO_ROOT/install.sh" "$REPO_ROOT/bootstrap.sh")
for f in "$REPO_ROOT"/scripts/*; do [ -f "$f" ] && files+=("$f"); done

found=0
offenders=()
for file in "${files[@]}"; do
  while IFS=':' read -r lineno _; do
    text="$(sed -n "${lineno}p" "$file")"
    is_real_invocation "$text" || continue
    found=$((found + 1))
    logical="$text"
    if [[ "$text" =~ \\[[:space:]]*$ ]]; then
      logical="$text $(sed -n "$((lineno + 1))p" "$file")"
    fi
    has_https_env "$logical" \
      || offenders+=("${file#"$REPO_ROOT"/}:$lineno: missing CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1 — ${text# }")
  done < <(grep -nE 'claude plugin (install|update|marketplace add|marketplace update)' "$file" || true)
done

if [ "${#offenders[@]}" -eq 0 ]; then
  pass "all $found real 'claude plugin' invocations carry CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1"
else
  for o in "${offenders[@]}"; do fail "$o"; done
fi
# Sanity: the scan must actually see the known call sites (atelier-update,
# 3 setup-* helpers x2, bootstrap x2, install.sh x2 = at least 10).
if [ "$found" -ge 10 ]; then
  pass "scan saw $found real invocations (matcher is not over-excluding)"
else
  fail "scan saw only $found real invocations, expected >= 10 (matcher over-excluding?)"
fi

echo
if [ "$fails" -eq 0 ]; then echo "All claude-plugin-prefer-https checks passed."; exit 0
else echo "$fails claude-plugin-prefer-https check(s) FAILED."; exit 1; fi
