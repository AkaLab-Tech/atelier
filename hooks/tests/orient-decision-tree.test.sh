#!/usr/bin/env bash
#
# Test for atelier-orient's priority decision tree (TASK_016 Phase 1). Drives the
# real helper against synthetic project / workspace dirs and asserts the headline
# suggestion for each state. Filesystem + jq only (the helper does no network).
#
# Run:  hooks/tests/orient-decision-tree.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ORIENT="$REPO_ROOT/scripts/atelier-orient"
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

# Resolve symlinks (macOS /var → /private/var) so synthetic registry paths match
# what atelier-orient sees after its own `pwd -P` canonicalization.
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/cfg"; mkdir -p "$CFG"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
# orient <dir> | assert <label> <substring>
run()    { ATELIER_CONFIG_DIR="$CFG" bash "$ORIENT" "$1" 2>&1; }
chk()    { printf '%s' "$1" | grep -qF "$3" && pass "$2" || fail "$2 (want: $3)"; }

mkcfgd() { local d="$1"; mkdir -p "$d/.claude" "$d/.git"; echo '{}' > "$d/.claude/settings.json"; echo '{}' > "$d/.atelier.json"; }

# --- build dirs ---
mkdir -p "$TMP/nogit"
mkdir -p "$TMP/multi/a/.git" "$TMP/multi/b/.git"
mkdir -p "$TMP/bare/.git"
mkcfgd "$TMP/s5ready"; printf '# Roadmap\n## 🎯 P1 — Next\n- [ ] `feat` thing `#1` [ready]\n' > "$TMP/s5ready/ROADMAP.md"; printf '# In Progress\n' > "$TMP/s5ready/IN_PROGRESS.md"
mkcfgd "$TMP/s5plan";  printf '# Roadmap\n## 🎯 P1 — Next\n- [ ] `feat` thing `#1`\n'        > "$TMP/s5plan/ROADMAP.md";  printf '# In Progress\n' > "$TMP/s5plan/IN_PROGRESS.md"
mkcfgd "$TMP/foreign"; printf '# Roadmap\n## Backlog\n### TASK-1 — Prioridad Alta\n'          > "$TMP/foreign/ROADMAP.md"; printf '# In Progress\n' > "$TMP/foreign/IN_PROGRESS.md"
mkcfgd "$TMP/hml";     printf '# Roadmap\n## High Priority\n## Low Priority / Ideas\n'         > "$TMP/hml/ROADMAP.md";     printf '# In Progress\n' > "$TMP/hml/IN_PROGRESS.md"
mkcfgd "$TMP/inprog";  printf '# Roadmap\n## 🎯 P1 — Next\n- [ ] `feat` x `#1` [ready]\n'      > "$TMP/inprog/ROADMAP.md";  printf '# In Progress\n- [ ] Wire the widget\n' > "$TMP/inprog/IN_PROGRESS.md"
mkcfgd "$TMP/drift";   printf '# Roadmap\n## 🎯 P1 — Next\n- [ ] `feat` x `#1` [ready]\n'      > "$TMP/drift/ROADMAP.md";   printf '# In Progress\n' > "$TMP/drift/IN_PROGRESS.md"
mkdir -p "$TMP/wsroot"
# non-files backend (github-project): configured, not in-progress, NO ROADMAP.md /
# IN_PROGRESS.md — regresses issue #322 (used to print the false "No ROADMAP.md yet.")
mkcfgd "$TMP/ghproj";  printf '{"backend":"github-project"}\n' > "$TMP/ghproj/.roadmap.json"

# registry: drift dir on an ancient version, the rest on a future one (no drift)
jq -n --arg r "$TMP/s5ready" --arg p "$TMP/s5plan" --arg f "$TMP/foreign" --arg h "$TMP/hml" --arg i "$TMP/inprog" --arg d "$TMP/drift" --arg g "$TMP/ghproj" '{projects:{
  ($r):{setupVersion:"99.0.0"},($p):{setupVersion:"99.0.0"},($f):{setupVersion:"99.0.0"},
  ($h):{setupVersion:"99.0.0"},($i):{setupVersion:"99.0.0"},($d):{setupVersion:"0.0.1"},
  ($g):{setupVersion:"99.0.0"}
}}' > "$CFG/projects.json"
jq -n --arg root "$TMP/wsroot" '{workspaces:{ wt:{name:"wt", root:$root, members:[]} }}' > "$CFG/workspaces.json"

chk "$(run "$TMP/nogit")"   "not a git repo → git init"          "Not a git repository"
chk "$(run "$TMP/multi")"   "multi-repo parent → setup-workspace" "/atelier:setup-workspace --discover ."
chk "$(run "$TMP/bare")"    "bare git repo → setup-project"      "/atelier:setup-project"
chk "$(run "$TMP/s5ready")" "§5 + ready → next-task"             "/atelier:next-task"
chk "$(run "$TMP/s5plan")"  "§5 + unplanned → plan-task"         "/atelier:plan-task"
chk "$(run "$TMP/foreign")" "foreign roadmap → adopt-roadmap"    "/adopt-roadmap --format atelier"
chk "$(run "$TMP/hml")"     "High/Med/Low → no adoption push"    "High/Medium/Low layout"
hml_out="$(run "$TMP/hml")"; printf '%s' "$hml_out" | grep -qF "onboard-workspace" && fail "High/Med/Low must NOT push onboard" || pass "High/Med/Low does not push onboard"
chk "$(run "$TMP/inprog")"  "in-progress → resume-task"          "/atelier:resume-task"
chk "$(run "$TMP/drift")"   "drift → resync note"                "setup v0.0.1 < installed"
chk "$(run "$TMP/wsroot")"  "workspace root → board"             "Root of workspace \"wt\""
chk "$(run "$TMP/ghproj")"  "non-files backend → board message"  "github-project board"
ghproj_out="$(run "$TMP/ghproj")"; printf '%s' "$ghproj_out" | grep -qF "No ROADMAP.md yet." && fail "non-files backend must NOT show No ROADMAP.md yet." || pass "non-files backend does not show No ROADMAP.md yet."

echo ""
if [ "$fails" -eq 0 ]; then echo "orient decision tree: all assertions passed."; exit 0
else echo "orient decision tree: $fails assertion(s) failed."; exit 1; fi
