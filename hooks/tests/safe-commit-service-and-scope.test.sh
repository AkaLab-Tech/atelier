#!/usr/bin/env bash
#
# Regression test for #29 — skills/safe-commit/SKILL.md documents two new
# behaviors on top of the existing lint/typecheck/test push gate:
#
#   1. Package-scoping pre-check: when a pnpm-workspace.yaml is present and
#      staged paths resolve to a confident single-package scope, the skill
#      documents a scoped test command (`pnpm --filter <pkg>... run test` or
#      `turbo run test --filter=<pkg>...`) — and explicitly states this
#      scoping is a PRE-CHECK only, with the PR's full CI remaining the
#      authoritative §6 gate.
#   2. `service unreachable` outcome: a distinct BLOCKED classification
#      (separate from GREEN and a plain RED) for a test failure caused by an
#      unreachable dependency service (e.g. Postgres/Redis/Mongo), including
#      a `SERVICE-UNREACHABLE` `Result:` line, a connection-failure signature
#      (e.g. ECONNREFUSED), and remedy guidance pointing at `docker compose`
#      / the `docker-env` skill.
#
# This is a pure static-content assertion over the tracked skill file — the
# change under test is prose, not shell surface. No network, no Docker, no
# external state: hermetic and deterministic.
#
# Run:  hooks/tests/safe-commit-service-and-scope.test.sh
# Exit: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="${SAFE_COMMIT_SKILL_PATH:-$REPO_ROOT/skills/safe-commit/SKILL.md}"

fails=0
pass() { printf '  PASS: %s\n' "$1"; }
fail() { printf '  FAIL: %s\n' "$1"; fails=$((fails + 1)); }

[ -r "$SKILL" ] || { echo "  FAIL: cannot read $SKILL"; exit 1; }

# chk_prose <fixed-string> <label>
chk_prose() {
  local pattern="$1" label="$2"
  if grep -qF "$pattern" "$SKILL" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — token '$pattern' not found in $SKILL"
  fi
}

# ---------------------------------------------------------------------------
# Group 1: service-unreachable classification
# ---------------------------------------------------------------------------

chk_prose 'Result:      SERVICE-UNREACHABLE' \
  "documents a SERVICE-UNREACHABLE Result: line in the report format"

chk_prose '**`service unreachable`**' \
  "documents the service-unreachable outcome as its own classification (bold anchor)"

chk_prose 'distinct BLOCKED outcome' \
  "states service-unreachable is a distinct BLOCKED outcome, never a bypass"

chk_prose 'ECONNREFUSED' \
  "documents ECONNREFUSED as a connection-failure signature"

chk_prose 'docker compose up -d' \
  "documents the docker compose remedy for an unreachable service"

chk_prose '`docker-env`' \
  "points the remedy at the docker-env skill"

# ---------------------------------------------------------------------------
# Group 2: package-scoping pre-check
# ---------------------------------------------------------------------------

chk_prose '`pnpm-workspace.yaml`' \
  "documents detecting pnpm-workspace.yaml before choosing the test command"

chk_prose 'pnpm --filter <pkg>... run test' \
  "documents the scoped pnpm --filter <pkg>... dependents-inclusive test command"

chk_prose 'turbo run test --filter=<pkg>...' \
  "documents the turbo run test --filter=<pkg>... alternative when turbo.json exists"

chk_prose '**Scoping is a pre-check, not a substitute for CI.**' \
  "states scoping is a pre-check, not a substitute for CI"

chk_prose 'remains the authoritative §6 gate' \
  "states the PR's full CI run remains the authoritative §6 gate"

echo ""
if [ "$fails" -eq 0 ]; then
  echo "safe-commit-service-and-scope (#29): all assertions passed."
  exit 0
else
  echo "safe-commit-service-and-scope (#29): $fails assertion(s) failed."
  exit 1
fi
