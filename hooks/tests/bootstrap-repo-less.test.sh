#!/usr/bin/env bash
#
# Regression test for #39 F3 — bootstrap.sh, the repo-less one-line installer.
#
# bootstrap.sh checks minimal deps (git/jq/curl), ensures the claude CLI,
# resolves $ATELIER_CONFIG_DIR, registers the akalab-tech marketplace and
# installs atelier@akalab-tech (both idempotent, both pinned to
# CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR), then execs the CACHED install.sh
# --from-cache resolved via installed_plugins.json's installPath pointer.
#
# Hermetic: a fake `claude` shim on PATH logs every invocation (plus the
# CLAUDE_CONFIG_DIR it saw), fakes the marketplace/plugin state, and writes a
# fake installed_plugins.json + cache tree. Scratch HOME + config dir; the
# real claude CLI and ~/.claude-work are never touched. No network.
#
# Run:  hooks/tests/bootstrap-repo-less.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP="$REPO_ROOT/bootstrap.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
CFG="$TMP/cfg"
STATE="$TMP/state"
SHIM_BIN="$TMP/bin"
mkdir -p "$HOME_DIR" "$STATE" "$SHIM_BIN"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "bootstrap.sh repo-less installer (#39 F3)"

# ---------------------------------------------------------------------------
# Syntax gate
# ---------------------------------------------------------------------------
bash -n "$BOOTSTRAP" \
  && pass "bash -n bootstrap.sh" \
  || fail "bootstrap.sh has syntax errors"

# ---------------------------------------------------------------------------
# Fake claude shim. Logs "<CLAUDE_CONFIG_DIR>|<args>" per call; fakes the
# marketplace/plugin state via files under $FAKE_CLAUDE_STATE; `plugin
# install atelier@akalab-tech` plants the fake cache tree + the
# installed_plugins.json pointer, exactly the layout the real CLI produces.
# ---------------------------------------------------------------------------
cat > "$SHIM_BIN/claude" <<'SHIM'
#!/usr/bin/env bash
set -u
S="${FAKE_CLAUDE_STATE:?}"
printf '%s|%s\n' "${CLAUDE_CONFIG_DIR:-<unset>}" "$*" >> "$S/calls.log"
case "$*" in
  --version) echo "9.9.9 (fake)" ;;
  "plugin marketplace list --json")
    if [ -f "$S/marketplace-added" ]; then echo '[{"name":"akalab-tech"}]'; else echo '[]'; fi ;;
  "plugin marketplace add "*)
    touch "$S/marketplace-added" ;;
  "plugin list --json")
    if [ -f "$S/plugin-installed" ]; then echo '[{"id":"atelier@akalab-tech"}]'; else echo '[]'; fi ;;
  "plugin install atelier@akalab-tech")
    touch "$S/plugin-installed"
    cache="$CLAUDE_CONFIG_DIR/plugins/cache/akalab-tech/atelier/1.2.3"
    mkdir -p "$cache"
    printf '#!/usr/bin/env bash\nprintf "CACHED-INSTALL-RAN args:%%s\\n" "$*"\n' > "$cache/install.sh"
    printf '{"plugins":{"atelier@akalab-tech":[{"scope":"user","installPath":"%s","version":"1.2.3"}]}}\n' \
      "$cache" > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
    ;;
esac
exit 0
SHIM
chmod +x "$SHIM_BIN/claude"

run_bootstrap() {
  HOME="$HOME_DIR" ATELIER_CONFIG_DIR="$CFG" FAKE_CLAUDE_STATE="$STATE" \
    PATH="$SHIM_BIN:$PATH" "$@"
}

# ---------------------------------------------------------------------------
# Group 1: missing dep → die with a per-OS hint, before any claude call.
# PATH is reduced to a dir that has git + curl but NO jq (bash builtins cover
# everything bootstrap runs before the dep check).
# ---------------------------------------------------------------------------
DEPS="$TMP/deps"
mkdir -p "$DEPS"
printf '#!/usr/bin/env bash\nexit 0\n' > "$DEPS/git"
printf '#!/usr/bin/env bash\nexit 0\n' > "$DEPS/curl"
chmod +x "$DEPS/git" "$DEPS/curl"
REAL_BASH="$(command -v bash)"

dep_out="$(HOME="$HOME_DIR" PATH="$DEPS" "$REAL_BASH" "$BOOTSTRAP" 2>&1)"
dep_rc=$?
[ "$dep_rc" -ne 0 ] \
  && pass "missing jq: non-zero exit" \
  || fail "missing jq: expected failure, got 0 (out: $dep_out)"
printf '%s' "$dep_out" | grep -q 'missing required tools: jq' \
  && pass "missing jq: names the missing tool" \
  || fail "missing jq: tool not named (out: $dep_out)"
printf '%s' "$dep_out" | grep -Eq 'brew install|apt-get install' \
  && pass "missing jq: per-OS install hint printed" \
  || fail "missing jq: no install hint (out: $dep_out)"
printf '%s' "$dep_out" | grep -q 'never runs sudo' \
  && pass "missing jq: states bootstrap never sudo's" \
  || fail "missing jq: no-sudo statement missing (out: $dep_out)"

# ---------------------------------------------------------------------------
# Group 2: fresh run with ATELIER_BOOTSTRAP_NO_EXEC=1 — marketplace added,
# plugin installed, every claude call pinned to CLAUDE_CONFIG_DIR=$CFG,
# exec target resolved via installPath, exec NOT performed.
# ---------------------------------------------------------------------------
out1="$(run_bootstrap env ATELIER_BOOTSTRAP_NO_EXEC=1 bash "$BOOTSTRAP" 2>&1)"
rc1=$?
[ "$rc1" -eq 0 ] \
  && pass "fresh no-exec run exits 0" \
  || fail "fresh no-exec run rc=$rc1 (out: $out1)"
grep -q '|plugin marketplace add https://github.com/AkaLab-Tech/claude-plugins.git' "$STATE/calls.log" \
  && pass "marketplace added via the full HTTPS URL (no SSH-defaulting shortcut)" \
  || fail "marketplace add call missing/wrong (log: $(cat "$STATE/calls.log"))"
grep -q '|plugin install atelier@akalab-tech' "$STATE/calls.log" \
  && pass "atelier@akalab-tech installed" \
  || fail "plugin install call missing (log: $(cat "$STATE/calls.log"))"
if grep -v "^$CFG|" "$STATE/calls.log" | grep -q .; then
  fail "some claude call ran without CLAUDE_CONFIG_DIR=$CFG: $(grep -v "^$CFG|" "$STATE/calls.log")"
else
  pass "every claude invocation pinned to CLAUDE_CONFIG_DIR=\$ATELIER_CONFIG_DIR"
fi
EXEC_TARGET="$CFG/plugins/cache/akalab-tech/atelier/1.2.3/install.sh"
printf '%s' "$out1" | grep -qF "$EXEC_TARGET --from-cache" \
  && pass "exec target resolved from installed_plugins.json installPath" \
  || fail "exec target not surfaced (out: $out1)"
printf '%s' "$out1" | grep -q 'CACHED-INSTALL-RAN' \
  && fail "NO_EXEC=1 still executed the cached install.sh" \
  || pass "ATELIER_BOOTSTRAP_NO_EXEC=1 stops before exec"
[ -d "$CFG" ] \
  && pass "config dir created" \
  || fail "config dir missing"

# ---------------------------------------------------------------------------
# Group 3: idempotent re-run — marketplace add + plugin install both skipped.
# ---------------------------------------------------------------------------
: > "$STATE/calls.log"
out2="$(run_bootstrap env ATELIER_BOOTSTRAP_NO_EXEC=1 bash "$BOOTSTRAP" 2>&1)"
rc2=$?
[ "$rc2" -eq 0 ] \
  && pass "idempotent re-run exits 0" \
  || fail "re-run rc=$rc2 (out: $out2)"
grep -q 'plugin marketplace add' "$STATE/calls.log" \
  && fail "re-run repeated the marketplace add" \
  || pass "marketplace add skipped when already registered"
grep -q 'plugin install atelier@akalab-tech' "$STATE/calls.log" \
  && fail "re-run repeated the plugin install" \
  || pass "plugin install skipped when already installed"
printf '%s' "$out2" | grep -q 'already added' \
  && pass "re-run reports the marketplace skip" \
  || fail "no marketplace skip message (out: $out2)"
printf '%s' "$out2" | grep -q 'already installed' \
  && pass "re-run reports the plugin skip" \
  || fail "no plugin skip message (out: $out2)"

# ---------------------------------------------------------------------------
# Group 4: real handover — without NO_EXEC, bootstrap execs the cached
# install.sh with --from-cache plus the operator's passthrough args.
# ---------------------------------------------------------------------------
out3="$(run_bootstrap bash "$BOOTSTRAP" --yes 2>&1)"
rc3=$?
[ "$rc3" -eq 0 ] \
  && pass "exec run exits 0" \
  || fail "exec run rc=$rc3 (out: $out3)"
printf '%s' "$out3" | grep -q 'CACHED-INSTALL-RAN args:--from-cache --yes' \
  && pass "delegates to the cached install.sh with --from-cache + passthrough args" \
  || fail "cached install.sh not exec'd with expected args (out: $out3)"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "bootstrap-repo-less: all assertions passed."
  exit 0
else
  echo "bootstrap-repo-less: $fails assertion(s) failed."
  exit 1
fi
