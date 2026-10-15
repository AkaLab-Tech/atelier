#!/usr/bin/env bash
#
# Regression test for #488 — `atelier-automode-sync --replace-path OLD=NEW`.
# Dry-run is read-only (exit 1 when replacements are pending, 0 when none);
# --apply rewrites only whole-path occurrences of OLD inside the six arrays
# autoMode.{allow,soft_deny,environment} and permissions.{allow,deny,ask},
# leaving every other key, the entry order and `[atelier-managed:*]` entries
# untouched; a malformed argument exits 2.
#
# Hermetic: --config-dir points at a temp dir; no network.
#
# Run:  hooks/tests/automode-replace-path.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-automode-sync"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

CFG="$TMP/config"
mkdir -p "$CFG"
S="$CFG/settings.json"
OLD="/x/atelier-dev"
NEW="/y/atelier"

write_fixture() {
  cat > "$S" <<'JSON'
{
  "model": "opus",
  "env": {"HOME_PROJECT": "/x/atelier-dev"},
  "permissions": {
    "additionalDirectories": ["/x/atelier-dev"],
    "allow": [
      "Bash(ls)",
      "Edit(/x/atelier-dev/**)",
      "Bash(cd /x/atelier-dev && git status)",
      "Read(/x/atelier-dev2/**)",
      "Read(/other/x/atelier-dev/**)",
      "Read(/x/atelier-dev-old/**)",
      "[atelier-managed:keep] Never push to main",
      "Edit(/x/atelier-dev/a) and Edit(/x/atelier-dev/b)"
    ],
    "deny": ["Edit(/x/atelier-dev/.env*)"],
    "ask": ["/x/atelier-dev"]
  },
  "autoMode": {
    "allow": ["Work in /x/atelier-dev.", "[atelier-managed:m1] managed rule", 42],
    "soft_deny": ["Do not delete /x/atelier-dev/ ever"],
    "environment": ["Project lives at /x/atelier-dev, sibling /x/atelier-dev2"],
    "other": ["/x/atelier-dev"]
  }
}
JSON
}

run() { bash "$SCRIPT" --config-dir "$CFG" "$@" 2>&1; }

# ---------- case 1: dry-run is read-only, exit 1 when pending ----------
write_fixture
before="$(cksum < "$S")"
out="$(run --replace-path "$OLD=$NEW")"; rc=$?
[ "$rc" -eq 1 ] && pass "dry-run with pending replacements exits 1" || fail "dry-run exit $rc: $out"
[ "$before" = "$(cksum < "$S")" ] && pass "dry-run leaves settings.json byte-identical" || fail "dry-run modified settings.json"
ls "$CFG" | grep -q 'atelier\.' && fail "dry-run left a temp file" || pass "dry-run leaves no temp file"
case "$out" in *"permissions.allow[1]"*"- Edit($OLD/**)"*"+ Edit($NEW/**)"*) pass "dry-run prints a before/after diff for permissions.allow[1]" ;;
  *) fail "diff missing: $out" ;; esac
case "$out" in *"Read-only: nothing written"*) pass "dry-run says nothing was written" ;; *) fail "no read-only footer: $out" ;; esac
case "$out" in *"permissions.allow[3]"*|*"permissions.allow[4]"*|*"permissions.allow[5]"*|*"permissions.allow[6]"*)
  fail "diff lists a sibling/prefix entry as changed: $out" ;;
  *) pass "diff lists no sibling/prefix entry as changed" ;; esac

# ---------- case 2: --apply rewrites only whole-path occurrences ----------
out="$(run --replace-path "$OLD=$NEW" --apply)"; rc=$?
[ "$rc" -eq 0 ] && pass "--apply exits 0" || fail "--apply exit $rc: $out"
case "$out" in *"Applied: path replacements written"*) pass "--apply reports the write" ;; *) fail "no Applied line: $out" ;; esac
jq -e . "$S" >/dev/null 2>&1 && pass "result is valid JSON" || fail "result is not valid JSON"
expected="$(jq -n '{
  model: "opus",
  env: {HOME_PROJECT: "/x/atelier-dev"},
  permissions: {
    additionalDirectories: ["/x/atelier-dev"],
    allow: [
      "Bash(ls)",
      "Edit(/y/atelier/**)",
      "Bash(cd /y/atelier && git status)",
      "Read(/x/atelier-dev2/**)",
      "Read(/other/x/atelier-dev/**)",
      "Read(/x/atelier-dev-old/**)",
      "[atelier-managed:keep] Never push to main",
      "Edit(/y/atelier/a) and Edit(/y/atelier/b)"
    ],
    deny: ["Edit(/y/atelier/.env*)"],
    ask: ["/y/atelier"]
  },
  autoMode: {
    allow: ["Work in /y/atelier.", "[atelier-managed:m1] managed rule", 42],
    soft_deny: ["Do not delete /y/atelier/ ever"],
    environment: ["Project lives at /y/atelier, sibling /x/atelier-dev2"],
    other: ["/x/atelier-dev"]
  }
}')"
[ "$(jq -S . "$S")" = "$(jq -S . <<<"$expected")" ] && pass "all six arrays rewritten; sibling/prefix/embedded paths, other keys and non-strings untouched" \
  || fail "unexpected result: $(diff <(jq -S . <<<"$expected") <(jq -S . "$S"))"
# Order of entries preserved (jq -S sorts keys, not array elements; compare arrays directly).
[ "$(jq -c '.permissions.allow' "$S")" = "$(jq -c '.permissions.allow' <<<"$expected")" ] && pass "entry order preserved" || fail "entry order changed"
[ "$(jq -r '.autoMode.allow[1]' "$S")" = "[atelier-managed:m1] managed rule" ] && pass "[atelier-managed:*] entry untouched" || fail "managed entry changed"
ls "$CFG" | grep -q 'atelier\.' && fail "--apply left a temp file" || pass "--apply leaves no temp file"

# ---------- case 3: nothing to replace -> exit 0, no write ----------
before="$(cksum < "$S")"
out="$(run --replace-path "$OLD=$NEW")"; rc=$?
[ "$rc" -eq 0 ] && pass "dry-run with nothing pending exits 0" || fail "nothing-pending exit $rc: $out"
case "$out" in *"No whole-path occurrence to replace"*) pass "says there is nothing to replace" ;; *) fail "no nothing-to-do message: $out" ;; esac
out="$(run --replace-path "$OLD=$NEW" --apply)"; rc=$?
[ "$rc" -eq 0 ] && [ "$before" = "$(cksum < "$S")" ] && pass "--apply with nothing pending exits 0 and does not rewrite" || fail "apply-none: rc=$rc"

# ---------- case 4: trailing slashes normalised; repeatable flag ----------
write_fixture
out="$(run --replace-path "$OLD/=$NEW/" --replace-path "/x/atelier-dev2=/y/atelier2" --apply)"; rc=$?
[ "$rc" -eq 0 ] && pass "two --replace-path pairs apply" || fail "two pairs exit $rc: $out"
[ "$(jq -r '.permissions.allow[1]' "$S")" = "Edit(/y/atelier/**)" ] && [ "$(jq -r '.permissions.allow[3]' "$S")" = "Read(/y/atelier2/**)" ] \
  && pass "trailing slash stripped and second pair applied" || fail "pairs result: $(jq -c '.permissions.allow' "$S")"
[ "$(jq -r '.permissions.allow[5]' "$S")" = "Read(/x/atelier-dev-old/**)" ] && pass "prefix-name path still untouched" || fail "prefix-name path rewritten"

# ---------- case 5: malformed argument -> exit 2 ----------
write_fixture
before="$(cksum < "$S")"
for bad in "nonsense" "relative=/y/b" "/x/a=relative" "/x/a" "="; do
  out="$(run --replace-path "$bad" --apply)"; rc=$?
  [ "$rc" -eq 2 ] && pass "malformed '$bad' exits 2" || fail "malformed '$bad' exit $rc: $out"
done
out="$(run --replace-path)"; rc=$?
[ "$rc" -eq 2 ] && pass "--replace-path without a value exits 2" || fail "missing value exit $rc: $out"
[ "$before" = "$(cksum < "$S")" ] && pass "malformed arguments never touch settings.json" || fail "settings.json changed on malformed input"

# ---------- case 6: missing / invalid settings.json ----------
rm -f "$S"
out="$(run --replace-path "$OLD=$NEW" --apply)"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$S" ] && pass "missing settings.json: exit 0, not created" || fail "missing: rc=$rc"
printf '{ nope' > "$S"
out="$(run --replace-path "$OLD=$NEW" --apply)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$S")" = '{ nope' ] && pass "invalid settings.json: exit 0, left alone" || fail "invalid: rc=$rc"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "automode-sync --replace-path (#488): all assertions passed."
  exit 0
else
  echo "automode-sync --replace-path (#488): $fails assertion(s) failed."
  exit 1
fi
