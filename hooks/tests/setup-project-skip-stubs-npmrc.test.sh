#!/usr/bin/env bash
#
# Regression test for #466 — setup-project:
#   C1  step_roadmap_files() creates no ROADMAP/IN_PROGRESS/HISTORY stubs when
#       an existing .roadmap.json names a non-`files` backend; `files` or an
#       absent backend still creates them.
#   C1b step_npmrc() creates no .npmrc without a package.json; creates it with
#       one; never touches an existing complete .npmrc (byte-identical).
#
# Strategy (mirrors setup-project-backend-marker.test.sh): extract the step
# functions from the script and drive them against throwaway project dirs.
#
# Run:  hooks/tests/setup-project-skip-stubs-npmrc.test.sh
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

extract() { awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1} f{print} f&&/^\}/{exit}' "$SCRIPT"; }

for fn in detect_backend_status step_roadmap_files step_npmrc; do
  extract "$fn" > "$TMP/$fn.sh"
  [ -s "$TMP/$fn.sh" ] || { echo "  FAIL: could not extract $fn() from $SCRIPT"; exit 1; }
  # shellcheck disable=SC1090
  source "$TMP/$fn.sh"
done

# shellcheck disable=SC2034
PROJECT_NAME="test-project"
ROADMAP_STATUS=""; INPROGRESS_STATUS=""; HISTORY_STATUS=""; NPMRC_STATUS=""

mkproj() { local d="$TMP/$1"; mkdir -p "$d"; printf '%s' "$d"; }

stubs_present() { [ -e "$PROJECT/ROADMAP.md" ] || [ -e "$PROJECT/IN_PROGRESS.md" ] || [ -e "$PROJECT/HISTORY.md" ]; }

# ---------- C1: tracking stubs ----------
PROJECT="$(mkproj gp)"
printf '{"backend":"github-project"}' > "$PROJECT/.roadmap.json"
step_roadmap_files
if stubs_present; then fail "github-project: stubs were created"; else pass "github-project: no ROADMAP/IN_PROGRESS/HISTORY stubs"; fi
[ "$ROADMAP_STATUS" = "skipped (backend: github-project)" ] && pass "ROADMAP_STATUS = skipped (backend: github-project)" || fail "ROADMAP_STATUS='$ROADMAP_STATUS'"
[ "$INPROGRESS_STATUS" = "skipped (backend: github-project)" ] && pass "INPROGRESS_STATUS skipped" || fail "INPROGRESS_STATUS='$INPROGRESS_STATUS'"
[ "$HISTORY_STATUS" = "skipped (backend: github-project)" ] && pass "HISTORY_STATUS skipped" || fail "HISTORY_STATUS='$HISTORY_STATUS'"

# existing files are never touched under a non-files backend
PROJECT="$(mkproj gp2)"
printf '{"backend":"github-project"}' > "$PROJECT/.roadmap.json"
printf 'mine\n' > "$PROJECT/ROADMAP.md"
step_roadmap_files
[ "$(cat "$PROJECT/ROADMAP.md")" = "mine" ] && pass "github-project: existing ROADMAP.md untouched" || fail "existing ROADMAP.md modified"

PROJECT="$(mkproj files_explicit)"
printf '{"backend":"files"}' > "$PROJECT/.roadmap.json"
step_roadmap_files
if [ -f "$PROJECT/ROADMAP.md" ] && [ -f "$PROJECT/IN_PROGRESS.md" ] && [ -f "$PROJECT/HISTORY.md" ]; then
  pass "backend=files: all three stubs created"
else
  fail "backend=files: stubs missing"
fi

PROJECT="$(mkproj files_absent)"
step_roadmap_files
if [ -f "$PROJECT/ROADMAP.md" ] && [ -f "$PROJECT/IN_PROGRESS.md" ] && [ -f "$PROJECT/HISTORY.md" ]; then
  pass "absent .roadmap.json: all three stubs created"
else
  fail "absent .roadmap.json: stubs missing"
fi

# ---------- C1b: .npmrc ----------
PROJECT="$(mkproj npm_nopkg)"
NPMRC_STATUS=""
step_npmrc
[ ! -e "$PROJECT/.npmrc" ] && pass "no package.json: .npmrc not created" || fail "no package.json: .npmrc created"
[ "$NPMRC_STATUS" = "skipped (no package.json)" ] && pass "NPMRC_STATUS = skipped (no package.json)" || fail "NPMRC_STATUS='$NPMRC_STATUS'"

PROJECT="$(mkproj npm_pkg)"
printf '{"name":"x"}\n' > "$PROJECT/package.json"
NPMRC_STATUS=""
step_npmrc
[ -f "$PROJECT/.npmrc" ] && pass "with package.json: .npmrc created" || fail "with package.json: .npmrc missing"
[ "$NPMRC_STATUS" = "created" ] && pass "NPMRC_STATUS = created" || fail "NPMRC_STATUS='$NPMRC_STATUS'"
for line in ignore-scripts=true minimum-release-age=10080 audit-level=moderate; do
  grep -qxF "$line" "$PROJECT/.npmrc" && pass ".npmrc has $line" || fail ".npmrc lacks $line"
done

# existing complete .npmrc, no package.json: byte-identical, preserved
PROJECT="$(mkproj npm_existing)"
printf '# mine\nignore-scripts=true\nminimum-release-age=10080\naudit-level=moderate\nregistry=https://example.invalid/\n' > "$PROJECT/.npmrc"
cp "$PROJECT/.npmrc" "$TMP/npmrc.before"
NPMRC_STATUS=""
step_npmrc
cmp -s "$PROJECT/.npmrc" "$TMP/npmrc.before" && pass "existing complete .npmrc byte-identical" || fail "existing .npmrc modified"
[ "$NPMRC_STATUS" = "preserved" ] && pass "NPMRC_STATUS = preserved" || fail "NPMRC_STATUS='$NPMRC_STATUS'"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "setup-project skip stubs / .npmrc (#466): all assertions passed."
  exit 0
else
  echo "setup-project skip stubs / .npmrc (#466): $fails assertion(s) failed."
  exit 1
fi
