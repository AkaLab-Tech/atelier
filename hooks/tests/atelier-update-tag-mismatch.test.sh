#!/usr/bin/env bash
#
# Regression test for #548 — managed atelier-update verifies that the cached
# plugin's gitCommitSha is the peeled v<version> tag before swapping.
#
#   T1 cache sha != peeled tag (0.52.0 / abe8136-style) -> exit != 0, both shas
#      and the remedy printed, `current` and helper symlinks untouched
#   T2 tag missing on the remote                        -> refuse, untouched
#   T3 cache sha == peeled tag                          -> proceeds, swapped
#   T4 no gitCommitSha recorded                         -> warns and continues
#   T5 remote unreachable                               -> warns and continues
#
# Hermetic: local bare repo with annotated tags as the release remote
# (ATELIER_RELEASE_REPO_URL), fake `claude` shim, and a failing `gh` stub so
# the gh-api fallback can never reach the network.
#
# Run:  hooks/tests/atelier-update-tag-mismatch.test.sh
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

G=(git -c user.name=t -c user.email=t@t)
SHIM_BIN="$TMP/shim-bin"; mkdir -p "$SHIM_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SHIM_BIN/claude"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM_BIN/gh"
chmod +x "$SHIM_BIN/claude" "$SHIM_BIN/gh"

# Release remote: commits A (tagged v0.52.0, annotated) and B (a later main HEAD).
SRC="$TMP/src"; REMOTE="$TMP/remote.git"
git init -q "$SRC"
"${G[@]}" -C "$SRC" commit -q --allow-empty -m A
SHA_A="$(git -C "$SRC" rev-parse HEAD)"
"${G[@]}" -C "$SRC" tag -a v0.52.0 -m "v0.52.0"
"${G[@]}" -C "$SRC" commit -q --allow-empty -m B
SHA_B="$(git -C "$SRC" rev-parse HEAD)"
git clone -q --bare "$SRC" "$REMOTE"
TAG_OBJ="$(git -C "$REMOTE" rev-parse v0.52.0)"
[ "$TAG_OBJ" != "$SHA_A" ] || { echo "  FAIL: fixture tag is not annotated"; exit 1; }

# build <name> <version> <sha-or-NONE> -> sets HOME_DIR BIN CFG RT
build() {
  local d="$TMP/$1" ver="$2" sha="$3" cache
  HOME_DIR="$d/home"; BIN="$HOME_DIR/.local/bin"; CFG="$d/cfg"; RT="$d/runtime"
  mkdir -p "$BIN" "$CFG/templates" "$RT/0.1.0/scripts" "$RT/0.1.0/templates" "$RT/0.1.0/.claude-plugin"
  cp "$UPDATE" "$RT/0.1.0/scripts/atelier-update"; cp "$INSTALL" "$RT/0.1.0/install.sh"
  printf '#!/usr/bin/env bash\necho foo-v1\n' > "$RT/0.1.0/scripts/atelier-foo"
  chmod +x "$RT/0.1.0/scripts/"*
  printf '{ "name": "atelier", "version": "0.1.0" }\n' > "$RT/0.1.0/.claude-plugin/plugin.json"
  ln -s "0.1.0" "$RT/current"
  ln -s "$RT/current/scripts/atelier-update" "$BIN/atelier-update"
  ln -s "$RT/0.1.0/scripts/atelier-foo" "$BIN/atelier-foo"
  cache="$CFG/plugins/cache/akalab-tech/atelier/$ver"
  mkdir -p "$cache/scripts" "$cache/templates" "$cache/.claude-plugin"
  cp "$UPDATE" "$cache/scripts/atelier-update"; cp "$INSTALL" "$cache/install.sh"
  cp "$REPO_ROOT/scripts/atelier-automode-sync" "$cache/scripts/"
  cp "$REPO_ROOT/templates/automode.user.json" "$cache/templates/"
  printf '#!/usr/bin/env bash\necho foo-v2\n' > "$cache/scripts/atelier-foo"; chmod +x "$cache/scripts/"*
  printf '{ "name": "atelier", "version": "%s" }\n' "$ver" > "$cache/.claude-plugin/plugin.json"
  printf '{ "permissions": [] }\n' > "$cache/templates/settings.template.json"
  printf 'p\n' > "$cache/templates/project-claude.md.template"
  printf '{ "v": 2 }\n' > "$cache/templates/atelier.template.json"
  if [ "$sha" = NONE ]; then
    jq -n --arg p "$cache" --arg v "$ver" '{plugins:{"atelier@akalab-tech":[{scope:"user",installPath:$p,version:$v}]}}' > "$CFG/plugins/installed_plugins.json"
  else
    jq -n --arg p "$cache" --arg v "$ver" --arg s "$sha" '{plugins:{"atelier@akalab-tech":[{scope:"user",installPath:$p,version:$v,gitCommitSha:$s}]}}' > "$CFG/plugins/installed_plugins.json"
  fi
}
run_update() { # <remote-url>
  HOME="$HOME_DIR" ATELIER_CONFIG_DIR="$CFG" ATELIER_RUNTIME_DIR="$RT" ATELIER_RELEASE_REPO_URL="$1" \
    SHELL=/bin/zsh NO_COLOR=1 PATH="$SHIM_BIN:$PATH" "$BIN/atelier-update" 2>&1 </dev/null
}
untouched() { # <label>
  [ "$(readlink "$RT/current")" = "0.1.0" ] && pass "$1: current still -> 0.1.0" || fail "$1: current moved to $(readlink "$RT/current")"
  [ ! -e "$RT/0.52.0" ] && pass "$1: no 0.52.0 runtime dir created" || fail "$1: 0.52.0 dir created"
  [ "$(readlink "$BIN/atelier-foo")" = "$RT/0.1.0/scripts/atelier-foo" ] \
    && pass "$1: atelier-foo symlink untouched" || fail "$1: atelier-foo now -> $(readlink "$BIN/atelier-foo")"
  [ "$(readlink "$BIN/atelier-update")" = "$RT/current/scripts/atelier-update" ] \
    && pass "$1: atelier-update symlink untouched" || fail "$1: atelier-update now -> $(readlink "$BIN/atelier-update")"
}

echo "atelier-update managed: cache vs released tag (#548)"

# T1 mismatch
build t1 0.52.0 "$SHA_B"
out="$(run_update "$REMOTE")"; rc=$?
[ "$rc" -ne 0 ] && pass "T1: mismatch exits non-zero (rc=$rc)" || fail "T1: expected non-zero, got 0 (out: $out)"
printf '%s' "$out" | grep -q "$SHA_B" && pass "T1: prints the cached commit" || fail "T1: cached sha missing (out: $out)"
printf '%s' "$out" | grep -q "$SHA_A" && pass "T1: prints the peeled tag commit (not the tag object)" || fail "T1: tag commit missing (out: $out)"
printf '%s' "$out" | grep -q "$TAG_OBJ" && fail "T1: printed the tag object sha instead of the peeled commit" || pass "T1: tag object sha not printed"
printf '%s' "$out" | grep -q 'claude plugin marketplace update akalab-tech' && pass "T1: prints the remedy" || fail "T1: remedy missing (out: $out)"
untouched T1

# T2 tag missing (cache says 0.99.0, remote has no v0.99.0)
build t2 0.99.0 "$SHA_B"
out="$(run_update "$REMOTE")"; rc=$?
[ "$rc" -ne 0 ] && pass "T2: missing tag exits non-zero (rc=$rc)" || fail "T2: expected non-zero (out: $out)"
printf '%s' "$out" | grep -q 'no such tag' && pass "T2: reports no such tag" || fail "T2: message missing (out: $out)"
[ "$(readlink "$RT/current")" = "0.1.0" ] && pass "T2: current untouched" || fail "T2: current moved"
[ ! -e "$RT/0.99.0" ] && pass "T2: no 0.99.0 runtime dir" || fail "T2: 0.99.0 dir created"
[ "$(readlink "$BIN/atelier-foo")" = "$RT/0.1.0/scripts/atelier-foo" ] && pass "T2: helper symlink untouched" || fail "T2: helper symlink moved"

# T3 match
build t3 0.52.0 "$SHA_A"
out="$(run_update "$REMOTE")"; rc=$?
[ "$rc" -eq 0 ] && pass "T3: match exits 0" || fail "T3: rc=$rc (out: $out)"
[ "$(readlink "$RT/current")" = "0.52.0" ] && pass "T3: current swapped to 0.52.0" || fail "T3: current -> $(readlink "$RT/current")"

# T4 no gitCommitSha
build t4 0.52.0 NONE
out="$(run_update "$REMOTE")"; rc=$?
[ "$rc" -eq 0 ] && pass "T4: no gitCommitSha continues (exit 0)" || fail "T4: rc=$rc (out: $out)"
printf '%s' "$out" | grep -q 'no gitCommitSha' && pass "T4: warns about missing gitCommitSha" || fail "T4: warning missing (out: $out)"
[ "$(readlink "$RT/current")" = "0.52.0" ] && pass "T4: current swapped" || fail "T4: current -> $(readlink "$RT/current")"

# T5 unreachable remote
build t5 0.52.0 "$SHA_B"
out="$(run_update "$TMP/does-not-exist.git")"; rc=$?
[ "$rc" -eq 0 ] && pass "T5: unreachable remote continues (exit 0)" || fail "T5: rc=$rc (out: $out)"
printf '%s' "$out" | grep -q 'continuing unverified' && pass "T5: warns it is unverified" || fail "T5: warning missing (out: $out)"
[ "$(readlink "$RT/current")" = "0.52.0" ] && pass "T5: current swapped" || fail "T5: current -> $(readlink "$RT/current")"

echo
[ "$fails" -eq 0 ] && { echo "All assertions passed."; exit 0; } || { echo "$fails assertion(s) failed."; exit 1; }
