#!/usr/bin/env bash
#
# Regression test for #556 — scripts/atelier-resolve-base resolves the task
# base from GitHub's default branch (then origin/HEAD), never dev-else-main.
#
# Setup: a bare origin with branches main and stage, a clone whose origin URL
# is rewritten to a github.com URL (refs/remotes/origin/* and origin/HEAD are
# set up locally, so no fetch is needed) and a `gh` shim on PATH driven by
# GH_DEFAULT_BRANCH (fails when unset; records each invocation).
#
# Hermetic: local git only, no network.
#
# Run:  hooks/tests/resolve-base.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/atelier-resolve-base"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
eq() { # eq <label> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — expected '$2', got '$3'"; fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

mkdir "$TMP/bin"
cat >"$TMP/bin/gh" <<SHIM
#!/usr/bin/env bash
echo "\$*" >>"$TMP/gh.calls"
[ -n "\${GH_DEFAULT_BRANCH+x}" ] || exit 1
printf '%s\n' "\$GH_DEFAULT_BRANCH"
SHIM
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
unset GH_DEFAULT_BRANCH
: >"$TMP/gh.calls"

git init -q "$TMP/seed"
git -C "$TMP/seed" checkout -q -b main
git -C "$TMP/seed" commit -q --allow-empty -m init
git -C "$TMP/seed" branch stage
git clone -q --bare "$TMP/seed" "$TMP/origin.git"

mkclone() { # mkclone <dir> <origin-url> [with-head]
  git init -q "$1"
  git -C "$1" remote add origin "$2"
  git -C "$1" fetch -q "$TMP/origin.git" '+refs/heads/*:refs/remotes/origin/*'
  if [ "${3:-}" = with-head ]; then
    git -C "$1" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  fi
  return 0
}

snap() { git -C "$1" for-each-ref; git -C "$1" symbolic-ref -q refs/remotes/origin/HEAD || echo none; }

run() { # run <dir> -> sets OUT, RC
  OUT=$("$HELPER" "$1" 2>/dev/null); RC=$?
}

echo "resolve-base (#556) — GitHub default first, origin/HEAD second, fail closed"

mkclone "$TMP/c" https://github.com/acme/widget.git with-head
before=$(snap "$TMP/c")
GHCALL="repo view acme/widget --json defaultBranchRef --jq .defaultBranchRef.name"

# 1. GitHub wins over origin/HEAD
GH_DEFAULT_BRANCH=stage run "$TMP/c"
eq "1: gh=stage beats origin/HEAD=main (rc)" 0 "$RC"
eq "1: output" $'base=stage\nsource=github' "$OUT"
eq "1: gh asked for the origin slug" "$GHCALL" "$(tail -1 "$TMP/gh.calls")"
eq "7: refs unchanged after case 1" "$before" "$(snap "$TMP/c")"

# 2. gh fails -> origin/HEAD
run "$TMP/c"
eq "2: gh fails, origin/HEAD used (rc)" 0 "$RC"
eq "2: output" $'base=main\nsource=origin-head' "$OUT"
eq "7: refs unchanged after case 2" "$before" "$(snap "$TMP/c")"

# 2b. slug forms (ssh, ssh://, no .git)
for u in git@github.com:acme/widget.git ssh://git@github.com/acme/widget.git https://github.com/acme/widget; do
  git -C "$TMP/c" remote set-url origin "$u"
  GH_DEFAULT_BRANCH=stage run "$TMP/c"
  eq "2b: $u -> github" $'base=stage\nsource=github' "$OUT"
  eq "2b: $u slug" "$GHCALL" "$(tail -1 "$TMP/gh.calls")"
done
git -C "$TMP/c" remote set-url origin https://github.com/acme/widget.git

# 3. neither resolves
mkclone "$TMP/n" https://github.com/acme/widget.git
before_n=$(snap "$TMP/n")
run "$TMP/n"
eq "3: exit 1" 1 "$RC"
eq "3: base= empty" "base=" "$(printf '%s\n' "$OUT" | sed -n 1p)"
if printf '%s\n' "$OUT" | grep -q '^reason=.'; then pass "3: reason= line present"; else fail "3: reason= line missing: $OUT"; fi
if printf '%s\n' "$OUT" | grep -q '^base=.'; then fail "3: a base was produced: $OUT"; else pass "3: no base (no main fallback)"; fi
eq "7: refs unchanged after case 3" "$before_n" "$(snap "$TMP/n")"

# 4. empty / invalid gh answers fall back to origin/HEAD
for bad in "" "bad..name" "-x"; do
  GH_DEFAULT_BRANCH=$bad run "$TMP/c"
  eq "4: gh='$bad' falls back to origin-head" $'base=main\nsource=origin-head' "$OUT"
done
GH_DEFAULT_BRANCH=bad..name run "$TMP/n"
eq "4: invalid gh name, no origin/HEAD: exit 1" 1 "$RC"

# 5. non-GitHub origins never call gh
for u in "$TMP/origin.git" https://gitlab.com/acme/widget.git; do
  rm -rf "$TMP/g"
  mkclone "$TMP/g" "$u" with-head
  : >"$TMP/gh.calls"
  GH_DEFAULT_BRANCH=stage run "$TMP/g"
  eq "5: $(basename "$u") uses origin-head" $'base=main\nsource=origin-head' "$OUT"
  eq "5: $(basename "$u") gh never invoked" 0 "$(wc -c <"$TMP/gh.calls" | tr -d ' ')"
done

# 6. usage
"$HELPER" >/dev/null 2>&1; eq "6: no args -> exit 2" 2 $?
"$HELPER" "$TMP/does-not-exist" >/dev/null 2>&1; eq "6: missing dir -> exit 2" 2 $?
"$HELPER" "" >/dev/null 2>&1; eq "6: empty arg -> exit 2" 2 $?

# 7. final snapshot
eq "7: refs unchanged at the end" "$before" "$(snap "$TMP/c")"

echo
if [ "$fails" -eq 0 ]; then echo "All assertions passed."; exit 0; fi
echo "$fails assertion(s) failed."; exit 1
