#!/usr/bin/env bash
#
# Regression test for #689 — atelier-agent-input-hooks render-block.
#
#   R1 stub modules receive includeCommands:false, toolSearchBootstrap:true and
#      the "claude-code" namer; stdout is byte-exact with no added newline
#      (SKIP without node)
#   R2 a pretooluse.mjs / core/routing.mjs that write a sentinel on import are
#      never loaded
#   R3 static: the helper never imports or execs pretooluse.mjs or
#      core/routing.mjs (outside comments)
#   R4 not installed -> exit 3; missing module -> exit 2
#
# Hermetic: scratch HOME + ATELIER_CONFIG_DIR, fixture plugin tree. The real
# context-mode install is never read. No network.
#
# Run:  hooks/tests/agent-input-hooks-render.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/atelier-agent-input-hooks"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

export HOME="$TMP/home"; mkdir -p "$HOME"
export ATELIER_CONFIG_DIR="$TMP/cfg"
mkdir -p "$ATELIER_CONFIG_DIR/plugins"
echo '{"version":2,"plugins":{}}' > "$ATELIER_CONFIG_DIR/plugins/installed_plugins.json"
echo '{}' > "$ATELIER_CONFIG_DIR/settings.json"
unset CLAUDE_PROJECT_DIR

# Fixture context-mode tree with stub modules + trap modules.
ROOT="$TMP/cm"
mkdir -p "$ROOT/hooks/core"
cat > "$ROOT/hooks/routing-block.mjs" <<'MJS'
export function createRoutingBlock(namer, opts) {
  return "BLOCK|" + namer.platform + "|includeCommands:" + opts.includeCommands + "|toolSearchBootstrap:" + opts.toolSearchBootstrap;
}
MJS
cat > "$ROOT/hooks/core/tool-naming.mjs" <<'MJS'
export function createToolNamer(platform) { return { platform }; }
MJS
SENTINEL="$TMP/sentinel"
cat > "$ROOT/hooks/pretooluse.mjs" <<MJS
import { writeFileSync } from "node:fs";
writeFileSync("$SENTINEL", "pretooluse loaded");
MJS
cat > "$ROOT/hooks/core/routing.mjs" <<MJS
import { writeFileSync } from "node:fs";
writeFileSync("$SENTINEL", "routing loaded");
MJS

echo "atelier-agent-input-hooks render-block (#689)"

# R1
if command -v node >/dev/null 2>&1; then
  "$HELPER" render-block --plugin-root "$ROOT" > "$TMP/r1.out" 2>"$TMP/r1.err"; rc=$?
  printf '%s' 'BLOCK|claude-code|includeCommands:false|toolSearchBootstrap:true' > "$TMP/r1.exp"
  if [ "$rc" = 0 ] && cmp -s "$TMP/r1.out" "$TMP/r1.exp"; then
    pass "R1 byte-exact stdout, claude-code namer, includeCommands:false, toolSearchBootstrap:true"
  else
    fail "R1: rc=$rc out=[$(cat "$TMP/r1.out")] err=[$(cat "$TMP/r1.err")]"
  fi

  # R2
  if [ ! -e "$SENTINEL" ]; then pass "R2 pretooluse.mjs / core/routing.mjs never triggered"; else fail "R2: sentinel written: $(cat "$SENTINEL")"; fi
else
  echo "  SKIP: R1/R2 (node not on PATH)"
fi

# R3
if grep -v '^[[:space:]]*#' "$HELPER" | grep -Eq 'pretooluse\.mjs|core/routing\.mjs'; then
  fail "R3: helper references pretooluse.mjs or core/routing.mjs outside comments"
else
  pass "R3 no import/exec of pretooluse.mjs or core/routing.mjs"
fi

# R4: not installed (empty config, no --plugin-root) -> 3
"$HELPER" render-block >/dev/null 2>&1; rc=$?
if [ "$rc" = 3 ]; then pass "R4 not installed -> exit 3"; else fail "R4 not installed: rc=$rc"; fi

# R4: missing module -> 2
mkdir -p "$TMP/empty-cm"
"$HELPER" render-block --plugin-root "$TMP/empty-cm" >/dev/null 2>"$TMP/r4.err"; rc=$?
if [ "$rc" = 2 ] && grep -q 'missing' "$TMP/r4.err"; then pass "R4 missing module -> exit 2"; else fail "R4 missing module: rc=$rc err=[$(cat "$TMP/r4.err")]"; fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
