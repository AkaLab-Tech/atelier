#!/usr/bin/env bash
#
# Regression test for M7.1.F74 — onboarding must flag a non-§5 ROADMAP.md
# REGARDLESS of IN_PROGRESS.md state. `atelier-setup-project`'s
# detect_roadmap_format() emits the `atelier-roadmap-format=` signal that
# /setup-project Phase 3b reads to offer `/adopt-roadmap --format atelier`.
#
# Hermetic: extracts the detect_roadmap_format() function from
# scripts/atelier-setup-project and drives it directly against throwaway
# ROADMAP.md files under a temp dir. No network, no plugin root, no jq —
# the function only reads $PROJECT/ROADMAP.md and $ROADMAP_STATUS.
#
# Run:  hooks/tests/setup-project-roadmap-format-f74.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-setup-project"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# --- extract the function under test ---------------------------------------
FN="$TMP/detect_roadmap_format.sh"
awk '/^detect_roadmap_format\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SCRIPT" > "$FN"
if ! grep -q "printf 'non-conforming" "$FN"; then
  echo "  FAIL: could not extract detect_roadmap_format() from $SCRIPT"
  exit 1
fi
# shellcheck disable=SC1090
source "$FN"

# --- harness ----------------------------------------------------------------
# assert_format <expected> <label> ; uses globals PROJECT + ROADMAP_STATUS
assert_format() {
  local expected="$1" label="$2" got
  got="$(detect_roadmap_format)"
  if [ "$got" = "$expected" ]; then pass "$label (=$got)"; else fail "$label: expected '$expected', got '$got'"; fi
}

mkproj() { local d="$TMP/$1"; mkdir -p "$d"; printf '%s' "$d"; }

# --- case 1: §5 ROADMAP with emoji priority heading -> conforming ----------
PROJECT="$(mkproj p1)"; ROADMAP_STATUS="preserved"
cat > "$PROJECT/ROADMAP.md" <<'MD'
# Roadmap
## 🎯 P1 — Next
- [ ] `feat` Add thing `#12` `~2h`
MD
assert_format conforming "§5 ROADMAP (emoji P1 heading)"

# --- case 2: §5 ROADMAP, plain heading no emoji -> conforming --------------
PROJECT="$(mkproj p2)"; ROADMAP_STATUS="preserved"
cat > "$PROJECT/ROADMAP.md" <<'MD'
# Roadmap
## P0 — Blockers
(None.)
MD
assert_format conforming "§5 ROADMAP (plain P0 heading, no emoji)"

# --- case 3: foreign format (deminut-spa shape) -> non-conforming ----------
PROJECT="$(mkproj p3)"; ROADMAP_STATUS="preserved"
cat > "$PROJECT/ROADMAP.md" <<'MD'
# Roadmap
## Backlog
### TASK-68: Store Logo — Prioridad Alta
- [ ] Upload
MD
assert_format non-conforming "foreign ROADMAP (Backlog / TASK-NN / Prioridad Alta)"

# --- case 4: High/Med/Low layout (atelier's own / crt default) -> non-conf -
PROJECT="$(mkproj p4)"; ROADMAP_STATUS="preserved"
cat > "$PROJECT/ROADMAP.md" <<'MD'
# Roadmap
## High Priority
## Phase 8 — Multi-repo workspaces
## Low Priority / Ideas
MD
assert_format non-conforming "High/Med/Low layout (no P0/P1/P2; 'Phase' must not match)"

# --- case 5: freshly-created template -> conforming by construction --------
PROJECT="$(mkproj p5)"; ROADMAP_STATUS="created"
# no ROADMAP.md on disk, or any content — `created` short-circuits to conforming
assert_format conforming "freshly-created ROADMAP (ROADMAP_STATUS=created)"

# --- case 6: no ROADMAP.md at all -> absent --------------------------------
PROJECT="$(mkproj p6)"; ROADMAP_STATUS="preserved"
assert_format absent "missing ROADMAP.md"

# --- result -----------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "F74 detect_roadmap_format: all assertions passed."
  exit 0
else
  echo "F74 detect_roadmap_format: $fails assertion(s) failed."
  exit 1
fi
