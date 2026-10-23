#!/usr/bin/env bash
#
# Regression test for hooks/gh-shim-path.sh (#582): the SessionStart hook that
# puts the atelier `gh` shim first on PATH for every Bash call of the session
# via $CLAUDE_ENV_FILE, plus the install.sh shellrc wiring (block version 7).
#
# Hermetic: temp HOME / runtime dir / env file; no network, no real gh.
#
# Run:  hooks/tests/gh-shim-path.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/hooks/gh-shim-path.sh"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
INSTALL="$REPO_ROOT/install.sh"

TMP="$(cd -P "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

bash -n "$HOOK" && pass "bash -n hooks/gh-shim-path.sh" || fail "bash -n hook"

HOME_DIR="$TMP/home"; RT="$TMP/runtime"; PROOT="$TMP/plugin"; STUB="$TMP/stub"; RCBIN="$TMP/rcbin"
RTSHIMS="$RT/current/scripts/shims"
mkdir -p "$HOME_DIR" "$RTSHIMS" "$PROOT/scripts/shims" "$STUB" "$RCBIN"
cp "$REPO_ROOT/scripts/shims/gh" "$RTSHIMS/gh"
cp "$REPO_ROOT/scripts/shims/gh" "$PROOT/scripts/shims/gh"
chmod +x "$RTSHIMS/gh" "$PROOT/scripts/shims/gh"
printf '#!/bin/sh\necho REAL\n' > "$STUB/gh"; chmod +x "$STUB/gh"
printf '#!/bin/sh\necho RC-GH\n' > "$RCBIN/gh"; chmod +x "$RCBIN/gh"

# hook ENVFILE ROOT RUNTIME -> sets RC, ERR
hook() {
  ERR="$(env -i HOME="$HOME_DIR" PATH=/usr/bin:/bin ${1:+CLAUDE_ENV_FILE="$1"} \
    ${2:+CLAUDE_PLUGIN_ROOT="$2"} ATELIER_RUNTIME_DIR="$3" bash "$HOOK" 2>&1 >/dev/null </dev/null)"; RC=$?
}

# --- runtime dir preferred; sourcing resolves gh to the shim ---
EF="$TMP/env1"; : > "$EF"
hook "$EF" "$PROOT" "$RT"
[ "$RC" = 0 ] && pass "exits 0 with runtime shim" || fail "rc=$RC"
[ "$(cat "$EF")" = "export PATH=\"$RTSHIMS:\$PATH\"" ] && pass "env file gets the runtime shim prepend (runtime preferred over plugin root)" || fail "env file: $(cat "$EF")"
[ -z "$ERR" ] && pass "no warning when the shim is active" || fail "unexpected stderr: $ERR"

got="$(env -i HOME="$HOME_DIR" PATH="$STUB:/usr/bin:/bin" bash -c ". '$EF'; command -v gh")"
[ "$got" = "$RTSHIMS/gh" ] && pass "after sourcing, command -v gh resolves to the shim" || fail "command -v gh = $got"

# rc-style prepend of a dir holding another gh BEFORE the env file is sourced: shim still first.
got="$(env -i HOME="$HOME_DIR" PATH="$STUB:/usr/bin:/bin" bash -c "export PATH='$RCBIN':\"\$PATH\"; . '$EF'; command -v gh")"
[ "$got" = "$RTSHIMS/gh" ] && pass "shim stays first after an rc-style prepend" || fail "after rc prepend: $got"
got="$(env -i HOME="$HOME_DIR" PATH="$STUB:/usr/bin:/bin" bash -c ". '$EF'; command -v gh" )"
out="$(env -i HOME="$HOME_DIR" PATH="$STUB:/usr/bin:/bin" ATELIER_CONFIG_DIR="$TMP/acd" bash -c "export PATH='$RCBIN':\"\$PATH\"; . '$EF'; gh pr view 1")"
[ "$out" = "RC-GH" ] && pass "shim defers to the next gh on PATH (rc-prepended one)" || fail "pass-through output: $out"

# --- plugin-root fallback ---
EF="$TMP/env2"; : > "$EF"
hook "$EF" "$PROOT" "$TMP/no-such-runtime"
[ "$RC" = 0 ] && [ "$(cat "$EF")" = "export PATH=\"$PROOT/scripts/shims:\$PATH\"" ] \
  && pass "plugin-root fallback writes \$CLAUDE_PLUGIN_ROOT/scripts/shims" || fail "fallback: rc=$RC file=$(cat "$EF")"

# runtime dir exists but has no executable gh -> fallback
mkdir -p "$TMP/rt-empty/current/scripts/shims"; : > "$TMP/rt-empty/current/scripts/shims/gh"
EF="$TMP/env3"; : > "$EF"
hook "$EF" "$PROOT" "$TMP/rt-empty"
[ "$(cat "$EF")" = "export PATH=\"$PROOT/scripts/shims:\$PATH\"" ] && pass "non-executable runtime gh -> plugin-root fallback" || fail "non-exec runtime: $(cat "$EF")"

# --- degraded: no CLAUDE_ENV_FILE ---
hook "" "$PROOT" "$RT"
[ "$RC" = 0 ] && pass "no CLAUDE_ENV_FILE: exits 0" || fail "no env file: rc=$RC"
printf '%s' "$ERR" | grep -q 'gh shim not active; identity relies on the #544 hook' && pass "no CLAUDE_ENV_FILE: one-line warning" || fail "warning missing: $ERR"
[ "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')" = 1 ] && pass "warning is a single line" || fail "warning lines: $ERR"

# env file path that does not exist
hook "$TMP/missing-env" "$PROOT" "$RT"
[ "$RC" = 0 ] && [ ! -e "$TMP/missing-env" ] && printf '%s' "$ERR" | grep -q 'gh shim not active' \
  && pass "nonexistent env file: warns, exits 0, does not create it" || fail "missing env file: rc=$RC err=$ERR"

# no shim anywhere
EF="$TMP/env4"; : > "$EF"
hook "$EF" "$TMP/empty-root" "$TMP/no-such-runtime"
[ "$RC" = 0 ] && [ ! -s "$EF" ] && printf '%s' "$ERR" | grep -q 'gh shim not active' \
  && pass "no shim anywhere: warns, exits 0, writes nothing" || fail "no shim: rc=$RC err=$ERR file=$(cat "$EF")"

# repo's own shim via the real plugin root
EF="$TMP/env5"; : > "$EF"
hook "$EF" "$REPO_ROOT" "$TMP/no-such-runtime"
[ "$(cat "$EF")" = "export PATH=\"$REPO_ROOT/scripts/shims:\$PATH\"" ] && pass "real plugin root resolves to scripts/shims in this repo" || fail "repo root: $(cat "$EF")"

# --- hooks.json wiring ---
jq -e '[.hooks.SessionStart[]?.hooks[]?.command | select(. != null) | test("gh-shim-path\\.sh")] | any' "$HOOKS_JSON" >/dev/null 2>&1 \
  && pass "hooks.json registers gh-shim-path.sh under SessionStart" || fail "hooks.json lacks gh-shim-path.sh"
jq -e '[.hooks.SessionStart[]?.hooks[]? | select((.command // "") | test("gh-shim-path\\.sh")) | .command | test("CLAUDE_PLUGIN_ROOT")] | all' "$HOOKS_JSON" >/dev/null 2>&1 \
  && pass "hook command is addressed via \$CLAUDE_PLUGIN_ROOT" || fail "hook command not via CLAUDE_PLUGIN_ROOT"

# --- install.sh --refresh-shellrc writes block version 7 with the PATH prefix ---
IH="$TMP/ihome"; CFG="$IH/cfg"; mkdir -p "$CFG"; : > "$IH/.zshrc"
SHELL=/bin/zsh HOME="$IH" bash "$INSTALL" --config-dir "$CFG" --refresh-shellrc >/dev/null 2>&1 \
  && pass "--refresh-shellrc exits 0" || fail "--refresh-shellrc failed"
grep -q '# atelier-hooks-version: 7' "$IH/.zshrc" && pass "shellrc block is version 7" || fail "block version != 7"
[ "$(grep -c 'PATH="${ATELIER_RUNTIME_DIR:-$HOME/.local/share/atelier}/current/scripts/shims:$PATH"' "$IH/.zshrc")" = 2 ] \
  && pass "task() and atelier() both prefix PATH with the runtime shim dir" || fail "shim PATH prefix count != 2"
awk '/^task\(\)/,/^}/' "$IH/.zshrc" | grep -q 'current/scripts/shims' && pass "prefix is inside task()" || fail "prefix not in task()"
awk '/^atelier\(\)/,/^}/' "$IH/.zshrc" | grep -q 'current/scripts/shims' && pass "prefix is inside atelier()" || fail "prefix not in atelier()"
# An older block (version 6) is upgraded, not duplicated.
python3 - "$IH/.zshrc" <<'E'
import sys; p=sys.argv[1]; s=open(p).read(); open(p,'w').write(s.replace('# atelier-hooks-version: 7','# atelier-hooks-version: 6'))
E
SHELL=/bin/zsh HOME="$IH" bash "$INSTALL" --config-dir "$CFG" --refresh-shellrc >/dev/null 2>&1
[ "$(grep -c '>>> atelier hooks' "$IH/.zshrc")" = 1 ] && grep -q '# atelier-hooks-version: 7' "$IH/.zshrc" \
  && pass "a version-6 block is upgraded to 7 in place" || fail "v6 block not upgraded cleanly"

# --- the shim is NOT linked into ~/.local/bin ---
if grep -nE '_phase_c_1_symlink_helper[[:space:]]+gh([[:space:]]|$)' "$INSTALL" >/dev/null; then
  fail "install.sh symlinks gh into ~/.local/bin"
else pass "install.sh has no helper symlink for gh"; fi
if grep -nE 'ln[[:space:]].*scripts/shims|bin_dir/gh' "$INSTALL" >/dev/null; then
  fail "install.sh links the shims dir or bin_dir/gh"
else pass "install.sh never links scripts/shims or bin_dir/gh into ~/.local/bin"; fi

echo ""
if [ "$fails" -eq 0 ]; then echo "gh-shim-path: all assertions passed."; exit 0
else echo "gh-shim-path: $fails assertion(s) failed."; exit 1; fi
