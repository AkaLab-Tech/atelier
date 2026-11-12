# shellcheck shell=bash
# Sourced by the atelier-memory-render*.test.sh files (#764); not a test itself,
# and not named *.test.sh so run-all.sh and the CI loop do not discover it.
# Provides the prerequisite skips, an isolated $TMP, pass/fail/rc/grepq, the vault
# isolation guard, the shared $PROJ and an optional base-record seed. Each test
# file builds its own small fixture and runs its own `mem render --full`.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MEM="$REPO_ROOT/scripts/atelier-memory"
RENDER_LIB="$REPO_ROOT/scripts/lib/atelier-memory-render.sh"

command -v sqlite3 >/dev/null 2>&1 || { echo "  SKIP: sqlite3 not on PATH"; exit 0; }
if ! printf 'CREATE VIRTUAL TABLE t USING fts5(a);' | sqlite3 :memory: >/dev/null 2>&1; then
  echo "  SKIP: sqlite3 lacks FTS5"; exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "  SKIP: git not on PATH"; exit 0; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# shellcheck source=hooks/tests/memory-test-isolation.sh
. "$REPO_ROOT/hooks/tests/memory-test-isolation.sh"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

# Vault assertion: ensure vault is hermetic and strictly under $TMP
vault_assert_isolated() {
  local v="${1:-}"
  [ -n "$v" ] || { echo "vault_assert_isolated: empty vault path" >&2; exit 1; }
  case "$v" in
    "$TMP"/*) ;;
    *) echo "vault_assert_isolated: vault '$v' not under temp dir '$TMP'" >&2; exit 1 ;;
  esac
  case "$v" in
    "$MEMTEST_REAL_HOME"/*|"$MEMTEST_REAL_CFG"/*|"$MEMTEST_REAL_HOME/Atelier"|"$MEMTEST_REAL_HOME/Atelier"/*)
      echo "vault_assert_isolated: vault '$v' touches real user directories" >&2; exit 1 ;;
  esac
}

rc() { "$@" >/dev/null 2>&1; echo $?; }
grepq() { local d; d="$(cat)"; grep -q "$@" <<<"$d"; }

PROJ="$TMP/proj"
mkdir -p "$PROJ"
echo "console.log('hello');" > "$PROJ/app.js"
PROJ_SLUG="$(basename "$PROJ")"

enc_path() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
MEM_IMPORT_DIR="$ATELIER_CONFIG_DIR/projects/$(enc_path "$PROJ")/memory"

# Registers $PROJ in projects.json so `mem import --project "$PROJ"` maps the directory.
register_project() {
  mkdir -p "$MEM_IMPORT_DIR"
  jq -n --arg p "$PROJ" '{projects: {($p): {name: "proj"}}}' > "$ATELIER_CONFIG_DIR/projects.json"
}

# Seeds the R/Q/H/F/G records, D-1 with its 4 refs, the D-1 -> D-2 -> D-3 supersede
# chain and a global fact, and sets the id_* variables. Runs with the vault off so no
# incremental render happens during setup; the caller does one `mem render --full`.
# shellcheck disable=SC2034 # id_* are read by the sourcing test files
seed_base_records() {
  local saved="${ATELIER_MEMORY_VAULT:-}"
  export ATELIER_MEMORY_VAULT=off
  id_r1="$(mem add request --project "$PROJ" --source operator-verbatim --quote "Build Obsidian vault render" --title "Render vault request" --by operator)"
  id_q1="$(mem add question --project "$PROJ" --source agent-inferred --title "How to structure notes?" --body "Need markdown stubs and index")"
  id_h1="$(mem add held --project "$PROJ" --source agent-inferred --title "Wait on obsidian plugin api")"
  id_f1="$(mem add fact --project "$PROJ" --source agent-inferred --title "Obsidian supports wikilinks")"
  id_g1="$(mem add digest --project "$PROJ" --source agent-inferred --title "Sprint summary week 44")"
  id_d1="$(mem add decision --project "$PROJ" --source board-derived --title "Decision v1: vault schema" \
    --ref "record:$id_r1" --ref "issue:acme/repo#42" --ref "pr:acme/repo#100" --ref "file:scripts/atelier-memory")"
  id_d2="$(mem supersede "$id_d1" --source agent-inferred --title "Decision v2: vault schema refined")"
  id_d3="$(mem supersede "$id_d2" --source agent-inferred --title "Decision v3: final schema")"
  id_f_glob="$(mem add fact --project '*' --source agent-inferred --title "Global policy fact")"
  export ATELIER_MEMORY_VAULT="$saved"
}

# finish <label>: prints the summary line and exits 0 (all pass) or 1.
finish() {
  echo ""
  if [ "$fails" -eq 0 ]; then
    echo "$1: all tests passed"
    exit 0
  fi
  echo "$1: $fails test(s) failed"
  exit 1
}
