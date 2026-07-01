#!/usr/bin/env bash
#
# Tests for issue #281 — doctor version_cmp() + check_plugin_drift() semver
# ordering. Before the fix, check_plugin_drift() compared local vs upstream
# with plain string equality: any mismatch was reported "✗ local → upstream"
# and offered `claude plugin update`, EVEN WHEN the local build was newer than
# the published tag. On a dev/self-dev host that is a false-positive whose
# "fix" downgrades the plugin.
#
# COVERAGE
#   Phase A — version_cmp() unit table (pure function):
#     equal, a<b, a>b, differing segment counts, multi-digit (0.10 > 0.9,
#     0.36 > 0.9), pre-release/build suffixes stripped, leading zeros safe.
#   Phase B — check_plugin_drift() branch selection (deps stubbed):
#     B1 equal     (0.7.0 / 0.7.0)  → OK "up to date",          no fix
#     B2 behind    (0.6.0 / 0.7.0)  → FAIL "→",                  two fix_auto
#     B3 ahead     (0.8.0 / 0.7.0)  → OK "ahead of published",  no fix   (#281)
#     B4 ahead-2dig(0.10.0 / 0.9.0) → OK "ahead of published",  no fix
#
# Hermetic: `claude` is stubbed on PATH; fetch_upstream_version / strip_v /
# push_* are shell stubs. No network, no real plugin state. macOS bash 3.2 ok.
#
# Run:  hooks/tests/doctor-semver-drift.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/atelier-doctor"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# Extract version_cmp() and check_plugin_drift() from atelier-doctor.
FN_FILE="$TMP/fns.sh"
awk '/^version_cmp\(\) \{/{f=1} f{print} f&&/^\}/{f=0} /^check_plugin_drift\(\) \{/{g=1} g{print} g&&/^\}/{g=0}' \
  "$DOCTOR" > "$FN_FILE"
if ! grep -q 'version_cmp()' "$FN_FILE" || ! grep -q 'ahead of published' "$FN_FILE"; then
  echo "  FAIL: could not extract version_cmp/check_plugin_drift from $DOCTOR"
  exit 1
fi
# shellcheck disable=SC1090
source "$FN_FILE"

# =============================================================================
# Phase A — version_cmp() unit table
# =============================================================================
echo "Phase A: version_cmp() numeric ordering"

check_cmp() {
  local a="$1" b="$2" want="$3" got
  got="$(version_cmp "$a" "$b")"
  if [ "$got" = "$want" ]; then
    pass "version_cmp $a $b = $want"
  else
    fail "version_cmp $a $b = $got (want $want)"
  fi
}

check_cmp 0.7.0   0.7.0   0
check_cmp 0.6.0   0.7.0   -1
check_cmp 0.8.0   0.7.0   1
check_cmp 0.7.0   0.7.1   -1
check_cmp 1.0.0   0.9.9   1
check_cmp 0.10.0  0.9.0   1      # multi-digit: 10 > 9 (string compare would fail)
check_cmp 0.36.0  0.9.0   1      # the real atelier row: 36 > 9
check_cmp 0.7     0.7.0   0      # differing segment counts, missing = 0
check_cmp 0.7.0   0.7     0
check_cmp v0.8.0  0.7.0   1      # a stray leading v is tolerated by the strip
check_cmp 0.8.0-rc1 0.8.0 0      # pre-release suffix dropped -> numeric core equal
check_cmp 0.08.0  0.8.0   0      # leading zero not treated as octal

# =============================================================================
# Phase B — check_plugin_drift() branch selection (deps stubbed)
# =============================================================================
echo "Phase B: check_plugin_drift() branch selection"

# Doctor infrastructure + symbols the extracted function references.
PLUGIN_OUT="$TMP/plugin_out"
FIX_AUTO_OUT="$TMP/fix_auto_out"
push_plugin()   { printf '%s\n' "$*" >> "$PLUGIN_OUT"; }
push_fix_auto() { printf '%s\n' "$*" >> "$FIX_AUTO_OUT"; }
strip_v()       { printf '%s' "${1#v}"; }
OK="✓"; FAIL="✗"; SKIP="–"
ATELIER_CONFIG_DIR="$TMP/cfg"; mkdir -p "$ATELIER_CONFIG_DIR"

# fetch_upstream_version is overridden to return the scenario's published tag.
fetch_upstream_version() { printf '%s' "${UPSTREAM_VERSION:-0.0.0}"; }

# Stub `claude plugin list --json` to report the scenario's local version.
mkdir -p "$TMP/bin"; export PATH="$TMP/bin:$PATH"
cat > "$TMP/bin/claude" << 'SHIMEOF'
#!/usr/bin/env bash
case "$*" in
  *"plugin list --json"*)
    printf '[{"id":"testplugin","version":"%s"}]\n' "${LOCAL_VERSION:-0.0.0}"
    ;;
  *) exit 0 ;;
esac
SHIMEOF
chmod +x "$TMP/bin/claude"

reset_capture() { rm -f "$PLUGIN_OUT" "$FIX_AUTO_OUT"; }

# B1 — equal → OK up-to-date, no fix
reset_capture
export LOCAL_VERSION="0.7.0" UPSTREAM_VERSION="0.7.0"
check_plugin_drift testplugin AkaLab-Tech/example
if grep -q "up to date" "$PLUGIN_OUT" 2>/dev/null; then
  pass "B1: equal → 'up to date'"
else
  fail "B1: equal → expected 'up to date' (got: $(cat "$PLUGIN_OUT" 2>/dev/null || printf '<nothing>'))"
fi
[ ! -f "$FIX_AUTO_OUT" ] && pass "B1: equal → no fix_auto" || fail "B1: unexpected fix_auto: $(cat "$FIX_AUTO_OUT")"

# B2 — behind → FAIL arrow, two fix_auto commands
reset_capture
export LOCAL_VERSION="0.6.0" UPSTREAM_VERSION="0.7.0"
check_plugin_drift testplugin AkaLab-Tech/example
if grep -q "$FAIL testplugin 0.6.0 → 0.7.0" "$PLUGIN_OUT" 2>/dev/null; then
  pass "B2: behind → '✗ … → …'"
else
  fail "B2: behind → expected '✗ 0.6.0 → 0.7.0' (got: $(cat "$PLUGIN_OUT" 2>/dev/null || printf '<nothing>'))"
fi
if [ -f "$FIX_AUTO_OUT" ] && [ "$(wc -l < "$FIX_AUTO_OUT")" -eq 2 ]; then
  pass "B2: behind → two fix_auto commands"
else
  fail "B2: behind → expected two fix_auto (got: $(cat "$FIX_AUTO_OUT" 2>/dev/null || printf '<nothing>'))"
fi

# B3 — ahead → OK 'ahead of published', NO fix (the #281 case)
reset_capture
export LOCAL_VERSION="0.8.0" UPSTREAM_VERSION="0.7.0"
check_plugin_drift testplugin AkaLab-Tech/example
if grep -q "$OK testplugin 0.8.0 (ahead of published 0.7.0)" "$PLUGIN_OUT" 2>/dev/null; then
  pass "B3: ahead → '✓ … (ahead of published …)'"
else
  fail "B3: ahead → expected '✓ 0.8.0 (ahead of published 0.7.0)' (got: $(cat "$PLUGIN_OUT" 2>/dev/null || printf '<nothing>'))"
fi
[ ! -f "$FIX_AUTO_OUT" ] && pass "B3: ahead → no fix_auto (no downgrade proposed)" \
  || fail "B3: ahead → unexpected fix_auto: $(cat "$FIX_AUTO_OUT")"

# B4 — ahead by a multi-digit minor (0.10.0 > 0.9.0) → same as B3
reset_capture
export LOCAL_VERSION="0.10.0" UPSTREAM_VERSION="0.9.0"
check_plugin_drift testplugin AkaLab-Tech/example
if grep -q "ahead of published 0.9.0" "$PLUGIN_OUT" 2>/dev/null; then
  pass "B4: ahead multi-digit (0.10.0 > 0.9.0) → 'ahead of published'"
else
  fail "B4: ahead multi-digit → expected 'ahead of published 0.9.0' (got: $(cat "$PLUGIN_OUT" 2>/dev/null || printf '<nothing>'))"
fi
[ ! -f "$FIX_AUTO_OUT" ] && pass "B4: ahead multi-digit → no fix_auto" \
  || fail "B4: ahead multi-digit → unexpected fix_auto: $(cat "$FIX_AUTO_OUT")"

# =============================================================================
# Result
# =============================================================================
echo ""
if [ "$fails" -eq 0 ]; then
  echo "doctor-semver-drift (#281): all assertions passed."
  exit 0
else
  echo "doctor-semver-drift (#281): $fails assertion(s) failed."
  exit 1
fi
