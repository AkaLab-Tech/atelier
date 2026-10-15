#!/usr/bin/env bash
#
# Regression test for #456 — scripts/atelier-automode-sync merges atelier's
# managed autoMode.allow entry (templates/automode.user.json) into the
# user-level $ATELIER_CONFIG_DIR/settings.json.
#
#   S1  read-only by default: no write without --apply (exit 1, diff printed)
#   S2  absent file + --apply -> {"autoMode":{"allow":["$defaults", managed]}}
#   S3  operator-shaped fixture: entries/order/other keys preserved, managed appended
#   S4  stale managed entry replaced in place; obsolete managed entry removed
#   S5  no "$defaults" in the operator's array -> none is added
#   S6  idempotent: second --apply is byte-identical, read-only run exits 0
#   S7  invalid JSON / non-array allow -> untouched, rc 0, warning
#   S8  exit codes (2 on missing template / unknown flag), --help
#   S9  no temp files left; real ~/.claude* never touched (scratch HOME)
#
# Fixtures are synthetic. Hermetic: scratch HOME + ATELIER_CONFIG_DIR.
#
# Run:  hooks/tests/automode-user-sync.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYNC="$REPO_ROOT/scripts/atelier-automode-sync"
TEMPLATE="$REPO_ROOT/templates/automode.user.json"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "atelier-automode-sync (#456)"

MANAGED="$(jq -c '.autoMode.allow[0]' "$TEMPLATE")"
MANAGED_TXT="$(jq -r '.autoMode.allow[0]' "$TEMPLATE")"
case "$MANAGED_TXT" in '[atelier-managed:gate-runs] '*) pass "template entry starts with the gate-runs marker" ;; *) fail "template entry lacks marker" ;; esac

# run <cfg> [args...] — prints combined output, then RC=<n>.
run() {
  local cfg="$1"; shift
  ATELIER_CONFIG_DIR="$cfg" NO_COLOR=1 "$SYNC" "$@" 2>&1
  echo "RC=$?"
}

# S1 --------------------------------------------------------------------
CFG="$TMP/s1"; mkdir -p "$CFG"
printf '{"model":"opus"}\n' > "$CFG/settings.json"
before="$(cat "$CFG/settings.json")"
out="$(run "$CFG")"
[ "$before" = "$(cat "$CFG/settings.json")" ] && pass "S1: no write without --apply" || fail "S1: file changed"
printf '%s' "$out" | grep -q 'RC=1' && pass "S1: read-only run exits 1 (out of sync)" || fail "S1: rc (out: $out)"
printf '%s' "$out" | grep -qF '+ [gate-runs]' && pass "S1: prints the + diff line for gate-runs" || fail "S1: no diff line (out: $out)"
printf '%s' "$out" | grep -q 'Read-only: nothing written' && pass "S1: footer says nothing written" || fail "S1: no footer"
out="$(run "$CFG" --quiet)"
printf '%s' "$out" | grep -q 'Read-only: nothing written' && fail "S1: --quiet still prints footer" || pass "S1: --quiet omits the footer"

# S2 --------------------------------------------------------------------
CFG="$TMP/s2"
out="$(run "$CFG" --apply)"
printf '%s' "$out" | grep -q 'RC=0' && pass "S2: --apply on absent config dir exits 0" || fail "S2: rc (out: $out)"
want="$(jq -nc --argjson m "$MANAGED" '{autoMode:{allow:(["$defaults"] + [$m])}}')"
[ "$(jq -c . "$CFG/settings.json" 2>/dev/null)" = "$want" ] \
  && pass "S2: absent file -> [\"\$defaults\", managed] only" || fail "S2: got $(cat "$CFG/settings.json" 2>&1)"
# existing file without autoMode
CFG="$TMP/s2b"; mkdir -p "$CFG"
printf '{"env":{"K":"v"}}\n' > "$CFG/settings.json"
run "$CFG" --apply >/dev/null
[ "$(jq -c . "$CFG/settings.json")" = "$(jq -nc --argjson m "$MANAGED" '{env:{K:"v"},autoMode:{allow:(["$defaults",$m])}}')" ] \
  && pass "S2: file without autoMode gets \$defaults + managed, env untouched" || fail "S2b: got $(cat "$CFG/settings.json")"

# S3 --------------------------------------------------------------------
CFG="$TMP/s3"; mkdir -p "$CFG"
cat > "$CFG/settings.json" <<'JSON'
{
  "permissions": {"defaultMode": "auto", "allow": ["Bash(ls *)"]},
  "model": "opus",
  "autoMode": {
    "environment": ["Repos live under ~/Work", "Staging is fake-staging.example.test"],
    "soft_deny": ["Never touch ~/Documents"],
    "allow": [
      "Reading files under ~/Work is fine",
      "$defaults",
      "Running linters in ~/Work/demo is fine",
      "Fetching docs from docs.example.test is fine",
      "Rule four, with | a pipe",
      "Rule five"
    ]
  }
}
JSON
cp "$CFG/settings.json" "$TMP/s3.orig"
run "$CFG" --apply >/dev/null
got="$(jq -c '.autoMode.allow' "$CFG/settings.json")"
want="$(jq -c --argjson m "$MANAGED" '.autoMode.allow + [$m]' "$TMP/s3.orig")"
[ "$got" = "$want" ] && pass "S3: 6 operator entries keep text and order (\$defaults at index 1), managed appended last" || fail "S3: got $got"
[ "$(jq -c 'del(.autoMode.allow)' "$CFG/settings.json")" = "$(jq -c 'del(.autoMode.allow)' "$TMP/s3.orig")" ] \
  && pass "S3: environment, soft_deny, permissions, model unchanged" || fail "S3: other keys changed"

# S4 --------------------------------------------------------------------
CFG="$TMP/s4"; mkdir -p "$CFG"
cat > "$CFG/settings.json" <<'JSON'
{"autoMode":{"allow":["Rule A","[atelier-managed:gate-runs] OLD stale text","$defaults","[atelier-managed:retired-rule] gone now","Rule B"]}}
JSON
out="$(run "$CFG")"
printf '%s' "$out" | grep -qF '~ [gate-runs]' && pass "S4: diff shows ~ for the stale entry" || fail "S4: no ~ line (out: $out)"
printf '%s' "$out" | grep -qF -- '- [retired-rule]' && pass "S4: diff shows - for the retired entry" || fail "S4: no - line (out: $out)"
run "$CFG" --apply >/dev/null
[ "$(jq -c '.autoMode.allow' "$CFG/settings.json")" = "$(jq -nc --argjson m "$MANAGED" '["Rule A",$m,"$defaults","Rule B"]')" ] \
  && pass "S4: stale replaced in place (same position), retired removed, operator entries kept" || fail "S4: got $(jq -c '.autoMode.allow' "$CFG/settings.json")"

# S5 --------------------------------------------------------------------
CFG="$TMP/s5"; mkdir -p "$CFG"
printf '{"autoMode":{"allow":["Only my rule"]}}\n' > "$CFG/settings.json"
run "$CFG" --apply >/dev/null
[ "$(jq -c '.autoMode.allow' "$CFG/settings.json")" = "$(jq -nc --argjson m "$MANAGED" '["Only my rule",$m]')" ] \
  && pass "S5: no \$defaults added to an array that lacks one" || fail "S5: got $(jq -c '.autoMode.allow' "$CFG/settings.json")"

# S6 --------------------------------------------------------------------
for c in s2 s3 s4 s5; do
  CFG="$TMP/$c"
  cp "$CFG/settings.json" "$TMP/$c.after1"
  out="$(run "$CFG")"
  printf '%s' "$out" | grep -q 'RC=0' && printf '%s' "$out" | grep -q 'already in sync' \
    && pass "S6/$c: read-only run on synced file exits 0 'already in sync'" || fail "S6/$c: (out: $out)"
  run "$CFG" --apply >/dev/null
  cmp -s "$CFG/settings.json" "$TMP/$c.after1" && pass "S6/$c: second --apply is byte-identical" || fail "S6/$c: file changed on second apply"
done

# S7 --------------------------------------------------------------------
CFG="$TMP/s7"; mkdir -p "$CFG"
printf '{ not json' > "$CFG/settings.json"
out="$(run "$CFG" --apply)"
[ "$(cat "$CFG/settings.json")" = '{ not json' ] && pass "S7: invalid JSON left untouched" || fail "S7: rewritten"
printf '%s' "$out" | grep -q 'not valid JSON' && printf '%s' "$out" | grep -q 'RC=0' \
  && pass "S7: warns and exits 0" || fail "S7: (out: $out)"
CFG="$TMP/s7b"; mkdir -p "$CFG"
printf '{"autoMode":{"allow":"nope"}}\n' > "$CFG/settings.json"
cp "$CFG/settings.json" "$TMP/s7b.orig"
out="$(run "$CFG" --apply)"
cmp -s "$CFG/settings.json" "$TMP/s7b.orig" && printf '%s' "$out" | grep -q 'RC=0' && printf '%s' "$out" | grep -q 'non-array' \
  && pass "S7: non-array autoMode.allow left untouched, warned, rc 0" || fail "S7b: (out: $out)"

# S8 --------------------------------------------------------------------
out="$(run "$TMP/s8" --template "$TMP/missing.json")"
printf '%s' "$out" | grep -q 'RC=2' && pass "S8: missing template exits 2" || fail "S8: (out: $out)"
printf '{"autoMode":{"allow":"x"}}\n' > "$TMP/badtmpl.json"
out="$(run "$TMP/s8" --template "$TMP/badtmpl.json")"
printf '%s' "$out" | grep -q 'RC=2' && pass "S8: template without allow array exits 2" || fail "S8: (out: $out)"
out="$(run "$TMP/s8" --bogus)"
printf '%s' "$out" | grep -q 'RC=2' && pass "S8: unknown flag exits 2" || fail "S8: (out: $out)"
out="$(run "$TMP/s8" --help)"
printf '%s' "$out" | grep -q 'RC=0' && printf '%s' "$out" | grep -q -- '--apply' && pass "S8: --help exits 0 and documents --apply" || fail "S8: help (out: $out)"
[ ! -e "$TMP/s8" ] && pass "S8: failed runs create nothing" || fail "S8: created $TMP/s8"
# --config-dir flag and custom template
CFG="$TMP/s8c"
printf '{"autoMode":{"allow":["[atelier-managed:x] custom"]}}\n' > "$TMP/custom.json"
"$SYNC" --apply --template "$TMP/custom.json" --config-dir "$CFG" >/dev/null 2>&1
[ "$(jq -c '.autoMode.allow' "$CFG/settings.json" 2>/dev/null)" = '["$defaults","[atelier-managed:x] custom"]' ] \
  && pass "S8: --config-dir and --template honored" || fail "S8c: got $(cat "$CFG/settings.json" 2>&1)"

# S9 --------------------------------------------------------------------
leftover="$(find "$TMP" -name 'settings.json.atelier.*' | head -1)"
[ -z "$leftover" ] && pass "S9: no temp files left behind" || fail "S9: leftover $leftover"
[ -z "$(ls -A "$HOME")" ] && pass "S9: scratch HOME untouched (no ~/.claude*)" || fail "S9: HOME touched: $(ls -A "$HOME")"

echo ""
if [ "$fails" -eq 0 ]; then echo "automode-user-sync: all assertions passed."; exit 0
else echo "automode-user-sync: $fails assertion(s) failed."; exit 1; fi
