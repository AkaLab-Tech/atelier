#!/usr/bin/env bash
#
# Test for hooks/version-drift-nudge.sh (#486): a UserPromptSubmit hook that
# nudges once per session when the atelier version the session loaded
# (CLAUDE_PLUGIN_ROOT) differs from the installed one
# ($ATELIER_CONFIG_DIR/plugins/installed_plugins.json). Fail-open everywhere.
#
# Run:  hooks/tests/version-drift-nudge.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/version-drift-nudge.sh"
BASH_BIN="$(command -v bash)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"; CFG="$TMP/cfg"; ROOT="$TMP/root"
mkdir -p "$HOME_DIR" "$CFG/plugins" "$ROOT/.claude-plugin"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

set_loaded()    { printf '{"name":"atelier","version":"%s"}\n' "$1" >"$ROOT/.claude-plugin/plugin.json"; }
set_installed() { printf '{"plugins":{"atelier@akalab-tech":[{"version":"%s"}]}}\n' "$1" >"$CFG/plugins/installed_plugins.json"; }

# run_hook <session_id|-> [env assignments...]: sets $out and $rc.
run_hook() {
  local sid="$1"; shift
  local payload='{}'
  [ "$sid" != "-" ] && payload="{\"session_id\":\"$sid\",\"prompt\":\"hi\"}"
  out="$(printf '%s' "$payload" | env HOME="$HOME_DIR" ATELIER_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_ROOT="$ROOT" "$@" "$BASH_BIN" "$HOOK" 2>/dev/null)"
  rc=$?
}

# --- equal versions -> silent ---
set_loaded 1.2.3; set_installed 1.2.3
run_hook s1
[ "$rc" = 0 ] && [ -z "$out" ] && pass "equal versions: silent, exit 0" || fail "equal versions: rc=$rc out=[$out]"

# --- different versions -> one nudge ---
set_installed 1.3.0
run_hook s1
[ "$rc" = 0 ] && pass "drift: exit 0" || fail "drift: rc=$rc"
[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)" = "UserPromptSubmit" ] \
  && pass "drift: hookEventName is UserPromptSubmit" || fail "drift: hookEventName wrong: [$out]"
sm="$(printf '%s' "$out" | jq -r '.systemMessage // empty' 2>/dev/null)"
ac="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
[ -n "$sm" ] && [ -n "$ac" ] && pass "drift: systemMessage and additionalContext present" || fail "drift: missing message fields"
ok=1
for needle in 1.2.3 1.3.0 /reload-plugins /atelier:refresh; do
  case "$sm" in *"$needle"*) ;; *) ok=0; fail "drift: systemMessage lacks '$needle'";; esac
  case "$ac" in *"$needle"*) ;; *) ok=0; fail "drift: additionalContext lacks '$needle'";; esac
done
[ "$ok" = 1 ] && pass "drift: both versions, /reload-plugins and /atelier:refresh named"
[ -e "$CFG/state/version-nudge/s1--1.3.0" ] && pass "drift: stamp written" || fail "drift: stamp missing"

# --- second prompt, same session + installed version -> silent ---
run_hook s1
[ "$rc" = 0 ] && [ -z "$out" ] && pass "second prompt same session: silent, exit 0" || fail "second prompt: rc=$rc out=[$out]"

# --- different session, same drift -> nudges again ---
run_hook s2
[ "$rc" = 0 ] && [ -n "$out" ] && pass "new session: nudges" || fail "new session: rc=$rc out=[$out]"

# --- newer installed version in the same session -> nudges again ---
set_installed 1.4.0
run_hook s1
case "$out" in *1.4.0*) pass "new installed version, same session: nudges again";; *) fail "new installed version: out=[$out]";; esac

# --- missing session_id -> silent ---
rm -rf "$CFG/state"
run_hook -
[ "$rc" = 0 ] && [ -z "$out" ] && pass "missing session_id: silent, exit 0" || fail "missing session_id: rc=$rc out=[$out]"
[ ! -e "$CFG/state/version-nudge" ] && pass "missing session_id: no stamp written" || fail "missing session_id: stamp dir created"

# --- missing files -> silent ---
set_loaded 1.2.3; set_installed 1.3.0
mv "$CFG/plugins/installed_plugins.json" "$CFG/plugins/installed_plugins.json.bak"
run_hook s3
[ "$rc" = 0 ] && [ -z "$out" ] && pass "no installed_plugins.json: silent, exit 0" || fail "no installed_plugins.json: rc=$rc out=[$out]"
mv "$CFG/plugins/installed_plugins.json.bak" "$CFG/plugins/installed_plugins.json"

mv "$ROOT/.claude-plugin/plugin.json" "$ROOT/.claude-plugin/plugin.json.bak"
run_hook s3
[ "$rc" = 0 ] && [ -z "$out" ] && pass "no plugin.json: silent, exit 0" || fail "no plugin.json: rc=$rc out=[$out]"
mv "$ROOT/.claude-plugin/plugin.json.bak" "$ROOT/.claude-plugin/plugin.json"

out="$(printf '{"session_id":"s3"}' | env -u CLAUDE_PLUGIN_ROOT HOME="$HOME_DIR" ATELIER_CONFIG_DIR="$CFG" "$BASH_BIN" "$HOOK" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "CLAUDE_PLUGIN_ROOT unset: silent, exit 0" || fail "CLAUDE_PLUGIN_ROOT unset: rc=$rc out=[$out]"

# --- unparsable manifest -> silent ---
printf 'not json' >"$CFG/plugins/installed_plugins.json"
run_hook s3
[ "$rc" = 0 ] && [ -z "$out" ] && pass "garbage installed_plugins.json: silent, exit 0" || fail "garbage manifest: rc=$rc out=[$out]"
set_installed 1.3.0

# --- jq missing -> silent ---
NOJQ="$TMP/nojq-bin"; mkdir -p "$NOJQ"
for t in cat tr mkdir dirname env; do
  p="$(command -v "$t" 2>/dev/null)"; [ -n "$p" ] && ln -s "$p" "$NOJQ/$t"
done
out="$(printf '{"session_id":"s9"}' | env PATH="$NOJQ" HOME="$HOME_DIR" ATELIER_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_ROOT="$ROOT" "$BASH_BIN" "$HOOK" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "jq missing: silent, exit 0" || fail "jq missing: rc=$rc out=[$out]"
[ ! -e "$CFG/state/version-nudge/s9--1.3.0" ] && pass "jq missing: no stamp written" || fail "jq missing: stamp written"

echo ""
if [ "$fails" -eq 0 ]; then echo "version-drift-nudge: all assertions passed."; exit 0
else echo "version-drift-nudge: $fails assertion(s) failed."; exit 1; fi
