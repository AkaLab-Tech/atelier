#!/usr/bin/env bash
#
# Hermetic regression test for the memory tests' isolation (#665): runs the three
# memory test files with a sentinel real-looking config dir as HOME /
# ATELIER_CONFIG_DIR and proves it is left byte-identical, and that the guard in
# memory-test-isolation.sh aborts (writing nothing) when a call would resolve to
# the sentinel or when ATELIER_CONFIG_DIR is empty. Skips cleanly without
# sqlite3 / FTS5 / jq / git.
#
# Run:  hooks/tests/memory-test-isolation.test.sh
# Exit: 0 = all pass (or skipped), 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$REPO_ROOT/hooks/tests"
MEM="$REPO_ROOT/scripts/atelier-memory"

command -v sqlite3 >/dev/null 2>&1 || { echo "  SKIP: sqlite3 not on PATH"; exit 0; }
if ! printf 'CREATE VIRTUAL TABLE t USING fts5(a);' | sqlite3 :memory: >/dev/null 2>&1; then
  echo "  SKIP: sqlite3 lacks FTS5"; exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "  SKIP: git not on PATH"; exit 0; }

S="$(mktemp -d)"; S="$(cd "$S" && pwd -P)"
trap 'rm -rf "$S"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
snap() { (cd "$1" && find . | sort; find . -type f | sort | xargs cksum 2>/dev/null); }

# --- sentinel real-looking config dir ---------------------------------------
SH="$S/home"; SC="$SH/.claude-work"
PROJ="$S/proj"; mkdir -p "$PROJ" "$SC/atelier"
enc="$(printf '%s' "$PROJ" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$SC/projects/$enc/memory"
printf -- '---\nname: Sentinel note\ndescription: must not move\nmetadata:\n  type: user\n---\nbody\n' > "$SC/projects/$enc/memory/note.md"
jq -n --arg p "$PROJ" '{projects: {($p): {name: "sentinel"}}}' > "$SC/projects.json"
sqlite3 "$SC/atelier/memory.db" "PRAGMA journal_mode=DELETE; CREATE TABLE sentinel(v); INSERT INTO sentinel VALUES ('keep');" >/dev/null
before="$(snap "$SH")"

# --- the memory tests, with the sentinel passed as the real HOME/config dir ---
for f in atelier-memory.test.sh atelier-memory-import.test.sh memory-brief-hook.test.sh; do
  out="$(env HOME="$SH" ATELIER_CONFIG_DIR="$SC" bash "$T/$f" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && pass "$f passes with the sentinel as the real config dir" || fail "$f rc=$rc: $(printf '%s' "$out" | grep -m3 'FAIL\|ABORT')"
done
[ "$before" = "$(snap "$SH")" ] && pass "sentinel is byte-identical after the memory tests" || fail "sentinel changed"
if find "$SH" \( -name '*-wal' -o -name '*-shm' \) | grep -q .; then fail "wal/shm created in the sentinel"; else pass "no -wal/-shm created in the sentinel"; fi

# --- guard self-test: a bad override aborts and writes nothing ----------------
G="$S/guard.sh"
cat > "$G" <<'GEOF'
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
MEM="$1"; BAD="$2"; PROJ="$3"
. "$4"
export ATELIER_CONFIG_DIR="$BAD"
mem add fact --project "$PROJ" --source agent-inferred --title "should never land"
echo "REACHED-AFTER-GUARD"
GEOF
for case_ in "$SC" ""; do
  label="${case_:-<empty>}"; [ -n "$case_" ] && label="sentinel"
  out="$(env HOME="$SH" ATELIER_CONFIG_DIR="$SC" bash "$G" "$MEM" "$case_" "$PROJ" "$T/memory-test-isolation.sh" 2>&1)"; rc=$?
  [ "$rc" != 0 ] && pass "guard aborts non-zero for $label ATELIER_CONFIG_DIR" || fail "guard did not abort for $label"
  case "$out" in *"memory-test-isolation: ABORT:"*) pass "guard prints the abort message for $label" ;; *) fail "no abort message for $label: $out" ;; esac
  case "$out" in *REACHED-AFTER-GUARD*) fail "execution continued past the guard for $label" ;; *) pass "nothing ran after the guard for $label" ;; esac
  [ "$before" = "$(snap "$SH")" ] && pass "sentinel unchanged after the $label guard case" || fail "sentinel changed in $label guard case"
done

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
