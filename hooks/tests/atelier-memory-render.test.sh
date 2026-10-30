#!/usr/bin/env bash
#
# Hermetic regression test for Obsidian vault rendering (#620, #610c).
# Sourced by scripts/atelier-memory via scripts/lib/atelier-memory-render.sh.
# Verifies all acceptance criteria:
#   1. render --full produces Home.md, Projects/, Records/, Issues/, PRs/ with
#      wikilinks between records, projects, issues, PRs, and two-way supersede chains.
#   2. Folder and note names follow operator.json chatLanguage (English and Spanish,
#      unknown falls back to English). Changing language re-renders without losing
#      inbox files or breaking record links.
#   3. Vault is outside project repos (default ~/Atelier, overridable) with the
#      read-only banner on every generated note.
#   4. Regeneration never modifies Inbox/ or .obsidian/ and never deletes operator
#      files outside the inbox. Running render twice gives byte-identical output.
#   5. Writes (add, supersede, close, import) trigger incremental re-renders;
#      vault render failures do not fail the write or corrupt the DB.
#   6. Rendering can be disabled via ATELIER_MEMORY_VAULT=off and operator.json (.memory.vault: false).
#   7. block-subagent-memory-write.sh allows render subcommands for subagents.
#
# Run:  bash hooks/tests/atelier-memory-render.test.sh
# Exit: 0 = all pass (or skipped), 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MEM="$REPO_ROOT/scripts/atelier-memory"
HOOK="$REPO_ROOT/hooks/block-subagent-memory-write.sh"
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
    "$MEMTEST_REAL_HOME"/*|"$MEMTEST_REAL_CFG"/*|"/Users/mike/Atelier"|"/Users/mike/Atelier"/*)
      echo "vault_assert_isolated: vault '$v' touches real user directories" >&2; exit 1 ;;
  esac
}

rc() { "$@" >/dev/null 2>&1; echo $?; }
grepq() { local d; d="$(cat)"; grep -q "$@" <<<"$d"; }

# Explicit isolated test vault directory
TEST_VAULT="$TMP/vault"
export ATELIER_MEMORY_VAULT="$TEST_VAULT"
vault_assert_isolated "$TEST_VAULT"

PROJ="$TMP/proj"
mkdir -p "$PROJ"
echo "console.log('hello');" > "$PROJ/app.js"

PROJ_SLUG="$(basename "$PROJ")"

# ==============================================================================
# 1. Vault Directory Resolution & Default Placement (Criterion 3)
# ==============================================================================

# Verify resolution logic via library helpers directly
# shellcheck source=scripts/lib/atelier-memory-render.sh
CFG="$ATELIER_CONFIG_DIR" DB="$ATELIER_CONFIG_DIR/atelier/memory.db"
. "$RENDER_LIB"

# 1a. ATELIER_MEMORY_VAULT override
res="$(ATELIER_MEMORY_VAULT="$TMP/custom-vault" vault_dir_resolve "")"
[ "$res" = "$TMP/custom-vault" ] \
  && pass "vault_dir_resolve respects \$ATELIER_MEMORY_VAULT" \
  || fail "vault_dir_resolve env override: $res"

# 1b. CLI --vault argument override
res="$(vault_dir_resolve "$TMP/cli-vault")"
[ "$res" = "$TMP/cli-vault" ] \
  && pass "vault_dir_resolve respects CLI --vault" \
  || fail "vault_dir_resolve cli override: $res"

# 1c. Custom ATELIER_CONFIG_DIR defaults to $ATELIER_CONFIG_DIR/vault
res="$(unset ATELIER_MEMORY_VAULT; ATELIER_CONFIG_DIR="$TMP/cfg2" HOME="$TMP/home" vault_dir_resolve "")"
[ "$res" = "$TMP/cfg2/vault" ] \
  && pass "vault_dir_resolve with custom ATELIER_CONFIG_DIR defaults to \$ATELIER_CONFIG_DIR/vault" \
  || fail "vault_dir_resolve config dir default: $res"

# 1d. ATELIER_CONFIG_DIR=$HOME/.claude-work defaults to $HOME/Atelier
res="$(unset ATELIER_MEMORY_VAULT; ATELIER_CONFIG_DIR="$TMP/home/.claude-work" HOME="$TMP/home" vault_dir_resolve "")"
[ "$res" = "$TMP/home/Atelier" ] \
  && pass "vault_dir_resolve default defaults to \$HOME/Atelier" \
  || fail "vault_dir_resolve default: $res"

# Restore ATELIER_MEMORY_VAULT for remaining tests
export ATELIER_MEMORY_VAULT="$TEST_VAULT"

# ==============================================================================
# 2. Acceptance Criterion 1 & 3: Full Render, Structure, Wikilinks, Banners
# ==============================================================================

# Populate database with records of various types and references
id_r1="$(mem add request --project "$PROJ" --source operator-verbatim --quote "Build Obsidian vault render" --title "Render vault request" --by operator)"
id_q1="$(mem add question --project "$PROJ" --source agent-inferred --title "How to structure notes?" --body "Need markdown stubs and index")"
id_h1="$(mem add held --project "$PROJ" --source agent-inferred --title "Wait on obsidian plugin api")"
id_f1="$(mem add fact --project "$PROJ" --source agent-inferred --title "Obsidian supports wikilinks")"
id_g1="$(mem add digest --project "$PROJ" --source agent-inferred --title "Sprint summary week 44")"

# Decision with references to record, issue, PR, and file
id_d1="$(mem add decision --project "$PROJ" --source board-derived --title "Decision v1: vault schema" \
  --ref "record:$id_r1" --ref "issue:acme/repo#42" --ref "pr:acme/repo#100" --ref "file:scripts/atelier-memory")"

# Supersede chain: D-1 -> D-2 -> D-3
id_d2="$(mem supersede "$id_d1" --source agent-inferred --title "Decision v2: vault schema refined")"
id_d3="$(mem supersede "$id_d2" --source agent-inferred --title "Decision v3: final schema")"

# Global record
id_f_glob="$(mem add fact --project '*' --source agent-inferred --title "Global policy fact")"

# Trigger full render
mem render --full

# 2a. Check folder structure
[ -f "$TEST_VAULT/Home.md" ] && pass "Home.md exists" || fail "Home.md missing"
[ -d "$TEST_VAULT/Projects" ] && pass "Projects/ directory exists" || fail "Projects/ missing"
[ -d "$TEST_VAULT/Records" ] && pass "Records/ directory exists" || fail "Records/ missing"
[ -d "$TEST_VAULT/Issues" ] && pass "Issues/ directory exists" || fail "Issues/ missing"
[ -d "$TEST_VAULT/PRs" ] && pass "PRs/ directory exists" || fail "PRs/ missing"
[ -d "$TEST_VAULT/Inbox" ] && pass "Inbox/ directory exists" || fail "Inbox/ missing"

# 2b. Check that vault is outside the project repository
[ ! -e "$PROJ/Home.md" ] && [ ! -d "$PROJ/Projects" ] && [ ! -d "$PROJ/Records" ] \
  && pass "vault is outside project repo" || fail "vault files leaked into project repo"

# 2c. Check banner on every generated note
banner="<!-- Generated by atelier — edits here are overwritten; write to Inbox/ -->"
all_notes_have_banner=1
while IFS= read -r f; do
  [ -f "$f" ] || continue
  case "$f" in
    */Inbox/*|*/.atelier-vault.json) continue ;;
  esac
  read -r first_line < "$f" || true
  if [ "$first_line" != "$banner" ]; then
    all_notes_have_banner=0
    fail "file missing banner: $f (first line: $first_line)"
    break
  fi
done < <(find "$TEST_VAULT" -type f -name '*.md')
[ "$all_notes_have_banner" = 1 ] && pass "every generated note carries the banner"

# 2d. Check Home.md content & wikilinks
home_content="$(cat "$TEST_VAULT/Home.md")"
if grepq "# Atelier Memory" <<<"$home_content" && \
   grepq "## Projects" <<<"$home_content" && \
   grepq "\[\[$PROJ_SLUG\]\]" <<<"$home_content" && \
   grepq "\[\[$id_r1\]\]: Render vault request" <<<"$home_content" && \
   grepq "\[\[$id_d3\]\]: Decision v3: final schema" <<<"$home_content" && \
   grepq "\[\[$id_f1\]\]: Obsidian supports wikilinks" <<<"$home_content"; then
  pass "Home.md index note contains correct sections and wikilinks"
else
  fail "Home.md content mismatch: $home_content"
fi

# Superseded records (D-1, D-2) must not appear in Home.md live decisions list
if grep -q "\[\[$id_d1\]\]" "$TEST_VAULT/Home.md" || grep -q "\[\[$id_d2\]\]" "$TEST_VAULT/Home.md"; then
  fail "Home.md lists superseded decisions"
else
  pass "Home.md hides superseded decisions"
fi

# 2e. Check Record note frontmatter, title, quote, project, supersede chain, references
rec_d1="$(cat "$TEST_VAULT/Records/$id_d1.md")"
if grepq "id: $id_d1" <<<"$rec_d1" && \
   grepq "type: decision" <<<"$rec_d1" && \
   grepq "superseded_by: $id_d2" <<<"$rec_d1" && \
   grepq "# Decision v1: vault schema" <<<"$rec_d1" && \
   grepq "## Project" <<<"$rec_d1" && \
   grepq "\[\[$PROJ_SLUG\]\]" <<<"$rec_d1" && \
   grepq "## Supersede chain" <<<"$rec_d1" && \
   grepq "\[\[$id_d1\]\] -> \[\[$id_d2\]\] -> \[\[$id_d3\]\]" <<<"$rec_d1" && \
   grepq "\[\[$id_r1\]\]" <<<"$rec_d1" && \
   grepq "\[\[acme-repo#42\]\]" <<<"$rec_d1" && \
   grepq "\[\[acme-repo#100\]\]" <<<"$rec_d1" && \
   grepq "\`scripts/atelier-memory\`" <<<"$rec_d1"; then
  pass "Records/$id_d1.md contains frontmatter, project link, supersede chain, and references"
else
  fail "Records/$id_d1.md format mismatch: $rec_d1"
fi

# Check supersede chain linked both ways in D-2 and D-3 notes
rec_d2="$(cat "$TEST_VAULT/Records/$id_d2.md")"
rec_d3="$(cat "$TEST_VAULT/Records/$id_d3.md")"
case "$rec_d2" in
  *"## Supersede chain"*"- [[$id_d1]] -> [[$id_d2]] -> [[$id_d3]]"*)
    pass "Records/$id_d2.md carries complete two-way supersede chain"
    ;;
  *)
    fail "Records/$id_d2.md supersede chain: $rec_d2"
    ;;
esac
case "$rec_d3" in
  *"## Supersede chain"*"- [[$id_d1]] -> [[$id_d2]] -> [[$id_d3]]"*)
    pass "Records/$id_d3.md carries complete two-way supersede chain"
    ;;
  *)
    fail "Records/$id_d3.md supersede chain: $rec_d3"
    ;;
esac

# Check record with verbatim quote (R-1)
rec_r1="$(cat "$TEST_VAULT/Records/$id_r1.md")"
case "$rec_r1" in
  *"> Build Obsidian vault render"*)
    pass "Records/$id_r1.md renders blockquote"
    ;;
  *)
    fail "Records/$id_r1.md blockquote missing: $rec_r1"
    ;;
esac

# 2f. Check Project note
proj_note="$(cat "$TEST_VAULT/Projects/$PROJ_SLUG.md")"
if grepq "## Open requests" <<<"$proj_note" && \
   grepq "\[\[$id_r1\]\]: Render vault request" <<<"$proj_note" && \
   grepq "## Open questions" <<<"$proj_note" && \
   grepq "\[\[$id_q1\]\]: How to structure notes\?" <<<"$proj_note" && \
   grepq "## Held items" <<<"$proj_note" && \
   grepq "\[\[$id_h1\]\]: Wait on obsidian plugin api" <<<"$proj_note" && \
   grepq "## Recent decisions" <<<"$proj_note" && \
   grepq "\[\[$id_d3\]\]: Decision v3: final schema" <<<"$proj_note" && \
   grepq "## Facts" <<<"$proj_note" && \
   grepq "\[\[$id_f1\]\]: Obsidian supports wikilinks" <<<"$proj_note"; then
  pass "Projects/$PROJ_SLUG.md contains all typed sections with wikilinks"
else
  fail "Projects/$PROJ_SLUG.md content mismatch: $proj_note"
fi

# 2g. Check Issue and PR stub notes
issue_note="$(cat "$TEST_VAULT/Issues/acme-repo#42.md")"
if grepq "# acme/repo#42" <<<"$issue_note" && \
   grepq "https://github.com/acme/repo/issues/42" <<<"$issue_note" && \
   grepq "## Mentioned in" <<<"$issue_note" && \
   grepq "\[\[$id_d1\]\]: Decision v1: vault schema" <<<"$issue_note"; then
  pass "Issues/acme-repo#42.md renders title, link, and Mentioned in backlink"
else
  fail "Issues/acme-repo#42.md content mismatch: $issue_note"
fi

pr_note="$(cat "$TEST_VAULT/PRs/acme-repo#100.md")"
if grepq "# acme/repo#100" <<<"$pr_note" && \
   grepq "https://github.com/acme/repo/pull/100" <<<"$pr_note" && \
   grepq "## Mentioned in" <<<"$pr_note" && \
   grepq "\[\[$id_d1\]\]: Decision v1: vault schema" <<<"$pr_note"; then
  pass "PRs/acme-repo#100.md renders title, link, and Mentioned in backlink"
else
  fail "PRs/acme-repo#100.md content mismatch: $pr_note"
fi

# ==============================================================================
# 3. Acceptance Criterion 2: Operator Chat Language & Language Switching
# ==============================================================================

# Add an operator file to Inbox before language switch
echo "Draft notes for next feature" > "$TEST_VAULT/Inbox/operator-draft.md"

# Configure operator.json with chatLanguage="es"
printf '{"chatLanguage": "es"}\n' > "$ATELIER_CONFIG_DIR/operator.json"

# Re-render
mem render --full

# 3a. Spanish folder names and index note
[ -f "$TEST_VAULT/Inicio.md" ] && [ ! -f "$TEST_VAULT/Home.md" ] \
  && pass "language switch: Home.md migrated to Inicio.md" || fail "Inicio.md not created or Home.md still present"

[ -d "$TEST_VAULT/Proyectos" ] && [ ! -d "$TEST_VAULT/Projects" ] \
  && pass "language switch: Projects/ migrated to Proyectos/" || fail "Proyectos/ missing or Projects/ retained"

[ -d "$TEST_VAULT/Registros" ] && [ ! -d "$TEST_VAULT/Records" ] \
  && pass "language switch: Records/ migrated to Registros/" || fail "Registros/ missing or Records/ retained"

[ -d "$TEST_VAULT/Entrada" ] && [ ! -d "$TEST_VAULT/Inbox" ] \
  && pass "language switch: Inbox/ migrated to Entrada/" || fail "Entrada/ missing or Inbox/ retained"

# 3b. Inbox files preserved without data loss
[ -f "$TEST_VAULT/Entrada/operator-draft.md" ] \
  && [ "$(cat "$TEST_VAULT/Entrada/operator-draft.md")" = "Draft notes for next feature" ] \
  && pass "language switch: operator file in Inbox moved to Entrada intact" \
  || fail "Entrada/operator-draft.md missing or modified"

# 3c. Spanish headings and banners
inicio_content="$(cat "$TEST_VAULT/Inicio.md")"
if grepq "# Memoria Atelier" <<<"$inicio_content" && \
   grepq "## Proyectos" <<<"$inicio_content" && \
   grepq "## Peticiones" <<<"$inicio_content" && \
   grepq "## Decisiones" <<<"$inicio_content"; then
  pass "Inicio.md contains Spanish headings"
else
  fail "Inicio.md missing Spanish headings: $inicio_content"
fi

es_banner="<!-- Generated by atelier — edits here are overwritten; write to Entrada/ -->"
read -r first_line < "$TEST_VAULT/Inicio.md" || true
[ "$first_line" = "$es_banner" ] \
  && pass "Spanish banner references Entrada/" || fail "Spanish banner mismatch: $first_line"

es_rec="$(cat "$TEST_VAULT/Registros/$id_d1.md")"
if grepq "## Cadena de reemplazo" <<<"$es_rec" && \
   grepq "## Referencias" <<<"$es_rec"; then
  pass "Registros note contains Spanish section headers"
else
  fail "Registros note Spanish headers missing: $es_rec"
fi

# 3d. Fallback: unknown language defaults to English
printf '{"chatLanguage": "klingon"}\n' > "$ATELIER_CONFIG_DIR/operator.json"
mem render --full

[ -f "$TEST_VAULT/Home.md" ] && [ ! -f "$TEST_VAULT/Inicio.md" ] \
  && [ -d "$TEST_VAULT/Projects" ] && [ -d "$TEST_VAULT/Records" ] && [ -d "$TEST_VAULT/Inbox" ] \
  && [ -f "$TEST_VAULT/Inbox/operator-draft.md" ] \
  && pass "unknown language falls back to English and moves Entrada/ back to Inbox/" \
  || fail "unknown language fallback failed"

# Clean up operator.json for subsequent tests
rm -f "$ATELIER_CONFIG_DIR/operator.json"

# ==============================================================================
# 4. Acceptance Criterion 4: Preservation of Operator Files & Idempotence
# ==============================================================================

# Ensure we're rendered in English
mem render --full

# Add non-generated files to vault:
# - .obsidian/ directory files
mkdir -p "$TEST_VAULT/.obsidian"
echo '{"theme": "dark"}' > "$TEST_VAULT/.obsidian/app.json"
echo '["dataview", "canvas"]' > "$TEST_VAULT/.obsidian/community-plugins.json"

# - Custom notes in root, Projects, Records without the banner
echo "# Personal Dashboard" > "$TEST_VAULT/Dashboard.md"
echo "# Manual Project Plan" > "$TEST_VAULT/Projects/ManualPlan.md"
echo "# Operator Scratchpad" > "$TEST_VAULT/Records/scratchpad.txt"
echo "# Inbox note 2" > "$TEST_VAULT/Inbox/note2.txt"

# Re-render
mem render --full

# 4a. Verify preservation
[ -f "$TEST_VAULT/.obsidian/app.json" ] \
  && [ "$(cat "$TEST_VAULT/.obsidian/app.json")" = '{"theme": "dark"}' ] \
  && pass ".obsidian/app.json preserved untouched" || fail ".obsidian/app.json modified or deleted"

[ -f "$TEST_VAULT/.obsidian/community-plugins.json" ] \
  && pass ".obsidian/community-plugins.json preserved" || fail ".obsidian/community-plugins.json lost"

[ -f "$TEST_VAULT/Dashboard.md" ] \
  && [ "$(cat "$TEST_VAULT/Dashboard.md")" = "# Personal Dashboard" ] \
  && pass "root operator note Dashboard.md preserved" || fail "Dashboard.md modified or deleted"

[ -f "$TEST_VAULT/Projects/ManualPlan.md" ] \
  && [ "$(cat "$TEST_VAULT/Projects/ManualPlan.md")" = "# Manual Project Plan" ] \
  && pass "Projects/ManualPlan.md operator note preserved" || fail "ManualPlan.md modified or deleted"

[ -f "$TEST_VAULT/Records/scratchpad.txt" ] \
  && [ "$(cat "$TEST_VAULT/Records/scratchpad.txt")" = "# Operator Scratchpad" ] \
  && pass "Records/scratchpad.txt operator note preserved" || fail "scratchpad.txt modified or deleted"

[ -f "$TEST_VAULT/Inbox/note2.txt" ] \
  && pass "Inbox/note2.txt preserved" || fail "Inbox/note2.txt lost"

# 4b. Idempotence: running render twice produces byte-identical generated output
snap_vault() {
  (
    cd "$TEST_VAULT" || exit 1
    find Home.md Projects Records Issues PRs -type f | sort | while read -r f; do
      printf '%s ' "$f"
      cksum "$f"
    done
  )
}

snap1="$(snap_vault)"
mem render --full
snap2="$(snap_vault)"

[ "$snap1" = "$snap2" ] \
  && pass "running render twice gives byte-identical generated output (idempotent)" \
  || fail "render is not idempotent; diff: $(diff -u <(echo "$snap1") <(echo "$snap2"))"

# ==============================================================================
# 5. Acceptance Criterion 5: Incremental Re-render on Writes & Failure Resilience
# ==============================================================================

# 5a. add triggers incremental re-render
id_f_inc="$(mem add fact --project "$PROJ" --source agent-inferred --title "Incremental fact title")"
[ -f "$TEST_VAULT/Records/$id_f_inc.md" ] \
  && grep -q "$id_f_inc" "$TEST_VAULT/Home.md" \
  && grep -q "Incremental fact title" "$TEST_VAULT/Projects/$PROJ_SLUG.md" \
  && pass "add triggers incremental render updating record note, index, and project note" \
  || fail "add incremental render failed for $id_f_inc"

# 5b. close triggers incremental re-render
mem close "$id_r1" --by "operator closing request"
# Check frontmatter in record note has closed timestamp (not null)
grep -q '^closed: 20' "$TEST_VAULT/Records/$id_r1.md" \
  && pass "close updates record frontmatter with closed timestamp" \
  || fail "close did not update frontmatter in $TEST_VAULT/Records/$id_r1.md"

# Check project note has removed R-1 from Open requests
if grep -q "\- \[\[$id_r1\]\]" "$TEST_VAULT/Projects/$PROJ_SLUG.md"; then
  fail "closed request $id_r1 still listed in Open requests of project note"
else
  pass "close updates project note to remove closed item from Open requests"
fi

# 5c. supersede triggers incremental re-render
id_d4="$(mem supersede "$id_d3" --source agent-inferred --title "Decision v4: latest increment")"
# Verify new record note exists and has complete supersede chain
case "$(cat "$TEST_VAULT/Records/$id_d4.md")" in
  *"## Supersede chain"*"- [[$id_d1]] -> [[$id_d2]] -> [[$id_d3]] -> [[$id_d4]]"*)
    pass "supersede renders new record note with full chain"
    ;;
  *)
    fail "supersede new note chain mismatch"
    ;;
esac

# Verify old record note was incrementally updated with new superseded_by and extended chain
case "$(cat "$TEST_VAULT/Records/$id_d1.md")" in
  *"## Supersede chain"*"- [[$id_d1]] -> [[$id_d2]] -> [[$id_d3]] -> [[$id_d4]]"*)
    pass "supersede incrementally updates predecessor notes in supersede chain"
    ;;
  *)
    fail "supersede did not update predecessor chain in $id_d1"
    ;;
esac

# 5d. import triggers re-render
enc_path() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
MEM_IMPORT_DIR="$ATELIER_CONFIG_DIR/projects/$(enc_path "$PROJ")/memory"
mkdir -p "$MEM_IMPORT_DIR"
cat <<'EOF' > "$MEM_IMPORT_DIR/imported-fact.md"
---
name: Obsidian rendering verified
type: fact
---
Learned that obsidian rendering works cleanly.
EOF

# Register project in projects.json so import maps directory to $PROJ
jq -n --arg p "$PROJ" '{projects: {($p): {name: "proj"}}}' > "$ATELIER_CONFIG_DIR/projects.json"

mem import --project "$PROJ" >/dev/null 2>&1
# Check that an imported fact note now exists in Records
imported_id="$(printf "SELECT id FROM records WHERE body LIKE '%%Learned that obsidian rendering works%%';" | sqlite3 "$ATELIER_CONFIG_DIR/atelier/memory.db")"
[ -n "$imported_id" ] && [ -f "$TEST_VAULT/Records/$imported_id.md" ] \
  && pass "import triggers re-render and imported record note is rendered in vault" \
  || fail "import did not render note for $imported_id"

# 5e. Render failure resilience: a failing vault render does NOT fail write or corrupt DB
RO_PARENT="$TMP/ro-parent"
mkdir -p "$RO_PARENT"
chmod 500 "$RO_PARENT"

# Point ATELIER_MEMORY_VAULT to a path inside read-only directory
out_id=""
err_out="$TMP/add-fail-err.txt"
out_id="$(ATELIER_MEMORY_VAULT="$RO_PARENT/vault" mem add fact --project "$PROJ" --source agent-inferred --title "Fact during vault failure" 2>"$err_out")"
add_rc=$?

# Restore permissions for cleanup
chmod 700 "$RO_PARENT"

[ "$add_rc" = 0 ] && [ -n "$out_id" ] \
  && pass "add succeeds (exit 0) even when vault render fails" \
  || fail "add failed when vault render failed (rc=$add_rc, out=$out_id)"

grep -q "atelier-memory: vault render warning" "$err_out" \
  && pass "add prints warning to stderr on vault render failure" \
  || fail "missing vault render warning on stderr: $(cat "$err_out")"

# Verify record is in database and DB is not corrupted
db_row="$(printf "SELECT title FROM records WHERE id=%s;" "'$out_id'" | sqlite3 "$ATELIER_CONFIG_DIR/atelier/memory.db")"
[ "$db_row" = "Fact during vault failure" ] \
  && pass "record successfully stored in DB during vault render failure" \
  || fail "record not found in DB: $db_row"

db_integrity="$(printf 'PRAGMA integrity_check;' | sqlite3 "$ATELIER_CONFIG_DIR/atelier/memory.db")"
[ "$db_integrity" = "ok" ] \
  && pass "DB integrity is 'ok' after vault render failure" \
  || fail "DB corrupted after vault failure: $db_integrity"

# Also test close under vault render failure
chmod 500 "$RO_PARENT"
err_close="$TMP/close-fail-err.txt"
close_out="$(ATELIER_MEMORY_VAULT="$RO_PARENT/vault" mem close "$out_id" --by "test" 2>"$err_close")"
close_rc=$?
chmod 700 "$RO_PARENT"

[ "$close_rc" = 0 ] \
  && pass "close succeeds (exit 0) when vault render fails" \
  || fail "close failed during vault render failure (rc=$close_rc)"

grep -q "atelier-memory: vault render warning" "$err_close" \
  && pass "close prints warning to stderr on vault render failure" \
  || fail "close missing vault render warning"

# Re-run full render to bring vault back into sync
mem render --full >/dev/null 2>&1
[ -f "$TEST_VAULT/Records/$out_id.md" ] \
  && pass "subsequent full render reconciles previously missed records" \
  || fail "full render did not reconcile $out_id"

# ==============================================================================
# 6. Acceptance Criterion 6: Disabling Rendering
# ==============================================================================

# 6a. Disabled via ATELIER_MEMORY_VAULT=off
snap_before="$(snap_vault)"
err_dis="$TMP/dis-err.txt"
( ATELIER_MEMORY_VAULT=off mem render 2>"$err_dis" )
dis_rc=$?

[ "$dis_rc" = 0 ] && grep -q "atelier-memory: vault render disabled" "$err_dis" \
  && pass "ATELIER_MEMORY_VAULT=off disables render command with message" \
  || fail "ATELIER_MEMORY_VAULT=off render command check (rc=$dis_rc, err=$(cat "$err_dis"))"

# Write with ATELIER_MEMORY_VAULT=off should not modify vault
off_id="$(ATELIER_MEMORY_VAULT=off mem add fact --project "$PROJ" --source agent-inferred --title "Fact while disabled via env")"
snap_after="$(snap_vault)"
[ "$snap_before" = "$snap_after" ] \
  && [ ! -f "$TEST_VAULT/Records/$off_id.md" ] \
  && pass "ATELIER_MEMORY_VAULT=off prevents writes from modifying vault" \
  || fail "vault was modified while ATELIER_MEMORY_VAULT=off"

# 6b. Disabled via operator.json .memory.vault: false
printf '{"memory": {"vault": false}}\n' > "$ATELIER_CONFIG_DIR/operator.json"
err_cfg_dis="$TMP/cfg-dis-err.txt"
mem render 2>"$err_cfg_dis"
cfg_dis_rc=$?

[ "$cfg_dis_rc" = 0 ] && grep -q "atelier-memory: vault render disabled" "$err_cfg_dis" \
  && pass "operator.json .memory.vault: false disables render command" \
  || fail "operator.json vault:false render check (rc=$cfg_dis_rc, err=$(cat "$err_cfg_dis"))"

snap_before2="$(snap_vault)"
cfg_off_id="$(mem add fact --project "$PROJ" --source agent-inferred --title "Fact while disabled via config")"
snap_after2="$(snap_vault)"
[ "$snap_before2" = "$snap_after2" ] \
  && [ ! -f "$TEST_VAULT/Records/$cfg_off_id.md" ] \
  && pass "operator.json .memory.vault: false prevents writes from modifying vault" \
  || fail "vault was modified while disabled via operator.json"

# Clean up operator.json
rm -f "$ATELIER_CONFIG_DIR/operator.json"

# ==============================================================================
# 7. Acceptance Criterion 7: block-subagent-memory-write.sh Allows render
# ==============================================================================

test_hook_allow() {
  local cmd="$1"
  local payload
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}, agent_id:"sub-1", agent_type:"atelier:implementer"}')"
  (
    cd "$PROJ" || exit 99
    export HOME="$TMP/home" ATELIER_CONFIG_DIR="$ATELIER_CONFIG_DIR"
    export CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP"
    unset ATELIER_ALLOW_SUBAGENT_MEMORY_WRITE CLAUDE_CODE_CHILD_SESSION
    bash "$HOOK" <<<"$payload" >/dev/null 2>"$TMP/hook-stderr"
  )
  return $?
}

test_hook_allow 'atelier-memory render' \
  && pass "block-subagent-memory-write.sh allows 'atelier-memory render' for subagents" \
  || fail "block-subagent-memory-write.sh blocked 'atelier-memory render'"

test_hook_allow 'atelier-memory render --full' \
  && pass "block-subagent-memory-write.sh allows 'atelier-memory render --full' for subagents" \
  || fail "block-subagent-memory-write.sh blocked 'atelier-memory render --full'"

test_hook_allow 'scripts/atelier-memory render --vault /tmp/v' \
  && pass "block-subagent-memory-write.sh allows 'scripts/atelier-memory render --vault' for subagents" \
  || fail "block-subagent-memory-write.sh blocked scripts/atelier-memory render --vault"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "atelier-memory-render: all tests passed"
  exit 0
fi
echo "atelier-memory-render: $fails test(s) failed"
exit 1
