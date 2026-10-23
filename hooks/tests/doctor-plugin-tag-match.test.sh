#!/usr/bin/env bash
#
# Regression test for #548 — atelier-doctor check_plugin_tag_match() and
# check_marketplace_pinned().
#
#   M1 cache sha == peeled tag                       -> OK
#   M2 cache sha != peeled tag                       -> FAIL (+ manual fix)
#   M3 remote unreachable                            -> SKIP, never FAIL
#   M4 no gitCommitSha                               -> SKIP
#   M5 clone install (`current` not a symlink)       -> SKIP
#   M6 local version ahead of highest published tag  -> SKIP
#   P1 catalog atelier ref starts with v             -> OK
#   P2 no ref / no catalog                           -> SKIP
#
# Hermetic: functions are extracted from scripts/atelier-doctor; the release
# remote is a local bare repo (ATELIER_RELEASE_REPO_URL); `gh` is a failing
# stub on PATH so the fallback never reaches the network.
#
# Run:  hooks/tests/doctor-plugin-tag-match.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCTOR="$REPO_ROOT/scripts/atelier-doctor"
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"
PATH="$TMP/bin:$PATH"

FN_FILE="$TMP/fns.sh"
: > "$FN_FILE"
for fn in version_cmp check_plugin_tag_match check_marketplace_pinned; do
  awk -v n="$fn" '$0 ~ "^"n"\\(\\) \\{"{f=1} f{print} f&&/^\}/{f=0}' "$DOCTOR" >> "$FN_FILE"
  grep -q "^$fn()" "$FN_FILE" || { echo "  FAIL: could not extract $fn"; exit 1; }
done
# shellcheck disable=SC1090
source "$FN_FILE"

PLUGIN_OUT="$TMP/plugin_out"
push_plugin()     { printf '%s\n' "$*" >> "$PLUGIN_OUT"; }
push_fix_manual() { :; }
OK="✓"; FAIL="✗"; SKIP="–"

G=(git -c user.name=t -c user.email=t@t)
SRC="$TMP/src"; REMOTE="$TMP/remote.git"
git init -q "$SRC"
"${G[@]}" -C "$SRC" commit -q --allow-empty -m A
SHA_A="$(git -C "$SRC" rev-parse HEAD)"
"${G[@]}" -C "$SRC" tag -a v0.52.0 -m "v0.52.0"
"${G[@]}" -C "$SRC" commit -q --allow-empty -m B
SHA_B="$(git -C "$SRC" rev-parse HEAD)"
git clone -q --bare "$SRC" "$REMOTE"

# scenario <name> <version> <sha|NONE> <managed|clone> <remote-url>
scenario() {
  rm -f "$PLUGIN_OUT"; touch "$PLUGIN_OUT"
  local d="$TMP/$1"
  ATELIER_CONFIG_DIR="$d/cfg"; ATELIER_RUNTIME_BASE="$d/rt"
  export ATELIER_RELEASE_REPO_URL="$5"  # read by the sourced check_plugin_tag_match
  mkdir -p "$ATELIER_CONFIG_DIR/plugins" "$ATELIER_RUNTIME_BASE/0.1.0"
  if [ "$4" = managed ]; then ln -s 0.1.0 "$ATELIER_RUNTIME_BASE/current"; else mkdir -p "$ATELIER_RUNTIME_BASE/current"; fi
  if [ "$3" = NONE ]; then
    jq -n --arg v "$2" '{plugins:{"atelier@akalab-tech":[{version:$v}]}}'
  else
    jq -n --arg v "$2" --arg s "$3" '{plugins:{"atelier@akalab-tech":[{version:$v,gitCommitSha:$s}]}}'
  fi > "$ATELIER_CONFIG_DIR/plugins/installed_plugins.json"
  check_plugin_tag_match
}
no_fail() { grep -q "^$FAIL" "$PLUGIN_OUT" && fail "$1: reported FAIL ($(cat "$PLUGIN_OUT"))" || pass "$1: no FAIL"; }

echo "atelier-doctor check_plugin_tag_match / check_marketplace_pinned (#548)"

scenario m1 0.52.0 "$SHA_A" managed "$REMOTE"
grep -q "^$OK atelier 0.52.0 cache matches tag" "$PLUGIN_OUT" && pass "M1: match -> OK" || fail "M1: got $(cat "$PLUGIN_OUT")"

scenario m2 0.52.0 "$SHA_B" managed "$REMOTE"
grep -q "^$FAIL atelier 0.52.0 cache is ${SHA_B:0:7} but tag v0.52.0 is ${SHA_A:0:7}" "$PLUGIN_OUT" \
  && pass "M2: mismatch -> FAIL naming both short shas" || fail "M2: got $(cat "$PLUGIN_OUT")"

scenario m3 0.52.0 "$SHA_B" managed "$TMP/nope.git"
grep -q "^$SKIP .*tag lookup failed" "$PLUGIN_OUT" && pass "M3: unreachable -> SKIP" || fail "M3: got $(cat "$PLUGIN_OUT")"
no_fail M3

scenario m4 0.52.0 NONE managed "$REMOTE"
grep -q "^$SKIP .*no gitCommitSha" "$PLUGIN_OUT" && pass "M4: no gitCommitSha -> SKIP" || fail "M4: got $(cat "$PLUGIN_OUT")"
no_fail M4

scenario m5 0.52.0 "$SHA_B" clone "$REMOTE"
grep -q "^$SKIP .*not a managed install" "$PLUGIN_OUT" && pass "M5: clone install -> SKIP" || fail "M5: got $(cat "$PLUGIN_OUT")"
no_fail M5

scenario m6 0.60.0 "$SHA_B" managed "$REMOTE"
grep -q "^$SKIP .*0.60.0 is ahead of published 0.52.0" "$PLUGIN_OUT" && pass "M6: local ahead of latest tag -> SKIP" || fail "M6: got $(cat "$PLUGIN_OUT")"
no_fail M6

# check_marketplace_pinned
pinned() { # <name> <json|NONE>
  rm -f "$PLUGIN_OUT"; touch "$PLUGIN_OUT"
  ATELIER_CONFIG_DIR="$TMP/$1"
  local dir="$ATELIER_CONFIG_DIR/plugins/marketplaces/akalab-tech/.claude-plugin"
  mkdir -p "$dir"
  [ "$2" = NONE ] || printf '%s\n' "$2" > "$dir/marketplace.json"
  check_marketplace_pinned
}
pinned p1 '{"plugins":[{"name":"other","source":{"source":"github","repo":"x/y"}},{"name":"atelier","source":{"source":"github","repo":"AkaLab-Tech/atelier","ref":"v0.52.0","sha":"abc"}}]}'
grep -q "^$OK marketplace entry pinned (atelier ref v0.52.0)" "$PLUGIN_OUT" && pass "P1: ref v0.52.0 -> OK" || fail "P1: got $(cat "$PLUGIN_OUT")"
pinned p2 '{"plugins":[{"name":"atelier","source":{"source":"github","repo":"AkaLab-Tech/atelier"}}]}'
grep -q "^$SKIP marketplace entry not pinned" "$PLUGIN_OUT" && pass "P2: no ref -> SKIP" || fail "P2: got $(cat "$PLUGIN_OUT")"
pinned p3 '{"plugins":[{"name":"atelier","source":{"source":"github","repo":"AkaLab-Tech/atelier","ref":"main"}}]}'
grep -q "^$SKIP marketplace entry not pinned" "$PLUGIN_OUT" && pass "P3: ref main -> SKIP" || fail "P3: got $(cat "$PLUGIN_OUT")"
pinned p4 '{"plugins":[{"name":"atelier","source":"./"}]}'
grep -q "^$SKIP marketplace entry not pinned" "$PLUGIN_OUT" && pass "P4: string source -> SKIP" || fail "P4: got $(cat "$PLUGIN_OUT")"
pinned p5 NONE
grep -q "^$SKIP marketplace entry pinned (no readable" "$PLUGIN_OUT" && pass "P5: no catalog -> SKIP" || fail "P5: got $(cat "$PLUGIN_OUT")"

echo
[ "$fails" -eq 0 ] && { echo "All assertions passed."; exit 0; } || { echo "$fails assertion(s) failed."; exit 1; }
