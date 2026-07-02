#!/usr/bin/env bash
#
# Regression test for #39 F5 — atelier-uninstall removes the managed runtime
# dir and every ~/.local/bin/atelier-* symlink.
#
# COVERAGE
#   Group 1 — default (non-purge) mode, non-interactive:
#     - removes $HOME/.local/share/atelier entirely (all version dirs +
#       the `current` symlink)
#     - removes EVERY atelier-* symlink in ~/.local/bin (auto-discovered,
#       not a fixed name list), including ones resolving into the runtime dir
#     - leaves a plain-file atelier-* (operator-pinned copy) alone
#     - strips the shellrc hook block, removes ~/.local/state/atelier
#     - PRESERVES $ATELIER_CONFIG_DIR (the documented default contract)
#   Group 2 — confirmation contract unchanged:
#     - --purge without --yes on a non-TTY refuses with exit 2 and
#       preserves $ATELIER_CONFIG_DIR
#     - --purge --yes removes $ATELIER_CONFIG_DIR
#
# Hermetic: scratch HOME + config dir, `claude` shimmed on PATH so the
# plugin-uninstall step never touches a real CLI/config. No network, no git.
#
# Run:  hooks/tests/atelier-uninstall-runtime.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UNINSTALL="$REPO_ROOT/scripts/atelier-uninstall"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
BIN="$HOME_DIR/.local/bin"
RT="$HOME_DIR/.local/share/atelier"
STATE_DIR="$HOME_DIR/.local/state/atelier"
CFG="$TMP/cfg"
SHIM_BIN="$TMP/shim-bin"
mkdir -p "$SHIM_BIN"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# Fake claude CLI: records the call, succeeds. Keeps step_plugin_uninstall
# away from any real CLI/config.
cat > "$SHIM_BIN/claude" <<'SHIM'
#!/usr/bin/env bash
printf '%s|%s\n' "${CLAUDE_CONFIG_DIR:-<unset>}" "$*" >> "${FAKE_CLAUDE_STATE:?}/calls.log"
exit 0
SHIM
chmod +x "$SHIM_BIN/claude"

# ---------------------------------------------------------------------------
# Fixture builder: the layout install.sh F2 leaves behind — versioned runtime
# dir + current, helper symlinks through current/, shellrc block, state dir,
# and a populated config dir.
# ---------------------------------------------------------------------------
build_fixture() {
  rm -rf "$HOME_DIR" "$CFG"
  mkdir -p "$BIN" "$RT/0.1.0/scripts" "$RT/0.2.0/scripts" "$STATE_DIR" \
           "$CFG/templates" "$TMP/state"
  printf '#!/usr/bin/env bash\necho foo\n' > "$RT/0.2.0/scripts/atelier-foo"
  chmod +x "$RT/0.2.0/scripts/atelier-foo"
  ln -s "0.2.0" "$RT/current"
  ln -s "$RT/current/scripts/atelier-foo" "$BIN/atelier-foo"
  ln -s "$RT/current/scripts/atelier-setup-project" "$BIN/atelier-setup-project"
  # Operator-pinned plain file (NOT a symlink) — must survive.
  printf '#!/usr/bin/env bash\necho pinned\n' > "$BIN/atelier-pinned"
  chmod +x "$BIN/atelier-pinned"
  printf 'deadbeef\n' > "$STATE_DIR/git-wt.sha"
  printf 'history\n' > "$CFG/history.jsonl"
  cat > "$HOME_DIR/.zshrc" <<'RC'
# operator content above
# >>> atelier hooks (managed by install.sh) >>>
export PATH="$HOME/.local/bin:$PATH"
# <<< atelier hooks (managed by install.sh) <<<
# operator content below
RC
}

run_uninstall() {
  HOME="$HOME_DIR" ATELIER_CONFIG_DIR="$CFG" FAKE_CLAUDE_STATE="$TMP/state" \
    PATH="$SHIM_BIN:$PATH" bash "$UNINSTALL" "$@" </dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Group 1 — default mode removes the runtime dir + all helper symlinks,
# preserves the config dir.
# ---------------------------------------------------------------------------
echo "Group 1: default (non-purge) uninstall"
build_fixture
out1="$(run_uninstall)"
rc1=$?
[ "$rc1" -eq 0 ] \
  && pass "default uninstall exits 0" \
  || fail "default uninstall rc=$rc1 (out: $out1)"
[ ! -e "$RT" ] && [ ! -L "$RT" ] \
  && pass "runtime dir removed (all version dirs + current symlink)" \
  || fail "runtime dir survives: $(ls -la "$RT" 2>/dev/null)"
printf '%s' "$out1" | grep -q "runtime dir:.*removed:" \
  && pass "summary reports the runtime dir removal" \
  || fail "no runtime-dir summary line (out: $out1)"
[ ! -L "$BIN/atelier-foo" ] && [ ! -L "$BIN/atelier-setup-project" ] \
  && pass "every atelier-* symlink removed (runtime-dir targets included)" \
  || fail "symlinks left behind: $(ls -la "$BIN" 2>/dev/null)"
[ -f "$BIN/atelier-pinned" ] \
  && pass "operator-pinned plain file left alone" \
  || fail "atelier-pinned was clobbered"
leftover=""
for e in "$BIN"/atelier-*; do
  { [ -e "$e" ] || [ -L "$e" ]; } || continue           # unmatched glob literal
  [ "$(basename "$e")" = "atelier-pinned" ] && continue  # the pinned plain file
  leftover="$leftover $(basename "$e")"
done
if [ -n "$leftover" ]; then
  fail "dangling atelier-* entries remain:$leftover"
else
  pass "no dangling helper symlinks after the runtime dir went away"
fi
[ ! -d "$STATE_DIR" ] \
  && pass "local state dir (\$HOME/.local/state/atelier) removed" \
  || fail "state dir survives"
grep -q 'atelier hooks' "$HOME_DIR/.zshrc" \
  && fail "shellrc block not stripped" \
  || pass "shellrc hook block stripped"
[ -f "$CFG/history.jsonl" ] \
  && pass "\$ATELIER_CONFIG_DIR preserved in default mode" \
  || fail "config dir was removed without --purge"

# ---------------------------------------------------------------------------
# Group 2 — the --purge confirmation contract is unchanged.
# ---------------------------------------------------------------------------
echo "Group 2: --purge confirmation contract"
build_fixture
out2="$(run_uninstall --purge)"
rc2=$?
[ "$rc2" -eq 2 ] \
  && pass "--purge without --yes on a non-TTY refuses with exit 2" \
  || fail "--purge non-TTY rc=$rc2 (out: $out2)"
[ -f "$CFG/history.jsonl" ] \
  && pass "refused purge preserves \$ATELIER_CONFIG_DIR" \
  || fail "config dir removed despite refusal"

build_fixture
out3="$(run_uninstall --purge --yes)"
rc3=$?
[ "$rc3" -eq 0 ] \
  && pass "--purge --yes exits 0" \
  || fail "--purge --yes rc=$rc3 (out: $out3)"
[ ! -d "$CFG" ] \
  && pass "--purge --yes removes \$ATELIER_CONFIG_DIR" \
  || fail "config dir survives --purge --yes"
[ ! -e "$RT" ] \
  && pass "--purge --yes also removed the runtime dir" \
  || fail "runtime dir survives --purge --yes"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "atelier-uninstall-runtime (#39 F5): all assertions passed."
  exit 0
else
  echo "atelier-uninstall-runtime (#39 F5): $fails assertion(s) failed."
  exit 1
fi
