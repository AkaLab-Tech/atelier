#!/usr/bin/env bash
#
# Regression test for #37 — /atelier:update's permission-diff confirmation
# must actually be reachable when the helper runs without a TTY (audit#72).
#
# Bug: commands/update.md claimed "Invoking via the slash command goes
# through Claude Code's I/O, which is interactive by construction — the
# prompt always resolves cleanly." False — the confirmation prompt lives
# inside scripts/atelier-update behind `if [ -t 0 ]; then ... read -r ans
# ...`, and a slash command's Bash tool calls never have a TTY on stdin, so
# every /atelier:update run touching templates/settings.template.json fell
# straight into the non-interactive refusal branch. The documented "apply
# or revert based on the operator's response" flow could never execute.
#
# Fix: scripts/atelier-update gained a --yes/-y flag a non-TTY caller can
# pass to apply a pending permission change explicitly; commands/update.md
# dropped the false claim, added AskUserQuestion to allowed-tools, and
# added a "No-TTY fallback" section (detect the helper's refusal -> show
# the diff -> AskUserQuestion -> re-invoke with --yes on accept).
#
# Assertions:
#   Group 1 — the false claim is gone from commands/update.md
#   Group 2 — allowed-tools frontmatter includes AskUserQuestion
#   Group 3 — the No-TTY fallback section is documented and names --yes
#   Group 4 — scripts/atelier-update accepts --yes/-y (arg-parse loop +
#             usage()/--help output), proved BEHAVIORALLY via --help and an
#             unknown-flag rejection, run in a sandboxed HOME/env
#   Group 5 — fail-safe preserved: non-interactive + no flag still refuses
#             (refusal warning string, APPLY_SETTINGS=false, and the
#             [ -t 0 ] interactive branch are all still present in the
#             script) — a future change defaulting to "apply" must break
#             this test
#
# Hermetic: static prose/source assertions plus two `--help`/unknown-arg
# invocations of the real script under a scratch $HOME and no network-
# reachable config. No git pull, no `claude plugin update`, no writes
# outside a mktemp -d sandbox cleaned up on exit.
#
# Run:  hooks/tests/atelier-update-no-tty-prompt.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPDATE_MD="$REPO_ROOT/commands/update.md"
UPDATE_SH="$REPO_ROOT/scripts/atelier-update"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "atelier-update no-TTY permission-diff confirmation (#37 / audit#72)"

# chk_prose <file> <fixed-string> <label> — passes when the string IS present.
# `--` guards patterns starting with `-` (e.g. "--yes") from being parsed as
# grep options.
chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF -- "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

# chk_absent <file> <fixed-string> <label> — passes when the string is ABSENT.
chk_absent() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF -- "$pattern" "$file" 2>/dev/null; then
    fail "$label — token '$pattern' found but should be absent in $file"
  else
    pass "$label"
  fi
}

if [ ! -f "$UPDATE_MD" ]; then
  fail "commands/update.md not found at $UPDATE_MD"
fi
if [ ! -f "$UPDATE_SH" ]; then
  fail "scripts/atelier-update not found at $UPDATE_SH"
fi

# ---------------------------------------------------------------------------
# Group 1 — the false "interactive by construction" claim is gone.
# ---------------------------------------------------------------------------
chk_absent "$UPDATE_MD" 'interactive by construction' \
  "false-claim: 'interactive by construction' phrasing absent from commands/update.md"

chk_absent "$UPDATE_MD" 'the prompt always resolves cleanly' \
  "false-claim: 'the prompt always resolves cleanly' claim absent from commands/update.md"

# ---------------------------------------------------------------------------
# Group 2 — allowed-tools frontmatter includes AskUserQuestion.
# ---------------------------------------------------------------------------
ALLOWED_TOOLS_LINE="$(grep -m1 '^allowed-tools:' "$UPDATE_MD" 2>/dev/null || true)"
if [ -n "$ALLOWED_TOOLS_LINE" ] && printf '%s' "$ALLOWED_TOOLS_LINE" | grep -qF 'AskUserQuestion'; then
  pass "frontmatter: allowed-tools includes AskUserQuestion"
else
  fail "frontmatter: allowed-tools missing AskUserQuestion (line: ${ALLOWED_TOOLS_LINE:-<absent>})"
fi

# ---------------------------------------------------------------------------
# Group 3 — the No-TTY fallback is documented and names the apply flag.
# ---------------------------------------------------------------------------
if grep -qE 'No-TTY fallback' "$UPDATE_MD" 2>/dev/null; then
  pass "docs: a 'No-TTY fallback' section heading is present in commands/update.md"
else
  fail "docs: no section heading matching /No-TTY fallback/ found in commands/update.md"
fi

chk_prose "$UPDATE_MD" '--yes' \
  "docs: No-TTY fallback documentation references the --yes apply flag"

chk_prose "$UPDATE_MD" 'AskUserQuestion' \
  "docs: fallback flow is described as going through AskUserQuestion"

# ---------------------------------------------------------------------------
# Group 4 — scripts/atelier-update behaviorally accepts --yes/-y.
# Sandboxed HOME; --help and an unknown flag need no config/network/git.
# ---------------------------------------------------------------------------
help_out="$(HOME="$HOME_DIR" bash "$UPDATE_SH" --help 2>&1)"
help_rc=$?
[ "$help_rc" -eq 0 ] \
  && pass "--help exits 0" \
  || fail "--help rc=$help_rc (out: $help_out)"

printf '%s' "$help_out" | grep -qE -- '--yes,? -y' \
  && pass "--help lists the --yes/-y apply flag in OPTIONS" \
  || fail "--help does not list --yes/-y (out: $help_out)"

unknown_out="$(HOME="$HOME_DIR" bash "$UPDATE_SH" --this-flag-does-not-exist 2>&1)"
unknown_rc=$?
[ "$unknown_rc" -ne 0 ] \
  && pass "unrecognized flag still rejected (rc=$unknown_rc)" \
  || fail "unrecognized flag was NOT rejected (rc=$unknown_rc, out: $unknown_out)"

printf '%s' "$unknown_out" | grep -qF 'unknown arg' \
  && pass "unrecognized flag reports 'unknown arg'" \
  || fail "no 'unknown arg' message for a bad flag (out: $unknown_out)"

# Source-level corroboration: the flag is wired into the arg-parse loop
# itself, not just documented in usage().
if grep -qE -- '--yes\|-y\)[[:space:]]*ASSUME_YES=true' "$UPDATE_SH"; then
  pass "source: --yes|-y is wired into the arg-parse loop (sets ASSUME_YES=true)"
else
  fail "source: no '--yes|-y) ASSUME_YES=true' arm found in the arg-parse loop"
fi

# ---------------------------------------------------------------------------
# Group 5 — fail-safe preserved: non-interactive + no flag still refuses.
# Static source assertions per the task spec (reproducing the real permission-
# diff prompt end-to-end needs a git history fixture; the invariants below
# are exactly what a future "make --yes the default" regression would break).
# ---------------------------------------------------------------------------
chk_prose "$UPDATE_SH" 'non-interactive mode: refusing to apply permission changes without confirmation' \
  "fail-safe: refusal warning string still present in scripts/atelier-update"

chk_prose "$UPDATE_SH" 'APPLY_SETTINGS=false' \
  "fail-safe: APPLY_SETTINGS=false assignment still present"

if grep -qE '\[ -t 0 \]' "$UPDATE_SH"; then
  pass "fail-safe: the [ -t 0 ] interactive-TTY branch is still present"
else
  fail "fail-safe: no [ -t 0 ] check found — interactive branch may have been removed"
fi

# The refusal must remain reachable in the non-flag path, i.e. ASSUME_YES is
# checked (elif/else) rather than having replaced the [ -t 0 ] gate outright.
if grep -qE 'if \$ASSUME_YES; then' "$UPDATE_SH" && grep -qE 'elif \[ -t 0 \]; then' "$UPDATE_SH"; then
  pass "fail-safe: --yes is an explicit opt-in gate ahead of (not a replacement for) the TTY check"
else
  fail "fail-safe: --yes does not sit as an 'if ASSUME_YES ... elif [ -t 0 ]' gate ahead of the TTY check"
fi

echo ""
if [ "$fails" -eq 0 ]; then
  echo "atelier-update-no-tty-prompt: all assertions passed."
  exit 0
else
  echo "atelier-update-no-tty-prompt: $fails assertion(s) failed."
  exit 1
fi
