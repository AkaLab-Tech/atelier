#!/usr/bin/env bash
#
# Regression test for #39 F2 — the versioned managed runtime dir.
#
# install.sh Phase C.1 (phase_c_1_runtime_dir) copies scripts/ + templates/
# (+ install.sh + .claude-plugin/plugin.json) from $ATELIER_SOURCE_ROOT into
# $ATELIER_RUNTIME_BASE/<version>/, atomically swaps the relative `current`
# symlink, prunes down to the 2 most recent versions (never the one `current`
# points to), and _phase_c_1_symlink_helper links ~/.local/bin/atelier-* at
# current/scripts/* — migrating pre-#39 clone-pointing links automatically.
#
# Hermetic: sources install.sh (main-gated) inside throwaway HOME +
# ATELIER_RUNTIME_DIR trees and drives the phase functions directly.
# Requires: git, jq, diff (install.sh Phase-A deps / POSIX).
#
# Run:  hooks/tests/install-runtime-dir.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
RT="$TMP/home/.runtime"
BIN="$HOME_DIR/.local/bin"
SRC="$TMP/source-tree"
mkdir -p "$BIN"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "versioned runtime dir install + swap + prune + symlink migration (#39 F2)"

# ---------------------------------------------------------------------------
# Fixture: fake atelier source tree (plain tree = snapshot mode, same shape
# the plugin cache ships).
# ---------------------------------------------------------------------------
mkdir -p "$SRC/scripts" "$SRC/templates" "$SRC/.claude-plugin"
printf '#!/usr/bin/env bash\necho foo-v1\n' > "$SRC/scripts/atelier-foo"
chmod +x "$SRC/scripts/atelier-foo"
printf 'template-x\n' > "$SRC/templates/x"
printf '#!/usr/bin/env bash\necho fake-installer\n' > "$SRC/install.sh"
mkdir -p "$SRC/agents/decision-broker"
printf '{ "categories": {} }\n' > "$SRC/agents/decision-broker/catalog.json"

set_version() {
  printf '{\n  "name": "atelier",\n  "version": "%s"\n}\n' "$1" > "$SRC/.claude-plugin/plugin.json"
}
set_version "0.0.1"

# run_phase — source install.sh under the scratch HOME/runtime env and run
# the runtime-dir phase + one helper symlink. Prints phase output + the
# detected SOURCE_MODE on the last line.
run_phase() {
  HOME="$HOME_DIR" ATELIER_RUNTIME_DIR="$RT" ATELIER_SOURCE_ROOT="$SRC" \
    NO_COLOR=1 INSTALL="$INSTALL" bash -c '
    set -euo pipefail
    # shellcheck disable=SC1090
    source "$INSTALL"
    resolve_source_root
    detect_source_mode
    phase_c_1_runtime_dir
    _phase_c_1_symlink_helper atelier-foo
    printf "SOURCE_MODE=%s\n" "$SOURCE_MODE"
  ' 2>&1
}

# ---------------------------------------------------------------------------
# Group 1: fresh install — runtime dir layout, current swap, bin symlink
# migration away from a pre-#39 clone target.
# ---------------------------------------------------------------------------

# Pre-plant a stale clone-era symlink: ~/.local/bin/atelier-foo -> <clone>/scripts/.
ln -s "$TMP/old-clone/scripts/atelier-foo" "$BIN/atelier-foo"

out1="$(run_phase)" || fail "first run exited non-zero: $out1"

[ -x "$RT/0.0.1/scripts/atelier-foo" ] \
  && pass "scripts/ copied into <runtime>/0.0.1/ (exec bit preserved)" \
  || fail "runtime scripts copy missing or not executable"
[ -f "$RT/0.0.1/templates/x" ] \
  && pass "templates/ copied preserving layout" \
  || fail "runtime templates copy missing"
[ -f "$RT/0.0.1/install.sh" ] && [ -f "$RT/0.0.1/.claude-plugin/plugin.json" ] \
  && pass "install.sh + plugin.json ride along for version introspection" \
  || fail "install.sh / plugin.json missing from runtime dir"
[ -f "$RT/0.0.1/agents/decision-broker/catalog.json" ] \
  && pass "decision-broker catalog rides along (setup-project policy prompts)" \
  || fail "agents/decision-broker/catalog.json missing from runtime dir"
[ "$(readlink "$RT/current")" = "0.0.1" ] \
  && pass "current is a RELATIVE symlink to 0.0.1" \
  || fail "current target: expected '0.0.1', got '$(readlink "$RT/current" 2>/dev/null)'"
[ "$(readlink "$BIN/atelier-foo")" = "$RT/current/scripts/atelier-foo" ] \
  && pass "stale clone symlink migrated to current/scripts/" \
  || fail "bin symlink: got '$(readlink "$BIN/atelier-foo" 2>/dev/null)'"
printf '%s' "$out1" | grep -q 'updated symlink' \
  && pass "migration logged as an updated symlink" \
  || fail "no 'updated symlink' log line (out: $out1)"
[ "$("$BIN/atelier-foo")" = "foo-v1" ] \
  && pass "helper resolves through current and runs" \
  || fail "helper did not execute through the runtime dir"
printf '%s' "$out1" | grep -q 'SOURCE_MODE=snapshot' \
  && pass "plain source tree ran in snapshot mode" \
  || fail "expected snapshot mode (out: $out1)"
staging_leftovers=("$RT"/.staging-*)
if [ -e "${staging_leftovers[0]}" ]; then
  fail "staging dir leaked into the runtime base"
else
  pass "no staging leftovers"
fi

# ---------------------------------------------------------------------------
# Group 2: idempotent re-run (identical content → skip, nothing rewritten)
# ---------------------------------------------------------------------------
out2="$(run_phase)" || fail "second run exited non-zero: $out2"
printf '%s' "$out2" | grep -q 'already in place' \
  && pass "identical re-run skips the copy" \
  || fail "re-run did not skip (out: $out2)"
printf '%s' "$out2" | grep -q 'already symlinked' \
  && pass "bin symlink untouched on re-run" \
  || fail "bin symlink churned on re-run (out: $out2)"

# ---------------------------------------------------------------------------
# Group 3: same version, changed content → replaced via staging+mv
# ---------------------------------------------------------------------------
printf '#!/usr/bin/env bash\necho foo-v1-hotfix\n' > "$SRC/scripts/atelier-foo"
chmod +x "$SRC/scripts/atelier-foo"
out3="$(run_phase)" || fail "hotfix run exited non-zero: $out3"
printf '%s' "$out3" | grep -q 'replaced runtime 0.0.1' \
  && pass "same-version content change replaces the version dir" \
  || fail "no replace on content change (out: $out3)"
[ "$("$BIN/atelier-foo")" = "foo-v1-hotfix" ] \
  && pass "replaced content is live through current/" \
  || fail "helper still serves stale content"

# ---------------------------------------------------------------------------
# Group 4: version bump → atomic swap, previous version retained
# ---------------------------------------------------------------------------
# Force deterministic mtime ordering for the prune (dir mtimes can collide
# within the same second on fast runs).
touch -t 202001010000 "$RT/0.0.1"

set_version "0.0.2"
printf '#!/usr/bin/env bash\necho foo-v2\n' > "$SRC/scripts/atelier-foo"
chmod +x "$SRC/scripts/atelier-foo"
out4="$(run_phase)" || fail "v0.0.2 run exited non-zero: $out4"
[ "$(readlink "$RT/current")" = "0.0.2" ] \
  && pass "current swapped to 0.0.2" \
  || fail "current: got '$(readlink "$RT/current")'"
[ -d "$RT/0.0.1" ] \
  && pass "previous version 0.0.1 retained for rollback" \
  || fail "0.0.1 was pruned too early"
[ "$("$BIN/atelier-foo")" = "foo-v2" ] \
  && pass "bin symlink serves the new version with zero re-linking" \
  || fail "helper did not follow the current swap"

# ---------------------------------------------------------------------------
# Group 5: third version → oldest pruned, keep 2, never current's target
# ---------------------------------------------------------------------------
touch -t 202001020000 "$RT/0.0.2"
set_version "0.0.3"
printf '#!/usr/bin/env bash\necho foo-v3\n' > "$SRC/scripts/atelier-foo"
chmod +x "$SRC/scripts/atelier-foo"
out5="$(run_phase)" || fail "v0.0.3 run exited non-zero: $out5"
[ "$(readlink "$RT/current")" = "0.0.3" ] \
  && pass "current swapped to 0.0.3" \
  || fail "current: got '$(readlink "$RT/current")'"
[ ! -d "$RT/0.0.1" ] \
  && pass "oldest version 0.0.1 pruned (keep 2)" \
  || fail "0.0.1 not pruned"
[ -d "$RT/0.0.2" ] && [ -d "$RT/0.0.3" ] \
  && pass "two most recent versions retained" \
  || fail "expected 0.0.2 + 0.0.3 to remain"

# Never prune the dir `current` points to, even when it is the oldest.
RT2="$TMP/runtime2"
mkdir -p "$RT2/1.0.0" "$RT2/1.0.1" "$RT2/1.0.2"
touch -t 202001010000 "$RT2/1.0.0"
touch -t 202001020000 "$RT2/1.0.1"
touch -t 202001030000 "$RT2/1.0.2"
ln -s "1.0.0" "$RT2/current"   # simulate an operator rollback to the oldest
HOME="$HOME_DIR" ATELIER_RUNTIME_DIR="$RT2" NO_COLOR=1 INSTALL="$INSTALL" bash -c '
  set -euo pipefail
  # shellcheck disable=SC1090
  source "$INSTALL"
  _runtime_prune_old_versions
' >/dev/null 2>&1
[ -d "$RT2/1.0.0" ] \
  && pass "prune NEVER removes the version current points to" \
  || fail "prune removed current's target (rollback dir gone)"
# Repoint current at the newest — the oldest is now fair game.
ln -sfn "1.0.2" "$RT2/current"
HOME="$HOME_DIR" ATELIER_RUNTIME_DIR="$RT2" NO_COLOR=1 INSTALL="$INSTALL" bash -c '
  set -euo pipefail
  # shellcheck disable=SC1090
  source "$INSTALL"
  _runtime_prune_old_versions
' >/dev/null 2>&1
[ ! -d "$RT2/1.0.0" ] && [ -d "$RT2/1.0.1" ] && [ -d "$RT2/1.0.2" ] \
  && pass "after repointing current, the unprotected oldest is pruned" \
  || fail "prune-after-repoint: unexpected survivors: $(ls "$RT2")"

# ---------------------------------------------------------------------------
# Group 6: clone-mode source ALSO goes through the runtime dir (single path)
# ---------------------------------------------------------------------------
git -C "$SRC" init -q
out6="$(run_phase)" || fail "clone-mode run exited non-zero: $out6"
printf '%s' "$out6" | grep -q 'SOURCE_MODE=clone' \
  && pass "git source tree detected as clone" \
  || fail "expected clone mode (out: $out6)"
[ "$(readlink "$RT/current")" = "0.0.3" ] && [ -x "$RT/0.0.3/scripts/atelier-foo" ] \
  && pass "clone mode populates the same runtime dir (single code path)" \
  || fail "clone mode bypassed the runtime dir"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "install-runtime-dir: all assertions passed."
  exit 0
else
  echo "install-runtime-dir: $fails assertion(s) failed."
  exit 1
fi
