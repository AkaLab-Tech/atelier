#!/usr/bin/env bash
#
# Regression test for #544 — hooks/block-operator-browser-github.sh must block
# any Claude in Chrome MCP call whose tool input references github.com,
# *.github.com or api.github.com (case-insensitive), under both the plain and
# the plugin-namespaced tool names, and must NOT block other hosts (including
# look-alikes such as notgithub.com / mygithub.com) or non-Chrome tools.
#
# Hermetic: pure string parsing over the stdin JSON; CLAUDE_PROJECT_DIR is
# pinned to a temp dir so log_decision never touches real state. Requires jq.
#
# Run:  hooks/tests/block-operator-browser-github.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/block-operator-browser-github.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/logs"

fails=0
blocked_n=0
allowed_n=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# run_hook <tool_name> <tool_input_json> -> echoes exit code
run_hook() {
  local payload
  payload="$(jq -cn --arg t "$1" --argjson i "$2" '{tool_name:$t, tool_input:$i}')"
  (
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" \
      bash "$HOOK" <<<"$payload" >/dev/null 2>"$TMP/stderr"
  )
  echo "$?"
}

assert_block() {
  local name="$1" tool="$2" input="$3"
  blocked_n=$((blocked_n + 1))
  local rc; rc="$(run_hook "$tool" "$input")"
  if [ "$rc" = "2" ] && grep -q 'atelier:block-operator-browser-github BLOCKED' "$TMP/stderr"; then
    pass "block: $name"
  else
    fail "block: $name (exit=$rc)"
  fi
}

assert_allow() {
  local name="$1" tool="$2" input="$3"
  allowed_n=$((allowed_n + 1))
  local rc; rc="$(run_hook "$tool" "$input")"
  if [ "$rc" = "0" ]; then
    pass "allow: $name"
  else
    fail "allow: $name (exit=$rc)"
  fi
}

C="mcp__claude-in-chrome__"
P="mcp__plugin_atelier_claude-in-chrome__"

echo "== GitHub targets are blocked =="
assert_block "navigate github.com"             "${C}navigate" '{"url":"https://github.com/o/r/pull/1"}'
assert_block "navigate bare github.com"        "${C}navigate" '{"url":"github.com"}'
assert_block "navigate api.github.com"         "${C}navigate" '{"url":"https://api.github.com/user"}'
assert_block "navigate gist.github.com"        "${C}navigate" '{"url":"https://gist.github.com/x"}'
assert_block "navigate uppercase GitHub.com"   "${C}navigate" '{"url":"https://GitHub.COM/o/r"}'
assert_block "tabs_create_mcp github url"      "${C}tabs_create_mcp" '{"url":"https://github.com/o/r/pulls"}'
assert_block "javascript_tool fetch api"       "${C}javascript_tool" '{"action":"javascript_exec","text":"fetch(\"https://api.github.com/user\").then(r=>r.json())"}'
assert_block "nested array string"             "${C}computer" '{"actions":[{"type":"type","text":"open github.com now"}]}'
assert_block "plugin-namespaced navigate"      "${P}navigate" '{"url":"https://github.com/o/r"}'
assert_block "plugin-namespaced javascript"    "${P}javascript_tool" '{"text":"fetch(\"https://api.github.com/user\")"}'

echo "== other hosts and tools pass =="
assert_allow "navigate example.com"            "${C}navigate" '{"url":"https://example.com"}'
assert_allow "navigate localhost"              "${C}navigate" '{"url":"http://localhost:3000/"}'
assert_allow "tabs_create_mcp non-github"      "${C}tabs_create_mcp" '{"url":"https://docs.anthropic.com"}'
assert_allow "notgithub.com"                   "${C}navigate" '{"url":"https://notgithub.com/x"}'
assert_allow "mygithub.com"                    "${C}navigate" '{"url":"https://mygithub.com/x"}'
assert_allow "javascript_tool non-github"      "${C}javascript_tool" '{"text":"document.title"}'
assert_allow "plugin-namespaced non-github"    "${P}navigate" '{"url":"https://example.com"}'
assert_allow "empty tool input"                "${C}tabs_context_mcp" '{}'
assert_allow "non-Chrome tool naming github"   "mcp__github__get_issue" '{"url":"https://github.com/o/r"}'
assert_allow "Bash tool naming github"         "Bash" '{"command":"echo github.com"}'

echo
echo "blocked cases: $blocked_n, allowed cases: $allowed_n"
total=$((blocked_n + allowed_n))
if [ "$fails" -eq 0 ]; then
  echo "block-operator-browser-github: all $total assertions passed"
  exit 0
fi
echo "block-operator-browser-github: $fails of $total assertions FAILED"
exit 1
