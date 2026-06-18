#!/usr/bin/env bash
#
# Test for atelier-workspace-status' friendly dashboard: per-member status +
# §5 / drift / in-progress hints, and the synthesized "Suggested next steps"
# footer. Guards that --json stays machine-clean (carries roadmapFormat, no color).
#
# Hermetic: synthetic $ATELIER_CONFIG_DIR (workspaces.json + projects.json) and
# member dirs; runs the real script with NO_COLOR=1.
#
# Run:  hooks/tests/workspace-status-render.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-workspace-status"
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/cfg"; mkdir -p "$CFG"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has()  { printf '%s' "$1" | grep -qF "$2" && pass "$3" || fail "$3 (missing: $2)"; }

mkmember() { # <dir> <roadmap-content> <inprogress-content>
  local d="$1"; mkdir -p "$d/.claude"
  echo '{}' > "$d/.claude/settings.json"; echo '{}' > "$d/.atelier.json"
  printf '%s\n' "$2" > "$d/ROADMAP.md"
  printf '%s\n' "$3" > "$d/IN_PROGRESS.md"
}

# member A: §5 roadmap, occupied in-progress, OLD setupVersion (→ drift ↻)
A="$TMP/api"; mkmember "$A" "# Roadmap
## 🎯 P1 — Next
- [ ] \`feat\` thing \`#1\`" "# In Progress
- [ ] Wire the widget"
# member B: non-§5 roadmap, empty in-progress, current setupVersion (no drift)
B="$TMP/spa"; mkmember "$B" "# Roadmap
## Backlog
### TASK-1 — Prioridad Alta" "# In Progress
(no tasks)"

jq -n --arg a "$A" --arg b "$B" '{projects:{
  ($a):{name:"api", setupVersion:"0.9.0",  setupCompleted:"2026-01-01T00:00:00Z"},
  ($b):{name:"spa", setupVersion:"0.27.0", setupCompleted:"2026-06-01T00:00:00Z"}
}}' > "$CFG/projects.json"

jq -n --arg root "$TMP" --arg a "$A" --arg b "$B" '{workspaces:{ wstest:{
  name:"wstest", root:$root,
  members:[ {path:$a,token:"api",role:"member"}, {path:$b,token:"spa",role:"member"} ]
}}}' > "$CFG/workspaces.json"

OUT="$(ATELIER_CONFIG_DIR="$CFG" NO_COLOR=1 bash "$SCRIPT" wstest 2>&1)"

has "$OUT" "Workspace: wstest"                              "header with slug"
has "$OUT" "2 member(s)"                                    "member count in header"
has "$OUT" "in-progress: Wire the widget   → /atelier:resume-task" "occupied in-progress → resume hint"
has "$OUT" "roadmap §5: no   → /atelier:onboard-workspace wstest"  "non-§5 member → onboard hint"
has "$OUT" "↻ set up with v0.9.0"                          "drift hint for old setupVersion"
has "$OUT" "Suggested next steps"                           "suggested footer present"
has "$OUT" "1 member(s) not §5 (spa)"                       "footer: non-§5 count + names"
has "$OUT" "1 with work in progress (api)"                  "footer: in-progress count + names"
has "$OUT" "on an older setup (api)"                        "footer: drift count + names"
has "$OUT" "task   (from this root"                         "footer: claim/continue via task"
has "$OUT" "full health → atelier-doctor"                   "footer: doctor"

# --json stays clean + carries roadmapFormat, no ANSI
J="$(ATELIER_CONFIG_DIR="$CFG" bash "$SCRIPT" wstest --json 2>&1)"
printf '%s' "$J" | jq -e '.members | length == 2' >/dev/null 2>&1 && pass "--json valid, 2 members" || fail "--json invalid"
printf '%s' "$J" | jq -e '[.members[].roadmapFormat] | index("non-conforming")' >/dev/null 2>&1 && pass "--json carries roadmapFormat" || fail "--json roadmapFormat"
printf '%s' "$J" | grep -q $'\033' && fail "--json leaked ANSI color" || pass "--json has no ANSI"

echo ""
if [ "$fails" -eq 0 ]; then echo "workspace-status render: all assertions passed."; exit 0
else echo "workspace-status render: $fails assertion(s) failed."; exit 1; fi
