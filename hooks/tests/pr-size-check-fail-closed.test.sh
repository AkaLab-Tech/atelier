#!/usr/bin/env bash
#
# Regression test for task #414 — atelier-pr-size-check must
#   (#370) fail closed: any failed git/gh call or bad payload exits 2, never "0 / OK"
#   (#397) diff against origin/<base> when it exists (local base as a noted fallback)
#   (#361) keep exempt globs as globs (no pathname expansion against the cwd)
#   (#380) exempt generated/ and __generated__/ at any depth, root included
#   (#384) cap exempt-only PRs (prSize.maxExemptOnlyLines, default 400)
#   plus: additive config, root tracking files, gh run from --project, and a
#   truncated gh file list exits 2.
#
# Hermetic: temp git repos with a local bare origin, a gh shim on PATH that
# emits the real `--json files,changedFiles` object, no network. bash 3.2 safe.
#
# Run:  hooks/tests/pr-size-check-fail-closed.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/atelier-pr-size-check"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

command -v jq >/dev/null 2>&1 || { echo "  SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "  SKIP: git not on PATH"; exit 0; }

# ---------- assertion helpers ----------
assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
assert_contains() { # name haystack needle
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac
}
assert_not_contains() { # name haystack needle
  case "$2" in *"$3"*) fail "$1 (unexpected '$3' in: $2)" ;; *) pass "$1" ;; esac
}
counted_line() { printf '%s\n' "$OUT" | grep '^Counted:' || true; }
exempt_line()  { printf '%s\n' "$OUT" | grep '^Exempt:' || true; }

# ---------- gh shim ----------
# GH_MODE=fail -> exit 1; otherwise cat $GH_PAYLOAD. Logs its physical cwd.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SHIMEOF'
#!/usr/bin/env bash
pwd -P > "$GH_CWD_LOG"
if [ "${GH_MODE:-ok}" = "fail" ]; then
  echo "gh: simulated failure" >&2
  exit 1
fi
cat "$GH_PAYLOAD"
SHIMEOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export GH_CWD_LOG="$TMP/gh.cwd"
export GH_PAYLOAD="$TMP/payload.json"
export GH_MODE=ok

# pr_payload <changedFiles> <path:add:del>...
pr_payload() {
  local changed="$1" arr="" sep="" spec p a d
  shift
  for spec in "$@"; do
    IFS=: read -r p a d <<<"$spec"
    arr="${arr}${sep}{\"path\":\"${p}\",\"additions\":${a},\"deletions\":${d}}"
    sep=","
  done
  printf '{"files":[%s],"changedFiles":%s}\n' "$arr" "$changed" > "$GH_PAYLOAD"
}

# ---------- repo helpers ----------
N=0
R=""
mkrepo() {
  N=$((N + 1))
  R="$TMP/repo$N"
  local origin="$TMP/origin$N.git"
  mkdir -p "$R"
  git init -q --bare "$origin"
  git -C "$R" init -q
  git -C "$R" symbolic-ref HEAD refs/heads/main
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name t
  git -C "$R" config commit.gpgsign false
  echo base > "$R/README.md"
  git -C "$R" add -A
  git -C "$R" commit -q -m base
  git -C "$R" remote add origin "$origin"
  git -C "$R" push -q origin main
}
add_lines() { # path n  (relative to $R)
  mkdir -p "$(dirname "$R/$1")"
  seq 1 "$2" | sed 's/^/line /' > "$R/$1"
}
commit_all() {
  git -C "$R" add -A
  git -C "$R" commit -q -m "$1"
}
write_cfg() { printf '%s\n' "$1" > "$R/.atelier.json"; }

# run <cwd> <args...>  -> sets OUT, ERR, RC
run() {
  local cwd="$1"
  shift
  (cd "$cwd" && bash "$SCRIPT" "$@") >"$TMP/o" 2>"$TMP/e"
  RC=$?
  OUT="$(cat "$TMP/o")"
  ERR="$(cat "$TMP/e")"
}
assert_never_ok() { # name
  assert_not_contains "$1: no OK verdict" "$OUT" "Verdict:     OK"
  assert_not_contains "$1: no 0/0 counted line" "$OUT" "0 line(s) across 0 file(s)"
}

OTHER="$TMP/other"
mkdir -p "$OTHER"

# =============================================================================
echo "Fail closed (#370)"
mkrepo
git -C "$R" checkout -q -b feat
add_lines src/a.ts 5
commit_all feat

run "$OTHER" --branch feat --base nope --project "$R"
assert_eq "nonexistent base exits 2" 2 "$RC"
assert_contains "nonexistent base names the ref" "$ERR" "nope"
assert_never_ok "nonexistent base"

run "$OTHER" --branch ghost --project "$R"
assert_eq "nonexistent branch exits 2" 2 "$RC"
assert_contains "nonexistent branch names the ref" "$ERR" "ghost"
assert_never_ok "nonexistent branch"

pr_payload 1 "src/a.ts:5:0"
GH_MODE=fail run "$OTHER" --pr 7 --project "$R"
assert_eq "failing gh pr view exits 2" 2 "$RC"
assert_contains "failing gh pr view names the PR" "$ERR" "gh pr view 7"
assert_never_ok "failing gh"

printf 'this is not json\n' > "$GH_PAYLOAD"
run "$OTHER" --pr 8 --project "$R"
assert_eq "invalid gh JSON exits 2" 2 "$RC"
assert_contains "invalid gh JSON names the PR" "$ERR" "gh pr view 8"
assert_never_ok "invalid gh JSON"

printf '[]\n' > "$GH_PAYLOAD"
run "$OTHER" --pr 9 --project "$R"
assert_eq "wrong-shape gh JSON exits 2" 2 "$RC"
assert_never_ok "wrong-shape gh JSON"

# =============================================================================
echo "Diff against origin/<base> (#397)"
mkrepo
# main gets a large change, pushed; the feature branches from it; local main
# is then rewound so it is behind origin/main.
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do add_lines "big/f$i.ts" 30; done
commit_all big-base
git -C "$R" push -q origin main
git -C "$R" checkout -q -b feat
add_lines src/small.ts 3
commit_all small
git -C "$R" checkout -q main
git -C "$R" reset -q --hard HEAD~1

run "$OTHER" --branch feat --project "$R"
assert_eq "stale local base: exit 0" 0 "$RC"
assert_contains "stale local base: resolved ref printed" "$OUT" "Branch:      feat ... origin/main"
assert_eq "stale local base: only the feature file counted" \
  "Counted:     3 line(s) across 1 file(s)" "$(counted_line)"
assert_not_contains "stale local base: no spurious OVERSIZE" "$OUT" "OVERSIZE"

# Only a local base: origin/main removed.
git -C "$R" update-ref -d refs/remotes/origin/main
run "$OTHER" --branch feat --project "$R"
assert_contains "local-only base: note printed" "$OUT" "Base: main (local; origin/main not found)"
assert_contains "local-only base: resolved ref printed" "$OUT" "Branch:      feat ... main"
assert_eq "local-only base: diffs against local main" \
  "Counted:     363 line(s) across 13 file(s)" "$(counted_line)"
assert_eq "local-only base: OVERSIZE exit 1 (stale local base used)" 1 "$RC"

# Neither origin/main nor local main.
git -C "$R" checkout -q feat
git -C "$R" branch -q -D main
run "$OTHER" --branch feat --project "$R"
assert_eq "no base anywhere exits 2" 2 "$RC"
assert_contains "no base anywhere names the base" "$ERR" "main"
assert_never_ok "no base anywhere"

# =============================================================================
echo "Globs stay globs (#361)"
for variant in one several; do
  mkrepo
  git -C "$R" checkout -q -b feat
  add_lines src/x.stories.tsx 7
  add_lines src/y.ts 4
  add_lines src/z.spec.ts 6
  commit_all feat
  write_cfg '{"prSize":{"exempt":["**/*.spec.*","**/*.stories.*"]}}'
  # Untracked files in the project cwd that match the globs exactly.
  mkdir -p "$R/sub"
  : > "$R/sub/one.stories.tsx"
  : > "$R/sub/one.spec.ts"
  if [ "$variant" = "several" ]; then
    : > "$R/sub/two.stories.tsx"
    : > "$R/sub/three.stories.tsx"
    : > "$R/sub/two.spec.ts"
    : > "$R/sub/three.spec.ts"
  fi
  run "$R" --branch feat
  assert_eq "$variant match(es) in cwd: exit 0" 0 "$RC"
  assert_eq "$variant match(es) in cwd: counted" "Counted:     4 line(s) across 1 file(s)" "$(counted_line)"
  assert_eq "$variant match(es) in cwd: exempt" "Exempt:      13 line(s) across 2 file(s)" "$(exempt_line)"
done

echo "Palabrium regression: same figures from project root and unrelated cwd"
mkrepo
git -C "$R" checkout -q -b feat
add_lines src/a.ts 10
add_lines lib/c.ts 5
add_lines src/a.test.ts 20
add_lines tests/b.ts 8
add_lines db/migrations/001.sql 6
add_lines schema.sql 3
commit_all palabrium
write_cfg '{"prSize":{"exempt":["**/*.test.*","**/tests/**","**/migrations/**","**/*.sql"]}}'
# Files in the project root and in the unrelated cwd that match the globs.
mkdir -p "$R/pkg/tests" "$OTHER/pkg/tests" "$OTHER/m/migrations"
: > "$R/pkg/a.test.js"; : > "$R/pkg/tests/t.js"
: > "$OTHER/pkg/a.test.js"; : > "$OTHER/pkg/tests/t.js"; : > "$OTHER/m/migrations/1.sql"; : > "$OTHER/q.sql"

run "$R" --branch feat
root_counted="$(counted_line)"; root_exempt="$(exempt_line)"
assert_eq "palabrium root: counted" "Counted:     15 line(s) across 2 file(s)" "$root_counted"
assert_eq "palabrium root: exempt" "Exempt:      37 line(s) across 4 file(s)" "$root_exempt"
run "$OTHER" --branch feat --project "$R"
assert_eq "palabrium other cwd: counted identical" "$root_counted" "$(counted_line)"
assert_eq "palabrium other cwd: exempt identical" "$root_exempt" "$(exempt_line)"

# =============================================================================
echo "Additive config"
mkrepo
git -C "$R" checkout -q -b feat
add_lines docs/guide.md 9
add_lines pnpm-lock.yaml 11
add_lines src/a.ts 4
commit_all feat
write_cfg '{"prSize":{"exempt":["docs/**"]}}'
run "$OTHER" --branch feat --project "$R"
assert_eq "docs/** + defaults: counted" "Counted:     4 line(s) across 1 file(s)" "$(counted_line)"
assert_eq "docs/** + defaults: exempt" "Exempt:      20 line(s) across 2 file(s)" "$(exempt_line)"

write_cfg '{"prSize":{"maxLines":300}}'
run "$OTHER" --branch feat --project "$R"
assert_eq "missing exempt list = defaults only: counted" "Counted:     13 line(s) across 2 file(s)" "$(counted_line)"
assert_eq "missing exempt list = defaults only: exempt" "Exempt:      11 line(s) across 1 file(s)" "$(exempt_line)"

write_cfg '{"prSize":{"exempt":[]}}'
run "$OTHER" --branch feat --project "$R"
assert_eq "empty exempt list = defaults only: counted" "Counted:     13 line(s) across 2 file(s)" "$(counted_line)"
assert_eq "empty exempt list = defaults only: exempt" "Exempt:      11 line(s) across 1 file(s)" "$(exempt_line)"

# =============================================================================
echo "Generated dirs (#380)"
mkrepo
git -C "$R" checkout -q -b feat
add_lines generated/a.ts 2
add_lines __generated__/b.ts 3
add_lines src/generated/c.ts 4
add_lines a/b/__generated__/d.ts 5
add_lines src/real.ts 6
commit_all feat
run "$OTHER" --branch feat --project "$R"
assert_eq "generated dirs: counted" "Counted:     6 line(s) across 1 file(s)" "$(counted_line)"
assert_eq "generated dirs: exempt" "Exempt:      14 line(s) across 4 file(s)" "$(exempt_line)"

# =============================================================================
echo "Exempt-only cap (#384)"
exempt_only() { # lines -> sets up repo with one exempt file of N lines
  mkrepo
  git -C "$R" checkout -q -b feat
  add_lines tests/big.ts "$1"
  commit_all feat
}
exempt_only 401
run "$OTHER" --branch feat --project "$R"
assert_eq "exempt-only 401: OVERSIZE exit 1" 1 "$RC"
assert_contains "exempt-only 401: verdict" "$OUT" "Verdict:     OVERSIZE"
assert_contains "exempt-only 401: reason" "$OUT" "exempt-only PR"

exempt_only 400
run "$OTHER" --branch feat --project "$R"
assert_eq "exempt-only exactly 400: exit 0" 0 "$RC"
assert_contains "exempt-only exactly 400: OK" "$OUT" "Verdict:     OK"

exempt_only 399
run "$OTHER" --branch feat --project "$R"
assert_eq "exempt-only 399: exit 0" 0 "$RC"

exempt_only 11
write_cfg '{"prSize":{"maxExemptOnlyLines":10}}'
run "$OTHER" --branch feat --project "$R"
assert_eq "cap overridden to 10, 11 lines: exit 1" 1 "$RC"
assert_contains "cap overridden: reason" "$OUT" "exempt-only PR"
exempt_only 10
write_cfg '{"prSize":{"maxExemptOnlyLines":10}}'
run "$OTHER" --branch feat --project "$R"
assert_eq "cap overridden to 10, 10 lines: exit 0" 0 "$RC"

exempt_only 450
write_cfg '{"prSize":{"maxExemptOnlyLines":500}}'
run "$OTHER" --branch feat --project "$R"
assert_eq "cap raised to 500, 450 lines: exit 0" 0 "$RC"

for bad in '"x"' '-1' '1.5'; do
  write_cfg "{\"prSize\":{\"maxExemptOnlyLines\":$bad}}"
  run "$OTHER" --branch feat --project "$R"
  assert_eq "maxExemptOnlyLines=$bad exits 2" 2 "$RC"
  assert_contains "maxExemptOnlyLines=$bad names the key" "$ERR" "maxExemptOnlyLines"
  assert_never_ok "maxExemptOnlyLines=$bad"
done

# =============================================================================
echo "Tracking files: --branch before/after the tracking commit and --pr agree"
mkrepo
git -C "$R" checkout -q -b feat
add_lines src/a.ts 5
commit_all src
run "$OTHER" --branch feat --project "$R"
before_counted="$(counted_line)"
assert_eq "tracking: before-commit counted" "Counted:     5 line(s) across 1 file(s)" "$before_counted"

add_lines ROADMAP.md 12
add_lines IN_PROGRESS.md 3
add_lines HISTORY.md 4
commit_all tracking
run "$OTHER" --branch feat --project "$R"
assert_eq "tracking: after-commit counted unchanged" "$before_counted" "$(counted_line)"
assert_eq "tracking: after-commit exempt" "Exempt:      19 line(s) across 3 file(s)" "$(exempt_line)"
branch_exempt="$(exempt_line)"

pr_payload 4 "src/a.ts:5:0" "ROADMAP.md:12:0" "IN_PROGRESS.md:3:0" "HISTORY.md:4:0"
run "$OTHER" --pr 5 --project "$R"
assert_eq "tracking: --pr counted equals --branch" "$before_counted" "$(counted_line)"
assert_eq "tracking: --pr exempt equals --branch" "$branch_exempt" "$(exempt_line)"

# =============================================================================
echo "gh invocation"
mkrepo
pr_payload 1 "src/a.ts:5:0"
rm -f "$GH_CWD_LOG"
run "$OTHER" --pr 5 --project "$R"
assert_eq "--pr without --repo: exit 0" 0 "$RC"
assert_eq "--pr without --repo: gh ran from --project" "$(cd "$R" && pwd -P)" "$(cat "$GH_CWD_LOG" 2>/dev/null)"

pr_payload 5 "src/a.ts:5:0" "src/b.ts:5:0"
run "$OTHER" --pr 5 --project "$R"
assert_eq "truncated file list exits 2" 2 "$RC"
assert_contains "truncated file list message" "$ERR" "size cannot be evaluated"
assert_never_ok "truncated file list"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "pr-size-check-fail-closed (#414): all assertions passed."
  exit 0
else
  echo "pr-size-check-fail-closed (#414): $fails assertion(s) failed."
  exit 1
fi
