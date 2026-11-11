#!/usr/bin/env bash
#
# Regression test for task #762 — block-env-commit.sh and scan-git-add.sh
# must let committed env TEMPLATES (.env.example, .env.sample, .env.template,
# .env.dist, .env.catalog.example: final suffix from the shared list in
# hooks/lib/env-names.sh) through when their content is placeholder-only, and
# must keep blocking real secret files and templates that carry a real secret.
#
# Hermetic: throwaway git repos under mktemp, hooks driven directly with a
# JSON payload, isolated git config (no host global excludes leak in). No
# network. Requires git + jq.
#
# Run:  hooks/tests/env-template-exemption.test.sh
# Exit: 0 = all assertions pass, 1 = at least one failed.

# shellcheck disable=SC2016  # test commands are literal text; no expansion wanted
# shellcheck disable=SC2015  # `A && pass || fail`: pass never fails

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMMIT_HOOK="$REPO_ROOT/hooks/block-env-commit.sh"
SCAN_HOOK="$REPO_ROOT/hooks/scan-git-add.sh"
READ_HOOK="$REPO_ROOT/hooks/block-env-read.sh"
LIB="$REPO_ROOT/hooks/lib/env-names.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Isolate git config (see block-env-commit-worktree.test.sh): the operator's
# real global excludes carry `.env*`, which would turn our untracked fixtures
# into "ignored" ones and defeat the wildcard-add assertions.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export HOME="$TMP/home"
export XDG_CONFIG_HOME="$TMP/home/.config"
mkdir -p "$XDG_CONFIG_HOME"

fails=0
cases=0
pass() { cases=$((cases + 1)); printf '  PASS: %s\n' "$1"; }
fail() { cases=$((cases + 1)); printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# Placeholder-only template body.
PLACEHOLDER_BODY=$'# template\nAPI_KEY=your_api_key_here\nDATABASE_URL=\nPORT=3000\nDEBUG=false\n'

# Secret-looking bodies, assembled at runtime so no literal credential sits in
# this file. DB_PASSWORD trips block-env-commit's sensitive-key layer; the AKIA
# id trips scan-git-add's aws-access-key pattern.
SECRET_BODY_COMMIT="$(printf 'DB_PASSWORD=%s\n' "hunter2-real-prod-pw-9f3a")"
SECRET_BODY_SCAN="$(printf 'REGION=eu\nACCESS_ID=%s%s\n' "AKI""A" "QWERTYUIOPASDFGH")"

# run_hook <hook-script> <cwd> <command> -> echoes the exit code.
run_hook() {
  local hook="$1" cwd="$2" cmd="$3" payload
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')"
  (
    cd "$cwd" || exit 99
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_PROJECT_DIR="$TMP/logs" \
      bash "$hook" <<<"$payload" >/dev/null 2>&1
  )
  echo "$?"
}

# make_repo <name> -> echoes the path of a committed, clean repo.
make_repo() {
  local d="$TMP/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@t.t
  git -C "$d" config user.name t
  printf '# fixture\n' > "$d/README.md"
  git -C "$d" add -A
  git -C "$d" commit -qm init
  echo "$d"
}

# write_file <repo> <relpath> <body>
write_file() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s' "$3" > "$1/$2"
}

# expect_code <label> <expected> <hook> <cwd> <cmd>
expect_code() {
  local label="$1" want="$2" code
  code="$(run_hook "$3" "$4" "$5")"
  if [ "$code" = "$want" ]; then pass "$label"
  else fail "$label (expected exit $want, got $code)"; fi
}

hook_label() { case "$1" in "$COMMIT_HOOK") echo block-env-commit ;; *) echo scan-git-add ;; esac; }

TEMPLATES=(scripts/.env.catalog.example .env.example .env.sample .env.template .env.dist)

# ============================================================================
echo "templates with placeholder content are allowed (both hooks)"
for hook in "$COMMIT_HOOK" "$SCAN_HOOK"; do
  h="$(hook_label "$hook")"
  for t in "${TEMPLATES[@]}"; do
    R="$(make_repo "a-$h-$(basename "$t")")"
    write_file "$R" "$t" "$PLACEHOLDER_BODY"
    expect_code "$h: git add $t -> allow" 0 "$hook" "$R" "git add $t"
    expect_code "$h: git -C <wt> add $t -> allow" 0 "$hook" "$TMP" "git -C $R add $t"
    expect_code "$h: git add -A with untracked $t -> allow" 0 "$hook" "$R" "git add -A"
    expect_code "$h: git -C <wt> add -A with untracked $t -> allow" 0 "$hook" "$TMP" "git -C $R add -A"
  done
done

echo "case-insensitive template suffix is still a template"
for hook in "$COMMIT_HOOK" "$SCAN_HOOK"; do
  h="$(hook_label "$hook")"
  R="$(make_repo "ci-$h")"
  write_file "$R" ".env.EXAMPLE" "$PLACEHOLDER_BODY"
  expect_code "$h: git add .env.EXAMPLE -> allow" 0 "$hook" "$R" "git add .env.EXAMPLE"
done

echo "several templates in one add are allowed"
for hook in "$COMMIT_HOOK" "$SCAN_HOOK"; do
  h="$(hook_label "$hook")"
  R="$(make_repo "multi-$h")"
  for t in "${TEMPLATES[@]}"; do write_file "$R" "$t" "$PLACEHOLDER_BODY"; done
  expect_code "$h: git add <all 5 templates> -> allow" 0 "$hook" "$R" \
    "git add scripts/.env.catalog.example .env.example .env.sample .env.template .env.dist"
done

# ============================================================================
echo "a staged template does not block a later add or commit"
for hook in "$COMMIT_HOOK" "$SCAN_HOOK"; do
  h="$(hook_label "$hook")"
  for t in scripts/.env.catalog.example .env.dist; do
    R="$(make_repo "later-$h-$(basename "$t")")"
    write_file "$R" "$t" "$PLACEHOLDER_BODY"
    git -C "$R" add "$t"
    write_file "$R" "src/other.txt" $'x\n'
    expect_code "$h: staged $t, later git -C add src/other.txt -> allow" 0 "$hook" "$TMP" "git -C $R add src/other.txt"
    expect_code "$h: staged $t, git commit -m x -> allow" 0 "$hook" "$R" "git commit -m x"
    expect_code "$h: staged $t, git -C <wt> commit -m x -> allow" 0 "$hook" "$TMP" "git -C $R commit -m x"
  done
done

# ============================================================================
echo "a real secret file is still blocked"
SECRET_FILES=(.env .env.prod .env.local .env.example.local .envrc)
for hook in "$COMMIT_HOOK" "$SCAN_HOOK"; do
  h="$(hook_label "$hook")"
  for f in "${SECRET_FILES[@]}"; do
    # scan-git-add's pre-existing env-file-added globs are `.env` / `.env.*`,
    # so `.envrc` is only covered by block-env-commit (unchanged by #762).
    if [ "$f" = ".envrc" ] && [ "$hook" = "$SCAN_HOOK" ]; then continue; fi
    R="$(make_repo "sec-$h-$f")"
    write_file "$R" "$f" "$PLACEHOLDER_BODY"
    expect_code "$h: git add $f -> block" 2 "$hook" "$R" "git add $f"
    expect_code "$h: git -C <wt> add $f -> block" 2 "$hook" "$TMP" "git -C $R add $f"
    expect_code "$h: git add -A with untracked $f -> block" 2 "$hook" "$R" "git add -A"
  done
  R="$(make_repo "sec2-$h")"
  write_file "$R" ".env.x.example" "$PLACEHOLDER_BODY"
  write_file "$R" ".env.prod" "$PLACEHOLDER_BODY"
  expect_code "$h: git add .env.x.example .env.prod -> block (second token)" 2 "$hook" "$R" \
    "git add .env.x.example .env.prod"
  expect_code "$h: git add .env.prod .env.x.example -> block (first token)" 2 "$hook" "$R" \
    "git add .env.prod .env.x.example"
done

echo "a real secret file staged (force-add) blocks the commit"
R="$(make_repo "sec-staged")"
write_file "$R" ".env.prod" "$PLACEHOLDER_BODY"
git -C "$R" add -f .env.prod
expect_code "block-env-commit: git commit with .env.prod staged -> block" 2 "$COMMIT_HOOK" "$R" "git commit -m x"

echo "a mixed template + real secret is still blocked by -A"
for hook in "$COMMIT_HOOK" "$SCAN_HOOK"; do
  h="$(hook_label "$hook")"
  R="$(make_repo "mixed-$h")"
  write_file "$R" ".env.example" "$PLACEHOLDER_BODY"
  write_file "$R" ".env.prod" "$PLACEHOLDER_BODY"
  expect_code "$h: git add -A with .env.example + .env.prod untracked -> block" 2 "$hook" "$R" "git add -A"
done

# ============================================================================
echo "wildcard add shapes with an untracked .env are blocked (#762 review-fix 1)"
for hook in "$COMMIT_HOOK" "$SCAN_HOOK"; do
  h="$(hook_label "$hook")"
  R="$(make_repo "wild-$h")"
  write_file "$R" ".env" "$PLACEHOLDER_BODY"
  write_file "$R" "a.txt" $'x\n'
  expect_code "$h: git add -Af with untracked .env -> block" 2 "$hook" "$R" "git add -Af"
  expect_code "$h: git add -Af && git commit -m wip -> block" 2 "$hook" "$R" "git add -Af && git commit -m wip"
  expect_code "$h: git add a.txt && (git add -A) -> block" 2 "$hook" "$R" "git add a.txt && (git add -A)"
  expect_code "$h: git add -vA -> block" 2 "$hook" "$R" "git add -vA"
  expect_code "$h: git add a.txt -> allow" 0 "$hook" "$R" "git add a.txt"

  U="$(make_repo "upd-$h")"
  write_file "$U" ".env.prod" "$PLACEHOLDER_BODY"
  git -C "$U" add -f .env.prod
  git -C "$U" commit -qm "track env"
  write_file "$U" ".env.prod" $'CHANGED=1\n'
  expect_code "$h: git add -u with modified tracked env file -> block" 2 "$hook" "$U" "git add -u"
done

# ============================================================================
echo "a template carrying a real-looking secret is still blocked"
for t in "${TEMPLATES[@]}"; do
  R="$(make_repo "tsec-commit-$(basename "$t")")"
  write_file "$R" "$t" "$SECRET_BODY_COMMIT"
  expect_code "block-env-commit: git add $t with real secret -> block" 2 "$COMMIT_HOOK" "$R" "git add $t"
  expect_code "block-env-commit: git add -A with secret $t -> block" 2 "$COMMIT_HOOK" "$R" "git add -A"
  git -C "$R" add -f "$t"
  expect_code "block-env-commit: git commit with secret $t staged -> block" 2 "$COMMIT_HOOK" "$R" "git commit -m x"
done

# scan-git-add skips .env.example/.env.sample/.env.template content by its
# pre-existing skips.path_substrings (unchanged here); .env.dist and
# .env.catalog.example are content-scanned.
for t in scripts/.env.catalog.example .env.dist; do
  R="$(make_repo "tsec-scan-$(basename "$t")")"
  write_file "$R" "$t" "$SECRET_BODY_SCAN"
  expect_code "scan-git-add: git add $t with AWS key id -> block" 2 "$SCAN_HOOK" "$R" "git add $t"
  expect_code "scan-git-add: git -C <wt> add $t with AWS key id -> block" 2 "$SCAN_HOOK" "$TMP" "git -C $R add $t"
  expect_code "scan-git-add: git add -A with AWS key id in $t -> block" 2 "$SCAN_HOOK" "$R" "git add -A"
done

# ============================================================================
echo "drift guard: the template suffix list lives only in hooks/lib/env-names.sh"

# Lines that are comments (first non-blank char is #) are dropped; everything
# else is scanned. A line "hardcodes the alternation" when, outside comment
# lines, it names two or more DISTINCT words of the template-suffix set as
# whole words (neighbours are non-letters) in a `|`-joined or space-separated
# list, which catches `example|sample`,
# `.env.example|.env.sample`, `example sample template dist`, etc.
hardcodes_alternation() {
  awk '
    /^[[:space:]]*#/ { next }
    {
      line = tolower($0); n = 0
      split("example sample template dist", w, " ")
      for (k = 1; k <= 4; k++) {
        if (match(" " line " ", "[^a-z](" w[k] ")[^a-z]")) n++
      }
      # Code-shaped lists only: `|`-joined or space-separated. Prose that
      # lists the names with `/` or `,` (user-facing messages) is not logic.
      listy = (index(line, "|") > 0) || ((" " line " ") ~ /[^a-z](example|sample|template|dist) (example|sample|template|dist)[^a-z]/)
      if (n >= 2 && listy) { printf "%d: %s\n", NR, $0; bad = 1 }
    }
    END { exit bad ? 0 : 1 }
  ' "$1"
}

# Self-test of the detector on synthetic input (so a vacuous pass is impossible).
DRIFT_FIX="$TMP/drift"
mkdir -p "$DRIFT_FIX"
printf '%s\n' '# example|sample|template|dist in a comment only' 'x=1' > "$DRIFT_FIX/comment-only.sh"
printf '%s\n' 'case "$b" in *.example|*.sample|*.template|*.dist) ;; esac' > "$DRIFT_FIX/pipe.sh"
printf '%s\n' 'for s in example sample template dist; do :; done' > "$DRIFT_FIX/spaced.sh"
printf '%s\n' '  grep -E "\.(example|sample|template)$"' > "$DRIFT_FIX/ere.sh"
printf '%s\n' 'name=".env.example"; templates_dir=x' > "$DRIFT_FIX/single.sh"
hardcodes_alternation "$DRIFT_FIX/comment-only.sh" >/dev/null && fail "detector: comment-only line flagged" || pass "detector: comment-only line ignored"
hardcodes_alternation "$DRIFT_FIX/pipe.sh" >/dev/null && pass "detector: case-glob alternation flagged" || fail "detector: case-glob alternation missed"
hardcodes_alternation "$DRIFT_FIX/spaced.sh" >/dev/null && pass "detector: space-separated list flagged" || fail "detector: space-separated list missed"
hardcodes_alternation "$DRIFT_FIX/ere.sh" >/dev/null && pass "detector: ERE alternation flagged" || fail "detector: ERE alternation missed"
hardcodes_alternation "$DRIFT_FIX/single.sh" >/dev/null && fail "detector: single word flagged" || pass "detector: single suffix word ignored"

# Positive control: the lib itself defines the list.
if grep -q '^export ENV_TEMPLATE_SUFFIXES="example sample template dist"$' "$LIB"; then
  pass "lib defines ENV_TEMPLATE_SUFFIXES with the four suffixes"
else
  fail "lib does not define ENV_TEMPLATE_SUFFIXES as expected"
fi

for hook in "$READ_HOOK" "$COMMIT_HOOK" "$SCAN_HOOK"; do
  name="$(basename "$hook")"
  if hits="$(hardcodes_alternation "$hook")"; then
    fail "$name hardcodes the template suffix alternation: $(printf '%s' "$hits" | head -n1)"
  else
    pass "$name does not hardcode the template suffix alternation"
  fi
  if grep -Eq '^[[:space:]]*source[[:space:]]+"\$\{CLAUDE_PLUGIN_ROOT\}/hooks/lib/env-names\.sh"' "$hook" \
     || grep -q 'lib/env-names.sh' "$hook"; then
    pass "$name sources hooks/lib/env-names.sh"
  else
    fail "$name does not source hooks/lib/env-names.sh"
  fi
done

# The catalogue exempts by reference to the shared list, not by its own list.
if jq -e '.patterns[] | select(.name=="env-file-added") | .exempt == "env-template"' \
     "$REPO_ROOT/hooks/patterns/scan-git-add.json" >/dev/null 2>&1; then
  pass "scan-git-add.json: env-file-added carries exempt=env-template"
else
  fail "scan-git-add.json: env-file-added lacks exempt=env-template"
fi

# Behavioural drift check: a suffix appended to the shared list at runtime
# (via a patched COPY of the plugin root) flows into both commit-side hooks
# without any hook edit. A copy keeps the real lib untouched.
PR="$TMP/plugin-copy"
mkdir -p "$PR"
cp -R "$REPO_ROOT/hooks" "$PR/hooks"
sed -i.bak 's/^export ENV_TEMPLATE_SUFFIXES="example sample template dist"$/export ENV_TEMPLATE_SUFFIXES="example sample template dist zzcustom"/' "$PR/hooks/lib/env-names.sh"
rm -f "$PR/hooks/lib/env-names.sh.bak"
run_hook_pr() {
  local hook="$1" cwd="$2" cmd="$3" payload
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')"
  ( cd "$cwd" || exit 99
    CLAUDE_PLUGIN_ROOT="$PR" CLAUDE_PROJECT_DIR="$TMP/logs" bash "$PR/hooks/$hook" <<<"$payload" >/dev/null 2>&1 )
  echo "$?"
}
R="$(make_repo "drift-behaviour")"
write_file "$R" ".env.zzcustom" "$PLACEHOLDER_BODY"
for hook in block-env-commit.sh scan-git-add.sh; do
  code="$(run_hook_pr "$hook" "$R" "git add .env.zzcustom")"
  [ "$code" = "0" ] && pass "$hook: suffix added only to the lib is honoured (allow)" \
                    || fail "$hook: suffix added only to the lib not honoured (got $code)"
done
for hook in "$COMMIT_HOOK" "$SCAN_HOOK"; do
  expect_code "$(hook_label "$hook"): .env.zzcustom with the real lib -> block" 2 "$hook" "$R" "git add .env.zzcustom"
done

# ---- review-fix cycle 2: nested-shell wrappers ------------------------------
# `sh -c '...'` / `eval "..."` hide the git verb inside a quoted string; the
# hook must still see it. core.excludesFile is pinned to /dev/null per repo so
# the untracked env file is not hidden by any global exclude.
R="$(make_repo "nested-shell")"
git -C "$R" config core.excludesFile /dev/null
write_file "$R" ".env.prod" "$SECRET_BODY_COMMIT"
expect_code "block-env-commit: untracked .env.prod, git status; sh -c 'git add -A' -> block" 2 "$COMMIT_HOOK" "$R" "git status; sh -c 'git add -A'"
expect_code "block-env-commit: untracked .env.prod, git status && eval \"git add .\" -> block" 2 "$COMMIT_HOOK" "$R" 'git status && eval "git add ."'
expect_code "block-env-commit: untracked .env.prod, git add a.txt -> allow" 0 "$COMMIT_HOOK" "$R" "git add a.txt"
git -C "$R" add -f .env.prod
expect_code "block-env-commit: .env.prod staged, git status; sh -c 'git commit -m x' -> block" 2 "$COMMIT_HOOK" "$R" "git status; sh -c 'git commit -m x'"
R="$(make_repo "nested-shell-template")"
git -C "$R" config core.excludesFile /dev/null
write_file "$R" ".env.example" "$PLACEHOLDER_BODY"
git -C "$R" add .env.example
expect_code "block-env-commit: placeholder template staged, git commit -m wip -> allow" 0 "$COMMIT_HOOK" "$R" "git commit -m wip"

# ---- review-fix cycle 3: unresolved raw git add/commit occurrences ----------
# A safe-looking first segment must not mask a nested-shell `git add|commit`
# later in the same command line.
R="$(make_repo "nested-unresolved-add")"
git -C "$R" config core.excludesFile /dev/null
write_file "$R" ".env.prod" "$SECRET_BODY_COMMIT"
expect_code "block-env-commit: untracked .env.prod, git add README.md && sh -c 'git add -A' -> block" 2 "$COMMIT_HOOK" "$R" "git add README.md && sh -c 'git add -A'"
expect_code "block-env-commit: untracked .env.prod, git add README.md && eval \"git add -A\" -> block" 2 "$COMMIT_HOOK" "$R" 'git add README.md && eval "git add -A"'
expect_code "block-env-commit: untracked .env.prod, git add README.md && bash -c \"git add .\" -> block" 2 "$COMMIT_HOOK" "$R" 'git add README.md && bash -c "git add ."'
expect_code "block-env-commit: untracked .env.prod, git add README.md && sh -c 'git add -f .env.prod' -> block" 2 "$COMMIT_HOOK" "$R" "git add README.md && sh -c 'git add -f .env.prod'"
expect_code "block-env-commit: untracked .env.prod, plain git add README.md -> allow" 0 "$COMMIT_HOOK" "$R" "git add README.md"

R="$(make_repo "nested-unresolved-commit")"
git -C "$R" config core.excludesFile /dev/null
write_file "$R" ".env.live" "$SECRET_BODY_COMMIT"
git -C "$R" add -f .env.live
git -C "$R" commit -qm "track env"
write_file "$R" ".env.live" "$(printf 'DB_PASSWORD=%s\n' "changed-real-prod-pw-1b2c")"
expect_code "block-env-commit: tracked env modified, git commit -m x && sh -c 'git commit -am y' -> block" 2 "$COMMIT_HOOK" "$R" "git commit -m x && sh -c 'git commit -am y'"

R="$(make_repo "commit-message-mention")"
git -C "$R" config core.excludesFile /dev/null
printf 'change\n' >> "$R/README.md"
git -C "$R" add README.md
expect_code "block-env-commit: only README staged, git commit -m \"mention .env.prod only\" -> allow" 0 "$COMMIT_HOOK" "$R" 'git commit -m "mention .env.prod only"'

# ============================================================================
echo
echo "cases: $cases, failures: $fails"
[ "$fails" -eq 0 ] && exit 0 || exit 1
