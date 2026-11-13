#!/usr/bin/env bash
#
# Regression test for #673 — atelier-housekeeping classifies release branches
# (task/release-<semver>) and catalog pin branches (chore/pin-<plugin>-v<semver>)
# by PR state (head-sha bound), never by a board claim, and never deletes
# unmerged / open / unknown work.
#
# Hermetic: a temp repo whose `origin` fetch URL is a github.com URL (so the
# repo slug resolves) but whose PUSH URL is a local bare repo; a projects.json
# in a temp ATELIER_CONFIG_DIR; and a `gh` shim on PATH that answers
# `repo ...` with `main` and `pr list --head <b>` from a fixture TSV
# (branch<TAB>state<TAB>headRefOid<TAB>number), ignoring --jq. Nothing reaches
# the network and nothing outside $TMP is touched. Checks use here-strings.
#
# Run:  hooks/tests/housekeeping-release-pin.test.sh
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

echo "housekeeping release + catalog pin branches (#673)"

BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHSHIM'
#!/usr/bin/env bash
case "${1:-}" in
  repo) printf 'main\n'; exit 0 ;;
  pr)
    head=""
    while [ $# -gt 0 ]; do
      [ "$1" = "--head" ] && { head="${2:-}"; break; }
      shift
    done
    line="$(awk -F'\t' -v b="$head" '$1 == b { print $2 "\t" $3 "\t" $4; exit }' "${GH_FIXTURE_TSV:-/dev/null}")"
    if [ -n "$line" ]; then printf '%s\n' "$line"; else printf 'NONE\t\t\n'; fi
    exit 0 ;;
esac
exit 0
GHSHIM
chmod +x "$BIN/gh"

BASE_DIR="$TMP/fx"
REPO="$BASE_DIR/repo"; CFG="$BASE_DIR/cfg"; BARE="$BASE_DIR/remote.git"; WT="$BASE_DIR/wt"
TSV="$BASE_DIR/prs.tsv"
mkdir -p "$REPO" "$CFG" "$WT"
git init -q --bare "$BARE"
git -C "$REPO" init -q -b main 2>/dev/null \
  || { git -C "$REPO" init -q; git -C "$REPO" symbolic-ref HEAD refs/heads/main; }
git -C "$REPO" config user.email "fixture@test"
git -C "$REPO" config user.name  "Fixture"
printf '.claude/\n' > "$REPO/.gitignore"
printf 'initial\n' > "$REPO/README.md"
mkdir -p "$REPO/.claude-plugin"
jq -n '{plugins:[{name:"atelier",source:{ref:"v1.2.0"}}]}' > "$REPO/.claude-plugin/marketplace.json"
git -C "$REPO" add .gitignore README.md .claude-plugin/marketplace.json
git -C "$REPO" commit -qm "init"
git -C "$REPO" remote add origin https://github.com/fixture/x.git
git -C "$REPO" remote set-url --push origin "$BARE"
jq -n --arg p "$REPO" '{"projects":{($p):{"setupVersion":"99.0.0"}}}' > "$CFG/projects.json"
: > "$TSV"

# mkbranch <name> — branch off main with one unique commit (not an ancestor of
# main, like a squash-merged branch). Echo nothing.
mkbranch() {
  git -C "$REPO" checkout -q -b "$1" main
  printf '%s\n' "$1" > "$REPO/f-${1//\//_}.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "work on $1"
  git -C "$REPO" checkout -q main
}
tip() { git -C "$REPO" rev-parse "refs/heads/$1"; }
# pr <branch> <state> <sha|tip|other> <number>
pr() {
  local sha="$3"
  case "$3" in tip) sha="$(tip "$1")" ;; other) sha="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ;; esac
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$sha" "$4" >> "$TSV"
}
# remote <branch> — publish on the bare remote + local tracking ref.
remote() {
  git -C "$REPO" push -q origin "refs/heads/$1:refs/heads/$1" 2>/dev/null
  git -C "$REPO" update-ref "refs/remotes/origin/$1" "$(tip "$1")"
}
# wt <branch> <dir> — worktree for an existing branch.
wt() { git -C "$REPO" worktree add -q "$WT/$2" "$1" 2>/dev/null; }

has_local()  { git -C "$REPO" rev-parse --verify -q "refs/heads/$1" >/dev/null 2>&1; }
has_remote() { git -C "$BARE" rev-parse --verify -q "refs/heads/$1" >/dev/null 2>&1; }

# (a) merged release PR, sha matches: worktree + origin; (a2) local + origin.
mkbranch task/release-1.0.0; wt task/release-1.0.0 a;  remote task/release-1.0.0; pr task/release-1.0.0 MERGED tip 101
mkbranch task/release-1.1.0;                            remote task/release-1.1.0; pr task/release-1.1.0 MERGED tip 102
# (b) open release PR with worktree + origin.
mkbranch task/release-2.0.0; wt task/release-2.0.0 b;  remote task/release-2.0.0; pr task/release-2.0.0 OPEN tip 103
# (c) release branch with no PR (no TSV row).
mkbranch task/release-3.0.0
# (d) merged PR whose head sha differs from the tip.
mkbranch task/release-4.0.0;                            pr task/release-4.0.0 MERGED other 104
# (e) superseded pin worktree: dirty, no PR; base pins v1.2.0, branch is v1.1.0.
mkbranch chore/pin-atelier-v1.1.0; wt chore/pin-atelier-v1.1.0 e
printf 'dirty\n' > "$WT/e/uncommitted.txt"
# (f) merged pin PR: clean worktree + origin; (f2) local-only merged pin.
mkbranch chore/pin-atelier-v1.2.0; wt chore/pin-atelier-v1.2.0 f; remote chore/pin-atelier-v1.2.0; pr chore/pin-atelier-v1.2.0 MERGED tip 105
mkbranch chore/pin-atelier-v1.0.5;                                  pr chore/pin-atelier-v1.0.5 MERGED tip 106
# (g) plain chore/other (local + origin) and a pin with an open PR.
mkbranch chore/other;              remote chore/other
mkbranch chore/pin-atelier-v1.4.0; remote chore/pin-atelier-v1.4.0; pr chore/pin-atelier-v1.4.0 OPEN tip 107

run_hk() {
  OUT="$(PATH="$BIN:$REPO_ROOT/scripts:$PATH" ATELIER_CONFIG_DIR="$CFG" GH_FIXTURE_TSV="$TSV" \
           bash "$HOUSEKEEPING" --project "$REPO" --no-stamp "$@" 2>&1)"
  EXIT=$?
}
# in_arr <array> <target> — target present in the JSON array.
in_arr() { jq -e --arg t "$2" --arg a "$1" '.[$a][] | select(.target == $t)' <<<"$JSON" >/dev/null 2>&1; }
check_in()  { if in_arr "$2" "$3"; then pass "$1: '$3' in $2"; else fail "$1: '$3' missing from $2 — json: $JSON"; fi; }
check_out() { if in_arr "$2" "$3"; then fail "$1: '$3' unexpectedly in $2 — json: $JSON"; else pass "$1: '$3' not in $2"; fi; }
reason_of() { jq -r --arg t "$2" --arg a "$1" '[.[$a][] | select(.target == $t) | .reason][0] // ""' <<<"$JSON"; }

# ---- (h) --json arrays, and (a)-(g) classification, before any deletion -----
JSON="$(PATH="$BIN:$REPO_ROOT/scripts:$PATH" ATELIER_CONFIG_DIR="$CFG" GH_FIXTURE_TSV="$TSV" \
          bash "$HOUSEKEEPING" --project "$REPO" --no-stamp --json 2>/dev/null)"
if jq -e . >/dev/null 2>&1 <<<"$JSON"; then pass "(h): --json output is valid JSON"; else fail "(h): --json invalid — $JSON"; fi

check_in "(a)"  worktrees       "$WT/a"
check_in "(a)"  remote_branches task/release-1.0.0
check_in "(a2)" local_branches  task/release-1.1.0
check_in "(a2)" remote_branches task/release-1.1.0
r="$(reason_of worktrees "$WT/a")"
if grep -q "squash, head sha matches" <<<"$r"; then pass "(a): reason names the sha-bound squash merge"; else fail "(a): reason was '$r'"; fi
check_out "(a)" needs_review "$WT/a"

check_in  "(b)" skipped "$WT/b"
check_in  "(b)" skipped task/release-2.0.0
check_in  "(b)" skipped origin/task/release-2.0.0
check_out "(b)" worktrees "$WT/b"
check_out "(b)" remote_branches task/release-2.0.0

check_in  "(c)" needs_review task/release-3.0.0
r="$(reason_of needs_review task/release-3.0.0)"
if grep -q "without a PR" <<<"$r"; then pass "(c): reason says no PR"; else fail "(c): reason was '$r'"; fi
check_out "(c)" local_branches task/release-3.0.0

check_in  "(d)" needs_review task/release-4.0.0
r="$(reason_of needs_review task/release-4.0.0)"
if grep -q "tip differs" <<<"$r"; then pass "(d): reason says tip differs from PR head"; else fail "(d): reason was '$r'"; fi
check_out "(d)" local_branches task/release-4.0.0

check_in  "(e)" needs_review "$WT/e"
r="$(reason_of needs_review "$WT/e")"
if grep -q "superseded pin v1.1.0 (catalog pins v1.2.0)" <<<"$r"; then pass "(e): reason names both versions"; else fail "(e): reason was '$r'"; fi
check_out "(e)" worktrees "$WT/e"

check_in "(f)"  worktrees       "$WT/f"
check_in "(f)"  remote_branches chore/pin-atelier-v1.2.0
check_in "(f2)" local_branches  chore/pin-atelier-v1.0.5

check_out "(g)" local_branches  chore/other
check_out "(g)" remote_branches chore/other
check_out "(g)" needs_review    chore/other
check_out "(g)" needs_review    origin/chore/other
check_in  "(g)" skipped         origin/chore/pin-atelier-v1.4.0
check_out "(g)" remote_branches chore/pin-atelier-v1.4.0

# ---- --report: no claim-state noise, nothing deleted -------------------------
run_hk --report
if grep -q "claim state unknown" <<<"$OUT"; then fail "report: still mentions 'claim state unknown' — $OUT"; else pass "report: no 'claim state unknown'"; fi
if grep -q "no board item found" <<<"$OUT"; then fail "report: still mentions 'no board item found' — $OUT"; else pass "report: no 'no board item found'"; fi
if [ -d "$WT/a" ] && has_local task/release-1.1.0 && has_remote task/release-1.1.0; then
  pass "report: nothing deleted"
else
  fail "report: deleted something — $OUT"
fi

# ---- --yes: removal + protection --------------------------------------------
run_hk --yes
if [ "$EXIT" -eq 0 ]; then pass "yes: exit 0"; else fail "yes: exit $EXIT — $OUT"; fi

if [ ! -d "$WT/a" ]; then pass "(a): worktree removed"; else fail "(a): worktree still on disk"; fi
if ! has_remote task/release-1.0.0; then pass "(a): origin branch removed"; else fail "(a): origin branch still on remote"; fi
if ! has_local task/release-1.1.0; then pass "(a2): local branch removed (squash, not an ancestor)"; else fail "(a2): local branch kept"; fi
if ! has_remote task/release-1.1.0; then pass "(a2): origin branch removed"; else fail "(a2): origin branch kept"; fi

if [ -d "$WT/b" ] && has_local task/release-2.0.0 && has_remote task/release-2.0.0; then
  pass "(b): open release PR untouched (worktree, local, remote)"
else
  fail "(b): open release PR was touched"
fi
if has_local task/release-3.0.0; then pass "(c): no-PR release branch untouched"; else fail "(c): deleted"; fi
if has_local task/release-4.0.0; then pass "(d): sha-mismatch release branch untouched"; else fail "(d): deleted"; fi
if [ -d "$WT/e" ] && [ -f "$WT/e/uncommitted.txt" ] && has_local chore/pin-atelier-v1.1.0; then
  pass "(e): superseded dirty pin worktree and branch untouched"
else
  fail "(e): superseded pin was touched"
fi
if [ ! -d "$WT/f" ]; then pass "(f): pin worktree removed"; else fail "(f): pin worktree still on disk"; fi
if ! has_remote chore/pin-atelier-v1.2.0; then pass "(f): pin origin branch removed"; else fail "(f): pin origin branch kept"; fi
if ! has_local chore/pin-atelier-v1.0.5; then pass "(f2): local pin branch removed"; else fail "(f2): local pin branch kept"; fi
if has_local chore/other && has_remote chore/other; then pass "(g): chore/other untouched"; else fail "(g): chore/other deleted"; fi
if has_local chore/pin-atelier-v1.4.0 && has_remote chore/pin-atelier-v1.4.0; then
  pass "(g): open-PR pin untouched"
else
  fail "(g): open-PR pin deleted"
fi

# ---- second sweep: the branch that backed a removed worktree is now plain ----
run_hk --yes
if ! has_local task/release-1.0.0; then pass "(a) rerun: former worktree branch removed"; else fail "(a) rerun: local branch task/release-1.0.0 kept — $OUT"; fi
if has_local task/release-2.0.0 && has_local task/release-3.0.0 && has_local task/release-4.0.0; then
  pass "rerun: protected release branches still present"
else
  fail "rerun: a protected release branch vanished"
fi

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; exit 0; else echo "$fails failure(s)"; exit 1; fi
