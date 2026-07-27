#!/usr/bin/env bash
#
# Regression test for #38 (audit#160) — planStorage must be declared, and must
# not contradict the repo's own ignore rules.
#
# The bug: this repo's committed `.atelier.json` carried NO `planStorage` key.
# Both `commands/plan-task.md` and `commands/next-task.md` resolve the flag with
# `jq -r '.planStorage // "committed"'`, so an absent key silently means
# `committed` — the mode in which /atelier:plan-task Phase 4 runs
# `git add .plan/<id>.md`. But this checkout lists `.plan/` in
# `.git/info/exclude` (next to the local-only ROADMAP.md / IN_PROGRESS.md /
# HISTORY.md / roadmap/ mirror entries for the github-project backend), so that
# `git add` exits 1 on an ignored path. Agents "recovered" from the failure with
# `git add -f` and re-committed plan files the project had deliberately stopped
# producing (PRs #314 / #315 committed 8 `.plan/*.md` each).
#
# The fix is a single explicit line: `"planStorage": "resident"`. This test
# locks it, and — more importantly — locks the general invariant behind it, so
# the same class of drift cannot come back in another shape.
#
# Assertion groups:
#   1 — JSON validity: `.atelier.json` and `templates/atelier.template.json`
#       parse (same check CI runs, `python3 -m json.tool`).
#   2 — Regression: `.atelier.json` DECLARES `planStorage` (key present, not
#       merely defaulted), its value is one of the three legal contracts, and
#       for this repo it is `resident`. Fails against the pre-fix state.
#   3 — Invariant: the resolved `planStorage` and the actual ignore status of
#       `.plan/` must be compatible. `committed` + git-ignored `.plan/` is a
#       contradiction. The ignore probe is `git check-ignore`, which sees
#       `.gitignore` AND `.git/info/exclude` alike — a `.gitignore` grep would
#       have missed the original bug entirely, since it hid in info/exclude.
#   4 — Behavioral proof (throwaway repo): `git add` on a path ignored via
#       `.git/info/exclude` really does exit non-zero and stage nothing — that
#       is the /atelier:plan-task Phase 4 failure this task prevents. Includes
#       the control case (same add succeeds once the exclude entry is gone).
#   5 — Template: `templates/atelier.template.json` still defaults to
#       `committed` for fresh installs, but documents `resident` as a legal
#       third value.
#
# Hermetic: reads committed files + one throwaway `mktemp -d` git repo removed
# by an EXIT trap. No network, no `gh`, no mutation of the real repo.
#
# Run:  hooks/tests/plan-storage-config-consistency.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

# ATELIER_TEST_REPO_ROOT exists so this test can be pointed at a fixture copy of
# the repo (used to prove it fails against the pre-fix config). Unset in normal
# and CI runs, where it resolves to the real repo root like its siblings.
REPO_ROOT="${ATELIER_TEST_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ATELIER_JSON="$REPO_ROOT/.atelier.json"
TEMPLATE="$REPO_ROOT/templates/atelier.template.json"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

# chk_prose <file> <fixed-string> <label>
chk_prose() {
  local file="$1" pattern="$2" label="$3"
  if grep -qF "$pattern" "$file" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $file"
  fi
}

# json_ok <file> — 0 when the file parses as JSON.
json_ok() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool < "$1" > /dev/null 2>&1
  elif command -v jq >/dev/null 2>&1; then
    jq -e . < "$1" > /dev/null 2>&1
  else
    return 2
  fi
}

# json_has_key <file> <key> — 0 when the top-level key is present.
json_has_key() {
  if command -v jq >/dev/null 2>&1; then
    jq -e --arg k "$2" 'has($k)' < "$1" > /dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1])) else 1)' "$1" "$2"
  else
    return 2
  fi
}

# json_str <file> <key> — prints the top-level string value, empty if absent.
json_str() {
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$2" '.[$k] // ""' < "$1" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2" 2>/dev/null
  else
    return 2
  fi
}

if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP: neither jq nor python3 available — cannot inspect JSON config."
  echo ""
  echo "plan-storage-config-consistency (#38): skipped (no JSON tool)."
  exit 0
fi

# ---------------------------------------------------------------------------
# Group 1: JSON validity (mirrors the CI json.tool step)
# ---------------------------------------------------------------------------

if json_ok "$ATELIER_JSON"; then
  pass "config: .atelier.json parses as JSON"
else
  fail "config: .atelier.json must parse as JSON ($ATELIER_JSON)"
fi

if json_ok "$TEMPLATE"; then
  pass "template: atelier.template.json parses as JSON"
else
  fail "template: atelier.template.json must parse as JSON ($TEMPLATE)"
fi

# ---------------------------------------------------------------------------
# Group 2: the regression — planStorage is DECLARED, not defaulted
# ---------------------------------------------------------------------------
#
# `jq -r '.planStorage // "committed"'` always yields a value, so "the resolve
# works" proves nothing. The bug WAS the absent key. Assert presence directly.

if json_has_key "$ATELIER_JSON" planStorage; then
  pass "config: .atelier.json declares planStorage explicitly (key present)"
else
  fail "config: .atelier.json has NO planStorage key — an absent key resolves to 'committed' via \`jq -r '.planStorage // \"committed\"'\`, which is the audit#160 bug"
fi

PLAN_STORAGE="$(json_str "$ATELIER_JSON" planStorage)"
[ -n "$PLAN_STORAGE" ] || PLAN_STORAGE="committed"   # same default the commands apply

case "$PLAN_STORAGE" in
  committed | local | resident)
    pass "config: planStorage='$PLAN_STORAGE' is one of the three legal contracts"
    ;;
  *)
    fail "config: planStorage='$PLAN_STORAGE' is not a legal contract (expected committed | local | resident)"
    ;;
esac

if [ "$PLAN_STORAGE" = "resident" ]; then
  pass "config: this repo stores plans in the backend item (planStorage=resident)"
else
  fail "config: this repo's planStorage must be 'resident' — the github-project backend holds the plan in the item body and no .plan/<id>.md exists here (got '$PLAN_STORAGE')"
fi

if json_has_key "$ATELIER_JSON" _planStorage_comment; then
  pass "config: planStorage carries a house-style _planStorage_comment"
else
  fail "config: planStorage must be documented by a _planStorage_comment sibling key"
fi

# ---------------------------------------------------------------------------
# Group 3: the invariant — planStorage must not contradict the ignore rules
# ---------------------------------------------------------------------------
#
# `git check-ignore` is the probe on purpose: it consults .gitignore AND
# .git/info/exclude (and the global excludes). The original bug lived in
# .git/info/exclude, where a `.gitignore` grep sees nothing.

git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1
_is_git=$?

if [ "$_is_git" -ne 0 ]; then
  pass "invariant: skipped (repo root is not a git checkout) — config assertions still enforced"
else
  git -C "$REPO_ROOT" check-ignore -q .plan/ 2>/dev/null
  _ignore_rc=$?

  case "$_ignore_rc" in
    0) PLAN_DIR_IGNORED=yes ;;
    1) PLAN_DIR_IGNORED=no ;;
    *) PLAN_DIR_IGNORED=unknown ;;
  esac

  if [ "$PLAN_DIR_IGNORED" = "unknown" ]; then
    fail "invariant: \`git check-ignore -q .plan/\` errored (rc=$_ignore_rc) in $REPO_ROOT — cannot evaluate consistency"
  elif [ "$PLAN_STORAGE" = "committed" ] && [ "$PLAN_DIR_IGNORED" = "yes" ]; then
    fail "invariant: planStorage='committed' but \`.plan/\` is git-ignored in $REPO_ROOT — /atelier:plan-task Phase 4 runs \`git add .plan/<id>.md\`, which exits 1 on an ignored path (audit#160). Declare planStorage=local or =resident, or stop ignoring .plan/"
  else
    pass "invariant: planStorage='$PLAN_STORAGE' is compatible with .plan/ ignored=$PLAN_DIR_IGNORED"
  fi

  # This repo specifically: .plan/ IS ignored (via .git/info/exclude), which is
  # precisely why 'committed' was unworkable here.
  if [ "$PLAN_DIR_IGNORED" = "yes" ]; then
    pass "invariant: .plan/ is git-ignored here — the precondition that made 'committed' fail"
  else
    pass "invariant: .plan/ is not ignored here — 'committed' would be workable (config still explicit)"
  fi
fi

# ---------------------------------------------------------------------------
# Group 4: behavioral — `git add` on an info/exclude-ignored path fails
# ---------------------------------------------------------------------------
#
# Grounds the invariant in observed git behaviour instead of prose. Asserted on
# exit status only — git's English error text varies across versions.

_tmpdir="$(mktemp -d)"
_cleanup() { rm -rf "$_tmpdir"; }
trap _cleanup EXIT

_repo="$_tmpdir/repo"
mkdir -p "$_repo"
git init -q "$_repo" 2>/dev/null
git -C "$_repo" config user.email "test@atelier.local"
git -C "$_repo" config user.name "Atelier Test"

_gitdir="$(git -C "$_repo" rev-parse --absolute-git-dir 2>/dev/null)"
mkdir -p "$_gitdir/info"

# Reproduce this checkout's shape: .plan/ ignored via .git/info/exclude, with
# NO .gitignore anywhere.
printf '# local-only excludes\n.plan/\n' > "$_gitdir/info/exclude"

printf 'initial\n' > "$_repo/README.md"
git -C "$_repo" add README.md >/dev/null 2>&1
git -C "$_repo" commit -q -m "chore: initial" 2>/dev/null

mkdir -p "$_repo/.plan"
printf '# Plan 99\nApproach: reproduce audit#160\n' > "$_repo/.plan/99.md"

# The ignore is invisible to a .gitignore grep but visible to check-ignore —
# the reason Group 3 probes with check-ignore.
if [ -e "$_repo/.gitignore" ]; then
  fail "behavioral: fixture must have no .gitignore (the ignore lives in .git/info/exclude)"
else
  pass "behavioral: fixture has no .gitignore — a grep-based probe would see nothing"
fi

if git -C "$_repo" check-ignore -q .plan/ 2>/dev/null; then
  pass "behavioral: check-ignore detects the .git/info/exclude entry for .plan/"
else
  fail "behavioral: check-ignore must detect .plan/ ignored via .git/info/exclude"
fi

# THE failure /atelier:plan-task Phase 4 hits under planStorage=committed.
if git -C "$_repo" add .plan/99.md >/dev/null 2>&1; then
  fail "behavioral: \`git add\` on an ignored .plan/99.md must exit non-zero (it succeeded)"
else
  pass "behavioral: \`git add .plan/99.md\` exits non-zero on the ignored path (Phase 4 failure reproduced)"
fi

if [ -z "$(git -C "$_repo" ls-files -- .plan/99.md 2>/dev/null)" ]; then
  pass "behavioral: the ignored plan file was not staged (git ls-files is empty)"
else
  fail "behavioral: the ignored plan file must not be staged after the failed add"
fi

# Control: the failure is caused by the ignore entry, nothing else. Drop the
# entry and the identical add succeeds.
printf '# local-only excludes\n' > "$_gitdir/info/exclude"
if git -C "$_repo" add .plan/99.md >/dev/null 2>&1; then
  pass "behavioral(control): the same add succeeds once .plan/ is no longer excluded"
else
  fail "behavioral(control): add of a non-ignored .plan/99.md should succeed"
fi

if [ -n "$(git -C "$_repo" ls-files -- .plan/99.md 2>/dev/null)" ]; then
  pass "behavioral(control): the plan file stages normally when not ignored"
else
  fail "behavioral(control): the plan file should be staged when not ignored"
fi

# ---------------------------------------------------------------------------
# Group 5: template documents `resident` without changing the install default
# ---------------------------------------------------------------------------

TEMPLATE_PLAN_STORAGE="$(json_str "$TEMPLATE" planStorage)"
if [ "$TEMPLATE_PLAN_STORAGE" = "committed" ]; then
  pass "template: fresh-install default for planStorage is still 'committed'"
else
  fail "template: planStorage default must stay 'committed' for fresh installs (got '$TEMPLATE_PLAN_STORAGE')"
fi

chk_prose "$TEMPLATE" '"planStorage": "committed"' \
  "template: planStorage key present, defaulting to committed"

TEMPLATE_COMMENT="$(json_str "$TEMPLATE" _planStorage_comment)"
if printf '%s' "$TEMPLATE_COMMENT" | grep -qF 'resident'; then
  pass "template: _planStorage_comment documents 'resident' as a legal third value"
else
  fail "template: _planStorage_comment must document 'resident' alongside committed/local"
fi

if printf '%s' "$TEMPLATE_COMMENT" | grep -qF 'Absent field is treated as '; then
  pass "template: _planStorage_comment still states the absent-field default"
else
  fail "template: _planStorage_comment must keep stating what an absent field means"
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$fails" -eq 0 ]; then
  echo "plan-storage-config-consistency (#38 / audit#160): all assertions passed."
  exit 0
else
  echo "plan-storage-config-consistency (#38 / audit#160): $fails assertion(s) failed."
  exit 1
fi
