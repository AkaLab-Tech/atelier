#!/usr/bin/env bash
#
# Test for atelier-list-projects' friendly default render: workspace labels,
# version-drift hints (↻), per-status suggested fixes, and the Suggested footer.
# Also guards that --quiet / --json stay machine-clean (no decoration).
#
# Hermetic: points $ATELIER_CONFIG_DIR at a throwaway dir with a synthetic
# projects.json + workspaces.json, runs the real script with NO_COLOR=1.
#
# Run:  hooks/tests/list-projects-render.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-list-projects"
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/cfg"; mkdir -p "$CFG"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has()  { printf '%s' "$1" | grep -qF "$2" && pass "$3" || fail "$3 (missing: $2)"; }

# configured member with an OLD setupVersion (→ drift ↻)
PA="$TMP/proj-a"; mkdir -p "$PA/.claude"; echo '{}' > "$PA/.claude/settings.json"; echo '{}' > "$PA/.atelier.json"
# registered path that no longer exists (→ missing-directory)
PM="$TMP/proj-gone"

jq -n --arg pa "$PA" --arg pm "$PM" '{
  projects: {
    ($pa): {name:"proj-a", setupVersion:"0.9.0", setupCompleted:"2026-01-02T03:04:05Z"},
    ($pm): {name:"proj-gone", setupVersion:"0.27.0", setupCompleted:"2026-06-01T00:00:00Z"}
  }
}' > "$CFG/projects.json"

jq -n --arg pa "$PA" '{
  workspaces: { ws1: { name:"ws1", root:"/nonexistent-root", members:[ {path:$pa, token:"proj-a", role:"member"} ] } }
}' > "$CFG/workspaces.json"

OUT="$(ATELIER_CONFIG_DIR="$CFG" NO_COLOR=1 bash "$SCRIPT" 2>&1)"

has "$OUT" "Workspaces: ws1 (1)"                         "workspaces overview line"
has "$OUT" "workspace: ws1"                              "member labeled with its workspace"
has "$OUT" "atelier 0.27.0 installed"                    "installed-version banner"
has "$OUT" "↻ set up with v0.9.0"                        "drift hint for old setupVersion"
has "$OUT" "directory no longer exists"                  "missing-directory status"
has "$OUT" "→ atelier-remove-project"                    "suggested fix for missing dir"
has "$OUT" "Suggested:"                                  "suggested-commands footer"
has "$OUT" "resync the 1 project(s) marked"              "footer drift resync hint (count)"

# proj-gone is standalone (not in ws1) → labeled standalone
has "$OUT" "standalone"                                  "non-member labeled standalone"

# --quiet stays clean: exactly the 2 registered paths, nothing else
Q="$(ATELIER_CONFIG_DIR="$CFG" NO_COLOR=1 bash "$SCRIPT" --quiet 2>&1)"
[ "$(printf '%s\n' "$Q" | grep -c .)" = "2" ] && pass "--quiet prints exactly 2 lines" || fail "--quiet line count"
printf '%s' "$Q" | grep -q 'Suggested\|↻\|workspace' && fail "--quiet leaked decoration" || pass "--quiet has no decoration"

# --json stays valid and carries status
J="$(ATELIER_CONFIG_DIR="$CFG" bash "$SCRIPT" --json 2>&1)"
printf '%s' "$J" | jq -e '.projects | length == 2' >/dev/null 2>&1 && pass "--json valid, 2 projects" || fail "--json invalid"
printf '%s' "$J" | jq -e '[.projects[].status] | index("missing-directory")' >/dev/null 2>&1 && pass "--json carries status" || fail "--json status field"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "list-projects render: all assertions passed."; exit 0
else
  echo "list-projects render: $fails assertion(s) failed."; exit 1
fi
