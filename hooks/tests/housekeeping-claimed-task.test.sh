#!/usr/bin/env bash
#
# Regression test for #540 — atelier-housekeeping must never remove the
# worktree or branches of a CLAIMED task (board Status In Progress on a
# github-project backend), nor of a freshly cut task branch with no commits
# and no PR (an ancestor of base), nor anything whose claim state is unknown.
#
# Each case builds its own hermetic fixture (temp repo, local bare remote that
# backs the pushes, temp ATELIER_CONFIG_DIR/projects.json, .roadmap.json with
# backend github-project) and a `gh` shim on PATH. No network, no real gh.
#
# The shim contract:
#   gh api graphql -f query=<aliased query>  -> one issue alias per id; the
#       board Status comes from env GH_STATUS_<id> (In Progress | Todo | Done |
#       NOITEM); GH_GRAPHQL_FAIL=1 makes it exit 1 (every id unknown).
#   gh pr list --repo S --head B ...        -> env GH_PR_STATE
#       (MERGED | OPEN | CLOSED | NONE).
#
# Cases:
#   1  ancestor of base, board In Progress, PR NONE -> worktree + branch kept,
#      output "claimed task #524"
#   2  ancestor of base, board Todo, PR NONE -> worktree kept, output
#      "no commits beyond base and no PR"
#   3  graphql fails, PR MERGED -> worktree kept, output "claim state unknown"
#   4  PR MERGED, board In Progress -> worktree kept
#   5  PR MERGED, board Done -> worktree removed (post-merge mop-up intact)
#   6  board In Progress, branch pushed, no worktree, ancestor of base, PR
#      NONE and PR MERGED -> local AND remote branch kept, claimed reason
#
# Run:  hooks/tests/housekeeping-claimed-task.test.sh
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

echo "housekeeping claimed-task protection (#540)"

# gh shim, shared by every case.
BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHSHIM'
#!/usr/bin/env bash
case "${1:-}" in
  pr)
    printf '%s' "${GH_PR_STATE:-NONE}"
    exit 0 ;;
  api)
    [ "${GH_GRAPHQL_FAIL:-0}" = "1" ] && exit 1
    q=""
    for a in "$@"; do
      case "$a" in query=*) q="${a#query=}" ;; esac
    done
    ids="$(printf '%s' "$q" | grep -oE 'i[0-9]+:issue' | sed -E 's/^i([0-9]+):issue$/\1/')"
    out='{"data":{"r":{'
    sep=""
    for id in $ids; do
      var="GH_STATUS_$id"
      st="${!var:-NOITEM}"
      if [ "$st" = "NOITEM" ]; then
        nodes='[]'
      else
        nodes="[{\"project\":{\"number\":1},\"fieldValueByName\":{\"name\":\"$st\"}}]"
      fi
      out="$out$sep\"i$id\":{\"projectItems\":{\"nodes\":$nodes}}"
      sep=","
    done
    printf '%s}}}\n' "$out"
    exit 0 ;;
esac
exit 0
GHSHIM
chmod +x "$BIN/gh"

# new_fixture <name> [with-worktree] — sets REPO, CFG, BARE, WT.
new_fixture() {
  local name="$1" withwt="${2:-yes}"
  local base="$TMP/$name"
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
  # repo_slug() reads the fetch URL (fixture/x); pushes go to the bare remote.
  git -C "$REPO" remote add origin https://github.com/fixture/x.git
  git -C "$REPO" remote set-url --push origin "$BARE"
  cat > "$REPO/.roadmap.json" <<'JSON'
{"backend":"github-project","githubProject":{"projectNumber":1,"stateMap":{"inProgress":["In Progress"]}}}
JSON
  jq -n --arg p "$REPO" '{"projects":{($p):{"setupVersion":"99.0.0"}}}' > "$CFG/projects.json"
  if [ "$withwt" = "yes" ]; then
    git -C "$REPO" worktree add -q -b task/524-fresh "$WT"
    mkdir -p "$WT/.claude"
    printf '{}\n' > "$WT/.claude/settings.json"
  fi
}

# run_hk — runs the sweep with the exact skill flags; sets OUT and EXIT.
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
  if printf '%s\n' "$OUT" | grep -qF -- "$2"; then
    pass "$1: output contains '$2'"
  else
    fail "$1: output lacks '$2' — output: $OUT"
  fi
}
check_wt_kept() {
  if [ -d "$WT" ]; then pass "$1: worktree kept"; else fail "$1: worktree $WT was removed — data loss"; fi
}

# ---- Case 1 ---------------------------------------------------------------
new_fixture c1
export GH_STATUS_524="In Progress" GH_PR_STATE=NONE; unset GH_GRAPHQL_FAIL
run_hk
check_exit "case 1"
check_wt_kept "case 1"
if has_branch task/524-fresh; then pass "case 1: local branch kept"; else fail "case 1: local branch task/524-fresh deleted"; fi
check_out "case 1" "claimed task #524"

# ---- Case 2 ---------------------------------------------------------------
new_fixture c2
export GH_STATUS_524="Todo" GH_PR_STATE=NONE; unset GH_GRAPHQL_FAIL
run_hk
check_exit "case 2"
check_wt_kept "case 2"
check_out "case 2" "no commits beyond base and no PR"

# ---- Case 3 ---------------------------------------------------------------
new_fixture c3
export GH_STATUS_524="In Progress" GH_PR_STATE=MERGED GH_GRAPHQL_FAIL=1
run_hk
check_exit "case 3"
check_wt_kept "case 3"
check_out "case 3" "claim state unknown"
unset GH_GRAPHQL_FAIL

# ---- Case 4 ---------------------------------------------------------------
new_fixture c4
export GH_STATUS_524="In Progress" GH_PR_STATE=MERGED
run_hk
check_exit "case 4"
check_wt_kept "case 4"

# ---- Case 5 ---------------------------------------------------------------
new_fixture c5
export GH_STATUS_524="Done" GH_PR_STATE=MERGED
run_hk
check_exit "case 5"
if [ ! -d "$WT" ]; then pass "case 5: merged + Done worktree removed"; else fail "case 5: worktree still present — post-merge mop-up regressed — output: $OUT"; fi

# ---- Case 6 ---------------------------------------------------------------
for pr in NONE MERGED; do
  new_fixture "c6-$pr" no
  git -C "$REPO" branch task/524-fresh main
  git -C "$REPO" push -q origin task/524-fresh 2>/dev/null
  export GH_STATUS_524="In Progress" GH_PR_STATE="$pr"
  has_remote task/524-fresh || fail "case 6 ($pr): fixture error — remote branch not pushed"
  run_hk
  check_exit "case 6 ($pr)"
  if has_branch task/524-fresh; then pass "case 6 ($pr): local branch kept"; else fail "case 6 ($pr): local branch deleted — output: $OUT"; fi
  if has_remote task/524-fresh; then pass "case 6 ($pr): remote branch kept"; else fail "case 6 ($pr): remote branch deleted — output: $OUT"; fi
  check_out "case 6 ($pr)" "claimed task #524"
done

echo ""
if [ "$fails" -eq 0 ]; then
  echo "housekeeping-claimed-task (#540): all assertions passed."
  exit 0
else
  echo "housekeeping-claimed-task (#540): $fails assertion(s) failed."
  exit 1
fi
