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
for needle in 1.2.3 1.3.0 /reload-plugins "next message"; do
  case "$sm" in *"$needle"*) ;; *) ok=0; fail "drift: systemMessage lacks '$needle'";; esac
  case "$ac" in *"$needle"*) ;; *) ok=0; fail "drift: additionalContext lacks '$needle'";; esac
done
[ "$ok" = 1 ] && pass "drift: both versions, /reload-plugins and next-message finish named"
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

# --- drift nudge names --force (#505) ---
rm -rf "$CFG/state"
set_loaded 1.2.3; set_installed 1.3.0
run_hook f1
case "$out" in *"/reload-plugins --force"*) pass "drift: nudge names /reload-plugins --force";; *) fail "drift: no --force in [$out]";; esac

# run_ev <sid> <event> <prompt>: sets $out and $rc, with hook_event_name in the payload.
run_ev() {
  local payload
  payload="$(jq -n --arg s "$1" --arg e "$2" --arg p "$3" '{session_id:$s,hook_event_name:$e,prompt:$p}')"
  out="$(printf '%s' "$payload" | env HOME="$HOME_DIR" ATELIER_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_ROOT="$ROOT" "$BASH_BIN" "$HOOK" 2>/dev/null)"
  rc=$?
}
CTXDIR="$CFG/state/version-nudge"

# --- SessionStart writes .ctx and prints nothing ---
rm -rf "$CFG/state"
set_loaded 1.2.3; set_installed 1.2.3
run_ev c1 SessionStart ""
[ "$rc" = 0 ] && [ -z "$out" ] && pass "SessionStart: silent, exit 0" || fail "SessionStart: rc=$rc out=[$out]"
[ "$(cat "$CTXDIR/c1.ctx" 2>/dev/null)" = "1.2.3" ] && pass "SessionStart: .ctx holds loaded version" || fail "SessionStart: .ctx wrong"

# --- same version after SessionStart -> silent ---
run_ev c1 UserPromptSubmit "hello"
[ "$rc" = 0 ] && [ -z "$out" ] && pass "ctx equals loaded: silent" || fail "ctx equals loaded: out=[$out]"

# --- post-reload finish fires once, then silent ---
set_loaded 1.3.0; set_installed 1.3.0
run_ev c1 UserPromptSubmit "hello"
ac="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
sm="$(printf '%s' "$out" | jq -r '.systemMessage // empty' 2>/dev/null)"
case "$ac" in *"1.3.0"*"/atelier:reload Steps 3-4"*) pass "finish: additionalContext names /atelier:reload Steps 3-4 and 1.3.0";; *) fail "finish: ac=[$ac]";; esac
[ "$sm" = "atelier 1.3.0 loaded; refreshing session rules." ] && pass "finish: systemMessage exact" || fail "finish: sm=[$sm]"
[ "$(cat "$CTXDIR/c1.ctx" 2>/dev/null)" = "1.3.0" ] && pass "finish: .ctx updated to loaded" || fail "finish: .ctx not updated"
run_ev c1 UserPromptSubmit "again"
[ "$rc" = 0 ] && [ -z "$out" ] && pass "finish: second prompt silent" || fail "finish second prompt: out=[$out]"

# --- skip on /atelier:reload and /atelier:refresh, .ctx still updated ---
for cmd in "/atelier:reload" "/atelier:refresh now"; do
  rm -rf "$CFG/state"; mkdir -p "$CTXDIR"
  set_loaded 1.3.0; set_installed 1.3.0
  printf '1.2.3\n' >"$CTXDIR/k1.ctx"
  run_ev k1 UserPromptSubmit "$cmd"
  [ "$rc" = 0 ] && [ -z "$out" ] && pass "skip on '$cmd': silent" || fail "skip on '$cmd': out=[$out]"
  [ "$(cat "$CTXDIR/k1.ctx" 2>/dev/null)" = "1.3.0" ] && pass "skip on '$cmd': .ctx updated" || fail "skip on '$cmd': .ctx not updated"
done

# --- legacy nudge stamp without .ctx still triggers the finish ---
rm -rf "$CFG/state"; mkdir -p "$CTXDIR"
: >"$CTXDIR/L1--1.3.0"
run_ev L1 UserPromptSubmit "hello"
case "$out" in *"/atelier:reload Steps 3-4"*) pass "legacy stamp: finish fires";; *) fail "legacy stamp: out=[$out]";; esac
[ "$(cat "$CTXDIR/L1.ctx" 2>/dev/null)" = "1.3.0" ] && pass "legacy stamp: .ctx written" || fail "legacy stamp: .ctx missing"
run_ev L1 UserPromptSubmit "again"
[ -z "$out" ] && pass "legacy stamp: fires once" || fail "legacy stamp second: out=[$out]"

# --- no record and no stamp -> silent (fail-open) ---
rm -rf "$CFG/state"
run_ev n1 UserPromptSubmit "hello"
[ "$rc" = 0 ] && [ -z "$out" ] && pass "no record: silent, exit 0" || fail "no record: rc=$rc out=[$out]"
[ ! -e "$CTXDIR/n1.ctx" ] && pass "no record: no .ctx created" || fail "no record: .ctx created"

# --- bad JSON on stdin -> silent ---
out="$(printf 'not json' | env HOME="$HOME_DIR" ATELIER_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_ROOT="$ROOT" "$BASH_BIN" "$HOOK" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "bad JSON stdin: silent, exit 0" || fail "bad JSON stdin: rc=$rc out=[$out]"

# --- jq missing on SessionStart -> silent, no .ctx ---
out="$(printf '{"session_id":"j1","hook_event_name":"SessionStart"}' | env PATH="$NOJQ" HOME="$HOME_DIR" ATELIER_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_ROOT="$ROOT" "$BASH_BIN" "$HOOK" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ ! -e "$CTXDIR/j1.ctx" ] && pass "jq missing on SessionStart: silent, no .ctx" || fail "jq missing SessionStart: rc=$rc out=[$out]"

echo ""
if [ "$fails" -eq 0 ]; then echo "version-drift-nudge: all assertions passed."; exit 0
else echo "version-drift-nudge: $fails assertion(s) failed."; exit 1; fi
