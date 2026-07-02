#!/usr/bin/env bash
#
# Regression test for #39 F4 — atelier-update managed mode (no git).
#
# A managed install (helpers resolving into $ATELIER_RUNTIME_DIR) updates by:
#   1. `claude plugin update atelier@akalab-tech` (pinned to
#      CLAUDE_CONFIG_DIR=$ATELIER_CONFIG_DIR) — refreshes the plugin cache;
#   2. re-reading installed_plugins.json for the active installPath/version;
#   3. copying the cached payload into $RUNTIME_BASE/<new-version>/ and
#      atomically swapping `current` (reuses install.sh's F2 phase by
#      sourcing it in a subshell) + pruning to 2 retained versions;
#   4. re-symlinking ~/.local/bin helpers through current/scripts/;
#   5. refreshing the instantiated templates in $ATELIER_CONFIG_DIR.
# Same-version runs exit 2 when nothing drifted, and still resync drifted
# symlinks/templates (exit 0) when something lagged.
#
# Hermetic: fake runtime dir at vN, fake plugin cache + installed_plugins.json
# at vN+1, fake `claude` shim that only logs. Scratch HOME/config; the real
# claude CLI and ~/.claude-work are never touched. No network, no git.
#
# Run:  hooks/tests/atelier-update-managed.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPDATE="$REPO_ROOT/scripts/atelier-update"
INSTALL="$REPO_ROOT/install.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
BIN="$HOME_DIR/.local/bin"
CFG="$TMP/cfg"
RT="$TMP/runtime"
STATE="$TMP/state"
SHIM_BIN="$TMP/shim-bin"
mkdir -p "$BIN" "$CFG/templates" "$STATE" "$SHIM_BIN"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "atelier-update managed mode: cache-driven update + runtime swap (#39 F4)"

# ---------------------------------------------------------------------------
# Fixture 1 — runtime dir at vN (0.1.0): the layout install.sh F2 lays down,
# with the REAL atelier-update + install.sh riding along, plus an extra
# pruning candidate at 0.0.9.
# ---------------------------------------------------------------------------
mkdir -p "$RT/0.1.0/scripts" "$RT/0.1.0/templates" "$RT/0.1.0/.claude-plugin" "$RT/0.0.9"
cp "$UPDATE" "$RT/0.1.0/scripts/atelier-update"
cp "$INSTALL" "$RT/0.1.0/install.sh"
printf '#!/usr/bin/env bash\necho foo-v1\n' > "$RT/0.1.0/scripts/atelier-foo"
chmod +x "$RT/0.1.0/scripts/"*
printf '{ "name": "atelier", "version": "0.1.0" }\n' > "$RT/0.1.0/.claude-plugin/plugin.json"
touch -t 202001010000 "$RT/0.0.9"
touch -t 202001020000 "$RT/0.1.0"
ln -s "0.1.0" "$RT/current"

# Helper symlinks: atelier-update routed through current/ (as F2 links it);
# atelier-foo pinned at the version dir — a stale, pre-F4-style link that the
# resync must migrate to current/.
ln -s "$RT/current/scripts/atelier-update" "$BIN/atelier-update"
ln -s "$RT/0.1.0/scripts/atelier-foo" "$BIN/atelier-foo"

# ---------------------------------------------------------------------------
# Fixture 2 — plugin cache at vN+1 (0.2.0) + installed_plugins.json pointer.
# The cache dir is the full repo tree: real install.sh (sourced for the F2
# swap), scripts/, templates/, plugin manifest.
# ---------------------------------------------------------------------------
CACHE="$CFG/plugins/cache/akalab-tech/atelier/0.2.0"
mkdir -p "$CACHE/scripts" "$CACHE/templates" "$CACHE/.claude-plugin" "$CFG/plugins"
cp "$UPDATE" "$CACHE/scripts/atelier-update"
cp "$INSTALL" "$CACHE/install.sh"
printf '#!/usr/bin/env bash\necho foo-v2\n' > "$CACHE/scripts/atelier-foo"
chmod +x "$CACHE/scripts/"*
printf '{ "name": "atelier", "version": "0.2.0" }\n' > "$CACHE/.claude-plugin/plugin.json"
printf '{ "permissions": ["<atelier-config-dir>/new-rule"] }\n' > "$CACHE/templates/settings.template.json"
printf 'project claude v2\n' > "$CACHE/templates/project-claude.md.template"
printf '{ "v": 2 }\n' > "$CACHE/templates/atelier.template.json"
printf '{"plugins":{"atelier@akalab-tech":[{"scope":"user","installPath":"%s","version":"0.2.0","gitCommitSha":"deadbeef"}]}}\n' \
  "$CACHE" > "$CFG/plugins/installed_plugins.json"

# Stale instantiated templates in the config dir (what setup-project reads).
printf '{ "permissions": ["old-rule"] }\n' > "$CFG/templates/settings.template.json"
printf 'project claude v1\n' > "$CFG/templates/project-claude.md.template"
printf '{ "v": 1 }\n' > "$CFG/templates/atelier.template.json"

# ---------------------------------------------------------------------------
# Fixture 3 — fake claude shim: logs "<CLAUDE_CONFIG_DIR>|<args>", exits 0.
# The cache/manifest above are pre-seeded at vN+1, so `plugin update` is a
# pure no-op fetch (mirrors "cache already refreshed by the CLI").
# ---------------------------------------------------------------------------
cat > "$SHIM_BIN/claude" <<'SHIM'
#!/usr/bin/env bash
printf '%s|%s\n' "${CLAUDE_CONFIG_DIR:-<unset>}" "$*" >> "${FAKE_CLAUDE_STATE:?}/calls.log"
exit 0
SHIM
chmod +x "$SHIM_BIN/claude"

run_update() {
  HOME="$HOME_DIR" ATELIER_CONFIG_DIR="$CFG" ATELIER_RUNTIME_DIR="$RT" \
    FAKE_CLAUDE_STATE="$STATE" SHELL=/bin/zsh NO_COLOR=1 \
    PATH="$SHIM_BIN:$PATH" "$BIN/atelier-update" "$@" 2>&1
}

# ---------------------------------------------------------------------------
# Group 1: --dry-run reports without mutating anything.
# ---------------------------------------------------------------------------
dry_out="$(run_update --dry-run)"
dry_rc=$?
[ "$dry_rc" -eq 0 ] \
  && pass "dry-run exits 0" \
  || fail "dry-run rc=$dry_rc (out: $dry_out)"
printf '%s' "$dry_out" | grep -q 'DRY-RUN' \
  && pass "dry-run announces itself" \
  || fail "no DRY-RUN banner (out: $dry_out)"
[ "$(readlink "$RT/current")" = "0.1.0" ] \
  && pass "dry-run leaves current untouched" \
  || fail "dry-run moved current to $(readlink "$RT/current")"
if [ -f "$STATE/calls.log" ] && grep -q 'plugin update' "$STATE/calls.log"; then
  fail "dry-run invoked claude plugin update"
else
  pass "dry-run does not invoke claude plugin update"
fi

# ---------------------------------------------------------------------------
# Group 2: real managed update — cache copied to <vN+1>/, current swapped,
# symlinks repointed through current/, templates refreshed, prune respected.
# ---------------------------------------------------------------------------
out1="$(run_update)"
rc1=$?
[ "$rc1" -eq 0 ] \
  && pass "managed update exits 0" \
  || fail "managed update rc=$rc1 (out: $out1)"
grep -q "^$CFG|plugin update atelier@akalab-tech" "$STATE/calls.log" \
  && pass "claude plugin update atelier@akalab-tech pinned to CLAUDE_CONFIG_DIR=\$ATELIER_CONFIG_DIR" \
  || fail "plugin update call missing/unpinned (log: $(cat "$STATE/calls.log" 2>/dev/null))"
[ -x "$RT/0.2.0/scripts/atelier-foo" ] && [ -f "$RT/0.2.0/install.sh" ] \
  && [ -f "$RT/0.2.0/.claude-plugin/plugin.json" ] && [ -f "$RT/0.2.0/templates/settings.template.json" ] \
  && pass "cache payload copied into <runtime>/0.2.0/ (scripts+templates+install.sh+manifest)" \
  || fail "runtime 0.2.0 payload incomplete: $(ls -R "$RT/0.2.0" 2>/dev/null)"
[ "$(readlink "$RT/current")" = "0.2.0" ] \
  && pass "current atomically swapped to 0.2.0" \
  || fail "current -> $(readlink "$RT/current" 2>/dev/null), expected 0.2.0"
[ "$(readlink "$BIN/atelier-foo")" = "$RT/current/scripts/atelier-foo" ] \
  && pass "stale version-pinned symlink repointed through current/scripts/" \
  || fail "atelier-foo -> $(readlink "$BIN/atelier-foo" 2>/dev/null)"
[ "$("$BIN/atelier-foo")" = "foo-v2" ] \
  && pass "helper serves the new version through current/" \
  || fail "helper output: $("$BIN/atelier-foo" 2>&1)"
grep -q "$CFG/new-rule" "$CFG/templates/settings.template.json" \
  && pass "settings.template.json refreshed + <atelier-config-dir> instantiated" \
  || fail "settings template stale: $(cat "$CFG/templates/settings.template.json")"
grep -q 'project claude v2' "$CFG/templates/project-claude.md.template" \
  && grep -q '"v": 2' "$CFG/templates/atelier.template.json" \
  && pass "verbatim templates refreshed from the new version" \
  || fail "verbatim templates stale"
ls "$CFG/templates/settings.template.json.bak."* >/dev/null 2>&1 \
  && pass "previous settings.template.json backed up before refresh" \
  || fail "no settings.template.json backup created"
[ ! -d "$RT/0.0.9" ] \
  && pass "oldest runtime version pruned (keep 2)" \
  || fail "0.0.9 not pruned: $(ls "$RT")"
[ -d "$RT/0.1.0" ] \
  && pass "previous version 0.1.0 retained for rollback" \
  || fail "0.1.0 pruned too early"
printf '%s' "$out1" | grep -q 'update applied' \
  && pass "reports 'update applied'" \
  || fail "no update-applied report (out: $out1)"
if git -C "$RT" rev-parse --git-dir >/dev/null 2>&1; then
  fail "managed update created git metadata in the runtime dir"
else
  pass "no git operations anywhere in the managed flow"
fi

# ---------------------------------------------------------------------------
# Group 3: same-version re-run — exits 2 (already up to date), drift checks
# still ran (proved by the sync report), nothing changed.
# ---------------------------------------------------------------------------
out2="$(run_update)"
rc2=$?
[ "$rc2" -eq 2 ] \
  && pass "same-version run exits 2 (already up to date)" \
  || fail "same-version rc=$rc2 (out: $out2)"
printf '%s' "$out2" | grep -q 'templates and helper symlinks all in sync' \
  && pass "drift checks ran on the same-version path" \
  || fail "no sync report (out: $out2)"
[ "$(readlink "$RT/current")" = "0.2.0" ] \
  && pass "same-version run leaves current alone" \
  || fail "current churned: $(readlink "$RT/current")"

# ---------------------------------------------------------------------------
# Group 4: same version but drifted symlink — exits 0 and resyncs it
# through current/.
# ---------------------------------------------------------------------------
rm -f "$BIN/atelier-foo"
out3="$(run_update)"
rc3=$?
[ "$rc3" -eq 0 ] \
  && pass "drifted same-version run exits 0 (resynced)" \
  || fail "drifted run rc=$rc3 (out: $out3)"
[ "$(readlink "$BIN/atelier-foo" 2>/dev/null)" = "$RT/current/scripts/atelier-foo" ] \
  && pass "missing helper symlink recreated through current/scripts/" \
  || fail "atelier-foo not relinked: $(readlink "$BIN/atelier-foo" 2>/dev/null)"
printf '%s' "$out3" | grep -q 'resynced' \
  && pass "reports the resync" \
  || fail "no resync report (out: $out3)"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "atelier-update-managed: all assertions passed."
  exit 0
else
  echo "atelier-update-managed: $fails assertion(s) failed."
  exit 1
fi
