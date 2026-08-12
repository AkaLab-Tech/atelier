#!/usr/bin/env bash
#
# Regression test for #40 — the gh credential helper must be registered INSIDE
# $ATELIER_CONFIG_DIR/git-identity.conf, not only in the operator's ~/.gitconfig.
#
# The bug: phase_b_atelier_author_login() ran `gh auth setup-git` with
# GH_CONFIG_DIR set but WITHOUT GIT_CONFIG_GLOBAL, so the
# `[credential "https://github.com"] helper = !gh auth git-credential` section
# landed only in the operator's personal ~/.gitconfig. Inside an atelier
# session the shellrc `task()` / `atelier()` functions export
# GIT_CONFIG_GLOBAL=$ATELIER_CONFIG_DIR/git-identity.conf, which REPLACES the
# global gitconfig rather than layering on top of it — and that file only ever
# carried a `[user]` section. Result: `git push` inside a session never saw the
# atelier-author token.
#
# The fix: phase_b_register_author_credential_helper() re-runs `gh auth
# setup-git` with BOTH GIT_CONFIG_GLOBAL=<identity file> and
# GH_CONFIG_DIR=<author config dir>, and phase_b() calls it LAST — after
# phase_b_capture_atelier_git_identity(), whose full-file `cat >` rewrite would
# otherwise clobber the freshly written [credential] section. A failing
# `gh auth setup-git` warns with a manual fix and returns; it never aborts the
# install.
#
# This test locks four things:
#   Group 1 (functional): the resulting git-identity.conf carries the gh helper
#     AND keeps [user] name/email — a file with only [credential] would break
#     every atelier commit.
#   Group 2 (order): pinned statically (call line numbers inside phase_b()) and
#     functionally (the reversed order demonstrably wipes the section, the
#     shipped order preserves it).
#   Group 3 (idempotence): a second registration leaves the file byte-identical
#     — no duplicated [credential] sections.
#   Group 4 (fail-safe): a failing `gh auth setup-git` warns and RETURNS; the
#     install continues. Asserted with a post-call sentinel so swapping the
#     `return` for a `die` would genuinely fail this test.
#
# Hermetic: sources install.sh (main-gated) inside a throwaway HOME +
# ATELIER_CONFIG_DIR and drives the phase functions directly, with a stub `gh`
# on PATH that mirrors what the real `gh auth setup-git` writes (a --replace-all
# reset plus an --add of the dynamic helper) via real `git config`. No network,
# no real credentials, no real gh config dir, no writes outside the temp dir.
# Requires: git (install.sh Phase-A dep).
#
# Run:  hooks/tests/install-credential-helper-git-identity.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
STUB_BIN="$TMP/stub-bin"
mkdir -p "$HOME_DIR" "$STUB_BIN"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "gh credential helper registered in git-identity.conf (#40)"

# Expected values the stub `gh api user` reports, and therefore the exact
# [user] block phase_b_capture_atelier_git_identity() must write.
EXP_NAME="Atelier Author"
EXP_EMAIL="12345678+atelier-author@users.noreply.github.com"
# The helper line the stub writes, mirroring `gh auth setup-git`.
GH_HELPER="!$STUB_BIN/gh auth git-credential"
CRED_KEY="credential.https://github.com.helper"

# ---------------------------------------------------------------------------
# Fixture: stub `gh`.
#
# `auth setup-git` writes the credential section into whatever gitconfig
# $GIT_CONFIG_GLOBAL points at (git honours it for `--global`), exactly as the
# real gh does: --replace-all with an empty value to reset any inherited
# helper, then --add of the dynamic `gh auth git-credential` line. Every
# invocation appends ARGS + the two env vars under test to a log so the test
# can assert the function passed BOTH GIT_CONFIG_GLOBAL and GH_CONFIG_DIR.
# ---------------------------------------------------------------------------
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
{
  printf 'ARGS=%s\n' "$*"
  printf '  GIT_CONFIG_GLOBAL=%s\n' "${GIT_CONFIG_GLOBAL:-<unset>}"
  printf '  GH_CONFIG_DIR=%s\n' "${GH_CONFIG_DIR:-<unset>}"
} >> "${STUB_GH_LOG:-/dev/null}"

case "$*" in
  "auth setup-git")
    if [ "${STUB_GH_SETUP_GIT_FAIL:-0}" = "1" ]; then
      printf 'failed to set up git credential helper: no authenticated hosts\n' >&2
      exit 1
    fi
    git config --global --replace-all "credential.https://github.com.helper" "" || exit 1
    git config --global --add "credential.https://github.com.helper" \
      "!${STUB_GH_SELF} auth git-credential" || exit 1
    ;;
  "api user --jq .login") printf 'atelier-author\n' ;;
  "api user --jq .id")    printf '12345678\n' ;;
  *"name // empty"*)      printf 'Atelier Author\n' ;;
  *"email // empty"*)     printf '12345678+atelier-author@users.noreply.github.com\n' ;;
  *)
    printf 'stub gh: unhandled invocation: %s\n' "$*" >&2
    exit 127 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"

# new_cfg <name> — a fresh $ATELIER_CONFIG_DIR sandbox, printed on stdout.
new_cfg() {
  local cfg="$TMP/cfg-$1"
  mkdir -p "$cfg/gh/author"
  printf '%s' "$cfg"
}

# run_fns <cfg-dir> <snippet> — source install.sh under the sandbox env and run
# <snippet> against the real phase functions. Prints combined output; exits
# with the subshell's status so a `die` inside a phase function is visible.
run_fns() {
  local cfg="$1" snippet="$2"
  HOME="$HOME_DIR" \
  ATELIER_CONFIG_DIR="$cfg" \
  NO_COLOR=1 \
  INSTALL="$INSTALL" \
  PATH="$STUB_BIN:$PATH" \
  STUB_GH_LOG="$cfg/gh-calls.log" \
  STUB_GH_SELF="$STUB_BIN/gh" \
  STUB_GH_SETUP_GIT_FAIL="${STUB_GH_SETUP_GIT_FAIL:-0}" \
  SNIPPET="$snippet" \
    bash -c '
      set -euo pipefail
      # shellcheck disable=SC1090
      source "$INSTALL"
      eval "$SNIPPET"
    ' 2>&1
}

# helpers_in <identity-file> — the credential helper values git actually
# resolves out of the file, one per line.
helpers_in() {
  GIT_CONFIG_GLOBAL="$1" git config --get-all "$CRED_KEY" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Group 1: functional — the resulting git-identity.conf
# ---------------------------------------------------------------------------
CFG1="$(new_cfg shipped)"
ID1="$CFG1/git-identity.conf"
out1="$(run_fns "$CFG1" 'phase_b_capture_atelier_git_identity
phase_b_register_author_credential_helper')"
run1_rc=$?

[ "$run1_rc" -eq 0 ] \
  && pass "shipped order runs clean (exit 0)" \
  || fail "shipped order exited $run1_rc: $out1"

[ -f "$ID1" ] \
  && pass "git-identity.conf written to \$ATELIER_CONFIG_DIR" \
  || fail "git-identity.conf missing at $ID1"

helpers1="$(helpers_in "$ID1")"
printf '%s\n' "$helpers1" | grep -qxF "$GH_HELPER" \
  && pass "credential.https://github.com.helper resolves to the gh helper" \
  || fail "gh helper absent from git-identity.conf (got: $(printf '%s' "$helpers1" | tr '\n' '|'))"

grep -qF '[credential "https://github.com"]' "$ID1" \
  && pass "[credential \"https://github.com\"] section present in the file" \
  || fail "no [credential \"https://github.com\"] section in $ID1"

# The whole point: the identity must SURVIVE alongside the credential section.
# A file carrying only [credential] would leave atelier commits unauthored.
grep -qF '[user]' "$ID1" \
  && pass "[user] section survives the credential registration" \
  || fail "[user] section lost from $ID1"

got_name="$(GIT_CONFIG_GLOBAL="$ID1" git config --get user.name 2>/dev/null)"
[ "$got_name" = "$EXP_NAME" ] \
  && pass "user.name is '$EXP_NAME' after registration" \
  || fail "user.name: expected '$EXP_NAME', got '$got_name'"

got_email="$(GIT_CONFIG_GLOBAL="$ID1" git config --get user.email 2>/dev/null)"
[ "$got_email" = "$EXP_EMAIL" ] \
  && pass "user.email is '$EXP_EMAIL' after registration" \
  || fail "user.email: expected '$EXP_EMAIL', got '$got_email'"

# Both env vars must be on the setup-git invocation — GIT_CONFIG_GLOBAL is the
# #40 fix, GH_CONFIG_DIR is what makes the helper serve the atelier-author
# token rather than the operator's personal gh login.
setup_call="$(grep -A2 '^ARGS=auth setup-git$' "$CFG1/gh-calls.log" 2>/dev/null)"
printf '%s\n' "$setup_call" | grep -qxF "  GIT_CONFIG_GLOBAL=$ID1" \
  && pass "gh auth setup-git invoked with GIT_CONFIG_GLOBAL=<identity file>" \
  || fail "setup-git ran without GIT_CONFIG_GLOBAL=$ID1 (log: $(printf '%s' "$setup_call" | tr '\n' '|'))"

printf '%s\n' "$setup_call" | grep -qxF "  GH_CONFIG_DIR=$CFG1/gh/author" \
  && pass "gh auth setup-git invoked with GH_CONFIG_DIR=<author config dir>" \
  || fail "setup-git ran without GH_CONFIG_DIR=$CFG1/gh/author (log: $(printf '%s' "$setup_call" | tr '\n' '|'))"

printf '%s' "$out1" | grep -qF 'atelier sessions will push with the atelier-author token' \
  && pass "success is reported to the operator" \
  || fail "no success line for the session-push registration (out: $out1)"

# The registration must not leak into the operator's personal gitconfig: this
# function's only target is the atelier identity file.
[ ! -e "$HOME_DIR/.gitconfig" ] \
  && pass "operator's ~/.gitconfig untouched by the identity-file registration" \
  || fail "the personal gitconfig was written: $(tr '\n' '|' < "$HOME_DIR/.gitconfig" 2>/dev/null)"

# ---------------------------------------------------------------------------
# Group 2a: order — static, pinned by line number inside phase_b()
# ---------------------------------------------------------------------------
# Both calls are matched at their exact call-site indentation, so the function
# DEFINITIONS (column 0) can never satisfy these patterns.
phase_b_start="$(grep -n '^phase_b() {$' "$INSTALL" | head -1 | cut -d: -f1)"
cap_line="$(awk '/^phase_b\(\) \{$/{f=1} f && /^  phase_b_capture_atelier_git_identity$/{print NR; exit}' "$INSTALL")"
reg_line="$(awk '/^phase_b\(\) \{$/{f=1} f && /^  phase_b_register_author_credential_helper$/{print NR; exit}' "$INSTALL")"

[ -n "$cap_line" ] \
  && pass "phase_b() calls phase_b_capture_atelier_git_identity (line $cap_line)" \
  || fail "phase_b() does not call phase_b_capture_atelier_git_identity"

[ -n "$reg_line" ] \
  && pass "phase_b() calls phase_b_register_author_credential_helper (line $reg_line)" \
  || fail "phase_b() does not call phase_b_register_author_credential_helper"

if [ -n "$cap_line" ] && [ -n "$reg_line" ] && [ "$reg_line" -gt "$cap_line" ]; then
  pass "registration ($reg_line) runs AFTER identity capture ($cap_line) in phase_b()"
else
  fail "order broken: capture at '${cap_line:-none}', registration at '${reg_line:-none}' (registration must come later)"
fi

[ -n "$phase_b_start" ] && [ -n "$reg_line" ] && [ "$reg_line" -gt "$phase_b_start" ] \
  && pass "the registration call lives inside phase_b()'s body" \
  || fail "registration call not found inside phase_b() (phase_b at '${phase_b_start:-none}')"

# It must also be the LAST phase_b_* step: anything appended after it would be
# free to rewrite the identity file and re-introduce the bug.
last_step="$(awk '/^phase_b\(\) \{$/{f=1} f && /^\}$/{exit} f && /^  phase_b_[a-z_]+$/{s=$1} END{print s}' "$INSTALL")"
[ "$last_step" = "phase_b_register_author_credential_helper" ] \
  && pass "registration is the last phase_b_* step in phase_b()" \
  || fail "last phase_b_* step is '$last_step', expected phase_b_register_author_credential_helper"

# ---------------------------------------------------------------------------
# Group 2b: order — functional. Reversing the two calls must demonstrably
# destroy the credential section, which is what makes the static pin above a
# real guarantee rather than a comment.
# ---------------------------------------------------------------------------
CFG2="$(new_cfg reversed)"
ID2="$CFG2/git-identity.conf"
out2="$(run_fns "$CFG2" 'phase_b_register_author_credential_helper
phase_b_capture_atelier_git_identity')"
rev_rc=$?

[ "$rev_rc" -eq 0 ] \
  && pass "reversed order also runs clean (isolating ordering as the only variable)" \
  || fail "reversed order exited $rev_rc: $out2"

helpers2="$(helpers_in "$ID2")"
printf '%s\n' "$helpers2" | grep -qxF "$GH_HELPER" \
  && fail "reversed order kept the gh helper — the clobber this test guards is gone" \
  || pass "reversed order WIPES the credential section (capture's cat > rewrite clobbers it)"

grep -qF '[credential' "$ID2" \
  && fail "reversed order left a [credential] section in $ID2" \
  || pass "reversed order leaves no [credential] section at all"

# ...and the wipe is real, not an artifact of the capture never running.
[ "$(GIT_CONFIG_GLOBAL="$ID2" git config --get user.name 2>/dev/null)" = "$EXP_NAME" ] \
  && pass "reversed order still wrote [user] (proves the capture ran and overwrote)" \
  || fail "reversed-order file lacks the expected [user] block — scenario is not isolating order"

# Shipped order, same fixtures, opposite outcome.
printf '%s\n' "$helpers1" | grep -qxF "$GH_HELPER" \
  && pass "shipped order SURVIVES: helper present where reversed order lost it" \
  || fail "shipped order lost the helper too — ordering guarantee is not held"

# ---------------------------------------------------------------------------
# Group 3: idempotence — re-registration is byte-stable
# ---------------------------------------------------------------------------
cp "$ID1" "$TMP/snapshot-run1"
out3="$(run_fns "$CFG1" 'phase_b_register_author_credential_helper')"
idem_rc=$?
cp "$ID1" "$TMP/snapshot-run2"

[ "$idem_rc" -eq 0 ] \
  && pass "second registration exits 0" \
  || fail "second registration exited $idem_rc: $out3"

cmp -s "$TMP/snapshot-run1" "$TMP/snapshot-run2" \
  && pass "git-identity.conf is BYTE-IDENTICAL after a repeat registration" \
  || fail "repeat registration churned the file: $(diff "$TMP/snapshot-run1" "$TMP/snapshot-run2" | tr '\n' '|')"

cred_sections="$(grep -c '^\[credential ' "$ID1")"
[ "$cred_sections" -eq 1 ] \
  && pass "exactly 1 [credential] section after two registrations" \
  || fail "expected 1 [credential] section, found $cred_sections"

helper_hits="$(helpers_in "$ID1" | grep -cxF "$GH_HELPER")"
[ "$helper_hits" -eq 1 ] \
  && pass "exactly 1 gh helper value (no duplicate helper lines)" \
  || fail "expected 1 gh helper value, found $helper_hits"

[ "$(GIT_CONFIG_GLOBAL="$ID1" git config --get user.email 2>/dev/null)" = "$EXP_EMAIL" ] \
  && pass "[user] still intact after the repeat registration" \
  || fail "repeat registration disturbed the [user] block"

# ---------------------------------------------------------------------------
# Group 4: fail-safe — a failing `gh auth setup-git` warns and RETURNS.
#
# The sentinel pattern below is deliberate: `set +e; fn; rc=$?; set -e` plus a
# printf AFTER the call. A `die`/`exit 1` in place of the `return` kills the
# subshell before the sentinel prints and surfaces as a non-zero status, so
# both assertions below flip to FAIL. An `if fn; then` wrapper would swallow
# exactly that difference and prove nothing.
# ---------------------------------------------------------------------------
CFG4="$(new_cfg failsafe)"
ID4="$CFG4/git-identity.conf"

# Seed the identity file with a successful capture, then break setup-git.
run_fns "$CFG4" 'phase_b_capture_atelier_git_identity' >/dev/null 2>&1

STUB_GH_SETUP_GIT_FAIL=1
out4="$(run_fns "$CFG4" 'set +e
phase_b_register_author_credential_helper
rc=$?
set -e
printf "SENTINEL_AFTER_CALL rc=%s\n" "$rc"')"
fail_rc=$?
STUB_GH_SETUP_GIT_FAIL=0

[ "$fail_rc" -eq 0 ] \
  && pass "failing gh auth setup-git does not abort the caller (subshell exit 0)" \
  || fail "install aborted on a failing setup-git (exit $fail_rc) — the function must return, not die"

printf '%s' "$out4" | grep -qF 'SENTINEL_AFTER_CALL rc=0' \
  && pass "execution continues past the call with rc=0 (return, not die/exit)" \
  || fail "sentinel after the call did not run with rc=0 (out: $out4)"

printf '%s' "$out4" | grep -qF "could not register the gh credential helper in $ID4" \
  && pass "failure is reported as a warning naming the identity file" \
  || fail "no warning about the failed registration (out: $out4)"

printf '%s' "$out4" | grep -qF 'GH_CONFIG_DIR' \
  && pass "the warning includes the by-hand fix command with GH_CONFIG_DIR" \
  || fail "warning lacks the manual gh auth setup-git recipe (out: $out4)"

printf '%s' "$out4" | grep -qF 'atelier sessions will push with the atelier-author token' \
  && fail "failed registration still claimed success" \
  || pass "no success claim on the failure path"

# A failed registration must leave the previously captured identity usable.
[ "$(GIT_CONFIG_GLOBAL="$ID4" git config --get user.name 2>/dev/null)" = "$EXP_NAME" ] \
  && pass "failed registration leaves the captured [user] identity intact" \
  || fail "failed registration corrupted $ID4"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "install-credential-helper-git-identity (#40): all assertions passed."
  exit 0
else
  echo "install-credential-helper-git-identity (#40): $fails assertion(s) failed."
  exit 1
fi
