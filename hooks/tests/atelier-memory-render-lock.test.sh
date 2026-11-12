#!/usr/bin/env bash
#
# Hermetic regression test for #684 7d-7g: concurrent renders are serialised, a stale
# lock is taken over, $HOME and / are refused as a vault, the default vault location
# is robust to the spelling of ~/.claude-work. Split from atelier-memory-render.test.sh
# in #764.
# Run:  bash hooks/tests/atelier-memory-render-lock.test.sh
# Exit: 0 = all pass (or skipped), 1 = at least one failure.

set -uo pipefail

# shellcheck source=hooks/tests/memory-render-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/memory-render-fixture.sh"

# shellcheck source=scripts/lib/atelier-memory-render.sh
CFG="$ATELIER_CONFIG_DIR" DB="$ATELIER_CONFIG_DIR/atelier/memory.db"
. "$RENDER_LIB"

id_r1="$(ATELIER_MEMORY_VAULT=off mem add request --project "$PROJ" --source operator-verbatim --quote "Build Obsidian vault render" --title "Render vault request" --by operator)"
ATELIER_MEMORY_VAULT=off mem add decision --project "$PROJ" --source board-derived --title "Decision v1: vault schema" \
  --ref "record:$id_r1" --ref "issue:acme/repo#42" >/dev/null
V684="$TMP/vault684"
export ATELIER_MEMORY_VAULT="$V684"
vault_assert_isolated "$V684"

mem render --full >/dev/null 2>&1

# 7d. concurrent renders are serialised
for round in 1 2 3; do
  ( mem render --full >/dev/null 2>"$TMP/conc-a" ) &
  ( mem render --full >/dev/null 2>"$TMP/conc-b" ) &
  wait
  skipped="$(cat "$TMP/conc-a" "$TMP/conc-b" | grep -c 'vault render skipped')"
  if [ -e "$V684/Records/Records" ] || [ -e "$V684/Projects/Projects" ] || [ "$skipped" -gt 1 ]; then
    fail "concurrent render round $round: nested folder or skipped=$skipped"; break
  fi
  [ "$round" = 3 ] && pass "concurrent render --full runs never nest folders and at most one skips"
done
[ ! -e "$V684/.atelier-render.lock" ] && pass "render lock released after runs" || fail "render lock left behind"

# 7e. a stale lock (dead owner) is taken over
mkdir -p "$V684/.atelier-render.lock"
( exit 0 ) & dead_pid=$!; wait "$dead_pid"
printf '%s' "$dead_pid" > "$V684/.atelier-render.lock/pid"
if [ "$(rc mem render --full)" = 0 ] && [ ! -e "$V684/.atelier-render.lock" ]; then
  pass "stale render lock is taken over"
else
  fail "stale render lock blocked the render"
fi

# 7f. a vault resolving to \$HOME or / is refused
err_home="$(mem render --vault "$HOME" 2>&1 >/dev/null)"; rc_home=$?
[ "$rc_home" -ne 0 ] && case "$err_home" in *refusing*) true ;; *) false ;; esac \
  && pass "render into \$HOME is refused with a warning" || fail "render into \$HOME not refused (rc=$rc_home)"
[ ! -e "$HOME/Records" ] && [ ! -e "$HOME/Home.md" ] || fail "render wrote into \$HOME"
( . "$RENDER_LIB"; HOME="$TMP/home"; vault_refuse_unsafe "/" 2>/dev/null ) \
  && fail "vault_refuse_unsafe accepted /" || pass "vault_refuse_unsafe refuses /"
( . "$RENDER_LIB"; HOME="$TMP/home"; vault_refuse_unsafe "$TMP/home/" 2>/dev/null ) \
  && fail "vault_refuse_unsafe accepted \$HOME with trailing slash" || pass "vault_refuse_unsafe refuses \$HOME spelled with a trailing slash"

# 7g. default vault location is robust to spelling of ~/.claude-work
mkdir -p "$TMP/home/.claude-work"
ln -sfn "$TMP/home/.claude-work" "$TMP/cfg-link"
for spelling in "$TMP/home/.claude-work/" "$TMP/home/.claude-work//" "$TMP/cfg-link" "$TMP/cfg-link/"; do
  res="$(unset ATELIER_MEMORY_VAULT; ATELIER_CONFIG_DIR="$spelling" HOME="$TMP/home" vault_dir_resolve "")"
  [ "$res" = "$TMP/home/Atelier" ] && pass "config dir spelled '$spelling' resolves to \$HOME/Atelier" || fail "spelling '$spelling' -> $res"
done
res="$(unset ATELIER_MEMORY_VAULT; ATELIER_CONFIG_DIR="$TMP/cfg2/" HOME="$TMP/home" vault_dir_resolve "")"
[ "$res" = "$TMP/cfg2//vault" ] || [ "$res" = "$TMP/cfg2/vault" ] \
  && pass "a different config dir keeps \$ATELIER_CONFIG_DIR/vault" || fail "different config dir -> $res"
res="$(ATELIER_MEMORY_VAULT="$TMP/ov" ATELIER_CONFIG_DIR="$TMP/home/.claude-work/" HOME="$TMP/home" vault_dir_resolve "")"
[ "$res" = "$TMP/ov" ] && pass "ATELIER_MEMORY_VAULT keeps precedence over a trailing-slash config dir" || fail "override lost: $res"

finish "atelier-memory-render-lock"
