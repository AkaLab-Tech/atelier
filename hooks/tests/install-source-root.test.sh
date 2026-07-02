#!/usr/bin/env bash
#
# Regression test for #39 F1 — parameterized source root + clone/snapshot
# mode detection in install.sh, and the managed-mode stub in atelier-update.
#
# install.sh side:
#   - resolve_source_root precedence: --source-root flag > $ATELIER_SOURCE_ROOT
#     env > the directory install.sh lives in (legacy behavior).
#   - detect_source_mode: git repo → "clone"; plain tree (plugin cache,
#     unpacked tarball) → "snapshot"; --from-cache forces "snapshot".
#   - main-gate: sourcing install.sh defines functions without running main
#     (this is what lets this suite exercise phase functions hermetically).
#
# atelier-update side:
#   - managed root (under the versioned runtime dir) → clean stub: exit 0 +
#     "managed install detected" message (the real managed update is #39 F4).
#   - clone root → EXACTLY today's git path (proved by reaching the
#     "no 'origin' remote" die on a remote-less throwaway repo).
#   - --plugin-root / non-git non-managed roots keep their hard failures.
#
# Hermetic: throwaway mktemp trees + local git repos only. No network.
# Requires: git, jq (install.sh Phase-A deps).
#
# Run:  hooks/tests/install-source-root.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"
UPDATE="$REPO_ROOT/scripts/atelier-update"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "install source-root resolution + mode detection (#39 F1)"

# ---------------------------------------------------------------------------
# Fixtures: two minimal atelier-shaped source trees (scripts/ + templates/ +
# .claude-plugin/plugin.json), one a git repo, one a plain tree.
# ---------------------------------------------------------------------------
mk_tree() {
  mkdir -p "$1/scripts" "$1/templates" "$1/.claude-plugin"
  printf '{\n  "name": "atelier",\n  "version": "9.9.9"\n}\n' > "$1/.claude-plugin/plugin.json"
  printf '#!/usr/bin/env bash\necho foo\n' > "$1/scripts/atelier-foo"
  chmod +x "$1/scripts/atelier-foo"
  : > "$1/templates/x"
}

SRC_GIT="$TMP/clone-tree"
SRC_PLAIN="$TMP/snapshot-tree"
mk_tree "$SRC_GIT"
mk_tree "$SRC_PLAIN"
git -C "$SRC_GIT" init -q

# probe <env-source-root|""> [install.sh args...]
# Sources install.sh, runs parse_args + resolve_source_root +
# detect_source_mode, prints "<mode>|<root>". Empty first arg = env unset.
probe() {
  local envroot="$1"; shift
  ATELIER_SOURCE_ROOT="$envroot" INSTALL="$INSTALL" bash -c '
    set -euo pipefail
    [ -n "${ATELIER_SOURCE_ROOT:-}" ] || unset ATELIER_SOURCE_ROOT
    # shellcheck disable=SC1090
    source "$INSTALL"
    parse_args "$@"
    resolve_source_root
    detect_source_mode
    printf "%s|%s\n" "$SOURCE_MODE" "$ATELIER_SOURCE_ROOT"
  ' probe "$@" 2>/dev/null
}

# physical path (mktemp on macOS returns /var/... which is a symlink to
# /private/var/...; resolve_source_root normalizes via cd -P).
phys() { (cd -P "$1" && pwd); }

# --- mode detection ---
out="$(probe "$SRC_PLAIN")"
[ "$out" = "snapshot|$(phys "$SRC_PLAIN")" ] \
  && pass "plain tree detected as snapshot" \
  || fail "plain tree: expected snapshot, got '$out'"

out="$(probe "$SRC_GIT")"
[ "$out" = "clone|$(phys "$SRC_GIT")" ] \
  && pass "git repo detected as clone" \
  || fail "git repo: expected clone, got '$out'"

out="$(probe "$SRC_GIT" --from-cache)"
[ "$out" = "snapshot|$(phys "$SRC_GIT")" ] \
  && pass "--from-cache forces snapshot mode even on a git repo" \
  || fail "--from-cache: expected snapshot, got '$out'"

# --- precedence ---
out="$(probe "$SRC_PLAIN" --source-root "$SRC_GIT")"
[ "$out" = "clone|$(phys "$SRC_GIT")" ] \
  && pass "--source-root flag wins over \$ATELIER_SOURCE_ROOT env" \
  || fail "flag precedence: got '$out'"

out="$(probe "" --source-root="$SRC_PLAIN")"
[ "$out" = "snapshot|$(phys "$SRC_PLAIN")" ] \
  && pass "--source-root=<path> form accepted" \
  || fail "--source-root= form: got '$out'"

out="$(probe "")"
[ "${out#*|}" = "$(phys "$REPO_ROOT")" ] \
  && pass "no flag/env → defaults to the dir install.sh lives in" \
  || fail "default root: expected $(phys "$REPO_ROOT"), got '$out'"

# --- validation failures ---
if probe "" --source-root "$TMP/does-not-exist" >/dev/null 2>&1; then
  fail "--source-root on a missing dir should die"
else
  pass "--source-root on a missing dir dies"
fi

mkdir -p "$TMP/not-atelier"
if probe "" --source-root "$TMP/not-atelier" >/dev/null 2>&1; then
  fail "--source-root on a non-atelier tree should die"
else
  pass "--source-root on a non-atelier tree dies (missing scripts/ + plugin.json)"
fi

# --- main-gate: sourcing install.sh must not run main ---
gate_out="$(INSTALL="$INSTALL" bash -c 'set -euo pipefail; source "$INSTALL"' 2>&1)"
gate_rc=$?
if [ "$gate_rc" -eq 0 ] && ! printf '%s' "$gate_out" | grep -q 'install.sh starting'; then
  pass "main-gate: sourcing install.sh defines functions, does not run main"
else
  fail "main-gate: sourcing ran main or exited $gate_rc (out: $gate_out)"
fi

# --- --help documents the new flags ---
help_out="$(bash "$INSTALL" --help 2>&1)"
printf '%s' "$help_out" | grep -q -- '--source-root' \
  && pass "--help documents --source-root" || fail "--help missing --source-root"
printf '%s' "$help_out" | grep -q -- '--from-cache' \
  && pass "--help documents --from-cache" || fail "--help missing --from-cache"

# ---------------------------------------------------------------------------
# atelier-update: managed-mode stub + clone path unchanged
# ---------------------------------------------------------------------------
echo "atelier-update managed/clone mode (#39 F1)"

# Fake managed runtime dir: <base>/<version>/{scripts/atelier-update,install.sh},
# current -> <version>, bin symlink routed through current (as install.sh F2
# lays it out).
RT="$TMP/runtime"
mkdir -p "$RT/0.0.1/scripts"
cp "$UPDATE" "$RT/0.0.1/scripts/atelier-update"
chmod +x "$RT/0.0.1/scripts/atelier-update"
: > "$RT/0.0.1/install.sh"
ln -s "0.0.1" "$RT/current"
mkdir -p "$TMP/bin"
ln -s "$RT/current/scripts/atelier-update" "$TMP/bin/atelier-update"

managed_out="$(ATELIER_RUNTIME_DIR="$RT" "$TMP/bin/atelier-update" 2>&1)"
managed_rc=$?
[ "$managed_rc" -eq 0 ] \
  && pass "managed root: exits 0" \
  || fail "managed root: expected exit 0, got $managed_rc (out: $managed_out)"
printf '%s' "$managed_out" | grep -q 'managed install detected' \
  && pass "managed root: prints the managed-install stub message" \
  || fail "managed root: stub message missing (out: $managed_out)"
printf '%s' "$managed_out" | grep -q -- '--plugin-root' \
  && pass "managed root: points at --plugin-root for the legacy flow" \
  || fail "managed root: legacy-flow hint missing"

# Clone mode still reaches the git path: a throwaway git repo with no origin
# remote must die with today's "no 'origin' remote" error — proof the mode
# gate routed it into the unchanged clone flow.
FAKE_CLONE="$TMP/fake-clone"
mkdir -p "$FAKE_CLONE/scripts"
cp "$UPDATE" "$FAKE_CLONE/scripts/atelier-update"
chmod +x "$FAKE_CLONE/scripts/atelier-update"
: > "$FAKE_CLONE/install.sh"
git -C "$FAKE_CLONE" init -q

clone_out="$("$FAKE_CLONE/scripts/atelier-update" 2>&1)"
clone_rc=$?
[ "$clone_rc" -ne 0 ] \
  && pass "clone root: still takes the git path (non-zero on remote-less repo)" \
  || fail "clone root: expected git-path failure, got exit 0 (out: $clone_out)"
printf '%s' "$clone_out" | grep -q "no 'origin' remote" \
  && pass "clone root: fails with today's \"no 'origin' remote\" error" \
  || fail "clone root: unexpected error (out: $clone_out)"

# --plugin-root on a non-repo keeps its hard failure (unchanged legacy check).
pr_out="$("$TMP/bin/atelier-update" --plugin-root "$TMP/not-atelier" 2>&1)"
pr_rc=$?
{ [ "$pr_rc" -ne 0 ] && printf '%s' "$pr_out" | grep -q 'is not a git repo'; } \
  && pass "--plugin-root on a non-repo still dies with 'is not a git repo'" \
  || fail "--plugin-root non-repo: rc=$pr_rc (out: $pr_out)"

# Non-git root that is NOT under the runtime dir → clear die, not a silent 0.
STRAY="$TMP/stray-root"
mkdir -p "$STRAY/scripts"
cp "$UPDATE" "$STRAY/scripts/atelier-update"
chmod +x "$STRAY/scripts/atelier-update"
: > "$STRAY/install.sh"
stray_out="$(ATELIER_RUNTIME_DIR="$RT" "$STRAY/scripts/atelier-update" 2>&1)"
stray_rc=$?
{ [ "$stray_rc" -ne 0 ] && printf '%s' "$stray_out" | grep -q 'neither a git clone nor a managed runtime dir'; } \
  && pass "non-git, non-managed root dies with a clear message" \
  || fail "stray root: rc=$stray_rc (out: $stray_out)"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "install-source-root: all assertions passed."
  exit 0
else
  echo "install-source-root: $fails assertion(s) failed."
  exit 1
fi
