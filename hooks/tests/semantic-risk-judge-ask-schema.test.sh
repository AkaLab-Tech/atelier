#!/usr/bin/env bash
#
# Regression test for task #127/#128 — semantic-risk-judge.sh's "ask" verdict
# must emit the CONTRACT-CORRECT nested PreToolUse permission-decision shape:
#   {hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", ...}}
# and NOT the invalid top-level shape `{permissionDecision:"ask",...}` that
# Claude Code silently degrades to allow (an "ask" that never asks). "ask" is
# this hook's ONLY effect (it never hard-blocks), so this is the entire
# behavioural surface under test.
#
# Fully offline: a `claude` STUB is put first on PATH so the hook never makes
# a real model call. The stub answers the way the real `claude -p ... --output
# -format json` invocation would: a JSON envelope whose `.result` is itself a
# JSON-encoded string `{"decision":...,"reason":...}` (see
# semantic-risk-judge.sh's verdict parsing: `.result` then `.result.decision`
# / `.result.reason`).
#
# Two cases in this file:
#   1. stub decision=ask   -> hook emits the nested ask JSON on stdout.
#   2. stub decision=allow -> hook emits NOTHING on stdout (allow is silent).
#
# The judged command (`echo x >> pnpm-lock.yaml`) must land on the hook's
# high-risk catalogue so it actually reaches the model-call step instead of
# short-circuiting at the local risk-gate. Confirmed against
# hooks/patterns/semantic-risk-judge.json: pattern "lockfile-touch" ->
# `pnpm-lock\.ya?ml|package-lock\.json|yarn\.lock`, riskClass
# "dependency-lock" — `pnpm-lock.yaml` in the command string matches.
#
# Run:  hooks/tests/semantic-risk-judge-ask-schema.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/semantic-risk-judge.sh"
PATTERNS_FILE="$REPO_ROOT/hooks/patterns/semantic-risk-judge.json"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

# --- sanity: the judged command actually hits the high-risk catalogue -------
if jq -e '.patterns[] | select(.name == "lockfile-touch") | .pattern' "$PATTERNS_FILE" >/dev/null 2>&1; then
  pass "sanity: semantic-risk-judge.json still carries a lockfile-touch pattern"
else
  fail "sanity: lockfile-touch pattern missing from $PATTERNS_FILE — judged surface assumption broken"
fi

# --- fake project dir: opts in via .atelier.json ----------------------------
FAKEPROJ="$TMP/fakeproj"
mkdir -p "$FAKEPROJ"
printf '{"semanticRiskJudge":{"enabled":true}}\n' > "$FAKEPROJ/.atelier.json"

payload='{"tool_name":"Bash","tool_input":{"command":"echo x >> pnpm-lock.yaml"}}'

# --- claude stub builder ------------------------------------------------------
# $1 = bin dir to create, $2 = decision, $3 = reason
make_claude_stub() {
  local dir="$1" decision="$2" reason="$3"
  mkdir -p "$dir"
  cat > "$dir/claude" <<STUBEOF
#!/usr/bin/env bash
# Fake claude CLI — offline stand-in for the Haiku judgement call. Ignores
# all args (-p <prompt> --model ... --output-format json --max-turns 1) and
# always answers the same verdict, matching --output-format json's envelope
# shape: {"result": "<json-encoded-string>"}.
printf '%s\n' '{"result":"{\\"decision\\":\\"${decision}\\",\\"reason\\":\\"${reason}\\"}"}'
STUBEOF
  chmod +x "$dir/claude"
}

# ===========================================================================
# Case 1: decision=ask -> nested ask JSON on stdout
# ===========================================================================
ASKBIN="$TMP/bin-ask"
make_claude_stub "$ASKBIN" "ask" "risky"

OUT1="$TMP/out1"
ERR1="$TMP/err1"
PATH="$ASKBIN:$PATH" \
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
CLAUDE_PROJECT_DIR="$FAKEPROJ" \
  bash "$HOOK" <<<"$payload" >"$OUT1" 2>"$ERR1"
code1=$?

if [ "$code1" -eq 0 ]; then
  pass "case 1 (ask): exit code 0"
else
  fail "case 1 (ask): expected exit code 0, got $code1 (stderr: $(cat "$ERR1"))"
fi

if jq -e '.hookSpecificOutput.permissionDecision == "ask" and .hookSpecificOutput.hookEventName == "PreToolUse"' "$OUT1" >/dev/null 2>&1; then
  pass "case 1 (ask): stdout is the nested {hookSpecificOutput:{hookEventName,permissionDecision:\"ask\"}} shape"
else
  fail "case 1 (ask): stdout did not match the nested ask shape — got: $(cat "$OUT1")"
fi

if jq -e '.permissionDecision == null' "$OUT1" >/dev/null 2>&1; then
  pass "case 1 (ask): top-level .permissionDecision is null (invalid top-level shape is gone)"
else
  fail "case 1 (ask): top-level .permissionDecision was NOT null — invalid shape still present: $(cat "$OUT1")"
fi

# ===========================================================================
# Case 2: decision=allow -> empty stdout (allow path emits no JSON at all)
# ===========================================================================
ALLOWBIN="$TMP/bin-allow"
make_claude_stub "$ALLOWBIN" "allow" "fine"

OUT2="$TMP/out2"
ERR2="$TMP/err2"
PATH="$ALLOWBIN:$PATH" \
CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
CLAUDE_PROJECT_DIR="$FAKEPROJ" \
  bash "$HOOK" <<<"$payload" >"$OUT2" 2>"$ERR2"
code2=$?

if [ "$code2" -eq 0 ]; then
  pass "case 2 (allow): exit code 0"
else
  fail "case 2 (allow): expected exit code 0, got $code2 (stderr: $(cat "$ERR2"))"
fi

if [ -s "$OUT2" ]; then
  fail "case 2 (allow): stdout expected EMPTY, got: $(cat "$OUT2")"
else
  pass "case 2 (allow): stdout is empty (allow path emits no JSON)"
fi

echo ""
if [ "$fails" -eq 0 ]; then
  echo "semantic-risk-judge-ask-schema (#127/#128): all assertions passed."
  exit 0
else
  echo "semantic-risk-judge-ask-schema (#127/#128): $fails assertion(s) failed."
  exit 1
fi
