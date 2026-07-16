#!/usr/bin/env bash
#
# Regression test for #100 — preflight_check's plugin-cache glob fix.
#
# preflight_check (install.sh, phase 0 preflight, M5.0.2/M7.1.F6) decides
# whether $ATELIER_CONFIG_DIR is safe to reuse: 0 = safe (missing, empty,
# marker-complete, or plugin-cache-shaped content), 1 = unrelated content
# (collision), 2 = a crashed prior install (installStatus=in_progress,
# resumable). Before #100 the nullglob match array only checked
# "$dir/plugins"/*/atelier — a config dir whose ONLY content is the real
# plugin-cache layout plugins/cache/<owner>/atelier/<version> fell through
# to the collision branch (1) instead of being recognised as safe (0). The
# fix adds "$dir/plugins/cache"/*/atelier as a second match alternative.
#
# Hermetic: sources install.sh (main-gated) inside a throwaway bash -c
# subshell per case and calls preflight_check directly against mktemp trees.
# No network.
#
# Run:  hooks/tests/preflight-plugin-cache.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "preflight_check plugin-cache glob (#100)"

# ---------------------------------------------------------------------------
# Syntax gate
# ---------------------------------------------------------------------------
bash -n "$INSTALL" \
  && pass "bash -n install.sh" \
  || fail "install.sh has syntax errors"

# preflight_rc <dir> — sources install.sh in a fresh subshell (set -e is
# confined to the subshell, so a nonzero preflight_check return does not
# abort this test script) and prints preflight_check's exact return code.
preflight_rc() {
  INSTALL="$INSTALL" bash -c '
    set -euo pipefail
    # shellcheck disable=SC1090
    source "$INSTALL"
    rc=0
    preflight_check "$1" || rc=$?
    printf "%s\n" "$rc"
  ' probe "$1"
}

# ---------------------------------------------------------------------------
# main-gate: sourcing install.sh must not run main.
# ---------------------------------------------------------------------------
gate_out="$(INSTALL="$INSTALL" bash -c 'set -euo pipefail; source "$INSTALL"' 2>&1)"
gate_rc=$?
if [ "$gate_rc" -eq 0 ] && ! printf '%s' "$gate_out" | grep -q 'install.sh starting'; then
  pass "main-gate: sourcing install.sh defines functions, does not run main"
else
  fail "main-gate: sourcing ran main or exited $gate_rc (out: $gate_out)"
fi

# ---------------------------------------------------------------------------
# Case 1 (the regression): dir whose ONLY content is the real plugin-cache
# layout plugins/cache/<owner>/atelier/<version> → safe (0).
# ---------------------------------------------------------------------------
CACHE_ONLY="$TMP/cache-only"
mkdir -p "$CACHE_ONLY/plugins/cache/akalab-tech/atelier/1.2.3"
rc="$(preflight_rc "$CACHE_ONLY")"
[ "$rc" = "0" ] \
  && pass "plugins/cache/<owner>/atelier/<version>-only dir: preflight_check returns 0" \
  || fail "plugins/cache layout: expected rc=0, got '$rc'"

# ---------------------------------------------------------------------------
# Case 2: empty dir → safe (0).
# ---------------------------------------------------------------------------
EMPTY="$TMP/empty"
mkdir -p "$EMPTY"
rc="$(preflight_rc "$EMPTY")"
[ "$rc" = "0" ] \
  && pass "empty dir: preflight_check returns 0" \
  || fail "empty dir: expected rc=0, got '$rc'"

# ---------------------------------------------------------------------------
# Case 3: nonexistent dir → safe (0).
# ---------------------------------------------------------------------------
MISSING="$TMP/does-not-exist"
rc="$(preflight_rc "$MISSING")"
[ "$rc" = "0" ] \
  && pass "nonexistent dir: preflight_check returns 0" \
  || fail "nonexistent dir: expected rc=0, got '$rc'"

# ---------------------------------------------------------------------------
# Case 4: unrelated content only (no plugins/, no marker) → collision (1).
# ---------------------------------------------------------------------------
UNRELATED="$TMP/unrelated"
mkdir -p "$UNRELATED"
printf 'some stray file\n' > "$UNRELATED/stray.txt"
rc="$(preflight_rc "$UNRELATED")"
[ "$rc" = "1" ] \
  && pass "unrelated content (stray file, no plugins/): preflight_check returns 1" \
  || fail "unrelated content: expected rc=1, got '$rc'"

# ---------------------------------------------------------------------------
# Case 4b: a plugins/ tree present but with NO atelier match anywhere in it
# (neither plugins/*/atelier nor plugins/cache/*/atelier) still collides (1)
# — the fix must not turn preflight_check into an "any plugins/ dir is fine"
# check.
# ---------------------------------------------------------------------------
OTHER_PLUGIN="$TMP/other-plugin"
mkdir -p "$OTHER_PLUGIN/plugins/cache/some-owner/not-atelier/1.0.0"
rc="$(preflight_rc "$OTHER_PLUGIN")"
[ "$rc" = "1" ] \
  && pass "plugins/cache tree present but no atelier match: preflight_check returns 1" \
  || fail "non-atelier plugins/cache content: expected rc=1, got '$rc'"

# ---------------------------------------------------------------------------
# Case 4c: the legacy (pre-cache) layout plugins/<owner>/atelier — the OTHER
# match alternative in the same array — still recognised as safe (0). Proves
# the fix is additive, not a replacement of the pre-existing pattern.
# ---------------------------------------------------------------------------
LEGACY="$TMP/legacy-plugins"
mkdir -p "$LEGACY/plugins/akalab-tech/atelier"
rc="$(preflight_rc "$LEGACY")"
[ "$rc" = "0" ] \
  && pass "legacy plugins/<owner>/atelier layout: preflight_check returns 0" \
  || fail "legacy plugins layout: expected rc=0, got '$rc'"

# ---------------------------------------------------------------------------
# Case 5a: .atelier-managed marker with installStatus=in_progress (a crashed
# prior install, M7.1.F6) → resumable (2), even alongside a plugin-cache dir.
# ---------------------------------------------------------------------------
IN_PROGRESS="$TMP/in-progress"
mkdir -p "$IN_PROGRESS/plugins/cache/akalab-tech/atelier/1.2.3"
cat > "$IN_PROGRESS/.atelier-managed" <<'MARKER'
{
  "managedBy": "atelier",
  "installStatus": "in_progress",
  "pid": 12345,
  "startedAt": "2026-01-01T00:00:00Z",
  "atelierConfigDir": "/tmp/in-progress"
}
MARKER
rc="$(preflight_rc "$IN_PROGRESS")"
[ "$rc" = "2" ] \
  && pass "in_progress .atelier-managed marker: preflight_check returns 2 (resumable)" \
  || fail "in_progress marker: expected rc=2, got '$rc'"

# ---------------------------------------------------------------------------
# Case 5b: .atelier-managed marker with installStatus=complete → safe (0).
# ---------------------------------------------------------------------------
COMPLETE="$TMP/complete"
mkdir -p "$COMPLETE"
cat > "$COMPLETE/.atelier-managed" <<'MARKER'
{
  "managedBy": "atelier",
  "installStatus": "complete",
  "completedAt": "2026-01-01T00:00:00Z",
  "installerVersion": "0.1.0",
  "atelierConfigDir": "/tmp/complete"
}
MARKER
rc="$(preflight_rc "$COMPLETE")"
[ "$rc" = "0" ] \
  && pass "complete .atelier-managed marker: preflight_check returns 0" \
  || fail "complete marker: expected rc=0, got '$rc'"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "preflight-plugin-cache: all assertions passed."
  exit 0
else
  echo "preflight-plugin-cache: $fails assertion(s) failed."
  exit 1
fi
