#!/usr/bin/env bash
#
# Tests for #545 — `atelier-size-waiver --package-json-version-only` (guardrail 4 exemption).
#
# Hermetic: `gh` is a PATH shim serving fixtures from $FIX:
#   - `gh api repos/<r>/pulls/<NN>`                    -> "<base>\t<head>" (the --jq result)
#   - `gh api repos/<r>/compare/<base>...<head>`       -> the merge-base sha
#   - `gh api repos/<r>/contents/package.json?ref=<s>` -> $FIX/pkg.<s> (raw file); missing -> failure
#   - $FIX/fail makes every gh call fail.
#
# Run:  hooks/tests/package-json-version-only.test.sh
# Exit: 0 = all passed, 1 = at least one failed.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/scripts/atelier-size-waiver"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fix"; mkdir -p "$TMP/bin" "$FIX"

PASS=0; FAILN=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAILN=$((FAILN+1)); echo "  FAIL: $1"; }

cat > "$TMP/bin/gh" << 'SHIMEOF'
#!/usr/bin/env bash
[ -f "$FIX/fail" ] && { echo "gh: boom" >&2; exit 1; }
[ "$1" = api ] || { echo "gh-stub: unexpected: $*" >&2; exit 1; }
case "$2" in
  repos/*/pulls/*) printf 'BASE0\tHEAD0\n' ;;
  repos/*/compare/*) printf 'MB0\n' ;;
  repos/*/contents/package.json\?ref=*)
    f="$FIX/pkg.${2##*ref=}"
    [ -f "$f" ] && cat "$f" || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *) echo "gh-stub: unexpected: $*" >&2; exit 1 ;;
esac
SHIMEOF
chmod +x "$TMP/bin/gh"
export FIX PATH="$TMP/bin:$PATH"

# setup <base-package.json> <head-package.json>  (merge base = MB0, head = HEAD0)
setup() { rm -f "$FIX"/fail "$FIX"/pkg.*; printf '%s' "$1" > "$FIX/pkg.MB0"; printf '%s' "$2" > "$FIX/pkg.HEAD0"; }
check() { # label want rc
  OUT="$(bash "$HELPER" --package-json-version-only o/r 7 2>/dev/null)"; RC=$?
  if [ "$OUT" = "$2" ] && [ "$RC" = "$3" ]; then pass "$1"; else fail "$1 — got '$OUT' rc=$RC, want '$2' rc=$3"; fi
}

echo "== version-only =="
setup '{"name":"x","version":"1.0.0","dependencies":{"a":"1"}}' '{"name":"x","version":"1.0.1","dependencies":{"a":"1"}}'
check "version bump only -> version-only" "package-json=version-only" 0

setup '{"name":"x","version":"1.0.0","scripts":{"t":"y"}}' '{"scripts":{"t":"y"},"version":"2.0.0","name":"x"}'
check "version bump with reordered keys -> version-only" "package-json=version-only" 0

setup '{"name":"x","version":"1.0.0"}' '{"name":"x","version":"1.0.0"}'
check "identical package.json -> version-only" "package-json=version-only" 0

echo "== changed =="
setup '{"name":"x","version":"1.0.0"}' '{"name":"x","version":"1.0.1","scripts":{"postinstall":"curl evil"}}'
check "version plus an added key -> changed" "package-json=changed" 1

setup '{"name":"x","version":"1.0.0","dependencies":{"a":"1"}}' '{"name":"x","version":"1.0.1","dependencies":{"a":"2"}}'
check "version plus a dependency change -> changed" "package-json=changed" 1

setup '{"name":"x","version":"1.0.0"}' '{"name":"y","version":"1.0.0"}'
check "name change without version change -> changed" "package-json=changed" 1

setup '{"name":"x","version":"1.0.0","a":{"version":"1"}}' '{"name":"x","version":"1.0.0","a":{"version":"2"}}'
check "nested version key change -> changed (only top-level exempt)" "package-json=changed" 1

echo "== fail closed (exit 2) =="
setup '{"name":"x","version":"1.0.0"}' '{"name":"x", "version": '
check "invalid head JSON -> exit 2, no pass" "" 2

setup 'not json' '{"name":"x","version":"1.0.1"}'
check "invalid base JSON -> exit 2, no pass" "" 2

setup '{"name":"x"}' '{"name":"x"}'
rm -f "$FIX/pkg.HEAD0"
check "head package.json unreadable -> exit 2" "" 2

setup '{"name":"x"}' '{"name":"x"}'
touch "$FIX/fail"
check "gh failure -> exit 2" "" 2

bash "$HELPER" --package-json-version-only o/r >/dev/null 2>&1; RC=$?
if [ "$RC" = 2 ]; then pass "missing PR number -> exit 2"; else fail "missing PR number exit code $RC"; fi

echo
echo "Results: $PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
