#!/usr/bin/env bash
#
# Regression test for #39 F5 — atelier-doctor install-mode detection and
# managed runtime coherence.
#
# COVERAGE
#   Phase A — check_install_mode() classification + coherence:
#     A1 managed, coherent      → OK mode line + OK "matches the plugin cache",
#                                 no fix registered
#     A2 version drift          → FAIL "runtime version X != plugin cache Y",
#                                 fix mentions atelier-update
#     A3 same-version content
#        drift (scripts/)       → FAIL "content drifted", fix re-materializes
#                                 from the cache (--from-cache)
#     A4 clone mode             → OK clone line + gentle migration hint,
#                                 NO fix (clone installs stay supported)
#     A5 mixed mode             → FAIL "mixed", converge fix
#     A6 managed, current gone  → FAIL "current ... missing", atelier-update fix
#     A7 no helper symlinks     → FAIL, bootstrap one-liner fix
#   Phase B — check_hooks_liveness() plugin-root fallback (#39 F5 item 4):
#     B1 no clone on disk, hooks/ resolvable via the plugin-cache
#        installPath in installed_plugins.json → manifest check runs (no SKIP)
#     B2 no cache pointer either → SKIP mentions the plugin cache
#
# Hermetic: functions are extracted from scripts/atelier-doctor and run with
# push_* stubs against fixtures under a scratch HOME (fake symlinks, fake
# installed_plugins.json, a real `git init` for the clone fixture). No
# network, no real ~/.local or ~/.claude-work.
#
# Run:  hooks/tests/doctor-install-mode.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/atelier-doctor"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# ---------------------------------------------------------------------------
# Extract check_install_mode() and check_hooks_liveness() from the doctor.
# ---------------------------------------------------------------------------
FN_FILE="$TMP/fns.sh"
awk '/^check_install_mode\(\) \{/{f=1} f{print} f&&/^\}/{f=0}
     /^check_hooks_liveness\(\) \{/{g=1} g{print} g&&/^\}/{g=0}' \
  "$DOCTOR" > "$FN_FILE"
if ! grep -q 'check_install_mode()' "$FN_FILE" \
   || ! grep -q 'check_hooks_liveness()' "$FN_FILE"; then
  echo "  FAIL: could not extract functions from $DOCTOR"
  exit 1
fi
# shellcheck disable=SC1090
source "$FN_FILE"

# ---------------------------------------------------------------------------
# Doctor infrastructure stubs (report lines + fixes captured to files).
# ---------------------------------------------------------------------------
HOST_OUT="$TMP/host_out"
FIX_OUT="$TMP/fix_out"
push_host()       { printf '%s\n' "$*" >> "$HOST_OUT"; }
push_fix_manual() { printf '%s\n' "$*" >> "$FIX_OUT"; }
push_fix_auto()   { printf '%s\n' "$*" >> "$FIX_OUT"; }
OK="✓"; FAIL="✗"; SKIP="–"
reset_capture() { rm -f "$HOST_OUT" "$FIX_OUT"; }

# ---------------------------------------------------------------------------
# Shared fixture builder: a managed runtime dir + cache + manifest under a
# per-scenario HOME so $HOME/.local/bin is isolated each time.
# ---------------------------------------------------------------------------
make_managed_home() {
  # $1 = scenario dir; leaves globals HOME/ATELIER_RUNTIME_BASE/
  # ATELIER_CONFIG_DIR/CACHE pointing into it.
  local s="$1"
  HOME="$s/home"
  ATELIER_RUNTIME_BASE="$HOME/.local/share/atelier"
  ATELIER_CONFIG_DIR="$s/cfg"
  CACHE="$s/cache"
  mkdir -p "$HOME/.local/bin" \
           "$ATELIER_RUNTIME_BASE/0.5.0/scripts" \
           "$ATELIER_RUNTIME_BASE/0.5.0/templates" \
           "$ATELIER_RUNTIME_BASE/0.5.0/.claude-plugin" \
           "$ATELIER_CONFIG_DIR/plugins" \
           "$CACHE/scripts" "$CACHE/templates"
  printf '#!/usr/bin/env bash\necho doctor\n' > "$ATELIER_RUNTIME_BASE/0.5.0/scripts/atelier-doctor"
  printf 'tmpl-v5\n' > "$ATELIER_RUNTIME_BASE/0.5.0/templates/settings.template.json"
  printf '{ "name": "atelier", "version": "0.5.0" }\n' > "$ATELIER_RUNTIME_BASE/0.5.0/.claude-plugin/plugin.json"
  ln -s "0.5.0" "$ATELIER_RUNTIME_BASE/current"
  ln -s "$ATELIER_RUNTIME_BASE/current/scripts/atelier-doctor" "$HOME/.local/bin/atelier-doctor"
  # Cache payload identical to the runtime payload (coherent by default).
  cp "$ATELIER_RUNTIME_BASE/0.5.0/scripts/atelier-doctor" "$CACHE/scripts/atelier-doctor"
  cp "$ATELIER_RUNTIME_BASE/0.5.0/templates/settings.template.json" "$CACHE/templates/settings.template.json"
  printf '{"plugins":{"atelier@akalab-tech":[{"scope":"user","installPath":"%s","version":"0.5.0"}]}}\n' \
    "$CACHE" > "$ATELIER_CONFIG_DIR/plugins/installed_plugins.json"
}

echo "Phase A: check_install_mode() classification + managed coherence"

# --- A1: managed, coherent ---------------------------------------------------
reset_capture
make_managed_home "$TMP/a1"
# An optional-integration helper served from its OWN plugin cache must not
# count against the mode calculus (real installs have atelier-coolify etc.
# pointing into $ATELIER_CONFIG_DIR/plugins/cache/ in every mode).
mkdir -p "$ATELIER_CONFIG_DIR/plugins/cache/akalab-tech/coolify-integration/0.1.0/scripts"
printf '#!/usr/bin/env bash\necho coolify\n' \
  > "$ATELIER_CONFIG_DIR/plugins/cache/akalab-tech/coolify-integration/0.1.0/scripts/atelier-coolify"
ln -s "$ATELIER_CONFIG_DIR/plugins/cache/akalab-tech/coolify-integration/0.1.0/scripts/atelier-coolify" \
  "$HOME/.local/bin/atelier-coolify"
check_install_mode
grep -q "$OK install mode: managed" "$HOST_OUT" 2>/dev/null \
  && pass "A1: managed mode detected (integration-plugin helper excluded from the calculus)" \
  || fail "A1: no managed OK line (got: $(cat "$HOST_OUT" 2>/dev/null))"
grep -q "matches the plugin cache" "$HOST_OUT" 2>/dev/null \
  && pass "A1: coherence OK (version + content match)" \
  || fail "A1: no coherence OK line (got: $(cat "$HOST_OUT" 2>/dev/null))"
[ ! -f "$FIX_OUT" ] \
  && pass "A1: no fix registered on a coherent managed install" \
  || fail "A1: unexpected fix: $(cat "$FIX_OUT")"

# --- A2: version drift (cache ahead of runtime) ------------------------------
reset_capture
make_managed_home "$TMP/a2"
printf '{"plugins":{"atelier@akalab-tech":[{"scope":"user","installPath":"%s","version":"0.6.0"}]}}\n' \
  "$CACHE" > "$ATELIER_CONFIG_DIR/plugins/installed_plugins.json"
check_install_mode
grep -q "$FAIL runtime version 0.5.0 != plugin cache 0.6.0" "$HOST_OUT" 2>/dev/null \
  && pass "A2: version drift reported runtime-vs-cache" \
  || fail "A2: no version-drift FAIL (got: $(cat "$HOST_OUT" 2>/dev/null))"
grep -q "atelier-update" "$FIX_OUT" 2>/dev/null \
  && pass "A2: fix is atelier-update" \
  || fail "A2: no atelier-update fix (got: $(cat "$FIX_OUT" 2>/dev/null))"

# --- A3: same-version content drift ------------------------------------------
reset_capture
make_managed_home "$TMP/a3"
printf '#!/usr/bin/env bash\necho doctor-PATCHED\n' > "$CACHE/scripts/atelier-doctor"
check_install_mode
grep -q "content drifted from the plugin cache" "$HOST_OUT" 2>/dev/null \
  && pass "A3: same-version content drift detected (scripts/)" \
  || fail "A3: content drift missed (got: $(cat "$HOST_OUT" 2>/dev/null))"
grep -q -- "--from-cache" "$FIX_OUT" 2>/dev/null \
  && pass "A3: fix re-materializes from the cache (--from-cache)" \
  || fail "A3: no --from-cache fix (got: $(cat "$FIX_OUT" 2>/dev/null))"

# --- A4: clone mode -----------------------------------------------------------
reset_capture
HOME="$TMP/a4/home"
ATELIER_RUNTIME_BASE="$HOME/.local/share/atelier"   # does not exist
ATELIER_CONFIG_DIR="$TMP/a4/cfg"
CLONE="$TMP/a4/clone"
mkdir -p "$HOME/.local/bin" "$CLONE/scripts" "$ATELIER_CONFIG_DIR"
git -C "$CLONE" init -q
printf '#!/usr/bin/env bash\necho doctor\n' > "$CLONE/scripts/atelier-doctor"
ln -s "$CLONE/scripts/atelier-doctor" "$HOME/.local/bin/atelier-doctor"
check_install_mode
grep -q "$OK install mode: clone" "$HOST_OUT" 2>/dev/null \
  && pass "A4: clone mode detected as OK (still supported)" \
  || fail "A4: no clone OK line (got: $(cat "$HOST_OUT" 2>/dev/null))"
grep -q "$SKIP managed-runtime migration (optional)" "$HOST_OUT" 2>/dev/null \
  && pass "A4: gentle migration hint present" \
  || fail "A4: no migration hint (got: $(cat "$HOST_OUT" 2>/dev/null))"
[ ! -f "$FIX_OUT" ] \
  && pass "A4: clone mode registers NO fix (doctor stays green)" \
  || fail "A4: unexpected fix: $(cat "$FIX_OUT")"

# --- A5: mixed mode -----------------------------------------------------------
reset_capture
make_managed_home "$TMP/a5"
CLONE="$TMP/a5/clone"
mkdir -p "$CLONE/scripts"
git -C "$CLONE" init -q
printf '#!/usr/bin/env bash\necho update\n' > "$CLONE/scripts/atelier-update"
ln -s "$CLONE/scripts/atelier-update" "$HOME/.local/bin/atelier-update"
check_install_mode
grep -q "$FAIL install mode: mixed" "$HOST_OUT" 2>/dev/null \
  && pass "A5: mixed mode flagged as degraded" \
  || fail "A5: no mixed FAIL (got: $(cat "$HOST_OUT" 2>/dev/null))"
grep -q "atelier-update" "$FIX_OUT" 2>/dev/null \
  && pass "A5: converge fix suggested" \
  || fail "A5: no converge fix (got: $(cat "$FIX_OUT" 2>/dev/null))"

# --- A6: managed but current symlink missing ----------------------------------
reset_capture
make_managed_home "$TMP/a6"
rm "$ATELIER_RUNTIME_BASE/current"
check_install_mode
grep -q "current.*missing\|missing.*current" "$HOST_OUT" 2>/dev/null \
  && pass "A6: missing current symlink reported" \
  || fail "A6: missing current not caught (got: $(cat "$HOST_OUT" 2>/dev/null))"
grep -q "atelier-update" "$FIX_OUT" 2>/dev/null \
  && pass "A6: atelier-update fix offered" \
  || fail "A6: no fix (got: $(cat "$FIX_OUT" 2>/dev/null))"

# --- A7: no helper symlinks at all ---------------------------------------------
reset_capture
HOME="$TMP/a7/home"
ATELIER_RUNTIME_BASE="$HOME/.local/share/atelier"
ATELIER_CONFIG_DIR="$TMP/a7/cfg"
mkdir -p "$HOME/.local/bin" "$ATELIER_CONFIG_DIR"
check_install_mode
grep -q "$FAIL install mode: no atelier-\* helper symlinks" "$HOST_OUT" 2>/dev/null \
  && pass "A7: empty bin dir reported" \
  || fail "A7: no FAIL for empty bin (got: $(cat "$HOST_OUT" 2>/dev/null))"
grep -q "bootstrap.sh" "$FIX_OUT" 2>/dev/null \
  && pass "A7: fix points at the bootstrap one-liner" \
  || fail "A7: no bootstrap fix (got: $(cat "$FIX_OUT" 2>/dev/null))"

# --- A8: all symlinks dangling (deleted clone) ---------------------------------
reset_capture
HOME="$TMP/a8/home"
ATELIER_RUNTIME_BASE="$HOME/.local/share/atelier"
ATELIER_CONFIG_DIR="$TMP/a8/cfg"
mkdir -p "$HOME/.local/bin" "$ATELIER_CONFIG_DIR"
ln -s "$TMP/a8/deleted-clone/scripts/atelier-doctor" "$HOME/.local/bin/atelier-doctor"
ln -s "$TMP/a8/deleted-clone/scripts/atelier-update" "$HOME/.local/bin/atelier-update"
check_install_mode
grep -q "$FAIL install mode: broken (2 dangling helper symlink(s)" "$HOST_OUT" 2>/dev/null \
  && pass "A8: dangling-only install reported as broken (source moved/deleted)" \
  || fail "A8: dangling not diagnosed (got: $(cat "$HOST_OUT" 2>/dev/null))"
grep -q "bootstrap.sh" "$FIX_OUT" 2>/dev/null \
  && pass "A8: fix points at the bootstrap one-liner" \
  || fail "A8: no bootstrap fix (got: $(cat "$FIX_OUT" 2>/dev/null))"

# =============================================================================
# Phase B — check_hooks_liveness() resolves hooks/ from the plugin cache
# when neither $CLAUDE_PLUGIN_ROOT nor a checkout carries hooks/hooks.json
# (the managed-install case: the runtime payload ships no hooks/).
# =============================================================================
echo "Phase B: check_hooks_liveness() plugin-cache fallback"

# Stub `claude` so dep check (e) passes without the real CLI.
mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/claude"
chmod +x "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH"

# --- B1: cache pointer resolves hooks/ ----------------------------------------
reset_capture
HOME="$TMP/b1/home"
ATELIER_CONFIG_DIR="$TMP/b1/cfg"
CACHE="$TMP/b1/cache"
mkdir -p "$HOME" "$ATELIER_CONFIG_DIR/plugins" "$CACHE/hooks/patterns"
cat > "$CACHE/hooks/hooks.json" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}\"/hooks/probe.sh"}]}]}}
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$CACHE/hooks/probe.sh"
chmod +x "$CACHE/hooks/probe.sh"
printf '{"patterns":[]}\n' > "$CACHE/hooks/patterns/secrets.json"
printf '{"plugins":{"atelier@akalab-tech":[{"scope":"user","installPath":"%s","version":"0.5.0"}]}}\n' \
  "$CACHE" > "$ATELIER_CONFIG_DIR/plugins/installed_plugins.json"
unset CLAUDE_PLUGIN_ROOT
check_hooks_liveness
grep -q "hooks/hooks.json valid; all referenced hook scripts present" "$HOST_OUT" 2>/dev/null \
  && pass "B1: manifest check ran against the cache installPath (no clone on disk)" \
  || fail "B1: manifest check did not run (got: $(cat "$HOST_OUT" 2>/dev/null))"
grep -q "catalogues all parse as valid JSON" "$HOST_OUT" 2>/dev/null \
  && pass "B1: pattern-catalogue check ran too" \
  || fail "B1: pattern check missing (got: $(cat "$HOST_OUT" 2>/dev/null))"
if grep -q "$SKIP hook manifest check" "$HOST_OUT" 2>/dev/null; then
  fail "B1: manifest check degraded to SKIP despite the cache pointer"
else
  pass "B1: no SKIP degradation"
fi

# --- B2: no cache pointer → explicit SKIP naming the cache --------------------
reset_capture
HOME="$TMP/b2/home"
ATELIER_CONFIG_DIR="$TMP/b2/cfg"
mkdir -p "$HOME" "$ATELIER_CONFIG_DIR"
check_hooks_liveness
grep -q "$SKIP hook manifest check.*plugin cache" "$HOST_OUT" 2>/dev/null \
  && pass "B2: SKIP wording mentions the plugin cache as a probed location" \
  || fail "B2: SKIP wording stale (got: $(cat "$HOST_OUT" 2>/dev/null))"

# =============================================================================
# Result
# =============================================================================
echo ""
if [ "$fails" -eq 0 ]; then
  echo "doctor-install-mode (#39 F5): all assertions passed."
  exit 0
else
  echo "doctor-install-mode (#39 F5): $fails assertion(s) failed."
  exit 1
fi
