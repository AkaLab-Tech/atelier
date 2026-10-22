#!/usr/bin/env bash
#
# Regression test for #561 — atelier-housekeeping's claim check must resolve a
# task whose board item the issue-side query cannot see (board owned by a
# different account / user-owned aggregated board) through the owner-side
# paged scan, and must fail closed (unknown, kept) whenever it cannot.
#
# Each case builds a hermetic fixture (temp repo, local bare remote, temp
# ATELIER_CONFIG_DIR, .roadmap.json backend github-project, board owner alice
# while the repo slug is fixture/x) and a `gh` shim on PATH. No network.
#
# Shim contract (gh api graphql):
#   issue-side query (contains `i<N>:issue`):
#     GH_ISSUE_<N>   NOITEM (default) | <ownerLogin>:<Status> -> one
#                    projectItems node on project #1 owned by <ownerLogin>
#   owner-side query (contains `items(first:100,after:$c,query:"repo:`):
#     GH_OWNER_P1 / GH_OWNER_P2  JSON array of nodes for page 1 / page 2
#                    (page 2 is served when `-f c=` is passed)
#     GH_OWNER_NEXT=1   page 1 reports hasNextPage with endCursor CUR1
#     GH_OWNER_ENDLESS=1  every page is empty and reports hasNextPage
#     GH_OWNER_FAIL=1   {"data":{"o":null},"errors":[{"message":"..."}]}, exit 1
#   GH_CALL_LOG       one line per graphql call: "issue" | "owner" |
#                     "owner cursor=<c>"
#   gh pr list        -> GH_PR_STATE
#
# Run:  hooks/tests/housekeeping-cross-owner-board.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOUSEKEEPING="$REPO_ROOT/scripts/atelier-housekeeping"

command -v jq  >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "  SKIP: git not on PATH"; exit 0; }

TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "housekeeping cross-owner board claim check (#561)"

BIN="$TMP/bin"
mkdir -p "$BIN"
export GH_CALL_LOG="$TMP/calls.log"
cat > "$BIN/gh" <<'GHSHIM'
#!/usr/bin/env bash
case "${1:-}" in
  repo)
    printf 'main\n'; exit 0 ;;
  pr)
    printf '%s' "${GH_PR_STATE:-NONE}"; exit 0 ;;
  api)
    q=""; cur=""
    for a in "$@"; do
      case "$a" in query=*) q="${a#query=}" ;; c=*) cur="${a#c=}" ;; esac
    done
    case "$q" in
      *'items(first:100,after:$c,query:"repo:'*)
        if [ -n "$cur" ]; then echo "owner cursor=$cur" >> "$GH_CALL_LOG"; else echo "owner" >> "$GH_CALL_LOG"; fi
        if [ "${GH_OWNER_FAIL:-0}" = 1 ]; then
          printf '{"data":{"o":null},"errors":[{"message":"Resolve to a User with the login of alice failed"}]}\n'
          exit 1
        fi
        if [ "${GH_OWNER_ENDLESS:-0}" = 1 ]; then
          printf '{"data":{"o":{"p":{"items":{"pageInfo":{"hasNextPage":true,"endCursor":"CURX"},"nodes":[]}}}}}\n'
          exit 0
        fi
        if [ -n "$cur" ]; then
          nodes="${GH_OWNER_P2:-[]}"; next=false; ec=null
        else
          nodes="${GH_OWNER_P1:-[]}"
          if [ "${GH_OWNER_NEXT:-0}" = 1 ]; then next=true; ec='"CUR1"'; else next=false; ec=null; fi
        fi
        printf '{"data":{"o":{"p":{"items":{"pageInfo":{"hasNextPage":%s,"endCursor":%s},"nodes":%s}}}}}\n' "$next" "$ec" "$nodes"
        exit 0 ;;
    esac
    echo "issue" >> "$GH_CALL_LOG"
    ids="$(printf '%s' "$q" | grep -oE 'i[0-9]+:issue' | sed -E 's/^i([0-9]+):issue$/\1/')"
    out='{"data":{"r":{'
    sep=""
    for id in $ids; do
      var="GH_ISSUE_$id"; spec="${!var:-NOITEM}"
      if [ "$spec" = "NOITEM" ]; then
        nodes='[]'
      else
        nodes="[{\"project\":{\"number\":1,\"owner\":{\"login\":\"${spec%%:*}\"}},\"fieldValueByName\":{\"name\":\"${spec#*:}\"},\"aid\":null}]"
      fi
      out="$out$sep\"i$id\":{\"projectItems\":{\"nodes\":$nodes}}"
      sep=","
    done
    printf '%s},"o":{"p":{}}}}\n' "$out"
    exit 0 ;;
esac
exit 0
GHSHIM
chmod +x "$BIN/gh"

# new_fixture <name> — worktree task/524-fresh, branch pushed. Sets REPO, CFG, BARE, WT.
new_fixture() {
  local base="$TMP/$1"
  REPO="$base/repo"; CFG="$base/cfg"; BARE="$base/remote.git"; WT="$base/worktrees/task-524-fresh"
  mkdir -p "$REPO" "$CFG" "$base/worktrees"
  git init -q --bare "$BARE"
  git -C "$REPO" init -q -b main 2>/dev/null \
    || { git -C "$REPO" init -q; git -C "$REPO" symbolic-ref HEAD refs/heads/main; }
  git -C "$REPO" config user.email "fixture@test"
  git -C "$REPO" config user.name  "Fixture"
  printf '.claude/\n' > "$REPO/.gitignore"
  printf 'initial\n' > "$REPO/README.md"
  git -C "$REPO" add .gitignore README.md
  git -C "$REPO" commit -qm "init"
  git -C "$REPO" remote add origin https://github.com/fixture/x.git
  git -C "$REPO" remote set-url --push origin "$BARE"
  cat > "$REPO/.roadmap.json" <<'JSON'
{"backend":"github-project","githubProject":{"projectNumber":1,"owner":"alice","stateMap":{"inProgress":["In Progress"]}}}
JSON
  jq -n --arg p "$REPO" '{"projects":{($p):{"setupVersion":"99.0.0"}}}' > "$CFG/projects.json"
  git -C "$REPO" worktree add -q -b task/524-fresh "$WT"
  mkdir -p "$WT/.claude"
  printf '{}\n' > "$WT/.claude/settings.json"
  git -C "$REPO" push -q origin task/524-fresh 2>/dev/null
}

reset_env() {
  unset GH_ISSUE_524 GH_OWNER_P1 GH_OWNER_P2 GH_OWNER_NEXT GH_OWNER_ENDLESS GH_OWNER_FAIL
  export GH_PR_STATE=MERGED
  : > "$GH_CALL_LOG"
}

# onode <number> <status> <repo> [aid] -> one owner-side node
onode() {
  jq -cn --argjson n "$1" --arg st "$2" --arg r "$3" --arg aid "${4:-}" \
    '{content:{number:$n,repository:{nameWithOwner:$r}},st:{name:$st},aid:(if $aid == "" then null else {text:$aid} end)}'
}

run_hk() {
  OUT="$(PATH="$BIN:$REPO_ROOT/scripts:$PATH" ATELIER_CONFIG_DIR="$CFG" \
           bash "$HOUSEKEEPING" --project "$REPO" --yes --no-stamp 2>&1)"
  EXIT=$?
}

has_branch() { git -C "$REPO" rev-parse --verify -q "refs/heads/$1" >/dev/null 2>&1; }
has_remote() { git -C "$BARE" rev-parse --verify -q "refs/heads/$1" >/dev/null 2>&1; }
check_exit() {
  if [ "$EXIT" -eq 0 ]; then pass "$1: exit 0"; else fail "$1: exit $EXIT (expected 0) — output: $OUT"; fi
}
check_out() { # <label> <needle>
  if printf '%s\n' "$OUT" | grep -qF -- "$2"; then pass "$1: output contains '$2'"; else fail "$1: output lacks '$2' — output: $OUT"; fi
}
check_kept() {
  if [ -d "$WT" ]; then pass "$1: worktree kept"; else fail "$1: worktree removed — output: $OUT"; fi
  if has_branch task/524-fresh; then pass "$1: local branch kept"; else fail "$1: local branch deleted — output: $OUT"; fi
  if has_remote task/524-fresh; then pass "$1: remote branch kept"; else fail "$1: remote branch deleted — output: $OUT"; fi
}
check_cleaned() {
  if [ ! -d "$WT" ]; then pass "$1: worktree removed"; else fail "$1: worktree still present — output: $OUT"; fi
  # The local branch backs the worktree removed in this run; housekeeping
  # leaves it for the next sweep, so it is deliberately not asserted here.
  if ! has_remote task/524-fresh; then pass "$1: remote branch removed"; else fail "$1: remote branch kept — output: $OUT"; fi
}
owner_calls() { grep -c '^owner' "$GH_CALL_LOG" || true; }

# ---- Case 1: cross-owner, owner scan Done + MERGED -> cleaned -------------
new_fixture c1; reset_env
GH_OWNER_P1="[$(onode 524 Done fixture/x)]"
export GH_OWNER_P1
run_hk
check_exit "case 1"
check_cleaned "case 1"
if [ "$(owner_calls)" = 1 ]; then pass "case 1: one owner-side call"; else fail "case 1: owner calls = $(owner_calls), expected 1"; fi

# ---- Case 2: owner scan In Progress -> claimed and kept -------------------
new_fixture c2; reset_env
GH_OWNER_P1="[$(onode 524 'In Progress' fixture/x)]"
export GH_OWNER_P1
run_hk
check_exit "case 2"
check_kept "case 2"
check_out "case 2" "claimed task #524"

# ---- Case 3: board unreadable -> unknown, one warn, kept ------------------
new_fixture c3; reset_env
export GH_OWNER_FAIL=1
run_hk
check_exit "case 3"
check_kept "case 3"
check_out "case 3" "claim state unknown for #524"
check_out "case 3" "cannot read project alice/#1 with the author identity: Resolve to a User with the login of alice failed"
wn="$(printf '%s\n' "$OUT" | grep -c 'board: cannot read project alice/#1')"
if [ "$wn" = 1 ]; then pass "case 3: warn emitted once"; else fail "case 3: warn emitted $wn times — output: $OUT"; fi

# ---- Case 4: id missing from the scan -> unknown, kept --------------------
new_fixture c4; reset_env
GH_OWNER_P1="[$(onode 525 Done fixture/x)]"
export GH_OWNER_P1
run_hk
check_exit "case 4"
check_kept "case 4"
check_out "case 4" "no item for fixture/x#524 on project alice/#1"

# ---- Case 5: scan truncated past 10 pages -> unknown, kept ----------------
new_fixture c5; reset_env
export GH_OWNER_ENDLESS=1
run_hk
check_exit "case 5"
check_kept "case 5"
check_out "case 5" "board scan truncated at 1000 items"
if [ "$(owner_calls)" = 10 ]; then pass "case 5: scan stopped after 10 pages"; else fail "case 5: owner calls = $(owner_calls), expected 10"; fi

# ---- Case 6: item of another repo with the same number never matches ------
new_fixture c6; reset_env
GH_OWNER_P1="[$(onode 524 Done other/y)]"
export GH_OWNER_P1
run_hk
check_exit "case 6"
check_kept "case 6"
check_out "case 6" "no item for fixture/x#524 on project alice/#1"

# ---- Case 7: issue-side item on project #1 of another owner is ignored ----
new_fixture c7; reset_env
export GH_ISSUE_524="mallory:Done"
run_hk
check_exit "case 7"
check_kept "case 7"
check_out "case 7" "no item for fixture/x#524 on project alice/#1"
if [ "$(owner_calls)" = 1 ]; then pass "case 7: fell through to the owner scan"; else fail "case 7: owner calls = $(owner_calls), expected 1"; fi

# ---- Case 8: pagination, id only on page 2 --------------------------------
new_fixture c8; reset_env
export GH_OWNER_NEXT=1
GH_OWNER_P1="[$(onode 525 Todo fixture/x)]"
export GH_OWNER_P1
GH_OWNER_P2="[$(onode 524 Done fixture/x)]"
export GH_OWNER_P2
run_hk
check_exit "case 8"
check_cleaned "case 8"
if grep -qx 'owner cursor=CUR1' "$GH_CALL_LOG" && [ "$(owner_calls)" = 2 ]; then
  pass "case 8: page 2 fetched with the endCursor"
else
  fail "case 8: call log: $(tr '\n' '|' < "$GH_CALL_LOG")"
fi

# ---- Case 9: #553 mismatch applies to owner-side items --------------------
new_fixture c9; reset_env
GH_OWNER_P1="[$(onode 524 Done fixture/x 777)]"
export GH_OWNER_P1
run_hk
check_exit "case 9"
check_kept "case 9"
check_out "case 9" "issue/Atelier ID mismatch for #524"
check_out "case 9" "board Atelier ID is 777"

new_fixture c9b; reset_env
GH_OWNER_P1="[$(onode 524 Done fixture/x '#524')]"
export GH_OWNER_P1
run_hk
check_exit "case 9 (equal aid)"
check_cleaned "case 9 (equal aid)"

# ---- Case 10: same-owner board, issue side resolves -> no owner call ------
new_fixture c10; reset_env
export GH_ISSUE_524="ALICE:Done"   # login compared case-insensitively
run_hk
check_exit "case 10"
check_cleaned "case 10"
if [ "$(owner_calls)" = 0 ]; then pass "case 10: no owner-side call"; else fail "case 10: owner calls = $(owner_calls), expected 0"; fi

new_fixture c10b; reset_env
export GH_ISSUE_524="alice:In Progress"
run_hk
check_exit "case 10 (claimed)"
check_kept "case 10 (claimed)"
if [ "$(owner_calls)" = 0 ]; then pass "case 10 (claimed): no owner-side call"; else fail "case 10 (claimed): owner calls = $(owner_calls), expected 0"; fi

echo ""
if [ "$fails" -eq 0 ]; then
  echo "housekeeping-cross-owner-board (#561): all assertions passed."
  exit 0
else
  echo "housekeeping-cross-owner-board (#561): $fails assertion(s) failed."
  exit 1
fi
