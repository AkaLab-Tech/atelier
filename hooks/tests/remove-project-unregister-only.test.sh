#!/usr/bin/env bash
#
# Regression test for #466 — `atelier-remove-project --unregister-only`.
# The flag drops ONLY the registry key; every file on disk stays; it cannot be
# combined with --purge; default mode still deletes settings/.atelier.json.
#
# Hermetic: ATELIER_CONFIG_DIR + projects live in a temp dir; no network.
#
# Run:  hooks/tests/remove-project-unregister-only.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-remove-project"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(cd -P "$(mktemp -d)" && pwd)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

export ATELIER_CONFIG_DIR="$TMP/config"
mkdir -p "$ATELIER_CONFIG_DIR"

# mkproject <name> -> creates a project dir with the atelier files; echoes path
mkproject() {
  local d="$TMP/$1"
  mkdir -p "$d/.claude"
  printf '{"permissions":{}}\n' > "$d/.claude/settings.json"
  printf 'bak\n' > "$d/.claude/settings.json.bak.20260101"
  printf '{"x":1}\n' > "$d/.atelier.json"
  printf 'claude md\n' > "$d/.claude/CLAUDE.md"
  printf 'roadmap\n' > "$d/ROADMAP.md"
  printf 'ignore-scripts=true\nminimum-release-age=10080\naudit-level=moderate\n' > "$d/.npmrc"
  printf '.task-log/\n.DS_Store\n' > "$d/.gitignore"
  printf '%s' "$d"
}

seed_registry() {
  jq -n --arg a "$A" --arg b "$B" \
    '{projects: {($a): {name:"a"}, ($b): {name:"b"}}}' > "$ATELIER_CONFIG_DIR/projects.json"
}

has_key() { jq -e --arg p "$1" '.projects[$p]' "$ATELIER_CONFIG_DIR/projects.json" >/dev/null 2>&1; }

snapshot() { (cd "$1" && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }

# ---------- case 1: --unregister-only ----------
A="$(mkproject a)"; B="$(mkproject b)"
seed_registry
before="$(snapshot "$A")"
out="$(bash "$SCRIPT" "$A" --unregister-only --yes 2>&1)"; rc=$?

[ "$rc" -eq 0 ] && pass "unregister-only exits 0" || fail "unregister-only exit $rc: $out"
has_key "$A" && fail "registry key for A still present" || pass "registry key for A dropped"
has_key "$B" && pass "other registry key (B) intact" || fail "registry key for B was removed"
[ "$(jq -r --arg p "$B" '.projects[$p].name' "$ATELIER_CONFIG_DIR/projects.json")" = "b" ] \
  && pass "B's registry value intact (name=b)" || fail "B's registry value changed"
after="$(snapshot "$A")"
[ "$before" = "$after" ] && pass "every file in A byte-identical (none deleted/modified)" \
  || fail "files in A changed: $(diff <(echo "$before") <(echo "$after"))"
for f in .claude/settings.json .claude/settings.json.bak.20260101 .atelier.json .npmrc .gitignore; do
  [ -f "$A/$f" ] && pass "A/$f kept" || fail "A/$f missing"
done
case "$out" in *"preserved (--unregister-only)"*) pass "output lists files as preserved (--unregister-only)" ;;
  *) fail "output lacks 'preserved (--unregister-only)': $out" ;; esac

# ---------- case 2: --purge --unregister-only dies ----------
A="$(mkproject a2)"; B="$(mkproject b2)"
seed_registry
before="$(snapshot "$A")"
out="$(bash "$SCRIPT" "$A" --purge --unregister-only --yes 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "--purge --unregister-only exits non-zero ($rc)" || fail "combo exited 0"
case "$out" in *"cannot be combined"*) pass "combo message says 'cannot be combined'" ;;
  *) fail "combo message missing: $out" ;; esac
has_key "$A" && pass "combo leaves registry untouched" || fail "combo removed registry key"
[ "$before" = "$(snapshot "$A")" ] && pass "combo leaves files untouched" || fail "combo changed files"

# ---------- case 3: default mode still deletes ----------
A="$(mkproject a3)"; B="$(mkproject b3)"
seed_registry
out="$(bash "$SCRIPT" "$A" --yes 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "default mode exits 0" || fail "default mode exit $rc: $out"
[ ! -e "$A/.claude/settings.json" ] && pass "default deletes settings.json" || fail "settings.json survived default mode"
[ ! -e "$A/.claude/settings.json.bak.20260101" ] && pass "default deletes settings.json.bak.*" || fail "bak survived default mode"
[ ! -e "$A/.atelier.json" ] && pass "default deletes .atelier.json" || fail ".atelier.json survived default mode"
[ -f "$A/ROADMAP.md" ] && [ -f "$A/.npmrc" ] && pass "default preserves ROADMAP.md and .npmrc" || fail "default deleted operator content"
has_key "$A" && fail "default left registry key" || pass "default drops registry key"
has_key "$B" && pass "default keeps other key" || fail "default removed B"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "remove-project --unregister-only (#466): all assertions passed."
  exit 0
else
  echo "remove-project --unregister-only (#466): $fails assertion(s) failed."
  exit 1
fi
