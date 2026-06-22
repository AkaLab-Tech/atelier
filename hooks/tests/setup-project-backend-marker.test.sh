#!/usr/bin/env bash
#
# Regression test for M9.3a — setup-project backend detection / marker.
# `scripts/atelier-setup-project`'s detect_backend_status() reads an existing
# .roadmap.json (jq -r '.backend // "files"'), defaults to "files" when the
# file is absent, jq is unavailable, or the value is empty/null, and emits
# `atelier-backend=<value>` in the marker block.
#
# Test strategy (mirrors setup-project-roadmap-format-f74.test.sh):
#   Phase A — extract detect_backend_status() and drive it directly against
#             throwaway .roadmap.json files, covering all four marker cases.
#   Phase B — extract step_roadmap_files() and drive it directly to assert
#             the §5 tracking files are still written (files-path no-regression).
#   Both phases are hermetic: temp dirs, no network, no real project root.
#
# Run:  hooks/tests/setup-project-backend-marker.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-setup-project"

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# ============================================================
# Phase A — detect_backend_status() unit tests
# ============================================================

FN_DETECT="$TMP/detect_backend_status.sh"
awk '/^detect_backend_status\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SCRIPT" > "$FN_DETECT"
if ! grep -q 'roadmap.json' "$FN_DETECT"; then
  echo "  FAIL: could not extract detect_backend_status() from $SCRIPT"
  exit 1
fi
# shellcheck disable=SC1090
source "$FN_DETECT"

# assert_backend <expected> <label> ; uses global PROJECT
assert_backend() {
  local expected="$1" label="$2" got
  got="$(detect_backend_status)"
  if [ "$got" = "$expected" ]; then
    pass "$label (=$got)"
  else
    fail "$label: expected '$expected', got '$got'"
  fi
}

mkproj() { local d="$TMP/$1"; mkdir -p "$d"; printf '%s' "$d"; }

# --- case 1: no .roadmap.json → files (and file must not have been created) ---
PROJECT="$(mkproj c1)"
assert_backend files "absent .roadmap.json → files"
if [ ! -f "$PROJECT/.roadmap.json" ]; then
  pass "no .roadmap.json created in the temp dir (files is the no-op path)"
else
  fail ".roadmap.json was unexpectedly created by detect_backend_status()"
fi

# --- case 2: pre-existing {"backend":"github-project"} → github-project -------
PROJECT="$(mkproj c2)"
printf '{"backend":"github-project"}' > "$PROJECT/.roadmap.json"
assert_backend github-project 'pre-existing backend=github-project → github-project'

# --- case 3: pre-existing {"backend":"linear"} → linear -----------------------
PROJECT="$(mkproj c3)"
printf '{"backend":"linear"}' > "$PROJECT/.roadmap.json"
assert_backend linear 'pre-existing backend=linear → linear'

# --- case 4: .roadmap.json with no backend key → files (fail-open) -----------
PROJECT="$(mkproj c4)"
printf '{}' > "$PROJECT/.roadmap.json"
assert_backend files 'no backend key in .roadmap.json → files (fail-open)'

# --- case 4b: explicit backend=files in .roadmap.json → files ----------------
PROJECT="$(mkproj c4b)"
printf '{"backend":"files"}' > "$PROJECT/.roadmap.json"
assert_backend files 'explicit backend=files → files'

# --- case 4c: malformed JSON → files (fail-open) -----------------------------
PROJECT="$(mkproj c4c)"
printf 'not json{' > "$PROJECT/.roadmap.json"
assert_backend files 'malformed JSON → files (fail-open)'

# ============================================================
# Phase B — step_roadmap_files() no-regression test
# Verifies the §5 tracking-file layout is still written correctly
# even after the detect_backend_status() addition to the marker block.
# ============================================================

FN_ROADMAP="$TMP/step_roadmap_files.sh"
awk '/^step_roadmap_files\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SCRIPT" > "$FN_ROADMAP"
if ! grep -q 'ROADMAP.md' "$FN_ROADMAP"; then
  echo "  FAIL: could not extract step_roadmap_files() from $SCRIPT"
  exit 1
fi

# Provide the status variables that step_roadmap_files() mutates and reads.
# shellcheck disable=SC2034
ROADMAP_STATUS=""
# shellcheck disable=SC2034
INPROGRESS_STATUS=""
# shellcheck disable=SC2034
HISTORY_STATUS=""
# shellcheck disable=SC2034
PROJECT_NAME="test-project"

# shellcheck disable=SC1090
source "$FN_ROADMAP"

PROJECT="$(mkproj p_roadmap)"

# Run with a clean project dir — should create all three files.
step_roadmap_files

if [ -f "$PROJECT/ROADMAP.md" ]; then
  pass "files-path no-regression: ROADMAP.md created"
else
  fail "files-path no-regression: ROADMAP.md NOT created"
fi

if [ -f "$PROJECT/IN_PROGRESS.md" ]; then
  pass "files-path no-regression: IN_PROGRESS.md created"
else
  fail "files-path no-regression: IN_PROGRESS.md NOT created"
fi

if [ -f "$PROJECT/HISTORY.md" ]; then
  pass "files-path no-regression: HISTORY.md created"
else
  fail "files-path no-regression: HISTORY.md NOT created"
fi

# Verify ROADMAP.md has the §5 P0/P1/P2 priority headings.
if grep -Eq '^## 🔥 P0' "$PROJECT/ROADMAP.md" && \
   grep -Eq '^## 🎯 P1' "$PROJECT/ROADMAP.md" && \
   grep -Eq '^## 💭 P2' "$PROJECT/ROADMAP.md"; then
  pass "files-path no-regression: ROADMAP.md contains §5 P0/P1/P2 headings"
else
  fail "files-path no-regression: ROADMAP.md missing §5 P0/P1/P2 headings"
fi

# No .roadmap.json should have been created by step_roadmap_files().
if [ ! -f "$PROJECT/.roadmap.json" ]; then
  pass "files-path no-regression: .roadmap.json not created by step_roadmap_files()"
else
  fail "files-path no-regression: .roadmap.json unexpectedly created by step_roadmap_files()"
fi

# ============================================================
# Result
# ============================================================
echo ""
if [ "$fails" -eq 0 ]; then
  echo "setup-project backend marker (M9.3a): all assertions passed."
  exit 0
else
  echo "setup-project backend marker (M9.3a): $fails assertion(s) failed."
  exit 1
fi
