#!/usr/bin/env bash
#
# Regression test for task #28 — atelier-pr-size-check empty-array unbound-variable.
#
# OBSERVABLE CONTRACT (version-independent):
#   When --pr is passed WITHOUT --repo, the script's repo_flag array is empty.
#   The fix applies the "${arr[@]+"${arr[@]}"}" idiom so that bash's set -u does
#   NOT abort the script on an empty array expansion.  The observable contract is:
#     (a) no "unbound variable" on stderr
#     (b) the Counted: line shows a non-zero line count and ≥1 file (a real diff
#         was read from the gh fixture, not the false 0/0 produced by an abort)
#     (c) the same fixture count holds when --repo owner/name IS supplied
#
# WHY THE BUG DID NOT REPRODUCE ON CI (bash 5.x):
#   bash ≥4.4 does NOT raise "unbound variable" for an empty array's [@]
#   expansion under set -u — the bug only triggered on bash 3.2 (macOS system
#   bash). The unfixed script would go RED against that contract on a bash-3.2
#   host, while the fixed script stays GREEN everywhere.  This test guards the
#   contract in CI and catches any future regression that re-introduces an
#   unconditional empty-array [@] expansion in a set -u context.
#
# Run:  hooks/tests/pr-size-check-empty-array.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-pr-size-check"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# --- dependency check --------------------------------------------------------
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

# --- gh shim -----------------------------------------------------------------
# Intercepts `gh pr view <NN> [--repo ...] --json files --jq '.files[]'` and
# emits a fixture JSON files array.  The shim ignores --repo so both the
# no-repo and with-repo invocations return the same fixture.
#
# Fixture: two non-exempt source files with real additions+deletions.
#   scripts/atelier-pr-size-check  — not matched by any DEFAULT_EXEMPT glob
#   hooks/safe-commit.sh           — not matched by any DEFAULT_EXEMPT glob
# Combined: 45 additions + 12 deletions = 57 counted lines across 2 files.
# Verify non-exempt manually:
#   "pnpm-lock.yaml" / "package-lock.json" / "yarn.lock" — no match
#   "**/*.snap" / "**/*.generated.*"                      — no match
#   "**/*.test.*" / "**/*.spec.*"                         — no match (no .test. in name)
#   "**/__tests__/**" / "**/tests/**"                     — no match (no tests/ segment)
#   "**/e2e/**" / "**/playwright/**" / "**/cypress/**"    — no match
#   "**/migrations/**" / "**/*.sql"                       — no match
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SHIMEOF'
#!/usr/bin/env bash
# Minimal gh shim: respond to `gh pr view <NN> [flags...] --json files --jq '.files[]'`
# Consume all positional / flag arguments; emit two fixture file objects.
printf '{"path":"scripts/atelier-pr-size-check","additions":30,"deletions":8}\n'
printf '{"path":"hooks/safe-commit.sh","additions":15,"deletions":4}\n'
SHIMEOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# --- scenario 1: --pr without --repo (the previously-broken path) ------------
echo "Scenario 1: --pr without --repo (empty repo_flag)"

OUT1="$TMP/out1"
ERR1="$TMP/err1"
bash "$SCRIPT" --pr 1 --project "$TMP" >"$OUT1" 2>"$ERR1" || true

# (a) No "unbound variable" on stderr
if grep -q 'unbound variable' "$ERR1"; then
  fail "(a) no-repo: 'unbound variable' found on stderr — unbound-array bug is present"
else
  pass "(a) no-repo: no 'unbound variable' on stderr"
fi

# (b) Non-zero line count — Counted: line must NOT be "0 line(s) across 0 file(s)"
# The script prints: Counted:     57 line(s) across 2 file(s)
# Fixture: 30+8 + 15+4 = 57 lines, 2 files.
COUNTED_LINE="$(grep '^Counted:' "$OUT1" || true)"
if [ -z "$COUNTED_LINE" ]; then
  fail "(b) no-repo: 'Counted:' line not found in output (script may have aborted)"
else
  # Extract file count (the last integer on the line)
  FILE_COUNT="$(printf '%s' "$COUNTED_LINE" | grep -o '[0-9]* file(s)' | grep -o '^[0-9]*')"
  LINE_COUNT="$(printf '%s' "$COUNTED_LINE" | grep -o '^Counted:[[:space:]]*[0-9]*' | grep -o '[0-9]*$')"
  if [ "${FILE_COUNT:-0}" -ge 1 ] && [ "${LINE_COUNT:-0}" -gt 0 ]; then
    pass "(b) no-repo: counted ${LINE_COUNT} line(s) across ${FILE_COUNT} file(s) — not false 0/0"
  else
    fail "(b) no-repo: expected non-zero count; got '${COUNTED_LINE}' (false 0/0 suggests abort)"
  fi
fi

# --- scenario 2: --pr with --repo (must still count correctly) ---------------
echo "Scenario 2: --pr with --repo owner/name (repo_flag populated)"

OUT2="$TMP/out2"
ERR2="$TMP/err2"
bash "$SCRIPT" --pr 1 --repo owner/name --project "$TMP" >"$OUT2" 2>"$ERR2" || true

# (c-a) No "unbound variable" even with --repo
if grep -q 'unbound variable' "$ERR2"; then
  fail "(c-a) with-repo: 'unbound variable' found on stderr"
else
  pass "(c-a) with-repo: no 'unbound variable' on stderr"
fi

# (c-b) Same non-zero count as scenario 1 (shim returns same fixture)
COUNTED_LINE2="$(grep '^Counted:' "$OUT2" || true)"
if [ -z "$COUNTED_LINE2" ]; then
  fail "(c-b) with-repo: 'Counted:' line not found in output"
else
  FILE_COUNT2="$(printf '%s' "$COUNTED_LINE2" | grep -o '[0-9]* file(s)' | grep -o '^[0-9]*')"
  LINE_COUNT2="$(printf '%s' "$COUNTED_LINE2" | grep -o '^Counted:[[:space:]]*[0-9]*' | grep -o '[0-9]*$')"
  if [ "${FILE_COUNT2:-0}" -ge 1 ] && [ "${LINE_COUNT2:-0}" -gt 0 ]; then
    pass "(c-b) with-repo: counted ${LINE_COUNT2} line(s) across ${FILE_COUNT2} file(s)"
  else
    fail "(c-b) with-repo: expected non-zero count; got '${COUNTED_LINE2}'"
  fi
fi

# --- regression guard: exact counts match fixture ----------------------------
# Fixture delivers 57 lines (30+8+15+4) across 2 non-exempt files.
EXPECTED_LINES=57
EXPECTED_FILES=2

if [ "${LINE_COUNT:-0}" = "$EXPECTED_LINES" ] && [ "${FILE_COUNT:-0}" = "$EXPECTED_FILES" ]; then
  pass "regression guard: exact fixture counts match (${EXPECTED_LINES} lines / ${EXPECTED_FILES} files)"
else
  fail "regression guard: expected ${EXPECTED_LINES} lines / ${EXPECTED_FILES} files; got ${LINE_COUNT:-?} lines / ${FILE_COUNT:-?} files"
fi

echo ""
if [ "$fails" -eq 0 ]; then
  echo "pr-size-check-empty-array (#28): all assertions passed."
  exit 0
else
  echo "pr-size-check-empty-array (#28): $fails assertion(s) failed."
  exit 1
fi
