#!/usr/bin/env bash
#
# Regression test for #553 — atelier-housekeeping must keep (and report) a task
# whose GitHub issue number and board "Atelier ID" disagree, instead of removing
# it as merged + Done:
#   shape A: the item's own Atelier ID is set and differs from the issue number;
#   shape B: another same-repo issue carries Atelier ID == N (reverse lookup).
#
# Each case builds a hermetic fixture (temp repo, local bare remote, temp
# ATELIER_CONFIG_DIR, .roadmap.json backend github-project) and a `gh` shim on
# PATH. No network, no real gh.
#
# Shim contract (gh api graphql, one aliased query):
#   GH_STATUS_<n>   board Status of item n (Done | In Progress | ...)
#   GH_AID_<n>      Atelier ID on item n: "text:<v>" or "num:<v>"; unset = null
#   GH_AIDREV_<n>   space-separated "<issue>:<aid>" pairs returned by the
#                   reverse lookup a<n> (text-typed Atelier ID); unset = none
#   GH_O_MODE       "" (normal) | missing (no `o` key) | bad (o.p is a string)
#   GH_PR_STATE     MERGED | OPEN | NONE for `gh pr list`
#
# Cases: 1 shape A, 2 equal value in other formats, 3 shape B, 4 shape B hit on
# self ignored, 5 branch-only path, 6 field absent, 7 --yes/--include-unmerged,
# 8 unreadable cross-check -> unknown.
#
# Run:  hooks/tests/housekeeping-id-mismatch.test.sh
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

echo "housekeeping issue/Atelier ID mismatch (#553)"

BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHSHIM'
#!/usr/bin/env bash
# aidjson <spec> -> JSON for the aid alias value
aidjson() {
  case "$1" in
    text:*) jq -cn --arg v "${1#text:}" '{text:$v}' ;;
    num:*)  jq -cn --argjson v "${1#num:}" '{number:$v}' ;;
    *)      printf 'null' ;;
  esac
}
case "${1:-}" in
  repo)
    printf 'main\n'; exit 0 ;;
  pr)
    printf '%s' "${GH_PR_STATE:-NONE}"; exit 0 ;;
  api)
    q=""
    for a in "$@"; do
      case "$a" in query=*) q="${a#query=}" ;; esac
    done
    case "$q" in
      *'items(first:100,after:$c,query:"repo:'*)
        # owner-side scan (#561): always an empty page here
        printf '{"data":{"o":{"p":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}\n'
        exit 0 ;;
    esac
    ids="$(printf '%s' "$q" | grep -oE 'i[0-9]+:issue' | sed -E 's/^i([0-9]+):issue$/\1/')"
    out='{"data":{"r":{'
    sep=""; ob=""; osep=""
    for id in $ids; do
      var="GH_STATUS_$id"; st="${!var:-NOITEM}"
      avar="GH_AID_$id"; aj="$(aidjson "${!avar:-}")"
      if [ "$st" = "NOITEM" ]; then
        nodes='[]'
      else
        nodes="[{\"project\":{\"number\":1,\"owner\":{\"login\":\"fixture\"}},\"fieldValueByName\":{\"name\":\"$st\"},\"aid\":$aj}]"
      fi
      out="$out$sep\"i$id\":{\"projectItems\":{\"nodes\":$nodes}}"
      sep=","
      rvar="GH_AIDREV_$id"; rn=""; rsep=""
      for pair in ${!rvar:-}; do
        rn="$rn$rsep{\"content\":{\"number\":${pair%%:*},\"repository\":{\"nameWithOwner\":\"fixture/x\"}},\"aid\":{\"text\":\"${pair#*:}\"}}"
        rsep=","
      done
      ob="$ob$osep\"a$id\":{\"nodes\":[$rn]}"; osep=","
    done
    case "${GH_O_MODE:-}" in
      missing) printf '%s}}}\n' "$out" ;;
      bad)     printf '%s},"o":{"p":"garbage"}}}\n' "$out" ;;
      *)       printf '%s},"o":{"p":{%s}}}}\n' "$out" "$ob" ;;
    esac
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
  else
    git -C "$REPO" branch task/524-fresh main
    git -C "$REPO" push -q origin task/524-fresh 2>/dev/null
  fi
}

# reset_env — clear every shim variable between cases.
reset_env() {
  unset GH_AID_524 GH_AIDREV_524 GH_O_MODE
  export GH_STATUS_524=Done GH_PR_STATE=MERGED
}

# run_hk [extra flags...] — sets OUT and EXIT.
run_hk() {
  OUT="$(PATH="$BIN:$REPO_ROOT/scripts:$PATH" ATELIER_CONFIG_DIR="$CFG" \
           bash "$HOUSEKEEPING" --project "$REPO" --yes --no-stamp "$@" 2>&1)"
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
  if [ -d "$WT" ]; then pass "$1: worktree kept"; else fail "$1: worktree removed — output: $OUT"; fi
}
check_wt_removed() {
  if [ ! -d "$WT" ]; then pass "$1: worktree removed (merged + Done)"; else fail "$1: worktree still present — output: $OUT"; fi
}
check_branches_kept() {
  if has_branch task/524-fresh; then pass "$1: local branch kept"; else fail "$1: local branch deleted — output: $OUT"; fi
  if has_remote task/524-fresh; then pass "$1: remote branch kept"; else fail "$1: remote branch deleted — output: $OUT"; fi
}

# ---- Case 1: shape A, worktree path ---------------------------------------
new_fixture c1; reset_env
export GH_AID_524="text:777"
run_hk
check_exit "case 1"
check_wt_kept "case 1"
check_out "case 1" "issue/Atelier ID mismatch for #524"
check_out "case 1" "board Atelier ID is 777"

# ---- Case 2: equal value, other formats -----------------------------------
c2n=0
for spec in "text:#524" "num:524" "num:524.0" "text: 524 "; do
  c2n=$((c2n + 1))
  new_fixture "c2-$c2n"; reset_env
  export GH_AID_524="$spec"
  run_hk
  check_exit "case 2 ($spec)"
  check_wt_removed "case 2 ($spec)"
  if printf '%s\n' "$OUT" | grep -qF "Atelier ID mismatch"; then fail "case 2 ($spec): spurious mismatch — output: $OUT"; else pass "case 2 ($spec): no mismatch reported"; fi
done

# ---- Case 3: shape B, other issue holds Atelier ID == N -------------------
new_fixture c3; reset_env
export GH_AIDREV_524="900:524"
run_hk
check_exit "case 3"
check_wt_kept "case 3"
check_out "case 3" "issue/Atelier ID mismatch for #524"
check_out "case 3" "#900"

# ---- Case 4: shape B, reverse lookup hits N itself ------------------------
new_fixture c4; reset_env
export GH_AIDREV_524="524:524"
run_hk
check_exit "case 4"
check_wt_removed "case 4"

# ---- Case 5: branch-only path (no worktree) -------------------------------
new_fixture c5 no; reset_env
export GH_AID_524="text:777"
run_hk
check_exit "case 5"
check_branches_kept "case 5"
check_out "case 5" "issue/Atelier ID mismatch for #524"

# ---- Case 6: field absent -------------------------------------------------
new_fixture c6; reset_env
run_hk
check_exit "case 6"
check_wt_removed "case 6"

new_fixture c6b no; reset_env
run_hk
check_exit "case 6 (branch-only)"
if ! has_branch task/524-fresh; then pass "case 6 (branch-only): merged + Done local branch removed"; else fail "case 6 (branch-only): local branch kept — output: $OUT"; fi

# ---- Case 7: --yes (default in run_hk) and --include-unmerged -------------
new_fixture c7; reset_env
export GH_AID_524="text:777"
run_hk --include-unmerged
check_exit "case 7 (--yes --include-unmerged)"
check_wt_kept "case 7 (--yes --include-unmerged)"
check_out "case 7 (--yes --include-unmerged)" "issue/Atelier ID mismatch for #524"

new_fixture c7b; reset_env
export GH_AIDREV_524="900:524"
run_hk --include-unmerged
check_exit "case 7 (shape B, --include-unmerged)"
check_wt_kept "case 7 (shape B, --include-unmerged)"

# ---- Case 8: unreadable cross-check -> unknown -> kept --------------------
for mode in missing bad; do
  new_fixture "c8-$mode"; reset_env
  export GH_O_MODE="$mode"
  run_hk
  check_exit "case 8 ($mode)"
  check_wt_kept "case 8 ($mode)"
  check_out "case 8 ($mode)" "claim state unknown for #524"
  check_out "case 8 ($mode)" "Atelier ID cross-check unreadable"
done

echo ""
if [ "$fails" -eq 0 ]; then
  echo "housekeeping-id-mismatch (#553): all assertions passed."
  exit 0
else
  echo "housekeeping-id-mismatch (#553): $fails assertion(s) failed."
  exit 1
fi
