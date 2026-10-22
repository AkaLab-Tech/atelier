#!/usr/bin/env bash
#
# Regression test for #556 — the task base comes from atelier-resolve-base
# (GitHub's default branch), never from a dev-else-main probe.
#
# Hermetic: reads committed files only.
#
# Run:  hooks/tests/base-branch-resolution-prose.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

# Literal backticks in fixed-string patterns; nothing should expand.
# shellcheck disable=SC2016
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }
has() { # has <file> <fixed-string> <label>
  if grep -qF -- "$2" "$1" 2>/dev/null; then pass "$3"; else fail "$3 — '$2' not in $1"; fi
}

NEXT=commands/next-task.md
RESUME=commands/resume-task.md
ALIGN=commands/align.md
MERGE=skills/auto-merge/SKILL.md
RETRY=skills/retry-with-logs/SKILL.md

echo "base-branch-resolution (#556) — prose invariants"

# The dev-else-main rule is gone.
scope="commands skills"
# agents/task-orchestrator.md is owned by #413; include agents/ only when clean.
if grep -rqE 'ls-remote --heads origin dev|dev-else-main|dev else main' agents 2>/dev/null; then
  echo "  NOTE: agents/ still carries the dev-else-main rule (owned by #413); scoped out"
else
  scope="commands skills agents"
fi
for pat in 'ls-remote --heads origin dev' 'dev-else-main' 'dev else main'; do
  # shellcheck disable=SC2086
  hit=$(grep -rnF -- "$pat" $scope 2>/dev/null | head -1)
  if [ -n "$hit" ]; then fail "absent in [$scope]: '$pat' — $hit"; else pass "absent in [$scope]: '$pat'"; fi
done

# The helper is used at the 5 sites.
for f in "$NEXT" "$RESUME" "$ALIGN" "$MERGE" "$RETRY"; do
  has "$f" 'atelier-resolve-base' "$f uses atelier-resolve-base"
done

# Frontmatter grants (the allowed-tools line).
tools() { grep -m1 '^allowed-tools:' "$1"; }
for f in "$NEXT" "$RESUME" "$ALIGN"; do
  if tools "$f" | grep -qF 'Bash(atelier-resolve-base:*)'; then pass "$f grants atelier-resolve-base"; else fail "$f frontmatter lacks Bash(atelier-resolve-base:*)"; fi
done
if tools "$RESUME" | grep -qF 'Bash(git fetch:*)'; then pass "$RESUME grants git fetch"; else fail "$RESUME frontmatter lacks Bash(git fetch:*)"; fi

# Registration and allowlist.
has install.sh '_phase_c_1_symlink_helper atelier-resolve-base' "install.sh symlinks the helper"
has install.sh 'atelier-resolve-base <root>' "install.sh help lists the helper"
has templates/settings.template.json '"Bash(atelier-resolve-base:*)"' "settings template allows the helper"
if [ -x scripts/atelier-resolve-base ]; then pass "scripts/atelier-resolve-base is executable"; else fail "scripts/atelier-resolve-base not executable"; fi

# next-task fails closed.
has "$NEXT" 'On a non-zero exit' "next-task keys on the helper's exit status"
has "$NEXT" '**stop in both modes**' "next-task stops in both modes"
has "$NEXT" 'Never fall back to `main`' "next-task forbids a main fallback"

# retry-with-logs resets from the resolved base.
has "$RETRY" '--from origin/<base>' "retry-with-logs resets with --from origin/<base>"
has "$RETRY" 'reset blocked: base branch unresolved' "retry-with-logs blocks on an unresolved base"

# Other sites.
has "$RESUME" 'git fetch origin <base>' "resume-task fetches the resolved base"
has "$MERGE" 'base not fast-forwarded: base branch unresolved' "auto-merge skips with the unresolved message"

echo
if [ "$fails" -eq 0 ]; then echo "All assertions passed."; exit 0; fi
echo "$fails assertion(s) failed."; exit 1
