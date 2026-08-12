#!/usr/bin/env bash
#
# Regression test for #41 — CLAUDE_CONFIG_DIR must be exported from
# main() AFTER phase_0_preflight, not before it.
#
# The bug: main() used to run
#   export CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR"
# BEFORE calling phase_0_preflight(). On a collision, phase_0_preflight()
# reassigns $ATELIER_CONFIG_DIR to the operator-picked alternative path —
# but CLAUDE_CONFIG_DIR kept pointing at the REJECTED dir, because it was
# captured before the reassignment. Phase B auth prefixes every `claude`
# call with an explicit CLAUDE_CONFIG_DIR="$ATELIER_CONFIG_DIR" (so it was
# unaffected), but phase_c_2_marketplace / phase_c_2_install_plugin /
# verify_plugin call `claude` BARE, relying on the exported env var. Result:
# the marketplace + plugins installed into the OLD (rejected) dir,
# verify_plugin reported green against that old dir, and the shellrc hook
# block pointed the operator's future sessions at the NEW dir — every later
# `task`/`atelier` session started with no plugins, while the installer
# claimed "complete".
#
# The fix: the single `export CLAUDE_CONFIG_DIR=` statement in main() moved
# from before the `--refresh-shellrc` early-exit block to immediately AFTER
# phase_0_preflight (right before phase_a) — see install.sh main().
#
# This test locks two invariants:
#   Group 1 (static):     main() exports CLAUDE_CONFIG_DIR exactly once, and
#     that export call-site is textually AFTER the phase_0_preflight
#     call-site — located by content (awk over main()'s body), not hardcoded
#     line numbers, so the assertion survives comment edits / reflow and
#     would still pass a future "re-export after preflight" refactor that
#     preserves the order.
#   Group 2 (functional): sourcing install.sh (main-gated) and driving a
#     REAL extract of main()'s own body through parse_args ->
#     resolve_config_dir -> resolve_source_root -> detect_source_mode ->
#     phase_0_preflight -> export, on a scratch ATELIER_CONFIG_DIR that
#     collides with unrelated content, proves CLAUDE_CONFIG_DIR ends up
#     equal to the NEW (operator-picked) ATELIER_CONFIG_DIR at the point the
#     bare-`claude` phases would run — not the rejected one.
#
# Meaningfulness proof (both groups): a synthetic fixture reproduces the
# pre-#41-fix main() layout by mechanically moving the export call back to
# right after detect_source_mode (content-driven splice, not copied from git
# history — keeps this hermetic against a shallow/single-branch checkout in
# CI). Both groups re-run their exact same checks against that fixture and
# assert they FAIL there — proving the assertions actually catch the bug
# rather than being tautologies. Verified by hand against the real
# origin/main install.sh too (see PR description) — that fixture reproduces
# this synthetic one byte-for-byte in the relevant region.
#
# Hermetic: sources install.sh (main-gated) inside a throwaway HOME +
# ATELIER_SOURCE_ROOT + ATELIER_CONFIG_DIR tree and drives the extracted
# main()-prefix directly. No network, no real `claude`/plugin work (the
# probe stops before the first `phase_a` call), no writes outside the temp
# dir.
# Requires: git, awk (install.sh Phase-A deps / POSIX).
#
# Run:  hooks/tests/install-claude-config-dir-preflight.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "install.sh CLAUDE_CONFIG_DIR export runs after phase_0_preflight (#41)"

# ---------------------------------------------------------------------------
# Shared fixtures
# ---------------------------------------------------------------------------

# BUGGY: a synthetic reconstruction of the pre-#41-fix main() layout. Drops
# the (unique) `export CLAUDE_CONFIG_DIR=` statement from wherever it
# currently lives and re-inserts it right after `detect_source_mode` —
# BEFORE phase_0_preflight, exactly where main() had it before the fix.
# Content-driven (matches the literal statement text), so it stays correct
# even if unrelated lines shift.
BUGGY="$TMP/buggy-install.sh"
make_buggy_install() {
  awk '
    /^  export CLAUDE_CONFIG_DIR="\$ATELIER_CONFIG_DIR"$/ { next }
    { print }
    /^  detect_source_mode$/ { print "  export CLAUDE_CONFIG_DIR=\"$ATELIER_CONFIG_DIR\"" }
  ' "$1" > "$2"
}
make_buggy_install "$INSTALL" "$BUGGY"

bash -n "$BUGGY" \
  && pass "fixture sanity: the synthetic buggy install.sh is still syntactically valid bash" \
  || fail "fixture sanity: buggy install.sh failed bash -n — the splice broke the file"

# A minimal scratch source tree satisfying resolve_source_root()'s shape
# check (scripts/ + .claude-plugin/plugin.json), used by both groups so
# detect_source_mode()/resolve_source_root() never touch this real repo.
SRC_TREE="$TMP/src-tree"
mkdir -p "$SRC_TREE/scripts" "$SRC_TREE/.claude-plugin"
printf '{\n  "name": "atelier",\n  "version": "9.9.9"\n}\n' > "$SRC_TREE/.claude-plugin/plugin.json"

# ---------------------------------------------------------------------------
# Group 1: STATIC ORDER PIN
# ---------------------------------------------------------------------------
echo "Group 1: static order pin (content-located, not line-number-hardcoded)"

# main_line_range <file> — prints "<start> <end>", the line numbers of
# "main() {" and its matching closing "}".
main_line_range() {
  awk '
    /^main\(\) \{$/ { start = NR; f = 1; next }
    f && /^\}$/ { print start, NR; exit }
  ' "$1"
}

# lines_in_main <file> <pattern> — line numbers (one per line, may be empty)
# of every line inside main()'s body (exclusive of its boundary lines)
# matching <pattern>. Call-site indentation (2 spaces) is baked into every
# pattern this test passes, so a function DEFINITION at column 0 can never
# satisfy a match.
lines_in_main() {
  local file="$1" pattern="$2" range s e
  range="$(main_line_range "$file")"
  s="${range%% *}"; e="${range##* }"
  awk -v s="$s" -v e="$e" -v pat="$pattern" 'NR > s && NR < e && $0 ~ pat { print NR }' "$file"
}

# order_check_file <file> — sets OC_* globals describing whether main()
# exports CLAUDE_CONFIG_DIR exactly once, AFTER exactly one
# phase_0_preflight call.
order_check_file() {
  local file="$1" preflight_hits export_hits preflight_count export_count
  preflight_hits="$(lines_in_main "$file" '^  phase_0_preflight$')"
  export_hits="$(lines_in_main "$file" '^  export CLAUDE_CONFIG_DIR=')"
  preflight_count=0; [ -n "$preflight_hits" ] && preflight_count="$(printf '%s\n' "$preflight_hits" | wc -l | tr -d ' ')"
  export_count=0; [ -n "$export_hits" ] && export_count="$(printf '%s\n' "$export_hits" | wc -l | tr -d ' ')"
  OC_PREFLIGHT_COUNT="$preflight_count"
  OC_EXPORT_COUNT="$export_count"
  OC_PREFLIGHT_LINES="$preflight_hits"
  OC_EXPORT_LINES="$export_hits"
  if [ "$preflight_count" -eq 1 ] && [ "$export_count" -eq 1 ] && [ "$export_hits" -gt "$preflight_hits" ]; then
    OC_STATUS="ok"
  else
    OC_STATUS="bad"
  fi
}

order_check_file "$INSTALL"

[ "$OC_PREFLIGHT_COUNT" -eq 1 ] \
  && pass "main() calls phase_0_preflight exactly once (line $OC_PREFLIGHT_LINES)" \
  || fail "main() calls phase_0_preflight $OC_PREFLIGHT_COUNT times, expected 1 (lines: $(printf '%s' "$OC_PREFLIGHT_LINES" | tr '\n' ','))"

[ "$OC_EXPORT_COUNT" -eq 1 ] \
  && pass "main() exports CLAUDE_CONFIG_DIR exactly once (line $OC_EXPORT_LINES)" \
  || fail "main() exports CLAUDE_CONFIG_DIR $OC_EXPORT_COUNT times, expected exactly 1 (lines: $(printf '%s' "$OC_EXPORT_LINES" | tr '\n' ','))"

[ "$OC_STATUS" = "ok" ] \
  && pass "export CLAUDE_CONFIG_DIR (line $OC_EXPORT_LINES) runs AFTER phase_0_preflight (line $OC_PREFLIGHT_LINES) inside main()" \
  || fail "order broken: phase_0_preflight at '${OC_PREFLIGHT_LINES:-none}', export at '${OC_EXPORT_LINES:-none}' — export must come later"

# Explicit "not left dangling before it" check: independent of the count/
# order check above, walk every export hit and confirm none of them sit
# before the (first) phase_0_preflight call. Written this way so it still
# catches a regression that reintroduces the old export line ALONGSIDE the
# new one (which the "exactly 1" check above would also catch, but this
# names the specific failure mode the bug report called out).
export_before_preflight=0
if [ -n "$OC_EXPORT_LINES" ] && [ -n "$OC_PREFLIGHT_LINES" ]; then
  first_preflight_line="$(printf '%s\n' "$OC_PREFLIGHT_LINES" | head -1)"
  for ln in $OC_EXPORT_LINES; do
    [ "$ln" -lt "$first_preflight_line" ] && export_before_preflight=$((export_before_preflight + 1))
  done
fi
[ "$export_before_preflight" -eq 0 ] \
  && pass "no CLAUDE_CONFIG_DIR export left dangling before phase_0_preflight in main()" \
  || fail "$export_before_preflight CLAUDE_CONFIG_DIR export(s) found before phase_0_preflight in main()"

# Meaningfulness: the same checks against the synthetic pre-fix layout must
# FAIL — otherwise the pin above is a tautology that would not have caught
# #41.
order_check_file "$BUGGY"
[ "$OC_STATUS" != "ok" ] \
  && pass "meaningfulness: the pre-#41-fix layout (export BEFORE phase_0_preflight) correctly FAILS the static order pin (preflight=$OC_PREFLIGHT_LINES export=$OC_EXPORT_LINES)" \
  || fail "meaningfulness: the pre-#41-fix layout PASSED the static order pin — the pin would not have caught #41"

# ---------------------------------------------------------------------------
# Group 2: FUNCTIONAL COLLISION-BRANCH SIMULATION
# ---------------------------------------------------------------------------
echo "Group 2: functional collision-branch simulation"

# extract_main_probe <install-file> <dest> — extracts main()'s REAL body up
# to (excluding) the first `phase_a` call and wraps it as `main_probe()`.
# This runs the actual, unmodified control flow install.sh ships
# (parse_args -> resolve_config_dir -> resolve_source_root ->
# detect_source_mode -> [--refresh-shellrc gate] -> phase_0_preflight ->
# export) — the exact prefix the bug lived in — without reaching phase_a
# onward, which does real installs. install.sh's own main-gate comment
# documents this pattern: "The hermetic tests ... source this file to
# exercise individual phase functions ... without triggering a full
# install."
extract_main_probe() {
  {
    awk '
      /^main\(\) \{$/ { print "main_probe() {"; f=1; next }
      f && /^  phase_a$/ { exit }
      f { print }
    ' "$1"
    echo "}"
  } > "$2"
}

# run_probe <install-file> <config-dir> <collision-answer>
# Sources <install-file> (main-gated: defines functions/vars only) plus the
# extracted main_probe(), then runs main_probe with
# ATELIER_CONFIG_DIR=<config-dir>. <collision-answer> is piped on stdin so
# phase_0_preflight's interactive "pick an alternative path" prompt (if
# triggered) picks it. Prints install.sh's own log lines plus:
#   RC=<exit status>
#   FINAL_ATELIER_CONFIG_DIR=<value after main_probe returns>
#   FINAL_CLAUDE_CONFIG_DIR=<value after main_probe returns, or <unset>>
run_probe() {
  local install_file="$1" cfg="$2" answer="$3" probe_file="$TMP/probe.sh"
  extract_main_probe "$install_file" "$probe_file"
  HOME="$HOME_DIR" ATELIER_CONFIG_DIR="$cfg" ATELIER_SOURCE_ROOT="$SRC_TREE" \
  NO_COLOR=1 INSTALL="$install_file" PROBE="$probe_file" bash -c '
    set -uo pipefail
    # shellcheck disable=SC1090
    source "$INSTALL"
    # shellcheck disable=SC1090
    source "$PROBE"
    main_probe
    rc=$?
    printf "RC=%s\n" "$rc"
    printf "FINAL_ATELIER_CONFIG_DIR=%s\n" "$ATELIER_CONFIG_DIR"
    printf "FINAL_CLAUDE_CONFIG_DIR=%s\n" "${CLAUDE_CONFIG_DIR:-<unset>}"
  ' <<< "$answer" 2>&1
}

# field <probe-output> <KEY> — last "<KEY>=<value>" line's value.
field() {
  printf '%s\n' "$1" | grep -o "^$2=.*" | tail -1 | cut -d= -f2-
}

# --- Case A: shipped install.sh, collision branch (the bug's exact scenario) ---
CFG_A="$TMP/cfg-collide-a"; mkdir -p "$CFG_A"; : > "$CFG_A/unrelated-file.txt"
ALT_A="$TMP/cfg-alt-a"

out_a="$(run_probe "$INSTALL" "$CFG_A" "$ALT_A")"
rc_a="$(field "$out_a" RC)"
final_atelier_a="$(field "$out_a" FINAL_ATELIER_CONFIG_DIR)"
final_claude_a="$(field "$out_a" FINAL_CLAUDE_CONFIG_DIR)"

[ "$rc_a" = "0" ] \
  && pass "shipped install.sh: main()'s preflight prefix runs clean on a collision (exit 0)" \
  || fail "shipped install.sh: probe exited $rc_a (out: $out_a)"

[ "$final_atelier_a" = "$ALT_A" ] \
  && pass "collision branch reassigns ATELIER_CONFIG_DIR to the operator-picked alternative ($ALT_A)" \
  || fail "ATELIER_CONFIG_DIR after preflight: expected '$ALT_A', got '$final_atelier_a'"

[ "$final_atelier_a" != "$CFG_A" ] \
  && pass "sanity: the reassigned dir differs from the rejected colliding dir (isolates the scenario)" \
  || fail "sanity failed: ATELIER_CONFIG_DIR never actually changed from the colliding dir"

[ "$final_claude_a" = "$ALT_A" ] \
  && pass "THE FIX: CLAUDE_CONFIG_DIR equals the NEW ATELIER_CONFIG_DIR at the point bare-\`claude\` phases run" \
  || fail "CLAUDE_CONFIG_DIR='$final_claude_a' still points at the rejected dir '$CFG_A', not the operator's chosen '$ALT_A' (out: $out_a)"

# --- Case B: non-collision happy path — CLAUDE_CONFIG_DIR still resolves
#     correctly when no prompt fires (no divergence window either way).
CFG_C="$TMP/cfg-clean-c"
out_c="$(run_probe "$INSTALL" "$CFG_C" "")"
rc_c="$(field "$out_c" RC)"
final_claude_c="$(field "$out_c" FINAL_CLAUDE_CONFIG_DIR)"
{ [ "$rc_c" = "0" ] && [ "$final_claude_c" = "$CFG_C" ]; } \
  && pass "non-collision happy path: CLAUDE_CONFIG_DIR still resolves to ATELIER_CONFIG_DIR when no prompt is needed" \
  || fail "non-collision happy path broke: rc=$rc_c CLAUDE_CONFIG_DIR='$final_claude_c' expected '$CFG_C' (out: $out_c)"

# --- Case D: meaningfulness — same scenario as Case A, against the
#     synthetic pre-#41-fix layout, must reproduce the real bug: ATELIER_
#     CONFIG_DIR moves, CLAUDE_CONFIG_DIR does NOT follow it.
CFG_D="$TMP/cfg-collide-d"; mkdir -p "$CFG_D"; : > "$CFG_D/unrelated-file.txt"
ALT_D="$TMP/cfg-alt-d"

out_d="$(run_probe "$BUGGY" "$CFG_D" "$ALT_D")"
final_atelier_d="$(field "$out_d" FINAL_ATELIER_CONFIG_DIR)"
final_claude_d="$(field "$out_d" FINAL_CLAUDE_CONFIG_DIR)"

[ "$final_atelier_d" = "$ALT_D" ] \
  && pass "meaningfulness: the buggy fixture's preflight still reassigns ATELIER_CONFIG_DIR (isolates export ordering as the only variable)" \
  || fail "meaningfulness setup broken: ATELIER_CONFIG_DIR after buggy-fixture preflight: expected '$ALT_D', got '$final_atelier_d'"

[ "$final_claude_d" = "$CFG_D" ] \
  && pass "meaningfulness: the pre-#41-fix layout reproduces the real bug — CLAUDE_CONFIG_DIR stays stuck on the REJECTED dir ($CFG_D) while ATELIER_CONFIG_DIR moved to $ALT_D" \
  || fail "meaningfulness: buggy fixture did NOT reproduce the bug (CLAUDE_CONFIG_DIR='$final_claude_d') — the functional simulation may be tautological"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "install-claude-config-dir-preflight (#41): all assertions passed."
  exit 0
else
  echo "install-claude-config-dir-preflight (#41): $fails assertion(s) failed."
  exit 1
fi
