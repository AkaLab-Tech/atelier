#!/usr/bin/env bash
#
# Structural regression guard — every invocation of `claude plugin (update|install|uninstall)`
# under scripts/ must redirect stdin from /dev/null on the same logical command.
#
# Rationale: `claude plugin update/install/uninstall` emits an interactive confirmation
# prompt; without </dev/null the command blocks forever when stdin is a terminal,
# hanging atelier-update's plugin-cache refresh and any non-interactive setup run.
# (Bug reproduced 2026-06-24 — see .plan/29.md root-cause section.)
#
# Static guard: no runtime `claude` or network needed — pure grep/bash source scan.
# Auto-discovered by .github/workflows/structural.yml "hooks/tests regression suite".
#
# Run:  hooks/tests/atelier-update-plugin-stdin.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "atelier-update plugin stdin regression — every mutating 'claude plugin' invocation must have </dev/null"

# ---------------------------------------------------------------------------
# is_real_invocation LINE_TEXT
#   Returns 0 (true) when the line text is a real shell invocation of a
#   mutating claude plugin verb — not a comment, not a string literal inside
#   a sublog/warn/die/push_fix_auto argument.
#
#   A real invocation has `claude` as the command token: it is immediately
#   preceded on the line by only whitespace, `if `, `( `, or env-var
#   assignments (WORD=VALUE sequences).  String-literal mentions have `claude`
#   preceded by a `"` or `'` (they are inside a quoted argument).
# ---------------------------------------------------------------------------
is_real_invocation() {
  local text="$1"

  # Exclude comment lines (leading optional whitespace then #)
  if [[ "$text" =~ ^[[:space:]]*# ]]; then
    return 1
  fi

  # Exclude push_fix_auto suggestion literals (atelier-doctor prints these as
  # strings to the operator — they are never executed by the script).
  if [[ "$text" == *push_fix_auto* ]]; then
    return 1
  fi

  # Exclude lines where "claude plugin" appears inside a double-quoted string.
  # Heuristic: if the substring `"claude plugin` appears, it is a string
  # argument (sublog/warn/die), not an invocation.
  if [[ "$text" == *'"claude plugin'* ]]; then
    return 1
  fi

  # Exclude backtick-quoted references in heredoc/usage prose
  if [[ "$text" == *'`claude plugin'* ]]; then
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# scan_scripts — main assertion loop
#
# For every file matching scripts/atelier-* that contains a mutating verb
# (update|install|uninstall), collect line-number:text pairs and check each
# real invocation for </dev/null.
#
# Continuation lines: when a real-invocation line ends with \, read the next
# line too and check the combined logical command. This handles:
#   CLAUDE_CONFIG_DIR=... claude plugin install "$PLUGIN_ID" </dev/null \
#     || die ...
# ---------------------------------------------------------------------------
offenders=()

while IFS='' read -r match_line; do
  file="${match_line%%:*}"
  rest="${match_line#*:}"
  lineno="${rest%%:*}"
  text="${rest#*:}"

  if ! is_real_invocation "$text"; then
    continue
  fi

  # Build the logical command: if line ends with \, grab the next line too
  logical="$text"
  if [[ "$text" =~ \\[[:space:]]*$ ]]; then
    nextline="$(sed -n "$((lineno + 1))p" "$file" 2>/dev/null || true)"
    logical="${text}${nextline}"
  fi

  # Assert </dev/null is present somewhere in the logical command
  if [[ "$logical" != *"</dev/null"* ]]; then
    offenders+=("$file:$lineno: missing </dev/null — $text")
  fi

done < <(grep -rn 'claude plugin \(update\|install\|uninstall\)' "$REPO_ROOT/scripts/atelier-"*)

# Report
if [ "${#offenders[@]}" -eq 0 ]; then
  pass "all mutating 'claude plugin' invocations under scripts/ redirect stdin from /dev/null"
else
  for o in "${offenders[@]}"; do
    fail "$o"
  done
fi

# ---------------------------------------------------------------------------
# Negative check: push_fix_auto literals in atelier-doctor must NOT be flagged.
# Scan only atelier-doctor for push_fix_auto lines containing mutating verbs
# and verify they are all excluded by is_real_invocation.
# ---------------------------------------------------------------------------
doctor="$REPO_ROOT/scripts/atelier-doctor"
if [ -f "$doctor" ]; then
  false_pos=0
  while IFS='' read -r match_line; do
    text="${match_line#*:*:}"
    if is_real_invocation "$text"; then
      false_pos=$((false_pos + 1))
    fi
  done < <(grep -n 'claude plugin \(update\|install\|uninstall\)' "$doctor" || true)

  if [ "$false_pos" -eq 0 ]; then
    pass "atelier-doctor suggestion strings correctly excluded (no false positives)"
  else
    fail "atelier-doctor strings were NOT excluded ($false_pos false positive(s))"
  fi
else
  fail "atelier-doctor not found at $doctor"
fi

# ---------------------------------------------------------------------------
# Positive check: atelier-uninstall's already-correct call must register as
# a real invocation AND pass the </dev/null check. Confirms the matcher
# recognises the established precedent.
# ---------------------------------------------------------------------------
uninstall="$REPO_ROOT/scripts/atelier-uninstall"
if [ -f "$uninstall" ]; then
  precedent_found=0
  precedent_has_null=0
  while IFS='' read -r match_line; do
    text="${match_line#*:}"
    if is_real_invocation "$text"; then
      precedent_found=$((precedent_found + 1))
      if [[ "$text" == *"</dev/null"* ]]; then
        precedent_has_null=$((precedent_has_null + 1))
      fi
    fi
  done < <(grep -n 'claude plugin uninstall' "$uninstall" || true)

  if [ "$precedent_found" -gt 0 ] && [ "$precedent_has_null" -eq "$precedent_found" ]; then
    pass "atelier-uninstall precedent correctly detected and passes </dev/null check"
  elif [ "$precedent_found" -eq 0 ]; then
    fail "atelier-uninstall: no real uninstall invocation found (matcher may be over-excluding)"
  else
    fail "atelier-uninstall: invocation found but missing </dev/null ($precedent_found found, $precedent_has_null with </dev/null)"
  fi
else
  fail "atelier-uninstall not found at $uninstall"
fi

# ---------------------------------------------------------------------------
# Negative check: read-only `claude plugin list` calls are structurally
# excluded because they don't match the mutating-verb grep pattern. Confirm
# no list hits survive into the offenders list (they can't, by grep design).
# ---------------------------------------------------------------------------
pass "claude plugin list calls excluded by mutating-verb grep pattern (structural)"

echo
if [ "$fails" -eq 0 ]; then
  echo "All plugin-stdin regression checks passed."
  exit 0
else
  echo "$fails plugin-stdin regression check(s) FAILED."
  exit 1
fi
