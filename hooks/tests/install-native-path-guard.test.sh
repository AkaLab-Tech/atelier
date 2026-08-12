#!/usr/bin/env bash
#
# Regression test for #42 — phase_a_claude_code must patch PATH after the
# native Claude Code installer lands the binary in ~/.local/bin, or die
# loudly, rather than silently continuing with `claude` unresolved.
#
# The bug: phase_a_claude_code() ran
#   curl -fsSL https://claude.ai/install.sh | bash
# which drops the `claude` binary in ~/.local/bin, but did NOT patch PATH
# for the CURRENT install.sh run. On a clean box where ~/.local/bin is not
# already on PATH (a fresh macOS shell, a non-interactive CI-style run,
# ...), phase_b_claude_login() later runs
#   CLAUDE_CONFIG_DIR=... claude auth login
# as a plain statement. `claude` is unresolvable -> exit 127 -> `set -e`
# aborts install.sh mid-Phase-B, leaving $ATELIER_CONFIG_DIR partially
# populated (installStatus stuck at in_progress).
#
# The fix: right after the curl|bash native install, phase_a_claude_code()
# now (1) prepends ~/.local/bin to PATH — for THIS run only, in-process —
# if `claude` still doesn't resolve but the binary is executable there
# (mirrors the identical guard already in bootstrap.sh), and (2) hard-dies
# with a clear message if `claude` is STILL unresolvable afterwards, instead
# of silently falling through to the exit-127 crash three phases later.
#
# This test locks two layers, per the task-42 plan:
#   Group 1 (static):     phase_a_claude_code()'s function body (extracted
#     by content, not line number) contains the ~/.local/bin existence
#     check, the PATH-prepend guard, and the `has claude || die` fallback —
#     so a future refactor that drops any of the three fails loudly.
#   Group 2 (functional): sourcing install.sh (main-gated) and calling the
#     REAL phase_a_claude_code() in a sandboxed HOME + constrained PATH,
#     with the native `curl|bash` install stubbed out (no network), proves:
#       2a. when the installer lands a real ~/.local/bin/claude, `claude`
#           is UNRESOLVABLE beforehand and RESOLVABLE afterwards, in the
#           same process — the PATH-prepend guard actually ran.
#       2b. when the installer does NOT land a binary (a genuinely broken
#           install), the function dies with the documented message instead
#           of returning as if nothing happened.
#   Group 3 (meaningfulness): both the static pin and the 2a functional
#     probe are re-run against a synthetic pre-#42-fix fixture (the guard
#     block mechanically stripped out of the shipped file, content-driven,
#     not copied from git history) and must FAIL / reproduce the bug there
#     — proving the assertions actually catch #42 rather than being
#     tautologies.
#
# RED/GREEN override: set INSTALL_SH to point this test at a different
# install.sh (e.g. a pre-fix `git show origin/main:install.sh` copy) to
# reproduce #42 against the real base revision:
#   INSTALL_SH=/tmp/base-install.sh bash hooks/tests/install-native-path-guard.test.sh
#
# Hermetic: NO network. The native `curl -fsSL https://claude.ai/install.sh
# | bash` step is stubbed (fake `curl` on a constrained PATH that never
# reaches the real one); HOME points at a throwaway mktemp dir; no writes
# outside the temp dir.
# Requires: bash, awk (install.sh Phase-A deps / POSIX).
#
# Run:  hooks/tests/install-native-path-guard.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${INSTALL_SH:-$REPO_ROOT/install.sh}"

if [ ! -f "$INSTALL" ]; then
  echo "install-native-path-guard: INSTALL_SH points at a missing file: $INSTALL" >&2
  exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "install.sh native installer PATH guard (#42): $INSTALL"

# ---------------------------------------------------------------------------
# Fixture: stub `curl`. Logs every invocation ("ARGS=...") and always exits
# 0 with empty stdout — piped into `bash` that's an empty (no-op) program,
# exactly as the shipped `curl -fsSL ... | bash` line requires, with zero
# network access and zero real installation.
# ---------------------------------------------------------------------------
cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
{ printf 'ARGS=%s\n' "$*"; } >> "${STUB_CURL_LOG:-/dev/null}"
exit 0
STUB
chmod +x "$STUB_BIN/curl"

# new_home <name> — a fresh throwaway $HOME, printed on stdout.
new_home() {
  local h="$TMP/home-$1"
  mkdir -p "$h"
  printf '%s' "$h"
}

# land_fake_claude <home-dir> — pre-populates ~/.local/bin/claude as an
# executable stub, simulating a SUCCESSFUL native install (this is what the
# real curl|bash would have left behind; the stub curl above intentionally
# does nothing, so tests that need a "landed binary" scenario place it here
# themselves).
land_fake_claude() {
  local h="$1"
  mkdir -p "$h/.local/bin"
  cat > "$h/.local/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo "fake claude $*"
EOF
  chmod +x "$h/.local/bin/claude"
}

# run_probe <install-file> <home-dir> <snippet> — sources <install-file>
# (main-gated: defines functions/vars only) under a sandboxed HOME and a
# PATH constrained to <stub-bin>:/usr/bin:/bin (deliberately excludes every
# directory a real `claude` might already live in on the host running this
# test), then evals <snippet>. Prints combined stdout+stderr; exits with the
# snippet's status so a `die` inside phase_a_claude_code is visible.
run_probe() {
  local install_file="$1" home_dir="$2" snippet="$3"
  HOME="$home_dir" \
  PATH="$STUB_BIN:/usr/bin:/bin" \
  NO_COLOR=1 \
  INSTALL="$install_file" \
  STUB_CURL_LOG="$home_dir/curl-calls.log" \
  SNIPPET="$snippet" \
    bash -c '
      set -uo pipefail
      # shellcheck disable=SC1090
      source "$INSTALL"
      eval "$SNIPPET"
    ' 2>&1
}

# field <probe-output> <KEY> — last "<KEY>=<value>" line's value.
field() {
  printf '%s\n' "$1" | grep -o "^$2=.*" | tail -1 | cut -d= -f2-
}

# extract_fn <name> <file> — the exact source text of function <name>()'s
# body (opening "<name>() {" line through its matching column-0 "}"),
# located by content, not a hardcoded line number.
extract_fn() {
  local name="$1" file="$2"
  awk -v want="${name}() {" '
    $0 == want { f = 1 }
    f { print }
    f && $0 == "}" { exit }
  ' "$file"
}

# ---------------------------------------------------------------------------
# Group 1: STATIC PIN
# ---------------------------------------------------------------------------
echo "Group 1: static pin on phase_a_claude_code()"

FN_BODY="$(extract_fn phase_a_claude_code "$INSTALL")"

[ -n "$FN_BODY" ] \
  && pass "phase_a_claude_code() extracted from $INSTALL" \
  || fail "could not locate phase_a_claude_code() in $INSTALL"

printf '%s\n' "$FN_BODY" | grep -qF 'curl -fsSL https://claude.ai/install.sh | bash' \
  && pass "extraction canary: the native curl|bash install line is inside the extracted body" \
  || fail "extraction canary failed — phase_a_claude_code() no longer contains the native install line (extraction may be mis-scoped)"

printf '%s\n' "$FN_BODY" | grep -qF '$HOME/.local/bin/claude' \
  && pass "guard checks for the landed binary at \$HOME/.local/bin/claude" \
  || fail "no \$HOME/.local/bin/claude existence check in phase_a_claude_code()"

printf '%s\n' "$FN_BODY" | grep -qF 'PATH="${HOME}/.local/bin:${PATH}"' \
  && pass "guard prepends \${HOME}/.local/bin onto PATH for the rest of this run" \
  || fail "no PATH=\"\${HOME}/.local/bin:\${PATH}\" prepend in phase_a_claude_code()"

printf '%s\n' "$FN_BODY" | grep -qF 'has claude || die' \
  && pass "fallback: \`has claude || die\` — a still-unresolvable claude is fatal, not silent" \
  || fail "no \`has claude || die\` fallback in phase_a_claude_code() — a broken install could fall through silently (the exact #42 bug)"

printf '%s\n' "$FN_BODY" | grep -qF 'claude CLI not on PATH after install' \
  && pass "die message names the exact failure (\"claude CLI not on PATH after install\")" \
  || fail "die message text missing/changed — assert text drifted from the shipped message"

# ---------------------------------------------------------------------------
# Group 2: FUNCTIONAL PROBE
# ---------------------------------------------------------------------------
echo "Group 2: functional probe (real phase_a_claude_code(), stubbed curl, no network)"

# --- 2a: installer lands a binary -> guard patches PATH for this run ---
HOME_A="$(new_home guard-success)"
land_fake_claude "$HOME_A"

pre_out="$(run_probe "$INSTALL" "$HOME_A" 'printf "PRE_CLAUDE=%s\n" "$(command -v claude || echo NONE)"')"
pre_claude="$(field "$pre_out" PRE_CLAUDE)"
[ "$pre_claude" = "NONE" ] \
  && pass "sanity: claude is genuinely UNRESOLVABLE before the guard runs (constrained PATH)" \
  || fail "sanity failed: claude already resolved to '$pre_claude' before the guard even ran — scenario is not isolating the bug"

out_a="$(run_probe "$INSTALL" "$HOME_A" 'phase_a_claude_code
printf "AFTER_CLAUDE=%s\n" "$(command -v claude || echo NONE)"')"
rc_a=$?
after_claude_a="$(field "$out_a" AFTER_CLAUDE)"

[ "$rc_a" -eq 0 ] \
  && pass "shipped phase_a_claude_code() runs clean when the installer lands a binary (exit 0)" \
  || fail "shipped phase_a_claude_code() exited $rc_a (out: $out_a)"

grep -qF 'ARGS=-fsSL https://claude.ai/install.sh' "$HOME_A/curl-calls.log" 2>/dev/null \
  && pass "the native curl|bash install step actually ran (stubbed, no network)" \
  || fail "stub curl was never invoked with the native installer URL (log: $(cat "$HOME_A/curl-calls.log" 2>/dev/null | tr '\n' '|'))"

[ "$after_claude_a" = "$HOME_A/.local/bin/claude" ] \
  && pass "THE FIX: claude resolves to \$HOME/.local/bin/claude in-process, right after the guard runs" \
  || fail "claude did not resolve after phase_a_claude_code(): expected '$HOME_A/.local/bin/claude', got '$after_claude_a' (out: $out_a)"

# --- 2b: installer does NOT land a binary -> guard dies, does not fall through ---
HOME_B="$(new_home guard-failure)"
# deliberately no ~/.local/bin/claude — simulates a genuinely broken install.

out_b="$(run_probe "$INSTALL" "$HOME_B" 'phase_a_claude_code
printf "UNREACHABLE\n"')"
rc_b=$?

[ "$rc_b" -ne 0 ] \
  && pass "shipped phase_a_claude_code() dies (non-zero exit) when no binary landed" \
  || fail "phase_a_claude_code() exited 0 with no binary landed — should have died (out: $out_b)"

printf '%s' "$out_b" | grep -qF 'UNREACHABLE' \
  && fail "execution continued past the failed guard (die did not abort the function)" \
  || pass "die genuinely aborts phase_a_claude_code() — nothing runs after it"

printf '%s' "$out_b" | grep -qF 'claude CLI not on PATH after install — open a new terminal and re-run install.sh' \
  && pass "die reports the documented remediation (\"open a new terminal and re-run install.sh\")" \
  || fail "die message missing/changed (out: $out_b)"

# ---------------------------------------------------------------------------
# Group 3: MEANINGFULNESS — same checks against a synthetic pre-#42-fix
# fixture must fail / reproduce the bug, proving Groups 1-2 are not
# tautological.
# ---------------------------------------------------------------------------
echo "Group 3: meaningfulness (synthetic pre-#42-fix fixture)"

# strip_path_guard <src> <dest> — mechanically removes the #42 guard block
# (the comment header through the `has claude || die` line, inclusive),
# reproducing exactly what phase_a_claude_code() looked like before #42:
# curl|bash, then nothing else before the closing brace. Content-driven
# (plain substring search via index()), not copied from git history — keeps
# this hermetic against a shallow/single-branch checkout in CI.
strip_path_guard() {
  awk '
    index($0, "# The native installer targets ~/.local/bin, which may not be on PATH yet") > 0 { skip = 1 }
    skip {
      if (index($0, "has claude || die \"claude CLI not on PATH after install") > 0) { skip = 0 }
      next
    }
    { print }
  ' "$1" > "$2"
}

BUGGY="$TMP/buggy-install.sh"
strip_path_guard "$INSTALL" "$BUGGY"

bash -n "$BUGGY" \
  && pass "fixture sanity: the synthetic pre-fix install.sh is still syntactically valid bash" \
  || fail "fixture sanity: buggy install.sh failed bash -n — the splice broke the file"

BUGGY_FN_BODY="$(extract_fn phase_a_claude_code "$BUGGY")"
printf '%s\n' "$BUGGY_FN_BODY" | grep -qF 'has claude || die' \
  && fail "meaningfulness: the stripped fixture still contains the guard — strip_path_guard did not remove it" \
  || pass "meaningfulness: the stripped fixture genuinely lacks the guard (strip worked)"

printf '%s\n' "$BUGGY_FN_BODY" | grep -qF 'PATH="${HOME}/.local/bin:${PATH}"' \
  && fail "meaningfulness: the static pin PASSED against the pre-fix fixture — it would not have caught #42" \
  || pass "meaningfulness: the static pin correctly FAILS against the pre-fix fixture (PATH-prepend line absent)"

HOME_M="$(new_home meaningfulness)"
land_fake_claude "$HOME_M"

out_m="$(run_probe "$BUGGY" "$HOME_M" 'phase_a_claude_code
printf "AFTER_CLAUDE=%s\n" "$(command -v claude || echo NONE)"')"
rc_m=$?
after_claude_m="$(field "$out_m" AFTER_CLAUDE)"

[ "$rc_m" -eq 0 ] \
  && pass "meaningfulness: the pre-fix fixture returns cleanly (exit 0) — the bug is silence, not a crash here" \
  || fail "meaningfulness setup broken: pre-fix fixture exited $rc_m unexpectedly (out: $out_m)"

[ "$after_claude_m" = "NONE" ] \
  && pass "meaningfulness: the pre-#42-fix fixture REPRODUCES the bug — claude is still unresolvable after \"install\", exactly the state that later hits exit 127 in phase_b_claude_login" \
  || fail "meaningfulness: pre-fix fixture did NOT reproduce the bug (claude resolved to '$after_claude_m') — the functional probe may be tautological"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "install-native-path-guard (#42): all assertions passed."
  exit 0
else
  echo "install-native-path-guard (#42): $fails assertion(s) failed."
  exit 1
fi
