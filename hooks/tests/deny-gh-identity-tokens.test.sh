#!/usr/bin/env bash
#
# Regression test for #48 / audit#193 — atelier's own gh identity OAuth
# tokens must be covered by the permission deny list.
#
# $ATELIER_CONFIG_DIR/gh/{author,reviewer}/hosts.yml holds the oauth_token
# for atelier's two bot gh identities. templates/settings.template.json
# already denies Read on the operator's personal ~/.config/gh/**, ~/.ssh,
# ~/.aws, ~/.gnupg — but (pre-fix) said nothing about atelier's own gh
# config dirs, leaving those tokens readable by an agent. The fix adds:
#   "Read(<atelier-config-dir>/gh/**)"
# to permissions.deny, right after the existing ~/.config/gh/** entry.
# <atelier-config-dir> is an install-time placeholder substituted by
# install.sh's phase_c_1_instantiate_templates() (sed over the whole file,
# with a leftover-placeholder guard) when it instantiates the template
# into $ATELIER_CONFIG_DIR/templates/.
#
# This test asserts BOTH:
#   1. the shipped source template's deny list literally carries the
#      <atelier-config-dir>/gh/** entry (static check); and
#   2. a REAL run of phase_c_1_instantiate_templates over a scratch
#      source tree substitutes the placeholder correctly INSIDE the deny
#      array specifically — not merely somewhere in the file (e.g. it
#      would not be enough for the substitution to land in `allow`).
#
# It also carries an explicit negative control: deny_has_gh_config_dir()
# is a path-parameterized helper, run once against the real (fixed)
# template and once against a reconstructed pre-fix baseline (the real
# template with only the new deny line stripped back out — i.e. exactly
# origin/main's content before this task, verified byte-for-byte via
# `git diff origin/main -- templates/settings.template.json` showing
# that single added line as the whole diff). The baseline copy is
# reconstructed from the current file rather than fetched from
# `origin/main` at test time so the suite stays hermetic and does not
# depend on a remote-tracking ref being present (CI checks out PRs
# shallow, with no local origin/main ref).
#
# Hermetic: no network, no writes outside $TMP, no dependence on the
# operator's real $ATELIER_CONFIG_DIR. Sources install.sh (main-gated) to
# drive phase_c_1_instantiate_templates() directly, same pattern as
# hooks/tests/install-runtime-dir.test.sh. Requires jq (already a
# hard dependency of this repo's tests) and sed/grep (POSIX).
#
# Run:  hooks/tests/deny-gh-identity-tokens.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/settings.template.json"
INSTALL="$REPO_ROOT/install.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "#48 / audit#193 regression — atelier gh identity dirs covered by deny list"

# --- helper: does <file>'s permissions.deny array literally contain the
#     <atelier-config-dir>/gh/** entry (source form, placeholder intact)? ---
deny_has_gh_config_dir() {
  local file="$1"
  jq -e '(.permissions.deny // []) | any(. == "Read(<atelier-config-dir>/gh/**)")' \
    "$file" >/dev/null 2>&1
}

# --- helper: does <file>'s permissions.deny array literally contain the
#     INSTANTIATED entry for a given config dir (placeholder substituted)? ---
deny_has_substituted_gh_config_dir() {
  local file="$1" cfg_dir="$2"
  jq -e --arg want "Read(${cfg_dir}/gh/**)" \
    '(.permissions.deny // []) | any(. == $want)' \
    "$file" >/dev/null 2>&1
}

# =============================================================================
# Group 1 — static check: the shipped source template denies
# <atelier-config-dir>/gh/** (not just the operator's ~/.config/gh/**).
# =============================================================================
if deny_has_gh_config_dir "$TEMPLATE"; then
  pass "templates/settings.template.json deny[] carries Read(<atelier-config-dir>/gh/**)"
else
  fail "templates/settings.template.json deny[] is missing Read(<atelier-config-dir>/gh/**) — atelier's own gh oauth tokens are unprotected"
fi

# The pre-existing operator-gh entry must still be present too — additive
# fix, never a replacement.
if jq -e '(.permissions.deny // []) | any(. == "Read(~/.config/gh/**)")' "$TEMPLATE" >/dev/null 2>&1; then
  pass "pre-existing Read(~/.config/gh/**) deny entry is untouched"
else
  fail "Read(~/.config/gh/**) deny entry regressed/removed — must stay additive-only"
fi

# =============================================================================
# Group 2 — negative control: a reconstructed pre-fix baseline (the real
# template minus exactly the one line this task added) must NOT satisfy
# the predicate. This is the RED/GREEN pin: red on the old content, green
# on the current file, using the same path-parameterized helper.
# =============================================================================
BASELINE="$TMP/pre-fix-settings.template.json"
grep -v -F '"Read(<atelier-config-dir>/gh/**)",' "$TEMPLATE" > "$BASELINE"

if ! deny_has_gh_config_dir "$BASELINE"; then
  pass "negative control: reconstructed pre-fix template correctly fails the predicate (RED)"
else
  fail "negative control is broken: reconstructed pre-fix template still passes deny_has_gh_config_dir — the helper is not discriminating"
fi
jq . "$BASELINE" >/dev/null 2>&1 \
  && pass "reconstructed pre-fix baseline is still valid JSON (line strip didn't corrupt it)" \
  || fail "reconstructed pre-fix baseline is not valid JSON"

# =============================================================================
# Group 3 — real instantiation: install.sh's phase_c_1_instantiate_templates
# over a scratch source tree substitutes <atelier-config-dir> to the real
# path INSIDE deny[], for both the fixed template and (as a further red/green
# pin) the reconstructed pre-fix baseline.
# =============================================================================
SRC_FIXED="$TMP/source-fixed"
SRC_BASELINE="$TMP/source-baseline"
CFG_FIXED="$TMP/cfg-fixed"
CFG_BASELINE="$TMP/cfg-baseline"

mkdir -p "$SRC_FIXED/scripts" "$SRC_FIXED/.claude-plugin" \
         "$SRC_BASELINE/scripts" "$SRC_BASELINE/.claude-plugin" \
         "$CFG_FIXED" "$CFG_BASELINE"

mkdir -p "$SRC_FIXED/templates" "$SRC_BASELINE/templates"
cp "$TEMPLATE" "$SRC_FIXED/templates/settings.template.json"
cp "$BASELINE" "$SRC_BASELINE/templates/settings.template.json"
printf 'project claude scratch\n' > "$SRC_FIXED/templates/project-claude.md.template"
printf 'project claude scratch\n' > "$SRC_BASELINE/templates/project-claude.md.template"
printf '{ "name": "atelier", "version": "0.0.0-test" }\n' \
  > "$SRC_FIXED/.claude-plugin/plugin.json"
printf '{ "name": "atelier", "version": "0.0.0-test" }\n' \
  > "$SRC_BASELINE/.claude-plugin/plugin.json"

# run_instantiate — source install.sh (main-gated, same pattern as
# hooks/tests/install-runtime-dir.test.sh) and drive
# phase_c_1_instantiate_templates() directly under a scratch source root +
# config dir. Nothing outside $TMP is read or written.
run_instantiate() {
  local src="$1" cfg="$2"
  ATELIER_SOURCE_ROOT="$src" ATELIER_CONFIG_DIR="$cfg" \
    NO_COLOR=1 INSTALL="$INSTALL" bash -c '
    set -euo pipefail
    # shellcheck disable=SC1090
    source "$INSTALL"
    resolve_source_root
    phase_c_1_instantiate_templates
  ' 2>&1
}

out_fixed="$(run_instantiate "$SRC_FIXED" "$CFG_FIXED")"
rc_fixed=$?
[ "$rc_fixed" -eq 0 ] \
  && pass "phase_c_1_instantiate_templates exits 0 over the fixed template (out: $out_fixed)" \
  || fail "phase_c_1_instantiate_templates rc=$rc_fixed over the fixed template (out: $out_fixed)"

INSTANTIATED_FIXED="$CFG_FIXED/templates/settings.template.json"
[ -f "$INSTANTIATED_FIXED" ] || fail "no instantiated settings.template.json under $CFG_FIXED/templates/"

if deny_has_substituted_gh_config_dir "$INSTANTIATED_FIXED" "$CFG_FIXED"; then
  pass "real instantiation: deny[] carries Read($CFG_FIXED/gh/**) — placeholder substituted correctly inside deny, not just somewhere in the file"
else
  fail "real instantiation: deny[] does NOT carry Read($CFG_FIXED/gh/**) after phase_c_1_instantiate_templates (content: $(cat "$INSTANTIATED_FIXED" 2>/dev/null))"
fi

if grep -q '<atelier-config-dir>' "$INSTANTIATED_FIXED" 2>/dev/null; then
  fail "instantiated template still has a literal <atelier-config-dir> placeholder — substitution incomplete"
else
  pass "instantiated template has no leftover <atelier-config-dir> placeholder"
fi

# Sanity: the substituted entry must land in deny[], not merely somewhere
# else in the tree (e.g. accidentally only in allow[]).
if jq -e --arg want "Read(${CFG_FIXED}/gh/**)" \
     '(.permissions.allow // []) | any(. == $want)' \
     "$INSTANTIATED_FIXED" >/dev/null 2>&1; then
  fail "substituted gh identity entry leaked into allow[] as well — deny-list intent violated"
else
  pass "substituted gh identity entry is not duplicated into allow[]"
fi

# --- red/green pin on the real instantiation path itself: the reconstructed
#     pre-fix baseline must NOT produce a substituted deny entry. ---
out_baseline="$(run_instantiate "$SRC_BASELINE" "$CFG_BASELINE")"
rc_baseline=$?
[ "$rc_baseline" -eq 0 ] \
  && pass "phase_c_1_instantiate_templates exits 0 over the pre-fix baseline (out: $out_baseline)" \
  || fail "phase_c_1_instantiate_templates rc=$rc_baseline over the pre-fix baseline (out: $out_baseline)"

INSTANTIATED_BASELINE="$CFG_BASELINE/templates/settings.template.json"
if ! deny_has_substituted_gh_config_dir "$INSTANTIATED_BASELINE" "$CFG_BASELINE"; then
  pass "negative control (real instantiation): pre-fix baseline correctly fails to produce Read($CFG_BASELINE/gh/**) in deny[] (RED)"
else
  fail "negative control (real instantiation) is broken: pre-fix baseline unexpectedly produced the substituted deny entry"
fi

echo ""
if [ "$fails" -eq 0 ]; then
  echo "#48 gh identity deny-list regression: all assertions passed."
  exit 0
else
  echo "#48 gh identity deny-list regression: $fails assertion(s) failed."
  exit 1
fi
