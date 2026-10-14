#!/usr/bin/env bash
#
# Regression test for #442 — atelier-update must surface `claude plugin update`
# failures (SSH clone errors on HTTPS-only hosts) instead of reporting
# "already up to date", and must run every plugin update with
# CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1.
#
#   1 managed, atelier update fails (SSH error) → exit 1, error shown + HTTPS
#     hint, no "already up to date", runtime `current` NOT swapped
#   2 managed, only claude-roadmap-tools fails → atelier swap happened, exit 1,
#     failing plugin named, no "already up to date"
#   3 managed, success, same version → exit 2 (contract unchanged)
#   4 env CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1 reaches every `plugin update` call
#   5 settings.json gains env.CLAUDE_CODE_PLUGIN_PREFER_HTTPS="1", keeps
#     pre-seeded permissions.defaultMode; invalid JSON is left alone
#   6 clone mode (local bare origin, no network): cache drift + failing update
#     → exit 1 + "plugin cache NOT refreshed"
#
# Hermetic: scratch HOME/ATELIER_CONFIG_DIR/runtime, fake `claude` shim, local
# bare git origin for case 6. No network.
#
# Run:  hooks/tests/atelier-update-plugin-failure.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPDATE="$REPO_ROOT/scripts/atelier-update"
INSTALL="$REPO_ROOT/install.sh"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "atelier-update plugin-update failure surfacing + HTTPS env (#442)"

# Fake claude: logs "<PREFER_HTTPS>|<CLAUDE_CONFIG_DIR>|<args>". Fails
# `plugin update <id>` for every id listed in FAKE_CLAUDE_FAIL (space list)
# with the SSH error Claude Code prints.
SHIM_BIN="$TMP/shim-bin"; mkdir -p "$SHIM_BIN"
cat > "$SHIM_BIN/claude" <<'SHIM'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "${CLAUDE_CODE_PLUGIN_PREFER_HTTPS:-<unset>}" "${CLAUDE_CONFIG_DIR:-<unset>}" "$*" >> "${FAKE_CLAUDE_STATE:?}/calls.log"
if [ "${1:-}" = plugin ] && [ "${2:-}" = update ]; then
  for id in ${FAKE_CLAUDE_FAIL:-}; do
    if [ "$id" = "${3:-}" ]; then
      echo "Failed to clone repository: git@github.com: Permission denied (publickey)." >&2
      exit 1
    fi
  done
fi
exit 0
SHIM
chmod +x "$SHIM_BIN/claude"

# build_managed <dir> — managed fixture (runtime 0.1.0, cache 0.2.0), as in
# atelier-update-managed.test.sh. Sets S_HOME S_CFG S_RT S_STATE.
build_managed() {
  local d="$1" cache
  S_HOME="$d/home"; S_CFG="$d/cfg"; S_RT="$d/runtime"; S_STATE="$d/state"
  mkdir -p "$S_HOME/.local/bin" "$S_CFG/templates" "$S_STATE" \
    "$S_RT/0.1.0/scripts" "$S_RT/0.1.0/templates" "$S_RT/0.1.0/.claude-plugin"
  cp "$UPDATE" "$S_RT/0.1.0/scripts/atelier-update"
  cp "$INSTALL" "$S_RT/0.1.0/install.sh"
  printf '#!/usr/bin/env bash\necho foo-v1\n' > "$S_RT/0.1.0/scripts/atelier-foo"
  chmod +x "$S_RT/0.1.0/scripts/"*
  printf '{ "name": "atelier", "version": "0.1.0" }\n' > "$S_RT/0.1.0/.claude-plugin/plugin.json"
  ln -s "0.1.0" "$S_RT/current"
  ln -s "$S_RT/current/scripts/atelier-update" "$S_HOME/.local/bin/atelier-update"
  ln -s "$S_RT/current/scripts/atelier-foo" "$S_HOME/.local/bin/atelier-foo"
  cache="$S_CFG/plugins/cache/akalab-tech/atelier/0.2.0"
  mkdir -p "$cache/scripts" "$cache/templates" "$cache/.claude-plugin"
  cp "$UPDATE" "$cache/scripts/atelier-update"
  cp "$INSTALL" "$cache/install.sh"
  printf '#!/usr/bin/env bash\necho foo-v2\n' > "$cache/scripts/atelier-foo"
  chmod +x "$cache/scripts/"*
  printf '{ "name": "atelier", "version": "0.2.0" }\n' > "$cache/.claude-plugin/plugin.json"
  printf '{ "permissions": [] }\n' > "$cache/templates/settings.template.json"
  printf 'p\n' > "$cache/templates/project-claude.md.template"
  printf '{ "v": 2 }\n' > "$cache/templates/atelier.template.json"
  printf '{ "permissions": [] }\n' > "$S_CFG/templates/settings.template.json"
  printf 'p\n' > "$S_CFG/templates/project-claude.md.template"
  printf '{ "v": 2 }\n' > "$S_CFG/templates/atelier.template.json"
  printf '{"plugins":{"atelier@akalab-tech":[{"scope":"user","installPath":"%s","version":"0.2.0"}]}}\n' \
    "$cache" > "$S_CFG/plugins/installed_plugins.json"
}

run_update() { # run_update <fail-list> [args...]
  local fl="$1"; shift
  HOME="$S_HOME" ATELIER_CONFIG_DIR="$S_CFG" ATELIER_RUNTIME_DIR="$S_RT" \
    FAKE_CLAUDE_STATE="$S_STATE" FAKE_CLAUDE_FAIL="$fl" SHELL=/bin/zsh NO_COLOR=1 \
    PATH="$SHIM_BIN:$PATH" "$S_HOME/.local/bin/atelier-update" "$@" 2>&1
}

# --- Case 1: atelier update fails over SSH ----------------------------------
build_managed "$TMP/c1"
out="$(run_update "atelier@akalab-tech")"; rc=$?
[ "$rc" -eq 1 ] && pass "1: exit 1 when atelier plugin update fails" || fail "1: rc=$rc (out: $out)"
printf '%s' "$out" | grep -q 'Permission denied (publickey)' \
  && pass "1: real clone error is shown" || fail "1: SSH error not surfaced (out: $out)"
printf '%s' "$out" | grep -q 'CLAUDE_CODE_PLUGIN_PREFER_HTTPS' \
  && pass "1: HTTPS retry hint printed" || fail "1: no HTTPS hint (out: $out)"
printf '%s' "$out" | grep -q 'nothing was swapped' \
  && pass "1: dies with 'nothing was swapped'" || fail "1: missing die message (out: $out)"
printf '%s' "$out" | grep -qi 'already up to date' \
  && fail "1: falsely reports 'already up to date'" || pass "1: no 'already up to date' report"
[ "$(readlink "$S_RT/current")" = "0.1.0" ] \
  && pass "1: runtime current still at 0.1.0" || fail "1: current -> $(readlink "$S_RT/current")"

# --- Case 2: only claude-roadmap-tools fails --------------------------------
build_managed "$TMP/c2"
out="$(run_update "claude-roadmap-tools@akalab-tech")"; rc=$?
[ "$rc" -eq 1 ] && pass "2: exit 1 when only claude-roadmap-tools fails" || fail "2: rc=$rc (out: $out)"
[ "$(readlink "$S_RT/current")" = "0.2.0" ] \
  && pass "2: atelier swap still happened (current -> 0.2.0)" || fail "2: current -> $(readlink "$S_RT/current")"
printf '%s' "$out" | grep -q 'claude-roadmap-tools plugin update failed' \
  && pass "2: failed plugin named in the final error" || fail "2: plugin not named (out: $out)"
printf '%s' "$out" | grep -qi 'already up to date' \
  && fail "2: falsely reports 'already up to date'" || pass "2: no 'already up to date' report"

# --- Case 2b: same-version rerun with crt still failing exits 1, not 2 ------
out="$(run_update "claude-roadmap-tools@akalab-tech")"; rc=$?
[ "$rc" -eq 1 ] \
  && pass "2b: same-version rerun with crt failure exits 1 (not 2)" || fail "2b: rc=$rc (out: $out)"
printf '%s' "$out" | grep -qi 'already up to date' \
  && fail "2b: falsely reports 'already up to date'" || pass "2b: no 'already up to date' report"

# --- Case 3 + 4: success, same version; env reaches the shim ----------------
build_managed "$TMP/c3"
run_update "" >/dev/null     # first run swaps 0.1.0 -> 0.2.0
out="$(run_update "")"; rc=$?
[ "$rc" -eq 2 ] && pass "3: success on same version still exits 2" || fail "3: rc=$rc (out: $out)"
n_upd="$(grep -c '|plugin update ' "$S_STATE/calls.log")"
n_ok="$(grep -c '^1|.*|plugin update ' "$S_STATE/calls.log")"
[ "$n_upd" -ge 4 ] && [ "$n_upd" = "$n_ok" ] \
  && pass "4: all $n_upd 'plugin update' calls carried CLAUDE_CODE_PLUGIN_PREFER_HTTPS=1" \
  || fail "4: $n_ok of $n_upd update calls had the env (log: $(cat "$S_STATE/calls.log"))"
grep -q "^1|$S_CFG|plugin update claude-roadmap-tools@akalab-tech" "$S_STATE/calls.log" \
  && pass "4: claude-roadmap-tools update pinned to config dir with the env" \
  || fail "4: crt update call wrong"

# --- Case 5: settings reconcile ---------------------------------------------
build_managed "$TMP/c5"
printf '{"permissions":{"defaultMode":"auto"},"env":{"KEEP":"x"}}\n' > "$S_CFG/settings.json"
run_update "" >/dev/null
[ "$(jq -r '.env.CLAUDE_CODE_PLUGIN_PREFER_HTTPS' "$S_CFG/settings.json")" = "1" ] \
  && pass "5: settings.json gained env.CLAUDE_CODE_PLUGIN_PREFER_HTTPS=\"1\"" \
  || fail "5: env not set: $(cat "$S_CFG/settings.json")"
[ "$(jq -r '.permissions.defaultMode' "$S_CFG/settings.json")" = "auto" ] \
  && [ "$(jq -r '.env.KEEP' "$S_CFG/settings.json")" = "x" ] \
  && pass "5: pre-seeded permissions.defaultMode and env.KEEP preserved" \
  || fail "5: keys lost: $(cat "$S_CFG/settings.json")"
before="$(cat "$S_CFG/settings.json")"
run_update "" >/dev/null
[ "$before" = "$(cat "$S_CFG/settings.json")" ] \
  && pass "5: second run is idempotent" || fail "5: settings changed on rerun"

build_managed "$TMP/c5b"
printf '{ not json' > "$S_CFG/settings.json"
out="$(run_update "")"
[ "$(cat "$S_CFG/settings.json")" = '{ not json' ] \
  && pass "5: invalid settings.json left untouched" || fail "5: invalid JSON was rewritten"
printf '%s' "$out" | grep -q 'not valid JSON' \
  && pass "5: invalid JSON warned about" || fail "5: no warning (out: $out)"

# --- Case 6: clone mode ------------------------------------------------------
if command -v git >/dev/null 2>&1; then
  C="$TMP/c6"; mkdir -p "$C/home/.local/bin" "$C/cfg/plugins" "$C/state"
  git init -q -b main "$C/clone"
  git -C "$C/clone" config user.email t@t; git -C "$C/clone" config user.name t
  mkdir -p "$C/clone/scripts" "$C/clone/.claude-plugin" "$C/clone/templates"
  printf '{ "name": "atelier", "version": "0.3.0" }\n' > "$C/clone/.claude-plugin/plugin.json"
  cp "$UPDATE" "$C/clone/scripts/atelier-update"
  cp "$INSTALL" "$C/clone/install.sh"
  printf '{ "permissions": [] }\n' > "$C/clone/templates/settings.template.json"
  printf 'p\n' > "$C/clone/templates/project-claude.md.template"
  printf '{ "v": 3 }\n' > "$C/clone/templates/atelier.template.json"
  git -C "$C/clone" add -A && git -C "$C/clone" commit -q -m init
  # Local bare origin made by cloning (no network, no push needed).
  git clone -q --bare "$C/clone" "$C/origin.git"
  git -C "$C/clone" remote add origin "$C/origin.git"
  git -C "$C/clone" fetch -q origin
  # Plugin cache lags the clone (0.2.0 vs 0.3.0) => cache drift => refresh.
  printf '{"plugins":{"atelier@akalab-tech":[{"scope":"user","installPath":"/x","version":"0.2.0"}]}}\n' \
    > "$C/cfg/plugins/installed_plugins.json"
  out="$(HOME="$C/home" ATELIER_CONFIG_DIR="$C/cfg" ATELIER_RUNTIME_DIR="$C/runtime" \
    FAKE_CLAUDE_STATE="$C/state" FAKE_CLAUDE_FAIL="atelier@akalab-tech" SHELL=/bin/zsh NO_COLOR=1 \
    PATH="$SHIM_BIN:$PATH" bash "$C/clone/scripts/atelier-update" --plugin-root "$C/clone" 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] && pass "6: clone mode exits 1 when the cache refresh fails" || fail "6: rc=$rc (out: $out)"
  printf '%s' "$out" | grep -q 'plugin cache NOT refreshed' \
    && pass "6: clone mode reports 'plugin cache NOT refreshed'" || fail "6: message missing (out: $out)"
  printf '%s' "$out" | grep -q 'update applied\|resynced to' \
    && fail "6: success banner printed despite failure" || pass "6: no success banner"
else
  echo "  SKIP: 6 (git not on PATH)"
fi

echo ""
if [ "$fails" -eq 0 ]; then echo "atelier-update-plugin-failure: all assertions passed."; exit 0
else echo "atelier-update-plugin-failure: $fails assertion(s) failed."; exit 1; fi
