#!/usr/bin/env bash
#
# Regression test for audit#1 — the gh credential helper must live INSIDE
# $ATELIER_CONFIG_DIR/git-identity.conf, not only in the operator's personal
# ~/.gitconfig.
#
# The bug: install.sh registered `gh auth setup-git` without GIT_CONFIG_GLOBAL,
# so the `[credential "https://github.com"] helper = !gh auth git-credential`
# section landed in ~/.gitconfig only. But the `task()` / `atelier()` shell
# functions export GIT_CONFIG_GLOBAL=$ATELIER_CONFIG_DIR/git-identity.conf, and
# GIT_CONFIG_GLOBAL REPLACES the global gitconfig wholesale — that file carried
# just a [user] section, so inside an atelier session `git push` had no gh
# credential helper at all (macOS silently fell through to the system
# osxkeychain = the operator's PERSONAL identity; Linux prompts or fails).
#
# The fix: phase_b_register_author_credential_helper() re-runs
#   GIT_CONFIG_GLOBAL=<identity_file> GH_CONFIG_DIR=<cfg>/gh/author gh auth setup-git
# and is called LAST in phase_b(), after phase_b_capture_atelier_git_identity —
# whose full-file `cat >` rewrite would otherwise clobber the credential
# section. On gh failure it warns + prints a manual fix and returns (no abort).
#
# What this pins:
#   1. the helper resolves from the identity file (value carries `gh` +
#      `auth git-credential`; the absolute gh path is host-specific and is
#      deliberately NOT hardcoded here);
#   2. the [user] identity survives alongside it;
#   3. idempotency — N runs leave exactly one [user] section, one credential
#      section per host, one real helper line, and a byte-identical file;
#   4. ordering — the capture rewrite clobbers the section, so register must
#      run after it; phase_b()'s call order is asserted statically;
#   5. the degraded path returns 0 with a warning + copy-pasteable fix;
#   6. an early-bailing identity capture is not made worse by the register step.
#
# Hermetic: sources install.sh (main-gated) with HOME + $ATELIER_CONFIG_DIR
# inside a throwaway tree, and puts a fake `gh` first on PATH that reproduces
# what real `gh auth setup-git` does (`git config --replace-all <key> ""` then
# `git config --add <key> "!<gh> auth git-credential"` for github.com and
# gist.github.com, honouring GIT_CONFIG_GLOBAL) plus the `gh api user` reads
# phase_b_capture_atelier_git_identity makes. No authenticated gh, no network,
# no writes outside the scratch tree — the fake refuses to run when
# GIT_CONFIG_GLOBAL is unset or points outside the sandbox, so a regression can
# never touch the real ~/.gitconfig. Requires: git, bash, coreutils.
#
# Run:  hooks/tests/install-credential-helper-git-identity.test.sh
#       INSTALL=/path/to/other/install.sh hooks/tests/install-...test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="${INSTALL:-$REPO_ROOT/install.sh}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
STUB_BIN="$TMP/stub-bin"
GH_LOG="$TMP/gh-calls.log"
mkdir -p "$HOME_DIR" "$STUB_BIN"
: > "$GH_LOG"

FAKE_LOGIN="atelier-author-test"
FAKE_ID="4242"
EXPECTED_EMAIL="${FAKE_ID}+${FAKE_LOGIN}@users.noreply.github.com"

# Failure injection for the fake gh (set/reset around a drive call rather than
# prefixed to it — bash's persistence rules for `VAR=x func` vary by version).
GH_API_USER_FAIL=""
GH_SETUP_GIT_FAIL=""

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "gh credential helper registered in git-identity.conf (audit#1)"

# ---------------------------------------------------------------------------
# Fixture: fake `gh`.
#
# `auth setup-git` mirrors the real thing byte for byte (empty helper line to
# sever any inherited chain, then the absolute-path helper, per host) but
# hard-refuses to write anywhere outside the sandbox. `api user` answers the
# four --jq reads phase_b_capture_atelier_git_identity performs; .name/.email
# come back empty, the common fresh-service-account case, so install.sh's
# noreply defaults are exercised too.
# ---------------------------------------------------------------------------
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

self="$0"
case "$self" in /*) ;; *) self="$PWD/$self" ;; esac

printf '%s GIT_CONFIG_GLOBAL=%s GH_CONFIG_DIR=%s\n' \
  "$*" "${GIT_CONFIG_GLOBAL:-<unset>}" "${GH_CONFIG_DIR:-<unset>}" >> "$FAKE_GH_LOG"

sub="${1:-}"; shift 2>/dev/null || true

case "$sub" in
  api)
    [ "${1:-}" = "user" ] || { echo "fake gh: unsupported api endpoint: ${1:-}" >&2; exit 1; }
    if [ -n "${GH_API_USER_FAIL:-}" ]; then
      echo "fake gh: no authenticated account for this GH_CONFIG_DIR" >&2
      exit 1
    fi
    for arg in "$@"; do
      case "$arg" in
        *.login*) printf '%s\n' "$FAKE_LOGIN"; exit 0 ;;
        *.id*)    printf '%s\n' "$FAKE_ID";    exit 0 ;;
        *.name*)  printf '\n';                 exit 0 ;;  # no public name
        *.email*) printf '\n';                 exit 0 ;;  # no public email
      esac
    done
    echo "fake gh: unsupported jq expression: $*" >&2
    exit 1
    ;;
  auth)
    [ "${1:-}" = "setup-git" ] || { echo "fake gh: unsupported auth subcommand: ${1:-}" >&2; exit 1; }
    if [ -n "${GH_SETUP_GIT_FAIL:-}" ]; then
      echo "fake gh: failed to set up git credential helper: no authenticated account" >&2
      exit 1
    fi
    # Hermeticity guard: `git config --global` without GIT_CONFIG_GLOBAL would
    # rewrite the real operator ~/.gitconfig. That is exactly the bug under
    # test, so refuse loudly instead of doing it.
    if [ -z "${GIT_CONFIG_GLOBAL:-}" ]; then
      echo "fake gh: refusing 'git config --global' with GIT_CONFIG_GLOBAL unset" >&2
      exit 1
    fi
    case "$GIT_CONFIG_GLOBAL" in
      "${TEST_SANDBOX:?}"/*) ;;
      *) echo "fake gh: refusing to write outside the sandbox: $GIT_CONFIG_GLOBAL" >&2; exit 1 ;;
    esac
    for host in github.com gist.github.com; do
      git config --global --replace-all "credential.https://$host.helper" "" || exit 1
      git config --global --add "credential.https://$host.helper" "!$self auth git-credential" || exit 1
    done
    exit 0
    ;;
esac

echo "fake gh: unsupported command: $sub $*" >&2
exit 1
STUB
chmod +x "$STUB_BIN/gh"

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

# new_cfg — a fresh throwaway $ATELIER_CONFIG_DIR, so each group starts from a
# clean slate. Sets $CFG_DIR (not a command substitution: the counter must
# survive in this shell).
cfg_seq=0
CFG_DIR=""
new_cfg() {
  cfg_seq=$((cfg_seq + 1))
  CFG_DIR="$TMP/config-$cfg_seq"
  mkdir -p "$CFG_DIR/gh/author" "$CFG_DIR/gh/reviewer"
}

# drive <config-dir> <fn>... — source install.sh (main-gated) in the scratch
# env and run the named phase functions in order. Prints their combined
# stdout+stderr; a function install.sh does not define is reported as
# MISSING_FN:<name>, a non-zero return as FN_RC:<name>=<rc>.
drive() {
  local cfg="$1"; shift
  # `env -u`: an atelier session itself exports GIT_CONFIG_GLOBAL/GH_CONFIG_DIR
  # (that is the whole point of the bug). Strip them so the driver can never
  # inherit a pointer to the operator's real config — install.sh must set them
  # itself on the calls that need them, which is exactly what is under test.
  env -u GIT_CONFIG_GLOBAL -u GH_CONFIG_DIR \
    HOME="$HOME_DIR" \
    ATELIER_CONFIG_DIR="$cfg" \
    PATH="$STUB_BIN:$PATH" \
    TEST_SANDBOX="$TMP" \
    FAKE_GH_LOG="$GH_LOG" \
    FAKE_LOGIN="$FAKE_LOGIN" \
    FAKE_ID="$FAKE_ID" \
    GH_API_USER_FAIL="$GH_API_USER_FAIL" \
    GH_SETUP_GIT_FAIL="$GH_SETUP_GIT_FAIL" \
    GIT_CONFIG_NOSYSTEM=1 \
    NO_COLOR=1 \
    INSTALL="$INSTALL" \
    bash -c '
    set -uo pipefail
    # shellcheck disable=SC1090
    source "$INSTALL"   # note: install.sh sets IFS=$"\n\t", hence "$@" below
    for fn in "$@"; do
      if ! declare -F "$fn" >/dev/null 2>&1; then
        printf "MISSING_FN:%s\n" "$fn"
        continue
      fi
      "$fn"; rc=$?
      [ "$rc" -eq 0 ] || printf "FN_RC:%s=%s\n" "$fn" "$rc"
    done
    ' phase-driver "$@" 2>&1
}

# idcfg <identity-file> <git-config-args>... — read the file the way an
# atelier session does: GIT_CONFIG_GLOBAL pointing at it, from a non-repo cwd
# and with the system gitconfig out of the picture, so nothing but that file
# can answer.
idcfg() {
  local f="$1"; shift
  ( cd "$TMP" && HOME="$HOME_DIR" GIT_CONFIG_GLOBAL="$f" GIT_CONFIG_NOSYSTEM=1 \
      git config "$@" )
}

# ---------------------------------------------------------------------------
# Group 1: happy path — capture then register (phase_b's order)
# ---------------------------------------------------------------------------
new_cfg; CFG1="$CFG_DIR"
ID1="$CFG1/git-identity.conf"
out1="$(drive "$CFG1" phase_b_capture_atelier_git_identity phase_b_register_author_credential_helper)"

printf '%s' "$out1" | grep -q 'MISSING_FN:phase_b_register_author_credential_helper' \
  && fail "install.sh defines no phase_b_register_author_credential_helper (pre-fix install.sh)" \
  || pass "install.sh defines phase_b_register_author_credential_helper"
printf '%s' "$out1" | grep -q 'FN_RC:' \
  && fail "a phase function returned non-zero: $(printf '%s' "$out1" | grep 'FN_RC:')" \
  || pass "both phase functions returned 0"

[ -f "$ID1" ] \
  && pass "git-identity.conf written" \
  || fail "git-identity.conf missing at $ID1"

helpers1="$(idcfg "$ID1" --get-all credential.https://github.com.helper)"; rc=$?
[ "$rc" -eq 0 ] \
  && pass "credential.https://github.com.helper resolves from git-identity.conf (exit 0)" \
  || fail "no github.com credential helper in git-identity.conf (git config exit $rc) — audit#1 regression"

if printf '%s\n' "$helpers1" | grep -q 'auth git-credential'; then
  helper_line="$(printf '%s\n' "$helpers1" | grep 'auth git-credential' | head -1)"
  case "$helper_line" in
    *gh*auth\ git-credential*) pass "helper is a gh credential helper: $helper_line" ;;
    *) fail "helper does not look like gh: $helper_line" ;;
  esac
else
  fail "no '... auth git-credential' helper value (got: $(printf '%s' "$helpers1" | tr '\n' '|'))"
fi

# The empty leading helper (severing any inherited chain) is part of what gh
# writes; keep it pinned so a hand-rolled replacement cannot drop it.
[ "$(printf '%s\n' "$helpers1" | head -1)" = "" ] \
  && pass "leading empty helper preserved (severs inherited helper chain)" \
  || fail "expected an empty first helper value, got: $(printf '%s\n' "$helpers1" | head -1)"

idcfg "$ID1" --get-all credential.https://gist.github.com.helper >/dev/null 2>&1 \
  && pass "gist.github.com helper registered too (gh writes both hosts)" \
  || fail "gist.github.com credential helper missing"

# The [user] section must coexist with the credential section.
[ "$(idcfg "$ID1" --get user.name)" = "$FAKE_LOGIN" ] \
  && pass "user.name survives: $FAKE_LOGIN" \
  || fail "user.name: expected '$FAKE_LOGIN', got '$(idcfg "$ID1" --get user.name)'"
[ "$(idcfg "$ID1" --get user.email)" = "$EXPECTED_EMAIL" ] \
  && pass "user.email survives: $EXPECTED_EMAIL" \
  || fail "user.email: expected '$EXPECTED_EMAIL', got '$(idcfg "$ID1" --get user.email)'"

# The registration must be scoped to BOTH the identity file and the author gh
# config dir — the missing GIT_CONFIG_GLOBAL is the whole bug.
grep -Fxq "auth setup-git GIT_CONFIG_GLOBAL=$ID1 GH_CONFIG_DIR=$CFG1/gh/author" "$GH_LOG" \
  && pass "gh auth setup-git invoked with GIT_CONFIG_GLOBAL=<identity file> and the author GH_CONFIG_DIR" \
  || fail "no setup-git call scoped to $ID1 + $CFG1/gh/author (log: $(tr '\n' '|' < "$GH_LOG"))"

# ---------------------------------------------------------------------------
# Group 2: idempotency — three capture+register cycles
# ---------------------------------------------------------------------------
new_cfg; CFG2="$CFG_DIR"
ID2="$CFG2/git-identity.conf"
for run in 1 2 3; do
  out2="$(drive "$CFG2" phase_b_capture_atelier_git_identity phase_b_register_author_credential_helper)"
  case "$run" in
    2) cp "$ID2" "$TMP/snapshot-run2" 2>/dev/null || : ;;
    3) cp "$ID2" "$TMP/snapshot-run3" 2>/dev/null || : ;;
  esac
done
printf '%s' "$out2" | grep -q 'FN_RC:' \
  && fail "re-run returned non-zero: $(printf '%s' "$out2" | grep 'FN_RC:')" \
  || pass "re-runs return 0"

user_sections="$(grep -c '^\[user\]' "$ID2" 2>/dev/null)" || user_sections="${user_sections:-0}"
[ "$user_sections" = "1" ] \
  && pass "exactly one [user] section after 3 runs" \
  || fail "expected 1 [user] section after 3 runs, found ${user_sections:-0}"

cred_sections="$(grep -c '^\[credential "https://github.com"\]' "$ID2" 2>/dev/null)" || cred_sections="${cred_sections:-0}"
[ "$cred_sections" = "1" ] \
  && pass "exactly one [credential \"https://github.com\"] section after 3 runs" \
  || fail "expected 1 github.com credential section after 3 runs, found ${cred_sections:-0}"

real_helpers="$(idcfg "$ID2" --get-all credential.https://github.com.helper 2>/dev/null | grep -c 'auth git-credential')"
[ "$real_helpers" = "1" ] \
  && pass "exactly one gh helper line for github.com (no duplicate accumulation)" \
  || fail "expected 1 gh helper line after 3 runs, found $real_helpers"

if [ -f "$TMP/snapshot-run2" ] && [ -f "$TMP/snapshot-run3" ] \
   && cmp -s "$TMP/snapshot-run2" "$TMP/snapshot-run3"; then
  pass "git-identity.conf is byte-identical across consecutive runs"
else
  fail "git-identity.conf changed between run 2 and run 3 (not idempotent)"
fi

# ---------------------------------------------------------------------------
# Group 3: ordering — register MUST run after the capture rewrite
# ---------------------------------------------------------------------------
# 3a (functional): the reverse order loses the helper. This is what makes the
# ordering load-bearing rather than cosmetic — phase_b_capture_atelier_git_identity
# rewrites the whole file with `cat >`.
new_cfg; CFG3="$CFG_DIR"
ID3="$CFG3/git-identity.conf"
drive "$CFG3" phase_b_register_author_credential_helper phase_b_capture_atelier_git_identity >/dev/null
idcfg "$ID3" --get-all credential.https://github.com.helper >/dev/null 2>&1 \
  && fail "capture no longer clobbers the credential section — the ordering contract in phase_b() and its comments are now stale, update both" \
  || pass "the capture rewrite DOES clobber the credential section (register must therefore run last)"
[ "$(idcfg "$ID3" --get user.name)" = "$FAKE_LOGIN" ] \
  && pass "reverse order still writes [user] (isolating the clobber to [credential])" \
  || fail "reverse-order run produced no user.name at all"

# 3b (static): pin the call order inside phase_b() so a reorder is caught even
# though the functional consequence above is silent at install time.
phase_b_body="$(awk '/^phase_b\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$INSTALL")"
cap_line="$(printf '%s\n' "$phase_b_body" | grep -n '^[[:space:]]*phase_b_capture_atelier_git_identity[[:space:]]*$' | head -1 | cut -d: -f1)"
reg_line="$(printf '%s\n' "$phase_b_body" | grep -n '^[[:space:]]*phase_b_register_author_credential_helper[[:space:]]*$' | head -1 | cut -d: -f1)"
if [ -z "$reg_line" ]; then
  fail "phase_b() never calls phase_b_register_author_credential_helper — the fix is not wired in"
elif [ -z "$cap_line" ]; then
  fail "phase_b() never calls phase_b_capture_atelier_git_identity"
elif [ "$reg_line" -gt "$cap_line" ]; then
  pass "phase_b() calls register AFTER capture (line $reg_line > $cap_line)"
else
  fail "phase_b() calls register BEFORE capture (line $reg_line <= $cap_line) — the rewrite will clobber it"
fi

# ---------------------------------------------------------------------------
# Group 4: degraded path — gh auth setup-git fails
# ---------------------------------------------------------------------------
new_cfg; CFG4="$CFG_DIR"
ID4="$CFG4/git-identity.conf"
GH_SETUP_GIT_FAIL=1
out4="$(drive "$CFG4" phase_b_capture_atelier_git_identity phase_b_register_author_credential_helper)"
GH_SETUP_GIT_FAIL=""

printf '%s' "$out4" | grep -q 'FN_RC:phase_b_register_author_credential_helper' \
  && fail "register aborted/returned non-zero when gh failed — must degrade, not abort" \
  || pass "register returns 0 when gh auth setup-git fails (degrades, never aborts the install)"
printf '%s' "$out4" | grep -q 'could not register the gh credential helper' \
  && pass "a warning is emitted on the degraded path" \
  || fail "no warning about the failed registration (out: $out4)"
printf '%s' "$out4" | grep -q 'GIT_CONFIG_GLOBAL=.*gh auth setup-git' \
  && pass "the warning carries a copy-pasteable manual fix" \
  || fail "degraded path printed no manual fix command (out: $out4)"
[ "$(idcfg "$ID4" --get user.name)" = "$FAKE_LOGIN" ] \
  && pass "degraded path leaves the captured [user] identity intact" \
  || fail "degraded path damaged the [user] section"

# ---------------------------------------------------------------------------
# Group 5: capture bails early (gh identity unreadable) — register must not
# make things worse.
# ---------------------------------------------------------------------------
new_cfg; CFG5="$CFG_DIR"
ID5="$CFG5/git-identity.conf"
GH_API_USER_FAIL=1
out5="$(drive "$CFG5" phase_b_capture_atelier_git_identity phase_b_register_author_credential_helper)"
GH_API_USER_FAIL=""

printf '%s' "$out5" | grep -q 'FN_RC:' \
  && fail "a phase function returned non-zero when the identity lookup failed: $(printf '%s' "$out5" | grep 'FN_RC:')" \
  || pass "identity-lookup failure degrades cleanly (both functions return 0)"
printf '%s' "$out5" | grep -q 'could not read atelier-author identity' \
  && pass "capture warns that it skipped the identity file" \
  || fail "capture emitted no warning on identity-lookup failure (out: $out5)"
if [ ! -f "$ID5" ] || ! grep -q '^\[user\]' "$ID5"; then
  pass "no bogus [user] section is fabricated when the identity is unknown"
else
  fail "a [user] section was written despite the failed identity lookup: $(grep -A2 '^\[user\]' "$ID5" | tr '\n' '|')"
fi

echo ""
if [ "$fails" -eq 0 ]; then
  echo "install-credential-helper-git-identity: all assertions passed."
  exit 0
else
  echo "install-credential-helper-git-identity: $fails assertion(s) failed."
  exit 1
fi
