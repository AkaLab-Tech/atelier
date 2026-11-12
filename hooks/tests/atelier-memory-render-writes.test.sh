#!/usr/bin/env bash
#
# Hermetic regression test for Obsidian vault rendering (#620, #610c), split from
# atelier-memory-render.test.sh in #764.
# Criterion 5: writes (add, supersede, close, import) trigger incremental re-renders;
# vault render failures do not fail the write or corrupt the DB.
# Run:  bash hooks/tests/atelier-memory-render-writes.test.sh
# Exit: 0 = all pass (or skipped), 1 = at least one failure.

set -uo pipefail

# shellcheck source=hooks/tests/memory-render-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/memory-render-fixture.sh"

TEST_VAULT="$TMP/vault"
export ATELIER_MEMORY_VAULT="$TEST_VAULT"
vault_assert_isolated "$TEST_VAULT"

seed_base_records
mem render --full >/dev/null 2>&1

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
mkdir -p "$MEM_IMPORT_DIR"
cat <<'EOF' > "$MEM_IMPORT_DIR/imported-fact.md"
---
name: Obsidian rendering verified
type: fact
---
Learned that obsidian rendering works cleanly.
EOF

# Register project in projects.json so import maps directory to $PROJ
register_project

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

finish "atelier-memory-render-writes"
