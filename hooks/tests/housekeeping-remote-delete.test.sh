#!/usr/bin/env bash
#
# Regression test for #510 — atelier-housekeeping must treat a remote
# task/* branch that is already gone on origin as success (prune the stale
# tracking ref, quiet log), while a real delete failure is still reported
# with git's own text and the ref is kept.
#
# Hermetic: every fixture is a temp repo whose `origin` fetch URL is a
# github.com URL (so the repo slug resolves) but whose PUSH URL is a local
# bare repo; ls-remote/push use the push URL, so nothing reaches the network.
# `gh` is a shim (repo -> main, pr -> $GH_PR_STATE). Backend is `files`
# (no .roadmap.json, no IN_PROGRESS.md) so no claim is found.
# Never runs against a real project.
#
# Case (e): the enumeration-time `git ls-remote` (the call WITHOUT
# --exit-code) is made to fail by a `git` wrapper on PATH; the per-delete
# confirmation call (`ls-remote --exit-code`) passes through to real git.
#
# Run:  hooks/tests/housekeeping-remote-delete.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOUSEKEEPING="$REPO_ROOT/scripts/atelier-housekeeping"

command -v jq  >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "  SKIP: git not on PATH"; exit 0; }
REAL_GIT="$(command -v git)"

TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

echo "housekeeping already-deleted remote branch (#510)"

BIN="$TMP/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'GHSHIM'
#!/usr/bin/env bash
case "${1:-}" in
  repo) printf 'main\n' ;;
  pr)   printf '%s' "${GH_PR_STATE:-MERGED}" ;;
esac
exit 0
GHSHIM
chmod +x "$BIN/gh"

# git wrapper for case (e): fail `ls-remote` calls that lack --exit-code.
BIN_E="$TMP/bin-e"
mkdir -p "$BIN_E"
cat > "$BIN_E/git" <<GITSHIM
#!/usr/bin/env bash
case " \$* " in
  *" ls-remote "*)
    case " \$* " in *" --exit-code "*) ;; *) echo "shim: enumeration ls-remote refused" >&2; exit 128 ;; esac ;;
esac
exec "$REAL_GIT" "\$@"
GITSHIM
chmod +x "$BIN_E/git"

# new_fixture <name> — repo + bare push remote. Sets REPO, CFG, BARE.
new_fixture() {
  local base="$TMP/$1"
  REPO="$base/repo"; CFG="$base/cfg"; BARE="$base/remote.git"
  mkdir -p "$REPO" "$CFG"
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
  jq -n --arg p "$REPO" '{"projects":{($p):{"setupVersion":"99.0.0"}}}' > "$CFG/projects.json"
  # Branch on the remote + local tracking ref (no local branch, no worktree).
  git -C "$REPO" push -q origin main:refs/heads/task/510-gone 2>/dev/null
  git -C "$REPO" update-ref refs/remotes/origin/task/510-gone "$(git -C "$REPO" rev-parse main)"
}

# run_hk <extra args...> [PATHPREFIX env via HK_PATH]
run_hk() {
  OUT="$(PATH="${HK_PATH:-$BIN}:$REPO_ROOT/scripts:$PATH" ATELIER_CONFIG_DIR="$CFG" GH_PR_STATE=MERGED \
           bash "$HOUSEKEEPING" --project "$REPO" --no-stamp "$@" 2>&1)"
  EXIT=$?
}

has_remote()  { git -C "$BARE" rev-parse --verify -q "refs/heads/task/510-gone" >/dev/null 2>&1; }
has_tracking(){ git -C "$REPO" rev-parse --verify -q "refs/remotes/origin/task/510-gone" >/dev/null 2>&1; }
check_exit() {
  if [ "$EXIT" -eq 0 ]; then pass "$1: exit 0"; else fail "$1: exit $EXIT (expected 0) — output: $OUT"; fi
}
check_out() {
  if printf '%s\n' "$OUT" | grep -qF -- "$2"; then pass "$1: output contains '$2'"; else fail "$1: output lacks '$2' — output: $OUT"; fi
}
check_no_out() {
  if printf '%s\n' "$OUT" | grep -qF -- "$2"; then fail "$1: output unexpectedly contains '$2' — output: $OUT"; else pass "$1: output lacks '$2'"; fi
}

# ---- (a) normal delete succeeds -------------------------------------------
new_fixture a
run_hk --yes
check_exit "(a)"
check_out "(a)" "deleted remote branch origin/task/510-gone"
if ! has_remote; then pass "(a): branch gone from the bare remote"; else fail "(a): branch still on remote — output: $OUT"; fi
check_no_out "(a)" "could not delete"

# ---- (b) already gone + stale tracking ref -> pruned; rerun is a no-op -----
new_fixture b
git -C "$BARE" update-ref -d refs/heads/task/510-gone
run_hk --yes
check_exit "(b)"
check_out "(b)" "origin/task/510-gone already deleted"
check_no_out "(b)" "could not delete"
if ! has_tracking; then pass "(b): stale tracking ref pruned"; else fail "(b): tracking ref still present — output: $OUT"; fi
run_hk --yes
check_exit "(b) rerun"
check_out "(b) rerun" "nothing to clean up"

# ---- (c) --report lists the ghost and changes nothing -----------------------
new_fixture c
git -C "$BARE" update-ref -d refs/heads/task/510-gone
run_hk --report
check_exit "(c)"
check_out "(c)" "already gone on origin"
if has_tracking; then pass "(c): tracking ref untouched by --report"; else fail "(c): --report removed the ref — output: $OUT"; fi

# ---- (d) pre-receive rejection is reported with its text, ref kept ----------
new_fixture d
mkdir -p "$BARE/hooks"
printf '#!/bin/sh\necho "deletion forbidden by policy-510" >&2\nexit 1\n' > "$BARE/hooks/pre-receive"
chmod +x "$BARE/hooks/pre-receive"
run_hk --yes
check_exit "(d)"
check_out "(d)" "could not delete remote branch origin/task/510-gone"
check_out "(d)" "deletion forbidden by policy-510"
check_no_out "(d)" "already deleted"
if has_remote; then pass "(d): remote branch kept"; else fail "(d): remote branch deleted — output: $OUT"; fi
if has_tracking; then pass "(d): tracking ref kept"; else fail "(d): tracking ref removed — output: $OUT"; fi

# ---- (e) enumeration ls-remote fails -> per-delete check says already deleted
new_fixture e
git -C "$BARE" update-ref -d refs/heads/task/510-gone
HK_PATH="$BIN_E:$BIN" run_hk --yes
unset HK_PATH
check_exit "(e)"
check_out "(e)" "could not list origin heads"
check_out "(e)" "origin/task/510-gone already deleted"
check_no_out "(e)" "could not delete"
if ! has_tracking; then pass "(e): tracking ref pruned by the per-delete check"; else fail "(e): tracking ref still present — output: $OUT"; fi

echo
if [ "$fails" -eq 0 ]; then echo "all passed"; exit 0; else echo "$fails failure(s)"; exit 1; fi
