#!/usr/bin/env bash
#
# Test for atelier-resolve-dep (task #22a): backend-aware branch.
# Covers:
#   - files backend (absent .roadmap.json): satisfied / open / unknown-id
#   - non-files backend (linear, github-project): backend-deferred / exit 6
#   - unknown-token precedence: exit 4 before backend is consulted
#   - explicit {"backend":"files"} in .roadmap.json == absent .roadmap.json
#
# Run:  bash hooks/tests/resolve-dep-backend.test.sh
# Exit: 0 = all pass, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESOLVE="$REPO_ROOT/scripts/atelier-resolve-dep"
command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CFG="$TMP/config"; mkdir -p "$CFG"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# run_resolve <token> <id> → sets OUT and CODE
# Captures stdout and exit code without tripping set -e.
run_resolve() {
  local token="$1" id="$2"
  set +e
  OUT="$(bash "$RESOLVE" --workspace ws --token "$token" --id "$id" 2>/dev/null)"
  CODE=$?
  set -e
}

# chk_both <expected-stdout> <expected-code> <label>
chk_both() {
  local want_out="$1" want_code="$2" label="$3"
  if [ "$OUT" = "$want_out" ] && [ "$CODE" -eq "$want_code" ]; then
    pass "$label (stdout=$OUT, exit=$CODE)"
  else
    fail "$label: want stdout='$want_out' exit=$want_code  got stdout='$OUT' exit=$CODE"
  fi
}

# ---------- scaffold: member dirs ----------
M_FILES="$TMP/member-files";    mkdir -p "$M_FILES"
M_LINEAR="$TMP/member-linear";  mkdir -p "$M_LINEAR"
M_GHPROJ="$TMP/member-ghproj";  mkdir -p "$M_GHPROJ"
M_XFILES="$TMP/member-xfiles";  mkdir -p "$M_XFILES"   # explicit backend=files

# M_LINEAR: declare linear backend
printf '{"backend":"linear"}\n' > "$M_LINEAR/.roadmap.json"

# M_GHPROJ: declare github-project backend
printf '{"backend":"github-project"}\n' > "$M_GHPROJ/.roadmap.json"

# M_XFILES: explicit backend=files (regression guard)
printf '{"backend":"files"}\n' > "$M_XFILES/.roadmap.json"

# ---------- tracking files for the files-backend member ----------
# HISTORY.md: contains a closed entry anchored by a markdown heading carrying id #7
cat > "$M_FILES/HISTORY.md" <<'HISTEOF'
# History

### feat: widget thing #7

Closed by PR #42.

- [x] Deliver the widget `#7`
HISTEOF

# ROADMAP.md: contains an open entry for id #9 (not closed in HISTORY)
cat > "$M_FILES/ROADMAP.md" <<'ROADEOF'
# Roadmap

## P1 — Next
- [ ] `feat` something `#9`
ROADEOF

# IN_PROGRESS.md: nothing for #9 (ROADMAP is enough)
cat > "$M_FILES/IN_PROGRESS.md" <<'IPEOF'
# In Progress
- [ ] something `#9`
IPEOF

# Regression guard: M_XFILES gets the same tracking as M_FILES
cp "$M_FILES/HISTORY.md" "$M_XFILES/HISTORY.md"
cp "$M_FILES/ROADMAP.md"  "$M_XFILES/ROADMAP.md"
cp "$M_FILES/IN_PROGRESS.md" "$M_XFILES/IN_PROGRESS.md"

# ---------- workspaces.json ----------
# Shape from workspace-status-render.test.sh:
#   .workspaces.<slug>.members[] = [{path, token, role}]
jq -n \
  --arg mf  "$M_FILES" \
  --arg ml  "$M_LINEAR" \
  --arg mgp "$M_GHPROJ" \
  --arg mxf "$M_XFILES" \
  '{workspaces:{ws:{
    name:"ws",
    root: "'"$TMP"'",
    members:[
      {path:$mf,  token:"repo-files",   role:"member"},
      {path:$ml,  token:"repo-linear",  role:"member"},
      {path:$mgp, token:"repo-ghproj",  role:"member"},
      {path:$mxf, token:"repo-xfiles",  role:"member"}
    ]
  }}}' > "$CFG/workspaces.json"

export ATELIER_CONFIG_DIR="$CFG"

# ==========================================================================
# Assertion 1: files backend, id CLOSED in HISTORY.md → satisfied / exit 0
# ==========================================================================
run_resolve repo-files 7
chk_both "satisfied" 0 "files (absent .roadmap.json), id in HISTORY.md → satisfied / exit 0"

# ==========================================================================
# Assertion 2: files backend, id OPEN in ROADMAP/IN_PROGRESS → open / exit 3
# ==========================================================================
run_resolve repo-files 9
chk_both "open" 3 "files backend, id in ROADMAP/IN_PROGRESS → open / exit 3"

# ==========================================================================
# Assertion 3: files backend, id appears NOWHERE → unknown-id / exit 5
# ==========================================================================
run_resolve repo-files 999
chk_both "unknown-id" 5 "files backend, id appears nowhere → unknown-id / exit 5"

# ==========================================================================
# Assertion 4a: linear backend → backend-deferred / exit 6
# ==========================================================================
run_resolve repo-linear 7
chk_both "backend-deferred" 6 "linear backend → backend-deferred / exit 6"

# ==========================================================================
# Assertion 4b: github-project backend → backend-deferred / exit 6
# ==========================================================================
run_resolve repo-ghproj 7
chk_both "backend-deferred" 6 "github-project backend → backend-deferred / exit 6"

# ==========================================================================
# Assertion 5: unknown token → unknown-token / exit 4 (before backend branch)
# ==========================================================================
run_resolve no-such-token 7
chk_both "unknown-token" 4 "unknown token → unknown-token / exit 4 (precedence over backend)"

# ==========================================================================
# Assertion 6: explicit {"backend":"files"} == absent .roadmap.json (regression)
# ==========================================================================
run_resolve repo-xfiles 7
chk_both "satisfied" 0 "explicit backend=files → same as absent .roadmap.json (satisfied / exit 0)"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "resolve-dep-backend: all assertions passed."
  exit 0
else
  echo "resolve-dep-backend: $fails assertion(s) failed."
  exit 1
fi
