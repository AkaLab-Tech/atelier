#!/usr/bin/env bash
#
# Test for atelier-workspace-status (task #22b): mixed-backend workspace
# aggregation. Covers:
#   1. MIXED-BACKEND DEGRADATION: files + non-files (github-project) member.
#      - JSON: non-files openTasks=null, roadmapFormat=backend-name, backend=backend-name.
#      - JSON: files openTasks numeric, roadmapFormat file-derived, backend="files".
#      - Human render: non-files shows "backend:<name>", NOT "0" or "absent".
#        Non-files member NOT in S_NONSEC5 footer (no false alarm).
#   2. BACKEND JSON FIELD: every member object carries a `backend` field; the
#      crossRepoBlocked array shape (member/task/title/blocker/verdict) is preserved.
#   3. BACKEND-DEFERRED HANDLING: stubbed atelier-resolve-dep exits 6 → verdict
#      "backend-deferred" appears in the blocked section and is counted unsatisfied.
#      Stubbed exit-0 blocker (satisfied) is omitted.
#   4. FILES-ONLY NO-REGRESSION: all-files workspace → human render has no
#      "backend:<name>" leak; openTasks stays numeric; roadmapFormat stays
#      file-derived; each JSON member now carries backend="files".
#
# Run:  hooks/tests/workspace-status-mixed-backend.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-workspace-status"
TASK_BACKEND_REAL="$REPO_ROOT/scripts/atelier-task-backend"
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/cfg"; mkdir -p "$CFG"
BIN="$TMP/bin"; mkdir -p "$BIN"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has()   { printf '%s' "$1" | grep -qF "$2"  && pass "$3" || fail "$3 (missing: [$2])"; }
lacks() { printf '%s' "$1" | grep -qF "$2"  && fail "$3 (unexpected: [$2])" || pass "$3"; }

# ---------------------------------------------------------------------------
# Scaffold helpers
# ---------------------------------------------------------------------------

mkmember() {   # <dir> [roadmap-content] [inprogress-content]
  local d="$1"; mkdir -p "$d/.claude"
  printf '{}' > "$d/.claude/settings.json"
  printf '{}' > "$d/.atelier.json"
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$d/ROADMAP.md" || true
  [ -n "${3:-}" ] && printf '%s\n' "$3" > "$d/IN_PROGRESS.md" || true
}

# Place the real atelier-task-backend first on PATH so the script resolves it.
# This avoids the sibling-fallback path depending on the CWD being the scripts dir.
ln -sf "$TASK_BACKEND_REAL" "$BIN/atelier-task-backend"

# ---------------------------------------------------------------------------
# Section 1 + 2 + partial 4: mixed-backend workspace
# ---------------------------------------------------------------------------
# Member F: files backend (default — no .roadmap.json).
MF="$TMP/mf"
mkmember "$MF" \
  "# Roadmap
## 🎯 P1 — Next
- [ ] \`feat\` do the thing \`#3\`" \
  "# In Progress
- [ ] Some task in flight"

# Member G: github-project backend.
MG="$TMP/mg"
mkmember "$MG" "" ""
printf '{"backend":"github-project"}\n' > "$MG/.roadmap.json"

jq -n --arg root "$TMP" --arg mf "$MF" --arg mg "$MG" \
  '{workspaces:{mixws:{
    name:"mixws", root:$root,
    members:[
      {path:$mf, token:"repo-files",  role:"member"},
      {path:$mg, token:"repo-ghproj", role:"member"}
    ]
  }}}' > "$CFG/workspaces.json"

# --- 1a: JSON fields for the non-files member ---
J="$(ATELIER_CONFIG_DIR="$CFG" PATH="$BIN:$PATH" bash "$SCRIPT" mixws --json 2>&1)"

# non-files: openTasks must be JSON null (not 0, not a string)
NF_OT="$(printf '%s' "$J" | jq -r '.members[] | select(.token=="repo-ghproj") | .openTasks')"
[ "$NF_OT" = "null" ] \
  && pass "non-files member: openTasks is JSON null (not 0)" \
  || fail "non-files member: openTasks should be null, got '$NF_OT'"

# non-files: roadmapFormat must equal the backend name "github-project"
NF_RF="$(printf '%s' "$J" | jq -r '.members[] | select(.token=="repo-ghproj") | .roadmapFormat')"
[ "$NF_RF" = "github-project" ] \
  && pass "non-files member: roadmapFormat='github-project'" \
  || fail "non-files member: roadmapFormat should be 'github-project', got '$NF_RF'"

# non-files: backend field must equal "github-project"
NF_BK="$(printf '%s' "$J" | jq -r '.members[] | select(.token=="repo-ghproj") | .backend')"
[ "$NF_BK" = "github-project" ] \
  && pass "non-files member: backend='github-project'" \
  || fail "non-files member: backend should be 'github-project', got '$NF_BK'"

# --- 1b: JSON fields for the files member ---

# files: openTasks must be numeric (jq type "number")
F_OT_TYPE="$(printf '%s' "$J" | jq -r '.members[] | select(.token=="repo-files") | .openTasks | type')"
[ "$F_OT_TYPE" = "number" ] \
  && pass "files member: openTasks is numeric (type=$F_OT_TYPE)" \
  || fail "files member: openTasks should be numeric, got type '$F_OT_TYPE'"

# files: roadmapFormat must be conforming/non-conforming/absent (file-derived, not a backend name)
F_RF="$(printf '%s' "$J" | jq -r '.members[] | select(.token=="repo-files") | .roadmapFormat')"
case "$F_RF" in
  conforming|non-conforming|absent)
    pass "files member: roadmapFormat='$F_RF' (file-derived)" ;;
  *)
    fail "files member: roadmapFormat should be file-derived, got '$F_RF'" ;;
esac

# files: backend field must be "files"
F_BK="$(printf '%s' "$J" | jq -r '.members[] | select(.token=="repo-files") | .backend')"
[ "$F_BK" = "files" ] \
  && pass "files member: backend='files'" \
  || fail "files member: backend should be 'files', got '$F_BK'"

# --- 2: backend field present on EVERY member; crossRepoBlocked shape preserved ---

ALL_HAVE_BK="$(printf '%s' "$J" | jq '[.members[] | has("backend")] | all')"
[ "$ALL_HAVE_BK" = "true" ] \
  && pass "all member objects carry a 'backend' field" \
  || fail "some member objects are missing the 'backend' field"

# crossRepoBlocked is an array (even when empty)
XRB_TYPE="$(printf '%s' "$J" | jq -r '.crossRepoBlocked | type')"
[ "$XRB_TYPE" = "array" ] \
  && pass "crossRepoBlocked is a JSON array" \
  || fail "crossRepoBlocked should be an array, got '$XRB_TYPE'"

# shape guard: if non-empty, every element has the five required keys
XRB_LEN="$(printf '%s' "$J" | jq '.crossRepoBlocked | length')"
if [ "$XRB_LEN" -gt 0 ]; then
  SHAPE_OK="$(printf '%s' "$J" | jq '[.crossRepoBlocked[] | (has("member") and has("task") and has("title") and has("blocker") and has("verdict"))] | all')"
  [ "$SHAPE_OK" = "true" ] \
    && pass "crossRepoBlocked elements have all 5 required keys (member/task/title/blocker/verdict)" \
    || fail "crossRepoBlocked elements are missing one or more of: member/task/title/blocker/verdict"
else
  pass "crossRepoBlocked is empty — shape guard skipped (no rows to check)"
fi

# --- 1c: Human dashboard — non-files member renders "backend:<name>" ---
H="$(ATELIER_CONFIG_DIR="$CFG" NO_COLOR=1 PATH="$BIN:$PATH" bash "$SCRIPT" mixws 2>&1)"

has   "$H" "backend:github-project"       "human render: non-files member shows 'backend:github-project' in output"
lacks "$H" "open 0  "                     "human render: non-files member does NOT show 'open 0' (misleading zero)"
lacks "$H" "roadmap §5: no"               "human render: non-files member does NOT show 'roadmap §5: no' (false alarm)"
lacks "$H" "1 member(s) not §5 (repo-ghproj)" "human render: non-files member is NOT in S_NONSEC5 footer"

# The "not §5" footer bullet must not mention repo-ghproj (non-files members are excluded).
# We check that the footer line containing "not §5" does not contain "repo-ghproj".
if printf '%s' "$H" | grep -F "not §5" | grep -qF "repo-ghproj"; then
  fail "footer 'not §5' line names repo-ghproj (non-files member should be excluded from S_NONSEC5)"
else
  pass "footer 'not §5' line does NOT name repo-ghproj (non-files member excluded from S_NONSEC5)"
fi

# roadmap §5: backend:<name> line must appear for the non-files member
has "$H" "roadmap §5: backend:github-project" "human render: non-files member shows 'roadmap §5: backend:github-project'"

# ---------------------------------------------------------------------------
# Section 3: BACKEND-DEFERRED handling
# ---------------------------------------------------------------------------
# Member B: files backend with an unchecked ROADMAP line blocked by a token
#   whose atelier-resolve-dep will exit 6 (backend-deferred).
# Member S: a satisfied blocker (exit 0) that must be omitted from output.

MB="$TMP/mb"
mkmember "$MB" \
  "# Roadmap
## 🎯 P1 — Next
- [ ] \`feat\` cross-repo thing \`#11\` blocked_by:remote-ghproj#42,remote-satisfied#7" \
  "# In Progress
(no tasks)"

# We need a workspace.json that includes MB.
# For atelier-resolve-dep --from "$MB", the script reverse-looks up which workspace
# MB belongs to. So MB must be in the workspace.
jq -n --arg root "$TMP" --arg mb "$MB" \
  '{workspaces:{blockedws:{
    name:"blockedws", root:$root,
    members:[
      {path:$mb, token:"repo-blocker-owner", role:"member"}
    ]
  }}}' > "$CFG/workspaces2.json"

# Stub atelier-resolve-dep: dispatch on the --token argument.
# remote-ghproj  → backend-deferred (exit 6)
# remote-satisfied → satisfied (exit 0)
# anything else  → open (exit 3)
cat > "$BIN/atelier-resolve-dep" <<'STUB'
#!/usr/bin/env bash
# Stub: parse --token to decide verdict.
token=""
while [ $# -gt 0 ]; do
  case "$1" in
    --token) token="${2:-}"; shift 2 ;;
    --token=*) token="${1#--token=}"; shift ;;
    *) shift ;;
  esac
done
case "$token" in
  remote-ghproj)     printf 'backend-deferred\n'; exit 6 ;;
  remote-satisfied)  printf 'satisfied\n';         exit 0 ;;
  *)                 printf 'open\n';              exit 3 ;;
esac
STUB
chmod +x "$BIN/atelier-resolve-dep"

# Run with the secondary config (workspaces2.json).
BJ="$(ATELIER_CONFIG_DIR="$CFG" PATH="$BIN:$PATH" \
      bash "$SCRIPT" blockedws --json \
      --from /dev/null 2>&1)" || true
# blockedws workspace: run directly by slug.
BJ="$(ATELIER_CONFIG_DIR="$CFG" PATH="$BIN:$PATH" \
      bash -c "ATELIER_CONFIG_DIR='$CFG/'; cp '$CFG/workspaces2.json' '$CFG/workspaces.json.bak' 2>/dev/null; true")" || true

# Replace workspaces.json with the blockedws config for this section.
cp "$CFG/workspaces.json" "$CFG/workspaces-orig.json"
cp "$CFG/workspaces2.json" "$CFG/workspaces.json"

set +e
BJ="$(ATELIER_CONFIG_DIR="$CFG" PATH="$BIN:$PATH" bash "$SCRIPT" blockedws --json 2>&1)"
BJrc=$?
set -e

[ "$BJrc" -eq 0 ] \
  && pass "backend-deferred workspace: script exits 0" \
  || fail "backend-deferred workspace: script exited $BJrc (expected 0)"

# backend-deferred blocker must appear in crossRepoBlocked
BD_COUNT="$(printf '%s' "$BJ" | jq '[.crossRepoBlocked[] | select(.verdict=="backend-deferred")] | length')"
[ "$BD_COUNT" -ge 1 ] \
  && pass "backend-deferred: at least one crossRepoBlocked entry has verdict='backend-deferred'" \
  || fail "backend-deferred: expected verdict='backend-deferred' in crossRepoBlocked, found $BD_COUNT"

# The backend-deferred blocker must be COUNTED (included in the row) — it is unsatisfied.
XRB_TOTAL="$(printf '%s' "$BJ" | jq '.crossRepoBlocked | length')"
[ "$XRB_TOTAL" -ge 1 ] \
  && pass "backend-deferred: crossRepoBlocked total >= 1 (counted unsatisfied, not dropped)" \
  || fail "backend-deferred: crossRepoBlocked total should be >=1, got $XRB_TOTAL"

# Satisfied blocker must be OMITTED — remote-satisfied exits 0, so it should not appear.
SAT_COUNT="$(printf '%s' "$BJ" | jq '[.crossRepoBlocked[] | select(.blocker | startswith("remote-satisfied"))] | length')"
[ "$SAT_COUNT" -eq 0 ] \
  && pass "backend-deferred: satisfied blocker (remote-satisfied) is omitted from crossRepoBlocked" \
  || fail "backend-deferred: satisfied blocker should be omitted but $SAT_COUNT row(s) found"

# Human dashboard must show the backend-deferred row.
set +e
BH="$(ATELIER_CONFIG_DIR="$CFG" NO_COLOR=1 PATH="$BIN:$PATH" bash "$SCRIPT" blockedws 2>&1)"
set -e
has "$BH" "backend-deferred" "backend-deferred: human dashboard shows 'backend-deferred' verdict"

# Restore original workspaces.json.
cp "$CFG/workspaces-orig.json" "$CFG/workspaces.json"

# ---------------------------------------------------------------------------
# Section 4: FILES-ONLY no-regression (additive backend:"files" + no leak)
# ---------------------------------------------------------------------------
# Build a purely files-only workspace (both members default to files backend).
FF1="$TMP/ff1"
mkmember "$FF1" \
  "# Roadmap
## 🎯 P1 — Next
- [ ] \`feat\` item one \`#1\`" \
  "# In Progress
(no tasks)"
FF2="$TMP/ff2"
mkmember "$FF2" \
  "# Roadmap
## Backlog
### TASK-5 — Prioridad Alta" \
  "# In Progress
(no tasks)"

jq -n --arg root "$TMP" --arg f1 "$FF1" --arg f2 "$FF2" \
  '{workspaces:{filesonly:{
    name:"filesonly", root:$root,
    members:[
      {path:$f1, token:"repo-a", role:"member"},
      {path:$f2, token:"repo-b", role:"member"}
    ]
  }}}' > "$CFG/workspaces.json"

FJ="$(ATELIER_CONFIG_DIR="$CFG" PATH="$BIN:$PATH" bash "$SCRIPT" filesonly --json 2>&1)"

# All files members carry backend="files"
ALL_FILES_BK="$(printf '%s' "$FJ" | jq '[.members[] | .backend == "files"] | all')"
[ "$ALL_FILES_BK" = "true" ] \
  && pass "files-only: all members carry backend='files'" \
  || fail "files-only: expected all members to have backend='files'; got $(printf '%s' "$FJ" | jq '[.members[].backend]')"

# openTasks stays numeric for both members
ALL_OT_NUM="$(printf '%s' "$FJ" | jq '[.members[] | .openTasks | type == "number"] | all')"
[ "$ALL_OT_NUM" = "true" ] \
  && pass "files-only: all members have numeric openTasks" \
  || fail "files-only: some member has non-numeric openTasks"

# roadmapFormat stays file-derived (conforming/non-conforming/absent) — never a backend name
ALL_RF_OK="$(printf '%s' "$FJ" | jq '[.members[] | .roadmapFormat | (. == "conforming" or . == "non-conforming" or . == "absent")] | all')"
[ "$ALL_RF_OK" = "true" ] \
  && pass "files-only: all members have file-derived roadmapFormat (conforming|non-conforming|absent)" \
  || fail "files-only: some member has non-file-derived roadmapFormat; got $(printf '%s' "$FJ" | jq '[.members[].roadmapFormat]')"

# Human dashboard must contain NO "backend:<anything>" cell in the open-count line.
# The human render uses "backend:<name>" only in the non-files branch; files branch
# shows a plain numeric open count. Neither "backend:github-project" nor any
# "backend:" substring should appear in a files-only render.
FH="$(ATELIER_CONFIG_DIR="$CFG" NO_COLOR=1 PATH="$BIN:$PATH" bash "$SCRIPT" filesonly 2>&1)"

# The open-count cells show "open <number>" — grep that none say "open backend:"
if printf '%s' "$FH" | grep -qE 'open[[:space:]]+backend:'; then
  fail "files-only: human render contains 'open backend:' in the open-count cell (non-files code path leaked)"
else
  pass "files-only: human render has no 'open backend:' cell (files branch only)"
fi

# No "roadmap §5: backend:" line should appear.
lacks "$FH" "roadmap §5: backend:" "files-only: human render has no 'roadmap §5: backend:' line"

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "workspace-status-mixed-backend: all assertions passed."
  exit 0
else
  echo "workspace-status-mixed-backend: $fails assertion(s) failed."
  exit 1
fi
