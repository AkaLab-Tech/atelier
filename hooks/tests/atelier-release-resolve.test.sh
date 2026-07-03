#!/usr/bin/env bash
#
# Tests for #43 — scripts/atelier-release resolve.
#
# Locks the SemVer resolution logic behind /atelier:release: Conventional
# Commit inference (feat -> minor; fix/chore -> patch; !/BREAKING CHANGE ->
# major), explicit override (level or X.Y.Z), the noop case, and the three
# refusal guards (dirty working tree, local main behind origin/main,
# resolved next_version not advancing past current).
#
# Hermetic: every scenario builds its own throwaway fixture repo under
# mktemp -d with --allow-empty commits (no tracked-file churn needed) and a
# manually-pinned refs/remotes/origin/main (no real remote, no network,
# no fetch). No writes outside $TMP. Cleaned up via trap.
#
# Field names/shape asserted below are taken verbatim from the JSON
# contract documented at the top of scripts/atelier-release (current,
# last_tag, unreleased_commits, inferred_bump, next_version, noop,
# refuse_reason, pr_body_lines) — do not rename without re-checking the
# helper's own doc comment.
#
# Run:  hooks/tests/atelier-release-resolve.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ATELIER_RELEASE="$REPO_ROOT/scripts/atelier-release"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }
[ -x "$ATELIER_RELEASE" ] || { echo "  FAIL: $ATELIER_RELEASE not found or not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# new_repo <dir> <current-version> — init a repo with a committed
# .claude-plugin/plugin.json at <current-version> and a matching v<current>
# tag on the init commit.
new_repo() {
  local dir="$1" current="$2"
  mkdir -p "$dir/.claude-plugin"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name "Test"
  printf '{"version":"%s"}\n' "$current" > "$dir/.claude-plugin/plugin.json"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "chore: init v$current"
  git -C "$dir" tag "v$current"
}

# commit_empty <dir> <subject> [<body>] — an --allow-empty commit so fixture
# history never has to churn tracked files (keeps the working tree clean by
# construction between scenario steps).
commit_empty() {
  local dir="$1" subject="$2" body="${3:-}"
  if [ -n "$body" ]; then
    git -C "$dir" commit -q --allow-empty -m "$subject" -m "$body"
  else
    git -C "$dir" commit -q --allow-empty -m "$subject"
  fi
}

# sync_origin <dir> [<sha-or-ref>] — pin refs/remotes/origin/main, standing
# in for a real `git fetch origin main` (hermetic: no remote is configured).
sync_origin() {
  local dir="$1" ref="${2:-main}"
  git -C "$dir" update-ref refs/remotes/origin/main "$(git -C "$dir" rev-parse "$ref")"
}

# do_resolve <dir> [<override>] — runs `resolve`, stashes stdout/exit code
# in RESOLVE_OUT / RESOLVE_CODE (stderr discarded — the human message is
# not part of the JSON contract under test here).
do_resolve() {
  local dir="$1"; shift
  RESOLVE_OUT="$("$ATELIER_RELEASE" resolve --project "$dir" "$@" 2>/dev/null)"
  RESOLVE_CODE=$?
}

jf() { # jf <field> — read a field out of $RESOLVE_OUT
  jq -r --arg f "$1" '.[$f]' <<<"$RESOLVE_OUT" 2>/dev/null
}

assert_eq() { # assert_eq <label> <expected> <actual>
  if [ "$3" = "$2" ]; then pass "$1 = $2"; else fail "$1 — want '$2' got '$3'"; fi
}

assert_code() { # assert_code <label> <expected> <actual>
  if [ "$3" = "$2" ]; then pass "$1 exit=$2"; else fail "$1 — want exit $2 got $3"; fi
}

# ===========================================================================
# A — feat: commit since last tag -> minor bump
# ===========================================================================
echo "A: feat -> minor"
A="$TMP/a"; new_repo "$A" 0.39.0
commit_empty "$A" "feat: add widget"
sync_origin "$A"
do_resolve "$A"
assert_code  "A"          0            "$RESOLVE_CODE"
assert_eq    "A current"      "0.39.0"     "$(jf current)"
assert_eq    "A last_tag"     "v0.39.0"    "$(jf last_tag)"
assert_eq    "A inferred_bump" "minor"     "$(jf inferred_bump)"
assert_eq    "A next_version" "0.40.0"     "$(jf next_version)"
assert_eq    "A noop"         "false"      "$(jf noop)"
assert_eq    "A refuse_reason" "null"      "$(jf refuse_reason)"
assert_eq    "A unreleased count" "1"      "$(jq -r '.unreleased_commits | length' <<<"$RESOLVE_OUT")"
if [[ "$(jq -r '.pr_body_lines[0]' <<<"$RESOLVE_OUT")" =~ ^-\ [0-9a-f]{7}\ feat:\ add\ widget$ ]]; then
  pass "A pr_body_lines[0] shape '- <short-sha> <subject>'"
else
  fail "A pr_body_lines[0] shape — got '$(jq -r '.pr_body_lines[0]' <<<"$RESOLVE_OUT")'"
fi

# ===========================================================================
# B — only fix:/chore: commits -> patch bump (not cumulative per-commit)
# ===========================================================================
echo "B: fix|chore -> patch"
B="$TMP/b"; new_repo "$B" 0.39.0
commit_empty "$B" "fix: fix off-by-one"
commit_empty "$B" "chore: bump deps"
sync_origin "$B"
do_resolve "$B"
assert_code "B"            0            "$RESOLVE_CODE"
assert_eq   "B inferred_bump" "patch"   "$(jf inferred_bump)"
assert_eq   "B next_version"  "0.39.1"  "$(jf next_version)"
assert_eq   "B noop"          "false"   "$(jf noop)"
assert_eq   "B unreleased count" "2"    "$(jq -r '.unreleased_commits | length' <<<"$RESOLVE_OUT")"

# ===========================================================================
# C1 — feat!: subject bang -> major bump
# ===========================================================================
echo "C1: feat!: -> major"
C1="$TMP/c1"; new_repo "$C1" 0.39.0
commit_empty "$C1" "feat!: change public api"
sync_origin "$C1"
do_resolve "$C1"
assert_code "C1"            0           "$RESOLVE_CODE"
assert_eq   "C1 inferred_bump" "major"  "$(jf inferred_bump)"
assert_eq   "C1 next_version"  "1.0.0"  "$(jf next_version)"

# ===========================================================================
# C2 — BREAKING CHANGE: in commit body -> major bump
# ===========================================================================
echo "C2: BREAKING CHANGE body -> major"
C2="$TMP/c2"; new_repo "$C2" 0.39.0
commit_empty "$C2" "feat: add x" "BREAKING CHANGE: removes the old flag"
sync_origin "$C2"
do_resolve "$C2"
assert_code "C2"            0           "$RESOLVE_CODE"
assert_eq   "C2 inferred_bump" "major"  "$(jf inferred_bump)"
assert_eq   "C2 next_version"  "1.0.0"  "$(jf next_version)"

# ===========================================================================
# D1 — explicit bump-level override wins over inference (fix-only -> patch
# would be inferred; "major" override forces the major bump). Note:
# inferred_bump in the JSON still reports the *natural* inference — only
# next_version reflects the override.
# ===========================================================================
echo "D1: explicit level override (major) beats inferred patch"
D1="$TMP/d1"; new_repo "$D1" 0.39.0
commit_empty "$D1" "fix: patch-only change"
sync_origin "$D1"
do_resolve "$D1" major
assert_code "D1"            0           "$RESOLVE_CODE"
assert_eq   "D1 inferred_bump (unchanged)" "patch" "$(jf inferred_bump)"
assert_eq   "D1 next_version (overridden)" "1.0.0" "$(jf next_version)"

# ===========================================================================
# D2 — explicit X.Y.Z override wins over inference
# ===========================================================================
echo "D2: explicit X.Y.Z override"
D2="$TMP/d2"; new_repo "$D2" 0.39.0
commit_empty "$D2" "fix: patch-only change"
sync_origin "$D2"
do_resolve "$D2" 2.5.0
assert_code "D2"            0           "$RESOLVE_CODE"
assert_eq   "D2 next_version" "2.5.0"   "$(jf next_version)"

# ===========================================================================
# E — noop: zero unreleased commits since last tag
# ===========================================================================
echo "E: noop when nothing unreleased"
E="$TMP/e"; new_repo "$E" 0.39.0
sync_origin "$E"
do_resolve "$E"
assert_code "E"            0            "$RESOLVE_CODE"
assert_eq   "E noop"          "true"    "$(jf noop)"
assert_eq   "E next_version"  "0.39.0"  "$(jf next_version)"
assert_eq   "E inferred_bump" "null"    "$(jf inferred_bump)"
assert_eq   "E refuse_reason" "null"    "$(jf refuse_reason)"
assert_eq   "E unreleased count" "0"    "$(jq -r '.unreleased_commits | length' <<<"$RESOLVE_OUT")"

# ===========================================================================
# F — refusal: dirty working tree at <project>
# ===========================================================================
echo "F: refuse on dirty working tree"
F="$TMP/f"; new_repo "$F" 0.39.0
commit_empty "$F" "feat: add y"
sync_origin "$F"
echo "untracked scratch" > "$F/dirty.txt"
do_resolve "$F"
assert_code "F"             1          "$RESOLVE_CODE"
assert_eq   "F noop"          "false"  "$(jf noop)"
if [[ "$(jf refuse_reason)" == *"dirty working tree"* ]]; then
  pass "F refuse_reason mentions dirty working tree"
else
  fail "F refuse_reason — got '$(jf refuse_reason)'"
fi

# ===========================================================================
# G — refusal: local main behind origin/main
# ===========================================================================
echo "G: refuse when local main is behind origin/main"
G="$TMP/g"; new_repo "$G" 0.39.0
init_sha="$(git -C "$G" rev-parse HEAD)"
commit_empty "$G" "feat: commit only origin has seen"
ahead_sha="$(git -C "$G" rev-parse HEAD)"
git -C "$G" reset --hard -q "$init_sha"
sync_origin "$G" "$ahead_sha"
do_resolve "$G"
assert_code "G"             1          "$RESOLVE_CODE"
if [[ "$(jf refuse_reason)" == *"behind origin/main"* ]]; then
  pass "G refuse_reason mentions local main behind origin/main"
else
  fail "G refuse_reason — got '$(jf refuse_reason)'"
fi

# ===========================================================================
# H — refusal: resolved next_version does not advance past current
# (explicit override equal to current — the <= boundary)
# ===========================================================================
echo "H: refuse when next_version does not advance past current"
H="$TMP/h"; new_repo "$H" 0.39.0
commit_empty "$H" "fix: irrelevant"
sync_origin "$H"
do_resolve "$H" 0.39.0
assert_code "H"             1          "$RESOLVE_CODE"
if [[ "$(jf refuse_reason)" == *"does not advance past current"* ]]; then
  pass "H refuse_reason mentions next_version not advancing"
else
  fail "H refuse_reason — got '$(jf refuse_reason)'"
fi
assert_eq   "H next_version (surfaced despite refusal)" "0.39.0" "$(jf next_version)"

# ===========================================================================
# Result
# ===========================================================================
echo ""
if [ "$fails" -eq 0 ]; then
  echo "atelier-release-resolve (#43): all assertions passed."
  exit 0
else
  echo "atelier-release-resolve (#43): $fails assertion(s) failed."
  exit 1
fi
