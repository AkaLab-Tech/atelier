#!/usr/bin/env bash
#
# Regression test for #548 — `atelier-release pin-marketplace`.
# Rewrites only the named plugin's `source` to {source, repo, ref, sha};
# other entries stay byte-stable; bad input exits 2 and leaves the file alone.
# Hermetic: pure file edits in a scratch dir.
#
# Run:  hooks/tests/atelier-release-pin-marketplace.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REL="$REPO_ROOT/scripts/atelier-release"
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

SHA="0123456789abcdef0123456789abcdef01234567"
MP="$TMP/marketplace.json"
write_fixture() {
  cat > "$MP" <<'JSON'
{
  "name": "akalab-tech",
  "plugins": [
    { "name": "atelier", "source": { "source": "github", "repo": "AkaLab-Tech/atelier" } },
    { "name": "claude-roadmap-tools", "source": { "source": "github", "repo": "AkaLab-Tech/claude-roadmap-tools" } }
  ]
}
JSON
}

echo "atelier-release pin-marketplace (#548)"

write_fixture
before_other="$(jq -c '.plugins[1]' "$MP")"
out="$(bash "$REL" pin-marketplace --marketplace "$MP" --plugin atelier --tag v1.2.3 --sha "$SHA" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "pin exits 0" || fail "pin rc=$rc (out: $out)"
[ "$(jq -c '.plugins[0].source' "$MP")" = "{\"source\":\"github\",\"repo\":\"AkaLab-Tech/atelier\",\"ref\":\"v1.2.3\",\"sha\":\"$SHA\"}" ] \
  && pass "atelier source is {source, repo, ref, sha}" || fail "atelier source: $(jq -c '.plugins[0].source' "$MP")"
[ "$(jq -c '.plugins[1]' "$MP")" = "$before_other" ] \
  && pass "other plugin entry unchanged" || fail "other entry changed: $(jq -c '.plugins[1]' "$MP")"
[ "$(jq -r '.name' "$MP")" = "akalab-tech" ] && pass "top-level keys preserved" || fail "top-level changed"

# Re-pinning updates ref/sha in place.
SHA2="fedcba9876543210fedcba9876543210fedcba98"
bash "$REL" pin-marketplace --marketplace "$MP" --plugin atelier --tag v1.2.4 --sha "$SHA2" >/dev/null 2>&1
[ "$(jq -r '.plugins[0].source | "\(.ref) \(.sha)"' "$MP")" = "v1.2.4 $SHA2" ] \
  && pass "re-pin replaces ref and sha" || fail "re-pin result: $(jq -c '.plugins[0].source' "$MP")"

# Error cases: exit 2 and file byte-identical.
expect_rc2() { # <label> <file> <args...>
  local label="$1" file="$2"; shift 2
  local snap; snap="$(cat "$file" 2>/dev/null || true)"
  local o rc
  o="$(bash "$REL" pin-marketplace "$@" 2>&1)"; rc=$?
  [ "$rc" -eq 2 ] && pass "$label -> exit 2" || fail "$label expected exit 2, got $rc (out: $o)"
  if [ -f "$file" ]; then
    [ "$(cat "$file")" = "$snap" ] && pass "$label leaves file untouched" || fail "$label modified the file"
  fi
}
write_fixture
expect_rc2 "unknown plugin" "$MP" --marketplace "$MP" --plugin nope --tag v1.0.0 --sha "$SHA"
expect_rc2 "short sha" "$MP" --marketplace "$MP" --plugin atelier --tag v1.0.0 --sha abc123
expect_rc2 "uppercase sha" "$MP" --marketplace "$MP" --plugin atelier --tag v1.0.0 --sha "$(printf '%s' "$SHA" | tr a-f A-F)"
expect_rc2 "non-hex sha" "$MP" --marketplace "$MP" --plugin atelier --tag v1.0.0 --sha "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
expect_rc2 "non-v tag" "$MP" --marketplace "$MP" --plugin atelier --tag 1.0.0 --sha "$SHA"
expect_rc2 "branch-like tag" "$MP" --marketplace "$MP" --plugin atelier --tag main --sha "$SHA"
expect_rc2 "missing file" "$TMP/absent.json" --marketplace "$TMP/absent.json" --plugin atelier --tag v1.0.0 --sha "$SHA"
printf '{ not json' > "$TMP/bad.json"
expect_rc2 "invalid JSON" "$TMP/bad.json" --marketplace "$TMP/bad.json" --plugin atelier --tag v1.0.0 --sha "$SHA"

echo
[ "$fails" -eq 0 ] && { echo "All assertions passed."; exit 0; } || { echo "$fails assertion(s) failed."; exit 1; }
