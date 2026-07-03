#!/usr/bin/env bash
#
# Regression test for atelier-refresh-mirror (TASK_034) and its SessionStart
# dispatcher hooks/refresh-mirror.sh. Covers:
#
#   1. Backend + offlineMirror gating — files backend no-op; non-files with
#      offlineMirror:false/absent no-op; non-files + offlineMirror:true → surfaced.
#   2. Instruction content — names crt's existing "Mirror auto-refresh on
#      activation" procedure and the roadmap-tracking-flow skill.
#   3. NEVER /migrate-roadmap --to files — absent from both output and source.
#   4. .roadmap.json integrity — file not removed or mutated after the helper runs.
#   5. Worktree guard — linked worktree (.git as a file) → no-op.
#   6. Once-per-day stamp — first run (stale/absent stamp) surfaces instruction and
#      writes today's date; immediate second run with same-day stamp is a no-op.
#   7. Fail-open — missing ATELIER_CONFIG_DIR / non-git-repo dir → exit 0 silently.
#   8. SessionStart wiring — hooks/hooks.json has an entry referencing refresh-mirror.sh.
#
# Hermetic: filesystem + jq only; no network, no real gh, no GitHub MCP.
#
# Run:  hooks/tests/refresh-mirror.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/atelier-refresh-mirror"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH (required by helper)"; exit 0; }

# Resolve symlinks (macOS /var/... → /private/var/...) so fixture paths match
# what the helper sees after its own `pwd -P` canonicalisation.
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

CFG="$TMP/cfg"
mkdir -p "$CFG"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# run_helper <proj_dir>
# Runs the helper with our hermetic config dir and plugin root pointing at the
# real repo so atelier-task-backend is resolved from scripts/. stderr discarded
# (helper is fail-open; stderr noise is not part of the contract).
run_helper() {
  ATELIER_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    bash "$HELPER" "$1" 2>/dev/null
}

# mk_git_repo <dir> — make a directory that looks like a regular git repo
# (.git is a directory, not a file). The helper requires .git to be a directory.
mk_git_repo() {
  local d="$1"
  mkdir -p "$d/.git"
}

# mk_roadmap_json <dir> <backend> <offlineMirror-value>
# offlineMirror-value must be a JSON value (true, false, or omitted via "OMIT").
mk_roadmap_json() {
  local d="$1" backend="$2" mirror="$3"
  if [ "$mirror" = "OMIT" ]; then
    printf '{"backend":"%s"}\n' "$backend" > "$d/.roadmap.json"
  else
    printf '{"backend":"%s","offlineMirror":%s}\n' "$backend" "$mirror" > "$d/.roadmap.json"
  fi
}

# clear_stamp — remove the once-per-day stamp so the next run is not suppressed.
clear_stamp() { rm -f "$CFG/mirror-refresh-last-check"; }

echo "refresh-mirror (TASK_034) — hermetic regression"
echo ""

# ===========================================================================
# Group A — backend + offlineMirror gating (assertion #1)
# ===========================================================================

# A1: files backend + offlineMirror:true → no output (exits before stamp check)
A1="$TMP/a1_files"; mk_git_repo "$A1"; mk_roadmap_json "$A1" "files" "true"
clear_stamp
out="$(run_helper "$A1")"
[ -z "$out" ] \
  && pass "A1: files backend + offlineMirror:true → no-op (no output)" \
  || fail "A1: files backend → should be no-op; got: $out"

# A2: github-project + offlineMirror:false → no output
A2="$TMP/a2_false"; mk_git_repo "$A2"; mk_roadmap_json "$A2" "github-project" "false"
clear_stamp
out="$(run_helper "$A2")"
[ -z "$out" ] \
  && pass "A2: github-project + offlineMirror:false → no-op" \
  || fail "A2: offlineMirror:false → should be no-op; got: $out"

# A3: github-project + offlineMirror key absent → no output
A3="$TMP/a3_absent"; mk_git_repo "$A3"; mk_roadmap_json "$A3" "github-project" "OMIT"
clear_stamp
out="$(run_helper "$A3")"
[ -z "$out" ] \
  && pass "A3: github-project + offlineMirror absent → no-op" \
  || fail "A3: absent offlineMirror → should be no-op; got: $out"

# A4: github-project + offlineMirror:true → instruction IS surfaced
A4="$TMP/a4_surfaced"; mk_git_repo "$A4"; mk_roadmap_json "$A4" "github-project" "true"
clear_stamp
SURFACED="$(run_helper "$A4")"
[ -n "$SURFACED" ] \
  && pass "A4: github-project + offlineMirror:true → instruction surfaced" \
  || fail "A4: github-project + offlineMirror:true → expected output but got none"

# A5: any non-files backend (linear) + offlineMirror:true → instruction surfaced
A5="$TMP/a5_linear"; mk_git_repo "$A5"; mk_roadmap_json "$A5" "linear" "true"
clear_stamp
out="$(run_helper "$A5")"
[ -n "$out" ] \
  && pass "A5: linear backend + offlineMirror:true → instruction surfaced" \
  || fail "A5: linear backend + offlineMirror:true → expected output but got none"

# A6: files backend + no .roadmap.json → no output (atelier-task-backend returns 'files')
A6="$TMP/a6_nofile"; mk_git_repo "$A6"
clear_stamp
out="$(run_helper "$A6")"
[ -z "$out" ] \
  && pass "A6: no .roadmap.json (defaults to files backend) → no-op" \
  || fail "A6: no .roadmap.json → should be no-op; got: $out"

# ===========================================================================
# Group B — instruction content (assertions #2 and #3)
# Uses SURFACED captured in A4 above.
# ===========================================================================

# B1: instruction names the roadmap-tracking-flow skill
printf '%s' "$SURFACED" | grep -qF 'roadmap-tracking-flow' \
  && pass "B1: instruction names 'roadmap-tracking-flow' skill" \
  || fail "B1: instruction must mention 'roadmap-tracking-flow'; got: $SURFACED"

# B2: instruction names crt's EXISTING "Mirror auto-refresh on activation" procedure
printf '%s' "$SURFACED" | grep -qF 'Mirror auto-refresh on activation' \
  && pass "B2: instruction names 'Mirror auto-refresh on activation' procedure" \
  || fail "B2: instruction must mention 'Mirror auto-refresh on activation'; got: $SURFACED"

# B3: /migrate-roadmap --to files NEVER appears in instruction output
printf '%s' "$SURFACED" | grep -qF '/migrate-roadmap --to files' \
  && fail "B3: instruction must NOT contain '/migrate-roadmap --to files' — found in output" \
  || pass "B3: instruction does not reference /migrate-roadmap --to files"

# B4: /migrate-roadmap --to files NEVER appears in the helper SOURCE FILE
grep -qF '/migrate-roadmap --to files' "$HELPER" \
  && fail "B4: helper source must NOT contain '/migrate-roadmap --to files'" \
  || pass "B4: helper source does not reference /migrate-roadmap --to files"

# ===========================================================================
# Group C — .roadmap.json integrity (assertion #4)
# ===========================================================================

C="$TMP/c_integrity"; mk_git_repo "$C"; mk_roadmap_json "$C" "github-project" "true"
ROADMAP_BEFORE="$(cat "$C/.roadmap.json")"
clear_stamp
run_helper "$C" >/dev/null 2>&1

# C1: .roadmap.json still exists (not removed)
[ -f "$C/.roadmap.json" ] \
  && pass "C1: .roadmap.json still exists after helper runs" \
  || fail "C1: .roadmap.json was removed by the helper"

# C2: .roadmap.json contents unchanged (not mutated)
ROADMAP_AFTER="$(cat "$C/.roadmap.json" 2>/dev/null || true)"
[ "$ROADMAP_BEFORE" = "$ROADMAP_AFTER" ] \
  && pass "C2: .roadmap.json contents unchanged after helper runs" \
  || fail "C2: .roadmap.json was mutated — before: '$ROADMAP_BEFORE' after: '$ROADMAP_AFTER'"

# ===========================================================================
# Group D — worktree guard (assertion #5)
# A linked worktree has .git as a FILE (gitdir pointer), not a directory.
# ===========================================================================

D="$TMP/d_worktree"; mkdir -p "$D"
mk_roadmap_json "$D" "github-project" "true"
# .git is a file (gitdir pointer) — exactly how git creates linked worktrees
printf 'gitdir: /some/repo/.git/worktrees/task-34\n' > "$D/.git"
clear_stamp
out="$(run_helper "$D")"
[ -z "$out" ] \
  && pass "D1: linked worktree (.git is a file) → no-op" \
  || fail "D1: linked worktree → should be no-op; got: $out"

# Verify it exits 0 (fail-open contract holds for worktree guard too)
rc=0
ATELIER_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
  bash "$HELPER" "$D" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] \
  && pass "D2: linked worktree → exit 0 (fail-open)" \
  || fail "D2: linked worktree → non-zero exit $rc"

# ===========================================================================
# Group E — once-per-day stamp (assertion #6)
# ===========================================================================

E="$TMP/e_stamp"; mk_git_repo "$E"; mk_roadmap_json "$E" "github-project" "true"
STAMP="$CFG/mirror-refresh-last-check"
clear_stamp

# E1: first run (no stamp) → instruction surfaced
out_e1="$(run_helper "$E")"
[ -n "$out_e1" ] \
  && pass "E1: first run (absent stamp) → instruction surfaced" \
  || fail "E1: first run → expected instruction but got no output"

# E2: first run wrote the stamp file
[ -f "$STAMP" ] \
  && pass "E2: first run → stamp file created at $STAMP" \
  || fail "E2: first run → stamp file NOT written"

# E3: stamp file contains today's date in YYYY-MM-DD format
TODAY="$(date +%F)"
STAMP_VALUE="$(head -n1 "$STAMP" 2>/dev/null || true)"
[ "$STAMP_VALUE" = "$TODAY" ] \
  && pass "E3: stamp file contains today's date ($TODAY)" \
  || fail "E3: stamp file contains '$STAMP_VALUE', expected today '$TODAY'"

# E4: second run (same-day stamp already written) → no-op
out_e4="$(run_helper "$E")"
[ -z "$out_e4" ] \
  && pass "E4: second run (same-day stamp) → no-op (at most once per day)" \
  || fail "E4: second run → should be suppressed by same-day stamp; got: $out_e4"

# E5: stale stamp (past date) → instruction surfaced again
printf '2000-01-01\n' > "$STAMP"
out_e5="$(run_helper "$E")"
[ -n "$out_e5" ] \
  && pass "E5: stale stamp (2000-01-01) → instruction surfaced" \
  || fail "E5: stale stamp → expected instruction but got no output"

# ===========================================================================
# Group F — fail-open (assertion #7)
# ===========================================================================

F="$TMP/f_failopen"; mk_git_repo "$F"; mk_roadmap_json "$F" "github-project" "true"

# F1: missing ATELIER_CONFIG_DIR → exit 0, no output
rc=0; out=""
out="$(ATELIER_CONFIG_DIR="$TMP/nonexistent_cfg_dir" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
         bash "$HELPER" "$F" 2>/dev/null)" || rc=$?
[ "$rc" -eq 0 ] \
  && pass "F1: missing ATELIER_CONFIG_DIR → exit 0 (fail-open)" \
  || fail "F1: missing ATELIER_CONFIG_DIR → non-zero exit $rc"
[ -z "$out" ] \
  && pass "F2: missing ATELIER_CONFIG_DIR → no output" \
  || fail "F2: missing ATELIER_CONFIG_DIR → unexpected output: $out"

# F3: non-git-repo directory (.git entirely absent) → exit 0, no output
F3="$TMP/f3_nogit"; mkdir -p "$F3"; mk_roadmap_json "$F3" "github-project" "true"
clear_stamp
rc=0; out=""
out="$(run_helper "$F3")" || rc=$?
[ "$rc" -eq 0 ] \
  && pass "F3: non-git-repo (.git absent) → exit 0 (fail-open)" \
  || fail "F3: non-git-repo → non-zero exit $rc"
[ -z "$out" ] \
  && pass "F4: non-git-repo (.git absent) → no output" \
  || fail "F4: non-git-repo → unexpected output: $out"

# F5: nonexistent directory → exit 0 (helper fail-open on cd failure)
rc=0
ATELIER_CONFIG_DIR="$CFG" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
  bash "$HELPER" "$TMP/does_not_exist" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] \
  && pass "F5: nonexistent project dir → exit 0 (fail-open)" \
  || fail "F5: nonexistent project dir → non-zero exit $rc"

# F6: helper source contains the jq fail-open guard (runtime test of jq absence
#     requires fragile PATH surgery; assert the guard is present in source instead)
grep -qF 'command -v jq >/dev/null 2>&1 || exit 0' "$HELPER" \
  && pass "F6: helper source has fail-open guard for missing jq" \
  || fail "F6: helper source is missing fail-open guard 'command -v jq >/dev/null 2>&1 || exit 0'"

# ===========================================================================
# Group G — SessionStart wiring (assertion #8)
# ===========================================================================

# G1: hooks.json contains an entry referencing refresh-mirror.sh
grep -qF 'refresh-mirror.sh' "$HOOKS_JSON" \
  && pass "G1: hooks.json references refresh-mirror.sh" \
  || fail "G1: hooks.json does not reference refresh-mirror.sh"

# G2: the refresh-mirror.sh entry is in the SessionStart hook array (not another event)
jq -e '[
  .hooks.SessionStart[]?.hooks[]?.command
  | select(. != null)
  | test("refresh-mirror\\.sh")
] | any' "$HOOKS_JSON" >/dev/null 2>&1 \
  && pass "G2: refresh-mirror.sh is registered under hooks.SessionStart" \
  || fail "G2: refresh-mirror.sh is NOT under hooks.SessionStart in hooks.json"

# G3: it is a fifth entry (three pre-existing hooks + refresh-mirror.sh +
# sync-notification-hook.sh, added by #41)
count="$(jq '[.hooks.SessionStart[]?.hooks[]?.command | select(. != null)] | length' \
  "$HOOKS_JSON" 2>/dev/null || true)"
[ "$count" = "5" ] \
  && pass "G3: hooks.SessionStart has exactly 5 entries (3 existing + refresh-mirror + sync-notification-hook)" \
  || fail "G3: hooks.SessionStart has $count entries, expected 5"

# ===========================================================================
# Result
# ===========================================================================
echo ""
if [ "$fails" -eq 0 ]; then
  echo "refresh-mirror (TASK_034): all assertions passed."
  exit 0
else
  echo "refresh-mirror (TASK_034): $fails assertion(s) failed."
  exit 1
fi
